import CodexBarCore
import Foundation

/// One chart-time projection for the dial. Live presentation stays intact while the pointer inspects history.
@MainActor
enum NativeOrbitHistoricalInspection {
    static func windows(
        account: NativeOrbitAccountPresentation,
        date: Date?,
        now: Date,
        days: Int,
        preparedLanes: [NativeOrbitHistoryWidget.Lane]? = nil) -> [UsageWindow]
    {
        let windows = account.gauge.resolvedWindows
        guard let date else { return windows }
        let widget = NativeOrbitHistoryWidget(
            histories: account.history,
            now: now,
            days: days,
            quotaLabels: account.quotaLabels,
            quotaWindows: account.quotaWindows,
            provider: UsageProvider(rawValue: account.gauge.provider),
            preparedLanes: preparedLanes)
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
                let units = min(24, max(1, Int(ceil(period / (period >= 86400 ? 86400 : 3600)))))
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

    private static func historyID(_ window: UsageWindow, provider: String) -> String {
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
