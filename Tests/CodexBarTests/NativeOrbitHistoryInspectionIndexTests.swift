import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct NativeOrbitHistoryInspectionIndexTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func `prepared hit targets preserve source priority and exact timestamps`() {
        let index = NativeOrbitHistoryInspectionIndex(
            metricDates: [self.now.addingTimeInterval(-40)],
            spendingDates: [self.now.addingTimeInterval(-42), self.now.addingTimeInterval(-80)],
            futureEventDates: [self.now.addingTimeInterval(40)],
            resetDates: [self.now.addingTimeInterval(-120)],
            isolatedDates: [self.now.addingTimeInterval(-180)])
        let cases: [(TimeInterval, TimeInterval)] = [
            (-42, -40), // Metric readings retain precedence over closer spend samples.
            (-81, -80),
            (-119, -120),
            (-181, -180),
            (42, 40),
            (-95.25, -95.25), // Gaps keep continuous pointer precision.
            (17.75, 17.75),
        ]
        for (pointer, expected) in cases {
            #expect(index.date(at: self.now.addingTimeInterval(pointer), now: self.now, tolerance: 3)
                == self.now.addingTimeInterval(expected))
        }
    }

    @Test func `a measured instant just behind now still wins over a nearby future mark`() {
        let index = NativeOrbitHistoryInspectionIndex(
            metricDates: [self.now.addingTimeInterval(-1)],
            spendingDates: [],
            futureEventDates: [self.now.addingTimeInterval(1)],
            resetDates: [],
            isolatedDates: [])
        #expect(index.date(at: self.now.addingTimeInterval(1), now: self.now, tolerance: 3)
            == self.now.addingTimeInterval(-1))
    }

    @Test func `midpoint ties retain a later date when it was the first source target`() {
        let index = NativeOrbitHistoryInspectionIndex(
            metricDates: [],
            spendingDates: [],
            futureEventDates: [self.now.addingTimeInterval(20), self.now.addingTimeInterval(10)],
            resetDates: [],
            isolatedDates: [
                self.now.addingTimeInterval(-40),
                self.now.addingTimeInterval(-50),
                self.now.addingTimeInterval(-40),
            ])
        #expect(index.date(at: self.now.addingTimeInterval(15), now: self.now, tolerance: 6)
            == self.now.addingTimeInterval(20))
        #expect(index.date(at: self.now.addingTimeInterval(-45), now: self.now, tolerance: 6)
            == self.now.addingTimeInterval(-40))
    }

    @Test func `dense targets select nearest sources with stable original midpoint ties`() {
        let dates = (0..<100_000).reversed().map { self.now.addingTimeInterval(-Double($0)) }
        let index = NativeOrbitHistoryInspectionIndex(
            metricDates: dates, spendingDates: [], futureEventDates: [], resetDates: [], isolatedDates: [])
        #expect(index.date(at: self.now.addingTimeInterval(-54321.5), now: self.now, tolerance: 0.6)
            == self.now.addingTimeInterval(-54322))
        #expect(index.date(at: self.now.addingTimeInterval(-54321.125), now: self.now, tolerance: 0.2)
            == self.now.addingTimeInterval(-54321))
        #expect(index.date(at: self.now.addingTimeInterval(-54321.125), now: self.now, tolerance: 0.1)
            == self.now.addingTimeInterval(-54321.125))
        #expect(index.date(at: self.now, now: self.now, tolerance: 0) == self.now)
    }

    @Test func `static plot invalidates an interior correction while its latest sample stays unchanged`() {
        func widget(_ middle: Double) -> NativeOrbitHistoryWidget {
            NativeOrbitHistoryWidget(histories: [.init(
                name: .init(rawValue: "nativeQuota:primary"),
                windowMinutes: 300,
                entries: [
                    .init(capturedAt: self.now.addingTimeInterval(-120), usedPercent: 10, resetsAt: nil),
                    .init(capturedAt: self.now.addingTimeInterval(-60), usedPercent: middle, resetsAt: nil),
                    .init(capturedAt: self.now, usedPercent: 30, resetsAt: nil),
                ])], now: self.now)
        }
        let original = widget(20)
        let corrected = widget(25)
        let lanes = original.lanes
        #expect(original.plotKey(lanes) == original.plotKey(lanes))
        #expect(original.plotKey(lanes).lanes == corrected.plotKey(corrected.lanes).lanes)
        #expect(original.plotKey(lanes) != corrected.plotKey(corrected.lanes))
    }

    @Test func `static plot invalidates changed labels cadence and calendar semantics`() throws {
        var original = NativeOrbitHistoryWidget(histories: [], now: self.now)
        original.calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let key = original.plotKey([])
        var changed = original
        changed.quotaLabels = ["nativeQuota:primary": "Daily"]
        #expect(changed.plotKey([]) != key)
        changed = original
        changed.quotaWindows = ["nativeQuota:primary": .init(
            usedPercent: 20, windowMinutes: 1440, resetsAt: self.now, resetDescription: nil)]
        #expect(changed.plotKey([]) != key)
        changed = original
        changed.calendar.timeZone = try #require(TimeZone(secondsFromGMT: 19800))
        #expect(changed.plotKey([]) != key)
        changed = original
        changed.preparedObservationDates = [self.now.addingTimeInterval(-30)]
        #expect(changed.plotKey([]) != key)
    }
}
