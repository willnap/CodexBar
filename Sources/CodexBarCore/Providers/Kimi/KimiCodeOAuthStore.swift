import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct KimiCodeResolvedCredential: Sendable {
    let accessToken: String
    let historyOwnerID: String
    let historyOwnerAliases: [String]
}

/// Shares the CLI's file and refresh lock; never reads the Keychain or starts a login flow.
actor KimiCodeOAuthStore {
    static let shared = KimiCodeOAuthStore()
    private var inFlight: [String: (id: UUID, task: Task<KimiCodeResolvedCredential, Error>)] = [:]

    func resolve(
        region: KimiRegion,
        environment: [String: String],
        rejectedAccessToken: String? = nil,
        enrichmentToken: String? = nil,
        transport: any ProviderHTTPTransport) async throws -> KimiCodeResolvedCredential
    {
        guard let url = KimiSettingsReader.kimiCodeCredentialURL(region: region, environment: environment) else {
            throw KimiAPIError.expiredCodeCredential
        }
        let key = url.standardizedFileURL.path + "\0" + Self.enrichmentScope(enrichmentToken)
        if let current = self.inFlight[key] {
            let resolved = try await current.task.value
            if self.inFlight[key]?.id == current.id { self.inFlight[key] = nil }
            if rejectedAccessToken != resolved.accessToken { return resolved }
            // A forced refresh must not piggyback a normal fresh-token short circuit.
            return try await self.resolve(
                region: region,
                environment: environment,
                rejectedAccessToken: rejectedAccessToken,
                enrichmentToken: enrichmentToken,
                transport: transport)
        }
        let task = Task {
            try await Self.resolveLocked(
                url: url,
                environment: environment,
                rejectedAccessToken: rejectedAccessToken,
                enrichmentToken: enrichmentToken,
                transport: transport)
        }
        let id = UUID()
        self.inFlight[key] = (id, task)
        defer { if self.inFlight[key]?.id == id { self.inFlight[key] = nil } }
        return try await task.value
    }

    private static func resolveLocked(
        url: URL,
        environment: [String: String],
        rejectedAccessToken: String?,
        enrichmentToken: String?,
        transport: any ProviderHTTPTransport) async throws -> KimiCodeResolvedCredential
    {
        let lock = try await KimiCodeRefreshLock
            .acquire(home: url.deletingLastPathComponent().deletingLastPathComponent())
        defer { lock.release() }
        try Task.checkCancellation()
        try lock.validate()
        guard var credential = KimiCodeStoredCredential.load(url) else { throw KimiAPIError.expiredCodeCredential }
        let needsRefresh = !credential.isFresh || credential.accessToken == rejectedAccessToken
        if needsRefresh {
            guard !credential.refreshToken.isEmpty else { throw KimiAPIError.expiredCodeCredential }
            let original = credential
            let response: ProviderHTTPResponse
            do {
                response = try await self.refresh(
                    credential.refreshToken,
                    environment: environment,
                    transport: transport)
            } catch {
                try lock.validate()
                // A CLI process may have rotated without participating in the lock (older CLI versions).
                if let peer = KimiCodeStoredCredential.load(url), peer.fingerprint != original.fingerprint,
                   peer.isFresh
                {
                    credential = peer
                    return try self.persistOwner(credential, url: url, enrichmentToken: enrichmentToken)
                }
                throw error
            }
            try lock.validate()
            guard let current = KimiCodeStoredCredential.load(url) else {
                throw KimiAPIError.apiError("Kimi Code login was removed during refresh; sign in again.")
            }
            if current.fingerprint != original.fingerprint {
                guard current.isFresh
                else { throw KimiAPIError.apiError("Kimi Code login changed during refresh; retry.") }
                return try self.persistOwner(current, url: url, enrichmentToken: enrichmentToken)
            }
            // Keep metadata changes from peer writers and optional fields omitted by the server.
            credential = try current.rotated(response.data, enrichmentToken: enrichmentToken)
        }
        try lock.validate()
        return try self.persistOwner(credential, url: url, enrichmentToken: enrichmentToken)
    }

    private static func refresh(
        _ refreshToken: String,
        environment: [String: String],
        transport: any ProviderHTTPTransport) async throws -> ProviderHTTPResponse
    {
        var request = URLRequest(url: URL(string: "https://auth.kimi.com/api/oauth/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in KimiSettingsReader.kimiCodeIdentityHeaders(environment: environment) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let fields = [
            ("client_id", "17e5f671-d194-4dfb-9706-5516cb48c098"),
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
        ]
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        request.httpBody = Data(fields.map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed)!)" }
            .joined(separator: "&").utf8)
        let response = try await transport.response(for: request)
        let payload = (try? JSONSerialization.jsonObject(with: response.data)) as? [String: Any]
        if response.statusCode == 401 || response.statusCode == 403 || payload?["error"] as? String == "invalid_grant" {
            throw KimiAPIError.invalidCodeCredential
        }
        guard response.statusCode == 200 else {
            // OAuth response text can contain credentials; surface status only.
            throw KimiAPIError.apiError("Kimi Code login refresh failed (HTTP \(response.statusCode)).")
        }
        return response
    }

    private static func persistOwner(
        _ credential: KimiCodeStoredCredential,
        url: URL,
        enrichmentToken: String?) throws -> KimiCodeResolvedCredential
    {
        var payload = credential.payload
        let baseOwner = credential.ownerID
        let enrichmentScope = self.enrichmentScope(enrichmentToken)
        let owner = enrichmentToken == nil ? baseOwner : "kimi-credential-v1:" + KimiCodeStoredCredential.digest(
            "https://api.kimi.com/coding/v1/usages\0oauth-enriched\0" + baseOwner + "\0" + enrichmentScope)
        var aliases = credential.aliases(enrichmentScope: enrichmentScope)
        if let legacy = KimiUsageFetcher.legacyHistoryOwnerID(
            endpoint: KimiUsageFetcher.codeAPIUsageEndpoint(baseURL: KimiRegion.china.apiBaseURL),
            credential: credential.accessToken,
            enrichmentCredential: enrichmentToken), !aliases.contains(legacy)
        {
            aliases = [aliases.first, legacy].compactMap(\.self)
        }
        payload["codexbar_history"] = [
            "owner": baseOwner,
            "fingerprint": credential.fingerprint,
            "aliases": aliases,
            "alias_scope": enrichmentScope,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        if data != credential.data {
            do { try self.atomicWrite(data, to: url) } catch {
                throw KimiAPIError.apiError("Unable to save refreshed Kimi Code login.")
            }
        }
        return KimiCodeResolvedCredential(
            accessToken: credential.accessToken,
            historyOwnerID: owner,
            historyOwnerAliases: aliases)
    }

    static func enrichmentScope(_ token: String?) -> String {
        token.map(KimiUsageFetcher.historyCredentialScope) ?? "none"
    }

    private static func atomicWrite(_ data: Data, to url: URL) throws {
        let temporary = url.appendingPathExtension("codexbar-\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        guard rename(temporary.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}

private struct KimiCodeStoredCredential {
    let data: Data
    var payload: [String: Any] {
        (try? JSONSerialization.jsonObject(with: self.data)) as? [String: Any] ?? [:]
    }

    var accessToken: String {
        SettingsValue.cleaned(self.payload["access_token"] as? String) ?? ""
    }

    var refreshToken: String {
        SettingsValue.cleaned(self.payload["refresh_token"] as? String) ?? ""
    }

    var fingerprint: String {
        Self.digest(self.accessToken + "\0" + self.refreshToken)
    }

    var isFresh: Bool {
        let raw = self.payload["expires_at"]
        let expiry = (raw as? NSNumber)?.doubleValue ?? (raw as? String).flatMap(Double.init)
        return !self.accessToken.isEmpty && expiry.map { $0.isFinite && $0 > Date().timeIntervalSince1970 + 60 } == true
    }

    private var metadata: [String: Any]? {
        guard let metadata = self.payload["codexbar_history"] as? [String: Any],
              metadata["fingerprint"] as? String == self.fingerprint else { return nil }
        return metadata
    }

    func aliases(enrichmentScope: String) -> [String] {
        guard self.metadata?["alias_scope"] as? String == enrichmentScope else { return [] }
        return (self.metadata?["aliases"] as? [String] ?? []).filter(Self.validOwner)
    }

    var ownerID: String {
        if let subject = self.subject {
            return "kimi-credential-v1:" + Self.digest("https://api.kimi.com/coding/v1/usages\0oauth-sub\0" + subject)
        }
        if let owner = self.metadata?["owner"] as? String, Self.validOwner(owner) { return owner }
        return "kimi-credential-v1:" + Self
            .digest("https://api.kimi.com/coding/v1/usages\0oauth-login\0" + UUID().uuidString)
    }

    private var subject: String? {
        let scope = KimiUsageFetcher.historyCredentialScope(self.accessToken)
        return scope.hasPrefix("jwt:") ? scope : nil
    }

    static func load(_ url: URL) -> Self? {
        guard let data = try? Data(contentsOf: url),
              (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else { return nil }
        return Self(data: data)
    }

    func rotated(_ response: Data, enrichmentToken: String?) throws -> Self {
        guard let refreshed = (try? JSONSerialization.jsonObject(with: response)) as? [String: Any],
              let access = SettingsValue.cleaned(refreshed["access_token"] as? String),
              let refresh = SettingsValue.cleaned(refreshed["refresh_token"] as? String),
              let expiry = (refreshed["expires_in"] as? NSNumber)?.doubleValue,
              expiry.isFinite, expiry > 0
        else {
            throw KimiAPIError.parseFailed("Kimi Code login refresh returned an incomplete credential.")
        }
        var payload = self.payload
        for key in ["access_token", "refresh_token", "expires_in", "scope", "token_type"] {
            if let value = refreshed[key] { payload[key] = value }
        }
        payload["expires_at"] = Date().timeIntervalSince1970 + expiry
        var rotated = try Self(data: JSONSerialization.data(withJSONObject: payload))
        let sameSubject = self.subject == rotated.subject
        let owner = sameSubject ? self.ownerID : rotated.ownerID
        let enrichmentScope = KimiCodeOAuthStore.enrichmentScope(enrichmentToken)
        var aliases = sameSubject ? self.aliases(enrichmentScope: enrichmentScope) : []
        if sameSubject, let legacy = KimiUsageFetcher.legacyHistoryOwnerID(
            endpoint: KimiUsageFetcher.codeAPIUsageEndpoint(baseURL: KimiRegion.china.apiBaseURL),
            credential: self.accessToken,
            enrichmentCredential: enrichmentToken), !aliases.contains(legacy)
        { aliases = [aliases.first, legacy].compactMap(\.self) }
        payload["codexbar_history"] = [
            "owner": owner,
            "fingerprint": Self.digest(access + "\0" + refresh),
            "aliases": aliases,
            "alias_scope": enrichmentScope,
        ]
        rotated = try Self(data: JSONSerialization.data(withJSONObject: payload))
        return rotated
    }

    private static func validOwner(_ value: String) -> Bool {
        let prefix = "kimi-credential-v1:"
        return value.hasPrefix(prefix) && value.count == prefix.count + 64 &&
            value.dropFirst(prefix.count).allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Compatible with the CLI's proper-lockfile directory and mtime heartbeat.
private struct KimiCodeRefreshLock: Sendable {
    let url: URL
    let inode: UInt64
    let heartbeat: Task<Void, Never>

    static func acquire(home: URL) async throws -> Self {
        let directory = home.appendingPathComponent("oauth", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("kimi-code.lock", isDirectory: true)
        let deadline = Date().addingTimeInterval(35)
        while true {
            try Task.checkCancellation()
            if mkdir(url.path, 0o700) == 0 {
                let inode = try self.inode(at: url)
                let heartbeat = Task {
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(1)) } catch { return }
                        guard (try? self.inode(at: url)) == inode else { return }
                        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
                    }
                }
                return Self(url: url, inode: inode, heartbeat: heartbeat)
            }
            guard errno == EEXIST else { throw KimiAPIError.apiError("Unable to lock Kimi Code login refresh.") }
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            if let modified = attributes?[.modificationDate] as? Date, Date().timeIntervalSince(modified) > 10 {
                guard rmdir(url.path) == 0 else {
                    throw KimiAPIError.apiError("Unable to recover the Kimi Code login refresh lock.")
                }
                continue
            }
            guard Date() < deadline else { throw KimiAPIError.apiError("Kimi Code login refresh is busy; retry.") }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    func validate() throws {
        guard (try? Self.inode(at: self.url)) == self.inode else {
            throw KimiAPIError.apiError("Kimi Code login refresh lock changed; retry.")
        }
        do {
            try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: self.url.path)
        } catch {
            throw KimiAPIError.apiError("Unable to maintain the Kimi Code login refresh lock.")
        }
        guard (try? Self.inode(at: self.url)) == self.inode else {
            throw KimiAPIError.apiError("Kimi Code login refresh lock changed; retry.")
        }
    }

    func release() {
        self.heartbeat.cancel()
        if (try? Self.inode(at: self.url)) == self.inode { _ = rmdir(self.url.path) }
    }

    private static func inode(at url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let inode = attributes[.systemFileNumber] as? NSNumber else { throw CocoaError(.fileReadUnknown) }
        return inode.uint64Value
    }
}
