import Foundation

extension CostUsageScanner {
    /// One Claude report kept between scans of its transcript cache: the whole machine's, or one organization's rows.
    ///
    /// A scan usually appends to a few transcripts, yet a full rebuild reconciles, sorts and reprices every row of
    /// every transcript (hundreds of thousands) and sums them all again. The engine keeps each transcript's rows,
    /// sharing their storage with the cache so an unchanged transcript is recognised by identity, every request's
    /// winning row, and the day/model and time-bucket totals. A scan replays only the transcripts whose rows changed
    /// and re-sums only the buckets their rows fall in, each in the order a full rebuild sums it, so the report is the
    /// same one.
    final class ClaudeReportEngine: @unchecked Sendable {
        /// Engines by cache file and report, for the process.
        final class Registry: @unchecked Sendable {
            #if DEBUG
            @TaskLocal static var shared = Registry()
            #else
            static let shared = Registry()
            #endif
            private let lock = NSLock()
            private var engines: [String: ClaudeReportEngine] = [:]

            /// Forgets every engine. Each holds its transcripts' rows and the indexes over them, hundreds of
            /// megabytes for a heavy history; the next scan builds what it needs again from the cache on disk.
            func removeAll() -> Int {
                self.lock.withLock {
                    let count = self.engines.count
                    self.engines.removeAll()
                    return count
                }
            }

            func engine(cachePath: String, organizationID: String?) -> ClaudeReportEngine {
                let key = cachePath + "\u{0}" + (organizationID ?? "")
                return self.lock.withLock {
                    if let engine = self.engines[key] { return engine }
                    let engine = ClaudeReportEngine(organizationID: organizationID)
                    self.engines[key] = engine
                    return engine
                }
            }
        }

        /// The range and zone every total is bucketed in; a change rebuilds them all, as a new catalogue does.
        private struct Configuration: Equatable {
            let sinceKey: String
            let untilKey: String
            let timeZoneIdentifier: String
        }

        /// A row's place: its transcript, by number in `paths`, and its position there. Eight bytes instead of a
        /// path string and an integer, for an index that holds one of these for every request ever scanned.
        private struct RowRef: Hashable {
            let file: UInt32
            let index: UInt32
        }

        /// A request's identity in the index: 128 bits drawn from its canonical key. The key itself is two
        /// strings; with a reference beside it the index cost 80 bytes a request, four times this, and several
        /// engines each keep one. Two requests would have to agree on both halves to be confused, which at a
        /// million requests is a chance of about one in 10^26. Order still comes from the keys themselves.
        private struct RowID: Hashable {
            let high: UInt64
            let low: UInt64

            init(_ key: ClaudeRowKey) {
                var first = Hasher()
                first.combine(0x9E37_79B9_7F4A_7C15 as UInt64)
                first.combine(key)
                var second = Hasher()
                second.combine(0xC2B2_AE3D_27D4_EB4F as UInt64)
                second.combine(key)
                self.high = UInt64(bitPattern: Int64(first.finalize()))
                self.low = UInt64(bitPattern: Int64(second.finalize()))
            }
        }

        private struct FileState {
            let rows: [ClaudeUsageRow]
            /// Indexes of this report's rows, in file order; nil when the report takes every row.
            let included: [Int]?

            var indexes: [Int] {
                self.included ?? Array(self.rows.indices)
            }

            var hasRows: Bool {
                !(self.included?.isEmpty ?? self.rows.isEmpty)
            }

            func isSame(as rows: [ClaudeUsageRow]) -> Bool {
                guard self.rows.count == rows.count else { return false }
                return self.rows.withUnsafeBufferPointer { lhs in
                    rows.withUnsafeBufferPointer { rhs in lhs.baseAddress == rhs.baseAddress }
                }
            }
        }

        /// The buckets a change touches.
        private struct Touched {
            var dayModels: Set<ClaudeDayModelKey> = []
            var days: Set<String> = []
            var hours: Set<Date> = []
            var slices: Set<Date> = []
            var sliceTimes: Set<Int64> = []

            var isEmpty: Bool {
                self.dayModels.isEmpty
            }
        }

