import Foundation
import Testing
@testable import CodexBar

struct NativeOrbitRangeAndCountdownTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func window(
        _ id: String, period: TimeInterval, reset: TimeInterval?, units: Int = 7, scale: Bool = true) -> UsageWindow
    {
        UsageWindow(
            id: id,
            label: id,
            period: period,
            used: 0.5,
            countdown: ResetCountdown(
                units: scale ? units : 1,
                secondsPerUnit: scale ? period / Double(units) : 1,
                nextReset: reset.map(self.now.addingTimeInterval),
                isReliable: reset != nil && scale))
    }

    @Test func `only a lane with a reset schedule of its own keeps a countdown`() {
        let session = self.window("primary", period: 18000, reset: 3600, units: 5)
        let weekly = self.window("secondary", period: 604_800, reset: 86400)
        // Claude dates a model's share of the weekly limit a fraction of a second after the weekly reset itself.
        let fable = self.window("claude-weekly-scoped-fable", period: 604_800, reset: 86400.2)
        #expect(NativeOrbitCountdown.timedLanes([weekly, session, fable]) == ["secondary", "primary"])
        // The same period on another schedule is a limit of its own.
        let other = self.window("other", period: 604_800, reset: 3 * 86400)
        #expect(NativeOrbitCountdown.timedLanes([weekly, other]) == ["secondary", "other"])
        // Unknown deadlines on the same period are still one schedule; a deadline without a scale draws nothing.
        let unknown = self.window("secondary", period: 604_800, reset: nil)
        let unknownShare = self.window("tertiary", period: 604_800, reset: nil)
        #expect(NativeOrbitCountdown.timedLanes([unknown, unknownShare]) == ["secondary"])
        #expect(NativeOrbitCountdown.timedLanes([self.window("budget", period: 1, reset: 86400, scale: false)]).isEmpty)
        var never = weekly
        never.recovery = .none
        #expect(NativeOrbitCountdown.timedLanes([never]).isEmpty)
        // A share shown without its parent keeps the countdown: nothing else on the dial tells its time.
        #expect(NativeOrbitCountdown.timedLanes([session, fable]) == ["primary", "claude-weekly-scoped-fable"])
    }

    @Test func `a pinch scales the span continuously, down to an hour and up to a month`() {
        let day: TimeInterval = 86400
        // Spreading the fingers magnifies: less time in the same width.
        #expect(NativeOrbitRange.span(from: 7 * day, magnification: 1) == 7 * day)
        #expect(NativeOrbitRange.span(from: 7 * day, magnification: 2) == 3.5 * day)
        #expect(NativeOrbitRange.span(from: day, magnification: 4) == 6 * 3600)
        #expect(NativeOrbitRange.span(from: day, magnification: 1000) == 3600)
        #expect(NativeOrbitRange.span(from: 7 * day, magnification: 0.5) == 14 * day)
        #expect(NativeOrbitRange.span(from: 7 * day, magnification: 0.001) == 30 * day)
        #expect(NativeOrbitRange.span(from: 7 * day, magnification: .nan) == 7 * day)
        #expect(NativeOrbitRange.span(from: 7 * day, magnification: 0) == 7 * day)
        // It rests on whole hours or days, and on day, week or month when it is close to one.
        #expect(NativeOrbitRange.snapped(5.4 * 3600) == 5 * 3600)
        #expect(NativeOrbitRange.snapped(22.5 * 3600) == day)
        #expect(NativeOrbitRange.snapped(2.6 * day) == 3 * day)
        #expect(NativeOrbitRange.snapped(6.6 * day) == 7 * day)
        #expect(NativeOrbitRange.snapped(100) == 3600)
        // The corners total the whole days that cover what the chart shows.
        #expect(NativeOrbitRange.days(covering: 6 * 3600) == 1)
        #expect(NativeOrbitRange.days(covering: 3 * day) == 3)
        #expect(NativeOrbitRange.days(covering: 30 * day) == 30)
    }

    @Test func `the range control gains the pinched-to span and only that one`() {
        let day: TimeInterval = 86400
        #expect(NativeOrbitRange.segments(selected: day) == [day, 7 * day, 30 * day])
        #expect(NativeOrbitRange.segments(selected: 3 * day) == [day, 3 * day, 7 * day, 30 * day])
        #expect(NativeOrbitRange.segments(selected: 6 * 3600) == [6 * 3600, day, 7 * day, 30 * day])
        #expect(NativeOrbitRange.shortTitle(6 * 3600) == "6H")
        #expect(NativeOrbitRange.shortTitle(3 * day) == "3D")
        #expect(NativeOrbitRangeControl.title(21 * day) == "3W")
        #expect(NativeOrbitRangeControl.name(10 * day) == "Last 10 days")
        #expect(NativeOrbitRangeControl.name(3600) == "Last hour")
        // Day, week and month keep the widths they had; a fourth segment widens the control by one.
        #expect(NativeOrbitRangeControl.width(span: 7 * day, fullWords: false) == 102)
        #expect(NativeOrbitRangeControl.width(span: 7 * day, fullWords: true) == 180)
        #expect(NativeOrbitRangeControl.width(span: 6 * 3600, fullWords: false) == 135)
    }

    @MainActor @Test func `a pinch that comes to rest settles the range the corners total`() {
        let state = NativeOrbitPopupState()
        state.days = 7
        let sixHours: TimeInterval = 6 * 3600
        state.settle(span: 6.2 * 3600)
        #expect(state.days == 1)
        #expect(state.visibleSpan == sixHours)
        #expect(state.span == sixHours)
        state.settle(span: 2.9 * 86400)
        #expect(state.days == 3)
        #expect(state.visibleSpan == nil)
        // While the fingers move the span follows them; the marks stay as drawn until the pinch shows time they
        // do not cover, and then take in more than is showing so the next stretch needs no redraw.
        state.track(span: 2 * 86400)
        #expect(state.days == 3)
        #expect(state.span == 2 * 86400)
        #expect(state.plotSpan == 3 * 86400)
        state.track(span: 4 * 86400)
        #expect(state.plotSpan == 8 * 86400)
        state.settle(span: 5 * 3600)
        #expect(state.plotSpan == 5 * 3600)
        state.select(days: 1)
        #expect(state.visibleSpan == nil)
        #expect(state.span == 86400)
    }

    @Test func `a used reset fades evenly as it ages`() {
        func opacity(_ freshness: Double) -> Double {
            NativeOrbitResetSlot(state: .used(freshness: freshness)).inkOpacity
        }
        #expect(opacity(1) == 1)
        #expect(opacity(0.5) == 0.5)
        #expect(opacity(0.1) == 0.1)
        #expect(NativeOrbitResetSlot(state: .banked).inkOpacity == 1)
    }
}
