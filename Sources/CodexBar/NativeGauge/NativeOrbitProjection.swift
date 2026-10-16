import CodexBarCore
import Foundation

// MARK: - Activity

/// Whether an account is being used right now. Only measured evidence counts: a quota reading that rose inside its
/// window, or dated usage (local requests, credit events) recorded for this account.
enum NativeOrbitActivity {
    /// Evidence older than this no longer makes an account active.
    static let window: TimeInterval = 30 * 60
    /// Quota readings move in hundredths at best; a smaller change is noise.
    static let minimumIncrease = 0.01

    /// The latest instant at most `window` before `now` that shows this account consuming; nil when nothing does.
    static func lastActivity(
        lanes: [NativeOrbitHistoryWidget.Lane],
        metrics: NativeOrbitAccountMetrics,
        now: Date) -> Date?
    {
        let threshold = now.addingTimeInterval(-self.window)
        var latest: Date?
        func note(_ date: Date) {
            guard date >= threshold, date <= now, latest.map({ date > $0 }) ?? true else { return }
            latest = date
        }
        for lane in lanes {
            let readings = lane.samples.filter { !$0.isResetEdge && $0.id.historicalPeriod == nil }
            for (before, after) in zip(readings, readings.dropFirst()) where after.date >= threshold {
                if after.id.usedPercent > before.id.usedPercent + self.minimumIncrease,
                   self.sameWindow(before.id, after.id)
                {
                    note(after.date)
                }
            }
        }
        // Dated usage belongs to this account only when it is the account's own report or attributed to it.
        let attributed = metrics.localCostUsage?.isAccountAttributed == true ? metrics.localCostUsage?.snapshot : nil
        for snapshot in [metrics.usage, attributed].compactMap(\.self) {
            for slice in snapshot.quotaSlices where (slice.totalTokens ?? 0) > 0 || (slice.costUSD ?? 0) > 0 {
                note(slice.timestamp)
            }
        }
        for event in metrics.creditUsageEvents where event.creditsUsed > 0 {
            note(event.date)
        }
        return latest
    }

    /// Every instant where one of the account's quota lanes rose inside its window, across its whole history.
    static func consumptionDates(_ histories: [PlanUtilizationSeriesHistory]) -> [Date] {
        var dates: [Date] = []
        for history in histories where history.name.isNativeQuotaObservation {
            let entries = history.entries.sorted { $0.capturedAt < $1.capturedAt }
            for (before, after) in zip(entries, entries.dropFirst())
                where after.usedPercent > before.usedPercent + self.minimumIncrease && self.sameWindow(before, after)
            {
                dates.append(after.capturedAt)
            }
        }
        return dates.sorted()
    }

    /// A rise is consumption only inside one window. Rolling windows move their reset with the clock, so the reset
    /// may shift by the time between the readings; a window that started over moves it by a whole period.
    static func sameWindow(_ before: PlanUtilizationHistoryEntry, _ after: PlanUtilizationHistoryEntry) -> Bool {
        let elapsed = after.capturedAt.timeIntervalSince(before.capturedAt)
        guard let first = before.resetsAt, let second = after.resetsAt else { return elapsed <= self.window }
        return abs(second.timeIntervalSince(first)) <= elapsed + NativeOrbitResetEvent.sameInstant
    }
}

// MARK: - Lane projection

/// One quota lane carried forward from its latest reading: usage grows at the account's pace until the window is
/// exhausted, holds there until the scheduled reset, starts over empty at the reset, and fills again at the same pace
/// in every later window. An account that is not in use keeps its reading until the reset (rate 0).
struct NativeOrbitLaneProjection: Hashable, Sendable {
    enum RateSource: String, Hashable, Sendable {
        /// The window's average pace since it started, as the menu's pace calculation (`UsagePace.weekly`).
        case windowPace
        /// Too early in the window for its pace: the trend of this window's readings.
        case observedTrend
        /// The account is not in use, or the readings show no consumption yet.
        case idle
    }

    struct Point: Hashable, Sendable {
        let date: Date
        let available: Double
        var isResetEdge = false
    }

