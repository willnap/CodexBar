import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct NativePluginAggregateProjectionTests {
    @Test(arguments: ["llmproxy", "clawrouter", "bifrost", "neuralwatt"], BundledPluginTestSupport.engines)
    func `reported aggregate counts retain source scope without fake daily buckets`(
        provider: String, engine: ProviderPluginEngineKind) async throws
    {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let body = switch provider {
        case "llmproxy": """
            {"summary":{"total_requests":7,"total_tokens":300,"approx_cost":5},"providers":{}}
            """
        case "clawrouter": """
            {"budget":{"configured":false,"ledger":"usage"},"usage":{"providers":[],
            "summary":{"requestCount":7,"successCount":7,"errorCount":0,"inputTokens":100,
            "outputTokens":200,"totalTokens":300,"actualCostMicros":5000000}}}
            """
        case "bifrost": """
            {"budgets":[{"id":"monthly","current_usage":5,"reset_duration":"1M","per_model_usage":[
            {"model":"first","total_tokens":100,"total_requests":3},
            {"model":"second","total_tokens":200,"total_requests":4}]}]}
            """
        default: """
            {"balance":{"credits_remaining_usd":20},
            "usage":{"current_month":{"requests":7,"tokens":300,"cost_usd":5}}}
            """
        }
        let usage = try await self.fetch(provider, body: body, engine: engine, now: now)
        let report = try #require(usage.costUsage)
        #expect(report.last30DaysTokens == 300)
        #expect(report.last30DaysRequests == 7)
        #expect(report.last30DaysCostUSD == 5)
        #expect(report.daily.isEmpty)
        #expect(report.sessionTokens == nil)
        #expect(report.sessionRequests == nil)
        #expect(report.historyCoverageIsEstablished == false)
        #expect(report.historyDays == (provider == "neuralwatt" ? 15 : 1))
        #expect(report.historyLabel != nil)
        #expect(report.updatedAt == now)
        #expect(report.costProvenance == (provider == "llmproxy" ? .listPriceEstimate : .vendorMetered))
    }

    @Test(arguments: ["llmproxy", "bifrost", "neuralwatt"], BundledPluginTestSupport.engines)
    func `missing aggregate counters remain unknown`(provider: String, engine: ProviderPluginEngineKind) async throws {
        let body = switch provider {
        case "llmproxy": #"{"summary":{"approx_cost":5},"providers":{}}"#
        case "bifrost": #"{"budgets":[{"id":"monthly","current_usage":5,"reset_duration":"1M"}]}"#
        default: #"{"balance":{"credits_remaining_usd":20},"usage":{"current_month":{"cost_usd":5}}}"#
        }
        let report = try #require(try await self.fetch(
            provider, body: body, engine: engine, now: Date(timeIntervalSince1970: 1_800_000_000)).costUsage)
        #expect(report.last30DaysTokens == nil)
        #expect(report.last30DaysRequests == nil)
        #expect(report.last30DaysCostUSD == 5)
        #expect(report.daily.isEmpty)
        if provider == "bifrost" {
            for missingTokens in [true, false] {
                let secondFields = missingTokens ? #""total_requests":4"# : #""total_tokens":200"#
                let mixed = """
                {"budgets":[{"id":"monthly","current_usage":5,"per_model_usage":[
                {"model":"first","total_tokens":100,"total_requests":3},{"model":"second",\(secondFields)}]}]}
                """
                let mixedReport = try #require(try await self.fetch(
                    provider, body: mixed, engine: engine, now: Date(timeIntervalSince1970: 1_800_000_000)).costUsage)
                let expectedTokens: Int? = missingTokens ? nil : 300
                let expectedRequests: Int? = missingTokens ? 7 : nil
                #expect(mixedReport.last30DaysTokens == expectedTokens)
                #expect(mixedReport.last30DaysRequests == expectedRequests)
                #expect(mixedReport.last30DaysCostUSD == 5)
            }
        }
    }

    private func fetch(
        _ provider: String, body: String, engine: ProviderPluginEngineKind, now: Date) async throws -> UsageSnapshot
    {
        let runtime = try BundledPluginTestSupport.runtime(
            provider, engine: engine, transport: ProviderHTTPTransportHandler { request in
                let url = try #require(request.url)
                return try (Data(body.utf8), #require(HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
            })
        return try await runtime.fetchUsage(
            settings: [
                "LLM_PROXY_BASE_URL": "https://proxy.test",
                "BIFROST_BASE_URL": "https://bifrost.test",
                "CLAWROUTER_BASE_URL": "https://clawrouter.test",
                "BASE_URL": "https://api.neuralwatt.test",
            ],
            secrets: [
                "LLM_PROXY_API_KEY": "fixture-key",
                "BIFROST_API_KEY": "fixture-key",
                "CLAWROUTER_API_KEY": "fixture-key",
                "NEURALWATT_API_KEY": "fixture-key",
            ],
            now: now)
    }
}
