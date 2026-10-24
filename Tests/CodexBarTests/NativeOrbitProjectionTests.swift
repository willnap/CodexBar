import Foundation
import SwiftUI
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct NativeOrbitProjectionTests {
    /// 2027-01-15 12:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_800_014_400)
    private let hour: TimeInterval = 3600

    // MARK: - Activity

    @Test func `an account is in use when a quota reading rose within the last half hour`() {
        let reset = self.now.addingTimeInterval(2 * self.hour)
        let rising = self.lanes([self.quota("nativeQuota:primary", minutes: 300, [
            (-1200, 20, reset), (-600, 25, reset), (-60, 25, reset),
        ])])
        #expect(NativeOrbitActivity.lastActivity(lanes: rising, metrics: .empty, now: self.now)
            == self.now.addingTimeInterval(-600))

        let flat = self.lanes([self.quota("nativeQuota:primary", minutes: 300, [
            (-1200, 25, reset), (-600, 25, reset),
        ])])
        #expect(NativeOrbitActivity.lastActivity(lanes: flat, metrics: .empty, now: self.now) == nil)

        let stale = self.lanes([self.quota("nativeQuota:primary", minutes: 300, [
            (-3600, 20, reset), (-2400, 30, reset), (-60, 30, reset),
        ])])
        #expect(NativeOrbitActivity.lastActivity(lanes: stale, metrics: .empty, now: self.now) == nil)
    }

    @Test func `a reading higher than one from an earlier window is not use`() {
        let old = self.now.addingTimeInterval(-1200)
        let lanes = self.lanes([self.quota("nativeQuota:primary", minutes: 300, [
            (-1500, 10, old), (-600, 30, old.addingTimeInterval(5 * self.hour)),
        ])])
        #expect(NativeOrbitActivity.lastActivity(lanes: lanes, metrics: .empty, now: self.now) == nil)
    }

    @Test func `a rolling window starting with use counts although its reset moved`() {
        let lanes = self.lanes([self.quota("nativeQuota:secondary", minutes: 10080, [
            (-900, 0, self.now.addingTimeInterval(-900 + 7 * 86400)),
            (-300, 2, self.now.addingTimeInterval(-600 + 7 * 86400)),
        ])])
        #expect(NativeOrbitActivity.lastActivity(lanes: lanes, metrics: .empty, now: self.now)
            == self.now.addingTimeInterval(-300))
    }

    @Test func `dated local usage of the account makes it active and unattributed local usage does not`() {
        let slices = [CostUsageTimedEntry(
            timestamp: self.now.addingTimeInterval(-300),
            totalTokens: 1200,
            costUSD: nil)]
        let own = NativeOrbitAccountMetrics(usage: self.usage(daily: [], slices: slices))
        #expect(NativeOrbitActivity.lastActivity(lanes: [], metrics: own, now: self.now)
            == self.now.addingTimeInterval(-300))
        var shared = NativeOrbitAccountMetrics()
        shared.localCostUsage = NativeOrbitLocalUsage(
            snapshot: self.usage(daily: [], slices: slices), scope: .localMachine, bucketTimeZoneIdentifier: "UTC")
        #expect(NativeOrbitActivity.lastActivity(lanes: [], metrics: shared, now: self.now) == nil)
        shared.localCostUsage?.isAccountAttributed = true
        #expect(NativeOrbitActivity.lastActivity(lanes: [], metrics: shared, now: self.now) != nil)
        let old = [CostUsageTimedEntry(timestamp: self.now.addingTimeInterval(-3600), totalTokens: 1200, costUSD: nil)]
        #expect(NativeOrbitActivity.lastActivity(
            lanes: [], metrics: NativeOrbitAccountMetrics(usage: self.usage(daily: [], slices: old)), now: self.now)
            == nil)
    }

    // MARK: - Lane projection

    @Test func `projected usage follows the window pace and agrees with the menu's run-out time`() throws {
        // A 5 h window three hours in at 90 %: 30 % an hour, out in 20 minutes.
        let reset = self.now.addingTimeInterval(2 * self.hour)
        let lane = try self.projectedLane(used: [(-600, 85), (0, 90)], reset: reset)
        #expect(lane.rateSource == .windowPace)
        #expect(abs(lane.rate * self.hour - 30) < 0.0001)
        let pace = try #require(UsagePace.weekly(
            window: RateWindow(usedPercent: 90, windowMinutes: 300, resetsAt: reset, resetDescription: nil),
            now: self.now,
            defaultWindowMinutes: 300))
        let eta = try #require(pace.etaSeconds)
        let exhaustion = try #require(lane.exhaustion)
        #expect(abs(exhaustion.timeIntervalSince(self.now) - eta) < 0.001)
        #expect(abs(lane.used(at: self.now.addingTimeInterval(600)) - 95) < 0.0001)
    }

    @Test func `an exhausted window stays empty until its reset and refills at the same pace`() throws {
        let reset = self.now.addingTimeInterval(2 * self.hour)
        let lane = try self.projectedLane(used: [(-600, 85), (0, 90)], reset: reset)
        // Clamped at 0 % available after it runs out.
        #expect(lane.available(at: self.now.addingTimeInterval(self.hour)) == 0)
        #expect(lane.available(at: reset.addingTimeInterval(-1)) == 0)
        // From the reset on, the new window.
        #expect(lane.available(at: reset) == 100)
        #expect(abs(lane.available(at: reset.addingTimeInterval(self.hour)) - 70) < 0.0001)
        #expect(lane.nextReset(after: self.now) == reset)
        #expect(lane.nextReset(after: reset) == reset.addingTimeInterval(5 * self.hour))
        // Later windows run out too and start over at their own resets.
        #expect(lane.available(at: reset.addingTimeInterval(4 * self.hour)) == 0)
        #expect(lane.available(at: reset.addingTimeInterval(5 * self.hour)) == 100)

        let points = lane.points(through: reset.addingTimeInterval(self.hour))
        #expect(points.map { $0.date.timeIntervalSince(self.now).rounded() } == [0, 1200, 7200, 7200, 10800])
        #expect(points.map { ($0.available * 1000).rounded() / 1000 } == [10, 0, 0, 100, 70])
        #expect(points.map(\.isResetEdge) == [false, false, true, true, false])
    }

    @Test func `an account not in use holds its reading until the reset, then the window is full`() throws {
        let reset = self.now.addingTimeInterval(2 * self.hour)
        let history = self.quota("nativeQuota:primary", minutes: 300, [(-600, 40, reset), (0, 40, reset)])
        let lane = try #require(try self.projected(history, active: false))
        #expect(lane.rate == 0)
        #expect(lane.rateSource == .idle)
        #expect(lane.available(at: self.now.addingTimeInterval(self.hour)) == 60)
        #expect(lane.available(at: reset) == 100)
        #expect(lane.available(at: reset.addingTimeInterval(10 * self.hour)) == 100)
        #expect(lane.points(through: reset.addingTimeInterval(self.hour)).map(\.available) == [60, 60, 100, 100])
    }

    @Test func `an unstarted rolling window has no scheduled reset and stale readings are not projected`() throws {
        let unstarted = self.quota("nativeQuota:secondary", minutes: 10080, [
            (-60, 0, self.now.addingTimeInterval(-60 + 7 * 86400)),
        ])
        let lane = try #require(try self.projected(unstarted, active: true))
        #expect(lane.reset == nil)
        #expect(lane.available(at: self.now.addingTimeInterval(8 * 86400)) == 100)

        let stale = self.quota("nativeQuota:primary", minutes: 300, [
            (-3 * self.hour, 40, self.now.addingTimeInterval(self.hour)),
        ])
        #expect(try self.projected(stale, active: true) == nil)
    }

    @Test func `early in a window the trend of its readings sets the pace`() throws {
        // Half an hour into a week: too early for the window's pace.
        let reset = self.now.addingTimeInterval(7 * 86400 - 1800)
        let lane = try self.projectedLane(
            used: [(-1200, 1), (0, 3)], reset: reset, minutes: 10080, id: "nativeQuota:secondary")
        #expect(lane.rateSource == .observedTrend)
        #expect(abs(lane.rate * 1200 - 2) < 0.0001)
    }

    // MARK: - Shared axis

    @Test func `projecting centers now and gives the future the past's span in every column`() {
        // The recorded side is exactly the selected trailing span, mirrored into the future.
        for days in [1, 7, 30] {
            let bounds = NativeOrbitChartAxis.projectingBounds(now: self.now, days: days)
            #expect(bounds.end.timeIntervalSince(bounds.start) == 2 * NativeOrbitChartAxis.span(days: days))
            #expect(self.now.timeIntervalSince(bounds.start) == Double(days) * 86400)
            #expect(bounds.end.timeIntervalSince(self.now) == Double(days) * 86400)
            let center = bounds.start.addingTimeInterval(NativeOrbitChartAxis.span(days: days))
            #expect(center == self.now)
        }

        let reset = self.now.addingTimeInterval(2 * self.hour)
        let state = NativeOrbitPopupState()
        state.now = self.now
        state.accounts = [
            self.account(id: "busy", histories: [self.quota("nativeQuota:primary", minutes: 300, [
                (-600, 20, reset), (0, 25, reset),
            ])]),
            self.account(id: "idle", histories: [self.quota("nativeQuota:primary", minutes: 300, [
                (-600, 50, reset), (0, 50, reset),
            ])]),
        ]
        #expect(state.isProjecting)
        #expect(state.projection(for: state.accounts[0]).isActive)
        #expect(!state.projection(for: state.accounts[1]).isActive)
        #expect(state.chartEnd.timeIntervalSince(state.chartStart) == 2 * NativeOrbitChartAxis.span(days: state.days))
        #expect(abs(state.chartEnd.timeIntervalSince(state.now) - state.now.timeIntervalSince(state.chartStart)) <=
            3600)
        let widgets = state.accounts.map {
            NativeOrbitHistoryWidget(
                histories: $0.history,
                now: state.now,
                days: state.days,
                preparedLanes: state.renderLanes(for: $0),
                projection: state.projection(for: $0),
                isProjecting: state.isProjecting)
        }
        #expect(widgets.map(\.chartEnd) == [state.chartEnd, state.chartEnd])
        #expect(widgets[0].axisDates == [state.chartStart, state.now, state.chartEnd])
        #expect(widgets[0].axisLabel(state.now) == L("Now"))

        state.accounts = [state.accounts[1]]
        #expect(!state.isProjecting)
        #expect(state.chartEnd == state.now)
    }

    @Test func `the now line sits at the center while projecting and the right edge otherwise`() {
        let frame = CGRect(x: 10, y: 0, width: 200, height: 100)
        let projecting = NativeOrbitHistoryWidget(histories: [], now: self.now, isProjecting: true)
        let recorded = NativeOrbitHistoryWidget(histories: [], now: self.now)
        // Edges sit on whole hours, so now is within half an hour of the center (1/96 of a 48-hour plot).
        #expect(abs(projecting.plotX(self.now, in: frame) - frame.midX) <= frame.width / 96 + 0.001)
        #expect(abs(recorded.plotX(self.now, in: frame) - frame.maxX) < 0.001)
        #expect(abs(projecting.plotX(projecting.start, in: frame) - frame.minX) < 0.001)
        #expect(abs(projecting.plotX(projecting.chartEnd, in: frame) - frame.maxX) < 0.001)
        // A pointer ahead of now selects that instant; the past keeps its own snapping.
        let ahead = self.now.addingTimeInterval(3 * self.hour)
        #expect(projecting.inspectionDate(at: ahead, plotWidth: 200) == ahead)
    }

    @Test func `hovering next to a scheduled mark selects its instant`() {
        let reset = self.now.addingTimeInterval(2 * self.hour)
        let state = NativeOrbitPopupState()
        state.now = self.now
        state.accounts = [self.account(id: "busy", histories: [self.quota("nativeQuota:primary", minutes: 300, [
            (-600, 20, reset), (0, 25, reset),
        ])])]
        let account = state.accounts[0]
        let projection = state.projection(for: account)
        #expect(projection.events.first?.kind == .windowReset)
        #expect(projection.events.first?.date == reset)
        let widget = NativeOrbitHistoryWidget(
            histories: account.history,
            now: state.now,
            preparedLanes: state.lanes(for: account),
            projection: projection,
            isProjecting: true)
        // Session windows are long enough against the projected day that every reset in them is marked.
        #expect(widget.projectedEvents.map(\.date) == [0, 5, 10, 15, 20].map {
            reset.addingTimeInterval($0 * self.hour)
        })
        #expect(widget.inspectionDate(at: reset.addingTimeInterval(30), plotWidth: 200) == reset)
    }

    // MARK: - Clock

    @Test func `a minute passing keeps the prepared lanes and redoes only what reads the clock`() {
        let reset = self.now.addingTimeInterval(2 * self.hour)
        let state = NativeOrbitPopupState()
        state.now = self.now
        state.accounts = [self.account(id: "busy", histories: [self.quota("nativeQuota:primary", minutes: 300, [
            (-600, 20, reset), (0, 25, reset),
        ])])]
        let account = state.accounts[0]
        let lanes = state.lanes(for: account)
        #expect(state.projection(for: account).now == self.now)
        let later = self.now.addingTimeInterval(5 * 60)
        state.now = later
        #expect(Self.sameStorage(state.lanes(for: account), lanes), "Lanes change with their history, range or day")
        #expect(state.projection(for: account).now == later)
        state.now = self.now.addingTimeInterval(24 * self.hour)
        #expect(!Self.sameStorage(state.lanes(for: account), lanes))
    }

    @Test func `warning lights are reused within the popup's minute clock`() {
        let state = NativeOrbitPopupState()
        state.now = self.now
        var account = self.account(id: "busy", histories: [])
        account.warnings = [.init(.update, .opportunity, "CodexBar 9.0 is available.")]
        state.accounts = [account]
        let lights = state.warningLights(for: state.accounts[0])
        #expect(!lights.isEmpty)
        state.now = self.now.addingTimeInterval(10)
        #expect(Self.sameStorage(state.warningLights(for: state.accounts[0]), lights))
        state.now = self.now.addingTimeInterval(70)
        #expect(!Self.sameStorage(state.warningLights(for: state.accounts[0]), lights))
    }

    @Test func `a rebuilt row equal to the shown one keeps its prepared charts`() {
        let reset = self.now.addingTimeInterval(2 * self.hour)
        func busy(latest: Double) -> NativeOrbitAccountPresentation {
            self.account(id: "busy", histories: [self.quota("nativeQuota:primary", minutes: 300, [
                (-600, 20, reset), (0, latest, reset),
            ])])
        }
        let state = NativeOrbitPopupState()
        state.now = self.now
        state.accounts = [busy(latest: 25)]
        let lanes = state.lanes(for: state.accounts[0])
        // A store rebuild yields equal readings in new storage.
        state.accounts = [busy(latest: 25)]
        #expect(Self.sameStorage(state.lanes(for: state.accounts[0]), lanes))
        state.accounts = [busy(latest: 30)]
        #expect(!Self.sameStorage(state.lanes(for: state.accounts[0]), lanes))
        #expect(state.lanes(for: state.accounts[0]).first?.samples.last?.available == 70)
    }

    private static func sameStorage<Element>(_ first: [Element], _ second: [Element]) -> Bool {
        first.count == second.count && first.withUnsafeBufferPointer { lhs in
            second.withUnsafeBufferPointer { lhs.baseAddress == $0.baseAddress }
        }
    }

    // MARK: - Future readings

    @Test func `dials show each window's predicted usage and the next reset at a future instant`() throws {
        let reset = self.now.addingTimeInterval(2 * self.hour)
        let account = self.account(id: "busy", histories: [self.quota("nativeQuota:primary", minutes: 300, [
            (-600, 27, reset), (0, 30, reset),
        ])])
        let state = NativeOrbitPopupState()
        state.now = self.now
        state.accounts = [account]
        let projection = state.projection(for: account)
        func window(at date: Date) throws -> UsageWindow {
            try #require(NativeOrbitHistoricalInspection.windows(
                account: account,
                date: date,
                now: self.now,
                days: 1,
                preparedLanes: state.lanes(for: account),
                projection: projection).first)
        }
        // 30 % three hours into the window: 10 % an hour.
        let inHour = try window(at: self.now.addingTimeInterval(self.hour))
        #expect(abs((inHour.usedFraction ?? -1) - 0.4) < 0.0001)
        #expect(inHour.countdown?.nextReset == reset)
        // After the reset: the next window, half an hour in.
        let afterReset = try window(at: reset.addingTimeInterval(1800))
        #expect(abs((afterReset.usedFraction ?? -1) - 0.05) < 0.0001)
        #expect(afterReset.countdown?.nextReset == reset.addingTimeInterval(5 * self.hour))
        #expect(afterReset.countdown?.isReliable == true)
        // Live and history stay untouched.
        #expect(NativeOrbitHistoricalInspection.windows(account: account, date: nil, now: self.now, days: 1)
            == account.gauge.resolvedWindows)
    }

    @Test func `period totals ahead preserve unknown usage at a rolling boundary`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let midnight = calendar.startOfDay(for: self.now)
        let today = self.entry(self.now, tokens: 1_200_000, cost: 12, calendar: calendar)
        let yesterday = self.entry(midnight.addingTimeInterval(-3600), tokens: 500_000, cost: 5, calendar: calendar)
        let usage = self.usage(daily: [yesterday, today], slices: [])
        let reset = self.now.addingTimeInterval(2 * self.hour)
        let busy = self.quota("nativeQuota:primary", minutes: 300, [(-600, 20, reset), (0, 25, reset)])
        var account = self.account(id: "busy", histories: [busy])
        account.metrics = NativeOrbitAccountMetrics(usage: usage)
        let lanes = self.lanes([busy])
        // Twelve hours into the day at 1.2M tokens: 100k an hour.
        let projection = NativeOrbitAccountProjection.make(
            account: account,
            lanes: lanes,
            now: self.now,
            days: 1,
            start: midnight,
            end: self.now.addingTimeInterval(86400))
        #expect(projection.isActive)
        let evening = projection.summary(days: 1, at: self.now.addingTimeInterval(6 * self.hour), calendar: calendar)
        #expect(evening.summary.tokens == 1_800_000)
        #expect(evening.recordedTokens == 1_200_000)
        #expect(abs((evening.summary.cost ?? 0) - 18) < 0.0001)
        // Tomorrow's trailing day cuts through today's aggregate; its recorded part cannot be placed exactly.
        let tomorrow = projection.summary(days: 1, at: midnight.addingTimeInterval(30 * self.hour), calendar: calendar)
        #expect(tomorrow.summary.tokens == nil)
        #expect(tomorrow.recordedTokens == nil)

        // 7D two days ahead keeps the five recorded days still inside it.
        let week = NativeOrbitAccountProjection.make(
            account: account,
            lanes: lanes,
            now: self.now,
            days: 7,
            start: midnight.addingTimeInterval(-6 * 86400),
            end: self.now.addingTimeInterval(7 * 86400))
        let ahead = week.summary(days: 7, at: self.now.addingTimeInterval(2 * 86400), calendar: calendar)
        #expect(ahead.recordedTokens == 1_700_000)

        // Not in use: nothing more is projected.
        var idle = self.account(id: "idle", histories: [self.quota("nativeQuota:primary", minutes: 300, [
            (-600, 25, reset), (0, 25, reset),
        ])])
        idle.metrics = NativeOrbitAccountMetrics(usage: usage)
        let quiet = NativeOrbitAccountProjection.make(
            account: idle,
            lanes: self.lanes(idle.history),
            now: self.now,
            days: 1,
            start: midnight,
            end: self.now.addingTimeInterval(86400))
        #expect(!quiet.isActive)
        #expect(quiet.summary(days: 1, at: self.now.addingTimeInterval(6 * self.hour), calendar: calendar)
            .summary.tokens == 1_200_000)
        #expect(quiet.summary(days: 1, at: midnight.addingTimeInterval(30 * self.hour), calendar: calendar)
            .summary.tokens == nil)
    }

    @Test func `banked resets expire and an additional usage cycle starts over ahead`() {
        let spend = ProviderCostSnapshot(
            used: 20,
            limit: 100,
            currencyCode: "USD",
            resetsAt: self.now.addingTimeInterval(86400),
            updatedAt: self.now)
        var metrics = NativeOrbitAccountMetrics(reportedSpend: spend)
        metrics.bankedResets = 3
        metrics.usedResets = 1
        let inventory = NativeOrbitResetObservation(
            availableExpirations: [self.now.addingTimeInterval(self.hour), self.now.addingTimeInterval(3 * 86400), nil],
            usedExpirations: [self.now.addingTimeInterval(2 * self.hour)])
        let soon = metrics.projected(at: self.now.addingTimeInterval(1800), inventory: inventory)
        #expect(soon.bankedResets == 3)
        #expect(soon.usedResets == 1)
        #expect(soon.reportedSpend?.used == 20)
        let later = metrics.projected(at: self.now.addingTimeInterval(2 * 86400), inventory: inventory)
        #expect(later.bankedResets == 2)
        #expect(later.usedResets == 0)
        #expect(later.nextResetCreditExpiry == self.now.addingTimeInterval(3 * 86400))
        #expect(later.reportedSpend?.used == 0)
        #expect(later.extraUsageFraction == 0)
        // Without a current inventory the live count holds.
        #expect(metrics.projected(at: self.now.addingTimeInterval(2 * 86400), inventory: nil).bankedResets == 3)
        // Providers without banked resets stay not applicable.
        #expect(NativeOrbitAccountMetrics().projected(at: self.now, inventory: inventory).bankedResets == nil)
    }

    @Test func `scheduled events ahead are typed and merged per instant`() {
        let reset = self.now.addingTimeInterval(2 * self.hour)
        let lanes = [
            NativeOrbitLaneProjection(
                id: "nativeQuota:secondary",
                origin: self.now,
                originUsed: 50,
                rate: 0,
                rateSource: .idle,
                period: 604_800,
                reset: reset,
                lineStart: self.now),
            NativeOrbitLaneProjection(
                id: "nativeQuota:tertiary",
                origin: self.now,
                originUsed: 10,
                rate: 0,
                rateSource: .idle,
                period: 604_800,
                reset: reset.addingTimeInterval(30),
                lineStart: self.now),
        ]
        var live = NativeOrbitAccountMetrics(reportedSpend: ProviderCostSnapshot(
            used: 5,
            limit: 50,
            currencyCode: "USD",
            resetsAt: self.now.addingTimeInterval(3 * self.hour),
            updatedAt: self.now))
        live.reportedPlanExpiry = self.now.addingTimeInterval(5 * self.hour)
        let events = NativeOrbitAccountProjection.events(
            lanes: lanes,
            live: live,
            inventory: NativeOrbitResetObservation(availableExpirations: [
                self.now.addingTimeInterval(4 * self.hour), self.now.addingTimeInterval(4 * self.hour),
            ]),
            now: self.now,
            end: self.now.addingTimeInterval(12 * self.hour))
        #expect(events.map(\.kind) == [.windowReset, .additionalUsageCycle, .bankedResetExpiry, .planExpiry])
        #expect(events.first?.laneIDs == ["nativeQuota:secondary", "nativeQuota:tertiary"])
        #expect(events[2].quantity == 2)
        #expect(NativeOrbitProjectionStyle.eventSymbol(.windowReset) == nil)
        #expect(NativeOrbitProjectionStyle.eventSymbol(.bankedResetExpiry) == "hourglass.circle")
    }

    @Test func `the future accent is the same hue, more saturated`() throws {
        let base = NSColor(srgbRed: 204 / 255, green: 124 / 255, blue: 94 / 255, alpha: 1)
        let vivid = try #require(NativeOrbitProjectionStyle.vivid(base).usingColorSpace(.sRGB))
        #expect(abs(vivid.hueComponent - base.hueComponent) < 0.001)
        #expect(vivid.saturationComponent > base.saturationComponent + 0.2)
        let gray = NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        #expect(NativeOrbitProjectionStyle.vivid(gray).saturationComponent < 0.02)
    }

    @Test func `crossing now steps the accent at once and distance carries the rest`() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let start = now.addingTimeInterval(-86400)
        let end = now.addingTimeInterval(86400)
        func offset(_ seconds: TimeInterval) -> Double? {
            NativeOrbitProjectionStyle.temporalOffset(now.addingTimeInterval(seconds), now: now, start: start, end: end)
        }
        #expect(NativeOrbitProjectionStyle.temporalOffset(nil, now: now, start: start, end: end) == nil)
        // A minute either side already reads as past or future.
        #expect(offset(60) == 0.1)
        #expect(offset(-60) == -0.1)
        #expect(offset(43200) == 0.5)
        #expect(offset(-86400) == -1)
        #expect(offset(200_000) == 1)

        let base = NSColor(srgbRed: 204 / 255, green: 124 / 255, blue: 94 / 255, alpha: 1)
        func saturation(_ offset: Double) throws -> CGFloat {
            let color = NSColor(NativeOrbitProjectionStyle.temporalAccent(Color(nsColor: base), offset: offset))
            return try #require(color.usingColorSpace(.sRGB)).saturationComponent
        }
        let near = try saturation(0.1)
        let far = try saturation(1)
        #expect(near > base.saturationComponent + 0.1, "Crossing into the future steps up at once")
        #expect(far > near, "and intensifies further ahead")
        let recent = try saturation(-0.1)
        let distant = try saturation(-1)
        #expect(recent < base.saturationComponent - 0.05, "Crossing into the past steps down at once")
        #expect(distant < recent, "and fades further back")
        #expect(distant > 0.15, "but keeps enough colour to tell lanes apart")
    }

    @Test func `every hover step reading the same moment gets an equal accent`() {
        // The chart's marks are keyed by the accent; an unequal copy at each step would redraw all of them.
        let live = Color(nsColor: NSColor(srgbRed: 204 / 255, green: 124 / 255, blue: 94 / 255, alpha: 1))
        for offset in [-1, -0.3, 0.1, 0.8] {
            #expect(NativeOrbitProjectionStyle.temporalAccent(live, offset: offset)
                == NativeOrbitProjectionStyle.temporalAccent(live, offset: offset))
        }
        #expect(NativeOrbitProjectionStyle.temporalAccent(live, offset: 0.2)
            != NativeOrbitProjectionStyle.temporalAccent(live, offset: 0.3))
        #expect(NativeOrbitProjectionStyle.temporalAccent(live, offset: nil) == live)
    }

    @Test func `projected points keep their keys when the span grows`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(3600)
        let day: [NativeOrbitLaneProjection.Point] = [
            .init(date: now, available: 60),
            .init(date: reset, available: 20),
            .init(date: reset, available: 100, isResetEdge: true),
            .init(date: now.addingTimeInterval(86400), available: 40),
        ]
        let week = Array(day.prefix(3)) + [
            .init(date: now.addingTimeInterval(7200), available: 90),
            .init(date: now.addingTimeInterval(7 * 86400), available: 10),
        ]
        let dayKeys = NativeOrbitHistoryWidget.keyedPoints(day).map(\.key)
        let weekKeys = NativeOrbitHistoryWidget.keyedPoints(week).map(\.key)
        #expect(Set(dayKeys).count == day.count, "The two points of a reset at one instant stay distinct")
        #expect(Array(weekKeys.prefix(3)) == Array(dayKeys.prefix(3)), "Shared points keep their keys")
        #expect(!weekKeys.contains(dayKeys[3]), "A point that moved is a new point, not a neighbour's")
    }

    @Test func `longer ranges blur their projection harder`() throws {
        let day = NativeOrbitProjectionStyle.chartBlurRadii(days: 1)
        let week = NativeOrbitProjectionStyle.chartBlurRadii(days: 7)
        let month = NativeOrbitProjectionStyle.chartBlurRadii(days: 30)
        #expect(day.first == 0 && week.first == 0 && month.first == 0, "Sharp at now")
        #expect(try #require(day.last) < week.last! && week.last! < month.last!)
        #expect(NativeOrbitProjectionStyle.dialBlur(fraction: 0, days: 1) == 0)
        #expect(NativeOrbitProjectionStyle.dialBlur(fraction: 0.5, days: 1)
            < NativeOrbitProjectionStyle.dialBlur(fraction: 1, days: 1))
        #expect(NativeOrbitProjectionStyle.dialBlur(fraction: 1, days: 1)
            < NativeOrbitProjectionStyle.dialBlur(fraction: 1, days: 30))
    }

    // MARK: - Fixtures

    private func projectedLane(
        used: [(TimeInterval, Double)],
        reset: Date,
        minutes: Int = 300,
        id: String = "nativeQuota:primary") throws -> NativeOrbitLaneProjection
    {
        let history = self.quota(id, minutes: minutes, used.map { ($0.0, $0.1, reset) })
        return try #require(try self.projected(history, active: true))
    }

    private func projected(
        _ history: PlanUtilizationSeriesHistory,
        active: Bool) throws -> NativeOrbitLaneProjection?
    {
        let lane = try #require(self.lanes([history]).first)
        return NativeOrbitAccountProjection.project(lane, now: self.now, active: active)
    }

    private func quota(
        _ name: String,
        minutes: Int,
        _ readings: [(TimeInterval, Double, Date?)]) -> PlanUtilizationSeriesHistory
    {
        PlanUtilizationSeriesHistory(
            name: .init(rawValue: name),
            windowMinutes: minutes,
            entries: readings.map {
                .init(capturedAt: self.now.addingTimeInterval($0.0), usedPercent: $0.1, resetsAt: $0.2)
            })
    }

    private func lanes(_ histories: [PlanUtilizationSeriesHistory]) -> [NativeOrbitHistoryWidget.Lane] {
        NativeOrbitHistoryWidget(histories: histories, now: self.now, provider: .claude).lanes
    }

    private func usage(daily: [CostUsageDailyReport.Entry], slices: [CostUsageTimedEntry]) -> CostUsageTokenSnapshot {
        CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: nil,
            last30DaysCostUSD: nil,
            historyDays: 30,
            bucketTimeZoneIdentifier: "UTC",
            coverageThrough: self.now,
            costProvenance: .listPriceEstimate,
            daily: daily,
            quotaSlices: slices,
            updatedAt: self.now)
    }

    private func entry(_ date: Date, tokens: Int, cost: Double, calendar: Calendar) -> CostUsageDailyReport.Entry {
        CostUsageDailyReport.Entry(
            date: CostUsageLocalDay.key(from: date, calendar: calendar),
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: tokens,
            costUSD: cost,
            modelsUsed: nil,
            modelBreakdowns: nil)
    }

    private func account(id: String, histories: [PlanUtilizationSeriesHistory]) -> NativeOrbitAccountPresentation {
        var gauge = ComputeGauge.State()
        gauge.provider = "claude"
        gauge.windows = [UsageWindow(
            id: "primary",
            label: "Session",
            period: 18000,
            used: 0.25,
            countdown: ResetCountdown(units: 5, secondsPerUnit: 3600, nextReset: self.now.addingTimeInterval(7200)))]
        return NativeOrbitAccountPresentation(
            id: id,
            label: id,
            email: nil,
            symbol: "person",
            isActive: false,
            canActivate: false,
            gauge: gauge,
            updatedAt: self.now,
            history: histories,
            odometer: nil,
            odometerHelp: nil,
            statusText: nil,
            selection: .none)
    }
}