        private let organizationID: String?
        private let lock = NSLock()
        private var configuration: Configuration?
        private var catalog: ModelsDevCatalog?
        private var files: [String: FileState] = [:]
        private var sortedPaths: [String] = []
        /// Every transcript the engine has seen since its last reset, numbered for `RowRef`.
        private var paths: [String] = []
        private var pathNumbers: [String: UInt32] = [:]
        private var winners: [RowID: RowRef] = [:]
        /// Every transcript's best row, for the requests more than one transcript has.
        private var sharedCandidates: [RowID: [RowRef]] = [:]
        private var aggregates: [ClaudeDayModelKey: ClaudeReportAggregate] = [:]
        private var packedDays: [String: [String: [Int]]] = [:]
        /// The time buckets as the report lists them, in time order. A touched bucket is summed again from its
        /// rows and replaced here; nothing else is kept of it. (A dictionary of every bucket beside these lists
        /// was never read back, and with one entry per request instant it outweighed them several times over.)
        private var hourlyEntries: [CostUsageHourlyEntry] = []
        private var sliceEntries: [CostUsageTimedEntry] = []

        init(organizationID: String?) {
            self.organizationID = organizationID
        }

        /// The report, and the packed day totals, that a full rebuild of `cache` gives. Nil for a machine report when a
        /// transcript has no rows to replay (a legacy cache), which only the full rebuild can report.
        func report(
            cache: CostUsageCache,
            range: CostUsageDayRange,
            pricingResolver: CostUsagePricing.ClaudeResolver,
            includeRequestCounts: Bool,
            replayingUnchangedRows: Bool = false)
            -> (report: CostUsageDailyReport, days: [String: [String: [Int]]])?
        {
            if self.organizationID == nil,
               cache.files.isEmpty || cache.files.values.contains(where: { $0.claudeRows == nil }) { return nil }
            #if DEBUG
            CostUsageScanner.recordClaudeScanWork(.reconcile)
            #endif
            return self.lock.withLock {
                let configuration = Configuration(
                    sinceKey: range.sinceKey,
                    untilKey: range.untilKey,
                    timeZoneIdentifier: range.calendar.timeZone.identifier)
                if configuration != self.configuration { self.reset(configuration) }
                var touched = self.applyChanges(
                    cache: cache, range: range, replayingUnchangedRows: replayingUnchangedRows)
                let hasRows = self.files.values.contains(where: \.hasRows)
                // Rows are priced only when there are rows, as a full rebuild loads the catalogue.
                if hasRows {
                    let catalog = pricingResolver.prepareCatalog()
                    if let priced = self.catalog, priced != catalog {
                        self.reset(configuration)
                        touched = self.applyChanges(cache: cache, range: range, replayingUnchangedRows: false)
                    }
                    self.catalog = catalog
                }
                if !touched.isEmpty { self.recompute(touched, range: range, pricingResolver: pricingResolver) }
                let report = CostUsageScanner.assembleClaudeReport(
                    repricedCosts: self.aggregates,
                    timeline: (self.hourlyEntries, self.sliceEntries),
                    // As the full rebuild: a machine cache has rows for every transcript; an organization's partition
                    // has the transcripts with its rows, and no packed days.
                    packedDays: self.organizationID == nil || hasRows ? nil : [:],
                    range: range,
                    includeRequestCounts: includeRequestCounts)
                return (report, self.packedDays)
            }
        }

        private func reset(_ configuration: Configuration) {
            self.configuration = configuration
            self.catalog = nil
            self.files = [:]
            self.sortedPaths = []
            self.paths = []
            self.pathNumbers = [:]
            self.winners = [:]
            self.sharedCandidates = [:]
            self.aggregates = [:]
            self.packedDays = [:]
            self.hourlyEntries = []
            self.sliceEntries = []
        }

