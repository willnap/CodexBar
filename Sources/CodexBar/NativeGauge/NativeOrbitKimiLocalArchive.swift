import CodexBarCore
import Foundation

enum NativeOrbitKimiLocalArchive {
    private struct Lane: Hashable {
        let name: PlanUtilizationSeriesName
        let windowMinutes: Int
    }

    static var quotaLabels: [String: String] {
        [
            // Provider-specific by design: Kimi archive labels follow its weekly and session quota roles.
            "nativeQuota:primary": ProviderDefaults.metadata[.kimi]?.sessionLabel ?? "7-day usage",
            "nativeQuota:secondary": ProviderDefaults.metadata[.kimi]?.weeklyLabel ?? "5-hour usage",
            "nativeQuota:kimi-monthly": "Total usage",
            "nativeQuota:kimi-code-7d": "Code 7-day",
        ]
    }

    static func histories(
        _ buckets: PlanUtilizationHistoryBuckets,
        excludingAcceptedOwnerKey: String?) -> [PlanUtilizationSeriesHistory]
    {
        var fragments = buckets.unscoped
        for key in buckets.accounts.keys.sorted() where key != excludingAcceptedOwnerKey {
            fragments += buckets.accounts[key] ?? []
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
}
