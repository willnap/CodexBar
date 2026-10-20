import CoreFoundation
import Foundation

public struct NativeCodexQuotaSessionObservation: Equatable, Hashable, Sendable {
    /// Session quota events omit their authenticated account. The creator is never an event owner.
    public var workspaceAccountID: String? {
        nil
    }

    /// Used solely to undo the old importer’s creator-based attribution; never identifies a reading’s owner.
    public let legacyCreatorAccountID: String?
    public let snapshot: UsageSnapshot

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.legacyCreatorAccountID == rhs.legacyCreatorAccountID && lhs.snapshot.updatedAt == rhs.snapshot.updatedAt
            && lhs.snapshot.primary?.usedPercent == rhs.snapshot.primary?.usedPercent
            && lhs.snapshot.primary?.windowMinutes == rhs.snapshot.primary?.windowMinutes
            && lhs.snapshot.primary?.resetsAt == rhs.snapshot.primary?.resetsAt
            && lhs.snapshot.secondary?.usedPercent == rhs.snapshot.secondary?.usedPercent
            && lhs.snapshot.secondary?.windowMinutes == rhs.snapshot.secondary?.windowMinutes
            && lhs.snapshot.secondary?.resetsAt == rhs.snapshot.secondary?.resetsAt
            && lhs.snapshot.extraRateWindows == rhs.snapshot.extraRateWindows
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(self.legacyCreatorAccountID)
        hasher.combine(self.snapshot.updatedAt)
        for window in [self.snapshot.primary, self.snapshot.secondary] {
            hasher.combine(window?.usedPercent)
            hasher.combine(window?.windowMinutes)
            hasher.combine(window?.resetsAt)
        }
        for named in self.snapshot.extraRateWindows ?? [] {
            hasher.combine(named.id)
            hasher.combine(named.title)
            hasher.combine(named.usageKnown)
            hasher.combine(named.window.usedPercent)
            hasher.combine(named.window.windowMinutes)
            hasher.combine(named.window.resetsAt)
        }
    }
}

public enum NativeCodexQuotaSessionHistoryParser {
    public static func parse(_ data: Data, now: Date) -> [NativeCodexQuotaSessionObservation] {
        var state = State()
        for line in data.split(separator: 10) {
            state.ingest(Data(line), now: now)
        }
        return state.observations(now: now)
    }

