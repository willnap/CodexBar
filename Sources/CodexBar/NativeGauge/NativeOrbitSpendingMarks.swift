import Charts
import SwiftUI

/// Dated spend keeps a separate relative scale, with a lit cap and a shaded body so adjacent buckets stay legible.
struct NativeOrbitSpendingMarks: ChartContent {
    let history: NativeOrbitSpendingHistory
    let accent: Color
    let now: Date
    var selectedDate: Date?

    var body: some ChartContent {
        ForEach(self.history.bars) { bar in
            let selected = self.selectedDate.flatMap { self.history.bar(at: $0) }?.id == bar.id
            let strength = self.history.emphasizesQuota ? 0.42 : 0.88
            let ink = self.accent.opacity(selected ? 1 : strength)
            let fill = LinearGradient(
                colors: [ink, ink.opacity(0.68), ink.opacity(0.22)], startPoint: .top, endPoint: .bottom)
            let height = self.history.height(bar)
            if bar.cost == 0 {
                PointMark(x: .value("Time", bar.start), y: .value("Spend", 0))
                    .symbolSize(selected ? 16 : 9)
                    .foregroundStyle(ink)
                    .accessibilityLabel(self.history.help(bar))
            } else if bar.granularity == .event {
                BarMark(x: .value("Time", bar.start), y: .value("Spend", height), width: .fixed(selected ? 5 : 3))
                    .cornerRadius(1)
                    .foregroundStyle(fill)
                    .accessibilityLabel(self.history.help(bar))
            } else {
                let end = min(bar.end, self.now)
                let inset = max(0, end.timeIntervalSince(bar.start)) * 0.035
                let start = bar.start.addingTimeInterval(inset)
                let finish = end.addingTimeInterval(-inset)
                RectangleMark(
                    xStart: .value("Period start", start),
                    xEnd: .value("Period end", finish),
                    yStart: .value("Empty", 0),
                    yEnd: .value("Spend", height))
                    .cornerRadius(2)
                    .foregroundStyle(fill)
                    .accessibilityLabel(self.history.help(bar))
                RuleMark(
                    xStart: .value("Period start", start),
                    xEnd: .value("Period end", finish),
                    y: .value("Spend", height))
                    .lineStyle(StrokeStyle(lineWidth: selected ? 1.5 : 0.8, lineCap: .round))
                    .foregroundStyle(ink)
                    .accessibilityHidden(true)
            }
        }
    }
}