        /// Replays the transcripts whose rows differ from the last scan's and returns the buckets they touch.
        /// Whether `rows` are what was already replayed for `path`, so nothing about it needs redoing.
        private func keepsState(path: String, rows: [ClaudeUsageRow], replayingUnchangedRows: Bool) -> Bool {
            guard let state = self.files[path] else { return false }
            if state.isSame(as: rows) { return true }
            // The cache was read from disk again: the same rows in new storage. Replaying them would withdraw
            // and re-add every request of every transcript, so only take over the new storage, which also lets
            // the previous copy go. A forced rescan asked for everything to be redone.
            guard !replayingUnchangedRows, state.rows == rows else { return false }
            self.files[path] = FileState(rows: rows, included: state.included)
            return true
        }

        private func applyChanges(
            cache: CostUsageCache,
            range: CostUsageDayRange,
            replayingUnchangedRows: Bool) -> Touched
        {
            var replaced: [String: FileState?] = [:]
            for (path, file) in cache.files {
                let rows = file.claudeRows ?? []
                if self.keepsState(path: path, rows: rows, replayingUnchangedRows: replayingUnchangedRows) {
                    continue
                }
                let included = self.organizationID.map { organization in
                    rows.indices.filter { rows[$0].organizationID == organization }
                }
                replaced[path] = FileState(rows: rows, included: included)
            }
            for path in self.files.keys where cache.files[path] == nil {
                replaced[path] = .some(nil)
            }
            var touched = Touched()
            guard !replaced.isEmpty else { return touched }

            func state(_ path: String) -> FileState? {
                if let replacement = replaced[path] { return replacement }
                return self.files[path]
            }
            var affected: Set<RowID> = []
            var previousWinners: [RowID: ClaudeUsageRow] = [:]
            func noteAffected(_ key: RowID) {
                guard affected.insert(key).inserted, let winner = self.winners[key] else { return }
                previousWinners[key] = self.files[self.paths[Int(winner.file)]]?.rows[Int(winner.index)]
            }
            // Withdraw every replaced transcript's rows before adding any, so a request moving between them is seen
            // once with all of its candidates.
            for (path, _) in replaced {
                guard let old = self.files[path] else { continue }
                let file = self.number(of: path)
                for key in Self.localWinners(old).keys {
                    noteAffected(key)
                    if var shared = self.sharedCandidates[key] {
                        shared.removeAll { $0.file == file }
                        self.sharedCandidates[key] = shared.count > 1 ? shared : nil
                        self.winners[key] = shared.count == 1 ? shared[0] : self.winners[key]
                    } else if self.winners[key]?.file == file {
                        self.winners[key] = nil
                    }
                }
                for index in old.indexes where CostUsageScanner.claudeCanonicalRowKey(old.rows[index]) == nil {
                    Self.touch(old.rows[index], range: range, into: &touched)
                }
            }
            for (path, replacement) in replaced {
                guard let new = replacement else { continue }
                let file = self.number(of: path)
                for (key, index) in Self.localWinners(new) {
                    noteAffected(key)
                    let ref = RowRef(file: file, index: UInt32(index))
                    if self.sharedCandidates[key] != nil {
                        self.sharedCandidates[key]?.append(ref)
                    } else if let current = self.winners[key] {
                        self.sharedCandidates[key] = [current, ref]
                    } else {
                        self.winners[key] = ref
                    }
                }
                for index in new.indexes where CostUsageScanner.claudeCanonicalRowKey(new.rows[index]) == nil {
                    Self.touch(new.rows[index], range: range, into: &touched)
                }
            }
            for key in affected {
                if let previous = previousWinners[key] { Self.touch(previous, range: range, into: &touched) }
                let refs = self.sharedCandidates[key] ?? self.winners[key].map { [$0] } ?? []
                let best = refs.compactMap { ref -> (ref: RowRef, path: String, row: ClaudeUsageRow)? in
                    let path = self.paths[Int(ref.file)]
                    return state(path).map { (ref, path, $0.rows[Int(ref.index)]) }
                }.min { Self.precedes($0, $1) }
                self.winners[key] = best?.ref
                if let best { Self.touch(best.row, range: range, into: &touched) }
            }
            for (path, replacement) in replaced {
                self.files[path] = replacement
            }
            self.sortedPaths = self.files.keys.sorted()
            return touched
        }