    fileprivate struct State {
        var owners: Set<String> = []
        var invalidOwner = false
        var snapshots: [UsageSnapshot] = []

        mutating func ingest(_ line: Data, now: Date) {
            let metadata = line.range(of: Data("\"session_meta\"".utf8)) != nil
            guard metadata || line.range(of: Data("\"rate_limits\"".utf8)) != nil else { return }
            guard line.count <= 1024 * 1024,
                  let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let payload = object["payload"] as? [String: Any]
            else {
                if metadata { self.invalidOwner = true }
                return
            }
            if object["type"] as? String == "session_meta" {
                guard let raw = payload["creator_account_id"] as? String,
                      let owner = ManagedCodexAccount.normalizeWorkspaceAccountID(raw)
                else {
                    self.invalidOwner = true
                    return
                }
                self.owners.insert(owner)
                return
            }
            guard object["type"] as? String == "event_msg", payload["type"] as? String == "token_count",
                  let limits = payload["rate_limits"] as? [String: Any],
                  let timestamp = object["timestamp"] as? String,
                  let capturedAt = Self.date(timestamp), capturedAt <= now,
                  capturedAt >= now.addingTimeInterval(-32 * 86400)
            else { return }
            let windows = CodexRateWindowNormalizer.normalize(
                primary: Self.window(limits["primary"]), secondary: Self.window(limits["secondary"]))
            guard windows.primary != nil || windows.secondary != nil else { return }
            if limits["limit_id"] != nil, limits["limit_id"] as? String != "codex" {
                // The recorded model id and label prove Spark identity, never the authenticated account.
                guard limits["limit_id"] as? String == "codex_bengalfox",
                      let label = limits["limit_name"] as? String, label == "GPT-5.3-Codex-Spark"
                else { return }
                let extra = [
                    windows.primary.map {
                        NamedRateWindow(id: CodexAdditionalRateLimitMapper.sparkWindowID, title: label, window: $0)
                    },
                    windows.secondary.map {
                        NamedRateWindow(
                            id: CodexAdditionalRateLimitMapper.sparkWeeklyWindowID,
                            title: label,
                            window: $0)
                    },
                ].compactMap(\.self)
                self.snapshots.append(UsageSnapshot(
                    primary: nil, secondary: nil, extraRateWindows: extra, updatedAt: capturedAt))
                return
            }
            self.snapshots.append(UsageSnapshot(
                primary: windows.primary, secondary: windows.secondary, updatedAt: capturedAt))
        }

        func observations(now: Date) -> [NativeCodexQuotaSessionObservation] {
            let creator = !self.invalidOwner && self.owners.count == 1 ? self.owners.first : nil
            let cutoff = now.addingTimeInterval(-32 * 86400)
            return self.snapshots.filter { $0.updatedAt >= cutoff && $0.updatedAt <= now }.map {
                NativeCodexQuotaSessionObservation(legacyCreatorAccountID: creator, snapshot: $0)
            }
        }

        private static func window(_ raw: Any?) -> RateWindow? {
            guard let object = raw as? [String: Any],
                  let percent = number(object["used_percent"]), percent >= 0,
                  let minutes = number(object["window_minutes"]), minutes > 0, minutes <= 525_600,
                  minutes.rounded() == minutes,
                  let reset = number(object["resets_at"]), reset > 0
            else { return nil }
            return RateWindow(
                usedPercent: percent,
                windowMinutes: Int(minutes),
                resetsAt: Date(timeIntervalSince1970: reset),
                resetDescription: nil)
        }

        private static func number(_ raw: Any?) -> Double? {
            guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                  value.doubleValue.isFinite else { return nil }
            return value.doubleValue
        }

        private static func date(_ raw: String) -> Date? {
            (try? Date(raw, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
                ?? (try? Date(raw, strategy: .iso8601))
        }
    }
}

/// Keeps only quota observations, never messages or credential files. Each call has a bounded read budget;
/// callers can drain pending batches while yielding between them. Unchanged session files are not reparsed.
public actor NativeCodexQuotaSessionHistoryScanner {
    private struct FileState {
        let inode: UInt64
        var size: Int
        var modified: Date
        var offset: UInt64 = 0
        var pending = Data()
        var discardingLine = false
        var discardedTail = Data()
        var parser = NativeCodexQuotaSessionHistoryParser.State()
        var failedAt: Date?
    }

    private var files: [URL: FileState] = [:]
    public private(set) var hasPendingWork = false

    public init() {}

    public func scan(
        homeRoots: [URL], now: Date, byteBudget: Int = 64 * 1024 * 1024) -> [NativeCodexQuotaSessionObservation]
    {
        self.hasPendingWork = false
        var remaining = max(0, byteBudget)
        let candidates = Self.candidates(homeRoots: homeRoots, now: now)
        self.files = self.files.filter { candidates.contains($0.key) }
        for url in candidates.sorted(by: { $0.path < $1.path }) {
            guard !Task.isCancelled, CodexCredentialFileAccess.permits(url),
                  let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = (attributes[.size] as? NSNumber)?.intValue,
                  let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
                  let modified = attributes[.modificationDate] as? Date
            else { continue }
            var state = self.files[url] ?? FileState(inode: inode, size: size, modified: modified)
            if state.inode != inode || state.offset > size || (state.size == size && state.modified != modified) {
                state = FileState(inode: inode, size: size, modified: modified)
            }
            state.size = size
            state.modified = modified
            let cutoff = now.addingTimeInterval(-32 * 86400)
            if state.parser.snapshots.contains(where: { $0.updatedAt < cutoff }) {
                state.parser.snapshots.removeAll { $0.updatedAt < cutoff }
            }
            // A corrupt or inaccessible file never keeps a drain loop alive. Retry it on a later refresh.
            if state.failedAt == now { continue }
            state.failedAt = nil
            guard size <= 512 * 1024 * 1024 else {
                state.failedAt = now
                self.files[url] = state
                continue
            }
            if state.offset < size, remaining > 0 {
                do {
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    try handle.seek(toOffset: state.offset)
                    while state.offset < size, remaining > 0, !Task.isCancelled {
                        let count = min(256 * 1024, remaining, size - Int(state.offset))
                        guard let data = try handle.read(upToCount: count), !data.isEmpty else { break }
                        state.offset += UInt64(data.count)
                        remaining -= data.count
                        Self.ingest(data, state: &state, now: now)
                    }
                    if state.offset < size, remaining > 0, !Task.isCancelled { state.failedAt = now }
                } catch {
                    state.failedAt = now
                }
            }
            self.files[url] = state
            if state.offset < size, state.failedAt == nil { self.hasPendingWork = true }
        }
        return self.observations(now: now)
    }

    private static func candidates(homeRoots: [URL], now: Date) -> Set<URL> {
        var result = Set<URL>()
        let cutoff = now.addingTimeInterval(-32 * 86400)
        for home in Set(homeRoots.map(\.standardizedFileURL)) {
            for name in ["sessions", "archived_sessions"] {
                let root = home.appendingPathComponent(name, isDirectory: true)
                guard CodexCredentialFileAccess.permits(root),
                      let attributes = try? FileManager.default.attributesOfItem(atPath: root.path),
                      attributes[.type] as? FileAttributeType == .typeDirectory,
                      let enumerator = FileManager.default.enumerator(
                          at: root,
                          includingPropertiesForKeys: [.isSymbolicLinkKey, .contentModificationDateKey],
                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
                var visited = 0
                for case let url as URL in enumerator {
                    visited += 1
                    guard visited <= 20000, !Task.isCancelled else { break }
                    guard CodexCredentialFileAccess.permits(url),
                          let values = try? url.resourceValues(forKeys: [
                              .isSymbolicLinkKey,
                              .contentModificationDateKey,
                          ]),
                          values.isSymbolicLink != true
                    else {
                        enumerator.skipDescendants()
                        continue
                    }
                    guard url.pathExtension == "jsonl", values.contentModificationDate.map({ $0 >= cutoff }) == true
                    else { continue }
                    result.insert(url.standardizedFileURL)
                }
            }
        }
        return result
    }

    private static func ingest(_ data: Data, state: inout FileState, now: Date) {
        var start = data.startIndex
        let newline = Data([10])
        while let range = data.range(of: newline, in: start..<data.endIndex) {
            let index = range.lowerBound
            if state.discardingLine {
                Self.inspectDiscardedMetadata(Data(data[start..<index]), state: &state)
            } else {
                state.pending.append(data[start..<index])
                state.parser.ingest(state.pending, now: now)
            }
            state.pending.removeAll(keepingCapacity: true)
            state.discardingLine = false
            state.discardedTail.removeAll(keepingCapacity: true)
            start = range.upperBound
        }
        if state.discardingLine {
            Self.inspectDiscardedMetadata(Data(data[start...]), state: &state)
            return
        }
        state.pending.append(data[start...])
        if state.pending.count > 1024 * 1024 {
            // Oversized metadata invalidates only the legacy repair hint; valid quota events stay anonymous.
            Self.inspectDiscardedMetadata(state.pending, state: &state)
            state.pending.removeAll(keepingCapacity: false)
            state.discardingLine = true
        }
    }

    private static func inspectDiscardedMetadata(_ data: Data, state: inout FileState) {
        let marker = Data("\"session_meta\"".utf8)
        var searchable = state.discardedTail
        searchable.append(data)
        if searchable.range(of: marker) != nil { state.parser.invalidOwner = true }
        // Retain only enough bytes to detect metadata spanning two read chunks.
        state.discardedTail = Data(searchable.suffix(marker.count - 1))
    }

    /// How far each contributing file had been read when observations were last collected.
    private struct ReadState: Equatable {
        let inode: UInt64
        let offset: UInt64
    }

    /// The last collection, sorted. Rehashing and sorting every reading of the month cost seconds per refresh, while a
    /// refresh usually reads nothing new; readings only enter while a file is read, and never from later than then.
    private var collected: (states: [URL: ReadState], observations: [NativeCodexQuotaSessionObservation])?

    private func observations(now: Date) -> [NativeCodexQuotaSessionObservation] {
        var states: [URL: ReadState] = [:]
        var endsMidLine = false
        for (url, state) in self.files {
            guard CodexCredentialFileAccess.permits(url), state.failedAt == nil, state.offset == state.size,
                  !state.discardingLine else { continue }
            states[url] = ReadState(inode: state.inode, offset: state.offset)
            if !state.pending.isEmpty { endsMidLine = true }
        }
        let sorted: [NativeCodexQuotaSessionObservation]
        if !endsMidLine, let collected = self.collected, collected.states == states {
            sorted = collected.observations
        } else {
            var observations = Set<NativeCodexQuotaSessionObservation>()
            for url in states.keys {
                guard let state = self.files[url] else { continue }
                var parser = state.parser
                // A line still being written is read as it stands now, so it is never kept for later.
                if !state.pending.isEmpty { parser.ingest(state.pending, now: now) }
                observations.formUnion(parser.observations(now: now))
            }
            sorted = observations.sorted {
                if $0.snapshot.updatedAt != $1.snapshot.updatedAt {
                    return $0.snapshot.updatedAt < $1.snapshot.updatedAt
                }
                return ($0.legacyCreatorAccountID ?? "") < ($1.legacyCreatorAccountID ?? "")
            }
            self.collected = endsMidLine ? nil : (states, sorted)
        }
        let cutoff = now.addingTimeInterval(-32 * 86400)
        let lower = sorted.partitioningIndex { $0.snapshot.updatedAt >= cutoff }
        let upper = sorted.partitioningIndex { $0.snapshot.updatedAt > now }
        return lower < upper ? Array(sorted[lower..<upper]) : []
    }
}

extension RandomAccessCollection {
    /// The first index whose element satisfies `predicate`, which must be false then true along the collection.
    fileprivate func partitioningIndex(where predicate: (Element) -> Bool) -> Index {
        var lower = self.startIndex
        var count = self.count
        while count > 0 {
            let half = count / 2
            let middle = self.index(lower, offsetBy: half)
            if predicate(self[middle]) {
                count = half
            } else {
                lower = self.index(after: middle)
                count -= half + 1
            }
        }
        return lower
    }
}
