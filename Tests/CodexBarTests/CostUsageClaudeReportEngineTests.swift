import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized, CostUsageClaudeCacheFixtures())
struct CostUsageClaudeReportEngineTests {
    private typealias Scanner = CostUsageScanner
    private static let organizations: Set<String> = ["org-a", "org-b"]

    @Test(arguments: 0..<3)
    func `the engine reports exactly what a full rebuild does as transcripts change`(seed: Int) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        var generator = Generator(state: UInt64(seed + 1))
        let engine = Scanner.ClaudeReportEngine(organizationID: nil)
        var cache = Self.attributed(CostUsageClaudeRebuildTests.cache(
            fileCount: 24, rowsPerFile: 40, includeOverflow: true))
        var range = CostUsageClaudeRebuildTests.range
        for step in 0..<14 {
            if step == 9 {
                // A new day moves the range: everything is rebuilt.
                range = .init(
                    since: CostUsageClaudeRebuildTests.now.addingTimeInterval(-20 * 86400),
                    until: CostUsageClaudeRebuildTests.now,
                    calendar: range.calendar)
            }
            let full = Self.fullRebuild(cache, range: range, env: env, includeRequestCounts: false)
            let incremental = try #require(engine.report(
                cache: cache,
                range: range,
                pricingResolver: Self.resolver(env),
                includeRequestCounts: false))
            #expect(try Self.bytes(incremental.report) == Self.bytes(full.report), "step \(step)")
            #expect(incremental.days == full.days, "step \(step)")
            cache = Self.changed(cache, step: step, generator: &generator)
        }
    }

    @Test func `organization engines report exactly what their partitions' full rebuilds do`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        var generator = Generator(state: 7)
        var cache = Self.attributed(CostUsageClaudeRebuildTests.cache(fileCount: 16, rowsPerFile: 30))
        let range = CostUsageClaudeRebuildTests.range
        for step in 0..<10 {
            let full = Scanner.claudeOrganizationReports(
                cache: cache,
                organizationIDs: Self.organizations.union(["org-unused"]),
                range: range,
                pricingResolver: Self.resolver(env))
            let incremental = Scanner.claudeOrganizationReports(
                cache: cache,
                organizationIDs: Self.organizations.union(["org-unused"]),
                range: range,
                pricingResolver: Self.resolver(env),
                cachePath: "engine-fixture")
            #expect(incremental.attributionStart == full.attributionStart)
            #expect(Set(incremental.organizations.keys) == Set(full.organizations.keys))
            for (organization, report) in full.organizations {
                let replayed = try #require(incremental.organizations[organization])
                #expect(try Self.bytes(replayed) == Self.bytes(report), "step \(step) \(organization)")
            }
            cache = Self.changed(cache, step: step, generator: &generator)
        }
    }

    @Test func `an unchanged cache reprices nothing`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let engine = Scanner.ClaudeReportEngine(organizationID: nil)
        var cache = CostUsageClaudeRebuildTests.cache(fileCount: 8, rowsPerFile: 20)
        _ = engine.report(
            cache: cache,
            range: CostUsageClaudeRebuildTests.range,
            pricingResolver: Self.resolver(env),
            includeRequestCounts: false)
        let recorder = Scanner.ClaudeScanWorkRecorder()
        Scanner.withClaudeScanWorkRecorderForTesting(recorder) {
            _ = engine.report(
                cache: cache,
                range: CostUsageClaudeRebuildTests.range,
                pricingResolver: Self.resolver(env),
                includeRequestCounts: false)
        }
        #expect(recorder.snapshot().repricedRows == 0)
        // Appending one request reprices only the rows in that request's buckets.
        let path = try #require(cache.files.keys.min())
        var row = try #require(cache.files[path]?.claudeRows?.first)
        row = Self.copy(row, messageID: "appended", requestID: "appended", isSidechain: false)
        cache.files[path]?.claudeRows?.append(row)
        let appended = Scanner.ClaudeScanWorkRecorder()
        Scanner.withClaudeScanWorkRecorderForTesting(appended) {
            _ = engine.report(
                cache: cache,
                range: CostUsageClaudeRebuildTests.range,
                pricingResolver: Self.resolver(env),
                includeRequestCounts: false)
        }
        let total = cache.files.values.reduce(0) { $0 + ($1.claudeRows?.count ?? 0) }
        #expect(appended.snapshot().repricedRows > 0)
        #expect(appended.snapshot().repricedRows < total / 4)
    }

    @Test func `appends stay in memory between the app's cache writes and reach the file at the next one`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 1)
        func event(_ id: String, input: Int) -> [String: Any] {
            [
                "type": "assistant", "timestamp": env.isoString(for: day), "requestId": id,
                "message": [
                    "id": id,
                    "model": "claude-sonnet-4-6",
                    "usage": ["input_tokens": input, "output_tokens": 0],
                ],
            ]
        }
        let file = try env.writeClaudeProjectFile(
            relativePath: "project/session.jsonl", contents: env.jsonl([event("first", input: 10)]))
        func append(_ id: String, input: Int) throws {
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(env.jsonl([event(id, input: input)]).utf8))
            try handle.close()
        }
        var options = CostUsageScanner.Options(claudeProjectsRoots: [env.claudeProjectsRoot], cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0
        func load() throws -> Int? {
            try CostUsageScanner.loadDailyReportCancellable(
                provider: .claude, since: day, until: day, now: day, options: options, checkCancellation: nil)
                .summary?.totalInputTokens
        }
        let cacheURL = CostUsageClaudeCacheIO.cacheFileURL(provider: .claude, cacheRoot: env.cacheRoot)
        let memoURL = CostUsageClaudeReportMemo.reportMemoFileURL(cacheFileURL: cacheURL)
        let schedule = CostUsageClaudeCacheIO.WriteSchedule()
        schedule.setInterval(600)
        try CostUsageClaudeCacheIO.WriteSchedule.$shared.withValue(schedule) {
            #expect(try load() == 10)
            let written = try [Data(contentsOf: cacheURL), Data(contentsOf: memoURL)]
            try append("second", input: 5)
            #expect(try load() == 15)
            #expect(try load() == 15)
            #expect(try [Data(contentsOf: cacheURL), Data(contentsOf: memoURL)] == written)
        }
        // The next write (here, with deferral off) records everything kept in memory.
        try append("third", input: 1)
        #expect(try load() == 16)
        CostUsageClaudeCacheIO.evictArtifactMemoForTesting(at: cacheURL)
        let reloaded = CostUsageClaudeCacheIO.load(provider: .claude, cacheRoot: env.cacheRoot)
        #expect(reloaded.usage.files.values.compactMap(\.claudeRows).joined().map(\.input).sorted() == [1, 5, 10])
    }

    // MARK: - Fixture changes

    private static func changed(
        _ cache: CostUsageCache,
        step: Int,
        generator: inout Generator) -> CostUsageCache
    {
        var cache = cache
        let paths = cache.files.keys.sorted()
        let path = paths[Int.random(in: 0..<paths.count, using: &generator)]
        let rows = cache.files[path]?.claudeRows ?? []
        guard !rows.isEmpty else { return cache }
        switch step % 6 {
        case 0:
            // New requests, and a better copy of an existing one.
            var appended = (0..<5).map { index in
                Self.copy(
                    rows[index % max(1, rows.count)],
                    messageID: "new-\(step)-\(index)",
                    requestID: "new-\(step)-\(index)",
                    isSidechain: false)
            }
            if let first = rows.first(where: { $0.isSidechain }) {
                appended.append(Self.copy(
                    first, messageID: first.messageId, requestID: first.requestId, isSidechain: false))
            }
            cache.files[path]?.claudeRows = rows + appended
        case 1:
            // A transcript that sorts first, repeating another's requests.
            let source = cache.files[paths[0]]?.claudeRows ?? []
            cache.files["project/!copy-\(step).jsonl"] = .init(
                mtimeUnixMs: 0, size: 3, days: [:], parsedBytes: 3, claudeRows: source.reversed())
        case 2:
            cache.files[path] = nil
        case 3:
            cache.files[path]?.claudeRows = rows.shuffled(using: &generator)
        case 4:
            cache.files[path]?.claudeRows = rows.enumerated().map { index, row in
                var row = row
                if index.isMultiple(of: 3) { row.isIncomplete = row.isIncomplete == true ? nil : true }
                return row
            }
        default:
            break
        }
        return cache
    }

    private static func attributed(_ cache: CostUsageCache) -> CostUsageCache {
        var cache = cache
        for path in cache.files.keys {
            let rows = cache.files[path]?.claudeRows?.enumerated().map { index, row in
                var row = row
                row.organizationID = ["org-a", "org-b", nil][index % 3]
                return row
            }
            cache.files[path]?.claudeRows = rows
        }
        return cache
    }

    private static func copy(
        _ row: Scanner.ClaudeUsageRow,
        messageID: String?,
        requestID: String?,
        isSidechain: Bool) -> Scanner.ClaudeUsageRow
    {
        var copy = Scanner.ClaudeUsageRow(
            dayKey: row.dayKey,
            model: row.model,
            sessionId: row.sessionId,
            messageId: messageID,
            requestId: requestID,
            timestampUnixMs: row.timestampUnixMs,
            isSidechain: isSidechain,
            pathRole: row.pathRole,
            input: row.input + 1,
            cacheRead: row.cacheRead,
            cacheCreate: row.cacheCreate,
            cacheCreate1h: row.cacheCreate1h,
            output: row.output,
            costNanos: row.costNanos,
            costPriced: row.costPriced,
            isIncomplete: nil)
        copy.organizationID = row.organizationID
        return copy
    }

    // MARK: - Oracles

    private static func fullRebuild(
        _ cache: CostUsageCache,
        range: Scanner.CostUsageDayRange,
        env: CostUsageTestEnvironment,
        includeRequestCounts: Bool) -> (report: CostUsageDailyReport, days: [String: [String: [Int]]])
    {
        var cache = cache
        let rows = Scanner.reconciledClaudeRows(cache: cache)
        Scanner.rebuildClaudeDays(cache: &cache, rows: rows)
        let report = Scanner.buildClaudeReportFromCache(
            cache: cache,
            rows: rows,
            range: range,
            pricingResolver: self.resolver(env),
            includeRequestCounts: includeRequestCounts)
        return (report, cache.days)
    }

    private static func resolver(_ env: CostUsageTestEnvironment) -> CostUsagePricing.ClaudeResolver {
        CostUsagePricing.ClaudeResolver(now: CostUsageClaudeRebuildTests.now, cacheRoot: env.cacheRoot)
    }

    private static func bytes(_ report: CostUsageDailyReport) throws -> [Data] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try [
            encoder.encode(report),
            encoder.encode(report.hourly.map(CostUsageCodexPreviousReport.HourlyEntry.init)),
            encoder.encode(report.quotaSlices.map(CostUsageCodexPreviousReport.QuotaSlice.init)),
        ]
    }

    private struct Generator: RandomNumberGenerator {
        var state: UInt64

        mutating func next() -> UInt64 {
            self.state &+= 0x9E37_79B9_7F4A_7C15
            var value = self.state
            value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
            value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
            return value ^ (value >> 31)
        }
    }
}
