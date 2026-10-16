import CodexBarCore
import Foundation

/// Account-owned warning evidence. A pointer searches immutable receipt indexes; it never borrows later receipts.
final class NativeOrbitPreparedWarningHistory {
    private struct ResetKey: Hashable {
        let provider: UsageProvider
        let prefix: Int
    }

    private struct ResetResult {
        let event: NativeOrbitResetEvent?
    }

    private let quotas: [PlanUtilizationSeriesHistory]
    private let inventories: [PlanUtilizationSeriesHistory]
    private let resetEvidenceDates: [Date]
    private let consumption: [ClosedRange<Date>]
    private var resetResults: [ResetKey: ResetResult] = [:]

    init(history: [PlanUtilizationSeriesHistory]) {
        self.quotas = history.filter(\.name.isNativeQuotaObservation)
        self.inventories = history.filter { $0.name.rawValue == "nativeMetric:resets" }
        var dates = self.inventories.flatMap(\.entries).filter { $0.nativeMetrics?.resets != nil }.map(\.capturedAt)
        var consumption: [ClosedRange<Date>] = []
        for lane in self.quotas {
            for (before, after) in zip(lane.entries, lane.entries.dropFirst())
                where after.usedPercent > before.usedPercent + NativeOrbitActivity.minimumIncrease
                && NativeOrbitActivity.sameWindow(before, after)
            {
                consumption.append(before.capturedAt...after.capturedAt)
            }
            let measured = lane.entries.filter {
                $0.historicalPeriod == nil && $0.usedPercent.isFinite && $0.usedPercent >= 0
            }
            for (before, after) in zip(measured, measured.dropFirst())
                where after.capturedAt > before.capturedAt
            {
                guard let schedule = before.resetsAt, schedule > before.capturedAt,
                      schedule.timeIntervalSince(after.capturedAt) > NativeOrbitResetEvent.sameInstant,
                      NativeOrbitResetEvent.isResetDrop(from: before.usedPercent, to: after.usedPercent)
                else { continue }
                dates.append(after.capturedAt)
            }
        }
        self.resetEvidenceDates = Array(Set(dates)).sorted()
        self.consumption = consumption.enumerated().sorted {
            $0.element.upperBound == $1.element.upperBound
                ? $0.offset < $1.offset : $0.element.upperBound < $1.element.upperBound
        }.map(\.element)
    }

    func consumptionIntervals(at date: Date) -> ArraySlice<ClosedRange<Date>> {
        let lower = self.consumptionBoundary(date.addingTimeInterval(-86400), inclusive: false)
        let upper = self.consumptionBoundary(date, inclusive: true)
        return self.consumption[lower..<upper]
    }

    private func consumptionBoundary(_ date: Date, inclusive: Bool) -> Int {
        var lower = 0
        var upper = self.consumption.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            let end = self.consumption[middle].upperBound
            if end < date || (inclusive && end == date) { lower = middle + 1 } else { upper = middle }
        }
        return lower
    }

    func earlyReset(provider: UsageProvider, at date: Date) -> NativeOrbitResetEvent? {
        var lower = 0
        var upper = self.resetEvidenceDates.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if self.resetEvidenceDates[middle] <= date { lower = middle + 1 } else { upper = middle }
        }
        let key = ResetKey(provider: provider, prefix: lower)
        let result: ResetResult
        if let cached = self.resetResults[key] {
            result = cached
        } else {
            // Natural countdown expiry cannot change an early reset's classification. Only a new early drop or
            // inventory receipt can, so an exact receipt-prefix key remains valid between those boundaries.
            let events = NativeOrbitResetEvent.events(
                quotaHistories: self.quotas.map { $0.prefix(through: date) },
                metricHistories: self.inventories.map { $0.prefix(through: date) },
                provider: provider,
                now: date)
            result = ResetResult(event: events.last { $0.kind == .provider || $0.kind == .early })
            if self.resetResults.count >= 128 { self.resetResults.removeAll(keepingCapacity: true) }
            self.resetResults[key] = result
        }
        return result.event.flatMap { $0.date <= date && date.timeIntervalSince($0.date) <= 86400 ? $0 : nil }
    }
}
