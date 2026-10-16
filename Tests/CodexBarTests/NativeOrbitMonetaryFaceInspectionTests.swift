import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct NativeOrbitMonetaryFaceInspectionTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var past: Date {
        self.now.addingTimeInterval(-300)
    }

    @Test func `a current wallet face yields to an actually recorded past quota`() {
        let history = [PlanUtilizationSeriesHistory(name: "nativeQuota:primary", windowMinutes: 300, entries: [.init(
            capturedAt: self.past, usedPercent: 50, resetsAt: self.now.addingTimeInterval(3600))])]
        var account = self.account(windows: [self.unknown()], history: history)
        account.metrics.reportedBalance = .init(value: 10, unit: "USD", isWorkspace: false, updatedAt: self.now)
        let inspected = NativeOrbitHistoricalInspection.windows(
            account: account, date: self.past, now: self.now, days: 1)
        #expect(inspected.contains { $0.id == "primary" && $0.usedFraction == 0.5 })
        #expect(NativeOrbitMonetaryInstrument.mode(
            account: account, windows: inspected, date: self.past, now: self.now, projection: nil) == nil)
    }

    @Test func `a current quota face restores an actually recorded past wallet`() {
        let balance = NativeOrbitReportedBalance(
            value: 20, unit: "EUR", isWorkspace: true, updatedAt: self.past)
        let history = [PlanUtilizationSeriesHistory(name: "nativeMetric:balance", windowMinutes: 0, entries: [.init(
            capturedAt: self.past, usedPercent: 0, resetsAt: nil, nativeMetrics: .init(balance: balance))])]
        var account = self.account(windows: [self.quota()], history: history)
        // A newer optional spend cap cannot replace the earlier wallet receipt.
        account.metrics.reportedSpend = self.budget()
        let inspected = NativeOrbitHistoricalInspection.windows(
            account: account, date: self.past, now: self.now, days: 1)
        #expect(inspected.allSatisfy { $0.usedFraction == nil })
        #expect(NativeOrbitMonetaryInstrument.mode(
            account: account, windows: inspected, date: self.past, now: self.now, projection: nil) == .balance)
    }

    @Test(arguments: [false, true])
    func `unknown future subscription quotas never promote optional overage to a money face`(hasProjection: Bool) {
        var account = self.account(windows: [self.quota()])
        account.metrics.reportedSpend = self.budget()
        let projection = hasProjection ? self.projection(metrics: account.metrics) : nil
        let future = self.now.addingTimeInterval(300)
        let inspected = NativeOrbitHistoricalInspection.windows(
            account: account, date: future, now: self.now, days: 1, projection: projection)
        #expect(inspected.allSatisfy { $0.usedFraction == nil })
        #expect(NativeOrbitMonetaryInstrument.mode(
            account: account, windows: inspected, date: future, now: self.now, projection: projection) == nil)
    }

    @Test func `a real budget face retains its monetary identity during future inspection`() {
        let window = UsageWindow(id: "monetary-budget", label: "Budget", period: 1, used: 40, limit: 100, unit: "USD")
        var account = self.account(windows: [window])
        account.metrics.reportedSpend = self.budget()
        let projection = self.projection(metrics: account.metrics)
        let future = self.now.addingTimeInterval(300)
        let inspected = NativeOrbitHistoricalInspection.windows(
            account: account, date: future, now: self.now, days: 1, projection: projection)
        #expect(inspected.allSatisfy { $0.usedFraction == nil })
        #expect(NativeOrbitMonetaryInstrument.mode(
            account: account, windows: inspected, date: future, now: self.now, projection: projection) ==
            .budgetRemaining)
    }

    private func unknown() -> UsageWindow {
        .init(id: "unknown", label: "Usage", period: 1, used: nil, recovery: .none)
    }

    private func quota() -> UsageWindow {
        .init(id: "primary", label: "Session", period: 18000, used: 0.5)
    }

    private func budget() -> ProviderCostSnapshot {
        .init(used: 40, limit: 100, currencyCode: "USD", period: "Monthly", updatedAt: self.now)
    }

    private func account(
        windows: [UsageWindow], history: [PlanUtilizationSeriesHistory] = []) -> NativeOrbitAccountPresentation
    {
        var gauge = ComputeGauge.State()
        gauge.provider = "claude"
        gauge.windows = windows
        return .init(
            id: "fixture",
            label: "Fixture",
            email: nil,
            symbol: "person",
            isActive: true,
            canActivate: false,
            gauge: gauge,
            updatedAt: self.now,
            history: history,
            odometer: nil,
            odometerHelp: nil,
            statusText: nil,
            selection: .none)
    }

    private func projection(metrics: NativeOrbitAccountMetrics) -> NativeOrbitAccountProjection {
        .init(
            now: self.now,
            end: self.now.addingTimeInterval(86400),
            lastActivity: nil,
            lanes: [],
            events: [],
            tokenRate: nil,
            costRate: nil,
            periodSummary: .init(),
            resetInventory: nil,
            liveMetrics: metrics)
    }
}
