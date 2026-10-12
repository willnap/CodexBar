import CoreFoundation
import Foundation

/// A measured Claude Desktop window. The writer records an organization, not an account principal.
package struct NativeClaudeDesktopHistoryPoint: Codable, Hashable, Sendable {
    package let timestamp: Date
    package let organizationUUID: String?
    package let windowKey: String
    package let usedPercent: Double
}

package actor NativeClaudeDesktopHistory {
    package static let shared = NativeClaudeDesktopHistory()
    private static let retention: TimeInterval = 32 * 86400
    private static let maximumFileBytes = 64 * 1024 * 1024
    private let sourceURLs: [URL]
    private let cacheURL: URL?
    private var retained: Set<NativeClaudeDesktopHistoryPoint> = []
    /// Observable save failure only; never exposes paths, organization metadata, or underlying error text.
    package private(set) var persistenceFailed = false

    private struct Cache: Codable {
        let version: Int
        let points: [NativeClaudeDesktopHistoryPoint]
    }

    private enum HistoryError: Error { case invalidFormat }

    /// Tests must supply contained fixtures; Foundation's real home can ignore the HOME environment.
    package init(sourceURLs: [URL]? = nil, cacheURL: URL? = nil) {
        if TestProcessSafety.isRunning {
            self.sourceURLs = sourceURLs ?? []
            self.cacheURL = cacheURL
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? home.appendingPathComponent("Library/Application Support")
            self.sourceURLs = sourceURLs ?? ["Claude", "Claude-3p"].map {
                support.appendingPathComponent($0, isDirectory: true)
                    .appendingPathComponent("plan-usage-history.json")
            }
            self.cacheURL = cacheURL ?? support
                .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.steipete.codexbar", isDirectory: true)
                .appendingPathComponent("native-claude-desktop-history.json")
        }
    }

    package var hasConfiguredPaths: Bool {
        !self.sourceURLs.isEmpty || self.cacheURL != nil
    }

    /// Official Desktop v2 saves {t: milliseconds, org: UUID|null, u: {short window key: raw percent}}.
    /// V1 has fh/sd directly and no organization. Unknown numeric windows remain recoverable in the cache,
    /// but their cadence/model meaning must be verified independently before rendering them.
    package static func parse(_ data: Data, now: Date) throws -> [NativeClaudeDesktopHistoryPoint] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = number(root["version"]), version == 1 || version == 2,
              let samples = root["samples"] as? [Any] else { throw HistoryError.invalidFormat }
        var points: Set<NativeClaudeDesktopHistoryPoint> = []
        for sample in samples {
            try Task.checkCancellation()
            guard let sample = sample as? [String: Any], let milliseconds = Self.number(sample["t"]) else {
                continue
            }
            let organization: String?
            let windows: [String: Any]
            if version == 2 {
                guard let rawOrganization = sample["org"], let rawWindows = sample["u"] as? [String: Any] else {
                    continue
                }
                if rawOrganization is NSNull {
                    organization = nil
                } else {
                    guard let value = rawOrganization as? String, let uuid = UUID(uuidString: value) else { continue }
                    organization = uuid.uuidString.lowercased()
                }
                windows = rawWindows
            } else {
                organization = nil
                windows = ["fh": sample["fh"] ?? NSNull(), "sd": sample["sd"] ?? NSNull()]
            }
            let timestamp = Date(timeIntervalSince1970: milliseconds / 1000)
            for (window, rawValue) in windows {
                guard let used = Self.number(rawValue) else { continue }
                let point = NativeClaudeDesktopHistoryPoint(
                    timestamp: timestamp, organizationUUID: organization, windowKey: window, usedPercent: used)
                if Self.isRetained(point, now: now) { points.insert(point) }
            }
        }
        return points.sorted(by: Self.precedes)
    }

    /// No account-owned history is mutated. Org-only and anonymous rows remain source-tagged, including
    /// previously observed rows that Desktop prunes after 30 days or temporarily stops publishing.
    package func load(now: Date = Date()) -> [NativeClaudeDesktopHistoryPoint] {
        guard !Task.isCancelled else { return self.retained.sorted(by: Self.precedes) }
        if let cacheURL, self.sourceURLs.contains(where: {
            $0.resolvingSymlinksInPath().path == cacheURL.resolvingSymlinksInPath().path
        }) { return [] }
        let cached = self.cacheURL.flatMap { url -> [NativeClaudeDesktopHistoryPoint]? in
            guard let data = Self.read(url), let cache = try? JSONDecoder().decode(Cache.self, from: data),
                  cache.version == 1 else { return nil }
            return cache.points
        } ?? []
        var merged = Set((cached + Array(self.retained)).filter { Self.isRetained($0, now: now) })
        for source in self.sourceURLs {
            guard !Task.isCancelled else { return self.retained.sorted(by: Self.precedes) }
            if let data = Self.read(source), let points = try? Self.parse(data, now: now) { merged.formUnion(points) }
        }
        guard !Task.isCancelled else { return self.retained.sorted(by: Self.precedes) }
        self.retained = merged
        let points = merged.sorted(by: Self.precedes)
        if points != cached, let cacheURL {
            guard Self.isContainedFile(cacheURL) else {
                self.persistenceFailed = true
                return points
            }
            do {
                let data = try JSONEncoder().encode(Cache(version: 1, points: points))
                guard !Task.isCancelled else { return points }
                try FileManager.default.createDirectory(
                    at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: cacheURL, options: .atomic)
                self.persistenceFailed = false
            } catch {
                // Retain the observations in memory. A later load retries against the still-older disk cache.
                self.persistenceFailed = true
            }
        } else {
            self.persistenceFailed = false
        }
        return points
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue.isFinite ? number.doubleValue : nil
    }

    private static func isRetained(_ point: NativeClaudeDesktopHistoryPoint, now: Date) -> Bool {
        point.timestamp.timeIntervalSinceReferenceDate.isFinite
            && point.timestamp >= now.addingTimeInterval(-self.retention) && point.timestamp <= now
            && point.usedPercent.isFinite && point.usedPercent >= 0
            && !point.windowKey.isEmpty && point.windowKey.utf8.count <= 128
            && (point.organizationUUID == nil || point.organizationUUID.flatMap(UUID.init(uuidString:))?
                .uuidString.lowercased() == point.organizationUUID)
    }

    private static func precedes(
        _ lhs: NativeClaudeDesktopHistoryPoint,
        _ rhs: NativeClaudeDesktopHistoryPoint) -> Bool
    {
        if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
        if lhs.organizationUUID != rhs.organizationUUID {
            return (lhs.organizationUUID ?? "") < (rhs.organizationUUID ?? "")
        }
        if lhs.windowKey != rhs.windowKey { return lhs.windowKey < rhs.windowKey }
        return lhs.usedPercent < rhs.usedPercent
    }

    private static func isContainedFile(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath()
        return url.resolvingSymlinksInPath().path == parent.appendingPathComponent(url.lastPathComponent).path
    }

    private static func read(_ url: URL) -> Data? {
        guard !Task.isCancelled, self.isContainedFile(url),
              (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: Self.maximumFileBytes + 1),
              data.count <= Self.maximumFileBytes else { return nil }
        return data
    }
}
