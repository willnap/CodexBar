import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct NativeOrbitMonetaryOriginTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func `a delayed wallet receipt projects from its measured instant`() {
        var metrics = NativeOrbitAccountMetrics.empty
        metrics.reportedBalance = self.balance(10, offset: -1800)
        let prior = self.balance(12, offset: -5400)
        let history = [self.history("balance", at: prior.updatedAt, observation: .init(balance: prior))]
        let projected = NativeOrbitMonetaryInspection.projectedMetrics(
            metrics: metrics, history: history, at: self.now.addingTimeInterval(1800), now: self.now)
        #expect(projected.reportedBalance?.value == 8)
        #expect(projected.reportedBalance?.isWorkspace == true)
        #expect(projected.reportedBalance?.unit == "EUR")
    }

    @Test func `a delayed spend receipt projects from its measured instant`() {
        var metrics = NativeOrbitAccountMetrics.empty
        metrics.reportedSpend = self.spend(40, offset: -1800)
        let prior = self.spend(30, offset: -5400)
        let history = [self.history("spend", at: prior.updatedAt, observation: .init(spend: prior))]
        let projected = NativeOrbitMonetaryInspection.projectedMetrics(
            metrics: metrics, history: history, at: self.now.addingTimeInterval(1800), now: self.now)
        #expect(projected.reportedSpend?.used == 50)
        #expect(projected.reportedSpend?.currencyCode == "EUR")
    }

    @Test func `a delayed funded wallet reaches zero at its actual projected depletion time`() {
        var metrics = NativeOrbitAccountMetrics.empty
        metrics.reportedBalance = self.balance(2, offset: -1800)
        let prior = self.balance(4, offset: -5400)
        let history = [self.history("balance", at: prior.updatedAt, observation: .init(balance: prior))]
        let projected = NativeOrbitMonetaryInspection.projectedMetrics(
            metrics: metrics, history: history, at: self.now.addingTimeInterval(1800), now: self.now)
        #expect(projected.reportedBalance?.value == 0)
    }

    @Test func `a future inspection never refreshes an already stale monetary receipt`() {
        var metrics = NativeOrbitAccountMetrics.empty
        metrics.reportedBalance = self.balance(10, offset: -7201)
        metrics.reportedSpend = self.spend(40, offset: -7201)
        let priorBalance = self.balance(12, offset: -10801)
        let priorSpend = self.spend(30, offset: -10801)
        let history = [
            self.history("balance", at: priorBalance.updatedAt, observation: .init(balance: priorBalance)),
            self.history("spend", at: priorSpend.updatedAt, observation: .init(spend: priorSpend)),
        ]
        let projected = NativeOrbitMonetaryInspection.projectedMetrics(
            metrics: metrics, history: history, at: self.now.addingTimeInterval(1800), now: self.now)
        #expect(projected.reportedBalance == nil)
        #expect(projected.reportedSpend == nil)
    }

    private func balance(_ value: Double, offset: TimeInterval) -> NativeOrbitReportedBalance {
        .init(value: value, unit: "EUR", isWorkspace: true, updatedAt: self.now.addingTimeInterval(offset))
    }

    private func spend(_ used: Double, offset: TimeInterval) -> ProviderCostSnapshot {
        .init(
            used: used,
            limit: 100,
            currencyCode: "EUR",
            period: "Monthly",
            resetsAt: self.now.addingTimeInterval(3600),
            updatedAt: self.now.addingTimeInterval(offset))
    }

    private func history(
        _ name: String, at date: Date, observation: NativeOrbitMetricObservation) -> PlanUtilizationSeriesHistory
    {
        .init(name: .init(rawValue: "nativeMetric:" + name), windowMinutes: 0, entries: [.init(
            capturedAt: date, usedPercent: 0, resetsAt: nil, nativeMetrics: observation)])
    }
}
