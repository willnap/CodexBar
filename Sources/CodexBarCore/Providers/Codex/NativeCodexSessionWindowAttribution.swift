import Foundation

/// The weekly quota window that each local Codex session event reported, ordered by event time.
///
/// Every `token_count` event in a rollout carries the rate limits of the account that served the request. The
/// weekly window's `resets_at` therefore identifies that account, whatever login created the session file.
public struct NativeCodexSessionWindowTimeline: Sendable, Equatable {
    /// Events before this instant were not scanned; their requests cannot be attributed.
    public let coverageStart: Date
    public let coverageEnd: Date
    /// Seconds since 1970, ascending; `windowResets` holds the matching weekly reset instants.
    let eventTimes: [Double]
    let windowResets: [Double]

    public var eventCount: Int {
        self.eventTimes.count
    }

    /// The events at or after `start`, each with the weekly reset it reported; for diagnostics.
    public func events(since start: Date) -> [(time: Date, weeklyReset: Date)] {
        let threshold = start.timeIntervalSince1970
        return zip(self.eventTimes, self.windowResets).filter { $0.0 >= threshold }.map {
            (Date(timeIntervalSince1970: $0.0), Date(timeIntervalSince1970: $0.1))
        }
    }

    public init(observations: [NativeCodexQuotaSessionObservation], coverageStart: Date, coverageEnd: Date) {
        // Spark and other model-scoped limits use separate windows; only the main Codex limit names the account.
        let events = observations.compactMap { observation -> (Date, Date)? in
            let weekly = [observation.snapshot.secondary, observation.snapshot.primary].compactMap(\.self)
                .first { $0.windowMinutes == Self.weeklyWindowMinutes && $0.resetsAt != nil }
            guard let reset = weekly?.resetsAt else { return nil }
            return (observation.snapshot.updatedAt, reset)
        }
        self.init(events: events, coverageStart: coverageStart, coverageEnd: coverageEnd)
    }

    /// `events` pairs each event instant with the weekly reset it reported.
    public init(events: [(time: Date, weeklyReset: Date)], coverageStart: Date, coverageEnd: Date) {
        struct Event {
            let time: Double
            let reset: Double
        }
        var sorted: [Event] = []
        sorted.reserveCapacity(events.count)
        for event in events {
            let time = event.time.timeIntervalSince1970
            let reset = event.weeklyReset.timeIntervalSince1970
            if time.isFinite, reset.isFinite { sorted.append(Event(time: time, reset: reset)) }
        }
        sorted.sort { lhs, rhs in lhs.time != rhs.time ? lhs.time < rhs.time : lhs.reset < rhs.reset }
        self.eventTimes = sorted.map(\.time)
        self.windowResets = sorted.map(\.reset)
        self.coverageStart = coverageStart
        self.coverageEnd = max(coverageStart, coverageEnd)
    }

    public static let weeklyWindowMinutes = 10080
}

public enum NativeCodexSessionWindowAttribution {
    /// Reset instants of one window differ by seconds between events and account readings; windows of distinct
    /// accounts start at distinct request times.
    public static let resetTolerance: TimeInterval = 120
    /// Usage rows without their own rate-limit event take the window of the nearest event in time.
    public static let maximumEventGap: TimeInterval = 15 * 60

    public struct Result: Sendable, Equatable {
        /// Requests served by each account with window evidence, rebuilt as a local report.
        public let reports: [String: CostUsageTokenSnapshot]
        /// Civil days containing requests whose serving account is unknown or ambiguous.
        public let unattributedDays: Set<String>
        public let attributedSliceCount: Int
        public let unattributedSliceCount: Int
    }