    /// The lane's history name (`nativeQuota:…`).
    let id: String
    /// The reading the projection continues from.
    let origin: Date
    let originUsed: Double
    /// Used percent per second while the account is in use; 0 holds the reading.
    let rate: Double
    let rateSource: RateSource
    /// Window length; nil when unknown, in which case nothing is projected past the next reset.
    let period: TimeInterval?
    /// The window's scheduled reset; nil when none is scheduled (a rolling window not started yet, or no schedule).
    let reset: Date?
    /// Where the dashed line starts: the latest reading when it is recent, so it continues the recorded line, else now.
    let lineStart: Date

    /// Used percent at `date`; before the origin the reading itself.
    func used(at date: Date) -> Double {
        let date = max(date, self.origin)
        if let reset = self.reset, date >= reset {
            guard let period = self.period, period >= 60 else { return 0 }
            let elapsed = date.timeIntervalSince(reset).truncatingRemainder(dividingBy: period)
            return min(100, self.rate * elapsed)
        }
        return min(100, self.originUsed + self.rate * date.timeIntervalSince(self.origin))
    }

    func available(at date: Date) -> Double {
        100 - self.used(at: date)
    }

    /// The first scheduled reset strictly after `date`.
    func nextReset(after date: Date) -> Date? {
        guard let reset = self.reset else { return nil }
        if date < reset { return reset }
        guard let period = self.period, period >= 60 else { return nil }
        let windows = floor(date.timeIntervalSince(reset) / period) + 1
        return reset.addingTimeInterval(windows * period)
    }

    /// Scheduled resets in `(after, through]`, bounded so a malformed period can never loop for long.
    func resets(after start: Date, through end: Date, limit: Int = 400) -> [Date] {
        var dates: [Date] = []
        var cursor = start
        while dates.count < limit, let next = self.nextReset(after: cursor), next <= end {
            dates.append(next)
            cursor = next
        }
        return dates
    }

    /// The drawn line from `lineStart` to `end`: straight runs at the pace, a corner where the window runs out, and a
    /// vertical rise to 100 % at each scheduled reset (two points at the same instant, as recorded resets are drawn).
    func points(through end: Date) -> [Point] {
        let start = min(self.lineStart, end)
        var used = self.used(at: start)
        var cursor = start
        var points = [Point(date: start, available: 100 - used)]
        let resets = self.resets(after: start, through: end)
        for boundary in resets + (resets.last == end ? [] : [end]) where boundary > cursor {
            if self.rate > 0, used < 100 {
                let exhausted = cursor.addingTimeInterval((100 - used) / self.rate)
                if exhausted < boundary {
                    points.append(Point(date: exhausted, available: 0))
                    used = 100
                    cursor = exhausted
                }
            }
            let usedAtBoundary = min(100, used + self.rate * boundary.timeIntervalSince(cursor))
            if resets.contains(boundary) {
                points.append(Point(date: boundary, available: 100 - usedAtBoundary, isResetEdge: true))
                points.append(Point(date: boundary, available: 100, isResetEdge: true))
                used = 0
            } else {
                points.append(Point(date: boundary, available: 100 - usedAtBoundary))
                used = usedAtBoundary
            }
            cursor = boundary
        }
        return points
    }

    /// When the current window runs out at the projected pace; nil when it lasts until its reset.
    var exhaustion: Date? {
        if self.originUsed >= 100 { return self.origin }
        guard self.rate > 0 else { return nil }
        let date = self.origin.addingTimeInterval((100 - self.originUsed) / self.rate)
        if let reset = self.reset, date >= reset { return nil }
        return date
    }
}

// MARK: - Account projection

/// Everything the popup predicts for one account, computed once per presentation refresh (cached by
/// `NativeOrbitPopupState`): each quota lane carried forward, the scheduled events ahead, and the token and spend pace
/// for the selected period. Hovering only evaluates it.
struct NativeOrbitAccountProjection {
    /// A lane is projected only from a reading this recent.
    static let maximumReadingAge: TimeInterval = 2 * 3600
    /// The dashed line starts at the latest reading when it is this recent, so it continues the recorded line.
    static let continuationLimit: TimeInterval = 15 * 60
    /// Pace needs this share of the window behind it, as the menu's pace does (3 % expected), and ten minutes.
    static let minimumPaceFraction = 0.03
    static let minimumPaceSpan: TimeInterval = 10 * 60
    /// A rolling window whose reset lies a whole period after an empty reading has not started yet.
    static let unstartedSlack: TimeInterval = 5 * 60
    /// Later scheduled resets of a lane are marked only when its windows are long against the projected span;
    /// short windows already show every reset in their line.
    static let markedWindowsPerSpan = 12.0

