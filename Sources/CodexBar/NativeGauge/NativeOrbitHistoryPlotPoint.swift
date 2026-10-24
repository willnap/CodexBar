import Foundation

/// The same coordinates and series previously supplied to individual marks, consumed as one vectorized plot.
struct NativeOrbitHistoryPlotPoint: Equatable {
    let date: Date
    let available: Double
    let seriesID: String
}

extension NativeOrbitHistoryWidget.Lane {
    var plotPoints: [NativeOrbitHistoryPlotPoint] {
        self.cursorCurve.points
    }
}

extension NativeOrbitHistoryWidget {
    static func projectionPlotPoints(
        _ points: [NativeOrbitLaneProjection.Point], seriesID: String) -> [NativeOrbitHistoryPlotPoint]
    {
        keyedPoints(points).map {
            NativeOrbitHistoryPlotPoint(date: $0.renderDate, available: $0.point.available, seriesID: seriesID)
        }
    }

    /// Quota drawing keeps the complete prepared vertex order across Day, 7D and 30D. Culling against the new
    /// viewport would change mark topology during a range animation and make Charts morph unrelated vertices.
    func quotaPlotPoints(_ lane: Lane) -> [NativeOrbitHistoryPlotPoint] {
        lane.plotPoints
    }

    /// The future uses the same prepared endpoint across ranges, preserving reset pairs and dash origins while
    /// the chart's domain zooms. Inspection still uses its independent complete source indexes.
    func projectionPlotPoints(
        _ lane: NativeOrbitLaneProjection, seriesID: String) -> [NativeOrbitHistoryPlotPoint]
    {
        let points = self.drawnProjection?.markerCurve(lane, through: self.dataEnd).points
            ?? Self.projectionPlotPoints(lane.points(through: self.dataEnd), seriesID: seriesID)
        return points.map { .init(date: $0.date, available: $0.available, seriesID: seriesID) }
    }
}