    /// Splits local request slices between accounts by the weekly window each request reported.
    ///
    /// `evidence` holds, per account, the weekly reset instants that account recorded about itself. A window that
    /// matches several accounts, or none, stays unattributed: one account's usage is never shown as another's.
    public static func attribute(
        reports: [CostUsageTokenSnapshot],
        timeline: NativeCodexSessionWindowTimeline,
        evidence: [String: [Date]],
        calendar: Calendar) -> Result
    {
        let accounts = evidence.compactMapValues { resets -> [Double]? in
            let values = resets.map(\.timeIntervalSince1970).filter(\.isFinite).sorted()
            return values.isEmpty ? nil : values
        }
        var ownerByWindow: [Int64: String?] = [:]
        func owner(of reset: Double) -> String? {
            let key = Int64(reset.rounded())
            if let cached = ownerByWindow[key] { return cached }
            let owners = accounts.filter { Self.contains($0.value, near: reset, tolerance: Self.resetTolerance) }
            let owner = owners.count == 1 ? owners.first?.key : nil
            ownerByWindow[key] = owner
            return owner
        }

        var slicesByAccount: [String: [CostUsageTimedEntry]] = [:]
        var unattributedDays: Set<String> = []
        var dayKeys = DayKeyCache(calendar: calendar)
        var attributed = 0
        var unattributed = 0
        let start = timeline.coverageStart.timeIntervalSince1970
        for report in reports {
            var cursor = 0
            let slices = report.quotaSlices.sorted { $0.timestamp < $1.timestamp }
            for slice in slices {
                let instant = slice.timestamp.timeIntervalSince1970
                guard instant.isFinite, instant >= start else { continue }
                while cursor < timeline.eventTimes.count, timeline.eventTimes[cursor] < instant - 0.0005 {
                    cursor += 1
                }
                let window = Self.window(at: instant, from: cursor, in: timeline)
                if let window, let account = owner(of: window) {
                    slicesByAccount[account, default: []].append(slice)
                    attributed += 1
                } else {
                    unattributedDays.insert(dayKeys.key(for: slice.timestamp))
                    unattributed += 1
                }
            }
        }

        let established = !reports.isEmpty && reports.allSatisfy(\.historyCoverageIsEstablished)
        let partial = reports.contains(where: \.historyScanIsPartial)
        let updatedAt = reports.map(\.updatedAt).min() ?? timeline.coverageEnd
        let through = reports.map { $0.coverageThrough ?? $0.updatedAt }.min() ?? updatedAt
        let provenance = reports.map(\.costProvenance).first { $0 != .unknown } ?? .unknown
        let coveredDays = max(1, min(
            reports.map(\.historyDays).min() ?? 1,
            Self.civilDays(from: timeline.coverageStart, through: through, calendar: calendar)))
        var output: [String: CostUsageTokenSnapshot] = [:]
        for account in accounts.keys {
            let slices = (slicesByAccount[account] ?? []).sorted { $0.timestamp < $1.timestamp }
            output[account] = CostUsageTokenSnapshot(
                sessionTokens: nil,
                sessionCostUSD: nil,
                last30DaysTokens: nil,
                last30DaysCostUSD: nil,
                historyDays: coveredDays,
                historyCoverageIsEstablished: established,
                historyScanIsPartial: partial,
                historyLabel: "Local sessions served by this account",
                bucketTimeZoneIdentifier: calendar.timeZone.identifier,
                coverageThrough: through,
                costProvenance: provenance,
                daily: Self.daily(slices, unattributedDays: unattributedDays, dayKeys: &dayKeys),
                quotaSlices: slices,
                updatedAt: updatedAt)
        }
        return Result(
            reports: output,
            unattributedDays: unattributedDays,
            attributedSliceCount: attributed,
            unattributedSliceCount: unattributed)
    }

    /// Exact-instant events describe the request itself; otherwise the nearest event within the gap does.
    private static func window(at instant: Double, from cursor: Int, in timeline: NativeCodexSessionWindowTimeline)
        -> Double?
    {
        let times = timeline.eventTimes
        var index = cursor
        var exact: Double?
        while index < times.count, times[index] <= instant + 0.0005 {
            let reset = timeline.windowResets[index]
            if let known = exact, abs(known - reset) > Self.resetTolerance { return nil }
            exact = exact ?? reset
            index += 1
        }
        if let exact { return exact }
        let candidates = [cursor - 1, cursor].filter { $0 >= 0 && $0 < times.count }
        guard let nearest = candidates.min(by: { abs(times[$0] - instant) < abs(times[$1] - instant) }),
              abs(times[nearest] - instant) <= Self.maximumEventGap else { return nil }
        return timeline.windowResets[nearest]
    }

    private static func daily(
        _ slices: [CostUsageTimedEntry],
        unattributedDays: Set<String>,
        dayKeys: inout DayKeyCache) -> [CostUsageDailyReport.Entry]
    {
        struct Day {
            var tokens = 0
            var tokensKnown = true
            var cost = 0.0
            var costSeen = false
            var costIncomplete = false
        }
        var days: [String: Day] = [:]
        for slice in slices {
            let key = dayKeys.key(for: slice.timestamp)
            var day = days[key] ?? Day()
            if let tokens = slice.totalTokens, slice.tokensAreComplete {
                let sum = day.tokens.addingReportingOverflow(tokens)
                if sum.overflow { day.tokensKnown = false } else { day.tokens = sum.partialValue }
            } else {
                day.tokensKnown = false
            }
            if let cost = slice.costUSD, cost.isFinite, cost >= 0 {
                day.cost += cost
                day.costSeen = true
            }
            if !slice.costIsComplete { day.costIncomplete = true }
            days[key] = day
        }
        return days.keys.sorted().compactMap { key in
            guard let day = days[key] else { return nil }
            return CostUsageDailyReport.Entry(
                date: key,
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: day.tokensKnown ? day.tokens : nil,
                costUSD: day.costSeen && day.cost.isFinite ? day.cost : nil,
                modelsUsed: nil,
                modelBreakdowns: nil,
                costIsPartial: day.costIncomplete || unattributedDays.contains(key))
        }
    }

    private static func contains(_ sorted: [Double], near value: Double, tolerance: Double) -> Bool {
        var low = 0
        var high = sorted.count
        while low < high {
            let middle = (low + high) / 2
            if sorted[middle] < value - tolerance { low = middle + 1 } else { high = middle }
        }
        return low < sorted.count && sorted[low] <= value + tolerance
    }

    private static func civilDays(from start: Date, through end: Date, calendar: Calendar) -> Int {
        guard end >= start else { return 1 }
        let first = calendar.startOfDay(for: start)
        let last = calendar.startOfDay(for: end)
        return (calendar.dateComponents([.day], from: first, to: last).day ?? 0) + 1
    }

    /// Slices arrive in time order, so civil-day keys are recomputed only when a day boundary is crossed.
    private struct DayKeyCache {
        let calendar: Calendar
        var interval: DateInterval?
        var key = ""

        init(calendar: Calendar) {
            self.calendar = calendar
        }

        mutating func key(for date: Date) -> String {
            if let interval, date >= interval.start, date < interval.end { return self.key }
            self.interval = self.calendar.dateInterval(of: .day, for: date)
            self.key = CostUsageLocalDay.key(from: date, calendar: self.calendar)
            return self.key
        }
    }
}
