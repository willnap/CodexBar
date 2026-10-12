import Crypto
import Foundation

/// Retains organization-attributed daily totals after Claude Code prunes the transcripts they came from.
/// Holds only metered aggregates keyed by a hashed ownership receipt: no transcript content, credentials or paths.
enum ClaudeOrganizationUsageArchive {
    private static let version = 2
    static let retentionDays = 400
    private static let maximumBytes = 16 * 1024 * 1024
    static let fileName = "daily-v2.json"

    struct Document: Codable, Equatable {
        var version: Int
        var timeZoneIdentifier: String
        var attributionStartUnixMs: Int64?
        /// Daily entries per owner fingerprint, sorted by date.
        var owners: [String: [CostUsageDailyReport.Entry]]
    }

    static func fingerprint(organizationID: String, timeZone: String) -> String {
        let data = Data(["claude-transcript-organization", organizationID, timeZone].joined(separator: "\u{0}").utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func defaultRoot() -> URL? {
        guard !TestProcessSafety.isRunning else { return nil }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("CodexBar/claude-organization-usage", isDirectory: true)
    }

    /// A missing, unreadable, foreign-zone or future-schema archive contributes nothing and is never trusted.
    static func load(root: URL?, timeZoneIdentifier: String) -> Document? {
        self.read(root: root, timeZoneIdentifier: timeZoneIdentifier).document
    }

    /// An unreadable or future-schema file is not permission to replace somebody else's data.
    static func read(root: URL?, timeZoneIdentifier: String) -> (document: Document?, canWrite: Bool) {
        guard let url = root?.appendingPathComponent(self.fileName) else { return (nil, false) }
        guard FileManager.default.fileExists(atPath: url.path) else { return (nil, true) }
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= self.maximumBytes,
              let data = try? Data(contentsOf: url),
              let document = try? JSONDecoder().decode(Document.self, from: data),
              document.version == self.version
        else { return (nil, false) }
        // Daily keys belong to one zone; another zone's archive is replaced rather than reinterpreted.
        return document.timeZoneIdentifier == timeZoneIdentifier ? (document, true) : (nil, true)
    }

    static func save(_ document: Document, root: URL?) {
        guard let root else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(document), data.count <= self.maximumBytes else { return }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try data.write(to: root.appendingPathComponent(self.fileName), options: .atomic)
            self.removeLegacyChunkArchives(in: root)
        } catch {
            // Optional retention must not suppress live transcript observations.
        }
    }

    /// Version 1 stored up to 100,000 streaming chunks per owner (about four busy days). Daily totals replace it.
    private static func removeLegacyChunkArchives(in root: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        for name in names where name.count == 69 && name.hasSuffix(".json")
            && name.dropLast(5).allSatisfy(\.isHexDigit)
        {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(name))
        }
    }

    /// Live transcripts own every day they still describe in full. A day whose archived total exceeds the live
    /// one lost transcripts to pruning, so the archived total remains the better measurement.
    static func merge(
        live: [CostUsageDailyReport.Entry],
        archived: [CostUsageDailyReport.Entry]) -> (entries: [CostUsageDailyReport.Entry], usedArchive: Bool)
    {
        var byDate = Dictionary(live.map { ($0.date, $0) }, uniquingKeysWith: { _, newer in newer })
        var usedArchive = false
        for entry in archived {
            guard let current = byDate[entry.date] else {
                byDate[entry.date] = entry
                usedArchive = true
                continue
            }
            if (entry.totalTokens ?? 0) > (current.totalTokens ?? 0) {
                byDate[entry.date] = entry
                usedArchive = true
            }
        }
        return (byDate.values.sorted { $0.date < $1.date }, usedArchive)
    }

    static func retained(
        _ entries: [CostUsageDailyReport.Entry],
        now: Date,
        calendar: Calendar) -> [CostUsageDailyReport.Entry]
    {
        let start = calendar.date(
            byAdding: .day,
            value: -(self.retentionDays - 1),
            to: calendar.startOfDay(for: now)) ?? now
        let startKey = CostUsageLocalDay.key(from: start, calendar: calendar)
        let todayKey = CostUsageLocalDay.key(from: now, calendar: calendar)
        return entries.filter { $0.date >= startKey && $0.date <= todayKey }
    }
}
