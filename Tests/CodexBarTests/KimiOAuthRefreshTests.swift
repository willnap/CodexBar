import Foundation
import Testing
@testable import CodexBarCore

struct KimiOAuthRefreshTests {
    @Test
    func `expired CLI login refreshes and survives a new strategy instance`() async throws {
        let home = try makeTemporaryKimiCodeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let url = try writeKimiCodeCredential(
            home: home,
            accessToken: "expired",
            refreshToken: "refresh +/&",
            expiresAt: 1)
        let transport = KimiOAuthFixtureTransport()
        let context = self.context(home)
        let result = try await KimiCLICredentialFetchStrategy(transport: transport).fetch(context)
        let second = try await KimiCLICredentialFetchStrategy(transport: transport).fetch(context)
        #expect(result.usage.primary?.usedPercent == 25)
        #expect(second.usage.primary?.usedPercent == 25)
        let owner = try #require(result.usage.identity?.accountID)
        #expect(owner.hasPrefix("kimi-credential-v1:"))
        #expect(owner == second.usage.identity?.accountID)
        let saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(saved["access_token"] as? String == "renewed-access")
        #expect(saved["refresh_token"] as? String == "rotated-refresh")
        #expect(saved["scope"] as? String == "synthetic-scope")
        #expect((saved["expires_at"] as? Double ?? 0) > Date().timeIntervalSince1970 + 800)
        #expect(await transport.paths() == ["/api/oauth/token", "/coding/v1/usages", "/coding/v1/usages"])
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("oauth/kimi-code.lock").path))
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }

    @Test
    func `rejected fresh access refreshes once and retries usage`() async throws {
        let home = try makeTemporaryKimiCodeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        _ = try writeKimiCodeCredential(
            home: home,
            accessToken: "rejected",
            refreshToken: "refresh +/&",
            expiresAt: Date().addingTimeInterval(900).timeIntervalSince1970)
        let transport = KimiOAuthFixtureTransport()
        let result = try await KimiCLICredentialFetchStrategy(transport: transport).fetch(self.context(home))
        #expect(result.usage.primary?.usedPercent == 25)
        #expect(await transport.paths() == ["/coding/v1/usages", "/api/oauth/token", "/coding/v1/usages"])
    }

    @Test
    func `concurrent strategies rotate a refresh credential only once`() async throws {
        let home = try makeTemporaryKimiCodeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        _ = try writeKimiCodeCredential(home: home, accessToken: "expired", refreshToken: "refresh +/&", expiresAt: 1)
        let transport = KimiOAuthFixtureTransport()
        let context = self.context(home)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask { _ = try await KimiCLICredentialFetchStrategy(transport: transport).fetch(context) }
            }
            try await group.waitForAll()
        }
        #expect(await transport.paths().filter { $0 == "/api/oauth/token" }.count == 1)
    }

    @Test
    func `invalid grant preserves existing login file and never sends usage`() async throws {
        let home = try makeTemporaryKimiCodeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let url = try writeKimiCodeCredential(
            home: home,
            accessToken: "expired",
            refreshToken: "refresh +/&",
            expiresAt: 1)
        let original = try Data(contentsOf: url)
        let transport = KimiOAuthFixtureTransport(refreshStatus: 400)
        await #expect(throws: KimiAPIError.invalidCodeCredential) {
            try await KimiCLICredentialFetchStrategy(transport: transport).fetch(self.context(home))
        }
        #expect(try Data(contentsOf: url) == original)
        #expect(await transport.paths() == ["/api/oauth/token"])
    }

    @Test
    func `a rejected renewed access token is retried only once`() async throws {
        let home = try makeTemporaryKimiCodeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        _ = try writeKimiCodeCredential(
            home: home,
            accessToken: "rejected",
            refreshToken: "refresh +/&",
            expiresAt: Date().addingTimeInterval(900).timeIntervalSince1970)
        let transport = KimiOAuthFixtureTransport(rejectRenewedAccess: true)
        await #expect(throws: KimiAPIError.invalidCodeCredential) {
            try await KimiCLICredentialFetchStrategy(transport: transport).fetch(self.context(home))
        }
        #expect(await transport.paths() == ["/coding/v1/usages", "/api/oauth/token", "/coding/v1/usages"])
    }

    @Test(arguments: [200, 503])
    func `failed refresh preserves login for another attempt`(status: Int) async throws {
        let home = try makeTemporaryKimiCodeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let url = try writeKimiCodeCredential(
            home: home,
            accessToken: "expired",
            refreshToken: "refresh +/&",
            expiresAt: 1)
        let original = try Data(contentsOf: url)
        let transport = KimiOAuthFixtureTransport(
            refreshStatus: status,
            refreshBody: #"{"access_token":"synthetic-secret-value"}"#)
        do {
            _ = try await KimiCLICredentialFetchStrategy(transport: transport).fetch(self.context(home))
            Issue.record("Expected incomplete or unavailable refresh to fail")
        } catch {
            #expect(try Data(contentsOf: url) == original)
            #expect(!error.localizedDescription.contains("synthetic-secret-value"))
        }
        let result = try await KimiCLICredentialFetchStrategy(transport: KimiOAuthFixtureTransport())
            .fetch(self.context(home))
        #expect(result.usage.primary?.usedPercent == 25)
    }

    @Test
    func `shared CLI lock rereads a peer rotation instead of refreshing again`() async throws {
        let home = try makeTemporaryKimiCodeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        _ = try writeKimiCodeCredential(home: home, accessToken: "expired", refreshToken: "refresh +/&", expiresAt: 1)
        let lock = home.appendingPathComponent("oauth/kimi-code.lock", isDirectory: true)
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: true)
        let transport = KimiOAuthFixtureTransport()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                defer { try? FileManager.default.removeItem(at: lock) }
                try await Task.sleep(for: .milliseconds(100))
                _ = try writeKimiCodeCredential(
                    home: home,
                    accessToken: "renewed-access",
                    refreshToken: "peer-refresh",
                    expiresAt: Date().addingTimeInterval(900).timeIntervalSince1970)
            }
            let result = try await KimiCLICredentialFetchStrategy(transport: transport).fetch(self.context(home))
            #expect(result.usage.primary?.usedPercent == 25)
            try await group.waitForAll()
        }
        #expect(await transport.paths() == ["/coding/v1/usages"])
    }

    @Test
    func `concurrent enrichment accounts keep their owners and legacy aliases separate`() async throws {
        let home = try makeTemporaryKimiCodeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        _ = try writeKimiCodeCredential(
            home: home,
            accessToken: "renewed-access",
            refreshToken: "refresh +/&",
            expiresAt: Date().addingTimeInterval(900).timeIntervalSince1970)
        let store = KimiCodeOAuthStore()
        let owners = try await withThrowingTaskGroup(of: KimiCodeResolvedCredential.self) { group in
            for token in ["web-a", "web-b"] {
                group.addTask {
                    try await store.resolve(
                        region: .china,
                        environment: ["KIMI_CODE_HOME": home.path],
                        enrichmentToken: token,
                        transport: KimiOAuthFixtureTransport())
                }
            }
            var results: [KimiCodeResolvedCredential] = []
            for try await result in group {
                results.append(result)
            }
            return results
        }
        #expect(Set(owners.map(\.historyOwnerID)).count == 2)
        #expect(Set(owners[0].historyOwnerAliases).isDisjoint(with: Set(owners[1].historyOwnerAliases)))
    }

    @Test
    func `logout during refresh never recreates the credential file`() async throws {
        let home = try makeTemporaryKimiCodeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let url = try writeKimiCodeCredential(
            home: home,
            accessToken: "expired",
            refreshToken: "refresh +/&",
            expiresAt: 1)
        let fixture = KimiOAuthFixtureTransport()
        let transport = ProviderHTTPTransportHandler { request in
            let result = try await fixture.data(for: request)
            if request.url?.path == "/api/oauth/token" { try FileManager.default.removeItem(at: url) }
            return result
        }
        do {
            _ = try await KimiCLICredentialFetchStrategy(transport: transport).fetch(self.context(home))
            Issue.record("A completed logout must stop refresh persistence")
        } catch {
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test
    func `lost refresh lock ownership leaves peer credential untouched`() async throws {
        let home = try makeTemporaryKimiCodeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let url = try writeKimiCodeCredential(
            home: home,
            accessToken: "expired",
            refreshToken: "refresh +/&",
            expiresAt: 1)
        let lock = home.appendingPathComponent("oauth/kimi-code.lock", isDirectory: true)
        let fixture = KimiOAuthFixtureTransport()
        let peer = Data(#"{"access_token":"renewed-access","refresh_token":"peer-refresh","expires_at":2000000000}"#
            .utf8)
        let transport = ProviderHTTPTransportHandler { request in
            let result = try await fixture.data(for: request)
            if request.url?.path == "/api/oauth/token" {
                try FileManager.default.moveItem(at: lock, to: home.appendingPathComponent("retired-lock"))
                try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
                try peer.write(to: url, options: .atomic)
            }
            return result
        }
        do {
            _ = try await KimiCLICredentialFetchStrategy(transport: transport).fetch(self.context(home))
            Issue.record("A compromised lock must stop refresh persistence")
        } catch {
            #expect(try Data(contentsOf: url) == peer)
            #expect(FileManager.default.fileExists(atPath: lock.path))
        }
    }

    @Test
    func `stale lock that cannot be removed fails instead of spinning`() async throws {
        let home = try makeTemporaryKimiCodeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        _ = try writeKimiCodeCredential(
            home: home,
            accessToken: "renewed-access",
            refreshToken: "refresh +/&",
            expiresAt: Date().addingTimeInterval(900).timeIntervalSince1970)
        let lock = home.appendingPathComponent("oauth/kimi-code.lock", isDirectory: true)
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: true)
        try Data().write(to: lock.appendingPathComponent("unexpected-file"))
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-30)],
            ofItemAtPath: lock.path)
        // Bound the broken implementation's spin so the regression can fail safely.
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await Task.sleep(for: .milliseconds(250))
                try? FileManager.default.removeItem(at: lock)
            }
            do {
                _ = try await KimiCLICredentialFetchStrategy(transport: KimiOAuthFixtureTransport())
                    .fetch(self.context(home))
                Issue.record("An unremovable stale lock must fail closed")
            } catch {
                #expect(error is KimiAPIError)
            }
            try await group.waitForAll()
        }
    }

    private func context(_ home: URL) -> ProviderFetchContext {
        makeKimiFetchContext(
            sourceMode: .auto,
            environment: ["KIMI_CODE_HOME": home.path],
            settings: .make(kimi: .init(cookieSource: .off, manualCookieHeader: nil)))
    }
}

