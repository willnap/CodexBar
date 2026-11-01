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
        let timeline = NativeOrbitQuotaTimeline(history: account.history)
        let declared = timeline.declaredWindows(at: date)
        widget.selectedDate = date
        widget.preparedLanes = lanes
        let labels = widget.legendLabels
        var restored: [UsageWindow] = []
        var represented = Set<String>()
        // Historical membership comes from the inspected receipt, never from today's compact layout.
        for (index, lane) in lanes.enumerated() {
            let key = NativeOrbitQuotaTimeline.quotaID(
                lane.history, provider: UsageProvider(rawValue: account.gauge.provider)) ?? lane.history.name.rawValue
            guard !timeline.isAbsent(key, at: date), let point = widget.nearest(lane, to: date),
                  point.id.historicalPeriod == nil else { continue }
            let id = self.windowID(key, provider: account.gauge.provider)
            guard represented.insert(key).inserted else { continue }
            let definition = declared[key] ?? point.id.quotaDescriptor
            var window = self.restored(UsageWindow(
                id: id, label: definition?.label ?? labels[index], period: point.period ?? 1, used: nil), point: point)
            if let label = definition?.label { window.label = label }
            restored.append(window)
        }
        // A source may explicitly report an existing quota without reporting its utilization.
        for (key, definition) in declared.sorted(by: { $0.key < $1.key }) where !represented.contains(key) {
            restored.append(UsageWindow(
                id: self.windowID(key, provider: account.gauge.provider),
                label: definition.label ?? self.historicalLabel(definition),
                period: definition.period ?? 1,
                used: nil))
        }
        if restored.isEmpty {
            return [UsageWindow(id: "historical-unknown", label: L("Usage unknown"), period: 1, used: nil)]
        }
        // The symbol accepts three unique lanes. An exhausted historical allowance must remain visible even when
        // the account has accumulated more model-specific lanes than fit in that compact geometry.
        let selected = restored.enumerated().sorted { lhs, rhs in
            let leftExhausted = lhs.element.usedFraction == 1
            let rightExhausted = rhs.element.usedFraction == 1
            return leftExhausted == rightExhausted ? lhs.offset < rhs.offset : leftExhausted
        }.prefix(3).map(\.element)
        var historicalGauge = account.gauge
        historicalGauge.windows = selected
        return historicalGauge.resolvedWindows
    }

    private static func windowID(_ key: String, provider: String) -> String {
        let id = key.hasPrefix("nativeQuota:") ? String(key.dropFirst("nativeQuota:".count)) : key
        // Provider-specific by design: Codex dials use session/weekly IDs for their primary/secondary quota slots.
        if provider == UsageProvider.codex.rawValue {
            if id == "primary" { return "session" }
            if id == "secondary" { return "weekly" }
        }
        return id
    }

    private static func historicalLabel(_ definition: NativeOrbitQuotaDescriptor) -> String {
        switch definition.windowMinutes {
        case 300: "Session"
        case 10080: "Weekly"
        default: L("Usage unknown")
        }
    }

    private static func restored(_ window: UsageWindow, point: NativeOrbitHistoryWidget.Sample?) -> UsageWindow {
        var result = window
        // Server-period totals are discrete points, not a measurement of every quota at that instant.
        guard let point, point.id.historicalPeriod == nil else {
            result.used = nil
            if var countdown = result.countdown {
                countdown.nextReset = nil
                countdown.isReliable = false
                result.countdown = countdown
            }
            return result
        }
        result.used = (100 - point.available) / 100
        result.period = point.period ?? 1
        if let label = point.id.quotaDescriptor?.label { result.label = label }
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
