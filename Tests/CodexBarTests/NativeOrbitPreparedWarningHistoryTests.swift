import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct NativeOrbitPreparedWarningHistoryTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func `cached resets preserve every historical evidence boundary in either inspection direction`() {
        let grant = self.now.addingTimeInterval(10 * 86400)
        let snapshots: [UsageSnapshot] = [
            self.snapshot(
                at: -3600,
                used: 80,
                inventory: .init(expirations: [grant], updatedAt: self.now.addingTimeInterval(-3600))),
            self.snapshot(at: -3300, used: 0, inventory: nil),
            self.snapshot(
                at: -3100,
                used: 0,
                inventory: .init(expirations: [grant], updatedAt: self.now.addingTimeInterval(-3100))),
        ]
        let history = snapshots.reduce([PlanUtilizationSeriesHistory]()) {
            UsageStore.nativeOrbitHistoryIncludingCurrentSnapshot($0, provider: .claude, snapshot: $1)
        }
        let prepared = NativeOrbitPreparedWarningHistory(history: history)
        let offsets: [TimeInterval] = [
            -4000, -3600, -3300.01, -3300, -3299, -3100.01, -3100, -3000, 0, 86400,
        ]
        for provider in [UsageProvider.claude, .kimi] {
            for offset in offsets + offsets.reversed() {
                let date = self.now.addingTimeInterval(offset)
                let prefix = history.map { $0.prefix(through: date) }
                let expected = NativeOrbitResetEvent.events(
                    quotaHistories: prefix.filter(\.name.isNativeQuotaObservation),
                    metricHistories: prefix.filter(\.name.isNativeMetricObservation),
                    provider: provider,
                    now: date).last {
                    ($0.kind == .provider || $0.kind == .early) && $0.date <= date
                        && date.timeIntervalSince($0.date) <= 86400
                }
                #expect(prepared.earlyReset(provider: provider, at: date) == expected)
                let original = NativeOrbitWarningSignals.account(
                    provider: provider, snapshot: nil, metrics: .empty, history: prefix, now: date)
                let bounded = NativeOrbitWarningSignals.account(
                    provider: provider, snapshot: nil, metrics: .empty, history: history, now: date)
                #expect(bounded == original)
            }
        }
        #expect(prepared.earlyReset(provider: .claude, at: self.now.addingTimeInterval(-3300))?.kind == .early)
        #expect(prepared.earlyReset(provider: .claude, at: self.now.addingTimeInterval(-3100))?.kind == .provider)
    }

    @Test func `prepared consumption intervals preserve exact rolling boundaries without future receipts`() {
        let reset = self.now.addingTimeInterval(7 * 86400)
        let history = PlanUtilizationSeriesHistory(name: "nativeQuota:primary", windowMinutes: 10080, entries: [
            .init(capturedAt: self.now.addingTimeInterval(-90000), usedPercent: 10, resetsAt: reset),
            .init(capturedAt: self.now.addingTimeInterval(-86400), usedPercent: 20, resetsAt: reset),
            .init(capturedAt: self.now.addingTimeInterval(-300), usedPercent: 30, resetsAt: reset),
            .init(capturedAt: self.now, usedPercent: 40, resetsAt: reset),
            .init(capturedAt: self.now.addingTimeInterval(300), usedPercent: 50, resetsAt: reset),
        ])
        let prepared = NativeOrbitPreparedWarningHistory(history: [history])
        for offset in [-86400.0, -0.01, 0, 0.01, 300] {
            let date = self.now.addingTimeInterval(offset)
            let expected = zip(history.entries, history.entries.dropFirst()).compactMap { before, after in
                after.capturedAt <= date && date.timeIntervalSince(after.capturedAt) <= 86400
                    && after.usedPercent > before.usedPercent + NativeOrbitActivity.minimumIncrease
                    && NativeOrbitActivity.sameWindow(before, after) ? before.capturedAt...after.capturedAt : nil
            }
            #expect(Array(prepared.consumptionIntervals(at: date)) == expected)
        }
    }

    @Test func `ordered history prefix matches the prior filtered sorted prefix including timestamp ties`() {
        let history = PlanUtilizationSeriesHistory(name: "nativeQuota:primary", windowMinutes: 300, entries: [
            .init(capturedAt: self.now, usedPercent: 30, resetsAt: nil),
            .init(capturedAt: self.now.addingTimeInterval(-60), usedPercent: 20, resetsAt: nil),
            .init(capturedAt: self.now.addingTimeInterval(-60), usedPercent: 10, resetsAt: self.now),
        ])
        for offset in [-61.0, -60, -0.01, 0, 1] {
            let date = self.now.addingTimeInterval(offset)
            #expect(history.prefix(through: date) == PlanUtilizationSeriesHistory(
                name: history.name,
                windowMinutes: history.windowMinutes,
                entries: history.entries.filter { $0.capturedAt <= date }))
        }
    }

    @Test func `prepared external usage warning matches exact local coverage and receipt timing`() {
        let reset = self.now.addingTimeInterval(86400)
        let history = [PlanUtilizationSeriesHistory(name: "nativeQuota:primary", windowMinutes: 300, entries: [
            .init(capturedAt: self.now.addingTimeInterval(-300), usedPercent: 10, resetsAt: reset),
            .init(capturedAt: self.now, usedPercent: 30, resetsAt: reset),
            .init(capturedAt: self.now.addingTimeInterval(300), usedPercent: 50, resetsAt: reset),
        ])]
        var metrics = NativeOrbitAccountMetrics.empty
        metrics.localCostUsage = .init(
            snapshot: .init(
                sessionTokens: 0,
                sessionCostUSD: 0,
                last30DaysTokens: 0,
                last30DaysCostUSD: 0,
                daily: [],
                updatedAt: self.now),
            scope: .localMachine,
            bucketTimeZoneIdentifier: "UTC",
            isAccountAttributed: true)
        let prepared = NativeOrbitPreparedWarningHistory(history: history)
        for offset in [-0.01, 0, 0.01, 300, 3601, 86400] {
            let date = self.now.addingTimeInterval(offset)
            let prefix = history.map { $0.prefix(through: date) }
            let expected = NativeOrbitWarningSignals.account(
                provider: .claude, snapshot: nil, metrics: metrics, history: prefix, now: date)
            let indexed = NativeOrbitWarningSignals.account(
                provider: .claude,
                snapshot: nil,
                metrics: metrics,
                history: history,
                now: date,
                preparedHistory: prepared)
            #expect(indexed == expected)
            if offset == 0 { #expect(indexed.contains { $0.kind == .usedElsewhere }) }
        }
    }

    @Test func `shared full histories match copied prefixes for cadence allowance and funding evidence`() {
        let expiry = self.now.addingTimeInterval(3600)
        let history: [PlanUtilizationSeriesHistory] = [
            .init(name: "nativeQuota:primary", windowMinutes: 60, entries: [
                .init(capturedAt: self.now.addingTimeInterval(-3600), usedPercent: 10, resetsAt: expiry),
                .init(capturedAt: self.now.addingTimeInterval(600), usedPercent: 20, resetsAt: expiry),
            ]),
            .init(name: "nativeQuota:primary", windowMinutes: 300, entries: [
                .init(capturedAt: self.now.addingTimeInterval(-900), usedPercent: 20, resetsAt: expiry),
                .init(capturedAt: self.now.addingTimeInterval(1800), usedPercent: 30, resetsAt: expiry),
            ]),
            .init(name: "nativeMetric:allowances", windowMinutes: 0, entries: [
                .init(
                    capturedAt: self.now.addingTimeInterval(-300),
                    usedPercent: 0,
                    resetsAt: nil,
                    nativeMetrics: .init(planExpiryReferenceTime: expiry.timeIntervalSinceReferenceDate)),
                .init(
                    capturedAt: self.now.addingTimeInterval(0.25),
                    usedPercent: 0,
                    resetsAt: nil,
                    nativeMetrics: .init()),
            ]),
            .init(name: "nativeMetric:balance", windowMinutes: 0, entries: [
                .init(
                    capturedAt: self.now.addingTimeInterval(-600),
                    usedPercent: 0,
                    resetsAt: nil,
                    nativeMetrics: .init(balance: .init(
                        value: 10, unit: "USD", isWorkspace: false, updatedAt: self.now.addingTimeInterval(-600)))),
                .init(
                    capturedAt: self.now.addingTimeInterval(1),
                    usedPercent: 0,
                    resetsAt: nil,
                    nativeMetrics: .init()),
            ]),
        ]
        for offset in [-7200.0, -900, -300, 0, 0.25, 1, 600, 1800] {
            let moment = self.now.addingTimeInterval(offset)
            var metrics = NativeOrbitAccountMetrics.empty
            metrics.reportedPlanExpiry = expiry
            metrics.reportedBalance = .init(value: 0, unit: "USD", isWorkspace: false, updatedAt: moment)
            let snapshot = UsageSnapshot(
                primary: .init(usedPercent: 30, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: moment)
            let copied = NativeOrbitWarningSignals.account(
                provider: .claude,
                snapshot: snapshot,
                metrics: metrics,
                history: history.map { $0.prefix(through: moment) },
                now: moment,
                observedAt: moment)
            let shared = NativeOrbitWarningSignals.account(
                provider: .claude,
                snapshot: snapshot,
                metrics: metrics,
                history: history,
                now: moment,
                observedAt: moment)
            #expect(shared == copied)
            if offset == -7200 { #expect(shared.contains { $0.kind == .plan }) }
            if offset == 0 { #expect(shared.contains { $0.kind == .limitsChanged }) }
        }
    }

    private func snapshot(
        at offset: TimeInterval, used: Double, inventory: ClaudeRateLimitResetCreditsSnapshot?) -> UsageSnapshot
    {
        .init(
            primary: nil,
            secondary: .init(
                usedPercent: used,
                windowMinutes: 10080,
                resetsAt: self.now.addingTimeInterval(7 * 86400),
                resetDescription: nil),
            claudeResetCredits: inventory,
            updatedAt: self.now.addingTimeInterval(offset))
    }
}
