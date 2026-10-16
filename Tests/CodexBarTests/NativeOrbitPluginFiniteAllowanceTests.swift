import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct NativeOrbitPluginFiniteAllowanceTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test(arguments: [0, 100], Self.engines)
    func `Perplexity omits unallocated pools while retaining measured recurring credit usage`(
        total: Int, engine: ProviderPluginEngineKind) async throws
    {
        let body = #"""
        {"balance_cents":75,"renewal_date_ts":1893456000,"current_period_purchased_cents":0,
         "credit_grants":[{"type":"recurring","amount_cents":\#(total)}],"total_usage_cents":\#(total / 4)}
        """#
        let usage = try await self.fetch("perplexity", body: body, engine: engine)
        #expect(usage.primary?.usedPercent == (total > 0 ? 25 : nil))
        #expect(usage.secondary == nil)
        #expect(usage.tertiary == nil)
        if total == 0 { self.expectNoQuota(usage, provider: .perplexity) }
    }

    @Test(arguments: [0, 100], Self.engines)
    func `Qoder zero totals without a reported percentage are unknown and positive totals remain measured`(
        total: Int, engine: ProviderPluginEngineKind) async throws
    {
        let body = #"""
        {"totalQuota":{"quotaSummary":{"usedValue":\#(total / 4),"limitValue":\#(total),
          "remainingValue":\#(total * 3 / 4)}},"nextResetAt":"2030-01-01T00:00:00Z"}
        """#
        let usage = try await self.fetch("qoder", body: body, engine: engine)
        #expect(usage.primary?.usedPercent == (total > 0 ? 25 : nil))
        if total == 0 {
            self.expectNoQuota(usage, provider: .qoder)
            #expect(usage.details.flatMap(\.rows).contains { $0.value == "0 / 0 credits" })
        }
        let explicit = body.replacingOccurrences(of: #""usedValue":"#, with: #""usagePercentage":37,"usedValue":"#)
        let reported = try await self.fetch("qoder", body: explicit, engine: engine)
        #expect(reported.primary?.usedPercent == 37)
    }

    @Test(arguments: [0, 100], Self.engines)
    func `xKiro free token progress needs a positive daily allowance`(
        total: Int, engine: ProviderPluginEngineKind) async throws
    {
        let body = #"""
        {"object":"usage","free_tokens":{"used_today":\#(total / 4),"limit_per_day":\#(total),
          "remaining":\#(total * 3 / 4)}}
        """#
        let usage = try await self.fetch("xkiro", body: body, engine: engine)
        #expect(usage.primary?.usedPercent == (total > 0 ? 25 : nil))
        #expect(usage.details.flatMap(\.rows).contains { $0.label == "Daily allowance" && $0.value == String(total) })
        if total == 0 { self.expectNoQuota(usage, provider: .xkiro) }
    }

    @Test(arguments: [0, 100], Self.engines)
    func `Neuralwatt blocking is distinct from capacity while positive measured allowances remain quotas`(
        total: Int, engine: ProviderPluginEngineKind) async throws
    {
        let body = #"""
        {"balance":{"credits_remaining_usd":0,"credits_used_usd":0},
         "subscription":{"kwh_included":\#(total),"kwh_used":\#(total / 4),"kwh_remaining":\#(total * 3 / 4)},
         "key":{"allowance":{"limit_usd":\#(total),"spent_usd":\#(total / 4),"blocked":true}}}
        """#
        let usage = try await self.fetch("neuralwatt", body: body, engine: engine)
        #expect(usage.primary?.usedPercent == (total > 0 ? 25 : nil))
        #expect(usage.extraRateWindows?.first?.window.usedPercent == (total > 0 ? 25 : nil))
        #expect(usage.details.flatMap(\.rows).contains { $0.label == "Key access" && $0.value == "Blocked" })
        if total == 0 { self.expectNoQuota(usage, provider: .neuralwatt) }
    }

    @Test(arguments: [0, 100], Self.engines)
    func `v0 billing and rate limits require positive denominators without guessing a currency`(
        total: Int, engine: ProviderPluginEngineKind) async throws
    {
        for type in ["legacy", "token"] {
            let data = type == "legacy"
                ? #"{"limit":\#(total),"remaining":\#(total * 3 / 4)}"#
                : #"{"balance":{"total":\#(total),"remaining":\#(total * 3 / 4)},"billingCycle":{"end":1893456000}}"#
            let body = #"{"billingType":"\#(type)","data":\#(data)}"#
            let rate = #"{"limit":\#(total),"remaining":\#(total * 3 / 4),"reset":1893456000}"#
            let usage = try await self.fetch("v0", body: body, secondaryBody: rate, engine: engine)
            #expect(usage.primary?.usedPercent == (total > 0 ? 25 : nil))
            #expect(usage.secondary?.usedPercent == (total > 0 ? 25 : nil))
            #expect(usage.providerCost == nil)
            #expect(usage.details.flatMap(\.rows).contains { $0.label == "Billing remaining" })
            if total == 0 { self.expectNoQuota(usage, provider: .v0) }
        }
    }

    @Test(arguments: [0, 100], Self.engines)
    func `Venice balance and access are separate from a positive DIEM allocation`(
        total: Int, engine: ProviderPluginEngineKind) async throws
    {
        let body = #"""
        {"canConsume":true,"consumptionCurrency":"DIEM","balances":{"diem":\#(total * 3 / 4),"usd":null},
         "diemEpochAllocation":\#(total)}
        """#
        let usage = try await self.fetch("venice", body: body, engine: engine)
        #expect(usage.primary?.usedPercent == (total > 0 ? 25 : nil))
        if total == 0 { self.expectNoQuota(usage, provider: .venice) }
        let blocked = try await self.fetch(
            "venice",
            body: #"{"canConsume":false,"consumptionCurrency":"USD","balances":{"usd":12,"diem":null}}"#,
            engine: engine)
        self.expectNoQuota(blocked, provider: .venice)
        #expect(blocked.details.flatMap(\.rows).contains { $0.label == "API access" && $0.value == "Unavailable" })
        #expect(blocked.providerCost?.balance == 12)
    }

    private func expectNoQuota(_ usage: UsageSnapshot, provider: UsageProvider) {
        #expect(usage.measuredRateWindows.isEmpty)
        #expect(NativeUsageGaugeProjection.state(provider: provider, snapshot: usage)
            .resolvedWindows.allSatisfy { $0.usedFraction == nil })
        #expect(!NativeOrbitWarningSignals.account(
            provider: provider, snapshot: usage, metrics: .empty, history: [], now: self.now)
            .contains { [.limit, .resetLate, .allExhausted].contains($0.kind) })
    }

    private func fetch(
        _ name: String,
        body: String,
        secondaryBody: String? = nil,
        engine: ProviderPluginEngineKind) async throws -> UsageSnapshot
    {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "Sources/CodexBarCore/Resources/Plugins/\(name).js"), encoding: .utf8)
        let runtime = try ProviderPluginRuntime(
            source: source,
            transport: ProviderHTTPTransportHandler { request in
                let reply = request.url?.path == "/v1/rate-limits" ? secondaryBody ?? body : body
                let url = try #require(request.url)
                return try (Data(reply.utf8), #require(HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
            },
            engine: engine)
        return try await runtime.fetchUsage(
            settings: ["BASE_URL": "https://neuralwatt.example"],
            secrets: [
                "XKIRO_API_KEY": "fixture-key",
                "NEURALWATT_API_KEY": "fixture-key",
                "V0_API_KEY": "fixture-key",
                "VENICE_API_KEY": "fixture-key",
            ],
            now: self.now,
            cookieSource: .manual,
            cookieResolver: { _, _ in "authjs.session-token=fixture" })
    }

    #if canImport(JavaScriptCore)
    private nonisolated static let engines: [ProviderPluginEngineKind] = [.quickJS, .javaScriptCore]
    #else
    private nonisolated static let engines: [ProviderPluginEngineKind] = [.quickJS]
    #endif
}
