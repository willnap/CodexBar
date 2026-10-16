import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct NativeOrbitOptionalAllowanceTests {
    private let now = Date(timeIntervalSince1970: 1_800_014_400)

    @Test(arguments: [UsageProvider.opencode, .opencodego])
    func `OpenCode renewal dates never become an additional measured allowance`(provider: UsageProvider) {
        let renewal = self.now.addingTimeInterval(86400)
        let snapshot: UsageSnapshot = if provider == .opencode {
            OpenCodeUsageSnapshot(
                rollingUsagePercent: 25,
                weeklyUsagePercent: 50,
                rollingResetInSec: 3600,
                weeklyResetInSec: 86400,
                renewsAt: renewal,
                updatedAt: self.now).toUsageSnapshot()
        } else {
            OpenCodeGoUsageSnapshot(
                hasMonthlyUsage: false,
                rollingUsagePercent: 25,
                weeklyUsagePercent: 50,
                monthlyUsagePercent: 0,
                rollingResetInSec: 3600,
                weeklyResetInSec: 86400,
                monthlyResetInSec: nil,
                renewsAt: renewal,
                updatedAt: self.now).toUsageSnapshot()
        }
        #expect(snapshot.extraRateWindows?.first { $0.id == "renewal" }?.usageKnown == false)
        #expect(snapshot.extraRateWindows?.first { $0.id == "renewal" }?.window.resetsAt == renewal)
        #expect(snapshot.measuredRateWindows.count == 2)
        let gauge = NativeUsageGaugeProjection.state(provider: provider, snapshot: snapshot)
        #expect(!gauge.resolvedWindows.contains { $0.id == "renewal" && $0.usedFraction != nil })
    }

    @Test(arguments: ["metadata", "base", "month"], Self.engines)
    func `T3 missing optional percentages remain unknown`(
        fields: String,
        engine: ProviderPluginEngineKind) async throws
    {
        let body = switch fields {
        case "base": #"{"usageFourHourPercentage":25}"#
        case "month": #"{"usageMonthPercentage":40}"#
        default: #"{"subscription":{"productName":"pro"},"usageBand":"base"}"#
        }
        let snapshot = try await self.runtime("t3chat", body: body, engine: engine)
            .fetchUsage(now: self.now, cookieResolver: { _, _ in "session=fixture" })
        #expect(snapshot.primary?.measured?.usedPercent == (fields == "base" ? 25 : nil))
        #expect(snapshot.secondary?.measured?.usedPercent == (fields == "month" ? 40 : nil))
        #expect(snapshot.measuredRateWindows.count == (fields == "metadata" ? 0 : 1))
    }

    @Test(arguments: Self.engines)
    func `T3 explicitly reported zero usage remains measured`(engine: ProviderPluginEngineKind) async throws {
        let snapshot = try await self.runtime(
            "t3chat", body: #"{"usageFourHourPercentage":0,"usageMonthPercentage":0}"#, engine: engine)
            .fetchUsage(now: self.now, cookieResolver: { _, _ in "session=fixture" })
        #expect(snapshot.measuredRateWindows.count == 2)
        #expect(snapshot.primary?.measured?.usedPercent == 0)
        #expect(snapshot.secondary?.measured?.usedPercent == 0)
    }

    @Test(arguments: [
        #"{"used_credit":250}"#,
        #"{"budget_cap":0,"used_credit":250}"#,
        #"{"budget_cap":1000}"#,
        #"{"budget_cap":1000,"used_credit":250,"is_unlimited":true}"#,
    ], Self.engines)
    func `ZoomMate missing allocation or explicit unlimited never means a full quota`(
        status: String, engine: ProviderPluginEngineKind) async throws
    {
        let snapshot = try await self.zoom(status, engine: engine)
        #expect(snapshot.measuredRateWindows.isEmpty)
        if status.contains("is_unlimited") {
            #expect(snapshot.details.flatMap(\.rows).contains { $0.value == "Unlimited" })
        }
    }

    @Test(arguments: [0, 250], Self.engines)
    func `ZoomMate actual positive allocations preserve zero and nonzero measured usage`(
        used: Int, engine: ProviderPluginEngineKind) async throws
    {
        let snapshot = try await self.zoom("{\"budget_cap\":1000,\"used_credit\":\(used)}", engine: engine)
        #expect(snapshot.primary?.measured?.usedPercent == Double(used) / 10)
        #expect(snapshot.measuredRateWindows.count == 1)
    }

    @Test func `Doubao invalid credentials with no request allocation never manufacture capacity`() {
        let snapshot = DoubaoUsageSnapshot(
            remainingRequests: 0, limitRequests: 0, resetTime: nil, updatedAt: self.now, apiKeyValid: false)
            .toUsageSnapshot()
        #expect(snapshot.measuredRateWindows.isEmpty)
        #expect(snapshot.identity?.providerID == .doubao)
    }

    @Test func `Doubao real request allocation remains measured`() {
        let snapshot = DoubaoUsageSnapshot(
            remainingRequests: 750, limitRequests: 1000, resetTime: nil, updatedAt: self.now, apiKeyValid: true)
            .toUsageSnapshot()
        #expect(snapshot.primary?.measured?.usedPercent == 25)
    }

    @Test(arguments: [-1, Int.min])
    func `Doubao malformed negative remaining counts never measure or overflow`(remaining: Int) {
        let snapshot = DoubaoUsageSnapshot(
            remainingRequests: remaining,
            limitRequests: 1000,
            resetTime: nil,
            updatedAt: self.now,
            apiKeyValid: true).toUsageSnapshot()
        #expect(snapshot.measuredRateWindows.isEmpty)
    }

    private func zoom(_ status: String, engine: ProviderPluginEngineKind) async throws -> UsageSnapshot {
        try await self.runtime("zoommate", body: "{\"data\":{\"credit_status\":\(status)}}", engine: engine)
            .fetchUsage(
                secrets: ["AUTHORIZATION": "fixture"],
                now: self.now,
                cookieSource: .manual,
                cookieSessionResolver: { _, _ in
                    .init(header: "session=fixture", source: "Fixture", origin: "https://ai.zoom.us")
                })
    }

    private func runtime(
        _ name: String, body: String, engine: ProviderPluginEngineKind) throws -> ProviderPluginRuntime
    {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "Sources/CodexBarCore/Resources/Plugins/\(name).js"), encoding: .utf8)
        return try ProviderPluginRuntime(
            source: source,
            transport: ProviderHTTPTransportHandler { request in
                let reply = request.url?.lastPathComponent == "history" ? #"{"data":{"records":[]}}"# : body
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
}
