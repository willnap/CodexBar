import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct NativeOrbitKimiLocalUsageTests {
    @Test func `fixture usage survives disabled cost reporting and follows configuration changes`() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = home.appendingPathComponent(
            ".kimi-code/sessions",
            isDirectory: true)
        let wire = root.appendingPathComponent(
            "project/session/agents/main/wire.jsonl")
        try FileManager.default.createDirectory(
            at: wire.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: home)
        }
        try Data("""
        {"type":"usage.record","time":1799999900125,"usageScope":"turn",\
        "usage":{"inputOther":10,"output":7,"inputCacheRead":31,"inputCacheCreation":3}}
        """.utf8).write(to: wire)
        // The fixture file is written on the same clock as its records.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_800_000_000)],
            ofItemAtPath: wire.path)
        let settings = testSettingsStore(
            suiteName: "NativeKimiLocalUsage",
            userDefaults: InMemoryUserDefaults(),
            nativeDesignEnabled: true)
        settings.costUsageEnabled = false
        settings.costUsageBucketTimeZoneIdentifier = "UTC"
        enableTestProviders(
            [.kimi, .codex],
            settings: settings)
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            planUtilizationHistoryStore: .init(
                directoryURL: home.appendingPathComponent("history")),
            startupBehavior: .testing,
            environmentBase: ["HOME": home.path])
        store._cancelPlanUtilizationHistoryLoadForTesting()
        await store.refreshNativeKimiLocalUsage(
            sessionsRoot: root,
            now: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(store.nativeOrbitKimiLocalUsage()?.snapshot.last30DaysTokens == 51)
        #expect(store.nativeOrbitAmbientLocalUsage(for: .codex) == nil)
        let publication = store.nativeKimiLocalUsageReport
        settings.kimiRegion = .international
        #expect(store.nativeOrbitKimiLocalUsage() == nil)
        #expect(store.nativeKimiLocalUsageReport?.snapshot == publication?.snapshot)
        settings.kimiRegion = .china
        #expect(store.nativeOrbitKimiLocalUsage()?.scope == .localMachine)
    }

    @Test func `only matching ambient Kimi configuration can consume a local machine report`() throws {
        let configuration = self.configuration()
        let snapshot = NativeKimiLocalUsageParser.snapshot(
            data: Data("""
            {"type":"usage.record","time":1799999900125,"usageScope":"turn",\
            "usage":{"inputOther":10,"output":7,"inputCacheRead":31,"inputCacheCreation":3}}
            """.utf8),
            now: Date(timeIntervalSince1970: 1_800_000_000),
            bucketTimeZoneIdentifier: "UTC")
        let publication = NativeKimiLocalUsagePublication(
            configuration: configuration,
            snapshot: snapshot)
        let local = try #require(UsageStore.nativeOrbitKimiLocalUsage(
            publication: publication,
            configuration: configuration))
        #expect(local.scope == .localMachine)
        #expect(local.snapshot.last30DaysTokens == 51)
        #expect(local.bucketTimeZoneIdentifier == "GMT")
        let mismatches = [
            self.configuration(provider: .codex),
            self.configuration(root: "/tmp/other-fixture"),
            self.configuration(zone: "Europe/London"),
            self.configuration(source: .web),
            self.configuration(region: .international),
            self.configuration(account: UUID()),
        ]
        for mismatch in mismatches {
            #expect(UsageStore.nativeOrbitKimiLocalUsage(
                publication: publication,
                configuration: mismatch) == nil)
        }
        let named = self.configuration(account: UUID())
        #expect(UsageStore.nativeOrbitKimiLocalUsage(
            publication: .init(
                configuration: named,
                snapshot: snapshot),
            configuration: named) == nil)
        #expect(UsageStore.nativeOrbitKimiLocalUsage(
            publication: nil,
            configuration: configuration) == nil)
    }

    @Test func `historical token inspections retain event time instead of later day totals`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = NativeKimiLocalUsageParser.snapshot(
            data: Data("""
            {"type":"usage.record","time":1799999900125,"usageScope":"turn",\
            "usage":{"inputOther":10,"output":7,"inputCacheRead":31,"inputCacheCreation":3}}
            {"type":"usage.record","time":1799999950625,"usageScope":"turn",\
            "usage":{"inputOther":20,"output":7,"inputCacheRead":31,"inputCacheCreation":3}}
            """.utf8),
            now: now,
            bucketTimeZoneIdentifier: "UTC")
        let metrics = NativeOrbitAccountMetrics.make(
            provider: .kimi,
            snapshot: nil,
            usage: nil,
            now: now,
            localUsage: NativeOrbitLocalUsage(
                snapshot: snapshot,
                scope: .localMachine,
                bucketTimeZoneIdentifier: "UTC"))
        let inspected = metrics.summary(
            days: 1,
            now: Date(timeIntervalSince1970: 1_799_999_925))
        #expect(inspected.tokens == 51)
        #expect(inspected.isPartial)
        #expect(inspected.usageScope == .localMachine)
        #expect(inspected.cost == nil)
        #expect(metrics.summary(
            days: 1,
            now: now).tokens == 112)
    }

    private func configuration(
        provider: UsageProvider = .kimi,
        root: String = "/tmp/kimi-fixture",
        zone: String = "GMT",
        source: ProviderSourceMode = .auto,
        region: KimiRegion = .china,
        account: UUID? = nil) -> NativeKimiLocalUsageConfiguration
    { .init(
        provider: provider,
        sessionsRootPath: root,
        bucketTimeZoneIdentifier: zone,
        sourceMode: source,
        region: region,
        selectedAccountID: account)
    }
}
