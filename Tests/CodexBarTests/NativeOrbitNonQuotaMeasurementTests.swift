import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

/// Exercises the actual source boundary: calendars, resource occupancy and throughput are not account quotas.
@MainActor
struct NativeOrbitNonQuotaMeasurementTests {
    private let now = Date(timeIntervalSince1970: 1_800_014_400)

    @Test(arguments: [-60.0, 60.0], Self.engines)
    func `Zed unlimited predictions and billing calendar never become quota measurements`(
        secondsFromEnd: Double, engine: ProviderPluginEngineKind) async throws
    {
        let end = try #require(ISO8601DateFormatter().date(from: "2026-06-13T00:00:00Z"))
        let now = end.addingTimeInterval(secondsFromEnd)
        let snapshot = try await self.zed(engine: engine, now: now)
        self.expectNoQuota(snapshot, provider: .zed, now: now)
        #expect(snapshot.subscriptionRenewsAt == end)
        let rows = snapshot.details.flatMap(\.rows)
        #expect(rows.contains { $0.value == "Unlimited" })
        #expect(rows.contains { $0.value.contains("Cycle") })
        #expect(snapshot.subscriptionStatus != "past_due")
    }

    @Test(arguments: Self.engines)
    func `Zed finite prediction allowance stays measured without a calendar quota`(
        engine: ProviderPluginEngineKind) async throws
    {
        let snapshot = try await self.zed(engine: engine, limit: #"{"limited":20}"#)
        #expect(snapshot.primary?.usedPercent == 50)
        #expect(snapshot.primary?.resetDescription == "10 / 20 predictions")
        #expect(snapshot.secondary == nil)
        #expect(snapshot.measuredRateWindows.count == 1)
        #expect(!self.warnings(snapshot, provider: .zed, now: self.now).contains { $0.kind == .limit })
    }

    @Test(arguments: Self.engines)
    func `Zed overdue invoices produce a billing alarm without an exhausted quota`(
        engine: ProviderPluginEngineKind) async throws
    {
        let snapshot = try await self.zed(engine: engine, overdue: true)
        self.expectNoQuota(snapshot, provider: .zed, now: self.now)
        #expect(snapshot.subscriptionStatus == "past_due")
        #expect(self.warnings(snapshot, provider: .zed, now: self.now)
            .contains { $0.kind == .billing && $0.severity == .critical })
        #expect(snapshot.details.flatMap(\.rows).contains { $0.value == "Overdue invoices" })
    }

