import Foundation

/// The exact vertices supplied to Charts, indexed once for pointer and animated cursor sampling.
struct NativeOrbitHistoryCurve {
    struct Reading {
        let date: Date
        let available: Double
    }

    let points: [NativeOrbitHistoryPlotPoint]

    func reading(at date: Date) -> Reading? {
        var lower = 0
        var upper = self.points.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if self.points[middle].date <= date { lower = middle + 1 } else { upper = middle }
        }
        guard lower > 0 else { return nil }
        let before = self.points[lower - 1]
        if before.date == date { return Reading(date: date, available: before.available) }
        guard lower < self.points.count else { return nil }
        let after = self.points[lower]
        guard before.seriesID == after.seriesID else { return nil }
        let fraction = date.timeIntervalSince(before.date) / after.date.timeIntervalSince(before.date)
        return Reading(date: date, available: before.available + (after.available - before.available) * fraction)
    }
}

/// Each immutable account projection shares its prepared curves across chart construction and pointer updates.
final class NativeOrbitProjectionCurveCache {
    private struct Key: Hashable {
        let lane: NativeOrbitLaneProjection
        let end: Date
    }

    private var curves: [Key: NativeOrbitHistoryCurve] = [:]

    func curve(_ lane: NativeOrbitLaneProjection, through end: Date) -> NativeOrbitHistoryCurve {
        let key = Key(lane: lane, end: end)
        if let cached = self.curves[key] { return cached }
        let curve = NativeOrbitHistoryCurve(points: NativeOrbitHistoryWidget.projectionPlotPoints(
            lane.points(through: end), seriesID: lane.id))
        if self.curves.count >= 16 { self.curves.removeAll(keepingCapacity: true) }
        self.curves[key] = curve
        return curve
    }
}
