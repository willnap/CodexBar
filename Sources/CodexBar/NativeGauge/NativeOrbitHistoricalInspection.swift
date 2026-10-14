import CodexBarCore
import Foundation

/// One chart-time projection for the dial. Live presentation stays intact while the pointer inspects history or
/// the projected future.
@MainActor
enum NativeOrbitHistoricalInspection {
    static func windows(
        account: NativeOrbitAccountPresentation,
        date: Date?,
        now: Date,
        days: Int,
        preparedLanes: [NativeOrbitHistoryWidget.Lane]? = nil,
        projection: NativeOrbitAccountProjection? = nil,
        isProjecting: Bool = false) -> [UsageWindow]
    {
        let windows = account.gauge.resolvedWindows
        guard let date else { return windows }
        if date > now, let projection {
            return self.projectedWindows(windows, provider: account.gauge.provider, projection: projection, date: date)
        }
        // The chart a pointer hovers: while projecting it reaches back the full span, not just to the range's start.
        var widget = NativeOrbitHistoryWidget(
            histories: account.history,
            now: now,
            days: days,
            quotaLabels: account.quotaLabels,
            quotaWindows: account.quotaWindows,
            provider: UsageProvider(rawValue: account.gauge.provider),
            preparedLanes: preparedLanes)
        widget.isProjecting = isProjecting
        let lanes = widget.lanes
        return windows.map { window in
            var result = window
            let id = self.historyID(window, provider: account.gauge.provider)
            let lane = lanes.first { $0.history.name.rawValue == id }
                ?? lanes.first { $0.history.name.rawValue == window.id }
            // Server-period totals are discrete points, not a measurement of every quota at that instant.
            guard let lane, let point = widget.nearest(lane, to: date), point.id.historicalPeriod == nil else {
                result.used = nil
                if var countdown = result.countdown {
                    countdown.nextReset = nil
                    countdown.isReliable = false
                    result.countdown = countdown
                }
                return result
            }
            result.used = (100 - point.available) / 100
            result.limit = 1
            result.unit = "fraction"
            if let period = point.period {
                result.period = period
                let units = self.countdownUnits(period)
                result.countdown = ResetCountdown(
                    units: units,
                    secondsPerUnit: period / Double(units),
                    nextReset: point.id.resetsAt,
                    isReliable: point.id.resetsAt != nil)
            } else {
                result.countdown = nil
            }
            return result
        }
    }

    /// Each window's predicted usage at a future instant, with the countdown running to the reset scheduled after
    /// it (windows that reset before the instant have started over). No projection for a lane: unknown.
    static func projectedWindows(
        _ windows: [UsageWindow],
        provider: String,
        projection: NativeOrbitAccountProjection,
        date: Date) -> [UsageWindow]
    {
        windows.map { window in
            var result = window
            guard let lane = projection.lane(self.historyID(window, provider: provider))
                ?? projection.lane(window.id)
            else {
                result.used = nil
                if var countdown = result.countdown {
                    countdown.nextReset = nil
                    countdown.isReliable = false
                    result.countdown = countdown
                }
                return result
            }
            result.used = lane.used(at: date) / 100
            result.limit = 1
            result.unit = "fraction"
            let next = lane.nextReset(after: date)
            if let period = lane.period {
                result.period = period
                result.countdown = ResetCountdown(
                    units: self.countdownUnits(period),
                    secondsPerUnit: period / Double(self.countdownUnits(period)),
                    nextReset: next,
                    isReliable: next != nil)
            } else if var countdown = result.countdown {
                countdown.nextReset = next
                countdown.isReliable = next != nil && countdown.isReliable
                result.countdown = countdown
            }
            return result
        }
    }

    private static func countdownUnits(_ period: TimeInterval) -> Int {
        min(24, max(1, Int(ceil(period / (period >= 86400 ? 86400 : 3600)))))
    }

    static func historyID(_ window: UsageWindow, provider: String) -> String {
        // Provider-specific by design: Codex's reconciled display names differ from its raw quota slots.
        if provider == UsageProvider.codex.rawValue {
            if window.id == "session" { return "nativeQuota:primary" }
            if window.id == "weekly" || (window.id == "primary" && window.period == 604_800) {
                return "nativeQuota:secondary"
            }
        }
        return "nativeQuota:" + window.id
    }
}
