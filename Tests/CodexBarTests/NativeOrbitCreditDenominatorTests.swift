import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct NativeOrbitCreditDenominatorTests {
    @Test(arguments: ["abacus", "elevenlabs"], BundledPluginTestSupport.engines)
    func `an absent credit allocation cannot establish a full allowance`(
        provider: String, engine: ProviderPluginEngineKind) async throws
    {
        for used in [0, 25] {
            let snapshot = try await self.fetch(provider, total: 0, used: used, engine: engine)
            #expect(snapshot.measuredRateWindows.isEmpty)
            let id = try #require(UsageProvider(rawValue: provider))
            #expect(NativeUsageGaugeProjection.state(provider: id, snapshot: snapshot)
                .resolvedWindows.allSatisfy { $0.usedFraction == nil })
            #expect(!NativeOrbitWarningSignals.account(
                provider: id, snapshot: snapshot, metrics: .empty, history: [], now: snapshot.updatedAt)
                .contains { [.limit, .aheadOfPace, .behindPace, .farAheadPace].contains($0.kind) })
            #expect(!snapshot.details.isEmpty)
        }
    }

    @Test(arguments: ["abacus", "elevenlabs"], BundledPluginTestSupport.engines)
    func `a positive credit allocation retains its real percentage`(
        provider: String, engine: ProviderPluginEngineKind) async throws
    {
        let snapshot = try await self.fetch(provider, total: 100, used: 25, engine: engine)
        #expect(snapshot.measuredRateWindows.first?.usedPercent == 25)
    }

    private func fetch(
        _ provider: String, total: Int, used: Int, engine: ProviderPluginEngineKind) async throws -> UsageSnapshot
    {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/CodexBarCore/Resources/Plugins/\(provider).js"),
            encoding: .utf8)
        let runtime = try ProviderPluginRuntime(
            source: source,
            transport: ProviderHTTPTransportHandler { request in
                let url = try #require(request.url)
                let body: String = if provider == "abacus" {
                    url.path.hasSuffix("_getBillingInfo")
                        ? #"{"success":true,"result":{"currentTier":"Fixture"}}"#
                        : "{\"success\":true,\"result\":{\"totalComputePoints\":\(total),"
                        + "\"computePointsLeft\":\(total - used)}}"
                } else {
                    "{\"character_count\":\(used),\"character_limit\":\(total),\"tier\":\"fixture\"}"
                }
                let response = try #require(HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
                return (Data(body.utf8), response)
            }, engine: engine)
        return try await runtime.fetchUsage(
            settings: ["BASE_URL": "https://api.elevenlabs.io/v1/user/subscription"],
            secrets: ["ELEVENLABS_API_KEY": "fixture"],
            now: Date(timeIntervalSince1970: 1_800_000_000),
            cookieResolver: { _, _ in "fixture=session" })
    }
}
