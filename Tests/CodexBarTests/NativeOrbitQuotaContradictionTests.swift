import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct NativeOrbitQuotaContradictionTests {
    private let now = Date(timeIntervalSince1970: 1_791_810_000)
    private let calendar = CostUsageBucketTimeZone.calendar(identifier: "UTC")

    @Test func `a covered zero stays zero while the account's quota did not move`() {
        var metrics = NativeOrbitAccountMetrics(usage: self.coveredReportWithoutToday())
        metrics.quotaConsumption = NativeOrbitActivity.consumptionDates([self.weekly([(-7200, 40), (-600, 40)])])
        let today = metrics.summary(days: 1, now: self.now, calendar: self.calendar)
        #expect(today.tokens == 0)
        #expect(today.cost == 0)
        #expect(!today.zeroContradictedByQuota)
    }

    @Test func `quota consumed elsewhere turns a source's zero into unknown`() {
        var metrics = NativeOrbitAccountMetrics(usage: self.coveredReportWithoutToday())
        metrics.quotaConsumption = NativeOrbitActivity.consumptionDates([self.weekly([(-7200, 40), (-600, 46)])])
        let today = metrics.summary(days: 1, now: self.now, calendar: self.calendar)
        #expect(today.tokens == nil)
        #expect(today.cost == nil)
        #expect(today.zeroContradictedByQuota)
        // The week still holds its measured total; only the contradicted zero becomes unknown.
        let week = metrics.summary(days: 7, now: self.now, calendar: self.calendar)
        #expect(week.tokens == 1200)
        #expect(!week.zeroContradictedByQuota)
    }

    @Test func `a rise across a window reset is not consumption`() {
        let reset = self.now.addingTimeInterval(-3600)
        let history = PlanUtilizationSeriesHistory(name: "nativeQuota:secondary", windowMinutes: 10080, entries: [
            .init(capturedAt: self.now.addingTimeInterval(-7200), usedPercent: 2, resetsAt: reset),
            .init(
                capturedAt: self.now.addingTimeInterval(-600),
                usedPercent: 30,
                resetsAt: reset.addingTimeInterval(7 * 86400)),
        ])
        #expect(NativeOrbitActivity.consumptionDates([history]).isEmpty)
        let rising = self.weekly([(-7200, 2), (-600, 30)])
        #expect(NativeOrbitActivity.consumptionDates([rising]) == [self.now.addingTimeInterval(-600)])
    }

    private func weekly(_ points: [(TimeInterval, Double)]) -> PlanUtilizationSeriesHistory {
        let reset = self.now.addingTimeInterval(3 * 86400)
        return PlanUtilizationSeriesHistory(name: "nativeQuota:secondary", windowMinutes: 10080, entries: points.map {
            .init(capturedAt: self.now.addingTimeInterval($0.0), usedPercent: $0.1, resetsAt: reset)
        })
    }

    /// A complete account report with activity two days ago and none today.
    private func coveredReportWithoutToday() -> CostUsageTokenSnapshot {
        let past = self.now.addingTimeInterval(-2 * 86400)
        return CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: 1200,
            last30DaysCostUSD: 0.25,
            historyDays: 30,
            daily: [.init(
                date: CostUsageLocalDay.key(from: past, calendar: self.calendar),
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: 1200,
                requestCount: 3,
                costUSD: 0.25,
                modelsUsed: nil,
                modelBreakdowns: nil)],
            updatedAt: self.now)
    }
}
