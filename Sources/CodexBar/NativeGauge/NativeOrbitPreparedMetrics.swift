import CodexBarCore
import Foundation

/// Prepared inputs belong to one immutable account presentation. Array storage checks keep an alternate or
/// truncated history from accidentally borrowing this account's receipt cadence or recorded usage.
final class NativeOrbitPreparedMetricHistory {
    struct Lane {
        let entries: [PlanUtilizationHistoryEntry]
        private let prefixTolerances: [TimeInterval]

        init(_ entries: [PlanUtilizationHistoryEntry]) {
            self.entries = entries.enumerated().sorted {
                $0.element.capturedAt == $1.element.capturedAt
                    ? $0.offset < $1.offset : $0.element.capturedAt < $1.element.capturedAt
            }.map(\.element)
            self.prefixTolerances = Self.cadenceTolerances(self.entries)
        }

        func prefixCount(through date: Date) -> Int {
            var lower = 0
            var upper = self.entries.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if self.entries[middle].capturedAt <= date { lower = middle + 1 } else { upper = middle }
            }
            return lower
        }

        /// Equal-time receipts preserve the original max(by:) rule: the first source receipt wins.
        func latestIndex(through date: Date) -> Int? {
            let count = self.prefixCount(through: date)
            guard count > 0 else { return nil }
            let timestamp = self.entries[count - 1].capturedAt
            var lower = 0
            var upper = count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if self.entries[middle].capturedAt < timestamp { lower = middle + 1 } else { upper = middle }
            }
            return lower
        }

        func observation(at date: Date, cutoff: Date? = nil) -> PlanUtilizationHistoryEntry? {
            let through = min(
                date.addingTimeInterval(NativeOrbitAccountMetrics.sameRefreshSkew),
                cutoff ?? .distantFuture)
            guard let index = self.latestIndex(through: through) else { return nil }
            let count = cutoff.map { self.prefixCount(through: $0) } ?? self.entries.count
            let tolerance = count > 0 ? self.prefixTolerances[count - 1] : 900
            let entry = self.entries[index]
            return date.timeIntervalSince(entry.capturedAt) <= tolerance ? entry : nil
        }

        /// A Fenwick count tree selects the exact lower median after each receipt. Coordinate compression uses
        /// future intervals only as positions; prefix counts alone determine each historical cadence.
        private static func cadenceTolerances(_ entries: [PlanUtilizationHistoryEntry]) -> [TimeInterval] {
            let intervals = zip(entries, entries.dropFirst()).map { $1.capturedAt.timeIntervalSince($0.capturedAt) }
            let values = Set(intervals.filter { $0 > 1 && $0 <= 5400 }).sorted()
            let ranks = Dictionary(uniqueKeysWithValues: values.enumerated().map { ($0.element, $0.offset + 1) })
            var tree = Array(repeating: 0, count: values.count + 1)
            var count = 0
            var result: [TimeInterval] = []
            for index in entries.indices {
                if index > 0, var rank = ranks[intervals[index - 1]] {
                    count += 1
                    while rank < tree.count {
                        tree[rank] += 1
                        rank += rank & -rank
                    }
                }
                guard count > 0 else { result.append(900); continue }
                var target = (count + 1) / 2
                var rank = 0
                var step = 1
                while step <= values.count / 2 {
                    step *= 2
                }
                while step > 0 {
                    let candidate = rank + step
                    if candidate < tree.count, tree[candidate] < target {
                        target -= tree[candidate]
                        rank = candidate
                    }
                    step /= 2
                }
                result.append(min(5400, max(900, values[rank] * 3)))
            }
            return result
        }
    }

    private struct CreditVersion {
        let prefixCount: Int
        let multiplicity: Int
    }

    private let source: [PlanUtilizationSeriesHistory]
    lazy var warningHistory = NativeOrbitPreparedWarningHistory(history: self.source)
    /// Every recorded redemption; a range only filters them.
    lazy var resetRedemptions = NativeOrbitResetEvent.redemptions(in: self.source)
    private let lanes: [String: Lane]
    let creditEvents: [NativeOrbitCreditUsageEvent]
    private var usageSnapshots: [Int: CostUsageTokenSnapshot] = [:]
    private var invalidUsageSnapshots: Set<Int> = []
    private let creditVersions: [NativeOrbitCreditUsageEvent: [CreditVersion]]
    private var creditPrefixes: [Int: [NativeOrbitCreditUsageEvent]] = [:]

    init(history: [PlanUtilizationSeriesHistory]) {
        self.source = history
        var grouped: [String: [PlanUtilizationHistoryEntry]] = [:]
        for lane in history where lane.name.rawValue.hasPrefix("nativeMetric:") {
            grouped[lane.name.rawValue, default: []] += lane.entries
        }
        self.lanes = grouped.mapValues(Lane.init)
        self.creditEvents = NativeOrbitCreditUsageEvent.merging(
            (grouped["nativeMetric:creditEvents"] ?? []).compactMap { $0.nativeMetrics?.creditEvents })
        var versions: [NativeOrbitCreditUsageEvent: [CreditVersion]] = [:]
        for (index, entry) in (self.lanes["nativeMetric:creditEvents"]?.entries ?? []).enumerated() {
            let counts = Dictionary(grouping: entry.nativeMetrics?.creditEvents ?? [], by: { $0 }).mapValues(\.count)
            for (event, count) in counts where count > (versions[event]?.last?.multiplicity ?? 0) {
                versions[event, default: []].append(.init(prefixCount: index + 1, multiplicity: count))
            }
        }
        self.creditVersions = versions
    }

    func matches(_ history: [PlanUtilizationSeriesHistory]) -> Bool {
        nativeOrbitSharesArrayStorage(self.source, history)
    }

    func usageReceiptCount(through date: Date) -> Int {
        self.lanes["nativeMetric:usage"]?.prefixCount(through: date) ?? 0
    }

    var hasUsageReceipts: Bool {
        self.lanes["nativeMetric:usage"]?.entries.isEmpty == false
    }

    func observation(_ name: String, at date: Date, cutoff: Date? = nil) -> PlanUtilizationHistoryEntry? {
        self.lanes["nativeMetric:" + name]?.observation(at: date, cutoff: cutoff)
    }

    func creditEvents(through cutoff: Date) -> [NativeOrbitCreditUsageEvent] {
        let count = self.lanes["nativeMetric:creditEvents"]?.prefixCount(through: cutoff) ?? 0
        if let cached = self.creditPrefixes[count] { return cached }
        var events: [NativeOrbitCreditUsageEvent] = []
        for (event, versions) in self.creditVersions {
            var lower = 0
            var upper = versions.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if versions[middle].prefixCount <= count { lower = middle + 1 } else { upper = middle }
            }
            if lower > 0 { events += Array(repeating: event, count: versions[lower - 1].multiplicity) }
        }
        let merged = NativeOrbitCreditUsageEvent.merging([events])
        if self.creditPrefixes.count >= 64 { self.creditPrefixes.removeAll(keepingCapacity: true) }
        self.creditPrefixes[count] = merged
        return merged
    }

    /// Validation remains authoritative; each selected receipt is decoded only once while scrubbing over it.
    func usageSnapshot(at date: Date?, cutoff: Date? = nil) -> CostUsageTokenSnapshot? {
        guard let lane = self.lanes["nativeMetric:usage"],
              let index = lane.latestIndex(through: min(date ?? .distantFuture, cutoff ?? .distantFuture)),
              !self.invalidUsageSnapshots.contains(index) else { return nil }
        if let cached = self.usageSnapshots[index] { return cached }
        let entry = lane.entries[index]
        // A long scrub must not duplicate every archived daily report in memory.
        if self.usageSnapshots.count + self.invalidUsageSnapshots.count >= 64 {
            self.usageSnapshots.removeAll(keepingCapacity: true)
            self.invalidUsageSnapshots.removeAll(keepingCapacity: true)
        }
        guard let snapshot = entry.nativeMetrics?.usage?.snapshot(at: entry.capturedAt) else {
            self.invalidUsageSnapshots.insert(index)
            return nil
        }
        self.usageSnapshots[index] = snapshot
        return snapshot
    }
}

