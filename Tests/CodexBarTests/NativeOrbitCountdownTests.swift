import Foundation
import Testing
@testable import CodexBar

struct NativeOrbitCountdownTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func `monthly popup counts each remaining day rather than grouped menu bar units`() {
        let window = UsageWindow(
            id: "monthly",
            label: "Monthly",
            period: 30 * 86400,
            used: 0.2,
            countdown: ResetCountdown(
                units: 6,
                secondsPerUnit: 5 * 86400,
                nextReset: self.now.addingTimeInterval(18 * 86400)))
        let countdown = NativeOrbitCountdown(window: window)
        #expect(countdown.segments == 30)
        #expect(countdown.value(at: self.now) == 0.6)
        #expect(countdown.value(at: self.now.addingTimeInterval(86400)) == 17.0 / 30)
        #expect(countdown.value(at: self.now.addingTimeInterval(18 * 86400)) == 0)
    }

    @Test func `weekly and session segments correspond to days and hours`() {
        let fixtures: [(Double, Int, Double, Double)] = [
            (604_800.0, 7, 4 * 86400.0, 4.0 / 7),
            (18000, 5, 3 * 3600, 0.6),
            (86400, 24, 12 * 3600, 0.5),
        ]
        for (period, units, remaining, expected) in fixtures {
            let window = UsageWindow(
                id: "quota",
                label: "Quota",
                period: period,
                used: 0,
                countdown: ResetCountdown(
                    units: units,
                    secondsPerUnit: period / Double(units),
                    nextReset: self.now.addingTimeInterval(remaining)))
            let countdown = NativeOrbitCountdown(window: window)
            #expect(countdown.segments == units)
            #expect(countdown.value(at: self.now) == expected)
        }
    }

    @Test func `unknown deadline preserves known segment scale without inventing reset progress`() {
        let window = UsageWindow(
            id: "weekly",
            label: "Weekly",
            period: 604_800,
            used: nil,
            countdown: ResetCountdown(units: 7, secondsPerUnit: 86400, isReliable: false))
        let countdown = NativeOrbitCountdown(window: window)
        #expect(countdown.segments == 7)
        #expect(countdown.value(at: self.now) == nil)
    }
}
