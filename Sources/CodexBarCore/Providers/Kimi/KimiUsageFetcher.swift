#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct KimiUsageFetcher: Sendable {
    private static let log = CodexBarLog.logger(LogCategories.provider(.kimi, scope: "api"))
    private static let subscriptionGraceSeconds: TimeInterval = 2

    public static func fetchCodeAPIUsage(
        apiKey: String,
        region: KimiRegion = .china,
        baseURL: URL? = nil,
        identityHeaders: [String: String] = [:],
        webAuthToken: String? = nil,
        now: Date = Date(),
        readsProfile: Bool = false,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) async throws -> KimiUsageSnapshot
    {
        try await self.fetchCodeAPIUsage(
            apiKey: apiKey,
            region: region,
            baseURL: baseURL,
            identityHeaders: identityHeaders,
            webCredential: webAuthToken.map { KimiWebCredential(token: $0) },
            now: now,
            transport: transport)
    }

    static func fetchCodeAPIUsage(
        apiKey: String,
        region: KimiRegion = .china,
        baseURL: URL? = nil,
        identityHeaders: [String: String] = [:],
        webCredential: KimiWebCredential?,
        readsProfile: Bool = false,
        now: Date = Date(),
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) async throws -> KimiUsageSnapshot
    {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KimiAPIError.missingAPIKey
        }

        guard let validatedBaseURL = ProviderEndpointOverrideValidator()
            .validatedURL((baseURL ?? region.apiBaseURL).absoluteString)
        else {
            throw KimiAPIError.invalidRequest("Kimi Code API base URL must use HTTPS without user info")
        }

        let endpoint = self.codeAPIUsageEndpoint(baseURL: validatedBaseURL)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        for (name, value) in identityHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let response = try await transport.response(for: request)
        let data = response.data
        guard response.statusCode == 200 else {
            let responseBody = String(data: data, encoding: .utf8) ?? "<binary data>"
            Self.log.error("Kimi Code API returned \(response.statusCode): \(responseBody)")
            throw self.codeAPIError(statusCode: response.statusCode)
        }

        var snapshot = try self.parseCodeAPIUsage(from: data, now: now)
        if let webCredential {
            snapshot = try await self.enrichCodeAPIUsage(
                snapshot,
                webAuthToken: webCredential.token,
                region: region,
                transport: webCredential.transport(transport, region: region))
        }
        // Best effort: the profile names the login and its plan, and never holds up or fails the usage reading.
        if readsProfile, let profile = await self.fetchCodeProfile(
            usageEndpoint: endpoint, apiKey: apiKey, identityHeaders: identityHeaders, transport: transport)
        {
            snapshot.accountEmail = profile.email
            snapshot.accountName = profile.name
            if snapshot.planName == nil { snapshot.planName = profile.plan }
        }
        snapshot.historyOwnerID = self.historyOwnerID(
            endpoint: endpoint, credential: apiKey, enrichmentCredential: webCredential?.token)
        snapshot.historyOwnerAliases = self.legacyHistoryOwnerID(
            endpoint: endpoint, credential: apiKey, enrichmentCredential: webCredential?.token).map { [$0] }
        return snapshot
    }

    static func fetchUsage(
        credential: KimiWebCredential,
        region: KimiRegion,
        now: Date = Date(),
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) async throws -> KimiUsageSnapshot
    {
        try await self.fetchUsage(
            authToken: credential.token,
            region: region,
            now: now,
            transport: credential.transport(transport, region: region))
    }

    public static func fetchUsage(
        authToken: String,
        region: KimiRegion = .china,
        now: Date = Date(),
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        subscriptionGrace: Duration? = nil) async throws -> KimiUsageSnapshot
    {
        let sessionInfo = self.decodeSessionInfo(from: authToken)

        let enrichment = SubscriptionEnrichment(
            authToken: authToken,
            region: region,
            sessionInfo: sessionInfo,
            transport: transport,
            grace: subscriptionGrace ?? .seconds(self.subscriptionGraceSeconds))

        let codingUsage: KimiUsage?
        do {
            codingUsage = try await withTaskCancellationHandler {
                try await self.fetchCodingUsage(
                    authToken: authToken,
                    region: region,
                    sessionInfo: sessionInfo,
                    transport: transport)
            } onCancel: {
                enrichment.cancel()
            }
        } catch {
            enrichment.cancel()
            _ = try? await enrichment.value()
            throw error
        }

        let subscription = try await enrichment.value()

        let rateLimit = codingUsage?.limits?.first
        var snapshot = KimiUsageSnapshot(
            weekly: codingUsage?.detail,
            rateLimit: rateLimit?.detail,
            rateLimitWindow: rateLimit?.window,
            subscriptionBalance: subscription.stats?.subscriptionBalance,
            subscriptionCodeWeeklyLimit: subscription.stats?.ratelimitCode7d,
            giftBalances: subscription.stats?.giftBalances,
            planName: subscription.plan?.planName,
            subscriptionStatus: subscription.plan?.subscription?.status,
            subscriptionIsActive: subscription.plan?.subscription?.active,
            updatedAt: now)
        // A lapsed Code plan can still have a usable membership quota.
        if codingUsage == nil, snapshot.toUsageSnapshot().extraRateWindows?.isEmpty != false {
            throw KimiAPIError.parseFailed("FEATURE_CODING scope not found in response")
        }
        snapshot.historyOwnerID = self.historyOwnerID(endpoint: region.webBaseURL, credential: authToken)
        snapshot.historyOwnerAliases = self.legacyHistoryOwnerID(endpoint: region.webBaseURL, credential: authToken)
            .map { [$0] }
        return snapshot
    }

    static func historyOwnerID(
        endpoint: URL,
        credential: String,
        enrichmentCredential: String? = nil) -> String?
    {
        guard !credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let material = try? JSONEncoder().encode([
                  "kimi-account-scope-v2", endpoint.absoluteString, self.historyCredentialScope(credential),
                  enrichmentCredential.map(self.historyCredentialScope) ?? "",
              ]) else { return nil }
        return "kimi-credential-v1:" + self.historyDigest(material)
    }

    /// Used only after the service accepted the credential. Token rotation changes expiry and signature,
    /// while the verified issuer/subject stays the same. Opaque credentials remain separate until a refresh
    /// exchange establishes continuity, as handled by the CLI credential store.
    static func historyCredentialScope(_ credential: String) -> String {
        if credential.split(separator: ".").count == 3,
           let claims = UsageFetcher.parseJWT(credential),
           let subject = SettingsValue.cleaned(claims["sub"] as? String),
           let identity = try? JSONEncoder().encode([SettingsValue.cleaned(claims["iss"] as? String) ?? "", subject])
        { return "jwt:" + self.historyDigest(identity) }
        return "opaque:" + self.historyDigest(Data(credential.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
    }

    private static func historyDigest(_ material: Data) -> String {
        SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
    }

    static func legacyHistoryOwnerID(
        endpoint: URL,
        credential: String,
        enrichmentCredential: String? = nil) -> String?
    {
        guard !credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let material = try? JSONEncoder().encode([
                  "kimi-credential-v1", endpoint.absoluteString, credential, enrichmentCredential ?? "",
              ]) else { return nil }
        return "kimi-credential-v1:" + SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
    }

    private static func fetchCodingUsage(
        authToken: String,
        region: KimiRegion = .china,
        sessionInfo: SessionInfo?,
        transport: any ProviderHTTPTransport) async throws -> KimiUsage?
    {
        var request = self.webRequest(
            url: region.webBaseURL.appendingPathComponent("apiv2/kimi.gateway.billing.v1.BillingService/GetUsages"),
            authToken: authToken,
            sessionInfo: sessionInfo)
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["scope": ["FEATURE_CODING"]])

        let response = try await transport.response(for: request)
        let data = response.data
        guard response.statusCode == 200 else {
            let responseBody = String(data: data, encoding: .utf8) ?? "<binary data>"
            Self.log.error("Kimi API returned \(response.statusCode): \(responseBody)")

            if response.statusCode == 401 {
                throw KimiAPIError.invalidToken
            }
            if response.statusCode == 400 {
                throw KimiAPIError.invalidRequest("Bad request")
            }
            throw KimiAPIError.httpError(response.statusCode)
        }

        let usageResponse = try JSONDecoder().decode(KimiUsageResponse.self, from: data)
        return usageResponse.usages?.first(where: { $0.scope == "FEATURE_CODING" })
    }

    private static func enrichCodeAPIUsage(
        _ snapshot: KimiUsageSnapshot,
        webAuthToken: String,
        region: KimiRegion,
        transport: any ProviderHTTPTransport) async throws -> KimiUsageSnapshot
    {
        let sessionInfo = self.decodeSessionInfo(from: webAuthToken)
        let enrichment = SubscriptionEnrichment(
            authToken: webAuthToken,
            region: region,
            sessionInfo: sessionInfo,
            transport: transport,
            grace: .seconds(self.subscriptionGraceSeconds),
            includePlan: snapshot.planName == nil)
        let subscription = try await enrichment.value()
        var enriched = snapshot
        enriched.subscriptionBalance = subscription.stats?.subscriptionBalance
        enriched.subscriptionCodeWeeklyLimit = subscription.stats?.ratelimitCode7d
        enriched.giftBalances = subscription.stats?.giftBalances
        enriched.planName = snapshot.planName ?? subscription.plan?.planName
        enriched.subscriptionStatus = subscription.plan?.subscription?.status ?? snapshot.subscriptionStatus
        enriched.subscriptionIsActive = subscription.plan?.subscription?.active ?? snapshot.subscriptionIsActive
        return enriched
    }

    static func parseCodeAPIUsage(from data: Data, now: Date = Date()) throws -> KimiUsageSnapshot {
        let response = try JSONDecoder().decode(KimiCodeAPIUsageResponse.self, from: data)
        let rateLimit = response.limits?.first
        let snapshot = KimiUsageSnapshot(
            weekly: response.usage,
            rateLimit: rateLimit?.detail,
            rateLimitWindow: rateLimit?.window,
            subscriptionBalance: nil,
            codeUsagePools: response.usages,
            boosterCost: response.boosterWallet?.costSnapshot(at: now),
            planName: response.planName,
            updatedAt: now)
        let usage = snapshot.toUsageSnapshot()
        guard usage.primary != nil || usage.secondary != nil || usage.extraRateWindows?.isEmpty == false else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: [],
                debugDescription: "No supported quota windows in Code usage response"))
        }
        return snapshot
    }

    struct CodeProfile: Equatable {
        let email: String?
        let name: String?
        let plan: String?
    }

    /// Kimi Code's own profile (`/me`, beside `/usages`), as its CLI reads it. A phone login has no email; its
    /// nickname is the name the CLI shows.
    static func parseCodeProfile(_ data: Data) -> CodeProfile? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["user_id"] is String else { return nil }
        func text(_ key: String) -> String? {
            (object[key] as? String).flatMap { SettingsValue.cleaned($0) }
        }
        return CodeProfile(email: text("email"), name: text("nickname"), plan: text("user_level_name"))
    }

    private static func fetchCodeProfile(
        usageEndpoint: URL,
        apiKey: String,
        identityHeaders: [String: String],
        transport: any ProviderHTTPTransport) async -> CodeProfile?
    {
        var request = URLRequest(url: usageEndpoint.deletingLastPathComponent().appendingPathComponent("me"))
        request.httpMethod = "GET"
        request.timeoutInterval = self.subscriptionGraceSeconds
        for (name, value) in identityHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let response = try? await transport.response(for: request), response.statusCode == 200 else {
            return nil
        }
        return self.parseCodeProfile(response.data)
    }

    static func codeAPIUsageEndpoint(baseURL: URL) -> URL {
        let normalizedPath = baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if normalizedPath == "coding/v1" || normalizedPath.hasSuffix("/coding/v1") {
            return baseURL.appendingPathComponent("usages")
        }
        if normalizedPath == "coding" || normalizedPath.hasSuffix("/coding") {
            return baseURL.appendingPathComponent("v1/usages")
        }

        return baseURL.appendingPathComponent("coding/v1/usages")
    }

    private static func fetchPlan(
        authToken: String,
        region: KimiRegion = .china,
        sessionInfo: SessionInfo?,
        transport: any ProviderHTTPTransport) async throws -> KimiSubscriptionResponse?
    {
        let url = region.webBaseURL
            .appendingPathComponent("apiv2/kimi.gateway.membership.v2.MembershipService/GetSubscription")
        var request = self.webRequest(url: url, authToken: authToken, sessionInfo: sessionInfo)
        request.httpBody = Data("{}".utf8)
        request.timeoutInterval = self.subscriptionGraceSeconds
        let response = try await transport.response(for: request)
        guard response.statusCode == 200 else { return nil }
        return try JSONDecoder().decode(KimiSubscriptionResponse.self, from: response.data)
    }

    /// Statistics and the optional title share a deadline, but neither can discard the other's completed result.
    private struct SubscriptionEnrichment: Sendable {
        let stats: Task<BoundedTaskJoinOutcome<KimiSubscriptionStatsResponse?>, Never>
        let plan: Task<BoundedTaskJoinOutcome<KimiSubscriptionResponse?>, Never>

        init(
            authToken: String,
            region: KimiRegion,
            sessionInfo: SessionInfo?,
            transport: any ProviderHTTPTransport,
            grace: Duration,
            includePlan: Bool = true)
        {
            let deadline = ContinuousClock.now.advanced(by: grace)
            let statsTask = Task {
                try Task.checkCancellation()
                return try await KimiUsageFetcher.fetchUsageStats(
                    authToken: authToken,
                    region: region,
                    sessionInfo: sessionInfo,
                    transport: transport)
            }
            let planTask = Task<KimiSubscriptionResponse?, Error> {
                try Task.checkCancellation()
                guard includePlan else { return nil }
                return try await KimiUsageFetcher.fetchPlan(
                    authToken: authToken,
                    region: region,
                    sessionInfo: sessionInfo,
                    transport: transport)
            }
            self.stats = Task {
                await BoundedTaskJoin(sourceTask: statsTask)
                    .value(joinGrace: ContinuousClock.now.duration(to: deadline))
            }
            self.plan = Task {
                await BoundedTaskJoin(sourceTask: planTask).value(joinGrace: ContinuousClock.now.duration(to: deadline))
            }
        }

        func cancel() {
            self.stats.cancel()
            self.plan.cancel()
        }

        func value() async throws -> (stats: KimiSubscriptionStatsResponse?, plan: KimiSubscriptionResponse?) {
            let outcomes = await withTaskCancellationHandler {
                let stats = await self.stats.value
                let plan = await self.plan.value
                return (stats, plan)
            } onCancel: {
                self.cancel()
            }
            try Task.checkCancellation()
            return try (
                Self.optionalValue(outcomes.0, label: "subscription stats"),
                Self.optionalValue(outcomes.1, label: "plan"))
        }

        private static func optionalValue<Value: Sendable>(
            _ outcome: BoundedTaskJoinOutcome<Value?>,
            label: String) throws -> Value?
        {
            switch outcome {
            case let .value(value): return value
            case .timedOut:
                KimiUsageFetcher.log.warning("Kimi \(label) timed out")
                return nil
            case let .failure(error):
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    throw CancellationError()
                }
                KimiUsageFetcher.log.warning("Kimi \(label) unavailable: \(error.localizedDescription)")
                return nil
            }
        }
    }

    private static func fetchUsageStats(
        authToken: String,
        region: KimiRegion = .china,
        sessionInfo: SessionInfo?,
        transport: any ProviderHTTPTransport) async throws -> KimiSubscriptionStatsResponse?
    {
        var request = self.webRequest(
            url: region.webBaseURL
                .appendingPathComponent("apiv2/kimi.gateway.membership.v2.MembershipService/GetSubscriptionStats"),
            authToken: authToken,
            sessionInfo: sessionInfo)
        request.httpBody = Data("{}".utf8)

        let response = try await transport.response(for: request)
        guard response.statusCode == 200 else {
            Self.log.warning("Kimi subscription stats returned \(response.statusCode)")
            return nil
        }
        return try JSONDecoder().decode(KimiSubscriptionStatsResponse.self, from: response.data)
    }

    /// Kimi serves gift names in Chinese for unsupported languages; keep other UI languages on English.
    static func webLanguage(for locale: Locale) -> String {
        locale.language.languageCode?.identifier == "zh" ? "zh-CN" : "en-US"
    }

    private static func webRequest(url: URL, authToken: String, sessionInfo: SessionInfo?) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.setValue("kimi-auth=\(authToken)", forHTTPHeaderField: "Cookie")
        let origin = "https://\(url.host!)"
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.setValue("\(origin)/code/console", forHTTPHeaderField: "Referer")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
            "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("1", forHTTPHeaderField: "connect-protocol-version")
        request.setValue(Self.webLanguage(for: UsageFormatter.currentLocale()), forHTTPHeaderField: "x-language")
        request.setValue("web", forHTTPHeaderField: "x-msh-platform")
        request.setValue(TimeZone.current.identifier, forHTTPHeaderField: "r-timezone")

        request.setValue(sessionInfo?.deviceId, forHTTPHeaderField: "x-msh-device-id")
        request.setValue(sessionInfo?.sessionId, forHTTPHeaderField: "x-msh-session-id")
        request.setValue(sessionInfo?.trafficId, forHTTPHeaderField: "x-traffic-id")
        return request
    }

    static func codeAPIError(statusCode: Int) -> KimiAPIError {
        switch statusCode {
        case 400:
            .invalidRequest("Bad request")
        case 401:
            .invalidAPIKey
        case 403:
            .httpError(403)
        default:
            .httpError(statusCode)
        }
    }

    private static func decodeSessionInfo(from jwt: String) -> SessionInfo? {
        guard jwt.split(separator: ".", maxSplits: 2).count == 3,
              let json = UsageFetcher.parseJWT(jwt) else { return nil }

        return SessionInfo(
            deviceId: json["device_id"] as? String,
            sessionId: json["ssid"] as? String,
            trafficId: json["sub"] as? String)
    }

    private struct SessionInfo: Sendable {
        let deviceId: String?
        let sessionId: String?
        let trafficId: String?
    }
}
