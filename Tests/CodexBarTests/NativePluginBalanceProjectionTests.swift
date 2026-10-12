import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct NativePluginBalanceProjectionTests {
    @Test(arguments: ["zenmux", "neuralwatt", "xai", "xapi"], BundledPluginTestSupport.engines)
    func `plugin wallets preserve actual balances and do not invent spending`(
        provider: String, engine: ProviderPluginEngineKind) async throws
    {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let transport = ProviderHTTPTransportHandler { request in
            let url = try #require(request.url)
            let body: String = switch provider {
            case "zenmux": url.path.hasSuffix("/payg/balance")
                ? #"{"success":true,"data":{"currency":"usd","total_credits":12.34}}"#
                : ZenMuxPluginTests.subscription
            case "neuralwatt": """
                {"balance":{"credits_remaining_usd":12.34,"credits_used_usd":7.66,"total_credits_usd":20}}
                """
            case "xai": url.path.hasSuffix("/prepaid/balance")
                ? #"{"total":{"val":"-1234"}}"# : #"{"timeSeries":[]}"#
            default: url.path == "/api/me"
                ? #"{"account":{"id":"fixture-account"}}"#
                : #"{"credits":{"balance":10.34},"freeCredits":{"balance":2}}"#
            }
            return try (Data(body.utf8), #require(HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
        let runtime = try BundledPluginTestSupport.runtime(provider, engine: engine, transport: transport)
        let snapshot = try await runtime.fetchUsage(
            settings: ["INCLUDE_PAYG": "1", "XAI_TEAM_ID": "fixture-team", "BASE_URL": "https://api.neuralwatt.test"],
            secrets: [
                "ZENMUX_MANAGEMENT_API_KEY": "fixture-key",
                "NEURALWATT_API_KEY": "fixture-key",
                "XAI_MANAGEMENT_API_KEY": "fixture-key",
            ],
            now: now,
            cookieSessionResolver: { _, _ in
                .init(
                    header: "auth_token=synthetic; ct0=synthetic-csrf",
                    source: "Fixture",
                    origin: "https://console.x.com")
            })
        let cost = try #require(snapshot.providerCost)
        #expect(cost.balance == 12.34)
        #expect(cost.currencyCode == "USD")
        #expect(cost.balanceUpdatedAt == now)
        if provider == "neuralwatt" {
            #expect(cost.used == 7.66)
            #expect(cost.limit == 20)
            #expect(cost.usageIsUnavailable != true)
        } else {
            #expect(cost.usageIsUnavailable == true)
        }
    }

    @Test func `Neuralwatt wallet retains source observation time`() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let sourceTime = now.addingTimeInterval(-3600)
        let source = """
        {"snapshot_at":"\(ISO8601DateFormatter().string(from: sourceTime))",
        "balance":{"credits_remaining_usd":12.34}}
        """
        let snapshot = try await NeuralWattPluginTestSupport.fetch(Data(source.utf8), now: now)
        #expect(snapshot.providerCost?.balanceUpdatedAt == sourceTime)
        #expect(snapshot.providerCost?.usageIsUnavailable == true)
    }
}
