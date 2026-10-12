import Foundation
import Testing
@testable import CodexBarCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct CodexPlanLimitHistoryTests {
    private static let response = #"""
    {
      "data_as_of":"2026-10-11T00:00:00Z","coverage_start":"2026-09-11T00:00:00Z",
      "coverage_complete":false,"approximate":true,"boundary_tolerance_seconds":60,
      "periods":[
        {"id":"weekly","window_minutes":10080,"starts_at":"2026-09-20T11:31:14.291000Z",
         "ends_at":"2026-09-26T17:08:46Z","accounting_complete":true,"used_basis_points":9977.20383},
        {"id":"overage","window_minutes":300,"starts_at":"2026-09-27T09:16:14.094000Z",
         "ends_at":"2026-09-27T14:16:14.094000Z","accounting_complete":false,"used_basis_points":10013.713234},
        {"id":"unavailable","window_minutes":10080,"starts_at":"2026-10-10T19:52:06.302000Z",
         "ends_at":"2026-10-17T19:52:06.302000Z","accounting_complete":false,"used_basis_points":null},
        {"id":"bad","window_minutes":10080,"starts_at":"invalid","ends_at":"2026-10-01T00:00:00Z",
         "used_basis_points":30}
      ]
    }
    """#

    @Test
    func `server history retains fractional percentages and incomplete accounting`() throws {
        let history = try CodexPlanLimitHistory.decode(Data(Self.response.utf8))
        #expect(history.periods.count == 3)
        #expect(history.periods[0].usedPercent == 99.7720383)
        #expect(abs((history.periods[1].usedPercent ?? 0) - 100.13713234) < 1e-9)
        #expect(history.periods[2].usedPercent == nil)
        #expect(history.coverageComplete == false)
        #expect(history.approximate == true)
        #expect(history.periods[0].accountingComplete == true)
        #expect(abs(history.periods[0].startsAt.timeIntervalSince1970 - 1_789_903_874.291) < 0.001)
    }

    @Test
    func `closed periods exclude missing totals and periods beyond the server watermark`() throws {
        let history = try CodexPlanLimitHistory.decode(Data(Self.response.utf8))
        let now = try Date("2026-10-11T12:00:00Z", strategy: .iso8601)
        #expect(history.closedPeriods(now: now).map(\.id) == ["weekly", "overage"])
        let earlier = try Date("2026-09-27T12:00:00Z", strategy: .iso8601)
        #expect(history.closedPeriods(now: earlier).map(\.id) == ["weekly"])
    }

    @Test
    func `historical requests use the fixed provider origin and explicit account scope`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            #expect(request.url?
                .absoluteString == "https://chatgpt.com/backend-api/wham/usage/plan_limit_history?days=30")
            #expect(request.httpMethod == "GET")
            #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-access")
            #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "test-account")
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil))
            return (Data(Self.response.utf8), response)
        }
        let history = try await CodexPlanLimitHistoryFetcher.fetch(
            accessToken: "test-access", accountID: "test-account", transport: transport)
        #expect(history.periods.count == 3)
    }

    @Test
    func `malformed history is unavailable instead of an empty recovered graph`() {
        #expect(throws: (any Error).self) {
            try CodexPlanLimitHistory.decode(Data(#"{"periods":"not an array"}"#.utf8))
        }
    }

    @Test
    func `native history rejects another owner another scope and external credentials`() throws {
        let payload = try JSONSerialization.data(withJSONObject: ["email": "owner@example.com"])
        let idToken = "header." + payload.base64EncodedString() + ".signature"
        func credentials(
            accountID: String = "account-a",
            source: CodexOAuthCredentialSource = .codexHome,
            isAPIKey: Bool = false) -> CodexOAuthCredentials
        {
            CodexOAuthCredentials(
                accessToken: "test-access",
                refreshToken: "test-refresh",
                idToken: idToken,
                accountId: accountID,
                lastRefresh: Date(),
                expiresAt: Date().addingTimeInterval(3600),
                source: source,
                isAPIKey: isAPIKey)
        }
        #expect(CodexPlanLimitHistoryFetcher.credentialsMatchNativeOwner(
            credentials(), email: "owner@example.com", accountID: "account-a"))
        #expect(!CodexPlanLimitHistoryFetcher.credentialsMatchNativeOwner(
            credentials(), email: "other@example.com", accountID: "account-a"))
        #expect(!CodexPlanLimitHistoryFetcher.credentialsMatchNativeOwner(
            credentials(), email: "owner@example.com", accountID: "account-b"))
        #expect(!CodexPlanLimitHistoryFetcher.credentialsMatchNativeOwner(
            credentials(source: .openCode), email: "owner@example.com", accountID: "account-a"))
        #expect(!CodexPlanLimitHistoryFetcher.credentialsMatchNativeOwner(
            credentials(isAPIKey: true), email: "owner@example.com", accountID: "account-a"))
    }
}
