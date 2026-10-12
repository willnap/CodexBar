import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct NativeAccountBalanceSourceTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func `Grok prepaid wallet is an observed balance without measured spending`() {
        let usage = GrokUsageSnapshot(
            billing: nil,
            webBilling: .init(
                usedPercent: nil,
                resetsAt: nil,
                prepaidBalanceUSD: 14.46),
            credentials: nil,
            localSummary: nil,
            cliVersion: nil,
            updatedAt: Self.now).toUsageSnapshot()
        #expect(usage.providerCost?.balance == 14.46)
        #expect(usage.providerCost?.balanceUpdatedAt == Self.now)
        #expect(usage.providerCost?.usageIsUnavailable == true)
        #expect(usage.providerCost?.currencyCode == "USD")
    }

    @Test(arguments: [750.0, 0, -2.5])
    func `Codebuff measured remaining credits retain their source units`(remaining: Double) {
        let usage = CodebuffUsageSnapshot(
            creditsRemaining: remaining,
            updatedAt: Self.now).toUsageSnapshot()
        #expect(usage.providerCost?.balance == remaining)
        #expect(usage.providerCost?.currencyCode == "Credits")
        #expect(usage.providerCost?.balanceUpdatedAt == Self.now)
        #expect(usage.providerCost?.usageIsUnavailable == true)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `OpenAI billing fallback preserves measured available balance independently of spent and granted`(
        engine: ProviderPluginEngineKind) async throws
    {
        let transport = ProviderHTTPTransportHandler { request in
            let fallback = request.url?.path
                .hasSuffix("credit_grants") == true
            let body = fallback
                ? #"{"total_granted":100,"total_used":90,"total_available":13.25,"grants":{"data":[]}}"#
                : #"{"error":{"message":"fixture billing key"}}"#
            return try Self.response(
                request,
                body: body,
                status: fallback ? 200 : 401)
        }
        let runtime = try BundledPluginTestSupport.runtime("openai", engine: engine, transport: transport)
        let snapshot = try await runtime.fetchUsage(
            settings: ["OPENAI_ALLOW_BALANCE_FALLBACK": "1"],
            secrets: ["OPENAI_API_KEY": "fixture-key"],
            now: Self.now)
        #expect(snapshot.providerCost?.balance == 13.25)
        #expect(snapshot.providerCost?.balanceUpdatedAt == Self.now)
        #expect(snapshot.providerCost?.currencyCode == "USD")
        #expect(snapshot.providerCost?.used == 90)
    }

    @Test(arguments: ["null", "0", "20"], BundledPluginTestSupport.engines)
    func `DeepInfra monthly spend and signed balance survive without a positive budget`(
        limit: String,
        engine: ProviderPluginEngineKind) async throws
    {
        let transport = ProviderHTTPTransportHandler { request in
            let checklist = request.url?.path == "/payment/checklist"
            let body = checklist
                ? "{\"stripe_balance\":-10,\"recent\":2,\"limit\":\(limit)}"
                : #"{"months":[{"period":"2026.10","total_cost":345}]}"#
            return try Self.response(
                request,
                body: body)
        }
        let runtime = try BundledPluginTestSupport.runtime("deepinfra", engine: engine, transport: transport)
        let snapshot = try await runtime.fetchUsage(
            secrets: ["DEEPINFRA_API_KEY": "fixture-key"],
            now: Self.now)
        #expect(snapshot.providerCost?.used == 3.45)
        #expect(snapshot.providerCost?.balance == 8)
        #expect(snapshot.providerCost?.currencyCode == "USD")
        #expect(snapshot.providerCost?.balanceUpdatedAt == Self.now)
    }

    private static func response(
        _ request: URLRequest,
        body: String,
        status: Int = 200) throws -> (Data, URLResponse)
    {
        let url = try #require(request.url)
        return try (Data(body.utf8), #require(HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil)))
    }
}
