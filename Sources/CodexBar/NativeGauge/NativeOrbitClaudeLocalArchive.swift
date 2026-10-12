import CodexBarCore
import Foundation

enum NativeOrbitClaudeLocalArchive {
    private struct Lane: Hashable {
        let name: PlanUtilizationSeriesName
        let windowMinutes: Int
    }

    static var quotaLabels: [String: String] {
        [
            "nativeQuota:primary": L("Session"),
            "nativeQuota:secondary": L("Weekly"),
            "nativeQuota:claude-weekly-scoped-fable": "Fable only",
        ]
    }

    static func mergedHistories(
        fileHistories: [PlanUtilizationSeriesHistory],
        buckets: PlanUtilizationHistoryBuckets?,
        excludingOwnerKeys: Set<String>,
        // Provider-specific by design: Claude file observations never enter another provider's archive.
        provider: UsageProvider = .claude) -> [PlanUtilizationSeriesHistory]
    {
        guard provider == .claude else { return [] }
        var fragments = fileHistories
        if let buckets {
            fragments += buckets.unscoped
            for key in buckets.accounts.keys.sorted() where !excludingOwnerKeys.contains(key) {
                fragments += buckets.accounts[key] ?? []
            }
        }
        var entries: [Lane: Set<PlanUtilizationHistoryEntry>] = [:]
        for fragment in fragments where !fragment.entries.isEmpty {
            let lane = Lane(name: fragment.name, windowMinutes: fragment.windowMinutes)
            entries[lane, default: []].formUnion(fragment.entries)
        }
        return entries.map { lane, points in
            PlanUtilizationSeriesHistory(
                name: lane.name, windowMinutes: lane.windowMinutes, entries: Array(points))
        }.sorted(by: PlanUtilizationSeriesHistory.precedes)
    }

    static func histories(_ points: [NativeClaudeLocalArchivePoint]) -> [PlanUtilizationSeriesHistory] {
        guard !points.isEmpty else { return [] }
        return [
            PlanUtilizationSeriesHistory(name: "nativeQuota:primary", windowMinutes: 300, entries: points.map {
                .init(capturedAt: $0.timestamp, usedPercent: $0.sessionUsedFraction * 100, resetsAt: nil)
            }),
            PlanUtilizationSeriesHistory(name: "nativeQuota:secondary", windowMinutes: 10080, entries: points.map {
                .init(capturedAt: $0.timestamp, usedPercent: $0.weeklyUsedFraction * 100, resetsAt: nil)
            }),
        ]
    }
}
