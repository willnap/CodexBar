import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct NativeOrbitMonetaryQuotaIdentityTests {
    @Test func `OpenAI API credit grants use their actual monetary quota`() {
        var metrics = NativeOrbitAccountMetrics.empty
        metrics.reportedSpend = .init(
            used: 30,
            limit: 100,
            currencyCode: "USD",
            balance: 70,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(NativeOrbitMonetaryInstrument.mode(
            provider: .openai,
            windows: [.init(id: "primary", label: "API credits", period: 1, used: 0.3)],
            metrics: metrics) == .budgetRemaining)
    }

    @Test(arguments: UsageProvider.allCases)
    func `an exhausted quota and a separate unused budget do not prove future charges`(provider: UsageProvider) {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var metrics = NativeOrbitAccountMetrics.empty
        metrics.reportedSpend = .init(used: 50, limit: 100, currencyCode: "USD", updatedAt: now)
        let snapshot = UsageSnapshot(
            primary: .init(
                usedPercent: 100,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(3600),
                resetDescription: nil),
            secondary: nil,
            updatedAt: now)
        let lights = NativeOrbitWarningSignals.account(
            provider: provider, snapshot: snapshot, metrics: metrics, history: [], now: now)
        #expect(!lights.contains { $0.kind == .spend })
        #expect(lights.contains { $0.kind == .limit && $0.severity == .critical })
    }

    @Test(arguments: [0.4, 0.5, 1.0])
    func `Zed prediction percentages never turn a separate token budget into the primary quota`(used: Double) {
        var metrics = NativeOrbitAccountMetrics.empty
        metrics.reportedSpend = .init(
            used: 50, limit: 100, currencyCode: "USD", updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let mode = NativeOrbitMonetaryInstrument.mode(
            provider: .zed,
            windows: [.init(id: "primary", label: "Edit predictions", period: 1, used: used)],
            metrics: metrics)
        #expect(mode == nil)
    }

    @Test func `an explicit monetary budget retains its money face without a provider allowlist`() {
        var metrics = NativeOrbitAccountMetrics.empty
        metrics.reportedSpend = .init(
            used: 50, limit: 100, currencyCode: "USD", updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let mode = NativeOrbitMonetaryInstrument.mode(
            provider: .zed,
            windows: [.init(id: "monetary-budget", label: "Budget", period: 1, used: 0.5)],
            metrics: metrics)
        #expect(mode == .budgetRemaining)
    }
}
