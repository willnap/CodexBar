import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct ClaudeOrganizationUsageReaderTests {
    private static let first = "11111111-1111-1111-1111-111111111111"
    private static let second = "22222222-2222-2222-2222-222222222222"

    @Test func `organization totals equal a per organization filtered parse across switches and copies`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let now = try env.makeLocalNoon(year: 2026, month: 9, day: 20)
        let yesterday = now.addingTimeInterval(-86400)
        let lines = [
            Self.row(env: env, at: yesterday, id: "unknown", session: "s", input: 999),
            Self.attachment(org: Self.first, session: "s", at: yesterday),
            Self.row(env: env, at: yesterday, id: "a", session: "s", input: 100),
            // A claude-swap switch inside one session moves later requests to the other organization.
            Self.attachment(org: Self.second, session: "s", at: now),
            Self.row(env: env, at: now, id: "b", session: "s", input: 200),
            Self.row(env: env, at: now, id: "foreign-session", session: "other", input: 999),
        ]
        try Self.write(env.jsonl(lines), to: env.claudeProjectsRoot.appendingPathComponent("p/session.jsonl"))
        // A claude-swap backup copy repeats the same requests; reconciliation must not double count them.
        let backup = env.root.appendingPathComponent("backup/projects")
        try Self.write(env.jsonl(lines), to: backup.appendingPathComponent("p/session.jsonl"))
        let result = try await Self.read(env, roots: [env.claudeProjectsRoot, backup], now: now)
        let first = try #require(result.organizations[Self.first])
        let second = try #require(result.organizations[Self.second])
        #expect(first.last30DaysTokens == 110)
        #expect(first.daily.first?.requestCount == 1)
        #expect(first.sessionTokens == 0)
        #expect(second.sessionTokens == 210)
        #expect(second.last30DaysTokens == 210)
        #expect(first.historyIsFullyScanned)
        #expect(first.costProvenance == .listPriceEstimate)
        #expect(try abs(#require(first.last30DaysCostUSD) - 0.00045) < 0.000000001)
        #expect(result.machine?.last30DaysTokens == 1009 + 110 + 210 + 1009)

        // Equivalence with the reference: a parse filtered to each organization.
        for organization in [Self.first, Self.second] {
            let reference = try Self.filteredReference(env, organization: organization, now: now)
            let report = try #require(result.organizations[organization])
            #expect(report.last30DaysTokens == reference.tokens)
            #expect(report.last30DaysCostUSD.map { abs($0 - reference.cost) < 1e-12 } == true)
        }
    }

    @Test func `incremental append keeps attribution from attachments before the resume offset`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let now = try env.makeLocalNoon(year: 2026, month: 9, day: 20)
        let file = env.claudeProjectsRoot.appendingPathComponent("p/session.jsonl")
        let initial = [
            Self.attachment(org: Self.first, session: "s", at: now.addingTimeInterval(-600)),
            Self.row(env: env, at: now.addingTimeInterval(-500), id: "a", session: "s", input: 100),
        ]
        try Self.write(env.jsonl(initial), to: file)
        let before = try await Self.read(env, roots: [env.claudeProjectsRoot], now: now)
        #expect(before.organizations[Self.first]?.sessionTokens == 110)

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(env.jsonl([
            Self.row(env: env, at: now.addingTimeInterval(-100), id: "b", session: "s", input: 200),
        ]).utf8))
        try handle.close()
        let recorder = CostUsageScanner.ClaudeScanWorkRecorder()
        let after = try await CostUsageScanner.$observeClaudeScanWorkForTesting.withValue(recorder.record) {
            try await Self.readSynchronously(env, roots: [env.claudeProjectsRoot], now: now)
        }
        #expect(recorder.snapshot().incrementalTranscriptParses == 1)
        #expect(recorder.snapshot().transcriptParses == 1)
        #expect(after.organizations[Self.first]?.sessionTokens == 320)
        let cache = CostUsageClaudeCacheIO.load(
            provider: .claude, cacheRoot: env.cacheRoot, reportContext: .spendDashboard)
        // Temporary roots resolve through /private, so match the cached path by its project-relative suffix.
        let rows = try #require(cache.usage.files.first { $0.key.hasSuffix("/p/session.jsonl") }?.value.claudeRows)
        #expect(rows.allSatisfy { $0.organizationID == Self.first })
    }

    @Test func `idle owned organizations are covered zero from the first attachment`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let now = try env.makeLocalNoon(year: 2026, month: 9, day: 20)
        let threeDaysAgo = now.addingTimeInterval(-3 * 86400)
        try Self.write(env.jsonl([
            Self.row(env: env, at: threeDaysAgo.addingTimeInterval(-86400), id: "pre", session: "s", input: 5),
            Self.attachment(org: Self.first, session: "s", at: threeDaysAgo),
            Self.row(env: env, at: threeDaysAgo, id: "a", session: "s", input: 100),
        ]), to: env.claudeProjectsRoot.appendingPathComponent("p/session.jsonl"))
        let result = try await Self.read(env, roots: [env.claudeProjectsRoot], now: now)
        let active = try #require(result.organizations[Self.first])
        #expect(active.sessionTokens == 0)
        #expect(active.sessionCostUSD == 0)
        #expect(active.historyDays == 4)
        #expect(active.historyIsFullyScanned)
        // An owner with no attributed requests is a measured zero, not unknown.
        let idle = try #require(result.organizations[Self.second])
        #expect(idle.last30DaysTokens == 0)
        #expect(idle.last30DaysCostUSD == 0)
        #expect(idle.daily.isEmpty)
        #expect(idle.historyIsFullyScanned)
    }

    @Test func `organizations stay unknown when no transcript carries attribution`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let now = try env.makeLocalNoon(year: 2026, month: 9, day: 20)
        try Self.write(env.jsonl([
            Self.row(env: env, at: now, id: "a", session: "s", input: 100),
        ]), to: env.claudeProjectsRoot.appendingPathComponent("p/session.jsonl"))
        let result = try await Self.read(env, roots: [env.claudeProjectsRoot], now: now)
        #expect(result.organizations.isEmpty)
        #expect(result.machine?.sessionTokens == 110)
    }

    @Test func `malformed organization boundaries clear prior session ownership`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let now = try env.makeLocalNoon(year: 2026, month: 9, day: 20)
        for session in [nil, " "] as [String?] {
            var boundary: [String: Any] = [
                "type": "attachment",
                "attachment": ["type": "credential_org", "organizationUuid": Self.second],
            ]
            if let session { boundary["sessionId"] = session }
            try Self.write(env.jsonl([
                Self.attachment(org: Self.first, session: "s", at: now),
                Self.row(env: env, at: now, id: "owned", session: "s", input: 100),
                boundary,
                Self.row(env: env, at: now, id: "unknown", session: "s", input: 999),
            ]), to: env.claudeProjectsRoot.appendingPathComponent("p/session.jsonl"))
            let result = try await Self.read(env, roots: [env.claudeProjectsRoot], now: now)
            #expect(result.organizations[Self.first]?.sessionTokens == 110)
            #expect(result.organizations[Self.second]?.sessionTokens == 0)
        }
    }

    @Test func `organization daily totals survive pruned transcripts and restarts`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let now = try env.makeLocalNoon(year: 2026, month: 9, day: 20)
        let archive = env.root.appendingPathComponent("organization-archive")
        let old = env.claudeProjectsRoot.appendingPathComponent("p/old.jsonl")
        try Self.write(env.jsonl([
            Self.attachment(org: Self.first, session: "old", at: now.addingTimeInterval(-2 * 86400)),
            Self.row(env: env, at: now.addingTimeInterval(-2 * 86400), id: "old", session: "old", input: 100),
        ]), to: old)
        try Self.write(env.jsonl([
            Self.attachment(org: Self.first, session: "new", at: now),
            Self.row(env: env, at: now, id: "new", session: "new", input: 200),
        ]), to: env.claudeProjectsRoot.appendingPathComponent("p/new.jsonl"))
        let initial = try await Self.read(env, roots: [env.claudeProjectsRoot], now: now, archive: archive)
        #expect(initial.organizations[Self.first]?.last30DaysTokens == 320)
        // Claude Code prunes the older transcript; its attributed day remains measured.
        try FileManager.default.removeItem(at: old)
        let pruned = try await Self.read(env, roots: [env.claudeProjectsRoot], now: now, archive: archive)
        let report = try #require(pruned.organizations[Self.first])
        #expect(report.last30DaysTokens == 320)
        #expect(report.sessionTokens == 210)
        #expect(report.historyDays == 3)
        let document = try #require(ClaudeOrganizationUsageArchive.load(
            root: archive, timeZoneIdentifier: TimeZone.current.identifier))
        #expect(document.owners.values.flatMap(\.self).count == 2)
        // Unreadable or future archives are ignored, never trusted.
        let future = Data(#"{"version":999}"#.utf8)
        let archiveFile = archive.appendingPathComponent(ClaudeOrganizationUsageArchive.fileName)
        try future.write(to: archiveFile)
        let ignored = try await Self.read(env, roots: [env.claudeProjectsRoot], now: now, archive: archive)
        #expect(ignored.organizations[Self.first]?.last30DaysTokens == 210)
        #expect(try Data(contentsOf: archiveFile) == future)
    }

    @Test func `day rollover reparses only transcripts that skipped later dated rows`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 20)
        try Self.write(env.jsonl([
            Self.attachment(org: Self.first, session: "s", at: day),
            Self.row(env: env, at: day, id: "today", session: "s", input: 100),
        ]), to: env.claudeProjectsRoot.appendingPathComponent("p/settled.jsonl"))
        // Two days ahead of the first scan's window end: skipped now, so this file must be read again later.
        try Self.write(env.jsonl([
            Self.row(env: env, at: day.addingTimeInterval(2 * 86400), id: "ahead", session: "t", input: 5),
        ]), to: env.claudeProjectsRoot.appendingPathComponent("p/ahead.jsonl"))
        var options = CostUsageScanner.Options(claudeProjectsRoots: [env.claudeProjectsRoot], cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0
        options.claudeLogProviderFilter = .excludeVertexAI
        func load(_ now: Date) throws -> (CostUsageDailyReport, CostUsageScanner.ClaudeScanWorkMetrics) {
            let recorder = CostUsageScanner.ClaudeScanWorkRecorder()
            let report = try CostUsageScanner.withClaudeScanWorkRecorderForTesting(recorder) {
                try CostUsageScanner.loadDailyReportCancellable(
                    provider: .claude,
                    since: now.addingTimeInterval(-29 * 86400),
                    until: now,
                    now: now,
                    options: options,
                    reportContext: .spendDashboard,
                    checkCancellation: nil)
            }
            return (report, recorder.snapshot())
        }
        let (first, cold) = try load(day)
        #expect(cold.transcriptParses == 2)
        #expect(first.summary?.totalTokens == 110)
        let (next, rolled) = try load(day.addingTimeInterval(86400))
        #expect(rolled.transcriptParses == 1)
        #expect(next.summary?.totalTokens == 110)
        // The skipped row is now inside the window and already cached: the next rollover reads nothing.
        let (later, settled) = try load(day.addingTimeInterval(2 * 86400))
        #expect(settled.transcriptParses == 0)
        #expect(later.summary?.totalTokens == 125)
    }

    @Test func `attributed history replaces the unattributed v6 history artifact`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let now = try env.makeLocalNoon(year: 2026, month: 9, day: 20)
        let directory = env.cacheRoot.appendingPathComponent("cost-usage")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacy = ["claude-history-v6.json", "claude-history-v6.report-memo.json"]
            .map { directory.appendingPathComponent($0) }
        let regular = directory.appendingPathComponent("claude-v6.json")
        for url in legacy + [regular] {
            try Data("{}".utf8).write(to: url)
        }
        try Self.write(env.jsonl([
            Self.attachment(org: Self.first, session: "s", at: now),
            Self.row(env: env, at: now, id: "a", session: "s", input: 100),
        ]), to: env.claudeProjectsRoot.appendingPathComponent("p/session.jsonl"))
        let result = try await Self.read(env, roots: [env.claudeProjectsRoot], now: now)
        #expect(result.organizations[Self.first]?.sessionTokens == 110)
        #expect(legacy.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("claude-history-v7.json").path))
        #expect(try Data(contentsOf: regular) == Data("{}".utf8))
    }

    @Test func `dated organization events are grouped into five minute slices`() {
        let base = Date(timeIntervalSince1970: 1_790_000_000 - 1_790_000_000.truncatingRemainder(dividingBy: 300))
        let slices = (0..<10).map { index in
            CostUsageTimedEntry(
                timestamp: base.addingTimeInterval(Double(index) * 40),
                totalTokens: 10,
                costUSD: 0.5)
        }
        let grouped = CostUsageScanner.coarsenedQuotaSlices(slices, interval: 300)
        #expect(grouped.count == 2)
        #expect(grouped.map(\.totalTokens) == [80, 20])
        #expect(grouped.map(\.costUSD) == [4, 1])
        #expect(grouped.map(\.timestamp) == [base.addingTimeInterval(280), base.addingTimeInterval(360)])
        #expect(grouped.allSatisfy { $0.tokensAreComplete && $0.costIsComplete })
    }

    @Test func `adapter organization metadata is normalized and invalid evidence omitted`() throws {
        let payload = """
        {"schemaVersion":1,"activeAccountNumber":1,"accounts":[
          {"number":1,"active":true,"usageStatus":"ok","organizationUuid":"\(Self.first.uppercased())"},
          {"number":2,"active":false,"usageStatus":"ok","organizationUuid":"not-an-organization"}
        ]}
        """
        let list = try ClaudeSwapListParser.parse(Data(payload.utf8))
        let accounts = ClaudeSwapAccountProjection.accountSnapshots(from: list)
        #expect(accounts.first { $0.id.opaqueID == "1" }?.sourceOrganizationID == Self.first)
        #expect(accounts.first { $0.id.opaqueID == "2" }?.sourceOrganizationID == nil)
    }

    // MARK: - Helpers

    static func read(
        _ env: CostUsageTestEnvironment,
        roots: [URL],
        now: Date,
        archive: URL? = nil,
        organizations: [String] = [first, second]) async throws -> ClaudeLocalUsageResult
    {
        let fetcher = CostUsageFetcher(scannerOptions: CostUsageScanner.Options(
            claudeProjectsRoots: roots,
            cacheRoot: env.cacheRoot,
            calendar: .current))
        return try await ClaudeOrganizationUsageReader().read(
            organizationIDs: organizations,
            fetcher: fetcher,
            now: now,
            historyDays: 30,
            calendar: .current,
            archiveRoot: archive)
    }

    /// The executor queue does not inherit task locals; run the same projection inline to observe its work.
    private static func readSynchronously(
        _ env: CostUsageTestEnvironment,
        roots: [URL],
        now: Date) async throws -> ClaudeLocalUsageResult
    {
        let fetcher = CostUsageFetcher(scannerOptions: CostUsageScanner.Options(
            claudeProjectsRoots: roots,
            cacheRoot: env.cacheRoot,
            calendar: .current))
        let options = fetcher.claudeTranscriptScanOptions(calendar: .current)
        let since = Calendar.current.date(byAdding: .day, value: -29, to: now) ?? now
        let reports = try CostUsageScanner.loadClaudeLocalUsageReports(
            organizationIDs: [self.first, self.second],
            range: .init(since: since, until: now, calendar: .current),
            now: now,
            options: options,
            checkCancellation: nil)
        return ClaudeOrganizationUsageReader.result(
            from: reports, now: now, historyDays: 30, calendar: .current, archiveRoot: nil)
    }

    private static func filteredReference(
        _ env: CostUsageTestEnvironment,
        organization: String,
        now: Date) throws -> (tokens: Int, cost: Double)
    {
        let since = Calendar.current.date(byAdding: .day, value: -29, to: now) ?? now
        let range = CostUsageScanner.CostUsageDayRange(since: since, until: now, calendar: .current)
        let resolver = CostUsagePricing.ClaudeResolver(now: now, cacheRoot: env.cacheRoot)
        var rows: [CostUsageScanner.ClaudeUsageRow] = []
        for url in [
            env.claudeProjectsRoot.appendingPathComponent("p/session.jsonl"),
            env.root.appendingPathComponent("backup/projects/p/session.jsonl"),
        ] {
            rows += try CostUsageScanner.parseClaudeFileCancellable(
                fileURL: url,
                range: range,
                providerFilter: .excludeVertexAI,
                pricingResolver: resolver,
                organizationID: organization).rows
        }
        let merged = CostUsageScanner.mergeClaudeRows(existing: [], delta: rows)
        let tokens = merged.reduce(0) { $0 + $1.input + $1.output + $1.cacheRead + $1.cacheCreate }
        let cost = merged.reduce(0.0) { $0 + Double($1.costNanos) / 1_000_000_000 }
        return (tokens, cost)
    }

    private static func attachment(org: String, session: String, at: Date) -> [String: Any] {
        [
            "type": "attachment",
            "sessionId": session,
            "timestamp": ISO8601DateFormatter().string(from: at),
            "attachment": ["type": "credential_org", "organizationUuid": org],
        ]
    }

    private static func row(
        env: CostUsageTestEnvironment,
        at: Date,
        id: String,
        session: String,
        input: Int) -> [String: Any]
    {
        [
            "type": "assistant",
            "timestamp": env.isoString(for: at),
            "sessionId": session,
            "requestId": "req-\(id)",
            "message": [
                "id": id,
                "model": "claude-sonnet-4-5-20250929",
                "usage": ["input_tokens": input, "output_tokens": 10],
            ],
        ]
    }

    private static func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
