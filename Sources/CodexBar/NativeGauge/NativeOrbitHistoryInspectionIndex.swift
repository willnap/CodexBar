import Foundation

/// Immutable hit targets prepared with the static chart, so a pointer move searches dates instead of rebuilding
/// observation arrays and grouping every historical sample. Categories retain their source precedence.
struct NativeOrbitHistoryInspectionIndex: Sendable {
    private struct Target: Sendable {
        let date: Date
        let sourceOrder: Int
    }

    private let metricDates: [Target]
    private let spendingDates: [Target]
    private let futureEventDates: [Target]
    private let resetDates: [Target]
    private let isolatedDates: [Target]

    init(
        metricDates: [Date],
        spendingDates: [Date],
        futureEventDates: [Date],
        resetDates: [Date],
        isolatedDates: [Date])
    {
        self.metricDates = Self.targets(metricDates)
        self.spendingDates = Self.targets(spendingDates)
        self.futureEventDates = Self.targets(futureEventDates)
        self.resetDates = Self.targets(resetDates)
        self.isolatedDates = Self.targets(isolatedDates)
    }

    func date(at date: Date, now: Date, tolerance: TimeInterval) -> Date {
        // An actual complication reading wins over nearby quota-only points, even just behind now while the pointer
        // is slightly ahead of it. Each selected target is its genuine timestamp, never a quantized pointer date.
        if let metric = Self.nearest(self.metricDates, to: date, tolerance: tolerance) { return metric }
        if let spend = Self.nearest(self.spendingDates, to: date, tolerance: tolerance) { return spend }
        if date > now { return Self.nearest(self.futureEventDates, to: date, tolerance: tolerance) ?? date }
        if let reset = Self.nearest(self.resetDates, to: date, tolerance: tolerance) { return reset }
        return Self.nearest(self.isolatedDates, to: date, tolerance: tolerance) ?? date
    }

    private static func targets(_ dates: [Date]) -> [Target] {
        var seen = Set<Date>()
        return dates.enumerated().compactMap { index, date in
            seen.insert(date).inserted ? Target(date: date, sourceOrder: index) : nil
        }.sorted { $0.date < $1.date }
    }

    private static func nearest(_ dates: [Target], to date: Date, tolerance: TimeInterval) -> Date? {
        var lower = 0
        var upper = dates.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if dates[middle].date < date { lower = middle + 1 } else { upper = middle }
        }
        let before = lower > 0 ? dates[lower - 1] : nil
        let after = lower < dates.count ? dates[lower] : nil
        let nearest: Target? = if let before, let after {
            // The original filter/min path kept the first source target on equal distances, even when an isolated
            // or scheduled-event list was not chronological. Sorting the lookup must not change that selection.
            if date.timeIntervalSince(before.date) == after.date.timeIntervalSince(date) {
                before.sourceOrder < after.sourceOrder ? before : after
            } else {
                date.timeIntervalSince(before.date) < after.date.timeIntervalSince(date) ? before : after
            }
        } else {
            before ?? after
        }
        return nearest.flatMap { abs($0.date.timeIntervalSince(date)) <= tolerance ? $0.date : nil }
    }
}

extension NativeOrbitHistoryWidget {
    /// The same targets the chart draws, collected once when its static content changes.
    func inspectionIndex(_ lanes: [Lane]) -> NativeOrbitHistoryInspectionIndex {
        NativeOrbitHistoryInspectionIndex(
            metricDates: self.metricObservationDates,
            spendingDates: self.spending?.observationDates ?? [],
            futureEventDates: self.projectedEvents.map(\.date),
            resetDates: Self.resetEvents(lanes).map(\.date),
            isolatedDates: lanes.flatMap { ($0.isolatedSamples + $0.periodSamples).map(\.date) })
    }

    func inspectionDate(
        at date: Date,
        plotWidth: CGFloat,
        using preparedIndex: NativeOrbitHistoryInspectionIndex? = nil) -> Date
    {
        // Three points on the current time scale, with all the original source priorities and exact timestamps.
        // The real pointer callback captures its prepared index with the equatable static chart.
        let index = preparedIndex ?? self.inspectionIndex(self.lanes)
        let tolerance = self.chartEnd.timeIntervalSince(self.start) / max(1, Double(plotWidth)) * 3
        return index.date(at: date, now: self.now, tolerance: tolerance)
    }
}
