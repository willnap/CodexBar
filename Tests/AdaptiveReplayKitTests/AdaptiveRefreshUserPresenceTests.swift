import AdaptiveRefreshCore
import Foundation
import Testing

/// The gauges are always on screen, so a person using the Mac keeps readings current without opening the menu.
struct AdaptiveRefreshUserPresenceTests {
    private static let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func decision(
        menuAge: TimeInterval?,
        inputAge: TimeInterval?,
        lowPowerModeEnabled: Bool = false) -> AdaptiveRefreshPolicyCore.Decision
    {
        AdaptiveRefreshPolicyCore().nextDelay(for: AdaptiveRefreshPolicyCore.Input(
            now: Self.now,
            lastMenuOpenAt: menuAge.map { Self.now.addingTimeInterval(-$0) },
            lastUserActivityAt: inputAge.map { Self.now.addingTimeInterval(-$0) },
            lowPowerModeEnabled: lowPowerModeEnabled,
            thermalPressure: .nominal))
    }

    @Test
    func `presence caps an idle menu at the warm cadence`() {
        for menuAge in [nil, 2 * 3600.0, 10 * 3600.0] as [TimeInterval?] {
            let decision = self.decision(menuAge: menuAge, inputAge: 20)
            #expect(decision.reason == .userPresent)
            #expect(decision.delay == .seconds(5 * 60))
        }
    }

    @Test
    func `presence never slows a faster cadence`() {
        let decision = self.decision(menuAge: 60, inputAge: 20)
        #expect(decision.reason == .recentInteraction)
        #expect(decision.delay == .seconds(2 * 60))
    }

    @Test
    func `an unattended Mac keeps the idle table`() {
        #expect(self.decision(menuAge: nil, inputAge: nil).reason == .longIdle)
        #expect(self.decision(menuAge: nil, inputAge: 6 * 60).reason == .longIdle)
        #expect(self.decision(menuAge: 2 * 3600, inputAge: 6 * 60).reason == .idle)
    }

    @Test
    func `constrained power outranks presence`() {
        let decision = self.decision(menuAge: nil, inputAge: 20, lowPowerModeEnabled: true)
        #expect(decision.reason == .constrained)
        #expect(decision.delay == .seconds(30 * 60))
    }
}

/// A quota being consumed fast is read more often than attention alone would have it.
struct AdaptiveRefreshUsagePaceTests {
    private static let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private static let week: TimeInterval = 7 * 86400

    private func decision(
        pace: Double?,
        menuAge: TimeInterval? = nil,
        lowPowerModeEnabled: Bool = false) -> AdaptiveRefreshPolicyCore.Decision
    {
        AdaptiveRefreshPolicyCore().nextDelay(for: AdaptiveRefreshPolicyCore.Input(
            now: Self.now,
            lastMenuOpenAt: menuAge.map { Self.now.addingTimeInterval(-$0) },
            lastUserActivityAt: Self.now.addingTimeInterval(-20),
            usagePace: pace,
            lowPowerModeEnabled: lowPowerModeEnabled,
            thermalPressure: .nominal))
    }

    @Test
    func `a steady or unknown pace keeps the attention cadence`() {
        #expect(self.decision(pace: nil).reason == .userPresent)
        #expect(self.decision(pace: 1).delay == .seconds(5 * 60))
        #expect(self.decision(pace: .nan).reason == .userPresent)
    }

    @Test
    func `a moving quota is read every two minutes and a racing one every minute`() {
        #expect(self.decision(pace: 2).reason == .usageMoving)
        #expect(self.decision(pace: 2).delay == .seconds(2 * 60))
        #expect(self.decision(pace: 6).reason == .usageMoving)
        #expect(self.decision(pace: 12).reason == .usageRacing)
        #expect(self.decision(pace: 40).delay == .seconds(60))
        // Already on the two-minute cadence: only racing changes it.
        #expect(self.decision(pace: 3, menuAge: 30).reason == .recentInteraction)
        #expect(self.decision(pace: 13, menuAge: 30).delay == .seconds(60))
    }

    @Test
    func `constrained power outranks a racing quota`() {
        #expect(self.decision(pace: 40, lowPowerModeEnabled: true).reason == .constrained)
    }

    @Test
    func `pace is consumption relative to the window across recent readings`() {
        var tracker = UsageVelocityTracker()
        func note(_ used: Double, minutesAgo: Double, key: String = "codex|a|secondary", window: TimeInterval) {
            tracker.note(
                key: key, usedPercent: used, windowSeconds: window, at: Self.now.addingTimeInterval(-minutesAgo * 60))
        }
        // One reading, or two too close together, say nothing yet.
        note(40, minutesAgo: 20, window: Self.week)
        #expect(tracker.fastestPace(now: Self.now) == nil)
        note(40, minutesAgo: 18, window: Self.week)
        #expect(tracker.fastestPace(now: Self.now) == nil)
        // 1 % of a week in 20 minutes: the week would be gone in 33 hours, five times too fast.
        note(41, minutesAgo: 0, window: Self.week)
        #expect(abs((tracker.fastestPace(now: Self.now) ?? 0) - 5.04) < 0.01)

        // A five-hour window at 20 % an hour is exactly sustainable.
        note(10, minutesAgo: 15, key: "claude|a|primary", window: 5 * 3600)
        note(15, minutesAgo: 0, key: "claude|a|primary", window: 5 * 3600)
        #expect(abs((tracker.fastestPace(now: Self.now) ?? 0) - 5.04) < 0.01)
        tracker.retain(keys: ["claude|a|primary"])
        #expect(abs((tracker.fastestPace(now: Self.now) ?? 0) - 1) < 0.001)
    }

    @Test
    func `a reset starts the lane over and stale readings stop counting`() {
        var tracker = UsageVelocityTracker()
        func note(_ used: Double, minutesAgo: Double) {
            tracker.note(
                key: "k",
                usedPercent: used,
                windowSeconds: Self.week,
                at: Self.now.addingTimeInterval(-minutesAgo * 60))
        }
        note(90, minutesAgo: 25)
        note(96, minutesAgo: 12)
        // The window reset: the earlier climb is over.
        note(0, minutesAgo: 6)
        note(0, minutesAgo: 1)
        #expect(tracker.fastestPace(now: Self.now) == 0)
        // Nothing read for over half an hour: no pace at all.
        #expect(tracker.fastestPace(now: Self.now.addingTimeInterval(3600)) == nil)
    }
}