    let now: Date
    /// The end of the projected span: `now` plus the selected period's elapsed time.
    let end: Date
    let lastActivity: Date?
    let lanes: [NativeOrbitLaneProjection]
    let events: [NativeOrbitScheduledEvent]
    /// Tokens and spend per second over the selected period so far; 0 while the account is not in use, nil unknown.
    let tokenRate: Double?
    let costRate: Double?
    /// The selected period's live totals the pace comes from; their scope and labels carry over.
    let periodSummary: NativeOrbitMetricSummary
    /// The current reset inventory, for banked resets that expire ahead.
    let resetInventory: NativeOrbitResetObservation?
    /// The account's live readings with its recorded history applied, made once here so hovering never redoes it.
    let liveMetrics: NativeOrbitAccountMetrics
    /// Recorded totals depend on the fixed origin and civil-day count, not the pointer's subsecond position.
    let summaryMemo = NativeOrbitProjectionSummaryMemo()

    var isActive: Bool {
        self.lastActivity != nil
    }

    func lane(_ id: String) -> NativeOrbitLaneProjection? {
        self.lanes.first { $0.id == id }
    }

    /// What the static chart draws; it rebuilds only when this changes.
    var signature: [String] {
        self.lanes.map {
            "\($0.id)|\($0.lineStart.timeIntervalSince1970)|\($0.originUsed)|\($0.rate)|"
                + "\($0.reset?.timeIntervalSince1970 ?? 0)|\($0.period ?? 0)"
        } + self.events.map(\.id) + ["\(self.end.timeIntervalSince1970)"]
    }

    // swiftlint:disable:next function_parameter_count
    static func make(
        account: NativeOrbitAccountPresentation,
        lanes: [NativeOrbitHistoryWidget.Lane],
        now: Date,
        days: Int,
        start: Date,
        end: Date,
        markingEnd: Date? = nil) -> Self
    {
        let live = account.metrics.at(nil, observedAt: account.updatedAt, history: account.history)
        let quotaActivity = NativeOrbitActivity.lastActivity(lanes: lanes, metrics: live, now: now)
        let moneyActivity = NativeOrbitMonetaryInspection.lastActivity(
            metrics: live,
            history: account.history,
            now: now)
        let lastActivity = [quotaActivity, moneyActivity].compactMap(\.self).max()
        let projected = lanes.compactMap { self.project($0, now: now, active: lastActivity != nil) }
        let summary = live.summary(days: days, now: now)
        let elapsed = now.timeIntervalSince(start)
        func rate(_ total: Double?) -> Double? {
            guard let total, total.isFinite, total >= 0 else { return nil }
            return lastActivity != nil && elapsed > 0 ? total / elapsed : 0
        }
        let inventory = account.history.filter { $0.name.rawValue == "nativeMetric:resets" }.flatMap(\.entries)
        let resetInventory = NativeOrbitAccountMetrics.latestObservation(in: inventory, at: now)?.nativeMetrics?.resets
        return Self(
            now: now,
            end: end,
            lastActivity: lastActivity,
            lanes: projected,
            events: self.events(
                lanes: projected,
                live: live,
                inventory: resetInventory,
                now: now,
                end: end,
                markingEnd: markingEnd),
            tokenRate: rate(summary.tokens.map(Double.init)),
            costRate: rate(summary.cost),
            periodSummary: summary,
            resetInventory: resetInventory,
            liveMetrics: live)
    }

    static func project(_ lane: NativeOrbitHistoryWidget.Lane, now: Date, active: Bool) -> NativeOrbitLaneProjection? {
        guard let latest = lane.latestMeasuredSample, latest.date <= now,
              now.timeIntervalSince(latest.date) <= self.maximumReadingAge else { return nil }
        let used = min(100, max(0, 100 - latest.available))
        let minutes = lane.history.windowMinutes
        let period = latest.period ?? (minutes > 0 ? Double(minutes) * 60 : nil)
        var reset = latest.id.resetsAt
        if let scheduled = reset, let period, used == 0,
           scheduled.timeIntervalSince(latest.date) >= period - self.unstartedSlack
        {
            reset = nil
        }
        let pace: (rate: Double, source: NativeOrbitLaneProjection.RateSource) = active
            ? self.pace(lane, latest: latest, used: used, period: period, reset: reset) : (0, .idle)
        return NativeOrbitLaneProjection(
            id: lane.history.name.rawValue,
            origin: latest.date,
            originUsed: used,
            rate: pace.rate,
            rateSource: pace.source,
            period: period,
            reset: reset,
            lineStart: now.timeIntervalSince(latest.date) <= self.continuationLimit ? latest.date : now)
    }