    @Test(arguments: Self.engines)
    func `Zed browser unlimited plan retains exact spend without inventing an allowance`(
        engine: ProviderPluginEngineKind) async throws
    {
        let body = Self.billing
            .replacingOccurrences(of: #""limit":100"#, with: #""limit":null"#)
            .replacingOccurrences(of: #""limit_in_cents":1000"#, with: #""limit_in_cents":null"#)
        let runtime = try self.runtime("zed", engine: engine, body: body)
        let snapshot = try await runtime.fetchUsage(
            settings: ["SOURCE": "web"],
            now: self.now,
            cookieResolver: { _, _ in "zed.session=fixture-session" })
        self.expectNoQuota(snapshot, provider: .zed, now: self.now)
        let rows = snapshot.details.flatMap(\.rows)
        #expect(rows.contains { $0.label == "Spent" && $0.usageValue == 2.5 })
        #expect(rows.contains { $0.value == "Unlimited" })
        #expect(snapshot.providerCost == nil)
    }

    @Test(arguments: [0, 40_000_000_000], Self.engines)
    func `llmman memory occupancy stays numeric detail even when completely full`(
        loadedBytes: Int, engine: ProviderPluginEngineKind) async throws
    {
        let body = #"{"memory":40000000000,"loaded":{"fixture/model":\#(loadedBytes)},"stored":{}}"#
        let runtime = try self.runtime("llmman", engine: engine, body: body)
        let snapshot = try await runtime.fetchUsage(
            settings: ["LLMMAN_HOST": "http://127.0.0.1:17434"], now: self.now)
        self.expectNoQuota(snapshot, provider: .llmman, now: self.now)
        let memory = try #require(snapshot.details.flatMap(\.rows).first { $0.label == "Memory" })
        #expect(memory.progress?.usedPercent == Double(loadedBytes) / 40_000_000_000 * 100)
        #expect(snapshot.details.flatMap(\.rows).contains { $0.label == "fixture/model" })
    }

    @Test(arguments: [0.0, 2.0])
    func `Groq observed throughput retains actual rate and never claims remaining capacity`(rate: Double) {
        let snapshot = GroqUsageSnapshot(
            requestRatePerSecond: rate,
            inputTokenRatePerSecond: 100,
            outputTokenRatePerSecond: 50,
            promptCacheHitRatePerSecond: 3,
            updatedAt: self.now).toUsageSnapshot()
        self.expectNoQuota(snapshot, provider: .groq, now: self.now)
        let values = snapshot.details.flatMap(\.rows).map(\.value)
        #expect(values.contains(rate == 0 ? "0.00 req/min" : "120 req/min"))
        #expect(values.contains("9000 tok/min"))
        #expect(values.contains("180 cache/min"))
        #expect(snapshot.identity?.providerID == .groq)
    }

    @Test
    func `Azure deployment validation retains deployment facts without a zero percent quota`() {
        let snapshot = AzureOpenAIUsageSnapshot(
            endpointHost: "example-resource.openai.azure.com",
            deploymentName: "chat-prod",
            model: "gpt-4o-mini",
            apiVersion: "2024-10-21",
            updatedAt: self.now).toUsageSnapshot()
        self.expectNoQuota(snapshot, provider: .azureopenai, now: self.now)
        let values = snapshot.details.flatMap(\.rows).map(\.value)
        #expect(values.contains("chat-prod"))
        #expect(values.contains("gpt-4o-mini"))
        #expect(snapshot.identity?.accountOrganization == "example-resource.openai.azure.com")
    }

    @Test(arguments: [false, true], Self.engines)
    func `DeepInfra never funded zero is not quota exhaustion and suspension is explicit billing evidence`(
        suspended: Bool, engine: ProviderPluginEngineKind) async throws
    {
        let runtime = try self.runtime(
            "deepinfra",
            engine: engine,
            body: #"{"stripe_balance":0,"recent":0,"suspended":\#(suspended)}"#,
            secondaryBody: #"{"months":[]}"#)
        let snapshot = try await runtime.fetchUsage(
            secrets: ["DEEPINFRA_API_KEY": "fixture-token"], now: self.now)
        self.expectNoQuota(snapshot, provider: .deepinfra, now: self.now)
        #expect(snapshot.providerCost?.balance == 0)
        #expect(snapshot.subscriptionStatus == (suspended ? "suspended" : nil))
        let warnings = self.warnings(snapshot, provider: .deepinfra, now: self.now)
        #expect(warnings.contains { $0.kind == .billing && $0.severity == .critical } == suspended)
        #expect(!warnings.contains { $0.kind == .credits })
        #expect(snapshot.details.flatMap(\.rows).contains { $0.value.contains("$0.00 available") })
    }

    @Test(arguments: Self.engines)
    func `LLMProxy retains genuine quota while request token and provider counts stay details`(
        engine: ProviderPluginEngineKind) async throws
    {
        let body = #"""
        {"providers":{
          "openai":{"credential_count":3,"active_count":2,"total_requests":120,
            "tokens":{"input_cached":1000,"input_uncached":2000,"output":3000},"approx_cost":12.5,
            "quota_groups":[{"remaining_percent":42,"reset_time":"2030-01-01T00:00:00Z"}]},
          "anthropic":{"credential_count":1,"active_count":1,"total_requests":40,
            "tokens":{"input_cached":0,"input_uncached":500,"output":500},"approx_cost":3}
        },"summary":{"total_requests":160,"total_tokens":7000,"approx_cost":15.5}}
        """#
        let runtime = try self.runtime("llmproxy", engine: engine, body: body)
        let snapshot = try await runtime.fetchUsage(
            settings: ["LLM_PROXY_BASE_URL": "https://proxy.example.com"],
            secrets: ["LLM_PROXY_API_KEY": "fixture-key"],
            now: self.now)
        #expect(snapshot.primary?.usedPercent == 58)
        #expect(snapshot.measuredRateWindows.count == 1)
        #expect(snapshot.secondary == nil)
        #expect(snapshot.tertiary == nil)
        #expect(snapshot.extraRateWindows?.isEmpty != false)
        let gauge = NativeUsageGaugeProjection.state(provider: .llmproxy, snapshot: snapshot)
        #expect(gauge.resolvedWindows.filter { $0.usedFraction != nil }.count == 1)
        let rows = snapshot.details.flatMap(\.rows)
        #expect(rows.contains { $0.label == "Requests" && $0.usageValue == 160 })
        #expect(rows.contains { $0.label == "Tokens" && $0.usageValue == 7000 })
        #expect(rows.contains { $0.label == "openai" && $0.value == "120 req · 6,000 tok · $12.50" })
        #expect(rows.contains { $0.label == "anthropic" && $0.value == "40 req · 1,000 tok · $3.00" })
        #expect(snapshot.providerCost?.used == 15.5)
    }

    private func expectNoQuota(_ snapshot: UsageSnapshot, provider: UsageProvider, now: Date) {
        #expect(snapshot.measuredRateWindows.isEmpty)
        let gauge = NativeUsageGaugeProjection.state(provider: provider, snapshot: snapshot)
        #expect(gauge.resolvedWindows.allSatisfy { $0.usedFraction == nil })
        let quotaKinds: Set<NativeOrbitWarningLight.Kind> = [
            .limit, .resetLate, .behindPace, .aheadOfPace, .farAheadPace, .allExhausted,
        ]
        #expect(!self.warnings(snapshot, provider: provider, now: now).contains { quotaKinds.contains($0.kind) })
    }

    private func warnings(_ snapshot: UsageSnapshot, provider: UsageProvider, now: Date) -> [NativeOrbitWarningLight] {
        NativeOrbitWarningSignals.account(
            provider: provider, snapshot: snapshot, metrics: .empty, history: [], now: now)
    }

    private func zed(
        engine: ProviderPluginEngineKind,
        now: Date? = nil,
        limit: String = #""unlimited""#,
        overdue: Bool = false) async throws -> UsageSnapshot
    {
        let body = """
        {"user":{"id":4242,"github_login":"octocat","name":"The Octocat"},
         "plan":{"plan_v3":"zed_pro",
         "subscription_period":{"started_at":"2026-05-13T00:00:00.000Z","ended_at":"2026-06-13T00:00:00.000Z"},
         "usage":{"edit_predictions":{"used":10,"limit":\(limit)}},"has_overdue_invoices":\(overdue)}}
        """
        return try await self.runtime("zed", engine: engine, body: body).fetchUsage(
            settings: ["API_URL": "https://cloud.zed.dev/client/users/me"],
            secrets: ["EDITOR_AUTH": "4242 fixture-token"],
            now: now ?? self.now,
            sourceMode: .api)
    }

    private func runtime(
        _ name: String,
        engine: ProviderPluginEngineKind,
        body: String,
        secondaryBody: String? = nil) throws -> ProviderPluginRuntime
    {
        // Read disk source, not a stale copied SwiftPM resource, so RED/GREEN observes the plugin edit itself.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "Sources/CodexBarCore/Resources/Plugins/\(name).js"), encoding: .utf8)
        return try ProviderPluginRuntime(
            source: source,
            transport: ProviderHTTPTransportHandler { request in
                let reply: String = switch request.url?.path {
                case "/api/version": #"{"version":"0.9.0"}"#
                case "/payment/usage": secondaryBody ?? body
                default: body
                }
                let url = try #require(request.url)
                let response = try #require(HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
                return (Data(reply.utf8), response)
            },
            engine: engine)
    }

    #if canImport(JavaScriptCore)
    private nonisolated static let engines: [ProviderPluginEngineKind] = [.quickJS, .javaScriptCore]
    #else
    private nonisolated static let engines: [ProviderPluginEngineKind] = [.quickJS]
    #endif

    private static let billing = #"""
    {"plan":"zed_pro","current_usage":{
      "token_spend":{"spend_in_cents":250,"limit_in_cents":1000},
      "edit_predictions":{"used":12,"limit":100}}}
    """#
}
