import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct NativeOrbitPreparedMetricsTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func `prepared metric receipts preserve unavailable readings duplicate order skew and gaps`() {
        let balance = NativeOrbitReportedBalance(value: 12, unit: "USD", isWorkspace: false, updatedAt: self.now)
        let entries: [PlanUtilizationHistoryEntry] = [
            .init(
                capturedAt: self.now.addingTimeInterval(-600),
                usedPercent: 0,
                resetsAt: nil,
                nativeMetrics: .init(balance: balance)),
            .init(capturedAt: self.now, usedPercent: 0, resetsAt: nil, nativeMetrics: .init()),
            .init(capturedAt: self.now, usedPercent: 0, resetsAt: nil, nativeMetrics: .init(balance: balance)),
        ]
        let history = [PlanUtilizationSeriesHistory(
            name: .init(rawValue: "nativeMetric:balance"),
            windowMinutes: 0,
            entries: entries)]
        let metrics = NativeOrbitAccountMetrics.empty
        let prepared = metrics.preparingInspection(history: history)
        for offset in [-700.0, -600, -0.6, -0.4, 0, 900, 5401] {
            let date = self.now.addingTimeInterval(offset)
            #expect(prepared.at(date, observedAt: self.now, history: history).reportedBalance
                == metrics.at(date, observedAt: self.now, history: history).reportedBalance)
        }
    }

    @Test func `a prepared history never replaces an alternate account history`() {
        let first = self.history(balance: 12)
        let other = self.history(balance: 99)
        let prepared = NativeOrbitAccountMetrics.empty.preparingInspection(history: first)
        #expect(prepared.at(self.now, observedAt: self.now, history: other).reportedBalance?.value == 99)
    }

    @Test func `prepared timestamp ranges preserve intraday boundaries partial data and unsorted input`() {
        let calendar = CostUsageBucketTimeZone.calendar(identifier: "UTC")
        let slices: [CostUsageTimedEntry] = [
            .init(timestamp: self.now.addingTimeInterval(-90000), totalTokens: 100, costUSD: 1),
            .init(timestamp: self.now.addingTimeInterval(-600), totalTokens: 20, costUSD: 0.2),
            .init(timestamp: self.now, totalTokens: nil, costUSD: 0.3, tokensAreComplete: false),
            .init(timestamp: self.now.addingTimeInterval(600), totalTokens: 40, costUSD: nil),
        ]
        for ordered in [slices, Array(slices.reversed())] {
            let metrics = NativeOrbitAccountMetrics(usage: self.usage(slices: ordered))
            let prepared = metrics.preparingInspection(history: [])
            for days in [1, 7, 30] {
                for offset in [-90001.0, -90000, -601, -600, 0, 600] {
                    let date = self.now.addingTimeInterval(offset)
                    let expected = metrics.summary(days: days, now: date, calendar: calendar)
                    let actual = prepared.summary(days: days, now: date, calendar: calendar)
                    #expect(actual.tokens == expected.tokens)
                    #expect(actual.cost == expected.cost)
                    #expect(actual.isPartial == expected.isPartial)
                    #expect(actual.costIsPartial == expected.costIsPartial)
                }
            }
        }
    }

    @Test func `replacing usage cannot reuse a prepared timestamp range from another reading`() {
        var metrics = NativeOrbitAccountMetrics(usage: self.usage(slices: [
            .init(timestamp: self.now, totalTokens: 20, costUSD: 1),
        ])).preparingInspection(history: [])
        metrics.usage = self.usage(slices: [.init(timestamp: self.now, totalTokens: 99, costUSD: 2)])
        #expect(metrics.summary(days: 1, now: self.now).tokens == 99)
    }

    @Test func `cutoff preparation exactly matches truncated receipt histories including polling cadence`() {
        let dates = [-20000.0, -19000, -18000, -1000, -700, -400, -100, 0, 0.25]
        let entries = dates.enumerated().map { index, offset in
            PlanUtilizationHistoryEntry(
                capturedAt: self.now.addingTimeInterval(offset),
                usedPercent: 0,
                resetsAt: nil,
                nativeMetrics: .init(balance: .init(
                    value: Double(index),
                    unit: "USD",
                    isWorkspace: false,
                    updatedAt: self.now.addingTimeInterval(offset))))
        }
        let history = [PlanUtilizationSeriesHistory(
            name: .init(rawValue: "nativeMetric:balance"),
            windowMinutes: 0,
            entries: Array(entries.reversed()))]
        let metrics = NativeOrbitAccountMetrics.empty
        let prepared = metrics.preparingInspection(history: history)
        for offset in [-21000.0, -19500, -18500, -15000, -1500, -500, -0.1, 0, 0.2, 0.25, 901] {
            let date = self.now.addingTimeInterval(offset)
            let truncated = history.map { lane in
                PlanUtilizationSeriesHistory(
                    name: lane.name,
                    windowMinutes: lane.windowMinutes,
                    entries: lane.entries.filter { $0.capturedAt <= date })
            }
            let expected = metrics.at(date, observedAt: self.now, history: truncated)
            let actual = prepared.at(date, observedAt: self.now, history: history, historyCutoff: date)
            #expect(actual.reportedBalance == expected.reportedBalance)
        }
    }

    @Test func `cutoff preparation preserves credit event multiplicity without borrowing future receipts`() {
        let event = NativeOrbitCreditUsageEvent(CreditEvent(
            date: self.now.addingTimeInterval(-1000), service: "fixture", creditsUsed: 2))
        let history = [PlanUtilizationSeriesHistory(
            name: .init(rawValue: "nativeMetric:creditEvents"),
            windowMinutes: 0,
            entries: [
                .init(
                    capturedAt: self.now.addingTimeInterval(-600),
                    usedPercent: 0,
                    resetsAt: nil,
                    nativeMetrics: .init(creditEvents: [event])),
                .init(
                    capturedAt: self.now,
                    usedPercent: 0,
                    resetsAt: nil,
                    nativeMetrics: .init(creditEvents: [event, event])),
            ])]
        let metrics = NativeOrbitAccountMetrics.empty
        let prepared = metrics.preparingInspection(history: history)
        for offset in [-601.0, -600, -1, 0, 1] {
            let date = self.now.addingTimeInterval(offset)
            let truncated = history.map { lane in
                PlanUtilizationSeriesHistory(
                    name: lane.name,
                    windowMinutes: lane.windowMinutes,
                    entries: lane.entries.filter { $0.capturedAt <= date })
            }
            #expect(prepared.at(date, observedAt: self.now, history: history, historyCutoff: date).creditUsageEvents
                == metrics.at(date, observedAt: self.now, history: truncated).creditUsageEvents)
        }
    }

    private func history(balance: Double) -> [PlanUtilizationSeriesHistory] {
        [.init(name: .init(rawValue: "nativeMetric:balance"), windowMinutes: 0, entries: [
            .init(capturedAt: self.now, usedPercent: 0, resetsAt: nil, nativeMetrics: .init(balance: .init(
                value: balance, unit: "USD", isWorkspace: false, updatedAt: self.now))),
        ])]
    }

    private func usage(slices: [CostUsageTimedEntry]) -> CostUsageTokenSnapshot {
        .init(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: nil,
            last30DaysCostUSD: nil,
            bucketTimeZoneIdentifier: "UTC",
            daily: [],
            quotaSlices: slices,
            updatedAt: self.now.addingTimeInterval(3600))
    }
}
