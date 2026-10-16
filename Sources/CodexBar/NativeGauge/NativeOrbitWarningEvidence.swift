import CodexBarCore
import Foundation

/// Availability describes what can be shown. An alarm additionally needs evidence of a loss or failure.
enum NativeOrbitWarningEvidence {
    static func quotaLights(
        provider: UsageProvider,
        snapshot: UsageSnapshot,
        history: [PlanUtilizationSeriesHistory],
        now: Date) -> [NativeOrbitWarningLight]
    {
        // A synthetic primary represents no active session, rather than a failed session measurement.
        let absent = [("secondary", snapshot.secondary), ("tertiary", snapshot.tertiary)]
            .compactMap { id, window -> (String, RateWindow)? in
                guard let window, window.isSyntheticPlaceholder else { return nil }
                return (id, window)
            }
            + (snapshot.extraRateWindows ?? []).filter { !$0.usageKnown }.map { ($0.id, $0.window) }
        var lights: [NativeOrbitWarningLight] = []
        for (id, window) in absent {
            if let expiry = self.activeQuotaExpiry(
                id: "nativeQuota:" + id,
                minutes: window.windowMinutes,
                before: snapshot.updatedAt,
                history: history,
                now: now)
            {
                var light = NativeOrbitWarningLight(
                    .partialReading, .caution, "Active quota missing.", tooltipDetail: "Active quota missing.")
                light.validUntil = expiry
                lights.append(light)
            }
        }
        for (id, window) in UsageStore.nativeOrbitQuotaWindowMap(provider: provider, snapshot: snapshot)
            where window.usedPercent > 0 && window.resetsAt == nil
        {
            if let expiry = self.activeQuotaExpiry(
                id: id, minutes: window.windowMinutes, before: snapshot.updatedAt, history: history, now: now)
            {
                let title = NativeOrbitWarningSignals.quotaTitle(minutes: window.windowMinutes)
                var light = NativeOrbitWarningLight(
                    .notReported,
                    .caution,
                    "\(title) lost its reset time.",
                    tooltipDetail: "\(title) reset time missing.")
                light.validUntil = expiry
                lights.append(light)
            }
        }
        return lights.map { light in
            var light = light
            light.evidence = .providerState
            return light
        }
    }

    private static func activeQuotaExpiry(
        id: String,
        minutes: Int?,
        before measured: Date,
        history: [PlanUtilizationSeriesHistory],
        now: Date) -> Date?
    {
        guard let minutes, minutes > 0 else { return nil }
        var previous: PlanUtilizationHistoryEntry?
        var previousMinutes: Int?
        for lane in history where lane.name.rawValue == id {
            // Histories are already chronological. Search the strict measurement boundary, then skip only
            // aggregate timestamp groups: the first real receipt at an equal time keeps source precedence.
            var lower = 0
            var upper = lane.entries.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if lane.entries[middle].capturedAt < measured { lower = middle + 1 } else { upper = middle }
            }
            while lower > 0 {
                let time = lane.entries[lower - 1].capturedAt
                var first = lower - 1
                while first > 0, lane.entries[first - 1].capturedAt == time {
                    first -= 1
                }
                if let entry = lane.entries[first..<lower].first(where: { $0.historicalPeriod == nil }) {
                    if previous.map({ $0.capturedAt < entry.capturedAt }) ?? true {
                        previous = entry
                        previousMinutes = lane.windowMinutes
                    }
                    break
                }
                lower = first
            }
        }
        guard let previous, previousMinutes == minutes,
              previous.usedPercent.isFinite, previous.usedPercent > 0,
              let reset = previous.resetsAt, previous.capturedAt <= now
        else { return nil }
        let age = NativeOrbitWarningSignals.maximumQuotaAge
        let expiry = min(reset, measured.addingTimeInterval(age), previous.capturedAt.addingTimeInterval(age))
        return expiry > now ? expiry : nil
    }

    static func wasFunded(
        _ balance: NativeOrbitReportedBalance,
        history: [PlanUtilizationSeriesHistory]) -> Bool
    {
        let previous = history.filter { $0.name.rawValue == "nativeMetric:balance" }.flatMap(\.entries)
            .filter { $0.capturedAt < balance.updatedAt }.sorted { $0.capturedAt > $1.capturedAt }
        for receipt in previous {
            // An unavailable reading or a different pool ends continuity. Never search through it for funding.
            guard let prior = receipt.nativeMetrics?.balance,
                  prior.value.isFinite, prior.updatedAt <= receipt.capturedAt,
                  prior.unit.uppercased() == balance.unit.uppercased(), prior.isWorkspace == balance.isWorkspace
            else { return false }
            if prior.value > 0 { return true }
        }
        // Credit usage can come from a monthly included allowance, so it does not prove a purchased pool existed.
        return false
    }
}
