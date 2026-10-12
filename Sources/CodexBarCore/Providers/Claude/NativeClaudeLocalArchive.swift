import CoreFoundation
import Foundation

package struct NativeClaudeLocalArchivePoint: Codable, Equatable, Sendable {
    package let timestamp: Date
    package let sessionUsedFraction: Double
    package let weeklyUsedFraction: Double
}

package actor NativeClaudeLocalArchive {
    package static let shared = NativeClaudeLocalArchive()
    private static let retention: TimeInterval = 32 * 86400
    private static let maximumFileBytes = 64 * 1024 * 1024
    private let sourceURL: URL?
    private let cacheURL: URL?
    private var retained: [NativeClaudeLocalArchivePoint] = []

    private struct Cache: Codable {
        let version: Int
        let points: [NativeClaudeLocalArchivePoint]
    }

    private enum ArchiveError: Error { case invalidFormat }

    /// Explicit fixture URLs are the only filesystem access available in a test process. Foundation's
    /// real home directory can ignore HOME, so environment overrides are not an isolation mechanism.
    package init(sourceURL: URL? = nil, cacheURL: URL? = nil) {
        if TestProcessSafety.isRunning {
            self.sourceURL = sourceURL
            self.cacheURL = cacheURL
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            self.sourceURL = sourceURL ?? home.appendingPathComponent(".config/claude-usage-bar/history.json")
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? home.appendingPathComponent("Library/Application Support")
            self.cacheURL = cacheURL ?? support
                .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.steipete.codexbar", isDirectory: true)
                .appendingPathComponent("native-claude-local-archive.json")
        }
    }

    package var hasConfiguredPaths: Bool {
        self.sourceURL != nil || self.cacheURL != nil
    }

    /// The companion records used fractions, with no account or reset metadata. Preserve those measurements
    /// independently; neither the active CLI login nor a displayed companion email proves archive ownership.
    package static func parse(_ data: Data, now: Date) throws -> [NativeClaudeLocalArchivePoint] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["dataPoints"] as? [Any] else { throw ArchiveError.invalidFormat }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let whole = ISO8601DateFormatter()
        var points: [Date: NativeClaudeLocalArchivePoint] = [:]
        for row in rows {
            try Task.checkCancellation()
            guard let row = row as? [String: Any], let stamp = row["timestamp"] as? String,
                  let timestamp = fractional.date(from: stamp) ?? whole.date(from: stamp),
                  let session = Self.fraction(row["pct5h"]), let weekly = Self.fraction(row["pct7d"]) else { continue }
            let point = NativeClaudeLocalArchivePoint(
                timestamp: timestamp, sessionUsedFraction: session, weeklyUsedFraction: weekly)
            if Self.isRetained(point, now: now) { points[timestamp] = point }
        }
        return points.values.sorted { $0.timestamp < $1.timestamp }
    }

    /// Actor isolation keeps bounded file I/O and JSON decoding off the native popup's main executor.
    package func load(now: Date = Date()) -> [NativeClaudeLocalArchivePoint] {
        guard !Task.isCancelled else { return self.retained }
        if let sourceURL = self.sourceURL, let cacheURL = self.cacheURL,
           sourceURL.resolvingSymlinksInPath().path == cacheURL.resolvingSymlinksInPath().path
        {
            return []
        }
        var canReplaceCache = true
        let cached = self.cacheURL.flatMap { url -> [NativeClaudeLocalArchivePoint]? in
            guard let data = Self.read(url), let cache = try? JSONDecoder().decode(Cache.self, from: data),
                  cache.version == 1
            else {
                // An absent file is a new cache; unreadable or newer files must remain recoverable.
                canReplaceCache = !FileManager.default.fileExists(atPath: url.path)
                return nil
            }
            return cache.points
        } ?? []
        var merged: [Date: NativeClaudeLocalArchivePoint] = [:]
        for point in cached + self.retained where Self.isRetained(point, now: now) {
            merged[point.timestamp] = point
        }
        if let sourceURL = self.sourceURL, let data = Self.read(sourceURL),
           let source = try? Self.parse(data, now: now)
        {
            for point in source {
                merged[point.timestamp] = point
            }
        }
        guard !Task.isCancelled else { return self.retained }
        let points = merged.values.sorted { $0.timestamp < $1.timestamp }
        self.retained = points
        if canReplaceCache, points != cached, let cacheURL = self.cacheURL, Self.isContainedFile(cacheURL) {
            // The dedicated cache has exact Codable Date doubles and never enters account-owned history stores.
            if let data = try? JSONEncoder().encode(Cache(version: 1, points: points)) {
                try? FileManager.default.createDirectory(
                    at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: cacheURL, options: .atomic)
            }
        }
        return points
    }

    private static func fraction(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let fraction = number.doubleValue
        return fraction.isFinite && fraction >= 0 ? fraction : nil
    }

    private static func isRetained(_ point: NativeClaudeLocalArchivePoint, now: Date) -> Bool {
        point.timestamp.timeIntervalSinceReferenceDate.isFinite
            && point.timestamp >= now.addingTimeInterval(-self.retention) && point.timestamp <= now
            && point.sessionUsedFraction.isFinite && point.sessionUsedFraction >= 0
            && point.weeklyUsedFraction.isFinite && point.weeklyUsedFraction >= 0
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
