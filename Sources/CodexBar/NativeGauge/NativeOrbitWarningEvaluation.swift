import CodexBarCore
import Foundation

/// Rebuilds evidence-dependent lights for the moment being inspected. Current service/login faults are never
/// presented as recorded history, and a scheduled reset cannot keep a pre-reset exhaustion warning alive.
@MainActor
enum NativeOrbitWarningEvaluation {
    // swiftlint:disable:next function_parameter_count
    static func lights(
        account: NativeOrbitAccountPresentation,
        peers: [NativeOrbitAccountPresentation],
        projection: NativeOrbitAccountProjection,
        date: Date?,
        now: Date,
        days: Int,
        preparedLanes: [NativeOrbitHistoryWidget.Lane]? = nil,
        isProjecting: Bool = false) -> [NativeOrbitWarningLight]
    {
        guard let provider = UsageProvider(rawValue: account.gauge.provider) else { return [] }
        let moment = date ?? now
        let future = moment > now
        let prepared = account.metrics.preparedHistory.flatMap {
            $0.matches(account.history) ? $0.warningHistory : nil
        }
        // Evidence queries bound their own receipt searches to the inspected moment. Share the original source;
        // copying every quota prefix for each pointer move adds no evidence and defeats the retained indexes.
        let history = account.history
        let metrics: NativeOrbitAccountMetrics = if future {
            NativeOrbitMonetaryInspection.projectedMetrics(
                metrics: projection.liveMetrics, history: account.history, at: moment, now: now, projection: projection)
        } else {
            account.metrics.at(
                date,
                observedAt: account.updatedAt,
                history: account.history,
                historyCutoff: moment)
        }
        let windows = self.windows(
            account: account,
            date: date,
            now: now,
            projection: projection,
            histories: preparedLanes?.map(\.history) ?? history,
            days: days,
            preparedLanes: preparedLanes,
            isProjecting: isProjecting)
        let rates = windows.compactMap { window -> NamedRateWindow? in
            guard window.id != "monetary-budget", let used = window.usedFraction else { return nil }
            return NamedRateWindow(
                id: window.id,
                title: window.label,
                window: RateWindow(
                    usedPercent: used * 100,
                    windowMinutes: window.period >= 60 ? Int(window.period / 60) : nil,
                    resetsAt: window.countdown.flatMap { $0.isReliable ? $0.nextReset : nil },
                    resetDescription: nil))
        }
        let snapshot = rates.isEmpty ? nil : UsageSnapshot(
            primary: nil, secondary: nil, extraRateWindows: rates, updatedAt: moment)
        // Recomputed kinds also cover older callers that did not tag their measured warning evidence.
        let measuredKinds: Set<NativeOrbitWarningLight.Kind> = [
            .plan, .spend, .credits, .limit, .limitsChanged, .behindPace, .aheadOfPace, .farAheadPace,
            .spike, .idle, .resetLate, .earlyReset, .newSavedReset, .allExhausted, .usedElsewhere,
            .unpriced, .unattributed, .localLogs,
        ]
        var lights = date == nil ? account.warnings.filter {
            ($0.validUntil.map { now < $0 } ?? true)
                && $0.evidence != .measurement && ($0.evidence == .providerState
                    ? NativeOrbitWarningSignals.isCurrent(
                        account.updatedAt,
                        at: now,
                        maximumAge: NativeOrbitWarningSignals.maximumMoneyAge)
                    : !measuredKinds.contains($0.kind))
        } : []
        var measured = NativeOrbitWarningSignals.account(
            provider: provider,
            snapshot: snapshot,
            metrics: metrics,
            history: history,
            now: moment,
            days: days,
            observedAt: account.updatedAt,
            evidenceDate: future ? now : moment,
            includeObservedHistory: !future,
            preparedHistory: prepared)
        // The reconstructed snapshot describes the inspected instant, not a new provider observation.
        // Only an actual receipt can prove that a reset was still overdue after the grace period.
        measured.removeAll { $0.kind == .resetLate }
        if !future {
            measured += self.lateResetLights(account: account, windows: windows, history: history, date: date)
        }
        if future {
            // Neither activity in the future nor a new observed reset can be established by a projection.
            let observedOnly: Set<NativeOrbitWarningLight.Kind> = [
                .spike, .idle, .usedElsewhere, .unpriced, .unattributed, .earlyReset, .newSavedReset,
                .limitsChanged, .partialReading, .resetLate,
            ]
            measured.removeAll { observedOnly.contains($0.kind) }
            measured = measured.map { light in
                var light = light
                light.detail = "Projected: " + light.detail
                return light
            }
        }
        lights += measured
        if date == nil {
            func peer(_ row: NativeOrbitAccountPresentation) -> NativeOrbitPeerWarningSignals.Account {
                let windows = self.windows(
                    account: row,
                    date: nil,
                    now: now,
                    projection: nil,
                    histories: [],
                    days: days)
                return .init(
                    id: row.id,
                    provider: row.gauge.provider,
                    label: row.label,
                    isActive: row.isActive,
                    limits: Dictionary(windows.compactMap { window in
                        window.usedFraction.map { (window.id, $0) }
                    }, uniquingKeysWith: max))
            }
            lights += NativeOrbitPeerWarningSignals.lights(for: peer(account), peers: peers.map(peer))
        }
        return NativeOrbitWarningLight.reconciled(lights)
    }

