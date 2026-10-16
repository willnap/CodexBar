import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct NativeOrbitOpenAICreditSemanticsTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test(arguments: [0.0, 20.0], Self.engines)
    func `OpenAI available balance without a positive grant total never fabricates a finite allowance`(
        available: Double, engine: ProviderPluginEngineKind) async throws
    {
        let snapshot = try await self.fetch(granted: 0, used: 0, available: available, engine: engine)
        #expect(snapshot.primary == nil)
        #expect(snapshot.measuredRateWindows.isEmpty)
        #expect(snapshot.providerCost?.balance == available)
        #expect(snapshot.providerCost?.balanceUpdatedAt == self.now)
        #expect(snapshot.providerCost?.used == 0)
        let gauge = NativeUsageGaugeProjection.state(provider: .openai, snapshot: snapshot)
        #expect(gauge.resolvedWindows.allSatisfy { $0.usedFraction == nil })
        let lights = NativeOrbitWarningSignals.account(
            provider: .openai, snapshot: snapshot, metrics: .empty, history: [], now: self.now)
        #expect(!lights.contains { [.limit, .credits, .billing].contains($0.kind) })
    }

    @Test(arguments: Self.engines)
    func `OpenAI genuine credit grant utilization stays measured but grant expiry is not a reset`(
        engine: ProviderPluginEngineKind) async throws
    {
        let snapshot = try await self.fetch(
            granted: 100, used: 30, available: 70, expiry: 1_893_456_000, engine: engine)
        #expect(snapshot.primary?.usedPercent == 30)
        #expect(snapshot.primary?.resetsAt == nil)
        #expect(snapshot.providerCost?.used == 30)
        #expect(snapshot.providerCost?.limit == 100)
        #expect(snapshot.providerCost?.balance == 70)
        #expect(snapshot.providerCost?.resetsAt == nil)
        #expect(snapshot.subscriptionRenewsAt == nil)
        #expect(snapshot.subscriptionExpiresAt == nil)
        #expect(snapshot.details.flatMap(\.rows).contains {
            $0.label == "Credit expiry" && $0.value.hasPrefix("2030-01-01")
        })
        let gauge = NativeUsageGaugeProjection.state(provider: .openai, snapshot: snapshot)
        let window = try #require(gauge.resolvedWindows.first { $0.usedFraction != nil })
        #expect(window.usedFraction == 0.3)
        #expect(window.countdown == nil)
    }

    @Test(arguments: Self.engines)
    func `passing OpenAI credit expiry never retires a genuine exhaustion reading as a renewed quota`(
        engine: ProviderPluginEngineKind) async throws
    {
        let expiry = self.now.addingTimeInterval(60)
        let snapshot = try await self.fetch(
            granted: 100, used: 100, available: 0, expiry: expiry.timeIntervalSince1970, engine: engine)
        for date in [self.now, expiry.addingTimeInterval(1)] {
            #expect(NativeOrbitWarningSignals.account(
                provider: .openai, snapshot: snapshot, metrics: .empty, history: [], now: date)
                .contains { $0.kind == .limit && $0.severity == .critical })
        }
        #expect(snapshot.primary?.resetsAt == nil)
        #expect(snapshot.providerCost?.resetsAt == nil)
    }

    private func fetch(
        granted: Double,
        used: Double,
        available: Double,
        expiry: Double? = nil,
        engine: ProviderPluginEngineKind) async throws -> UsageSnapshot
    {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "Sources/CodexBarCore/Resources/Plugins/openai.js"), encoding: .utf8)
        let grant = expiry.map { #"{"grant_amount":\#(granted),"used_amount":\#(used),"expires_at":\#($0)}"# }
        let billing = #"""
        {"total_granted":\#(granted),"total_used":\#(used),"total_available":\#(available),
         "grants":{"data":[\#(grant ?? "")]}}
        """#
        let runtime = try ProviderPluginRuntime(
            source: source,
            transport: ProviderHTTPTransportHandler { request in
                #expect(request.httpMethod == "GET")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
                let isBilling = request.url?.path == "/v1/dashboard/billing/credit_grants"
                #expect(isBilling || request.url?.path == "/v1/organization/costs")
                let body = isBilling ? billing : #"{"error":{"message":"fixture billing key"}}"#
                let url = try #require(request.url)
                let response = try #require(HTTPURLResponse(
                    url: url,
                    statusCode: isBilling ? 200 : 401,
                    httpVersion: nil,
                    headerFields: nil))
                return (Data(body.utf8), response)
            },
            engine: engine)
        return try await runtime.fetchUsage(
            settings: ["OPENAI_ALLOW_BALANCE_FALLBACK": "1"],
            secrets: ["OPENAI_API_KEY": "fixture-key"],
            now: self.now)
    }

    #if canImport(JavaScriptCore)
    private nonisolated static let engines: [ProviderPluginEngineKind] = [.quickJS, .javaScriptCore]
    #else
    private nonisolated static let engines: [ProviderPluginEngineKind] = [.quickJS]
    #endif
}
