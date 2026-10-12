import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Server-reported token activity for the authenticated Codex principal.
/// Civil bucket dates have no documented timezone. Missing dates do not establish zero usage.
public struct CodexAccountUsageHistory: Codable, Sendable, Equatable {
    public let summary: Summary
    public let dailyUsageBuckets: [DailyBucket]?
    public let statsAsOf: String?
    public let generatedAt: String?
    public let statsError: String?
    public let coverageComplete: Bool?

    /// Callers must preserve their last good snapshot when the service reports a statistics error.
    public var hasStatsError: Bool {
        self.statsError != nil
    }

    public struct Summary: Codable, Sendable, Equatable {
        public let lifetimeTokens: Int64?
        public let peakDailyTokens: Int64?
        public let longestRunningTurnSec: Int64?
        public let currentStreakDays: Int64?
        public let longestStreakDays: Int64?
    }

    public struct DailyBucket: Codable, Sendable, Equatable {
        public let startDate: String
        public let tokens: Int64
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            summary: container.decode(Summary.self, forKey: .summary),
            dailyUsageBuckets: container.decodeIfPresent([DailyBucket].self, forKey: .dailyUsageBuckets),
            statsAsOf: container.decodeIfPresent(String.self, forKey: .statsAsOf),
            generatedAt: container.decodeIfPresent(String.self, forKey: .generatedAt),
            statsError: container.decodeIfPresent(String.self, forKey: .statsError),
            coverageComplete: container.decodeIfPresent(Bool.self, forKey: .coverageComplete))
    }

    private enum CodingKeys: String, CodingKey {
        case summary, dailyUsageBuckets, statsAsOf, generatedAt, statsError, coverageComplete
    }

    public static func decode(_ data: Data) throws -> Self {
        let raw = try JSONDecoder().decode(Response.self, from: data)
        let stats = raw.stats
        return try Self(
            summary: Summary(
                lifetimeTokens: stats.lifetimeTokens,
                peakDailyTokens: stats.peakDailyTokens,
                longestRunningTurnSec: stats.longestRunningTurnSec,
                currentStreakDays: stats.currentStreakDays,
                longestStreakDays: stats.longestStreakDays),
            dailyUsageBuckets: stats.dailyUsageBuckets?.map {
                DailyBucket(startDate: $0.startDate, tokens: $0.tokens)
            },
            statsAsOf: raw.metadata?.statsAsOf,
            generatedAt: raw.metadata?.generatedAt,
            statsError: raw.metadata?.statsError,
            coverageComplete: raw.coverageComplete)
    }

    private init(
        summary: Summary,
        dailyUsageBuckets: [DailyBucket]?,
        statsAsOf: String?,
        generatedAt: String?,
        statsError: String?,
        coverageComplete: Bool?) throws
    {
        let counts = [
            summary.lifetimeTokens, summary.peakDailyTokens, summary.longestRunningTurnSec,
            summary.currentStreakDays, summary.longestStreakDays,
        ]
        guard counts.compactMap(\.self).allSatisfy({ $0 >= 0 }), statsAsOf.map(Self.isCivilDate) ?? true else {
            throw CodexOAuthFetchError.invalidResponse
        }
        var buckets: [DailyBucket]?
        if let dailyUsageBuckets {
            var byDate: [String: Int64] = [:]
            for bucket in dailyUsageBuckets {
                guard Self.isCivilDate(bucket.startDate), bucket.tokens >= 0 else {
                    throw CodexOAuthFetchError.invalidResponse
                }
                if let existing = byDate[bucket.startDate], existing != bucket.tokens {
                    throw CodexOAuthFetchError.invalidResponse
                }
                byDate[bucket.startDate] = bucket.tokens
            }
            buckets = byDate.map { DailyBucket(startDate: $0.key, tokens: $0.value) }
                .sorted { $0.startDate < $1.startDate }
        }
        self.summary = summary
        self.dailyUsageBuckets = buckets
        self.statsAsOf = statsAsOf
        self.generatedAt = generatedAt
        self.statsError = statsError
        self.coverageComplete = coverageComplete
    }

    private static func isCivilDate(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 10, bytes[4] == 45, bytes[7] == 45,
              [0, 1, 2, 3, 5, 6, 8, 9].allSatisfy({ (48...57).contains(bytes[$0]) }),
              let year = Int(value.prefix(4)), year > 0,
              let month = Int(value.dropFirst(5).prefix(2)), (1...12).contains(month),
              let day = Int(value.suffix(2)), day > 0
        else { return false }
        let leapYear = year.isMultiple(of: 400) || (year.isMultiple(of: 4) && !year.isMultiple(of: 100))
        let days = [31, leapYear ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return day <= days[month - 1]
    }

    private struct Response: Decodable {
        let stats: Stats
        let metadata: Metadata?
        let coverageComplete: Bool?
        enum CodingKeys: String, CodingKey {
            case stats, metadata
            case coverageComplete = "coverage_complete"
        }
    }

    private struct Stats: Decodable {
        let lifetimeTokens: Int64?
        let peakDailyTokens: Int64?
        let longestRunningTurnSec: Int64?
        let currentStreakDays: Int64?
        let longestStreakDays: Int64?
        let dailyUsageBuckets: [RawBucket]?
        enum CodingKeys: String, CodingKey {
            case lifetimeTokens = "lifetime_tokens"
            case peakDailyTokens = "peak_daily_tokens"
            case longestRunningTurnSec = "longest_running_turn_sec"
            case currentStreakDays = "current_streak_days"
            case longestStreakDays = "longest_streak_days"
            case dailyUsageBuckets = "daily_usage_buckets"
        }
    }

    private struct RawBucket: Decodable {
        let startDate: String
        let tokens: Int64
        enum CodingKeys: String, CodingKey {
            case startDate = "start_date"
            case tokens
        }
    }

    private struct Metadata: Decodable {
        let statsAsOf: String?
        let generatedAt: String?
        let statsError: String?
        enum CodingKeys: String, CodingKey {
            case statsAsOf = "stats_as_of"
            case generatedAt = "generated_at"
            case statsError = "stats_error"
        }
    }
}

