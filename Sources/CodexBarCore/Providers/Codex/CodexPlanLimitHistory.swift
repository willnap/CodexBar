import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Account-scoped historical allowance totals from the official Codex analytics service.
/// A period total is evidence at the period's end, not a curve of usage within that period.
public struct CodexPlanLimitHistory: Sendable, Equatable {
    public let dataAsOf: Date
    public let coverageStart: Date?
    public let coverageComplete: Bool
    public let approximate: Bool
    public let boundaryToleranceSeconds: Double?
    public let periods: [Period]

    public struct Period: Sendable, Equatable {
        public let id: String
        public let windowMinutes: Int
        public let startsAt: Date
        public let endsAt: Date
        public let accountingComplete: Bool
        public let usedPercent: Double?
    }

    public static func decode(_ data: Data) throws -> Self {
        let raw = try JSONDecoder().decode(Response.self, from: data)
        guard let dataAsOf = Self.date(raw.dataAsOf) else { throw CodexOAuthFetchError.invalidResponse }
        let periods = raw.periods.compactMap { element -> Period? in
            guard let value = element.value,
                  !value.id.isEmpty, [300, 10080].contains(value.windowMinutes),
                  let start = Self.date(value.startsAt), let end = Self.date(value.endsAt), start < end
            else { return nil }
            let percent = value.usedBasisPoints.map { $0 / 100 }
            if let percent, !percent.isFinite || percent < 0 { return nil }
            return Period(
                id: value.id,
                windowMinutes: value.windowMinutes,
                startsAt: start,
                endsAt: end,
                accountingComplete: value.accountingComplete ?? false,
                usedPercent: percent)
        }
        return Self(
            dataAsOf: dataAsOf,
            coverageStart: raw.coverageStart.flatMap(Self.date),
            coverageComplete: raw.coverageComplete ?? false,
            approximate: raw.approximate ?? true,
            boundaryToleranceSeconds: raw.boundaryToleranceSeconds,
            periods: periods)
    }

    /// Do not publish missing totals, future endpoints, or time beyond the server's accounting watermark.
    public func closedPeriods(now: Date) -> [Period] {
        self.periods.filter { $0.usedPercent != nil && $0.endsAt <= min(self.dataAsOf, now) }
    }

    private static func date(_ value: String) -> Date? {
        (try? Date(value, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
            ?? (try? Date(value, strategy: .iso8601))
    }

    private struct Response: Decodable {
        let dataAsOf: String
        let coverageStart: String?
        let coverageComplete: Bool?
        let approximate: Bool?
        let boundaryToleranceSeconds: Double?
        let periods: [LossyPeriod]

        enum CodingKeys: String, CodingKey {
            case dataAsOf = "data_as_of"
            case coverageStart = "coverage_start"
            case coverageComplete = "coverage_complete"
            case approximate
            case boundaryToleranceSeconds = "boundary_tolerance_seconds"
            case periods
        }
    }

    private struct RawPeriod: Decodable {
        let id: String
        let windowMinutes: Int
        let startsAt: String
        let endsAt: String
        let accountingComplete: Bool?
        let usedBasisPoints: Double?

        enum CodingKeys: String, CodingKey {
            case id
            case windowMinutes = "window_minutes"
            case startsAt = "starts_at"
            case endsAt = "ends_at"
            case accountingComplete = "accounting_complete"
            case usedBasisPoints = "used_basis_points"
        }
    }

    private struct LossyPeriod: Decodable {
        let value: RawPeriod?
        init(from decoder: any Decoder) throws { self.value = try? RawPeriod(from: decoder) }
    }
}

public enum CodexPlanLimitHistoryFetcher {
    public static func fetchForNativeAccount(
        email: String,
        accountID: String,
        env: [String: String]) async throws -> CodexPlanLimitHistory
    {
        let credentials = try CodexOAuthCredentialsStore.loadForUsage(env: env, allowExternalSources: false)
        guard self.credentialsMatchNativeOwner(credentials, email: email, accountID: accountID) else {
            throw CodexOAuthFetchError.invalidResponse
        }
        return try await self.fetch(accessToken: credentials.accessToken, accountID: accountID)
    }

    static func credentialsMatchNativeOwner(
        _ credentials: CodexOAuthCredentials,
        email: String,
        accountID: String) -> Bool
    {
        guard credentials.source == .codexHome, !credentials.isAPIKey, !credentials.needsRefresh,
              !credentials.accessToken.isEmpty,
              let owner = CodexNativeCredentialOwnerIdentity.normalizedEmail(fromIDToken: credentials.idToken),
              let expectedEmail = CodexIdentityResolver.normalizeEmail(email), owner == expectedEmail,
              let scope = CodexIdentityResolver.normalizeAccountID(credentials.accountId),
              let expectedScope = CodexIdentityResolver.normalizeAccountID(accountID), scope == expectedScope
        else { return false }
        return true
    }

    public static func fetch(accessToken: String, accountID: String, timeout: TimeInterval = 8) async throws
        -> CodexPlanLimitHistory
    {
        try await self.fetch(
            accessToken: accessToken,
            accountID: accountID,
            timeout: timeout,
            transport: CodexAuthenticatedHTTPTransport.current)
    }

    static func fetch(
        accessToken: String,
        accountID: String,
        timeout: TimeInterval = 8,
        transport: any ProviderHTTPTransport) async throws -> CodexPlanLimitHistory
    {
        guard !accessToken.isEmpty, !accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CodexOAuthFetchError.invalidResponse
        }
        let url = URL(string: "https://chatgpt.com/backend-api/wham/usage/plan_limit_history?days=30")!
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CodexBar", forHTTPHeaderField: "User-Agent")
        request.setValue("https://chatgpt.com/codex/cloud/settings/analytics", forHTTPHeaderField: "Referer")
        let data = try await CodexAuthenticatedHTTPTransport.perform(request: request, transport: transport)
        return try CodexPlanLimitHistory.decode(data)
    }
}
