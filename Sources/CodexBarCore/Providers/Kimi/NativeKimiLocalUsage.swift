import Crypto
import Foundation

public enum NativeKimiLocalUsageParser {
    public static func snapshot(
        data: Data,
        now: Date,
        bucketTimeZoneIdentifier: String) -> CostUsageTokenSnapshot
    {
        self.snapshot(data: data, now: now, bucketTimeZoneIdentifier: bucketTimeZoneIdentifier, pricingCatalog: nil)
    }

    static func snapshot(
        data: Data,
        now: Date,
        bucketTimeZoneIdentifier: String,
        pricingCatalog: ModelsDevCatalog?) -> CostUsageTokenSnapshot
    {
        var records = Records()
        for line in data.split(separator: 10) {
            records.ingest(Data(line))
        }
        // A standalone document cannot prove that it is every wire file on this machine.
        return self.snapshot(
            records: records,
            now: now,
            bucketTimeZoneIdentifier: bucketTimeZoneIdentifier,
            coverageIsEstablished: false,
            pricingCatalog: pricingCatalog)
    }

    fileprivate struct Event: Codable, Equatable, Sendable {
        let fingerprint: String
        let timestamp: Date
        let input: Int
        let output: Int
        let cacheRead: Int
        let cacheCreation: Int
        /// Route model of the turn. Version 2 archives omit it until the source line is read again.
        var model: String?

        var tokens: Int? {
            NativeKimiLocalUsageParser.sum([
                self.input,
                self.output,
                self.cacheRead,
                self.cacheCreation,
            ])
        }
    }

    private struct WireEvent: Decodable {
        struct Usage: Decodable {
            let inputOther: Int
            let output: Int
            let inputCacheRead: Int
            let inputCacheCreation: Int
        }

        let type: String
        let time: Double
        let usageScope: String
        let usage: Usage
    }

    fileprivate struct Records: Sendable {
        var events: [String: Event] = [:]
        var isPartial = false
        var sourceIdentity = "standalone"

        mutating func ingest(_ line: Data) {
            // Ignore token_counting/session aggregates,
            // messages and tool output. Only a turn record
            // is additive.
            guard line.range(of: Data("\"usage.record\"".utf8)) != nil else { return }
            guard line.count <= 1024 * 1024,
                  let object = (try? JSONSerialization.jsonObject(
                      with: line)) as? [String: Any]
            else { self.isPartial = true; return }
            guard object["type"] as? String == "usage.record",
                  object["usageScope"] as? String == "turn"
            else {
                return
            }
            guard let wire = try? JSONDecoder().decode(
                WireEvent.self,
                from: line),
                wire.time.isFinite, wire.time > 0,
                wire.usage.inputOther >= 0,
                wire.usage.output >= 0,
                wire.usage.inputCacheRead >= 0,
                wire.usage.inputCacheCreation >= 0,
                let canonical = try? JSONSerialization.data(
                    withJSONObject: object,
                    options: [.sortedKeys])
            else { self.isPartial = true; return }
            // Keep all record fields in the identity. Equal
            // time/counters from different agents remain
            // separate;
            // byte-order/whitespace variants of the same
            // complete source record are deduplicated
            // across copies.
            let material = Data((self.sourceIdentity + "\u{0}").utf8) + canonical
            let fingerprint = SHA256.hash(data: material).map { String(
                format: "%02x",
                $0) }.joined()
            let event = Event(
                fingerprint: fingerprint,
                timestamp: Date(timeIntervalSince1970: wire.time / 1000),
                input: wire.usage.inputOther,
                output: wire.usage.output,
                cacheRead: wire.usage.inputCacheRead,
                cacheCreation: wire.usage.inputCacheCreation,
                model: NativeKimiLocalUsageParser.model(object["model"]))
            guard event.tokens != nil
            else { self.isPartial = true; return }
            if self.events.count >= 250_000,
               self.events[fingerprint] == nil
            {
                self.isPartial = true
                return
            }
            self.events[fingerprint] = event
        }
    }

