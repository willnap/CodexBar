import Foundation
import Testing
@testable import CodexBarCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct CodexAccountUsageHistoryTests {
    @Test
    func `server dates and metadata remain civil dates without filling missing days`() throws {
        let history = try Self.decode(#"""
        {"metadata":{"stats_as_of":"2026-10-11","generated_at":"2026-10-11T18:44:58Z","stats_error":null},
         "stats":{"lifetime_tokens":123,"peak_daily_tokens":0,"daily_usage_buckets":[
           {"start_date":"2026-10-11","tokens":23},{"start_date":"2026-10-09","tokens":100}]}}
        """#)
        #expect(history.dailyUsageBuckets?.map(\.startDate) == ["2026-10-09", "2026-10-11"])
        #expect(history.dailyUsageBuckets?.map(\.tokens) == [100, 23])
        #expect(history.summary.lifetimeTokens == 123)
        #expect(history.summary.peakDailyTokens == 0)
        #expect(history.summary.currentStreakDays == nil)
        #expect(history.statsAsOf == "2026-10-11")
        #expect(history.generatedAt == "2026-10-11T18:44:58Z")
        #expect(history.coverageComplete == nil)
        #expect(!history.hasStatsError)
        let restored = try JSONDecoder().decode(
            CodexAccountUsageHistory.self, from: JSONEncoder().encode(history))
        #expect(restored == history)
    }

    @Test
    func `missing null and empty buckets preserve unavailable versus reported empty`() throws {
        #expect(try Self.decode(#"{"stats":{}}"#).dailyUsageBuckets == nil)
        #expect(try Self.decode(#"{"stats":{"daily_usage_buckets":null}}"#).dailyUsageBuckets == nil)
        #expect(try Self.decode(#"{"stats":{"daily_usage_buckets":[]}}"#).dailyUsageBuckets == [])
    }

    @Test(arguments: ["2026-02-29", "2026-04-31", "2026-1-01", "2026-01-01T00:00:00Z", "0000-01-01"])
    func `invalid civil dates cannot become token observations`(date: String) {
        #expect(throws: (any Error).self) {
            try Self.decode("{\"stats\":{\"daily_usage_buckets\":[{\"start_date\":\"\(date)\",\"tokens\":1}]}}")
        }
    }

    @Test
    func `Gregorian leap day remains an exact source date`() throws {
        let history = try Self.decode(
            #"{"stats":{"daily_usage_buckets":[{"start_date":"2024-02-29","tokens":0}]}}"#)
        #expect(history.dailyUsageBuckets?.first?.startDate == "2024-02-29")
        #expect(history.dailyUsageBuckets?.first?.tokens == 0)
    }

    @Test(arguments: ["-1", "1.5", "1e999", "null", "true", "\"12\"", "9223372036854775808"])
    func `invalid bucket counts cannot be rendered as measured tokens`(value: String) {
        #expect(throws: (any Error).self) {
            try Self
                .decode("{\"stats\":{\"daily_usage_buckets\":[{\"start_date\":\"2026-10-11\",\"tokens\":\(value)}]}}")
        }
    }

    @Test
    func `invalid summary counts and metadata watermarks are unavailable`() {
        #expect(throws: (any Error).self) { try Self.decode(#"{"stats":{"lifetime_tokens":-1}}"#) }
        #expect(throws: (any Error).self) {
            try Self.decode(#"{"metadata":{"stats_as_of":"2026-02-29"},"stats":{}}"#)
        }
        #expect(throws: (any Error).self) { try Self.decode(#"{}"#) }
    }

    @Test
    func `identical repeated dates deduplicate while conflicting totals reject the response`() throws {
        let history = try Self.decode(#"""
        {"stats":{"daily_usage_buckets":[
          {"start_date":"2026-10-11","tokens":12},{"start_date":"2026-10-11","tokens":12}]}}
        """#)
        #expect(history.dailyUsageBuckets?.count == 1)
        #expect(throws: (any Error).self) {
            try Self.decode(#"""
            {"stats":{"daily_usage_buckets":[
              {"start_date":"2026-10-11","tokens":12},{"start_date":"2026-10-11","tokens":13}]}}
            """#)
        }
    }

    @Test(arguments: [
        #"{"summary":{"lifetimeTokens":-1}}"#,
        #"{"summary":{},"dailyUsageBuckets":[{"startDate":"2026-02-29","tokens":1}]}"#,
        #"{"summary":{},"dailyUsageBuckets":[{"startDate":"2026-10-11","tokens":-1}]}"#,
        #"""
        {"summary":{},"dailyUsageBuckets":[
          {"startDate":"2026-10-11","tokens":1},{"startDate":"2026-10-11","tokens":2}]}
        """#,
    ])
    func `durable cache decoding rejects corrupt domain values`(json: String) {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(CodexAccountUsageHistory.self, from: Data(json.utf8))
        }
    }

    @Test(arguments: ["aggregation unavailable", ""])
    func `a reported source error stays visible and prevents healthy data adoption`(error: String) throws {
        let history = try Self.decode(
            "{\"metadata\":{\"stats_error\":\"\(error)\"},\"stats\":{\"lifetime_tokens\":12}}")
        #expect(history.statsError == error)
        #expect(history.hasStatsError)
        #expect(history.summary.lifetimeTokens == 12)
    }

    @Test
    func `profile request uses explicit account scope and refuses owner changes during response`() async throws {
        let owner = Self.credentials(email: "owner@example.com")
        let changedOwner = Self.credentials(email: "other@example.com")
        let source = CredentialSequence([owner, changedOwner])
        let transport = ProviderHTTPTransportStub { request in
            #expect(request.url?.absoluteString == "https://chatgpt.com/backend-api/wham/profiles/me")
            #expect(request.httpMethod == "GET")
            #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-access")
            #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "account-a")
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (Data(#"{"stats":{"lifetime_tokens":12}}"#.utf8), response)
        }
        await #expect(throws: (any Error).self) {
            try await CodexAccountUsageHistoryFetcher.fetchForNativeAccount(
                email: "owner@example.com",
                accountID: "account-a",
                credentialsLoader: { source.next() },
                transport: transport)
        }
        let stableSource = CredentialSequence([owner, owner])
        let history = try await CodexAccountUsageHistoryFetcher.fetchForNativeAccount(
            email: "owner@example.com",
            accountID: "account-a",
            credentialsLoader: { stableSource.next() },
            transport: transport)
        #expect(history.summary.lifetimeTokens == 12)
    }

    private static func decode(_ value: String) throws -> CodexAccountUsageHistory {
        try CodexAccountUsageHistory.decode(Data(value.utf8))
    }

    private static func credentials(email: String) -> CodexOAuthCredentials {
        let payload = Data("{\"email\":\"\(email)\"}".utf8).base64EncodedString()
        return CodexOAuthCredentials(
            accessToken: "test-access",
            refreshToken: "test-refresh",
            idToken: "header.\(payload).signature",
            accountId: "account-a",
            lastRefresh: Date(),
            expiresAt: Date().addingTimeInterval(3600),
            source: .codexHome,
            isAPIKey: false)
    }

    private final class CredentialSequence: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [CodexOAuthCredentials]
        init(_ values: [CodexOAuthCredentials]) { self.values = values }
        func next() -> CodexOAuthCredentials {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.values.count > 1 ? self.values.removeFirst() : self.values[0]
        }
    }
}
