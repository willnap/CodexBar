import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct NativeOrbitTemporalWarningTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func `cached usage lights clear when the displayed allowance is empty`() {
        var account = self.account(used: 0)
        account.warnings = [.init(.limit, .critical, "Old exhaustion."), .init(.farAheadPace, .caution, "Old pace.")]
        #expect(self.lights(account).isEmpty)
    }

    @Test func `inspection reconstructs old exhaustion without carrying current login faults backwards`() {
        var account = self.account(used: 0, history: [self.quota([
            (-600, 100, 3600), (0, 0, 18000),
        ])])
        account.warnings = [.init(.signIn, .critical, "Login expired now.")]
        let lights = self.lights(account, date: self.now.addingTimeInterval(-600))
        #expect(lights.contains { $0.kind == .limit && $0.severity == .critical })
        #expect(!lights.contains { $0.kind == .signIn })
        // The measured drop from 100% to zero before the earlier deadline is a separate real early reset.
        // Live login trouble must remain, while that reset replaces the obsolete exhaustion claim.
        #expect(self.lights(account).map(\.kind) == [.signIn, .earlyReset])
    }

    @Test func `no warning borrows a quota observation from after the inspected instant`() {
        let account = self.account(used: 1, history: [self.quota([(0, 100, 3600)])])
        #expect(self.lights(account, date: self.now.addingTimeInterval(-1)).isEmpty)
    }

    @Test func `forecast exhaustion clears at the same reset as the projected gauge`() {
        let account = self.account(used: 0.9)
        let lane = NativeOrbitLaneProjection(
            id: "nativeQuota:primary",
            origin: self.now,
            originUsed: 90,
            rate: 0.002,
            rateSource: .windowPace,
            period: 18000,
            reset: self.now.addingTimeInterval(7200),
            lineStart: self.now)
        let projection = self.projection(lanes: [lane])
        let exhausted = self.lights(account, date: self.now.addingTimeInterval(6000), projection: projection)
        #expect(exhausted.contains { $0.kind == .limit && $0.severity == .critical })
        #expect(exhausted.allSatisfy { $0.detail.hasPrefix("Projected:") })
        let reset = self.lights(account, date: self.now.addingTimeInterval(7200), projection: projection)
        #expect(!reset.contains { [.limit, .aheadOfPace, .farAheadPace].contains($0.kind) })
    }

    @Test func `an unknown future lane cannot inherit live exhaustion`() {
        var account = self.account(used: 1)
        account.warnings = [.init(.limit, .critical, "Live exhaustion.")]
        #expect(self.lights(account, date: self.now.addingTimeInterval(600)).isEmpty)
    }

    @Test func `expired live readings leave an age warning rather than an exhaustion claim`() {
        var account = self.account(used: 1, updatedAt: self.now.addingTimeInterval(-3600))
        account.warnings = [.init(.oldReading, .caution, "The source reports an old reading.", action: .refresh)]
        let lights = self.lights(account)
        #expect(lights.map(\.kind) == [.oldReading])
    }

    @Test func `a stale allowance receipt cannot keep a live plan expired warning`() {
        let measured = self.now.addingTimeInterval(-86400)
        let expiry = self.now.addingTimeInterval(-3600)
        var account = self.account(used: 0, history: [self.allowance(at: measured, expiry: expiry)])
        account.metrics.reportedPlanExpiry = expiry
        #expect(!self.lights(account).contains { $0.kind == .plan })
    }

    @Test func `plan expiration follows recorded and explicitly projected evidence`() {
        let measured = self.now.addingTimeInterval(-600)
        let expiry = self.now.addingTimeInterval(3600)
        var account = self.account(used: 0, history: [self.allowance(at: measured, expiry: expiry)])
        account.metrics.reportedPlanExpiry = expiry
        #expect(self.lights(account, date: measured).contains { $0.kind == .plan && $0.severity == .caution })
        var projection = self.projection()
        projection = .init(
            now: projection.now,
            end: projection.end,
            lastActivity: nil,
            lanes: [],
            events: [],
            tokenRate: nil,
            costRate: nil,
            periodSummary: .init(),
            resetInventory: nil,
            liveMetrics: account.metrics)
        let projected = self.lights(account, date: self.now.addingTimeInterval(7200), projection: projection)
        #expect(projected
            .contains { $0.kind == .plan && $0.severity == .critical && $0.detail.hasPrefix("Projected:") })
    }

    private func allowance(at date: Date, expiry: Date) -> PlanUtilizationSeriesHistory {
        .init(name: "nativeMetric:allowances", windowMinutes: 0, entries: [
            .init(
                capturedAt: date,
                usedPercent: 0,
                resetsAt: nil,
                nativeMetrics: .init(planExpiryReferenceTime: expiry.timeIntervalSinceReferenceDate)),
        ])
    }

    @Test func `historical credits follow the latest receipt including an empty replacement`() {
        let first = self.now.addingTimeInterval(-600)
        let second = self.now.addingTimeInterval(-300)
        let history = [PlanUtilizationSeriesHistory(name: "nativeMetric:balance", windowMinutes: 0, entries: [
            .init(
                capturedAt: first.addingTimeInterval(-600),
                usedPercent: 0,
                resetsAt: nil,
                nativeMetrics: .init(balance: .init(
                    value: 10, unit: "USD", isWorkspace: false, updatedAt: first.addingTimeInterval(-600)))),
            .init(
                capturedAt: first,
                usedPercent: 0,
                resetsAt: nil,
                nativeMetrics: .init(balance: .init(value: 0, unit: "USD", isWorkspace: false, updatedAt: first))),
            .init(capturedAt: second, usedPercent: 0, resetsAt: nil, nativeMetrics: .init()),
        ])]
        let account = self.account(used: 0, history: history)
        #expect(self.lights(account, date: first).contains { $0.kind == .credits })
        #expect(!self.lights(account, date: second).contains { $0.kind == .credits })
    }

    @Test func `prepared warning inspection excludes even same refresh receipts after its exact cutoff`() {
        let inspected = self.now.addingTimeInterval(-600)
        func receipt(_ date: Date, value: Double) -> PlanUtilizationHistoryEntry {
            .init(
                capturedAt: date,
                usedPercent: 0,
                resetsAt: nil,
                nativeMetrics: .init(balance: .init(
                    value: value, unit: "USD", isWorkspace: false, updatedAt: date)))
        }
        var account = self.account(used: 0, history: [.init(
            name: "nativeMetric:balance",
            windowMinutes: 0,
            entries: [
                receipt(inspected.addingTimeInterval(-600), value: 10),
                receipt(inspected, value: 0),
                receipt(inspected.addingTimeInterval(0.25), value: 10),
            ])])
        account.metrics = account.metrics.preparingInspection(history: account.history)
        #expect(self.lights(account, date: inspected).contains { $0.kind == .credits && $0.severity == .critical })
        #expect(!self.lights(account, date: inspected.addingTimeInterval(0.25)).contains { $0.kind == .credits })
    }

    @Test func `future warning calculation keeps money and unreadable logs while skipping observed reset history`() {
        let history = [self.quota([(-600, 100, 3600), (0, 0, 18000)])]
        let report = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: nil,
            last30DaysCostUSD: nil,
            historyScanIsPartial: true,
            daily: [],
            updatedAt: self.now)
        var metrics = NativeOrbitAccountMetrics.empty
        metrics.localCostUsage = NativeOrbitLocalUsage(
            snapshot: report, scope: .localMachine, bucketTimeZoneIdentifier: "UTC")
        metrics.reportedSpend = ProviderCostSnapshot(
            used: 95, limit: 100, currencyCode: "USD", updatedAt: self.now)
        let observed = NativeOrbitWarningSignals.account(
            provider: .claude, snapshot: nil, metrics: metrics, history: history, now: self.now)
        #expect(observed.contains { $0.kind == .earlyReset })
        let projected = NativeOrbitWarningSignals.account(
            provider: .claude,
            snapshot: nil,
            metrics: metrics,
            history: history,
            now: self.now,
            includeObservedHistory: false)
        #expect(Set(projected.map(\.kind)) == [.spend, .localLogs])
        #expect(projected.allSatisfy { $0.severity == .caution })
    }

    private func lights(
        _ account: NativeOrbitAccountPresentation,
        date: Date? = nil,
        projection: NativeOrbitAccountProjection? = nil) -> [NativeOrbitWarningLight]
    {
        NativeOrbitWarningEvaluation.lights(
            account: account,
            peers: [account],
            projection: projection ?? self.projection(),
            date: date,
            now: self.now,
            days: 1)
    }

    private func projection(lanes: [NativeOrbitLaneProjection] = []) -> NativeOrbitAccountProjection {
        .init(
            now: self.now,
            end: self.now.addingTimeInterval(86400),
            lastActivity: nil,
            lanes: lanes,
            events: [],
            tokenRate: nil,
            costRate: nil,
            periodSummary: .init(),
            resetInventory: nil,
            liveMetrics: .empty)
    }

    private func quota(_ entries: [(TimeInterval, Double, TimeInterval)]) -> PlanUtilizationSeriesHistory {
        .init(name: "nativeQuota:primary", windowMinutes: 300, entries: entries.map { offset, used, reset in
            .init(
                capturedAt: self.now.addingTimeInterval(offset),
                usedPercent: used,
                resetsAt: self.now.addingTimeInterval(reset))
        })
    }

    private func account(
        used: Double, history: [PlanUtilizationSeriesHistory] = [], updatedAt: Date? = nil)
        -> NativeOrbitAccountPresentation
    {
        var gauge = ComputeGauge.State()
        gauge.provider = "claude"
        gauge.windows = [.init(
            id: "primary",
            label: "Session",
            period: 18000,
            used: used,
            countdown: .init(
                units: 5,
                secondsPerUnit: 3600,
                nextReset: self.now.addingTimeInterval(7200)))]
        return .init(
            id: "fixture",
            label: "Fixture",
            email: nil,
            symbol: "person",
            isActive: true,
            canActivate: false,
            gauge: gauge,
            updatedAt: updatedAt ?? self.now,
            history: history,
            odometer: nil,
            odometerHelp: nil,
            statusText: nil,
            selection: .none)
    }
}
