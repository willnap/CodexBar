import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct NativeOrbitSpendingHistoryTests {
    private let now = ISO8601DateFormatter().date(from: "2026-10-15T12:00:00Z")!

    @Test func `missing cost remains a gap while explicitly measured zero is retained`() {
        let history = self.make(self.report(daily: [
            self.day("2026-10-13", cost: 4), self.day("2026-10-14", cost: nil),
            self.day("2026-10-15", cost: 0),
        ]))
        #expect(history.bars.map(\.cost) == [4, 0])
        #expect(history.bars.allSatisfy { $0.granularity == .daily })
        #expect(history.bar(at: self.date("2026-10-14T12:00:00Z")) == nil)
    }

    @Test func `billing aggregates never become fabricated daily or hourly spend`() {
        var metrics = NativeOrbitAccountMetrics(usage: self.report(daily: [], aggregate: 95))
        metrics.reportedSpend = ProviderCostSnapshot(
            used: 95, limit: 100, currencyCode: "USD", period: "Monthly", updatedAt: self.now)
        let history = NativeOrbitSpendingHistory.make(metrics: metrics, history: [], now: self.now, days: 30)
        #expect(history.bars.isEmpty)
    }

    @Test func `day chart prefers exact events without adding daily or hourly copies`() {
        let instant = self.date("2026-10-15T09:17:03Z")
        let report = self.report(
            daily: [self.day("2026-10-15", cost: 20)],
            hourly: [.init(hour: self.date("2026-10-15T09:00:00Z"), totalTokens: nil, costUSD: 20)],
            events: [.init(timestamp: instant, totalTokens: nil, costUSD: 2)])
        let history = self.make(report, days: 1)
        #expect(history.bars.count == 1)
        #expect(history.bars.first?.cost == 2)
        #expect(history.bars.first?.observedAt == instant)
        #expect(history.bars.first?.granularity == .event)
    }

    @Test func `day totals keep a civil day interval and never create intraday samples`() {
        let history = self.make(self.report(daily: [self.day("2026-10-15", cost: 20)]), days: 1)
        #expect(history.bars.count == 1)
        #expect(history.bars.first?.start == self.date("2026-10-15T00:00:00Z"))
        #expect(history.bars.first?.end == self.date("2026-10-16T00:00:00Z"))
        #expect(history.observationDates.isEmpty)
    }

    @Test func `token only event slices do not hide measured hourly money`() {
        let hour = self.date("2026-10-15T09:00:00Z")
        let report = self.report(
            daily: [self.day("2026-10-15", cost: 20)],
            hourly: [.init(hour: hour, totalTokens: nil, costUSD: 3)],
            events: [.init(timestamp: hour.addingTimeInterval(120), totalTokens: 100, costUSD: nil)])
        let history = self.make(report, days: 1)
        #expect(history.bars.map(\.cost) == [3])
        #expect(history.bars.first?.granularity == .hourly)
    }

    @Test func `invalid money and future events stay unknown and hourly buckets keep real boundaries`() {
        let hour = self.date("2026-10-15T09:00:00Z")
        let history = self.make(self.report(daily: [], hourly: [
            .init(hour: hour, totalTokens: nil, costUSD: 3),
            .init(hour: hour.addingTimeInterval(3600), totalTokens: nil, costUSD: .infinity),
            .init(hour: hour.addingTimeInterval(7200), totalTokens: nil, costUSD: -2),
            .init(hour: self.now.addingTimeInterval(3600), totalTokens: nil, costUSD: 5),
        ]), days: 1)
        #expect(history.bars.map(\.cost) == [3])
        #expect(history.bars.first?.start == hour)
        #expect(history.bars.first?.end == hour.addingTimeInterval(3600))
        #expect(history.bars.first?.granularity == .hourly)
    }

    @Test func `indexed hourly inspection keeps exclusive ends and missing intervals`() {
        let hour = self.date("2026-10-15T08:00:00Z")
        let history = self.make(self.report(daily: [], hourly: [
            .init(hour: hour, totalTokens: nil, costUSD: 2),
            .init(hour: hour.addingTimeInterval(3600), totalTokens: nil, costUSD: 3),
            .init(hour: hour.addingTimeInterval(10800), totalTokens: nil, costUSD: 0),
        ]), days: 1)
        #expect(history.bar(at: hour.addingTimeInterval(-1)) == nil)
        #expect(history.bar(at: hour.addingTimeInterval(3599.875))?.cost == 2)
        #expect(history.bar(at: hour.addingTimeInterval(3600))?.cost == 3)
        #expect(history.bar(at: hour.addingTimeInterval(7200)) == nil)
        #expect(history.bar(at: hour.addingTimeInterval(10799.875)) == nil)
        #expect(history.bar(at: hour.addingTimeInterval(10800))?.cost == 0)
        #expect(history.bar(at: hour.addingTimeInterval(14400)) == nil)
    }

    @Test func `indexed inspection preserves first source match where UTC hours overlap local daily totals`() {
        let hour = self.date("2026-10-14T18:00:00Z")
        let history = self.make(self.report(
            daily: [self.day("2026-10-15", cost: 20)],
            zone: "Asia/Kolkata",
            hourly: [.init(hour: hour, totalTokens: nil, costUSD: 3)]))
        #expect(history.bars.count == 2)
        #expect(history.bar(at: hour.addingTimeInterval(2700))?.cost == 3)
        #expect(history.bar(at: hour.addingTimeInterval(3600))?.cost == 20)
    }

    @Test func `indexed request inspection never turns instants into intervals and corrections redraw`() {
        let instant = self.date("2026-10-15T09:17:03Z")
        let original = self.make(self.report(daily: [], events: [
            .init(timestamp: instant, totalTokens: nil, costUSD: 2),
            .init(timestamp: instant.addingTimeInterval(60), totalTokens: nil, costUSD: 4),
        ]), days: 1)
        #expect(original.bar(at: instant)?.cost == 2)
        #expect(original.bar(at: instant.addingTimeInterval(0.125)) == nil)
        #expect(original.bar(at: instant.addingTimeInterval(60))?.cost == 4)
        #expect(original.observationDates == [instant, instant.addingTimeInterval(60)])
        let corrected = self.make(self.report(daily: [], events: [
            .init(timestamp: instant, totalTokens: nil, costUSD: 3),
            .init(timestamp: instant.addingTimeInterval(60), totalTokens: nil, costUSD: 4),
        ]), days: 1)
        var first = NativeOrbitHistoryWidget(histories: [], now: self.now)
        first.spending = original
        var second = first
        second.spending = corrected
        #expect(first.plotKey([]) != second.plotKey([]), "A corrected amount invalidates the static chart")
    }

    @Test func `account and local spend are selected as separate currency coherent streams`() {
        var metrics = NativeOrbitAccountMetrics(usage: self.report(
            daily: [self.day("2026-10-15", cost: 3)], currency: "EUR"))
        metrics.localCostUsage = NativeOrbitLocalUsage(
            snapshot: self.report(daily: [self.day("2026-10-15", cost: 50)]),
            scope: .localMachine,
            bucketTimeZoneIdentifier: "UTC")
        var history = NativeOrbitSpendingHistory.make(metrics: metrics, history: [], now: self.now, days: 7)
        #expect(history.bars.map(\.cost) == [3])
        #expect(history.currencyCode == "EUR")
        #expect(history.scope == .account)
        metrics.usage = self.report(daily: [self.day("2026-10-15", cost: nil)])
        history = NativeOrbitSpendingHistory.make(metrics: metrics, history: [], now: self.now, days: 7)
        #expect(history.bars.map(\.cost) == [50])
        #expect(history.currencyCode == "USD")
        #expect(history.scope == .localMachine)
        #expect(history.help(at: self.now).contains("Local machine"))
    }

    @Test func `repeated receipts deduplicate daily totals and newest correction wins`() throws {
        let old = self.report(daily: [self.day("2026-10-14", cost: 4)])
        let corrected = self.report(daily: [self.day("2026-10-14", cost: 3)])
        let history = try PlanUtilizationSeriesHistory(
            name: .init(rawValue: "nativeMetric:usage"),
            windowMinutes: 0,
            entries: [
                .init(
                    capturedAt: self.now.addingTimeInterval(-3600),
                    usedPercent: 0,
                    resetsAt: nil,
                    nativeMetrics: .init(usage: #require(NativeOrbitUsageObservation(old)))),
                .init(
                    capturedAt: self.now,
                    usedPercent: 0,
                    resetsAt: nil,
                    nativeMetrics: .init(usage: #require(NativeOrbitUsageObservation(corrected)))),
            ])
        let result = NativeOrbitSpendingHistory.make(
            metrics: .empty, history: [history, history], now: self.now, days: 7)
        #expect(result.bars.map(\.cost) == [3])
    }

    @Test func `old account receipts cannot add another currency to live money bars`() throws {
        let old = self.report(daily: [self.day("2026-10-14", cost: 40)], currency: "EUR")
        let receipts = try PlanUtilizationSeriesHistory(
            name: .init(rawValue: "nativeMetric:usage"),
            windowMinutes: 0,
            entries: [.init(
                capturedAt: self.now.addingTimeInterval(-3600),
                usedPercent: 0,
                resetsAt: nil,
                nativeMetrics: .init(usage: #require(NativeOrbitUsageObservation(old))))])
        let result = NativeOrbitSpendingHistory.make(
            metrics: .init(usage: self.report(daily: [self.day("2026-10-15", cost: 3)])),
            history: [receipts],
            now: self.now,
            days: 7)
        #expect(result.currencyCode == "USD")
        #expect(result.bars.map(\.cost) == [3])
    }

    @Test func `source civil days preserve DST boundaries and source timezone`() {
        let now = self.date("2026-03-09T12:00:00Z")
        let report = self.report(
            daily: [self.day("2026-03-08", cost: 3)],
            zone: "America/New_York",
            updatedAt: now)
        let history = NativeOrbitSpendingHistory.make(
            metrics: .init(usage: report), history: [], now: now, days: 7, calendar: self.calendar())
        #expect(history.bars.first?.start == self.date("2026-03-08T05:00:00Z"))
        #expect(history.bars.first?.end == self.date("2026-03-09T04:00:00Z"))
    }

    @Test func `budget receipts create only measured percentage observations with their actual timestamps`() {
        let instant = self.now.addingTimeInterval(-3600)
        let spend = ProviderCostSnapshot(
            used: 25, limit: 100, currencyCode: "USD", period: "Monthly", updatedAt: instant)
        let receipts = PlanUtilizationSeriesHistory(
            name: .init(rawValue: "nativeMetric:spend"),
            windowMinutes: 0,
            entries: [.init(capturedAt: instant, usedPercent: 0, resetsAt: nil, nativeMetrics: .init(spend: spend))])
        let history = NativeOrbitSpendingHistory.make(
            metrics: .empty, history: [receipts], now: self.now, days: 7, emphasizesQuota: true)
        #expect(history.budgetHistory?.entries.count == 1)
        #expect(history.budgetHistory?.entries.first?.capturedAt == instant)
        #expect(history.budgetHistory?.entries.first?.usedPercent == 25)
        #expect(history.bars.isEmpty)
    }

    @Test func `unavailable disabled and unbounded spend receipts cannot establish a percentage line`() {
        let costs = [
            ProviderCostSnapshot(used: 25, limit: 0, currencyCode: "USD", updatedAt: self.now),
            ProviderCostSnapshot(
                used: 25,
                limit: 100,
                currencyCode: "USD",
                usageIsUnavailable: true,
                updatedAt: self.now),
            ProviderCostSnapshot(
                used: 25,
                limit: 100,
                currencyCode: "USD",
                isDisabled: true,
                updatedAt: self.now),
        ]
        for spend in costs {
            let receipts = PlanUtilizationSeriesHistory(
                name: .init(rawValue: "nativeMetric:spend"),
                windowMinutes: 0,
                entries: [.init(
                    capturedAt: self.now,
                    usedPercent: 0,
                    resetsAt: nil,
                    nativeMetrics: .init(spend: spend))])
            let history = NativeOrbitSpendingHistory.make(
                metrics: .empty, history: [receipts], now: self.now, days: 7, emphasizesQuota: true)
            #expect(history.budgetHistory == nil)
        }
    }

    @Test func `latest unavailable budget observation invalidates older active budgets`() {
        let old = self.now.addingTimeInterval(-3600)
        let active = ProviderCostSnapshot(used: 25, limit: 100, currencyCode: "USD", updatedAt: old)
        let receipts = PlanUtilizationSeriesHistory(
            name: .init(rawValue: "nativeMetric:spend"),
            windowMinutes: 0,
            entries: [
                .init(capturedAt: old, usedPercent: 0, resetsAt: nil, nativeMetrics: .init(spend: active)),
                .init(capturedAt: self.now, usedPercent: 0, resetsAt: nil, nativeMetrics: .init()),
            ])
        let history = NativeOrbitSpendingHistory.make(
            metrics: .empty, history: [receipts], now: self.now, days: 7, emphasizesQuota: true)
        #expect(history.budgetHistory == nil)
        var metrics = NativeOrbitAccountMetrics.empty
        metrics.reportedSpend = ProviderCostSnapshot(
            used: 25, limit: 100, currencyCode: "Credits", updatedAt: self.now)
        #expect(NativeOrbitSpendingHistory.make(
            metrics: metrics, history: [], now: self.now, days: 7, emphasizesQuota: true).budgetHistory == nil)
    }

    @Test func `budget definition changes cannot masquerade as early provider resets`() throws {
        let old = self.now.addingTimeInterval(-3600)
        let reset = self.now.addingTimeInterval(86400)
        let original = ProviderCostSnapshot(
            used: 50, limit: 100, currencyCode: "USD", period: "Monthly", resetsAt: reset, updatedAt: old)
        let replacements = [
            ProviderCostSnapshot(
                used: 50,
                limit: 200,
                currencyCode: "USD",
                period: "Monthly",
                resetsAt: reset,
                updatedAt: self.now),
            ProviderCostSnapshot(
                used: 25,
                limit: 100,
                currencyCode: "USD",
                period: "Weekly",
                resetsAt: reset,
                updatedAt: self.now),
            ProviderCostSnapshot(
                used: 25,
                limit: 100,
                currencyCode: "EUR",
                period: "Monthly",
                resetsAt: reset,
                updatedAt: self.now),
            ProviderCostSnapshot(
                used: 25,
                limit: 100,
                currencyCode: "USD",
                period: "Monthly",
                resetsAt: reset.addingTimeInterval(3600),
                updatedAt: self.now),
        ]
        for replacement in replacements {
            let budget = try #require(self.budgetHistory([original, replacement]))
            #expect(budget.entries.map(\.capturedAt) == [self.now])
            #expect(NativeOrbitResetEvent.events(
                quotaHistories: [budget], metricHistories: [], provider: .openrouter, now: self.now).isEmpty)
        }
    }

    @Test func `a restored budget cannot bridge an unavailable monetary receipt`() throws {
        let old = self.now.addingTimeInterval(-3600)
        let original = ProviderCostSnapshot(
            used: 50, limit: 100, currencyCode: "USD", period: "Monthly", updatedAt: old)
        let restored = ProviderCostSnapshot(
            used: 25, limit: 100, currencyCode: "USD", period: "Monthly", updatedAt: self.now)
        let receipts = PlanUtilizationSeriesHistory(
            name: .init(rawValue: "nativeMetric:spend"), windowMinutes: 0, entries: [
                .init(capturedAt: old, usedPercent: 0, resetsAt: nil, nativeMetrics: .init(spend: original)),
                .init(
                    capturedAt: old.addingTimeInterval(1800),
                    usedPercent: 0,
                    resetsAt: nil,
                    nativeMetrics: .init()),
                .init(capturedAt: self.now, usedPercent: 0, resetsAt: nil, nativeMetrics: .init(spend: restored)),
            ])
        let result = NativeOrbitSpendingHistory.make(
            metrics: .empty, history: [receipts], now: self.now, days: 7, emphasizesQuota: true)
        #expect(try #require(result.budgetHistory).entries.map(\.capturedAt) == [self.now])
    }

    @Test func `comparable budget receipts preserve a real scheduled reset boundary`() throws {
        let reset = self.now.addingTimeInterval(-1800)
        let original = ProviderCostSnapshot(
            used: 50,
            limit: 100,
            currencyCode: "USD",
            period: "Monthly",
            resetsAt: reset,
            updatedAt: self.now.addingTimeInterval(-3600))
        let renewed = ProviderCostSnapshot(
            used: 5,
            limit: 100,
            currencyCode: "USD",
            period: "Monthly",
            resetsAt: self.now.addingTimeInterval(86400),
            updatedAt: self.now)
        let budget = try #require(self.budgetHistory([original, renewed]))
        #expect(budget.entries.count == 2)
        let events = NativeOrbitResetEvent.events(
            quotaHistories: [budget], metricHistories: [], provider: .openrouter, now: self.now)
        #expect(events.map(\.kind) == [.natural])
        #expect(events.map(\.date) == [reset])
    }

    private func budgetHistory(_ spends: [ProviderCostSnapshot]) -> PlanUtilizationSeriesHistory? {
        let receipts = PlanUtilizationSeriesHistory(
            name: .init(rawValue: "nativeMetric:spend"), windowMinutes: 0, entries: spends.map { spend in
                .init(capturedAt: spend.updatedAt, usedPercent: 0, resetsAt: nil, nativeMetrics: .init(spend: spend))
            })
        return NativeOrbitSpendingHistory.make(
            metrics: .empty, history: [receipts], now: self.now, days: 7, emphasizesQuota: true).budgetHistory
    }

    private func make(_ report: CostUsageTokenSnapshot, days: Int = 7) -> NativeOrbitSpendingHistory {
        NativeOrbitSpendingHistory.make(
            metrics: .init(usage: report), history: [], now: self.now, days: days, calendar: self.calendar())
    }

    private func calendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    private func day(_ date: String, cost: Double?) -> CostUsageDailyReport.Entry {
        .init(
            date: date,
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: nil,
            costUSD: cost,
            modelsUsed: nil,
            modelBreakdowns: nil)
    }

    private func report(
        daily: [CostUsageDailyReport.Entry],
        currency: String = "USD",
        zone: String = "UTC",
        aggregate: Double? = nil,
        hourly: [CostUsageHourlyEntry] = [],
        events: [CostUsageTimedEntry] = [],
        updatedAt: Date? = nil) -> CostUsageTokenSnapshot
    {
        .init(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: nil,
            last30DaysCostUSD: aggregate,
            currencyCode: currency,
            bucketTimeZoneIdentifier: zone,
            daily: daily,
            hourly: hourly,
            quotaSlices: events,
            updatedAt: updatedAt ?? self.now)
    }
}
