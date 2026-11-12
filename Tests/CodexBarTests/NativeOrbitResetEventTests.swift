import AppKit
import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct NativeOrbitResetEventTests {
    private let now = Date(timeIntervalSince1970: 1_791_800_000)

    // MARK: - Classification

    @Test func `a countdown that runs out is a window reset at its scheduled time`() {
        let reset = self.now.addingTimeInterval(-7200)
        let session = self.lane("nativeQuota:primary", minutes: 300, [
            (-9000, 40, reset),
            (-6900, 0, nil),
            // An idle window that runs out restores nothing and is not drawn.
            (-3600, 0, self.now.addingTimeInterval(-1800)),
            (-1200, 0, nil),
        ])
        let events = NativeOrbitResetEvent.events(
            quotaHistories: [session], metricHistories: [], provider: .claude, now: self.now)
        #expect(events.map(\.kind) == [.natural])
        #expect(events.first?.date == reset)
        #expect(events.first?.earliest == nil)
        #expect(events.first?.laneIDs == ["nativeQuota:primary"])
    }

    @Test func `a Codex redemption time types an early reset as banked and dates it exactly`() throws {
        let redeemed = self.now.addingTimeInterval(-3450)
        let before = self.codexInventory(at: -3600, status: .available, redeemedAt: nil)
        let after = self.codexInventory(at: -3300, status: .redeemed, redeemedAt: redeemed)
        let metrics = [before, after].reduce([PlanUtilizationSeriesHistory]()) {
            UsageStore.nativeOrbitHistoryIncludingCurrentSnapshot($0, provider: .codex, snapshot: $1)
        }
        let weeklyReset = self.now.addingTimeInterval(4 * 86400)
        let quota = [
            self.lane("nativeQuota:primary", minutes: 300, [
                (-3600, 100, self.now.addingTimeInterval(3600)), (-3300, 0, nil),
            ]),
            self.lane("nativeQuota:secondary", minutes: 10080, [
                (-3600, 100, weeklyReset), (-3300, 1, self.now.addingTimeInterval(7 * 86400)),
            ]),
        ]
        let events = NativeOrbitResetEvent.events(
            quotaHistories: quota, metricHistories: metrics, provider: .codex, now: self.now)
        // One redemption restored every Codex rate limit at once.
        let event = try #require(events.only)
        #expect(event.kind == .manual)
        #expect(event.kind.isBankable)
        #expect(event.date == redeemed)
        #expect(event.earliest == nil)
        #expect(event.laneIDs == ["nativeQuota:primary", "nativeQuota:secondary"])
    }

    @Test func `a Claude inventory whose used resets rose types an early reset as banked`() throws {
        let grantEnd = self.now.addingTimeInterval(10 * 86400)
        let histories = [
            self.claude(at: -7200, used: 40, weeklyReset: 3 * 86400, available: [grantEnd], usedResets: []),
            self.claude(at: -3600, used: 100, weeklyReset: 3 * 86400, available: [grantEnd], usedResets: []),
            self.claude(at: -3300, used: 0, weeklyReset: nil, available: [], usedResets: [grantEnd]),
        ].reduce([PlanUtilizationSeriesHistory]()) {
            UsageStore.nativeOrbitHistoryIncludingCurrentSnapshot($0, provider: .claude, snapshot: $1)
        }
        let events = NativeOrbitResetEvent.events(
            quotaHistories: histories.filter(\.name.isNativeQuotaObservation),
            metricHistories: histories.filter(\.name.isNativeMetricObservation),
            provider: .claude,
            now: self.now)
        let event = try #require(events.only)
        #expect(event.kind == .manual)
        #expect(event.date == self.now.addingTimeInterval(-3300))
        #expect(event.earliest == self.now.addingTimeInterval(-3600))
        #expect(event.laneIDs == ["nativeQuota:secondary"])
        #expect(NativeOrbitResetEvent.redemptions(in: histories).map(\.quantity) == [1])
    }

    @Test func `a prepared history counts redemptions once and each range only filters them`() {
        let grantEnd = self.now.addingTimeInterval(10 * 86400)
        let histories = [
            self.claude(at: -7200, used: 40, weeklyReset: 3 * 86400, available: [grantEnd], usedResets: []),
            self.claude(at: -3600, used: 100, weeklyReset: 3 * 86400, available: [grantEnd], usedResets: []),
            self.claude(at: -3300, used: 0, weeklyReset: nil, available: [], usedResets: [grantEnd]),
        ].reduce([PlanUtilizationSeriesHistory]()) {
            UsageStore.nativeOrbitHistoryIncludingCurrentSnapshot($0, provider: .claude, snapshot: $1)
        }
        let prepared = NativeOrbitPreparedMetricHistory(history: histories)
        #expect(prepared.resetRedemptions.map(\.date) == NativeOrbitResetEvent.redemptions(in: histories).map(\.date))
        for days in [1, 7, 30] {
            let plain = NativeOrbitResetEvent.redemptions(in: histories, days: days, now: self.now)
            let reused = NativeOrbitResetEvent.redemptions(in: histories, days: days, now: self.now, prepared: prepared)
            #expect(reused.map(\.date) == plain.map(\.date))
            #expect(reused.map(\.quantity) == plain.map(\.quantity))
        }
        // A history the preparation was not made from is counted from its own readings.
        let other = NativeOrbitPreparedMetricHistory(history: [])
        #expect(NativeOrbitResetEvent.redemptions(in: histories, days: 7, now: self.now, prepared: other).count
            == NativeOrbitResetEvent.redemptions(in: histories, days: 7, now: self.now).count)
    }

    @Test func `an early reset with the same inventory on both sides is the provider's`() throws {
        let grantEnd = self.now.addingTimeInterval(10 * 86400)
        let histories = [
            self.claude(at: -3600, used: 80, weeklyReset: 3 * 86400, available: [grantEnd], usedResets: []),
            self.claude(at: -3300, used: 0, weeklyReset: nil, available: [grantEnd], usedResets: []),
        ].reduce([PlanUtilizationSeriesHistory]()) {
            UsageStore.nativeOrbitHistoryIncludingCurrentSnapshot($0, provider: .claude, snapshot: $1)
        }
        let event = try #require(NativeOrbitResetEvent.events(
            quotaHistories: histories.filter(\.name.isNativeQuotaObservation),
            metricHistories: histories.filter(\.name.isNativeMetricObservation),
            provider: .claude,
            now: self.now).only)
        #expect(event.kind == .provider)
        #expect(!event.kind.isBankable)
        #expect(event.title(provider: .claude) == "Reset early by Anthropic")
        #expect(event.title(provider: .codex) == "Reset early by OpenAI")
    }

    @Test func `an early reset without inventory around it keeps an unknown cause unless others saw it`() throws {
        let weekly = self.lane("nativeQuota:secondary", minutes: 10080, [
            (-3600, 100, self.now.addingTimeInterval(86400)), (-1800, 0, self.now.addingTimeInterval(7 * 86400)),
        ])
        let alone = try #require(NativeOrbitResetEvent.events(
            quotaHistories: [weekly], metricHistories: [], provider: .codex, now: self.now).only)
        #expect(alone.kind == .early)
        #expect(alone.date == self.now.addingTimeInterval(-1800))
        #expect(alone.earliest == self.now.addingTimeInterval(-3600))
        #expect(alone.help(provider: .codex, laneLabels: ["Weekly"]).hasPrefix("Reset early, cause unknown: Weekly, "))

        // Another account of the provider started over in the same bracket with nothing redeemed.
        let peer = self.lane("nativeQuota:secondary", minutes: 10080, [
            (-3590, 36, self.now.addingTimeInterval(2 * 86400)), (-1790, 0, self.now.addingTimeInterval(7 * 86400)),
        ])
        let shared = try #require(NativeOrbitResetEvent.events(
            quotaHistories: [weekly],
            metricHistories: [],
            provider: .codex,
            peerHistories: [[peer]],
            now: self.now).only)
        #expect(shared.kind == .provider)
        // A peer reset hours later is a different event.
        let laterPeer = self.lane("nativeQuota:secondary", minutes: 10080, [
            (-900, 36, self.now.addingTimeInterval(2 * 86400)), (-600, 0, self.now.addingTimeInterval(7 * 86400)),
        ])
        #expect(NativeOrbitResetEvent.events(
            quotaHistories: [weekly],
            metricHistories: [],
            provider: .codex,
            peerHistories: [[laterPeer]],
            now: self.now).map(\.kind) == [.early])
        // A provider without banked resets resets every early window itself.
        #expect(NativeOrbitResetEvent.events(
            quotaHistories: [weekly], metricHistories: [], provider: .kimi, now: self.now).map(\.kind) == [.provider])
    }

    @Test func `quota rounding and slow rolling decreases are not resets`() {
        let weekly = self.lane("nativeQuota:secondary", minutes: 10080, [
            (-5400, 60, self.now.addingTimeInterval(86400)),
            (-3600, 57, self.now.addingTimeInterval(86400)),
            (-1800, 40, self.now.addingTimeInterval(86400)),
            (-600, 39.5, self.now.addingTimeInterval(86400)),
        ])
        #expect(NativeOrbitResetEvent.events(
            quotaHistories: [weekly], metricHistories: [], provider: .kimi, now: self.now).isEmpty)
    }

    @Test func `a redemption without a recorded quota drop still registers on the timeline`() throws {
        let redeemed = self.now.addingTimeInterval(-3000)
        let metrics = UsageStore.nativeOrbitHistoryIncludingCurrentSnapshot(
            [], provider: .codex, snapshot: self.codexInventory(at: -600, status: .redeemed, redeemedAt: redeemed))
        let event = try #require(NativeOrbitResetEvent.events(
            quotaHistories: [], metricHistories: metrics, provider: .codex, now: self.now).only)
        #expect(event.kind == .manual)
        #expect(event.date == redeemed)
        #expect(event.laneIDs.isEmpty)
    }

    // MARK: - Chart

    @Test func `chart marks and help spell out each reset type`() {
        let redeemed = self.now.addingTimeInterval(-3450)
        var histories = [
            self.codexInventory(at: -3600, status: .available, redeemedAt: nil),
            self.codexInventory(at: -3300, status: .redeemed, redeemedAt: redeemed),
        ].reduce([PlanUtilizationSeriesHistory]()) {
            UsageStore.nativeOrbitHistoryIncludingCurrentSnapshot($0, provider: .codex, snapshot: $1)
        }
        histories += [
            self.lane("nativeQuota:primary", minutes: 300, [
                (-30000, 50, self.now.addingTimeInterval(-28000)), (-27000, 0, nil),
                (-3600, 100, self.now.addingTimeInterval(3600)), (-3300, 0, nil),
            ]),
            self.lane("nativeQuota:secondary", minutes: 10080, [
                (-20000, 90, self.now.addingTimeInterval(86400)), (-19000, 0, self.now.addingTimeInterval(6 * 86400)),
                (-3600, 100, self.now.addingTimeInterval(6 * 86400)), (
                    -3300,
                    1,
                    self.now.addingTimeInterval(7 * 86400)),
            ]),
        ]
        let widget = NativeOrbitHistoryWidget(histories: histories, now: self.now, days: 7, provider: .codex)
        let lanes = widget.lanes
        let events = NativeOrbitHistoryWidget.resetEvents(lanes)
        // The inventory brackets only the redemption, so the earlier weekly drop keeps an unknown cause.
        #expect(events.map(\.kind) == [.natural, .early, .manual])
        // A planned window reset has only its rule; resets that broke the schedule carry a glyph.
        #expect(events.map { NativeOrbitHistoryWidget.resetSymbol($0.kind) } == [
            nil, "questionmark.circle.fill", "arrow.uturn.backward.circle.fill",
        ])
        #expect(NativeOrbitHistoryWidget.resetSymbol(.provider) == "building.2.crop.circle.fill")
        // Recorded reset rules are solid; dashes mean projected.
        #expect(NativeOrbitResetEvent.Kind.allCases
            .allSatisfy { NativeOrbitHistoryWidget.resetStroke($0).dash.isEmpty })
        // Glyphs ride inside the plot; its height never changes for them.
        #expect(NativeOrbitHistoryWidget.topPadding(lanes) == 3)
        // Hovering onto a mark names it in the pill: a planned reset by its window, the others by their cause.
        #expect(widget.markedEvents(lanes).map(\.title) == ["Session reset", "Early reset", "Reset by you"])
        #expect(widget.markedEvents(lanes).map(\.symbol) == events
            .map { NativeOrbitHistoryWidget.resetSymbol($0.kind) })
        // Hovering a point off a reset snaps onto it, or onto a dial reading beside it (readings win); either way
        // the mark stays within the point the pill names it from.
        let point = widget.chartEnd.timeIntervalSince(widget.start) / 196
        let marks = widget.markedEvents(lanes)
        for (event, mark) in zip(events, marks) {
            let snapped = widget.inspectionDate(at: event.date.addingTimeInterval(point), plotWidth: 196)
            #expect(abs(snapped.timeIntervalSince(event.date)) <= point)
            let named = marks.filter { abs($0.date.timeIntervalSince(snapped)) <= point }
                .min { abs($0.date.timeIntervalSince(snapped)) < abs($1.date.timeIntervalSince(snapped)) }
            #expect(named == mark)
        }
        #expect(widget.inspectionDate(at: events[0].date.addingTimeInterval(point), plotWidth: 196) == events[0].date)
        let labels = events.map { widget.resetAccessibilityLabel($0, lanes: lanes) }
        #expect(labels[0].hasPrefix("Window reset: Session, "))
        #expect(labels[1].hasPrefix("Reset early, cause unknown: Weekly, "))
        #expect(labels[2].hasPrefix("You used a banked reset: Session, Weekly, "))

        // A reset that is reclassified redraws the equatable plot.
        let unexplained = NativeOrbitHistoryWidget(
            histories: histories.filter { !$0.name.isNativeMetricObservation },
            now: self.now,
            days: 7,
            provider: .codex)
        #expect(unexplained.plotKey(unexplained.lanes).resetEvents != widget.plotKey(lanes).resetEvents)
        #expect(unexplained.plotKey(unexplained.lanes) != widget.plotKey(lanes))
        // Quota-only periods keep the original plot geometry.
        let quietLane = self.lane("nativeQuota:primary", minutes: 300, [
            (-30000, 50, self.now.addingTimeInterval(-28000)), (-27000, 0, nil),
        ])
        let quiet = NativeOrbitHistoryWidget(histories: [quietLane], now: self.now, days: 7)
        #expect(NativeOrbitHistoryWidget.resetEvents(quiet.lanes).map(\.kind) == [.natural])
        #expect(NativeOrbitHistoryWidget.topPadding(quiet.lanes) == 3)
    }

    // MARK: - Complications at an instant

    @Test func `the banked reset corner restores the inventory as of the hovered instant`() {
        let grantEnd = self.now.addingTimeInterval(10 * 86400)
        let histories = [
            self.claude(at: -3600, used: 100, weeklyReset: 3 * 86400, available: [grantEnd], usedResets: []),
            self.claude(at: -3300, used: 0, weeklyReset: nil, available: [], usedResets: [grantEnd]),
        ].reduce([PlanUtilizationSeriesHistory]()) {
            UsageStore.nativeOrbitHistoryIncludingCurrentSnapshot($0, provider: .claude, snapshot: $1)
        }
        func corner(_ offset: TimeInterval) -> (NativeOrbitResetCornerState, String) {
            let date = self.now.addingTimeInterval(offset)
            let metrics = NativeOrbitAccountMetrics.empty.at(date, observedAt: self.now, history: histories)
            let state = NativeOrbitResetCornerState.resolve(provider: .claude, metrics: metrics)
            let used = NativeOrbitResetEvent.redemptions(in: histories, days: 7, now: date)
            return (state, NativeOrbitInstruments.resetHelp(
                state,
                banked: metrics.bankedResetDetails,
                recentlyUsed: used.map(\.date),
                earlier: nil,
                gauges: [],
                provider: .claude,
                moment: .inspecting,
                now: self.now))
        }
        #expect(corner(-3700).0 == .unknown)
        #expect(corner(-3700).1 == "No banked-reset reading for this moment")
        #expect(corner(-3500).0 == .inventory(available: 1, used: 0))
        #expect(corner(-3500).1 == "1 reset")
        let after = corner(-3200)
        #expect(after.0 == .inventory(available: 0, used: 1))
        #expect(after.1.hasPrefix("No resets left\nUsed one at "))
        #expect(after.0.glyphs == [false])
    }

    @Test func `a used reset fades over a week into an empty place`() {
        typealias Slot = NativeOrbitResetSlot
        let inventory = NativeOrbitResetCornerState.inventory(available: 1, used: 1)
        func slots(usedAgo days: Double?) -> [Slot] {
            inventory.slots(recentlyUsed: days.map { [self.now.addingTimeInterval(-$0 * 86400)] } ?? [], now: self.now)
        }
        // Just used: the reset's dashed ghost in the same full colour. Spent, not switched off.
        let fresh = slots(usedAgo: 0)
        #expect(fresh == [Slot(state: .banked), Slot(state: .used(freshness: 1))])
        #expect(fresh[1].isSpent)
        #expect(!fresh[0].isSpent)
        #expect(fresh[1].inkOpacity == 1)
        #expect(fresh[1].emptyOpacity == 0)
        #expect(fresh[0].emptyOpacity == 0)
        // The ghost fades evenly with every day, in step with its blur, as the empty place comes through.
        let midweek = slots(usedAgo: 3.5)
        #expect(midweek[1].state == .used(freshness: 0.5))
        #expect(midweek[1].inkOpacity == 0.5)
        #expect(slots(usedAgo: 6.5)[1].inkOpacity < 0.1)
        #expect(midweek[1].emptyOpacity == 0.5)
        // It is in focus when just used and goes out of focus as it ages; a banked or absent reset never blurs.
        #expect(fresh[1].blurRadius == 0)
        #expect(midweek[1].blurRadius == Slot.oldestBlur / 2)
        #expect(slots(usedAgo: 6.5)[1].blurRadius > midweek[1].blurRadius)
        #expect(fresh[0].blurRadius == 0)
        #expect(Slot(state: .empty).blurRadius == 0)
        // Mostly drained of colour, so it cannot pass for one in stock.
        #expect(Slot.spentSaturation < 0.5)
        // The ghost's dashes close evenly round the circle. A part reset's are as thick and as long as a full
        // one's: it has fewer of them.
        let full = NativeOrbitResetGlyph(size: 17, isPart: false, tint: .orange)
        let part = NativeOrbitResetGlyph(size: 17, isPart: true, tint: .orange)
        for glyph in [full, part, NativeOrbitResetGlyph(size: 11, isPart: true, tint: .orange)] {
            let dash = glyph.ghostStroke.dash
            let count = (.pi * glyph.ghostDiameter / (dash[0] + dash[1])).rounded()
            #expect(abs((dash[0] + dash[1]) * count - .pi * glyph.ghostDiameter) < 0.001)
            #expect(count >= 5)
            #expect(dash[0] > 0 && dash[1] > glyph.ghostLineWidth)
        }
        #expect(part.ghostLineWidth == full.ghostLineWidth)
        #expect(abs(part.ghostStroke.dash[0] - full.ghostStroke.dash[0]) < 0.4)
        #expect(Slot(state: .empty).emptyOpacity == 1)
        #expect(slots(usedAgo: 7.5)[1] == Slot(state: .empty))
        #expect(slots(usedAgo: nil)[1] == Slot(state: .empty))
        #expect(Slot(state: .empty).inkOpacity == 0)
        // A use the inventory no longer counts (Codex forgets after a day) still fades for its week.
        let forgotten = NativeOrbitResetCornerState.inventory(available: 0, used: 0)
            .slots(recentlyUsed: [self.now.addingTimeInterval(-2 * 86400)], now: self.now)
        #expect(forgotten.count == 1)
        #expect(forgotten[0].inkOpacity > 0)
        // No resets at all is one empty place; a use dated after the shown instant has not happened yet.
        let none = NativeOrbitResetCornerState.inventory(available: 0, used: 0)
        #expect(none.slots(recentlyUsed: [], now: self.now) == [Slot(state: .empty)])
        #expect(none.slots(recentlyUsed: [self.now.addingTimeInterval(60)], now: self.now) == [Slot(state: .empty)])
        // The corner is an inventory, not a log of every use.
        let many = (0..<9).map { self.now.addingTimeInterval(-Double($0) * 3600) }
        #expect(none.slots(recentlyUsed: many, now: self.now).count == Slot.maximumSpent)
        #expect(NativeOrbitResetCornerState.unknown.slots(recentlyUsed: many, now: self.now).isEmpty)
    }

    @Test func `the reset tooltip counts, dates, and names a kind only when it is not an ordinary reset`() {
        let expiry = self.now.addingTimeInterval(20 * 86400)
        let later = self.now.addingTimeInterval(40 * 86400)
        let given = self.now.addingTimeInterval(-2 * 86400)
        let gauges = [
            NativeOrbitGaugeLane(id: "secondary", title: "Weekly", tint: .orange),
            NativeOrbitGaugeLane(id: "claude-weekly-scoped-fable", title: "Fable", tint: .brown),
        ]
        func help(
            _ banked: [ProviderReset],
            used: [Date] = [],
            earlier: Date? = nil,
            moment: NativeOrbitReadingMoment = .live) -> [String]
        {
            NativeOrbitInstruments.resetHelp(
                .inventory(available: banked.count, used: 0),
                banked: banked,
                recentlyUsed: used,
                earlier: earlier,
                gauges: gauges,
                provider: .claude,
                moment: moment,
                now: self.now).components(separatedBy: "\n")
        }
        let ordinary = ProviderReset(isAvailable: true, expiresAt: expiry, grantedAt: given)
        let when = NativeOrbitTooltip.moment(expiry, now: self.now)
        // Ordinary resets: the count and when they lapse, then when the last was given. Nothing about kinds.
        let two = help([ordinary, ordinary])
        #expect(two == ["2 resets, expire \(when)", "Last given " + NativeOrbitTooltip.at(given, now: self.now)])
        #expect(help([ordinary]).first == "1 reset, expires \(when)")
        #expect(help([ordinary, ProviderReset(isAvailable: true, expiresAt: later)]).first
            == "2 resets, next expires \(when)")
        #expect(help([ProviderReset(isAvailable: true, expiresAt: nil)]) == ["1 reset"])
        // What was used lately comes before when one was given; an older use is still the last use.
        let hourAgo = self.now.addingTimeInterval(-3600)
        #expect(help([ordinary], used: [hourAgo])[1] == "Used one " + NativeOrbitTooltip.at(hourAgo, now: self.now))
        #expect(help([ordinary], used: [hourAgo, given])[1].hasPrefix("Used 2 this week, last "))
        #expect(help([ordinary], earlier: given)[1] == "Last used " + NativeOrbitTooltip.at(given, now: self.now))
        #expect(help([], used: [hourAgo]).first == "No resets left")
        #expect(help([ordinary], moment: .projecting).first == "1 reset left by then, expires \(when)")
        // A reset that clears the main gauge and an inner one with it is still an ordinary reset.
        let full = ProviderReset(
            isAvailable: true, expiresAt: expiry, scope: .windows(["secondary", "claude-weekly-scoped-fable"]))
        #expect(help([full]).count == 1)
        // One that clears only the inner gauge says so, and what it gives back.
        let fable = ProviderReset(
            isAvailable: true,
            expiresAt: expiry,
            scope: .windows(["claude-weekly-scoped-fable"]),
            givesBackWiderUsage: true)
        // Straight under its count: what it refills, and what it gives back.
        let refills = "refills Fable and the Weekly it used"
        #expect(help([fable]) == ["1 Fable reset, expires \(when)", "It \(refills)"])
        #expect(help([fable, fable]) == ["2 Fable resets, expire \(when)", "Each \(refills)"])
        // Beside ordinary ones each kind gets its own count and end, and the ordinary one is called full.
        let last = ProviderReset(isAvailable: true, expiresAt: later, grantedAt: given)
        #expect(help([last, fable, fable]) == [
            "1 full reset, expires \(NativeOrbitTooltip.moment(later, now: self.now))",
            "2 Fable resets, expire \(when)",
            "Each \(refills)",
            "Last given " + NativeOrbitTooltip.at(given, now: self.now),
        ])
        // With part resets about, the one used this week is named too.
        let spent = ProviderReset(isAvailable: false, expiresAt: later)
        let named = NativeOrbitInstruments.resetHelp(
            .inventory(available: 1, used: 1),
            banked: [fable],
            used: [spent],
            recentlyUsed: [hourAgo],
            earlier: nil,
            gauges: gauges,
            provider: .claude,
            moment: .live,
            now: self.now).components(separatedBy: "\n")
        #expect(named.last == "Used a full reset " + NativeOrbitTooltip.at(hourAgo, now: self.now))
        // The gauge's own title is "Fable only" while it is off the dial; the reset is still a Fable reset.
        let offDial = NativeOrbitInstruments.resetHelp(
            .inventory(available: 1, used: 0),
            banked: [ProviderReset(isAvailable: true, expiresAt: nil, scope: .windows(["claude-weekly-scoped-fable"]))],
            recentlyUsed: [],
            earlier: nil,
            gauges: [gauges[0]],
            laneTitles: ["claude-weekly-scoped-fable": "Fable only"],
            provider: .claude,
            moment: .live,
            now: self.now)
        #expect(offDial == "1 Fable reset\nIt refills Fable only")
        // The corner draws it for that gauge; a full reset, or one for a gauge the dial lacks, for the main one
        // or for a part of it.
        let ids = gauges.map(\.id)
        #expect(NativeOrbitResetComplication.lane(fable.scope, gauges: ids) == "claude-weekly-scoped-fable")
        #expect(NativeOrbitResetComplication.lane(full.scope, gauges: ids) == nil)
        #expect(NativeOrbitResetComplication.lane(.everything, gauges: ids) == nil)
        #expect(NativeOrbitResetComplication.lane(.windows(["other"]), gauges: ids) == "other")
        let slots = NativeOrbitResetCornerState.inventory(available: 2, used: 0).slots(
            recentlyUsed: [], now: self.now, bankedLanes: [nil, "claude-weekly-scoped-fable"])
        #expect(slots.map(\.lane) == [nil, "claude-weekly-scoped-fable"])
    }

    @Test func `a reset for an inner gauge takes that gauge's colour and is drawn smaller`() {
        #expect(NativeOrbitResetLaneStyle(tint: .orange, isOutermost: true).scale == 1)
        let inner = NativeOrbitResetLaneStyle(tint: .orange, isOutermost: false).scale
        // Half the area: perceptually half the size.
        #expect(abs(inner * inner - 0.5) < 0.03)
        // Exactly half the area, with its arrow cut at the size and weight that measure a full reset's stroke.
        let full = NativeOrbitResetGlyph(size: 17, isPart: false, tint: .orange)
        let part = NativeOrbitResetGlyph(size: 17, isPart: true, tint: .orange)
        #expect(abs(part.discDiameter * part.discDiameter / (full.discDiameter * full.discDiameter) - 0.5) < 0.001)
        #expect(abs(full.discDiameter - 17.17) < 0.01)
        #expect(NativeOrbitResetGlyph.partArrowScale == 0.735)
    }

    @Test func `resets are spaced by the room between them, not by their centres`() {
        func gaps(_ parts: [Bool]) -> [CGFloat] {
            let places = NativeOrbitResetGlyph.places(parts: parts, size: 17, pitch: 25)
            let radii = parts.map { NativeOrbitResetGlyph(size: 17, isPart: $0, tint: .clear).discDiameter / 2 }
            return (1..<places.count).map { places[$0] - places[$0 - 1] - radii[$0] - radii[$0 - 1] }
        }
        // Full resets alone sit exactly where the even pitch put them.
        let full = NativeOrbitResetGlyph.places(parts: [false, false, false], size: 17, pitch: 25)
        #expect(full.map { ($0 * 1000).rounded() / 1000 } == [-25, 0, 25])
        // Beside or between part resets the room is about the same, a little less for the smaller pair, where
        // even centres left two part resets almost twice the room of two full ones.
        let mixed = gaps([true, true, false])
        let even = gaps([false, false])[0]
        #expect(mixed[0] < mixed[1] && mixed[1] < even)
        #expect(mixed[0] > even * 0.8)
        #expect(25 - NativeOrbitResetGlyph(size: 17, isPart: true, tint: .clear).discDiameter > even * 1.6)
        // The run stays centred on the corner, and one reset sits at its middle.
        let places = NativeOrbitResetGlyph.places(parts: [true, true, false], size: 17, pitch: 25)
        #expect(abs((places.first ?? 0) + (places.last ?? 0)) < 0.001)
        #expect(NativeOrbitResetGlyph.places(parts: [true], size: 17, pitch: 25) == [0])
        #expect(NativeOrbitResetGlyph.places(parts: [], size: 17, pitch: 25).isEmpty)
    }

    @Test func `zero banked resets read the same for every provider and not applicable is distinct`() {
        var codex = NativeOrbitAccountMetrics.empty
        codex.bankedResets = 0
        var claude = codex
        claude.usedResets = 1
        let codexState = NativeOrbitResetCornerState.resolve(provider: .codex, metrics: codex)
        let claudeState = NativeOrbitResetCornerState.resolve(provider: .claude, metrics: claude)
        #expect(codexState.glyphs == [false])
        #expect(claudeState.glyphs == [false])
        #expect(NativeOrbitResetCornerState.inventory(available: 2, used: 1).glyphs == [true, true, false])
        #expect(NativeOrbitResetCornerState.resolve(provider: .codex, metrics: .empty) == .unknown)
        #expect(NativeOrbitResetCornerState.resolve(provider: .kimi, metrics: .empty) == .notApplicable)
        #expect(NativeOrbitResetCornerState.notApplicable.glyphs.isEmpty)
    }

    @Test func `the additional usage icon is slashed only when it does not apply`() {
        func icon(
            _ metrics: NativeOrbitAccountMetrics,
            moment: NativeOrbitReadingMoment = .live,
            history: [PlanUtilizationSeriesHistory] = []) -> NativeOrbitExtraUsageIconState
        {
            NativeOrbitInstruments.extraUsageIcon(
                metrics,
                creditUsage: metrics.recordedCreditUsage(days: 1, now: self.now),
                moment: moment,
                history: history)
        }
        var metrics = NativeOrbitAccountMetrics.empty
        metrics.reportedSpend = .init(used: 0, limit: 0, currencyCode: "USD", isDisabled: true, updatedAt: self.now)
        #expect(icon(metrics) == .notApplicable)
        metrics.reportedSpend = .init(used: 0, limit: 50, currencyCode: "USD", updatedAt: self.now)
        #expect(icon(metrics) == .zero)
        metrics.reportedSpend = .init(used: 5, limit: 50, currencyCode: "USD", updatedAt: self.now)
        #expect(icon(metrics) == .active)
        // The gauge draws what is left, as the dial's other gauges do.
        #expect(metrics.extraUsageFraction == 0.1)
        #expect(metrics.extraUsageLeftFraction == 0.9)
        metrics.reportedSpend = .init(used: 0, limit: 50, currencyCode: "USD", updatedAt: self.now)
        #expect(metrics.extraUsageLeftFraction == 1)
        // Claude reports a plan's monthly credits as nothing used of the cap while flagging them out of credits.
        // The gauge follows used and limit, as Claude's own usage page does; the flag is reported in words.
        metrics.reportedSpend = .init(
            used: 0, limit: 200, currencyCode: "USD", period: "Monthly", isOutOfFunds: true, updatedAt: self.now)
        #expect(icon(metrics) == .zero)
        #expect(metrics.extraUsageFraction == 0)
        #expect(metrics.extraUsageLeftFraction == 1)
        let all = NativeOrbitInstruments.money(200, currency: "USD")
        #expect(NativeOrbitInstruments.extraUsageHelp(metrics, days: 1, now: self.now)
            == "\(all) left of \(all) additional usage this month\nThe provider has it paused: out of credits")
        // Without a limit there is nothing to draw a share of.
        metrics.reportedSpend = .init(used: 3, limit: 0, currencyCode: "USD", updatedAt: self.now)
        #expect(metrics.extraUsageLeftFraction == nil)
        var balanceOnly = NativeOrbitAccountMetrics.empty
        balanceOnly.reportedBalance = .init(value: 0, unit: "Credits", isWorkspace: false, updatedAt: self.now)
        #expect(icon(balanceOnly) == .zero)
        #expect(icon(.empty) == .notApplicable)
        #expect(icon(.empty, moment: .loading) == .unknown)
        let spendLane = PlanUtilizationSeriesHistory(name: "nativeMetric:spend", windowMinutes: 0, entries: [
            .init(
                capturedAt: self.now.addingTimeInterval(-86400),
                usedPercent: 0,
                resetsAt: nil,
                nativeMetrics: .init()),
        ])
        #expect(icon(.empty, moment: .inspecting, history: [spendLane]) == .unknown)
        #expect(icon(.empty, moment: .inspecting) == .notApplicable)
    }

    @Test func `a recorded turned-off allowance restores as turned off`() {
        let captured = self.now.addingTimeInterval(-600)
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: .init(
                used: 0, limit: 0, currencyCode: "USD", period: "Monthly", isDisabled: true, updatedAt: captured),
            updatedAt: captured)
        let histories = UsageStore.nativeOrbitHistoryIncludingCurrentSnapshot([], provider: .claude, snapshot: snapshot)
        let restored = NativeOrbitAccountMetrics.empty.at(captured, observedAt: self.now, history: histories)
        #expect(restored.reportedSpend?.isDisabled == true)
        #expect(NativeOrbitInstruments.extraUsageIcon(
            restored, creditUsage: nil, moment: .inspecting, history: histories) == .notApplicable)
    }

    @Test func `glyphs without a native slash variant get the drawn slash layer`() {
        #expect(!NativeOrbitSlashableGlyph.hasSlashVariant(NativeOrbitResetComplication.symbol))
        #expect(!NativeOrbitSlashableGlyph.hasSlashVariant(NativeOrbitExtraUsageComplication.symbol))
        #expect(NativeOrbitSlashableGlyph.hasSlashVariant("bell"))
        #expect(NativeOrbitSlashableGlyph.hasSlashVariant("bell.fill"))
    }

    @Test func `a drawn slash and its glyph are one template image, inked as one symbol`() throws {
        for (name, size) in [
            (NativeOrbitResetComplication.symbol, 17.0),
            (NativeOrbitExtraUsageComplication.symbol, 16),
        ] {
            let template = try #require(NativeOrbitSlashableGlyph.slashedTemplate(name, size: size, weight: .medium))
            #expect(template.isTemplate)
            let glyph = try #require(NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: size, weight: .medium)))
            #expect(template.size.width >= glyph.size.width && template.size.height >= glyph.size.height)
            // Made once per symbol and size.
            #expect(NativeOrbitSlashableGlyph.slashedTemplate(name, size: size, weight: .medium) === template)
            // Against the plain glyph on the same canvas: a clearance cut out of it, and a slash drawn in.
            let slashed = try Self.coverage(template, canvas: template.size)
            let plain = try Self.coverage(glyph, canvas: template.size)
            #expect(zip(plain, slashed).contains { $0 && !$1 }, "\(name) has a clearance")
            #expect(zip(plain, slashed).contains { !$0 && $1 } || name.hasSuffix(".fill"), "\(name) has a slash")
        }
    }

    /// Which pixels `image`, centred on `canvas` at 2x, covers.
    private static func coverage(_ image: NSImage, canvas: NSSize) throws -> [Bool] {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(canvas.width * 2),
            pixelsHigh: Int(canvas.height * 2),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0))
        bitmap.size = canvas
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(
            x: (canvas.width - image.size.width) / 2,
            y: (canvas.height - image.size.height) / 2,
            width: image.size.width,
            height: image.size.height))
        NSGraphicsContext.restoreGraphicsState()
        return (0..<bitmap.pixelsHigh).flatMap { y in
            (0..<bitmap.pixelsWide).map { x in (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 }
        }
    }

    // MARK: - Fixtures

    private func lane(
        _ name: String,
        minutes: Int,
        _ points: [(TimeInterval, Double, Date?)]) -> PlanUtilizationSeriesHistory
    {
        .init(name: .init(rawValue: name), windowMinutes: minutes, entries: points.map {
            .init(capturedAt: self.now.addingTimeInterval($0.0), usedPercent: $0.1, resetsAt: $0.2)
        })
    }

    private func codexInventory(
        at offset: TimeInterval,
        status: CodexRateLimitResetCreditStatus,
        redeemedAt: Date?) -> UsageSnapshot
    {
        let date = self.now.addingTimeInterval(offset)
        let credit = CodexRateLimitResetCredit(
            id: "RateLimitResetCredit_fixture",
            resetType: "codex_rate_limits",
            status: status,
            grantedAt: self.now.addingTimeInterval(-10 * 86400),
            expiresAt: self.now.addingTimeInterval(20 * 86400),
            redeemStartedAt: redeemedAt,
            redeemedAt: redeemedAt,
            title: nil,
            description: nil)
        return UsageSnapshot(
            primary: nil,
            secondary: nil,
            codexResetCredits: .init(credits: [credit], availableCount: status == .available ? 1 : 0, updatedAt: date),
            updatedAt: date)
    }

    private func claude(
        at offset: TimeInterval,
        used: Double,
        weeklyReset: TimeInterval?,
        available: [Date?],
        usedResets: [Date?]) -> UsageSnapshot
    {
        let date = self.now.addingTimeInterval(offset)
        return UsageSnapshot(
            primary: nil,
            secondary: .init(
                usedPercent: used,
                windowMinutes: 10080,
                resetsAt: weeklyReset.map { self.now.addingTimeInterval($0) },
                resetDescription: nil),
            claudeResetCredits: .init(expirations: available, updatedAt: date, usedExpirations: usedResets),
            updatedAt: date)
    }
}

extension Array {
    fileprivate var only: Element? {
        self.count == 1 ? self.first : nil
    }
}