    /// The window's average pace since it started (or since a reset recorded inside it), the rate `UsagePace.weekly`
    /// uses for the menu's pace and run-out time. Early in a window, the trend of its own readings instead.
    static func pace(
        _ lane: NativeOrbitHistoryWidget.Lane,
        latest: NativeOrbitHistoryWidget.Sample,
        used: Double,
        period: TimeInterval?,
        reset: Date?) -> (rate: Double, source: NativeOrbitLaneProjection.RateSource)
    {
        var windowStart: Date? = if let reset, let period {
            reset.addingTimeInterval(-period)
        } else {
            nil
        }
        if let restart = lane.resetEvents.last(where: { $0.date <= latest.date })?.date,
           windowStart.map({ restart > $0 }) ?? true
        {
            windowStart = restart
        }
        if let windowStart {
            let elapsed = latest.date.timeIntervalSince(windowStart)
            let minimum = max(self.minimumPaceSpan, self.minimumPaceFraction * (period ?? 0))
            if elapsed >= minimum {
                let rate = used / elapsed
                return rate > 0 ? (rate, .windowPace) : (0, .idle)
            }
        }
        let readings = lane.samples.filter {
            !$0.isResetEdge && $0.id.historicalPeriod == nil && $0.segment == latest.segment
                && $0.date <= latest.date && $0.date >= (windowStart ?? .distantPast)
                && NativeOrbitActivity.sameWindow($0.id, latest.id)
        }
        guard let first = readings.first else { return (0, .idle) }
        let span = latest.date.timeIntervalSince(first.date)
        guard span >= self.minimumPaceSpan else { return (0, .idle) }
        let rate = (used - (100 - first.available)) / span
        return rate > 0 ? (rate, .observedTrend) : (0, .idle)
    }

    /// Known events between now and the end of the projected span, typed for the chart's marks.
    static func events(
        lanes: [NativeOrbitLaneProjection],
        live: NativeOrbitAccountMetrics,
        inventory: NativeOrbitResetObservation?,
        now: Date,
        end: Date,
        markingEnd: Date? = nil) -> [NativeOrbitScheduledEvent]
    {
        // Short windows get a rule at every reset when the selected range is short enough to show them apart; the
        // events still run to `end`, the widest drawn range, so every range draws the same marks.
        let span = (markingEnd ?? end).timeIntervalSince(now)
        var resets: [NativeOrbitScheduledEvent] = []
        for lane in lanes {
            let marksEvery = (lane.period ?? 0) >= span / self.markedWindowsPerSpan
            for (index, date) in lane.resets(after: now, through: end).enumerated() where index == 0 || marksEvery {
                if let match = resets.firstIndex(where: {
                    abs($0.date.timeIntervalSince(date)) <= NativeOrbitResetEvent.sameInstant
                }) {
                    resets[match].laneIDs.append(lane.id)
                } else {
                    resets.append(.init(
                        id: "window|\(date.timeIntervalSince1970)",
                        date: date,
                        label: "Window reset",
                        recoveryPercent: nil,
                        kind: .windowReset,
                        laneIDs: [lane.id]))
                }
            }
        }
        var events = resets
        let expirations = Dictionary(
            grouping: (inventory?.available(at: now) ?? []).compactMap(\.self).filter { $0 > now && $0 <= end },
            by: { $0 })
        for (date, grants) in expirations {
            events.append(.init(
                id: "banked|\(date.timeIntervalSince1970)",
                date: date,
                label: grants.count == 1 ? "Banked reset expires" : "\(grants.count) banked resets expire",
                recoveryPercent: nil,
                kind: .bankedResetExpiry,
                quantity: grants.count))
        }
        if let spend = live.reportedSpend, spend.isDisabled != true, let date = spend.resetsAt, date > now,
           date <= end
        {
            events.append(.init(
                id: "additional|\(date.timeIntervalSince1970)",
                date: date,
                label: "Additional usage resets",
                recoveryPercent: nil,
                kind: .additionalUsageCycle))
        }
        if let date = live.reportedPlanExpiry, date > now, date <= end {
            events.append(.init(
                id: "plan|\(date.timeIntervalSince1970)",
                date: date,
                label: "Plan expires",
                recoveryPercent: nil,
                kind: .planExpiry))
        }
        return events.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }
    }
}

