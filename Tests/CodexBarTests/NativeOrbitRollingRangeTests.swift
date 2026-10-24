import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct NativeOrbitRollingRangeTests {
    private let now = Date(timeIntervalSince1970: 1_800_014_400)

    @Test func `day includes yesterday events inside twenty four hours and excludes older events`() {
        let metrics = NativeOrbitAccountMetrics(usage: self.snapshot)
        let reading = metrics.summary(days: 1, now: self.now)
        #expect(reading.tokens == 500)
        #expect(reading.cost == 5)
    }

    @Test func `inspection excludes requests after the pointer and keeps the preceding rolling day`() {
        let date = self.now.addingTimeInterval(-3600)
        let reading = NativeOrbitAccountMetrics(usage: self.snapshot).summary(days: 1, now: date)
        #expect(reading.tokens == 200)
        #expect(reading.cost == 2)
    }

    @Test func `unprojected ranges have exact durations and equally spaced labels across daylight savings`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/London"))
        let date = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 10,
            day: 25,
            hour: 12,
            minute: 23)))
        for days in [1, 7, 30] {
            let widget = NativeOrbitHistoryWidget(histories: [], now: date, days: days, calendar: calendar)
            #expect(date.timeIntervalSince(widget.start) == Double(days) * 86400)
            #expect(widget.axisDates.count == 3)
            #expect(widget.axisDates[1].timeIntervalSince(widget.start) == Double(days) * 43200)
        }
    }

    @Test func `an overlapping whole day cannot invent a rolling boundary total`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let formatter = DateFormatter()
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let usage = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: nil,
            last30DaysCostUSD: nil,
            historyDays: 30,
            daily: [.init(
                date: formatter.string(from: self.now.addingTimeInterval(-86400)),
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: 1000,
                costUSD: 10,
                modelsUsed: nil,
                modelBreakdowns: nil)],
            updatedAt: self.now)
        let reading = NativeOrbitAccountMetrics(usage: usage).summary(days: 1, now: self.now, calendar: calendar)
        #expect(reading.tokens == nil)
        #expect(reading.cost == nil)
        #expect(reading.isPartial)
    }

    @Test func `hourly receipts count the live partial hour but never leak it before the receipt`() throws {
        let hour = try #require(Calendar.current.dateInterval(of: .hour, for: self.now)?.start)
        let observed = hour.addingTimeInterval(1800)
        let usage = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: nil,
            last30DaysCostUSD: nil,
            historyDays: 30,
            daily: [],
            hourly: [
                .init(hour: hour.addingTimeInterval(-3600), totalTokens: 100, costUSD: 1),
                .init(hour: hour, totalTokens: 900, costUSD: 9),
            ],
            updatedAt: observed)
        let metrics = NativeOrbitAccountMetrics(usage: usage)
        #expect(metrics.summary(days: 1, now: observed).tokens == 1000)
        let past = metrics.summary(days: 1, now: observed.addingTimeInterval(-600))
        #expect(past.tokens == 100)
        #expect(past.isPartial)
    }

    private var snapshot: CostUsageTokenSnapshot {
        CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: nil,
            last30DaysCostUSD: nil,
            historyDays: 30,
            daily: [],
            quotaSlices: [
                .init(timestamp: self.now.addingTimeInterval(-93600), totalTokens: 100, costUSD: 1),
                .init(timestamp: self.now.addingTimeInterval(-80000), totalTokens: 200, costUSD: 2),
                .init(timestamp: self.now.addingTimeInterval(-600), totalTokens: 300, costUSD: 3),
                .init(timestamp: self.now.addingTimeInterval(600), totalTokens: 400, costUSD: 4),
            ],
            updatedAt: self.now)
    }
}
