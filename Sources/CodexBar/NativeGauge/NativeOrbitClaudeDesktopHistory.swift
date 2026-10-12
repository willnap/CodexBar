import CodexBarCore
import Foundation

/// Desktop observations expose an organization, not the account principal that acquired them.
/// This projects a source scope; matching an organization alone must never adopt an account history bucket.
enum NativeOrbitClaudeDesktopHistory {
    static func histories(
        _ points: [NativeClaudeDesktopHistoryPoint],
        organizationUUID: String?) -> [PlanUtilizationSeriesHistory]
    {
        let scope: String?
        if let organizationUUID {
            guard let organization = UUID(uuidString: organizationUUID) else { return [] }
            scope = organization.uuidString.lowercased()
        } else {
            scope = nil
        }
        // The installed official writer's fh/sd fields are measured session/weekly percentages.
        // It does not persist named Fable limits; never reinterpret its legacy Opus key as Fable.
        let windows: [String: (PlanUtilizationSeriesName, Int)] = [
            "fh": ("nativeQuota:primary", 300),
            "sd": ("nativeQuota:secondary", 10080),
        ]
        var entries: [String: Set<PlanUtilizationHistoryEntry>] = [:]
        for point in points where point.organizationUUID == scope && windows[point.windowKey] != nil {
            guard point.usedPercent.isFinite, point.usedPercent >= 0 else { continue }
            entries[point.windowKey, default: []].insert(.init(
                capturedAt: point.timestamp, usedPercent: point.usedPercent, resetsAt: nil))
        }
        return entries.compactMap { key, observations -> PlanUtilizationSeriesHistory? in
            guard let (name, cadence) = windows[key] else { return nil }
            return PlanUtilizationSeriesHistory(name: name, windowMinutes: cadence, entries: Array(observations))
        }.sorted(by: PlanUtilizationSeriesHistory.precedes)
    }
}