struct NativeOrbitPreparedAccountUsage {
    let snapshot: CostUsageTokenSnapshot?
}

/// The original event order is retained, including floating point accumulation order. Unsorted legacy input
/// keeps the original filtering path; chronological streams use two binary bounds instead of scanning all events.
struct NativeOrbitPreparedUsageSlices {
    let slices: [CostUsageTimedEntry]

    init?(_ slices: [CostUsageTimedEntry]) {
        guard !slices.isEmpty,
              zip(slices, slices.dropFirst()).allSatisfy({ $0.timestamp <= $1.timestamp }) else { return nil }
        self.slices = slices
    }

    func entries(matching source: [CostUsageTimedEntry], in bounds: ClosedRange<Date>) -> [CostUsageTimedEntry]? {
        guard nativeOrbitSharesArrayStorage(self.slices, source) else { return nil }
        func bound(_ date: Date, inclusive: Bool) -> Int {
            var lower = 0
            var upper = self.slices.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                let before = inclusive ? self.slices[middle].timestamp <= date : self.slices[middle].timestamp < date
                if before { lower = middle + 1 } else { upper = middle }
            }
            return lower
        }
        return Array(self.slices[bound(bounds.lowerBound, inclusive: false)..<bound(
            bounds.upperBound,
            inclusive: true)])
    }
}

private func nativeOrbitSharesArrayStorage<Element>(_ first: [Element], _ second: [Element]) -> Bool {
    guard first.count == second.count else { return false }
    return first.withUnsafeBufferPointer { lhs in
        second.withUnsafeBufferPointer { rhs in lhs.baseAddress == rhs.baseAddress }
    }
}

/// Copies of one account's readings share civil-day boundaries, including restored receipts and merged reports.
/// Parsing belongs to the first reading of a bucket, never to every pointer or plotted sample.
final class NativeOrbitUsageDayMemo {
    private struct Key: Hashable {
        let day: String
        let calendar: Calendar
    }

    private let lock = NSLock()
    private var intervals: [Key: DateInterval] = [:]

    func interval(for day: String, calendar: Calendar) -> DateInterval? {
        let key = Key(day: day, calendar: calendar)
        return self.lock.withLock {
            if let cached = self.intervals[key] { return cached }
            let fields = day.split(separator: "-")
            guard fields.count == 3, fields[0].count == 4, fields[1].count == 2, fields[2].count == 2,
                  let year = Int(fields[0]), let month = Int(fields[1]), let date = Int(fields[2]),
                  let start = calendar.date(from: DateComponents(year: year, month: month, day: date)),
                  calendar.component(.year, from: start) == year,
                  calendar.component(.month, from: start) == month,
                  calendar.component(.day, from: start) == date,
                  let interval = calendar.dateInterval(of: .day, for: start) else { return nil }
            if self.intervals.count >= 512 { self.intervals.removeAll(keepingCapacity: true) }
            self.intervals[key] = interval
            return interval
        }
    }
}
