import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct NativeOrbitClaudeAmbientUsageTests {
    @Test func `ambient usage survives disabled cost reporting and rejects changed configuration`() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent(".claude/projects")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true)
        try Data("""
        {"type":"assistant","timestamp":"2026-10-12T10:30:00Z","requestId":"fixture-request",\
        "message":{"id":"fixture-message","model":"claude-sonnet-4-5-20250929",\
        "usage":{"input_tokens":100,"output_tokens":10}}}
        """.utf8).write(to: root.appendingPathComponent("session.jsonl"))
        let settings = testSettingsStore(
            suiteName: "NativeClaudeAmbientUsage",
            userDefaults: InMemoryUserDefaults(),
            nativeDesignEnabled: true)
        settings.costUsageEnabled = false
        settings.costUsageBucketTimeZoneIdentifier = "UTC"
        enableTestProviders(
            [.claude],
            settings: settings)
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            planUtilizationHistoryStore: .init(directoryURL: home.appendingPathComponent("history")),
            startupBehavior: .testing,
            environmentBase: ["HOME": home.path])
        store._cancelPlanUtilizationHistoryLoadForTesting()
        let cacheRoot = home.appendingPathComponent("cache")
        let fetcher = CostUsageFetcher(scannerOptions: CostUsageScanner.Options(
            claudeProjectsRoots: [root],
            cacheRoot: cacheRoot,
            calendar: settings.costUsageBucketCalendar))
        try await store.refreshNativeClaudeAmbientUsage(
            fetcher: fetcher,
            now: #require(ISO8601DateParser.parse("2026-10-12T11:00:00Z")))
        let local = try #require(store.nativeOrbitClaudeAmbientUsage())
        #expect(local.snapshot.last30DaysTokens == 110)
        #expect(local.scope == .localMachine)
        #expect(store.nativeOrbitClaudeLocalUsage()?.snapshot.last30DaysTokens == 110)
        settings.costUsageBucketTimeZoneIdentifier = "Europe/London"
        #expect(store.nativeOrbitClaudeAmbientUsage() == nil)
        settings.costUsageBucketTimeZoneIdentifier = "UTC"
        settings.claudeUsageDataSource = .web
        #expect(store.nativeOrbitClaudeAmbientUsage() == nil)
    }
}
