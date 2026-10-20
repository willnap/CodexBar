import CoreFoundation
import Foundation

/// A response observation belongs to its request organization, not an inferred account principal.
/// Desktop's diagnostic logger omits the timezone; an unresolved civil timestamp must not be plotted.
package struct NativeClaudeWebLogHistoryPoint: Codable, Hashable, Sendable {
    package let localTimestamp: String
    package let timestamp: Date?
    package let timeZoneIdentifier: String?
    package let organizationUUID: String
    package let windowKey: String
    package let usedPercent: Double
    package let resetsAt: Date?
    package let sourceField: String
}

package actor NativeClaudeWebLogHistory {
    package static let shared = NativeClaudeWebLogHistory()
    private static let maximumFileBytes = 64 * 1024 * 1024
    private let sourceURLs: [URL]
    private let cacheURL: URL?
    private let sourceTimeZone: TimeZone?
    private var retained: Set<NativeClaudeWebLogHistoryPoint> = []
    /// Sources whose points are already in `retained`, and the cache as last read or written.
    private var parsedSources: [URL: FileContentStamp] = [:]
    private var cacheSnapshot: (stamp: FileContentStamp, points: [NativeClaudeWebLogHistoryPoint])?
    package private(set) var persistenceFailed = false

    private struct Cache: Codable {
        let version: Int
        let points: [NativeClaudeWebLogHistoryPoint]
    }

    private enum HistoryError: Error { case invalidFormat }

    /// Only supply a timezone when it is established for the historical source, not merely today's zone.
    package init(sourceURLs: [URL]? = nil, cacheURL: URL? = nil, sourceTimeZone: TimeZone? = nil) {
        self.sourceTimeZone = sourceTimeZone
        if TestProcessSafety.isRunning {
            self.sourceURLs = sourceURLs ?? []
            self.cacheURL = cacheURL
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
            self.sourceURLs = sourceURLs ?? ["Claude", "Claude-3p"].flatMap { name in
                ["claude.ai-web.log", "claude.ai-web1.log", "claude.ai-web2.log"].map {
                    home.appendingPathComponent("Library/Logs/\(name)", isDirectory: true)
                        .appendingPathComponent($0)
                }
            }
            self.cacheURL = cacheURL ?? support
                .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.steipete.codexbar", isDirectory: true)
                .appendingPathComponent("native-claude-web-log-history.json")
        }
    }

    package var hasConfiguredPaths: Bool {
        !self.sourceURLs.isEmpty || self.cacheURL != nil
    }

    /// Accept the actual diagnostic response envelope only, never arbitrary transcript text or errors.
    /// Keep raw over-100 utilization. Fable requires an explicitly model-scoped resolved limit.
    package static func parse(_ data: Data, now: Date, timeZone: TimeZone? = nil) throws
        -> [NativeClaudeWebLogHistoryPoint]
    {
        guard let text = String(data: data, encoding: .utf8) else { throw HistoryError.invalidFormat }
        let prefix = " [error] [COMPLETION] Request failed "
        let utcFormatter = Self.formatter(timeZone: TimeZone(secondsFromGMT: 0)!)
        let sourceFormatter = timeZone.map(Self.formatter)
        var points: Set<NativeClaudeWebLogHistoryPoint> = []
        for line in text.split(separator: "\n") {
            try Task.checkCancellation()
            guard line.count > 19, line.dropFirst(19).hasPrefix(prefix) else { continue }
            let local = String(line.prefix(19))
            guard let civil = utcFormatter.date(from: local), utcFormatter.string(from: civil) == local,
                  civil <= now.addingTimeInterval(14 * 3600),
                  let bytes = String(line.dropFirst(19 + prefix.count)).data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  root["type"] as? String == "rate_limit_error", Self.number(root["statusCode"]) == 429,
                  root["method"] as? String == "POST", let endpoint = root["endpoint"] as? String,
                  let organization = Self.organization(from: endpoint),
                  let message = root["message"] as? String, let messageData = message.data(using: .utf8),
                  let response = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any],
                  response["type"] as? String == "exceeded_limit", let windows = response["windows"] as? [String: Any]
            else { continue }
            var timestamp = sourceFormatter?.date(from: local)
            if let value = timestamp, let sourceFormatter,
               sourceFormatter.string(from: value) != local
               || [-3600.0, 3600.0].contains(where: {
                   sourceFormatter.string(from: value.addingTimeInterval($0)) == local
               }) || value > now
            { timestamp = nil }
            let resolved = response["resolved"] as? [String: Any]
            let limit = resolved?["limit"] as? [String: Any]
            let scope = limit?["scope"] as? [String: Any]
            let model = scope?["model"] as? [String: Any]
            let isFable = limit?["kind"] as? String == "weekly_scoped"
                && (model?["display_name"] as? String)?.caseInsensitiveCompare("Fable") == .orderedSame
            var readings: [(String, Double, Date?, String)] = []
            for (key, name) in [("5h", "five_hour"), ("7d", "seven_day")] {
                guard let window = windows[key] as? [String: Any],
                      let value = Self.number(window["utilization"]), value >= 0 else { continue }
                readings.append((name, value * 100, Self.reset(window["resets_at"]), "windows.\(key).utilization"))
            }
            // No public contract establishes that 7d_oi itself is the resolved model quota.
            // Retain its exact measurement in an unclassified window; never relabel it Fable.
            if let window = windows["7d_oi"] as? [String: Any],
               let value = Self.number(window["utilization"]), value >= 0
            {
                readings.append((
                    "seven_day_overage_included",
                    value * 100,
                    Self.reset(window["resets_at"]),
                    "windows.7d_oi.utilization"))
            }
            if isFable, let value = Self.number(limit?["percent"]), value >= 0 {
                readings.append(("fable", value, Self.reset(limit?["resets_at"]), "resolved.limit.percent"))
            }
            for (window, value, reset, field) in readings where value.isFinite {
                points.insert(.init(
                    localTimestamp: local,
                    timestamp: timestamp,
                    timeZoneIdentifier: timeZone?.identifier,
                    organizationUUID: organization,
                    windowKey: window,
                    usedPercent: value,
                    resetsAt: reset,
                    sourceField: field))
            }
        }
        return points.sorted(by: Self.precedes)
    }

    /// Logs rotate independently of graph ranges. Preserve genuine old observations in this source cache.
    /// The cache never contains raw log messages, conversation UUIDs, headers or authentication fields.
    package func load(now: Date = Date()) -> [NativeClaudeWebLogHistoryPoint] {
        guard !Task.isCancelled else { return self.retained.sorted(by: Self.precedes) }
        if let cacheURL, self.sourceURLs.contains(where: {
            $0.resolvingSymlinksInPath().path == cacheURL.resolvingSymlinksInPath().path
        }) { return [] }
        var cached: [NativeClaudeWebLogHistoryPoint] = []
        var canReplaceCache = true
        if let cacheURL, FileManager.default.fileExists(atPath: cacheURL.path) {
            let stamp = FileContentStamp(cacheURL)
            if let snapshot = self.cacheSnapshot, snapshot.stamp == stamp {
                cached = snapshot.points
            } else if let data = Self.read(cacheURL), let cache = try? JSONDecoder().decode(Cache.self, from: data),
                      cache.version == 1, cache.points.allSatisfy(Self.valid)
            {
                cached = cache.points
                self.cacheSnapshot = stamp.map { ($0, cached) }
            } else {
                // Absence permits a new cache; unreadable or unknown existing data must survive recovery.
                canReplaceCache = false
                self.cacheSnapshot = nil
            }
        }
        var merged = Set(cached + Array(self.retained))
        var parsed: [URL: FileContentStamp] = [:]
        for source in self.sourceURLs {
            guard !Task.isCancelled else { return self.retained.sorted(by: Self.precedes) }
            let stamp = FileContentStamp(source)
            if let stamp, self.parsedSources[source] == stamp { continue }
            if let data = Self.read(source), let points = try? Self.parse(
                data,
                now: now,
                timeZone: self.sourceTimeZone)
            {
                merged.formUnion(points)
                parsed[source] = stamp
            }
        }
        guard !Task.isCancelled else { return self.retained.sorted(by: Self.precedes) }
        self.retained = merged
        self.parsedSources.merge(parsed) { $1 }
        let points = merged.sorted(by: Self.precedes)
        guard canReplaceCache else {
            self.persistenceFailed = true
            return points
        }
        if points != cached, let cacheURL {
            guard Self.isContainedFile(cacheURL) else {
                self.persistenceFailed = true
                return points
            }
            do {
                let data = try JSONEncoder().encode(Cache(version: 1, points: points))
                guard data.count <= Self.maximumFileBytes else {
                    self.persistenceFailed = true
                    return points
                }
                guard !Task.isCancelled else { return points }
                try FileManager.default.createDirectory(
                    at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: cacheURL, options: .atomic)
                self.cacheSnapshot = FileContentStamp(cacheURL).map { ($0, points) }
                self.persistenceFailed = false
            } catch { self.persistenceFailed = true }
        } else { self.persistenceFailed = false }
        return points
    }

    private static func formatter(timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.isLenient = false
        return formatter
    }

    private static func organization(from endpoint: String) -> String? {
        let segments = endpoint.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.count == 7, segments[0].isEmpty, segments[1] == "api",
              segments[2] == "organizations", segments[4] == "chat_conversations",
              segments[6] == "completion", UUID(uuidString: String(segments[5])) != nil else { return nil }
        return UUID(uuidString: String(segments[3]))?.uuidString.lowercased()
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue.isFinite ? number.doubleValue : nil
    }

    private static func reset(_ value: Any?) -> Date? {
        if let seconds = number(value) { return Date(timeIntervalSince1970: seconds) }
        if let text = value as? String { return ISO8601DateParser.parse(text) }
        return nil
    }

    private static func valid(_ point: NativeClaudeWebLogHistoryPoint) -> Bool {
        self.formatter(timeZone: TimeZone(secondsFromGMT: 0)!).date(from: point.localTimestamp) != nil
            && point.usedPercent.isFinite && point.usedPercent >= 0
            && ["five_hour", "seven_day", "seven_day_overage_included", "fable"].contains(point.windowKey)
            && UUID(uuidString: point.organizationUUID)?.uuidString.lowercased() == point.organizationUUID
            && (point.timestamp == nil || point.timestamp!.timeIntervalSince1970.isFinite)
            && (point.resetsAt == nil || point.resetsAt!.timeIntervalSince1970.isFinite)
            && [
                "windows.5h.utilization",
                "windows.7d.utilization",
                "windows.7d_oi.utilization",
                "resolved.limit.percent",
            ].contains(point.sourceField)
    }

    private static func precedes(_ lhs: NativeClaudeWebLogHistoryPoint, _ rhs: NativeClaudeWebLogHistoryPoint) -> Bool {
        if lhs.localTimestamp != rhs.localTimestamp { return lhs.localTimestamp < rhs.localTimestamp }
        if lhs.organizationUUID != rhs.organizationUUID { return lhs.organizationUUID < rhs.organizationUUID }
        if lhs.windowKey != rhs.windowKey { return lhs.windowKey < rhs.windowKey }
        if lhs.usedPercent != rhs.usedPercent { return lhs.usedPercent < rhs.usedPercent }
        if lhs.sourceField != rhs.sourceField { return lhs.sourceField < rhs.sourceField }
        if lhs.resetsAt != rhs.resetsAt {
            return (lhs.resetsAt ?? .distantPast) < (rhs.resetsAt ?? .distantPast)
        }
        return (lhs.timeZoneIdentifier ?? "") < (rhs.timeZoneIdentifier ?? "")
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
