import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct NativeOrbitWarningAuditTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func `a model's own weekly limit is named and the largest gap from pace is the one shown`() {
        let main = RateWindow(
            usedPercent: 3,
            windowMinutes: 10080,
            resetsAt: self.now.addingTimeInterval(6 * 86400),
            resetDescription: nil)
        let scoped = RateWindow(
            usedPercent: 0.5,
            windowMinutes: 10080,
            resetsAt: self.now.addingTimeInterval(4 * 86400),
            resetDescription: nil)
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: main,
            extraRateWindows: [.init(id: "claude-weekly-scoped-fable", title: "Fable only", window: scoped)],
            updatedAt: self.now)
        let lights = self.lights(snapshot)
        let behind = lights.filter { $0.kind == .behindPace }
        #expect(behind.count == 1)
        // 3 % of a window 14 % through is 11 points behind; 0.5 % of one 43 % through is 42 behind.
        #expect(behind.first?.detail
            == "Weekly limit (Fable only) on pace to have some left over: under 1% used, 43% of the week gone.")
        #expect(NativeOrbitWarningSignals.paceDetail(
            .aheadOfPace, title: "Session limit", used: 33.4, elapsed: 4, minutes: 300)
            == "Session limit on pace to run out early: 33% used, 4% of the session gone.")
    }

    @Test func `a window's first minutes light no pace or fuel from a single request`() {
        let started = RateWindow(
            usedPercent: 1,
            windowMinutes: 10080,
            resetsAt: self.now.addingTimeInterval(7 * 86400 - 240),
            resetDescription: nil)
        #expect(self.lights(UsageSnapshot(primary: nil, secondary: started, updatedAt: self.now)).isEmpty)
    }

    @Test func `a Codex usage refresh leaves balance history to the credits read`() {
        let cost = ProviderCostSnapshot(
            used: 0,
            limit: 100,
            currencyCode: CodexExtraUsageCost.currencyCode,
            balanceUpdatedAt: self.now,
            updatedAt: self.now)
        let snapshot = UsageSnapshot(primary: nil, secondary: nil, providerCost: cost, updatedAt: self.now)
        func balanceSamples(_ provider: UsageProvider) -> Int {
            UsageStore.nativeOrbitMetricSamples(provider: provider, snapshot: snapshot)
                .count { $0.name.rawValue == "nativeMetric:balance" }
        }
        #expect(balanceSamples(.codex) == 0)
        #expect(balanceSamples(.claude) == 1)
    }

    @Test func `a saved reset added this morning stays news for the day`() {
        let added = self.now.addingTimeInterval(-6 * 3600)
        func inventory(_ count: Int, at date: Date) -> PlanUtilizationHistoryEntry {
            .init(capturedAt: date, usedPercent: 0, resetsAt: nil, nativeMetrics: .init(resets: .init(
                availableExpirations: Array(repeating: self.now.addingTimeInterval(30 * 86400), count: count),
                usedExpirations: nil,
                redeemedDates: nil)))
        }
        let history = [PlanUtilizationSeriesHistory(name: "nativeMetric:resets", windowMinutes: 0, entries: [
            inventory(1, at: added.addingTimeInterval(-3600)),
            inventory(2, at: added),
            inventory(2, at: self.now.addingTimeInterval(-600)),
        ])]
        var metrics = NativeOrbitAccountMetrics.empty
        metrics.resetInventoryObservedAt = self.now
        metrics.bankedResets = 2
        let lights = NativeOrbitWarningSignals.account(
            provider: .codex, snapshot: nil, metrics: metrics, history: history, now: self.now)
        #expect(lights.contains { $0.kind == .newSavedReset })
        let nextDay = NativeOrbitWarningSignals.account(
            provider: .codex,
            snapshot: nil,
            metrics: metrics,
            history: history,
            now: added.addingTimeInterval(86400 + 60))
        #expect(!nextDay.contains { $0.kind == .newSavedReset })
    }

    @Test func `Kimi's monthly pool renewal is not a plan ending`() {
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            subscriptionExpiresAt: self.now.addingTimeInterval(2 * 86400),
            updatedAt: self.now)
        #expect(NativeOrbitAccountMetrics.make(
            provider: .kimi, snapshot: snapshot, usage: nil, now: self.now).reportedPlanExpiry == nil)
        #expect(NativeOrbitAccountMetrics.make(
            provider: .claude, snapshot: snapshot, usage: nil, now: self.now).reportedPlanExpiry != nil)
    }

    private func lights(_ snapshot: UsageSnapshot) -> [NativeOrbitWarningLight] {
        NativeOrbitWarningSignals.account(
            provider: .claude, snapshot: snapshot, metrics: .empty, history: [], now: self.now)
    }
}
