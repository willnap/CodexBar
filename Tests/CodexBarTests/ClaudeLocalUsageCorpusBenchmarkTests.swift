import Foundation
import Testing
@testable import CodexBarCore

/// Opt-in measurement against a real transcript corpus. Prints aggregate timings only.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CODEXBAR_CLAUDE_CORPUS_BENCH"] == "1"))
struct ClaudeLocalUsageCorpusBenchmarkTests {
    @Test
    func `transcript parse throughput on a sampled corpus`() throws {
        let environment = ProcessInfo.processInfo.environment
        let root = try #require(environment["CODEXBAR_CLAUDE_CORPUS_ROOT"].map { URL(fileURLWithPath: $0) })
        let stride = Int(environment["CODEXBAR_CLAUDE_CORPUS_STRIDE"] ?? "") ?? 8
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var files: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            if url.pathExtension == "jsonl" { files.append(url) }
        }
        files.sort { $0.path < $1.path }
        let sample = files.enumerated().filter { $0.offset.isMultiple(of: stride) }.map(\.element)
        let now = Date()
        let range = CostUsageScanner.CostUsageDayRange(
            since: Date(timeIntervalSince1970: 0), until: now, calendar: .current)
        let resolver = CostUsagePricing.ClaudeResolver(now: now, cacheRoot: nil)
        var bytes: Int64 = 0
        var rows = 0
        var attributed = 0
        let started = ContinuousClock.now
        for url in sample {
            let parsed = try CostUsageScanner.parseClaudeFileCancellable(
                fileURL: url,
                range: range,
                providerFilter: .excludeVertexAI,
                pricingResolver: resolver)
            bytes += parsed.parsedBytes
            rows += parsed.rows.count
            attributed += parsed.rows.count(where: { $0.organizationID != nil })
        }
        let elapsed = ContinuousClock.now - started
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        print("[claude-corpus] files=\(sample.count)/\(files.count) bytes=\(bytes) rows=\(rows) "
            + "attributed=\(attributed) seconds=\(seconds) MBps=\(Double(bytes) / 1_000_000 / max(seconds, 0.001))")
    }

    /// Cold build, unchanged refresh, and per-organization totals over real roots into a scratch cache.
    @Test
    func `organization projection over the real corpus`() async throws {
        let environment = ProcessInfo.processInfo.environment
        let roots = try #require(environment["CODEXBAR_CLAUDE_CORPUS_ROOTS"])
            .split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        let cacheRoot = try #require(environment["CODEXBAR_CLAUDE_CORPUS_CACHE"].map { URL(fileURLWithPath: $0) })
        let organizations = (environment["CODEXBAR_CLAUDE_CORPUS_ORGS"] ?? "").split(separator: ",").map(String.init)
        let zone = environment["CODEXBAR_CLAUDE_CORPUS_TZ"] ?? "Europe/London"
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: zone))
        let now = environment["CODEXBAR_CLAUDE_CORPUS_NOW"].flatMap(Double.init)
            .map { Date(timeIntervalSince1970: $0) } ?? Date()
        let fetcher = CostUsageFetcher(scannerOptions: CostUsageScanner.Options(
            claudeProjectsRoots: roots, cacheRoot: cacheRoot, calendar: calendar))
        let reader = ClaudeOrganizationUsageReader()
        for pass in ["cold", "warm"] {
            let started = ContinuousClock.now
            let result = try await reader.read(
                organizationIDs: organizations,
                fetcher: fetcher,
                now: now,
                historyDays: CostReportingPeriod.allTime.days(now: now),
                calendar: calendar,
                archiveRoot: nil)
            let elapsed = ContinuousClock.now - started
            let machineTokens = result.machine?.last30DaysTokens ?? -1
            print("[claude-projection] pass=\(pass) elapsed=\(elapsed) machineTokens=\(machineTokens)")
            for (organization, report) in result.organizations.sorted(by: { $0.key < $1.key }) {
                for days in [1, 7, 30] {
                    let window = CostReportingPeriod.rolling(days: days)
                        .entries(report.daily, now: now, calendar: calendar)
                    let tokens = window.compactMap(\.totalTokens).reduce(0, +)
                    let cost = window.compactMap(\.costUSD).reduce(0, +)
                    let requests = window.compactMap(\.requestCount).reduce(0, +)
                    print("[claude-projection] org=\(organization.prefix(8)) days=\(days) tokens=\(tokens) "
                        + "requests=\(requests) cost=\(cost) historyDays=\(report.historyDays) "
                        + "slices=\(report.quotaSlices.count)")
                }
            }
        }
    }
}