// MARK: - Projected period totals

/// Tokens and spend for the selected period ending at a future instant.
struct NativeOrbitProjectedSummary {
    var summary: NativeOrbitMetricSummary
    /// Recorded from the period's start through now; nil when the period begins after now.
    var recordedTokens: Int?
    var recordedCost: Double?
    /// The time the pace is applied over: from now, or from the period's start when it begins later.
    var projectedSpan: TimeInterval
}

extension NativeOrbitAccountProjection {
    /// The selected Day / 7D / 30D period ending at `date`, respecting its calendar bounds: what is recorded from
    /// the period's start through now, plus this period's pace over the rest. A period that begins after now holds
    /// only the projected part. Unknown recorded totals stay unknown.
    func summary(days: Int, at date: Date, calendar: Calendar = .current) -> NativeOrbitProjectedSummary {
        let days = max(1, days)
        let period = CostReportingPeriod.rolling(days: days)
        let periodStart = period.bounds(now: date, calendar: calendar).lowerBound
        let ahead = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: self.now),
            to: calendar.startOfDay(for: date)).day ?? 0
        let recordedDays = days - max(0, ahead)
        let span = max(0, date.timeIntervalSince(max(self.now, periodStart)))
        func projectedCount(from recorded: Int) -> Int? {
            guard recorded >= 0, let rate = self.tokenRate, rate.isFinite, rate >= 0, span.isFinite,
                  let forecast = Int(exactly: (rate * span).rounded()), forecast >= 0 else { return nil }
            let total = recorded.addingReportingOverflow(forecast)
            return total.overflow ? nil : total.partialValue
        }
        func projectedCost(from recorded: Double) -> Double? {
            guard recorded.isFinite, recorded >= 0, let rate = self.costRate,
                  rate.isFinite, rate >= 0, span.isFinite else { return nil }
            let total = recorded + rate * span
            return total.isFinite ? total : nil
        }
        var result: NativeOrbitMetricSummary
        var recordedTokens: Int?
        var recordedCost: Double?
        if recordedDays >= 1 {
            result = self.summaryMemo.summary(days: recordedDays, calendar: calendar) {
                self.liveMetrics.summary(days: recordedDays, now: self.now, calendar: calendar)
            }
            recordedTokens = result.tokens
            recordedCost = result.cost
            result.tokens = result.tokens.flatMap { projectedCount(from: $0) }
            result.cost = result.cost.flatMap { projectedCost(from: $0) }
        } else {
            result = self.periodSummary
            result.tokens = projectedCount(from: 0)
            result.cost = projectedCost(from: 0)
        }
        result.requests = nil
        return NativeOrbitProjectedSummary(
            summary: result,
            recordedTokens: recordedTokens,
            recordedCost: recordedCost,
            projectedSpan: span)
    }
}

// MARK: - Shared axis

/// Every column shares one time axis, so one hovered instant means the same moment everywhere.
enum NativeOrbitChartAxis {
    static func start(now: Date, days: Int, calendar: Calendar = .current) -> Date {
        CostReportingPeriod.rolling(days: days).bounds(now: now, calendar: calendar).lowerBound
    }

    /// The past span a projecting chart mirrors into the future: a whole day, week or month.
    static func span(days: Int) -> TimeInterval {
        Double(max(1, days)) * 86400
    }

    /// Projecting: a full range span either side of now, both edges on the nearest whole hour so they read as clean
    /// times or dates and mirror each other; now sits at the center to within half an hour.
    static func projectingBounds(
        now: Date,
        days: Int,
        calendar: Calendar = .current) -> (start: Date, end: Date)
    {
        let anchor = calendar.dateInterval(of: .hour, for: now.addingTimeInterval(1800))?.start ?? now
        let span = self.span(days: days)
        return (anchor.addingTimeInterval(-span), anchor.addingTimeInterval(span))
    }
}
