import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct NativeOrbitCachedUsageReportTests {
    private let now = Date(timeIntervalSince1970: 1_786_363_200)

    @Test func `ambient row reads the published local store report as machine scoped periods`() throws {
        let store = self.store(.antigravity)
        store.installCachedTokenSnapshot(self.report(), for: .antigravity)
        let row = try #require(store.nativeOrbitAccounts(for: .antigravity).first)
        #expect(row.metrics.usageScope == .localMachine)
        let calendar = Self.utc
        let day = row.metrics.summary(days: 1, now: self.now, calendar: calendar)
        #expect(day.tokens == 100)
        #expect(day.cost == 1)
        #expect(day.usageScope == .localMachine)
        let week = row.metrics.summary(days: 7, now: self.now, calendar: calendar)
        #expect(week.tokens == 300)
        #expect(week.cost == 3)
        let month = row.metrics.summary(days: 30, now: self.now, calendar: calendar)
        #expect(month.tokens == 700)
        #expect(month.cost == 7)
        #expect(month.isPartial)
    }

    @Test func `historical inspection keeps completed days from the published report`() throws {
        let store = self.store(.antigravity)
        store.installCachedTokenSnapshot(self.report(), for: .antigravity)
        let row = try #require(store.nativeOrbitAccounts(for: .antigravity).first)
        let inspected = self.now.addingTimeInterval(-86400)
        let historical = row.metrics.at(inspected, observedAt: row.updatedAt)
            .summary(days: 7, now: inspected, calendar: Self.utc)
        #expect(historical.tokens == 200)
        #expect(historical.cost == 2)
        #expect(!historical.isPartial)
    }

    @Test func `billing report keeps account scope and joins live spend`() throws {
        let store = self.store(.bedrock)
        store.installCachedTokenSnapshot(self.report(), for: .bedrock)
        let row = try #require(store.nativeOrbitAccounts(for: .bedrock).first)
        #expect(row.metrics.usageScope == .account)
        #expect(row.metrics.summary(days: 7, now: self.now, calendar: Self.utc).cost == 3)
    }

    @Test func `Cursor scope follows the report credential provenance`() throws {
        let dashboard = try #require(UsageStore.nativeOrbitCachedUsage(
            provider: .cursor,
            report: self.report(credentialScopeFingerprint: "fixture-scope"),
            bucketTimeZoneIdentifier: "UTC"))
        #expect(dashboard.scope == .account)
        let exported = try #require(UsageStore.nativeOrbitCachedUsage(
            provider: .cursor,
            report: self.report(),
            bucketTimeZoneIdentifier: "UTC"))
        #expect(exported.scope == .localMachine)
    }

    @Test func `only scan backed providers without their own adapters adopt the cached report`() {
        for provider in [UsageProvider.antigravity, .bedrock, .cursor, .muse, .pi, .vertexai] {
            #expect(UsageStore.nativeOrbitUsesCachedUsageReport(provider))
        }
        for provider in [UsageProvider.claude, .codex, .kimi, .openrouter, .mistral, .openai, .xai, .grok, .zai] {
            #expect(!UsageStore.nativeOrbitUsesCachedUsageReport(provider))
            #expect(UsageStore.nativeOrbitCachedUsage(
                provider: provider, report: self.report(), bucketTimeZoneIdentifier: "UTC") == nil)
        }
    }

    @Test func `disabled cost usage and selected saved accounts never adopt the ambient report`() throws {
        let store = self.store(.antigravity)
        store.installCachedTokenSnapshot(self.report(), for: .antigravity)
        #expect(store.nativeOrbitCachedUsageReport(for: .antigravity) != nil)
        store.settings.addTokenAccount(provider: .antigravity, label: "Saved", token: "fixture-oauth")
        let account = try #require(store.settings.tokenAccounts(for: .antigravity).first)
        store.selectNativeTokenAccount(account.id, for: .antigravity)
        store.installCachedTokenSnapshot(self.report(), for: .antigravity)
        #expect(store.nativeOrbitCachedUsageReport(for: .antigravity) == nil)
        for row in store.nativeOrbitAccounts(for: .antigravity) {
            #expect(row.metrics.usage == nil)
            #expect(row.metrics.localCostUsage == nil)
        }
        store.selectNativeTokenAccount(nil, for: .antigravity)
        store.installCachedTokenSnapshot(self.report(), for: .antigravity)
        #expect(store.nativeOrbitCachedUsageReport(for: .antigravity) != nil)
        store.settings.costUsageEnabled = false
        #expect(store.nativeOrbitCachedUsageReport(for: .antigravity) == nil)
    }

    @Test func `machine local live scans stay labeled as this Mac and never become account receipts`() throws {
        for provider in [UsageProvider.mimo, .grok] {
            let store = self.store(provider)
            let report = self.report()
            let snapshot = UsageSnapshot(primary: nil, secondary: nil, costUsage: report, updatedAt: self.now)
            store.snapshots[provider.instanceID] = snapshot
            let row = try #require(store.nativeOrbitAccounts(for: provider).first)
            #expect(row.metrics.usageScope == .localMachine)
            let day = row.metrics.summary(days: 1, now: self.now, calendar: Self.utc)
            #expect(day.tokens == 100)
            #expect(day.usageScope == .localMachine)
            let samples = UsageStore.nativeOrbitMetricSamples(provider: provider, snapshot: snapshot)
            #expect(!samples.contains { $0.name.rawValue == "nativeMetric:usage" })
        }
        #expect(!UsageStore.nativeOrbitSnapshotReportIsMachineLocal(.openrouter))
    }

    private static var utc: Calendar {
        CostUsageBucketTimeZone.calendar(identifier: "UTC")
    }

    private func report(credentialScopeFingerprint: String? = nil) -> CostUsageTokenSnapshot {
        let entries = [(0, 100, 1.0), (3, 200, 2.0), (10, 400, 4.0)].map { offset, tokens, cost in
            CostUsageDailyReport.Entry(
                date: CostUsageLocalDay.key(
                    from: self.now.addingTimeInterval(-Double(offset) * 86400), calendar: Self.utc),
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: tokens,
                requestCount: nil,
                costUSD: cost,
                modelsUsed: nil,
                modelBreakdowns: nil)
        }
        return CostUsageTokenSnapshot(
            sessionTokens: 100,
            sessionCostUSD: 1,
            last30DaysTokens: 700,
            last30DaysCostUSD: 7,
            bucketTimeZoneIdentifier: "UTC",
            costProvenance: .vendorMetered,
            credentialScopeFingerprint: credentialScopeFingerprint,
            daily: entries,
            updatedAt: self.now)
    }

    private func store(_ provider: UsageProvider) -> UsageStore {
        let settings = testSettingsStore(
            suiteName: "NativeOrbitCachedUsageReport", userDefaults: InMemoryUserDefaults(), nativeDesignEnabled: true)
        enableTestProviders([provider], settings: settings)
        settings.costUsageEnabled = true
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        store._cancelPlanUtilizationHistoryLoadForTesting()
        return store
    }
}
