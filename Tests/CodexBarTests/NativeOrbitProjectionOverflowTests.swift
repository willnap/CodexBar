import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct NativeOrbitProjectionOverflowTests {
    /// 2027-01-15 12:00 UTC; every fixture has twelve measured hours of the current day.
    private let now = Date(timeIntervalSince1970: 1_800_014_400)

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }

    @Test func `projected tokens become unknown when addition exceeds the integer range`() {
        let projection = self.projection(tokens: Int.max, cost: 12)
        #expect(projection.isActive)
        #expect(projection.periodSummary.tokens == Int.max)
        let result = projection.summary(days: 1, at: self.now.addingTimeInterval(60), calendar: self.calendar)
        #expect(result.summary.tokens == nil)
        #expect(result.recordedTokens == Int.max)
        #expect(result.recordedCost == 12)
        #expect(result.summary.cost?.isFinite == true)
    }

    @Test func `future only tokens become unknown when their forecast cannot fit an integer`() {
        let projection = self.projection(tokens: Int.max, cost: 12)
        // Tomorrow at 18:00: no recorded part, and eighteen forecast hours at a twelve-hour measured pace.
        let result = projection.summary(days: 1, at: self.now.addingTimeInterval(30 * 3600), calendar: self.calendar)
        #expect(result.summary.tokens == nil)
        #expect(result.recordedTokens == nil)
        #expect(result.summary.cost?.isFinite == true)
    }

    @Test(arguments: [60.0, 30.0 * 3600])
    func `finite measured money never turns into an infinite projected amount`(ahead: TimeInterval) {
        let projection = self.projection(tokens: 1200, cost: .greatestFiniteMagnitude)
        #expect(projection.periodSummary.cost == .greatestFiniteMagnitude)
        let result = projection.summary(days: 1, at: self.now.addingTimeInterval(ahead), calendar: self.calendar)
        #expect(result.summary.cost == nil)
        #expect(result.summary.tokens != nil)
        if ahead < 86400 {
            #expect(result.recordedCost == .greatestFiniteMagnitude)
        }
    }

    @Test func `ordinary finite forecasts retain their measured and projected totals`() {
        let projection = self.projection(tokens: 1200, cost: 12)
        let result = projection.summary(days: 1, at: self.now.addingTimeInterval(3600), calendar: self.calendar)
        #expect(result.summary.tokens == 1300)
        #expect(result.summary.cost == 13)
        #expect(result.recordedTokens == 1200)
        #expect(result.recordedCost == 12)
    }

    private func projection(tokens: Int, cost: Double) -> NativeOrbitAccountProjection {
        let report = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: tokens,
            last30DaysCostUSD: cost,
            bucketTimeZoneIdentifier: "UTC",
            coverageThrough: self.now,
            daily: [.init(
                date: CostUsageLocalDay.key(from: self.now, calendar: self.calendar),
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: tokens,
                costUSD: cost,
                modelsUsed: nil,
                modelBreakdowns: nil)],
            quotaSlices: [.init(timestamp: self.now, totalTokens: 1, costUSD: nil)],
            updatedAt: self.now)
        var gauge = ComputeGauge.State()
        gauge.provider = "claude"
        var account = NativeOrbitAccountPresentation(
            id: "fixture",
            label: "Fixture",
            email: nil,
            symbol: "person",
            isActive: true,
            canActivate: false,
            gauge: gauge,
            updatedAt: self.now,
            history: [],
            odometer: nil,
            odometerHelp: nil,
            statusText: nil,
            selection: .none)
        account.metrics.usage = report
        return NativeOrbitAccountProjection.make(
            account: account,
            lanes: [],
            now: self.now,
            days: 1,
            start: self.calendar.startOfDay(for: self.now),
            end: self.now.addingTimeInterval(30 * 86400))
    }
}