        /// Re-sums every touched bucket from its rows, in a full rebuild's order: rows without a request identity in
        /// transcript order, then each request's winner in request order.
        private func recompute(
            _ touched: Touched,
            range: CostUsageDayRange,
            pricingResolver: CostUsagePricing.ClaudeResolver)
        {
            for key in touched.dayModels {
                self.aggregates[key] = nil
                self.packedDays[key.day]?[key.model] = nil
            }
            var buckets = TemporalBuckets()
            let hourTimes = touched.hours.map { hour -> ClosedRange<Int64> in
                let start = Int64((hour.timeIntervalSince1970 * 1000).rounded(.down))
                return start...(start + 3_600_000)
            }
            func mayCount(_ row: ClaudeUsageRow) -> Bool {
                if touched.days.contains(row.dayKey) { return true }
                guard let time = row.timestampUnixMs else { return false }
                return touched.sliceTimes.contains(time) || hourTimes.contains { $0.contains(time) }
            }
            var unkeyed: [ClaudeUsageRow] = []
            var keyed: [(key: ClaudeRowKey, row: ClaudeUsageRow)] = []
            for path in self.sortedPaths {
                guard let state = self.files[path], let file = self.pathNumbers[path] else { continue }
                for index in state.indexes {
                    let row = state.rows[index]
                    guard mayCount(row) else { continue }
                    if let key = CostUsageScanner.claudeCanonicalRowKey(row) {
                        if self.winners[RowID(key)] == RowRef(file: file, index: UInt32(index)) {
                            keyed.append((key, row))
                        }
                    } else {
                        unkeyed.append(row)
                    }
                }
            }
            keyed.sort { $0.key < $1.key }
            var overflowed: Set<ClaudeDayModelKey> = []
            for row in unkeyed + keyed.map(\.row) {
                let key = ClaudeDayModelKey(day: row.dayKey, model: row.model)
                let complete = row.isIncomplete != true
                let timestamp = complete && CostUsageDayRange.isInRange(
                    dayKey: row.dayKey, since: range.sinceKey, until: range.untilKey)
                    ? CostUsageScanner.date(fromUnixMs: row.timestampUnixMs) : nil
                let hour = timestamp.map { CostUsageScanner.hourStart(for: $0, calendar: range.calendar) }
                let hourTouched = hour.map(touched.hours.contains) ?? false
                let sliceTouched = timestamp.map(touched.slices.contains) ?? false
                let dayModelTouched = touched.dayModels.contains(key)
                guard dayModelTouched || hourTouched || sliceTouched else { continue }
                #if DEBUG
                CostUsageScanner.recordClaudeScanWork(.reprice)
                #endif
                let cost = complete ? CostUsageScanner.claudeRowCost(row, pricingResolver: pricingResolver) : nil
                if dayModelTouched {
                    CostUsageScanner.accumulateClaudeRow(
                        row, cost: cost, into: &self.aggregates[key, default: ClaudeReportAggregate()])
                    if !overflowed.contains(key), !CostUsageScanner.addClaudeRow(
                        row, to: &self.packedDays[row.dayKey, default: [:]][
                            row.model,
                            default: [0, 0, 0, 0, 0, 0, 0, 0],
                        ])
                    {
                        // As a full rebuild: the packed format cannot hold a total that overflowed.
                        overflowed.insert(key)
                        self.packedDays[row.dayKey]?.removeValue(forKey: row.model)
                    }
                }
                if let hour, hourTouched {
                    Self.add(row, cost: cost, to: &buckets.hourly[hour, default: HourlyBucket()])
                }
                if let timestamp, sliceTouched {
                    Self.add(row, cost: cost, to: &buckets.quotaSlices[timestamp, default: HourlyBucket()])
                }
            }
            // A full rebuild keeps a day whose every total overflowed, and has no day without rows.
            let daysWithRows = Set(self.aggregates.keys.map(\.day))
            for day in touched.days where !daysWithRows.contains(day) {
                self.packedDays[day] = nil
            }
            self.hourlyEntries = Self.replacing(touched.hours, in: self.hourlyEntries, date: \.hour) { hour in
                buckets.hourly[hour]?.hourlyEntry(hour: hour)
            }
            self.sliceEntries = Self.replacing(touched.slices, in: self.sliceEntries, date: \.timestamp) { time in
                buckets.quotaSlices[time]?.timedEntry(timestamp: time)
            }
        }

