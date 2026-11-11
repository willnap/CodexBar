import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized, CostUsageClaudeCacheFixtures())
struct CostUsageScannerClaudeMemoTests {
    @Test(arguments: [false, true])
    func `atomic transcript replacement discards prior rows in warm and cold processes`(cold: Bool) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 1)
        let file = try self.writeEvent(env: env, day: day, path: "project/session.jsonl", id: "old", input: 1000)
        let options = self.options(env: env)
        #expect(self.load(day: day, options: options).summary?.totalInputTokens == 1000)
        let original = try #require(CostUsageClaudeFileStamp.read(at: file))
        var first = self.event(env: env, day: day, id: "replacement-first", input: 7)
        first["fixturePadding"] = String(repeating: "x", count: Int(original.size) + 32)
        let replacement = try env.jsonl([first, self.event(env: env, day: day, id: "replacement-last", input: 17)])
        try Data(replacement.utf8).write(to: file, options: .atomic)
        let changed = try #require(CostUsageClaudeFileStamp.read(at: file))
        #expect(changed.fileID != original.fileID)
        #expect(changed.size > original.size)
        if cold {
            CostUsageScanner.evictClaudeReportMemoForTesting(provider: .claude, cacheRoot: env.cacheRoot)
        }

        let (normal, work) = self.recordedLoad(day: day, options: options)
        #expect(work.incrementalTranscriptParses == 0)
        var forced = options
        forced.forceRescan = true
        let oracle = self.load(day: day, options: forced)
        #expect(oracle.summary?.totalInputTokens == 24)
        #expect(normal.data == oracle.data)
        #expect(normal.summary == oracle.summary)
    }

    @Test(arguments: [false, true])
    func `replacement with unchanged size and modification time is still reparsed`(cold: Bool) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 1)
        let file = try self.writeEvent(env: env, day: day, path: "project/session.jsonl", id: "same", input: 1000)
        try FileManager.default.setAttributes([.modificationDate: day], ofItemAtPath: file.path)
        let options = self.options(env: env)
        _ = self.load(day: day, options: options)
        let original = try #require(CostUsageClaudeFileStamp.read(at: file))
        let replacement = try env.jsonl([self.event(env: env, day: day, id: "same", input: 2000)])
        try Data(replacement.utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes(
            [.modificationDate: day],
            ofItemAtPath: file.path)
        let changed = try #require(CostUsageClaudeFileStamp.read(at: file))
        #expect(changed.fileID != original.fileID)
        #expect(changed.size == original.size)
        #expect(changed.mtimeUnixMs == original.mtimeUnixMs)
        if cold {
            CostUsageScanner.evictClaudeReportMemoForTesting(provider: .claude, cacheRoot: env.cacheRoot)
        }

        let (report, work) = self.recordedLoad(day: day, options: options)
        #expect(report.summary?.totalInputTokens == 2000)
        #expect(work.transcriptParses == 1)
        #expect(work.incrementalTranscriptParses == 0)
    }

    @Test
    func `cache identities round trip with empty parsed rows and prune removed files`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 1)
        let file = try env.writeClaudeProjectFile(relativePath: "project/empty.jsonl", contents: "{}\n")
        let options = self.options(env: env)
        _ = self.load(day: day, options: options)
        let artifact = CostUsageClaudeCacheIO.load(provider: .claude, cacheRoot: env.cacheRoot)
        let path = try #require(artifact.usage.files.keys.first)
        #expect(artifact.usage.files[path]?.claudeRows == [])
        #expect(artifact.sourceFileIDs[path] == CostUsageClaudeFileStamp.read(at: file)?.fileID)
        CostUsageScanner.evictClaudeReportMemoForTesting(provider: .claude, cacheRoot: env.cacheRoot)
        #expect(self.recordedLoad(day: day, options: options).1.transcriptParses == 0)
        try FileManager.default.removeItem(at: file)
        _ = self.load(day: day, options: options)
        let pruned = CostUsageClaudeCacheIO.load(provider: .claude, cacheRoot: env.cacheRoot)
        #expect(pruned.usage.files.isEmpty)
        #expect(pruned.sourceFileIDs.isEmpty)
    }

    @Test
    func `legacy cache without file identity is rebuilt once before append reuse`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 1)
        let file = try self.writeEvent(env: env, day: day, path: "project/session.jsonl", id: "same", input: 10)
        var options = self.options(env: env)
        options.refreshMinIntervalSeconds = 60
        _ = self.load(day: day, options: options)
        var cache = CostUsageClaudeCacheIO.load(provider: .claude, cacheRoot: env.cacheRoot)
        #expect(cache.usage.files.count == 1)
        let path = try #require(cache.usage.files.keys.first)
        #expect(cache.sourceFileIDs[path] == CostUsageClaudeFileStamp.read(at: file)?.fileID)
        cache.sourceFileIDs[path] = nil
        let legacyData = try JSONEncoder().encode(cache.usage)
        try legacyData.write(to: CostUsageClaudeCacheIO.cacheFileURL(provider: .claude, cacheRoot: env.cacheRoot))
        CostUsageScanner.evictClaudeReportMemoForTesting(provider: .claude, cacheRoot: env.cacheRoot)

        let (report, work) = self.recordedLoad(day: day, options: options)
        #expect(report.summary?.totalInputTokens == 10)
        #expect(work.transcriptParses == 1)
        #expect(work.incrementalTranscriptParses == 0)
        let refreshed = CostUsageClaudeCacheIO.load(provider: .claude, cacheRoot: env.cacheRoot)
        #expect(refreshed.sourceFileIDs[path] == CostUsageClaudeFileStamp.read(at: file)?.fileID)
        CostUsageScanner.evictClaudeReportMemoForTesting(provider: .claude, cacheRoot: env.cacheRoot)
        #expect(self.recordedLoad(day: day, options: options).1.transcriptParses == 0)
    }

    @Test
    func `identical warm refresh only inventories sources`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 1)
        _ = try self.writeEvent(env: env, day: day, path: "project/session.jsonl", id: "first", input: 10)
        let options = self.options(env: env)
        let initial = self.load(day: day, options: options)
        let cacheURL = self.cacheURL(env: env)
        let cacheStamp = CostUsageClaudeFileStamp.read(at: cacheURL)

        let (warm, metrics) = self.recordedLoad(day: day, options: options)

        #expect(warm.data == initial.data)
        #expect(warm.summary == initial.summary)
        #expect(metrics == CostUsageScanner.ClaudeScanWorkMetrics())
        #expect(CostUsageClaudeFileStamp.read(at: cacheURL) == cacheStamp)
    }

    @Test
    func `cold process reuses the persisted report memo without decoding the cache`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 1)
        _ = try self.writeEvent(env: env, day: day, path: "project/first.jsonl", id: "first", input: 10)
        _ = try self.writeEvent(env: env, day: day, path: "project/second.jsonl", id: "second", input: 20)
        let options = self.options(env: env)
        let initial = self.load(day: day, options: options)
        let memoURL = CostUsageClaudeReportMemo.reportMemoFileURL(cacheFileURL: self.cacheURL(env: env))
        #expect(FileManager.default.fileExists(atPath: memoURL.path))
        CostUsageScanner.evictClaudeReportMemoForTesting(provider: .claude, cacheRoot: env.cacheRoot)

        let (restarted, metrics) = self.recordedLoad(day: day, options: options)

        #expect(restarted.data == initial.data)
        #expect(restarted.summary == initial.summary)
        #expect(!initial.quotaSlices.isEmpty)
        #expect(restarted.hourly == initial.hourly)
        #expect(restarted.quotaSlices == initial.quotaSlices)
        #expect(metrics == CostUsageScanner.ClaudeScanWorkMetrics())
    }

    @Test
    func `cold memo preserves priced and unpriced requests at one timestamp`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 1)
        _ = try self.writeEvent(env: env, day: day, path: "project/priced.jsonl", id: "priced", input: 100)
        _ = try self.writeEvent(
            env: env,
            day: day,
            path: "project/unpriced.jsonl",
            id: "unpriced",
            input: 200,
            model: "fixture-model-without-price")
        let options = self.options(env: env)
        let initial = self.load(day: day, options: options)
        let slice = try #require(initial.quotaSlices.first)
        #expect(slice.totalTokens == 300)
        #expect(slice.tokensAreComplete)
        #expect(slice.costUSD != nil)
        #expect(!slice.costIsComplete)
        CostUsageScanner.evictClaudeReportMemoForTesting(provider: .claude, cacheRoot: env.cacheRoot)
        let (restarted, metrics) = self.recordedLoad(day: day, options: options)
        #expect(restarted.quotaSlices == initial.quotaSlices)
        #expect(restarted.hourly == initial.hourly)
        #expect(metrics == CostUsageScanner.ClaudeScanWorkMetrics())
    }

    @Test(arguments: [nil, 0, 4, 5, 6, 7, CostUsageClaudeReportMemo.reportSemanticsVersion + 1] as [Int?])
    func `cold process rejects reports from incompatible semantics`(revision: Int?) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 1)
        let sourceURL = try self.writeEvent(env: env, day: day, path: "project/session.jsonl", id: "first", input: 10)
        let options = self.options(env: env)
        let initial = self.load(day: day, options: options)
        let sourceStamp = CostUsageClaudeFileStamp.read(at: sourceURL)
        let memoURL = CostUsageClaudeReportMemo.reportMemoFileURL(cacheFileURL: self.cacheURL(env: env))
        var envelope = try claudeMemoObjectForTesting(at: memoURL)
        envelope["reportSemanticsVersion"] = revision
        envelope["report"] = [
            "type": "codexbar-claude-report-memo", "data": [],
            "summary": ["totalTokens": 9999, "totalCostUSD": 9999],
        ]
        try JSONSerialization.data(withJSONObject: envelope).write(to: memoURL)
        CostUsageScanner.evictClaudeReportMemoForTesting(provider: .claude, cacheRoot: env.cacheRoot)

        let (restarted, metrics) = self.recordedLoad(day: day, options: options)

        #expect(restarted.data == initial.data)
        #expect(restarted.summary == initial.summary)
        #expect(!initial.quotaSlices.isEmpty)
        #expect(restarted.hourly == initial.hourly)
        #expect(restarted.quotaSlices == initial.quotaSlices)
        // Publication evicts decoded source rows; a memo miss reloads the persisted artifact once.
        #expect(metrics.cacheDecodes == 1)
        #expect(metrics.transcriptParses == 0)
        #expect(CostUsageClaudeFileStamp.read(at: sourceURL) == sourceStamp)
        let rewritten = try claudeMemoObjectForTesting(at: memoURL)
        #expect(rewritten["reportSemanticsVersion"] as? Int == CostUsageClaudeReportMemo.reportSemanticsVersion)
    }

    @Test(arguments: [false, true])
    func `missing or corrupt memo decodes the cache without parsing transcripts`(corrupt: Bool) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 1)
        _ = try self.writeEvent(env: env, day: day, path: "project/first.jsonl", id: "first", input: 10)
        _ = try self.writeEvent(env: env, day: day, path: "project/second.jsonl", id: "second", input: 20)
        let options = self.options(env: env)
        let initial = self.load(day: day, options: options)
        CostUsageScanner.evictClaudeReportMemoForTesting(provider: .claude, cacheRoot: env.cacheRoot)
        CostUsageScanner.evictPersistedClaudeReportMemoForTesting(provider: .claude, cacheRoot: env.cacheRoot)
        if corrupt {
            let memoURL = CostUsageClaudeReportMemo.reportMemoFileURL(cacheFileURL: self.cacheURL(env: env))
            try Data("invalid JSON".utf8).write(to: memoURL)
        }

        CostUsageClaudeCacheIO.evictArtifactMemoForTesting(at: self.cacheURL(env: env))
        let (restarted, metrics) = self.recordedLoad(day: day, options: options)

        #expect(restarted.data == initial.data)
        #expect(restarted.summary == initial.summary)
        #expect(!initial.quotaSlices.isEmpty)
        #expect(restarted.hourly == initial.hourly)
        #expect(restarted.quotaSlices == initial.quotaSlices)
        #expect(metrics.cacheDecodes == 1)
        #expect(metrics.transcriptParses == 0)
    }

    @Test
    func `nested source addition invalidates the memo`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 2)
        _ = try self.writeEvent(env: env, day: day, path: "project/session.jsonl", id: "first", input: 10)
        let options = self.options(env: env)
        _ = self.load(day: day, options: options)
        _ = try self.writeEvent(
            env: env,
            day: day,
            path: "project/nested/deeper/session.jsonl",
            id: "nested",
            input: 20)

        let (report, metrics) = self.recordedLoad(day: day, options: options)

        #expect(report.summary?.totalInputTokens == 30)
        #expect(metrics.cacheDecodes == 1)
        #expect(metrics.transcriptParses == 1)
        #expect(metrics.cacheEncodes == 1)
    }

    @Test
    func `source append invalidates the memo and parses the delta`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 3)
        let fileURL = try self.writeEvent(
            env: env,
            day: day,
            path: "project/session.jsonl",
            id: "first",
            input: 10)
        let options = self.options(env: env)
        _ = self.load(day: day, options: options)
        let appended = try env.jsonl([self.event(env: env, day: day, id: "second", input: 20)])
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(appended.utf8))
        try handle.close()

        let (report, metrics) = self.recordedLoad(day: day, options: options)

        #expect(report.summary?.totalInputTokens == 30)
        #expect(metrics.cacheDecodes == 1)
        #expect(metrics.transcriptParses == 1)
        #expect(metrics.incrementalTranscriptParses == 1)
        #expect(metrics.reconciliations == 1)
        #expect(metrics.cacheEncodes == 1)
    }

    @Test
    func `individual source deletion invalidates the memo and removes its rows`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 4)
        let deletedURL = try self.writeEvent(
            env: env,
            day: day,
            path: "project/deleted.jsonl",
            id: "deleted",
            input: 10)
        _ = try self.writeEvent(
            env: env,
            day: day,
            path: "project/retained.jsonl",
            id: "retained",
            input: 20)
        let options = self.options(env: env)
        _ = self.load(day: day, options: options)
        try FileManager.default.removeItem(at: deletedURL)

        let (report, metrics) = self.recordedLoad(day: day, options: options)

        #expect(report.summary?.totalInputTokens == 20)
        #expect(metrics.cacheDecodes == 1)
        #expect(metrics.transcriptParses == 0)
        #expect(metrics.cacheEncodes == 1)
    }

    @Test
    func `missing source root invalidates the memo and deletes cached rows`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 4)
        _ = try self.writeEvent(env: env, day: day, path: "project/session.jsonl", id: "first", input: 10)
        let options = self.options(env: env)
        _ = self.load(day: day, options: options)
        try FileManager.default.removeItem(at: env.claudeProjectsRoot)

        let (report, metrics) = self.recordedLoad(day: day, options: options)

        #expect(report.data.isEmpty)
        #expect(metrics.cacheDecodes == 1)
        #expect(metrics.transcriptParses == 0)
        #expect(metrics.cacheEncodes == 1)
    }

    @Test
    func `external atomic cache replacement invalidates the memo`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 5)
        _ = try self.writeEvent(env: env, day: day, path: "project/session.jsonl", id: "first", input: 10)
        let options = self.options(env: env)
        let initial = self.load(day: day, options: options)
        let cacheURL = self.cacheURL(env: env)
        let originalStamp = try #require(CostUsageClaudeFileStamp.read(at: cacheURL))
        let cacheData = try Data(contentsOf: cacheURL)
        try cacheData.write(to: cacheURL, options: [.atomic])
        let replacementStamp = try #require(CostUsageClaudeFileStamp.read(at: cacheURL))
        #expect(replacementStamp.fileID != originalStamp.fileID)

        let (report, metrics) = self.recordedLoad(day: day, options: options)

        #expect(report.data == initial.data)
        #expect(metrics.cacheDecodes == 1)
        #expect(metrics.transcriptParses == 0)
        #expect(metrics.cacheEncodes == 1)
    }

    @Test
    func `force rescan bypasses an exact memo hit`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 6)
        _ = try self.writeEvent(env: env, day: day, path: "project/session.jsonl", id: "first", input: 10)
        var options = self.options(env: env)
        _ = self.load(day: day, options: options)
        options.forceRescan = true

        let (report, metrics) = self.recordedLoad(day: day, options: options)

        #expect(report.summary?.totalInputTokens == 10)
        #expect(metrics.cacheDecodes == 1)
        #expect(metrics.transcriptParses == 1)
        #expect(metrics.cacheEncodes == 1)
        #expect(metrics.repricedRows == 1)
    }

    @Test(arguments: [false, true])
    func `pricing replacement reprices without parsing or rewriting the claude cache`(cold: Bool) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 7)
        let model = "claude-test-memo-pricing"
        _ = try self.writeEvent(
            env: env,
            day: day,
            path: "project/session.jsonl",
            id: "first",
            input: 100,
            model: model)
        #expect(try ModelsDevCache.save(
            catalog: self.catalog(model: model, inputRate: 10),
            fetchedAt: day,
            cacheRoot: env.cacheRoot))
        let options = self.options(env: env)
        let first = self.load(day: day, options: options)
        let cacheURL = self.cacheURL(env: env)
        let cacheStamp = CostUsageClaudeFileStamp.read(at: cacheURL)
        #expect(abs((first.summary?.totalCostUSD ?? 0) - 0.001) < 0.000000001)
        #expect(try ModelsDevCache.save(
            catalog: self.catalog(model: model, inputRate: 20),
            fetchedAt: day.addingTimeInterval(1),
            cacheRoot: env.cacheRoot))

        if cold {
            CostUsageScanner.evictClaudeReportMemoForTesting(provider: .claude, cacheRoot: env.cacheRoot)
            CostUsageClaudeCacheIO.evictArtifactMemoForTesting(at: cacheURL)
        }
        let (repriced, metrics) = self.recordedLoad(day: day, options: options)

        #expect(abs((repriced.summary?.totalCostUSD ?? 0) - 0.002) < 0.000000001)
        #expect(metrics.cacheDecodes == 1)
        #expect(metrics.transcriptParses == 0)
        #expect(metrics.cacheEncodes == 0)
        #expect(metrics.repricedRows == 1)
        #expect(CostUsageClaudeFileStamp.read(at: cacheURL) == cacheStamp)
    }

    @Test
    func `timezone change invalidates the memo and rebuilds the cache`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 8)
        _ = try self.writeEvent(env: env, day: day, path: "project/session.jsonl", id: "first", input: 10)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        var options = self.options(env: env, calendar: utc)
        _ = self.load(day: day, options: options)
        var shifted = Calendar(identifier: .gregorian)
        shifted.timeZone = try #require(TimeZone(secondsFromGMT: 3600))
        options.calendar = shifted

        let (report, metrics) = self.recordedLoad(day: day, options: options)

        #expect(report.summary?.totalInputTokens == 10)
        #expect(metrics.cacheDecodes == 1)
        #expect(metrics.transcriptParses == 1)
        #expect(metrics.cacheEncodes == 1)
    }

    @Test
    func `cancellation preserves disk and the prior memo`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 9)
        _ = try self.writeEvent(env: env, day: day, path: "project/session.jsonl", id: "first", input: 10)
        var options = self.options(env: env)
        _ = self.load(day: day, options: options)
        let cacheURL = self.cacheURL(env: env)
        let diskBefore = try Data(contentsOf: cacheURL)
        let memoURL = CostUsageClaudeReportMemo.reportMemoFileURL(cacheFileURL: cacheURL)
        let memoBefore = try Data(contentsOf: memoURL)
        let stampBefore = CostUsageClaudeFileStamp.read(at: cacheURL)
        options.forceRescan = true
        var checks = 0

        #expect(throws: CancellationError.self) {
            _ = try CostUsageScanner.loadDailyReportCancellable(
                provider: .claude,
                since: day,
                until: day,
                now: day.addingTimeInterval(1),
                options: options,
                checkCancellation: {
                    checks += 1
                    if checks == 4 {
                        throw CancellationError()
                    }
                })
        }
        #expect(try Data(contentsOf: cacheURL) == diskBefore)
        #expect(try Data(contentsOf: memoURL) == memoBefore)
        #expect(CostUsageClaudeFileStamp.read(at: cacheURL) == stampBefore)

        options.forceRescan = false
        let (_, metrics) = self.recordedLoad(day: day, options: options)
        #expect(metrics == CostUsageScanner.ClaudeScanWorkMetrics())
    }

    @Test
    func `persisted report retains token mix coverage and service tier details`() throws {
        let json = """
        {"type":"codexbar-claude-report-memo","data":[{"date":"2026-07-01",
        "inputTokens":1,"outputTokens":2,"cacheReadTokens":3,
        "cacheCreationTokens":4,"reasoningTokens":5,"totalTokens":15,"requestCount":4,"costUSD":0.5,
        "modelsUsed":["fixture-model"],"unpricedRequestCount":1,"pricedRequestCount":1,
        "unmeteredRequestCount":1,"estimatedRequestCount":1,"modelBreakdowns":[{"modelName":"fixture-model",
        "costUSD":0.5,"totalTokens":15,"requestCount":4,"inputTokens":1,"outputTokens":2,"cacheReadTokens":3,
        "cacheCreationTokens":4,"reasoningTokens":5,"standardCostUSD":0.2,"priorityCostUSD":0.3,
        "standardTokens":6,"priorityTokens":9}]}],"summary":{"totalInputTokens":1,"totalOutputTokens":2,
        "cacheReadTokens":3,"cacheCreationTokens":4,"reasoningTokens":5,"totalTokens":15,"totalCostUSD":0.5}}
        """
        let report = try JSONDecoder().decode(CostUsageDailyReport.self, from: Data(json.utf8))
        let persisted = try JSONEncoder().encode(report)
        let reloaded = try JSONDecoder().decode(CostUsageDailyReport.self, from: persisted)
        #expect(reloaded.data == report.data)
        #expect(reloaded.summary == report.summary)
    }

    @Test(arguments: ["negative", "same-day-overflow", "cross-day-overflow", "absent", "zero", "positive"])
    func `persisted exclusion counts are validated before report aggregation`(fixture: String) throws {
        let env = try CostUsageTestEnvironment()
        defer {
            CostUsageScanner.evictClaudeReportMemoForTesting(provider: .claude, cacheRoot: env.cacheRoot)
            env.cleanup()
        }
        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 1)
        let source = try self.writeEvent(env: env, day: day, path: "project/session.jsonl", id: "first", input: 10)
        let sourceData = try Data(contentsOf: source)
        let sourceStamp = CostUsageClaudeFileStamp.read(at: source)
        let options = self.options(env: env)
        let original = self.load(day: day, options: options)
        let memoURL = CostUsageClaudeReportMemo.reportMemoFileURL(cacheFileURL: self.cacheURL(env: env))
        var memo = try claudeMemoObjectForTesting(at: memoURL)
        var report = try #require(memo["report"] as? [String: Any])
        var days = try #require(report["data"] as? [[String: Any]])
        var models = try #require(days[0]["modelBreakdowns"] as? [[String: Any]])
        switch fixture {
        case "negative": models[0]["incompleteRequestCount"] = -1
        case "same-day-overflow":
            models[0]["incompleteRequestCount"] = Int.max
            models.append(["modelName": "fixture-other", "incompleteRequestCount": 1])
        case "cross-day-overflow":
            models[0]["incompleteRequestCount"] = Int.max
            days.append(["date": "2026-06-30", "modelBreakdowns": [
                ["modelName": "fixture-other", "incompleteRequestCount": 1],
            ]])
        case "zero": models[0]["incompleteRequestCount"] = 0
        case "positive": models[0]["incompleteRequestCount"] = 3
        default: break
        }
        days[0]["modelBreakdowns"] = models
        report["data"] = days
        memo["report"] = report
        try JSONSerialization.data(withJSONObject: memo).write(to: memoURL)
        CostUsageScanner.evictClaudeReportMemoForTesting(provider: .claude, cacheRoot: env.cacheRoot)
        CostUsageClaudeCacheIO.evictArtifactMemoForTesting(at: self.cacheURL(env: env))
        let (loaded, work) = self.recordedLoad(day: day, options: options)
        let valid = ["absent", "zero", "positive"].contains(fixture)
        if valid {
            #expect(loaded.data.first?.incompleteRequestCount == (fixture == "positive" ? 3 : 0))
            #expect(work == CostUsageScanner.ClaudeScanWorkMetrics())
        } else {
            #expect(loaded.data == original.data)
            #expect(loaded.summary == original.summary)
            #expect(work.cacheDecodes == 1)
            #expect(work.transcriptParses == 0)
            CostUsageScanner.evictClaudeReportMemoForTesting(provider: .claude, cacheRoot: env.cacheRoot)
            let (cold, coldWork) = self.recordedLoad(day: day, options: options)
            #expect(cold.data == original.data)
            #expect(coldWork == CostUsageScanner.ClaudeScanWorkMetrics())
        }
        #expect(try Data(contentsOf: source) == sourceData)
        #expect(CostUsageClaudeFileStamp.read(at: source) == sourceStamp)
    }

    // MARK: A process that scans for hours

    @Test(arguments: [false, true])
    func `a process that keeps its rows does not decode the artifact again for the next scan`(retains: Bool) throws {
        try CostUsageClaudeFragments.$shared.withValue(CostUsageClaudeFragments(retainsDecodedValues: retains)) {
            let env = try CostUsageTestEnvironment()
            defer { env.cleanup() }
            let day = try env.makeLocalNoon(year: 2026, month: 7, day: 1)
            _ = try self.writeEvent(env: env, day: day, path: "project/first.jsonl", id: "first", input: 10)
            let options = self.options(env: env)
            _ = self.load(day: day, options: options)
            // A new transcript: the scan must take the artifact up again to add it.
            _ = try self.writeEvent(env: env, day: day, path: "project/second.jsonl", id: "second", input: 20)
            let (next, work) = self.recordedLoad(day: day, options: options)
            #expect(work.cacheDecodes == (retains ? 0 : 1))
            #expect(work.transcriptParses == 1)
            #expect(next.summary?.totalInputTokens == 30)
            var forced = options
            forced.forceRescan = true
            let oracle = self.load(day: day, options: forced)
            #expect(next.data == oracle.data)
            #expect(next.summary == oracle.summary)
        }
    }

    @Test
    func `memos held back between writes are written before the process exits`() throws {
        let memo = CostUsageClaudeReportMemo()
        memo.setPersistInterval(3600)
        try CostUsageClaudeReportMemo.$shared.withValue(memo) {
            let env = try CostUsageTestEnvironment()
            defer { env.cleanup() }
            let day = try env.makeLocalNoon(year: 2026, month: 7, day: 1)
            _ = try self.writeEvent(env: env, day: day, path: "project/first.jsonl", id: "first", input: 10)
            let options = self.options(env: env)
            _ = self.load(day: day, options: options)
            #expect(!memo.hasUnwritten)
            _ = try self.writeEvent(env: env, day: day, path: "project/second.jsonl", id: "second", input: 20)
            let latest = self.load(day: day, options: options)
            // The second report is in memory only: its file still describes the artifact before this scan.
            #expect(memo.hasUnwritten)
            #expect(memo.persistUnwritten() == 1)
            #expect(!memo.hasUnwritten)
            #expect(memo.persistUnwritten() == 0)
            // A new process finds the memo current with its artifact and does no work at all.
            CostUsageScanner.evictClaudeReportMemoForTesting(provider: .claude, cacheRoot: env.cacheRoot)
            let (restarted, work) = self.recordedLoad(day: day, options: options)
            #expect(restarted.data == latest.data)
            #expect(restarted.summary == latest.summary)
            #expect(work == CostUsageScanner.ClaudeScanWorkMetrics())
        }
    }

    @Test
    func `rows decoded for a second artifact take their strings from the first`() throws {
        func row(message: String, request: String?, session: String) -> CostUsageScanner.ClaudeUsageRow {
            CostUsageScanner.ClaudeUsageRow(
                dayKey: "2026-07-01",
                model: "claude-sonnet-4-20250514",
                sessionId: session,
                messageId: message,
                requestId: request,
                timestampUnixMs: 1,
                isSidechain: false,
                pathRole: .parent,
                input: 1,
                cacheRead: 2,
                cacheCreate: 3,
                cacheCreate1h: nil,
                output: 4,
                costNanos: 5,
                costPriced: true,
                isIncomplete: nil,
                organizationID: nil)
        }
        /// A string with storage of its own, as a separate decode produces.
        func fresh(_ text: String) -> String { String(bytes: Array(text.utf8), encoding: .utf8) ?? text }
        func address(_ text: String?) -> UnsafeRawPointer? {
            var text = text ?? ""
            return text.withUTF8 { UnsafeRawPointer($0.baseAddress) }
        }
        let message = "msg_01AbCdEfGhIjKlMnOpQrStUvWx"
        let request = "req_011CabcdefghijklmnopqrstuV"
        let session = "0f8fad5b-d9cb-469f-a165-70867728950e"
        let donorRow = row(message: fresh(message), request: fresh(request), session: fresh(session))
        let encoder = JSONEncoder()
        var usage = CostUsageFileUsage(
            mtimeUnixMs: 1, size: 1, days: [:], parsedBytes: 1, codexCostCacheComplete: true, claudeRows: [donorRow])
        let donorFile = try CostUsageClaudeCache.File(usage: usage, sourceID: nil, sourceKey: nil, encoder: encoder)
        usage.claudeRows = []
        let emptyFile = try CostUsageClaudeCache.File(usage: usage, sourceID: nil, sourceKey: nil, encoder: encoder)
        let donors = CostUsageClaudeRowDonors([["/empty": emptyFile], ["/a": donorFile, "/empty": emptyFile]])

        let decoded = [
            row(message: fresh(message), request: fresh(request), session: fresh(session)),
            row(message: fresh("msg_01ZZZZZZZZZZZZZZZZZZZZZZZZ"), request: nil, session: "short"),
        ]
        #expect(address(decoded[0].messageId) != address(donorRow.messageId))
        let shared = donors.sharing(decoded, path: "/a")
        #expect(shared == decoded)
        #expect(address(shared[0].messageId) == address(donorRow.messageId))
        #expect(address(shared[0].requestId) == address(donorRow.requestId))
        #expect(address(shared[0].sessionId) == address(donorRow.sessionId))
        // A request the donor does not have keeps its own string; a transcript it does not have is left alone.
        #expect(address(shared[1].messageId) == address(decoded[1].messageId))
        #expect(address(donors.sharing(decoded, path: "/missing")[0].messageId) == address(decoded[0].messageId))
        #expect(address(donors.sharing(decoded, path: "/empty")[0].messageId) == address(decoded[0].messageId))
        // Canonically equal spellings are different bytes, and an artifact's bytes stay exactly its own.
        let composed = "session-caf\u{E9}-0123456789abcdef"
        let decomposed = "session-cafe\u{301}-0123456789abcdef"
        let accented = try CostUsageClaudeRowDonors(
            [["/a": CostUsageClaudeCache.File(
                usage: CostUsageFileUsage(
                    mtimeUnixMs: 1,
                    size: 1,
                    days: [:],
                    parsedBytes: 1,
                    codexCostCacheComplete: true,
                    claudeRows: [row(message: fresh(message), request: nil, session: composed)]),
                sourceID: nil,
                sourceKey: nil,
                encoder: encoder)]])
        let kept = accented.sharing([row(message: fresh(message), request: nil, session: decomposed)], path: "/a")
        #expect(kept[0].sessionId.map { Array($0.utf8) } == Array(decomposed.utf8))
    }

    private func options(
        env: CostUsageTestEnvironment,
        calendar: Calendar = .current) -> CostUsageScanner.Options
    {
        var options = CostUsageScanner.Options(
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot,
            calendar: calendar)
        options.refreshMinIntervalSeconds = 0
        return options
    }

    private func load(day: Date, options: CostUsageScanner.Options) -> CostUsageDailyReport {
        CostUsageScanner.loadDailyReport(
            provider: .claude,
            since: day,
            until: day,
            now: day,
            options: options)
    }

    private func recordedLoad(
        day: Date,
        options: CostUsageScanner.Options) -> (CostUsageDailyReport, CostUsageScanner.ClaudeScanWorkMetrics)
    {
        let recorder = CostUsageScanner.ClaudeScanWorkRecorder()
        let report = CostUsageScanner.withClaudeScanWorkRecorderForTesting(recorder) {
            self.load(day: day, options: options)
        }
        return (report, recorder.snapshot())
    }

    private func writeEvent(
        env: CostUsageTestEnvironment,
        day: Date,
        path: String,
        id: String,
        input: Int,
        model: String = "claude-sonnet-4-20250514") throws -> URL
    {
        try env.writeClaudeProjectFile(
            relativePath: path,
            contents: env.jsonl([self.event(env: env, day: day, id: id, input: input, model: model)]))
    }

    private func event(
        env: CostUsageTestEnvironment,
        day: Date,
        id: String,
        input: Int,
        model: String = "claude-sonnet-4-20250514") -> [String: Any]
    {
        [
            "type": "assistant",
            "timestamp": env.isoString(for: day),
            "sessionId": "session-\(id)",
            "requestId": "request-\(id)",
            "message": [
                "id": "message-\(id)",
                "model": model,
                "usage": [
                    "input_tokens": input,
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": 0,
                    "output_tokens": 0,
                ],
            ],
        ]
    }

    private func catalog(model: String, inputRate: Double) throws -> ModelsDevCatalog {
        try JSONDecoder().decode(ModelsDevCatalog.self, from: Data("""
        {
          "anthropic": {
            "id": "anthropic",
            "models": {
              "\(model)": {
                "id": "\(model)",
                "cost": { "input": \(inputRate), "output": 1 }
              }
            }
          }
        }
        """.utf8))
    }

    private func cacheURL(env: CostUsageTestEnvironment) -> URL {
        CostUsageClaudeCacheIO.cacheFileURL(provider: .claude, cacheRoot: env.cacheRoot)
    }
}