    fileprivate static func model(_ value: Any?) -> String? {
        guard let raw = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty, raw.utf8.count <= 128 else { return nil }
        return raw
    }

    fileprivate static func snapshot(
        records: Records,
        now: Date,
        bucketTimeZoneIdentifier: String,
        coverageIsEstablished: Bool,
        pricingCatalog: ModelsDevCatalog?) -> CostUsageTokenSnapshot
    {
        let calendar = CostUsageBucketTimeZone.calendar(identifier: bucketTimeZoneIdentifier)
        let bounds = CostReportingPeriod.rolling(days: 30).bounds(
            now: now,
            calendar: calendar)
        let events = records.events.values.filter {
            $0.timestamp >= bounds.lowerBound && $0.timestamp <= now
        }.sorted {
            $0.timestamp == $1.timestamp ? $0.fingerprint < $1.fingerprint : $0.timestamp < $1.timestamp
        }
        let pricing = NativeKimiListPricing(catalog: pricingCatalog, models: Set(events.compactMap(\.model)))
        let priced = events.map { event in
            (event: event, cost: pricing.costUSD(
                model: event.model,
                input: event.input,
                output: event.output,
                cacheRead: event.cacheRead,
                cacheCreation: event.cacheCreation))
        }
        let byDay = Dictionary(grouping: priced) {
            CostUsageLocalDay.key(
                from: $0.event.timestamp,
                calendar: calendar)
        }
        let daily = byDay.keys.sorted().map { day -> CostUsageDailyReport.Entry in
            let items = byDay[day] ?? []
            let costs = items.compactMap(\.cost)
            let models = Set(items.compactMap(\.event.model)).sorted()
            return .init(
                date: day,
                inputTokens: self.sum(items.map(\.event.input)),
                outputTokens: self.sum(items.map(\.event.output)),
                cacheReadTokens: self.sum(items.map(\.event.cacheRead)),
                cacheCreationTokens: self.sum(items.map(\.event.cacheCreation)),
                totalTokens: self.sum(items.compactMap(\.event.tokens)),
                requestCount: items.count,
                costUSD: costs.isEmpty ? nil : costs.reduce(0, +),
                modelsUsed: models.isEmpty ? nil : models,
                modelBreakdowns: nil,
                unpricedRequestCount: items.count - costs.count,
                pricedRequestCount: costs.isEmpty ? nil : costs.count,
                costIsPartial: costs.isEmpty ? nil : costs.count != items.count)
        }
        let total = events.isEmpty ? nil : self.sum(events.compactMap(\.tokens))
        let costs = priced.compactMap(\.cost)
        return CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: total,
            last30DaysCostUSD: costs.isEmpty ? nil : costs.reduce(0, +),
            last30DaysRequests: events.isEmpty ? nil : events.count,
            historyDays: 30,
            // A complete scan of every retained wire file (plus the durable archive of deleted ones) covers
            // this Mac's Kimi Code activity; the scope label states that boundary.
            historyCoverageIsEstablished: coverageIsEstablished,
            historyScanIsPartial: records.isPartial || (!events.isEmpty && total == nil),
            historyLabel: "Kimi Code local wire records",
            costProvenance: costs.isEmpty ? .unknown : .listPriceEstimate,
            daily: daily,
            quotaSlices: priced.map { .init(
                timestamp: $0.event.timestamp,
                totalTokens: $0.event.tokens,
                costUSD: $0.cost) },
            updatedAt: now)
    }

    private static func sum(_ values: [Int]) -> Int? {
        var total = 0
        for value in values {
            let sum = total.addingReportingOverflow(value)
            guard !sum.overflow else { return nil }
            total = sum.partialValue
        }
        return total
    }
}