public enum CodexAccountUsageHistoryFetcher {
    public static func fetchForNativeAccount(
        email: String,
        accountID: String,
        env: [String: String]) async throws -> CodexAccountUsageHistory
    {
        try await self.fetchForNativeAccount(
            email: email,
            accountID: accountID,
            credentialsLoader: {
                try CodexOAuthCredentialsStore.loadForUsage(env: env, allowExternalSources: false)
            },
            transport: CodexAuthenticatedHTTPTransport.current)
    }

    static func fetchForNativeAccount(
        email: String,
        accountID: String,
        credentialsLoader: @Sendable () throws -> CodexOAuthCredentials,
        transport: any ProviderHTTPTransport) async throws -> CodexAccountUsageHistory
    {
        let credentials = try credentialsLoader()
        guard CodexPlanLimitHistoryFetcher.credentialsMatchNativeOwner(
            credentials, email: email, accountID: accountID)
        else { throw CodexOAuthFetchError.invalidResponse }
        let history = try await self.fetch(
            accessToken: credentials.accessToken, accountID: accountID, transport: transport)
        let currentCredentials = try credentialsLoader()
        guard CodexPlanLimitHistoryFetcher.credentialsMatchNativeOwner(
            currentCredentials, email: email, accountID: accountID),
            currentCredentials.idToken == credentials.idToken
        else { throw CodexOAuthFetchError.invalidResponse }
        return history
    }

    /// The caller owns freezing and revalidating the requesting account before publishing this result.
    public static func fetch(
        accessToken: String,
        accountID: String,
        timeout: TimeInterval = 8) async throws -> CodexAccountUsageHistory
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
        transport: any ProviderHTTPTransport) async throws -> CodexAccountUsageHistory
    {
        guard !accessToken.isEmpty, !accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CodexOAuthFetchError.invalidResponse
        }
        let url = URL(string: "https://chatgpt.com/backend-api/wham/profiles/me")!
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CodexBar", forHTTPHeaderField: "User-Agent")
        let data = try await CodexAuthenticatedHTTPTransport.perform(request: request, transport: transport)
        return try CodexAccountUsageHistory.decode(data)
    }
}