private actor KimiOAuthFixtureTransport: ProviderHTTPTransport {
    private var requests: [URLRequest] = []
    let refreshStatus: Int
    let refreshBody: String?
    let rejectRenewedAccess: Bool
    init(refreshStatus: Int = 200, refreshBody: String? = nil, rejectRenewedAccess: Bool = false) {
        self.refreshStatus = refreshStatus
        self.refreshBody = refreshBody
        self.rejectRenewedAccess = rejectRenewedAccess
    }

    func paths() -> [String] { self.requests.compactMap { $0.url?.path } }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        self.requests.append(request)
        let url = try #require(request.url)
        let status: Int
        let body: String
        if url.path == "/api/oauth/token" {
            #expect(url.absoluteString == "https://auth.kimi.com/api/oauth/token")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
            #expect(request.value(forHTTPHeaderField: "X-Msh-Platform") == "kimi_code_cli")
            let form = try #require(String(data: request.httpBody ?? Data(), encoding: .utf8))
            #expect(form.contains("client_id=17e5f671-d194-4dfb-9706-5516cb48c098"))
            #expect(form.contains("grant_type=refresh_token"))
            #expect(form.contains("refresh_token=refresh%20%2B%2F%26") || form
                .contains("refresh_token=refresh+%2B%2F%26"))
            try await Task.sleep(for: .milliseconds(30))
            status = self.refreshStatus
            body = self.refreshBody ?? (status == 200
                ? #"{"access_token":"renewed-access","refresh_token":"rotated-refresh","expires_in":900}"#
                : #"{"error":"invalid_grant","error_description":"secret must not reach UI"}"#)
        } else {
            #expect(url.absoluteString == "https://api.kimi.com/coding/v1/usages")
            let accepted = request.value(forHTTPHeaderField: "Authorization") == "Bearer renewed-access"
                && !self.rejectRenewedAccess
            status = accepted ? 200 : 401
            body = status == 200
                ? #"{"usage":{"limit":"100","used":"25","remaining":"75"},"limits":[]}"#
                : #"{"error":"unauthorized"}"#
        }
        let response = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
        return (Data(body.utf8), response)
    }
}