public actor NativeKimiLocalUsageScanner {
    /// Events older than this are dropped from the durable archive.
    static let retention: TimeInterval = 32 * 86400
    /// A wire file last written before the retention window (less a day for clock adjustments) cannot contain a
    /// retained event: Kimi Code appends each record no earlier than the time it reports.
    static let staleFileMargin: TimeInterval = 86400
    static let readSlice = 4 * 1024 * 1024
    private static let recordMarker = Array("\"usage.record\"".utf8)
    /// Kimi passes are bounded and read only Kimi's own corpus, so they do not queue behind long Codex/Claude
    /// corpus scans. Passes stay serialized here and each continues from the last committed state.
    private static let queue = DispatchQueue(label: "com.steipete.codexbar.kimi-local-usage-scan", qos: .utility)

    private struct FileCache: Sendable {
        var size: UInt64 = 0
        var modified: Date = .distantPast
        var fileNumber: UInt64 = 0
        var offset: UInt64 = 0
        /// File offset just past the last complete line. Only this boundary is persisted, never partial lines.
        var lineStart: UInt64 = 0
        var cursorKey = ""
        var pending = Data()
        var discardingLongLine = false
        var records = NativeKimiLocalUsageParser.Records()

        var cursor: Cursor {
            Cursor(
                fileNumber: self.fileNumber,
                size: self.size,
                modifiedReferenceTime: self.modified.timeIntervalSinceReferenceDate,
                offset: min(self.lineStart, self.size))
        }
    }

    fileprivate struct Cursor: Codable, Equatable, Sendable {
        let fileNumber: UInt64
        let size: UInt64
        let modifiedReferenceTime: Double
        let offset: UInt64
    }

    private struct WireFile {
        let url: URL
        let key: String
        let size: UInt64
        let modified: Date
        let fileNumber: UInt64
    }

    private struct State: Sendable {
        var root: String?
        var files: [String: FileCache] = [:]
        /// Cursors from the archive, keyed by the digest of the root-relative path. They seed `files` once.
        var restoredCursors: [String: Cursor] = [:]
        var savedCursors: [String: Cursor] = [:]
        var hasPendingWork = false
        var archived = NativeKimiLocalUsageParser.Records()
        var archiveLoaded = false
        var archiveWritable = true
        var archiveDirty = false
        /// Directory listings from earlier passes, kept while each directory's modification time is unchanged.
        var listings: [String: DirectoryListing] = [:]
    }

    /// One directory's entries. Adding, removing or renaming an entry changes the directory's modification time;
    /// appending to a file does not, and the inventory stats every file itself.
    private struct DirectoryListing: Sendable {
        struct Entry: Sendable {
            let url: URL
            let isDirectory: Bool
            let isRegularFile: Bool
            let isSymbolicLink: Bool
        }

        let modified: Date
        let entries: [Entry]
    }

    private struct PassProgress {
        var partial: Bool
        var unreadable = false
        var eventsChanged = false
    }

    private struct Archive: Codable {
        let version: Int
        let sourceRootFingerprint: String
        let events: [NativeKimiLocalUsageParser.Event]
        let isPartial: Bool
        let files: [String: Cursor]?
    }

    private struct Options: Sendable {
        let byteBudget: Int
        let archiveURL: URL?
        let archiveDirectory: URL?
        let pricingCatalog: (@Sendable () -> ModelsDevCatalog?)?
    }

    private enum ArchiveError: Error { case invalid }

    private let options: Options
    private let store = CostUsageScanExecutor.LockedState(State())

    public init(byteBudget: Int = 64 * 1024 * 1024, archiveURL: URL? = nil) {
        // Pricing reads only the cached models.dev catalog, never the network. Tests inject their own catalog.
        let catalog: (@Sendable () -> ModelsDevCatalog?)? = if TestProcessSafety.isRunning {
            nil
        } else {
            Self.cachedPricingCatalog
        }
        self.init(byteBudget: byteBudget, archiveURL: archiveURL, pricingCatalog: catalog)
    }

    @Sendable private static func cachedPricingCatalog() -> ModelsDevCatalog? {
        CostUsagePricing.modelsDevCatalog()
    }

    init(byteBudget: Int, archiveURL: URL?, pricingCatalog: (@Sendable () -> ModelsDevCatalog?)?) {
        let archiveDirectory: URL? = if TestProcessSafety.isRunning || archiveURL != nil {
            nil
        } else {
            (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support"))
                .appendingPathComponent("CodexBar/KimiTokenHistory", isDirectory: true)
        }
        self.options = Options(
            byteBudget: max(1, byteBudget),
            archiveURL: archiveURL,
            archiveDirectory: archiveDirectory,
            pricingCatalog: pricingCatalog)
    }

    public var hasPendingWork: Bool {
        self.store.withLock { $0.hasPendingWork }
    }

    public func scan(
        sessionsRoot: URL,
        now: Date,
        bucketTimeZoneIdentifier: String) async -> CostUsageTokenSnapshot?
    {
        let store = self.store
        let options = self.options
        do {
            let snapshot = try await CostUsageScanExecutor.run(on: Self.queue) { checkCancellation in
                // Commit progress even when a superseding refresh cancels this pass, so completed reads are
                // never repeated. Every cancellation point leaves the state consistent at file granularity.
                var state = store.withLock { $0 }
                defer { store.withLock { $0 = state } }
                return try Self.scanBatch(
                    root: sessionsRoot,
                    state: &state,
                    options: options,
                    reportContext: (now, bucketTimeZoneIdentifier),
                    checkCancellation: checkCancellation)
            }
            guard !Task.isCancelled else { return nil }
            return snapshot
        } catch { return nil }
    }

    private static func scanBatch(
        root: URL,
        state: inout State,
        options: Options,
        reportContext: (date: Date, zone: String),
        checkCancellation: @Sendable () throws -> Void) throws -> CostUsageTokenSnapshot
    {
        let now = reportContext.date
        // Root resolution runs on the scan executor. Aliases of one corpus share ownership;
        // a different corpus cannot import another root's durable counters.
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        let rootFingerprint = self.digest(root.path)
        let archiveURL = options.archiveURL ?? options.archiveDirectory?
            .appendingPathComponent(rootFingerprint + ".json")
        if state.root != root.path {
            state = State()
            state.root = root.path
        }
        // Until this pass completes, more work is assumed to remain.
        state.hasPendingWork = true
        self.loadArchive(into: &state, url: archiveURL, owner: rootFingerprint)
        let discovery = try self.discoveredWireFiles(
            root: root, listings: &state.listings, checkCancellation: checkCancellation)
        var progress = PassProgress(partial: discovery.1 || !state.archiveWritable)
        let files = try self.inventory(discovery.0, progress: &progress, checkCancellation: checkCancellation)
        // An incomplete inventory proves no deletion. Retain unreadable/undiscovered file cursors.
        if !discovery.1 {
            let retained = Set(files.map(\.key))
            state.files = state.files.filter { retained.contains($0.key) }
        }
        let cutoff = now.addingTimeInterval(-self.retention)
        var remaining = options.byteBudget
        var pending = false
        for file in files {
            try checkCancellation()
            var cache = self.cache(for: file, state: state)
            let readFailed = self.advance(&cache, file: file, cutoff: cutoff, budget: &remaining)
            if readFailed { progress.partial = true; progress.unreadable = true }
            if cache.offset < file.size, !readFailed { pending = true }
            if cache.offset == file.size, !cache.pending.isEmpty {
                // A final line without its newline is complete only when it is a whole JSON document.
                if (try? JSONSerialization.jsonObject(with: cache.pending)) != nil {
                    cache.records.ingest(cache.pending)
                    cache.pending = Data()
                    cache.lineStart = file.size
                } else { progress.partial = true }
            }
            if self.merge(cache.records, into: &state.archived, cutoff: cutoff) { progress.eventsChanged = true }
            // Store events exactly once in a bounded archive, not in every duplicate file cache.
            cache.records.events = [:]
            state.files[file.key] = cache
            progress.partial = progress.partial || cache.records.isPartial || cache.discardingLongLine
        }
        state.hasPendingWork = pending
        // Expire retained events once per pass, never once per file.
        if state.archived.events.values.contains(where: { $0.timestamp < cutoff }) {
            state.archived.events = state.archived.events.filter { $0.value.timestamp >= cutoff }
            progress.eventsChanged = true
        }
        self.saveIfNeeded(
            &state,
            inventoryComplete: !discovery.1,
            progress: &progress,
            url: archiveURL,
            owner: rootFingerprint)
        var report = state.archived
        report.isPartial = report.isPartial || progress.partial || state.hasPendingWork
        return NativeKimiLocalUsageParser.snapshot(
            records: report,
            now: now,
            bucketTimeZoneIdentifier: reportContext.zone,
            // Coverage: a complete inventory, every file read to its end, and a durable archive of deleted files.
            coverageIsEstablished: !discovery.1 && !progress.unreadable && !state.hasPendingWork
                && state.archiveWritable,
            pricingCatalog: options.pricingCatalog?())
    }

    /// Stats every discovered file and orders them newest first, so the most recent activity is read first.
    private static func inventory(
        _ urls: [URL],
        progress: inout PassProgress,
        checkCancellation: @Sendable () throws -> Void) throws -> [WireFile]
    {
        var files: [WireFile] = []
        files.reserveCapacity(urls.count)
        for url in urls {
            try checkCancellation()
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = (attrs[.size] as? NSNumber)?.uint64Value,
                  let modified = attrs[.modificationDate] as? Date,
                  let fileNumber = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value
            else {
                progress.partial = true
                progress.unreadable = true
                continue
            }
            files.append(WireFile(
                url: url,
                key: url.pathComponents.suffix(5).joined(separator: "/"),
                size: size,
                modified: modified,
                fileNumber: fileNumber))
        }
        return files.sorted { $0.modified == $1.modified ? $0.key < $1.key : $0.modified > $1.modified }
    }

    private static func cache(for file: WireFile, state: State) -> FileCache {
        var cache: FileCache
        if let existing = state.files[file.key] {
            cache = existing
        } else {
            cache = FileCache()
            cache.cursorKey = self.digest(file.key)
            if let cursor = state.restoredCursors[cache.cursorKey], cursor.offset <= cursor.size {
                cache.size = cursor.size
                cache.modified = Date(timeIntervalSinceReferenceDate: cursor.modifiedReferenceTime)
                cache.fileNumber = cursor.fileNumber
                cache.offset = cursor.offset
                cache.lineStart = cursor.offset
            }
        }
        // A replaced, truncated or rewritten file restarts from its beginning; dedup keeps archived events exact.
        if cache.fileNumber != file.fileNumber || file.size < cache.size
            || (file.size == cache.size && file.modified != cache.modified)
        {
            let key = cache.cursorKey
            cache = FileCache()
            cache.cursorKey = key
        }
        if cache.cursorKey.isEmpty { cache.cursorKey = self.digest(file.key) }
        // Session IDs survive project-directory copies; each agent remains an independent request source.
        let parts = Array(file.url.pathComponents.suffix(5))
        cache.records.sourceIdentity = parts[1] + "\u{0}" + parts[3]
        cache.size = file.size
        cache.modified = file.modified
        cache.fileNumber = file.fileNumber
        return cache
    }

    /// Reads whole files within the pass budget. Returns true when the file could not be read.
    private static func advance(
        _ cache: inout FileCache,
        file: WireFile,
        cutoff: Date,
        budget: inout Int) -> Bool
    {
        guard cache.offset < file.size else { return false }
        if file.modified < cutoff.addingTimeInterval(-self.staleFileMargin) {
            // Every record in this file predates the retained window; consume it without reading.
            cache.offset = file.size
            cache.lineStart = file.size
            cache.pending = Data()
            cache.discardingLongLine = false
            return false
        }
        guard budget > 0 else { return false }
        do {
            let handle = try FileHandle(forReadingFrom: file.url)
            defer { try? handle.close() }
            try handle.seek(toOffset: cache.offset)
            while cache.offset < file.size, budget > 0 {
                let count = min(budget, self.readSlice, Int(min(file.size - cache.offset, UInt64(Int.max))))
                let data = try handle.read(upToCount: count) ?? Data()
                if data.isEmpty { return true }
                let start = cache.offset
                cache.offset += UInt64(data.count)
                budget -= data.count
                self.ingest(data, readStart: start, into: &cache)
            }
            return false
        } catch { return true }
    }

    private static func merge(
        _ records: NativeKimiLocalUsageParser.Records,
        into retained: inout NativeKimiLocalUsageParser.Records,
        cutoff: Date) -> Bool
    {
        var changed = false
        if records.isPartial, !retained.isPartial {
            retained.isPartial = true
            changed = true
        }
        for (key, event) in records.events where event.timestamp >= cutoff {
            if let existing = retained.events[key] {
                // A re-read source line can add a field that an older archive lacked (its route model).
                if existing != event {
                    retained.events[key] = event
                    changed = true
                }
                continue
            }
            if retained.events.count >= 250_000 {
                if !retained.isPartial { retained.isPartial = true; changed = true }
                continue
            }
            retained.events[key] = event
            changed = true
        }
        return changed
    }

    private static func saveIfNeeded(
        _ state: inout State,
        inventoryComplete: Bool,
        progress: inout PassProgress,
        url: URL?,
        owner: String)
    {
        var cursors = inventoryComplete ? [:] : state.restoredCursors
        for cache in state.files.values where !cache.cursorKey.isEmpty {
            cursors[cache.cursorKey] = cache.cursor
        }
        // Dropping cursors of deleted files alone is not worth a rewrite; they are pruned with the next save.
        let cursorsChanged = cursors.contains { state.savedCursors[$0.key] != $0.value }
        guard state.archiveWritable, state.archiveDirty || progress.eventsChanged || cursorsChanged else { return }
        let saved = self.saveArchive(state.archived, cursors: cursors, url: url, owner: owner)
        state.archiveDirty = !saved
        if saved { state.savedCursors = cursors } else { progress.partial = true }
    }

    private static func loadArchive(into state: inout State, url: URL?, owner: String) {
        guard !state.archiveLoaded else { return }
        state.archiveLoaded = true
        guard let url else { return }
        // Missing files are new archives. Unknown/foreign ownership, unreadable, malformed,
        // symlinked and newer documents stay untouched and cannot contribute events.
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size <= 64 * 1024 * 1024 else { throw ArchiveError.invalid }
            let archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: url))
            // Version 2 stored events only; its events migrate and every file is read once more for cursors.
            guard archive.version == 2 || archive.version == 3,
                  archive.sourceRootFingerprint == owner, archive.events.count <= 250_000,
                  archive.events.allSatisfy({ event in
                      event.fingerprint.count == 64 && event.fingerprint.allSatisfy(\.isHexDigit)
                          && event.timestamp.timeIntervalSince1970.isFinite && event.timestamp.timeIntervalSince1970 > 0
                          && event.input >= 0 && event.output >= 0 && event.cacheRead >= 0 && event.cacheCreation >= 0
                          && event.tokens != nil && (event.model.map { $0.utf8.count <= 128 } ?? true)
                  }) else { throw ArchiveError.invalid }
            var records = NativeKimiLocalUsageParser.Records()
            records.isPartial = archive.isPartial
            for event in archive.events {
                records.events[event.fingerprint] = event
            }
            state.archived = records
            let cursors = archive.version == 3 ? archive.files ?? [:] : [:]
            if cursors.allSatisfy({ key, cursor in
                key.count == 64 && key.allSatisfy(\.isHexDigit) && cursor.offset <= cursor.size
                    && cursor.modifiedReferenceTime.isFinite
            }) {
                state.restoredCursors = cursors
                state.savedCursors = cursors
            }
            state.archiveDirty = archive.version != 3
        } catch {
            state.archiveWritable = false
        }
    }

    private static func saveArchive(
        _ records: NativeKimiLocalUsageParser.Records,
        cursors: [String: Cursor],
        url: URL?,
        owner: String) -> Bool
    {
        guard let url else { return true }
        do {
            let events = records.events.values.sorted { $0.fingerprint < $1.fingerprint }
            let data = try JSONEncoder().encode(Archive(
                version: 3,
                sourceRootFingerprint: owner,
                events: events,
                isPartial: records.isPartial,
                files: cursors))
            guard data.count <= 64 * 1024 * 1024 else { return false }
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch { return false }
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func discoveredWireFiles(
        root: URL,
        listings: inout [String: DirectoryListing],
        checkCancellation: @Sendable () throws -> Void) throws -> ([URL], Bool)
    {
        var urls: [URL] = []
        var partial = false
        guard FileManager.default.fileExists(atPath: root.path) else { return (urls, partial) }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        var visited = 0
        var listed: Set<String> = []
        /// A pass relists only the directories that changed since the last one; the walk is otherwise the same.
        func entries(of directory: URL) -> [DirectoryListing.Entry]? {
            listed.insert(directory.path)
            // Read uncached: a URL from an earlier listing keeps the resource values it was first asked for.
            guard let modified = (try? FileManager.default.attributesOfItem(atPath: directory.path))?[.modificationDate]
                as? Date
            else { partial = true; return nil }
            if let listing = listings[directory.path], listing.modified == modified { return listing.entries }
            guard let children = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles])
            else { partial = true; return nil }
            let entries = children.compactMap { child -> DirectoryListing.Entry? in
                guard let values = try? child.resourceValues(forKeys: keys) else { partial = true; return nil }
                return .init(
                    url: child.standardizedFileURL,
                    isDirectory: values.isDirectory == true,
                    isRegularFile: values.isRegularFile == true,
                    isSymbolicLink: values.isSymbolicLink == true)
            }
            listings[directory.path] = .init(modified: modified, entries: entries)
            return entries
        }
        /// Prune tool artifacts; include sessions/<project>/<session>/agents/<agent>/wire.jsonl for every agent.
        func walk(_ directory: URL, depth: Int) throws -> Bool {
            for entry in entries(of: directory) ?? [] {
                try checkCancellation()
                visited += 1
                if visited > 20000 || urls.count >= 4096 { partial = true; return false }
                if entry.isSymbolicLink { partial = true; continue }
                if entry.isDirectory {
                    let descends = depth + 1 <= 4 && (depth + 1 != 3 || entry.url.lastPathComponent == "agents")
                    if descends, try !walk(entry.url, depth: depth + 1) { return false }
                } else if entry.isRegularFile, depth + 1 == 5, entry.url.lastPathComponent == "wire.jsonl" {
                    urls.append(entry.url)
                }
            }
            return true
        }
        _ = try walk(root, depth: 0)
        listings = listings.filter { listed.contains($0.key) }
        return (urls, partial)
    }

    /// Splits complete lines with memchr and parses only lines carrying a usage record.
    private static func ingest(
        _ data: Data,
        readStart: UInt64,
        into cache: inout FileCache)
    {
        let buffer: Data
        let bufferStart: UInt64
        if cache.pending.isEmpty {
            buffer = data
            bufferStart = readStart
        } else {
            var joined = cache.pending
            joined.append(data)
            buffer = joined
            bufferStart = readStart - UInt64(cache.pending.count)
        }
        cache.pending = Data()
        var discarding = cache.discardingLongLine
        var lineStart = cache.lineStart
        var records = cache.records
        let consumed = buffer.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return 0 }
            let count = raw.count
            var start = 0
            while start < count, let found = memchr(base + start, 10, count - start) {
                let end = base.distance(to: UnsafeRawPointer(found))
                if !discarding, end > start, self.recordMarker.withUnsafeBytes({ marker in
                    memmem(base + start, end - start, marker.baseAddress, marker.count) != nil
                }) {
                    records.ingest(Data(bytes: base + start, count: end - start))
                }
                discarding = false
                start = end + 1
                lineStart = bufferStart + UInt64(start)
            }
            return start
        }
        let remainder = buffer.count - consumed
        if remainder > 1024 * 1024 {
            records.isPartial = true
            discarding = true
        } else if !discarding, remainder > 0 {
            cache.pending = buffer.subdata(in: (buffer.startIndex + consumed)..<buffer.endIndex)
        }
        cache.discardingLongLine = discarding
        cache.lineStart = lineStart
        cache.records = records
    }
}