    private static func lateResetLights(
        account: NativeOrbitAccountPresentation,
        windows: [UsageWindow],
        history: [PlanUtilizationSeriesHistory],
        date: Date?) -> [NativeOrbitWarningLight]
    {
        windows.compactMap { window in
            guard window.usedFraction == 1, window.countdown?.isReliable == true,
                  let reset = window.countdown?.nextReset else { return nil }
            let observed: Date?
            if let date {
                let id = NativeOrbitHistoricalInspection.historyID(window, provider: account.gauge.provider)
                let receipt = self.latestMeasuredReceipt(
                    in: history, ids: [id, window.id], through: date)
                observed = receipt.flatMap {
                    $0.usedPercent.isFinite && $0.usedPercent >= 100 && $0.resetsAt == reset ? $0.capturedAt : nil
                }
            } else {
                observed = account.updatedAt
            }
            guard let observed, observed.timeIntervalSince(reset) > 600 else { return nil }
            let title = NativeOrbitWarningSignals.quotaTitle(minutes: window.period >= 60
                ? Int(window.period / 60) : nil)
            return NativeOrbitWarningLight(
                .resetLate,
                .caution,
                "\(window.label) still reports 100% after its scheduled reset.",
                tooltipDetail: "\(title) still exhausted after reset.")
        }
    }

    /// Histories are chronologically ordered by their initializer. Find each lane's last real receipt without
    /// flattening/copying every entry; equal-time receipts retain their original first-source precedence.
    private static func latestMeasuredReceipt(
        in histories: [PlanUtilizationSeriesHistory],
        ids: [String],
        through date: Date) -> PlanUtilizationHistoryEntry?
    {
        var latest: PlanUtilizationHistoryEntry?
        for lane in histories where ids.contains(lane.name.rawValue) {
            var lower = 0
            var upper = lane.entries.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if lane.entries[middle].capturedAt <= date { lower = middle + 1 } else { upper = middle }
            }
            while lower > 0 {
                let time = lane.entries[lower - 1].capturedAt
                var first = lower - 1
                while first > 0, lane.entries[first - 1].capturedAt == time {
                    first -= 1
                }
                if let receipt = lane.entries[first..<lower].first(where: { $0.historicalPeriod == nil }) {
                    if latest == nil || receipt.capturedAt > latest?.capturedAt ?? .distantPast { latest = receipt }
                    break
                }
                lower = first
            }
        }
        return latest
    }

    // swiftlint:disable:next function_parameter_count
    private static func windows(
        account: NativeOrbitAccountPresentation,
        date: Date?,
        now: Date,
        projection: NativeOrbitAccountProjection?,
        histories: [PlanUtilizationSeriesHistory],
        days: Int,
        preparedLanes: [NativeOrbitHistoryWidget.Lane]? = nil,
        isProjecting: Bool = false) -> [UsageWindow]
    {
        let windows = NativeOrbitHistoricalInspection.windows(
            account: account,
            date: date,
            now: now,
            days: days,
            preparedLanes: preparedLanes,
            projection: projection,
            isProjecting: isProjecting)
        if let date, date > now, let projection {
            return NativeOrbitHistoricalInspection.projectedWindows(
                windows, provider: account.gauge.provider, projection: projection, date: date)
        }
        let moment = date ?? now
        return windows.map { original in
            var window = original
            let observed: Date?
            if date != nil {
                let id = NativeOrbitHistoricalInspection.historyID(original, provider: account.gauge.provider)
                observed = self.latestMeasuredReceipt(
                    in: histories, ids: [id, original.id], through: moment)?.capturedAt
            } else {
                observed = account.updatedAt
            }
            if !NativeOrbitWarningSignals.isCurrent(
                observed,
                at: moment,
                maximumAge: NativeOrbitWarningSignals.maximumQuotaAge)
                || (window.countdown?.nextReset.map { (observed ?? .distantPast) < $0 && $0 <= moment } ?? false)
            {
                window.used = nil
            }
            return window
        }
    }
}