        /// Replaces the entries of `touched` instants in a time-ordered list with their recomputed ones (none when the
        /// bucket is now empty), keeping the order a full rebuild sorts them into.
        private static func replacing<Entry>(
            _ touched: Set<Date>,
            in entries: [Entry],
            date: KeyPath<Entry, Date>,
            entry: (Date) -> Entry?) -> [Entry]
        {
            guard let lowest = touched.min(), let highest = touched.max() else { return entries }
            let replacements = touched.sorted().compactMap(entry)
            var result: [Entry] = []
            result.reserveCapacity(entries.count + replacements.count)
            var next = replacements.startIndex
            for existing in entries {
                let time = existing[keyPath: date]
                if time >= lowest, time <= highest, touched.contains(time) { continue }
                while next < replacements.endIndex, replacements[next][keyPath: date] < time {
                    result.append(replacements[next])
                    next += 1
                }
                result.append(existing)
            }
            result.append(contentsOf: replacements[next...])
            return result
        }

        /// One complete row's tokens and cost in one of its time buckets, as
        /// `addClaudeTemporal(row:costUSD:range:into:)`
        /// adds them (that file is part of the Codex parser hash, so it stays as it is).
        private static func add(_ row: ClaudeUsageRow, cost: Double?, to bucket: inout HourlyBucket) {
            for tokens in [row.input, row.cacheRead, row.cacheCreate, row.output] {
                bucket.addTokens(tokens)
            }
            bucket.addCost(cost)
        }

        private static func touch(_ row: ClaudeUsageRow, range: CostUsageDayRange, into touched: inout Touched) {
            touched.dayModels.insert(ClaudeDayModelKey(day: row.dayKey, model: row.model))
            touched.days.insert(row.dayKey)
            guard row.isIncomplete != true,
                  CostUsageDayRange.isInRange(dayKey: row.dayKey, since: range.sinceKey, until: range.untilKey),
                  let time = row.timestampUnixMs, let timestamp = CostUsageScanner.date(fromUnixMs: time)
            else { return }
            touched.hours.insert(CostUsageScanner.hourStart(for: timestamp, calendar: range.calendar))
            touched.slices.insert(timestamp)
            touched.sliceTimes.insert(time)
        }

        /// Each request's best row in one transcript: as in a full rebuild, a later row replaces an earlier one only
        /// when it ranks better.
        private static func localWinners(_ state: FileState) -> [RowID: Int] {
            var winners: [RowID: Int] = [:]
            for index in state.indexes {
                let row = state.rows[index]
                guard let key = CostUsageScanner.claudeCanonicalRowKey(row).map(RowID.init) else { continue }
                if let current = winners[key], Self.rank(state.rows[current]) <= Self.rank(row) { continue }
                winners[key] = index
            }
            return winners
        }

        /// The transcript's number for `RowRef`, given on first sight and kept until the next reset.
        private func number(of path: String) -> UInt32 {
            if let number = self.pathNumbers[path] { return number }
            let number = UInt32(self.paths.count)
            self.paths.append(path)
            self.pathNumbers[path] = number
            return number
        }

        /// Smaller is better, in the full rebuild's order of tests: complete, then main conversation, then parent.
        private static func rank(_ row: ClaudeUsageRow) -> Int {
            (row.isIncomplete == true ? 4 : 0) + (row.isSidechain ? 2 : 0) + (row.pathRole == .subagent ? 1 : 0)
        }

        /// The full rebuild's winner across transcripts: the best rank, then the earlier path, then the earlier row.
        private static func precedes(
            _ lhs: (ref: RowRef, path: String, row: ClaudeUsageRow),
            _ rhs: (ref: RowRef, path: String, row: ClaudeUsageRow)) -> Bool
        {
            let lhsRank = Self.rank(lhs.row)
            let rhsRank = Self.rank(rhs.row)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            if lhs.path != rhs.path { return lhs.path < rhs.path }
            return lhs.ref.index < rhs.ref.index
        }
    }
}
