import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct NativeOrbitLocalUsageRefreshPolicyTests {
    @Test(arguments: [UsageProvider.claude, .kimi])
    func `failed quota refresh still schedules local metrics with cost reporting disabled`(
        provider: UsageProvider) async
    {
        let store = self.makeStore(provider: provider)
        var scheduled: [UsageProvider] = []
        store._test_nativeLocalUsageRefreshScheduledOverride = { scheduled.append($0) }
        store._test_providerFetchOutcomeOverride = { _ in
            ProviderFetchOutcome(result: .failure(URLError(.userAuthenticationRequired)), attempts: [])
        }
        await store.refreshProvider(provider)
        #expect(store.snapshot(for: provider.instanceID) == nil)
        #expect(scheduled == [provider])
    }

    @Test
    func `authenticated Codex token history follows native design independently of money reporting`() {
        let store = self.makeStore(provider: .codex)
        #expect(store.shouldFetchNativeCodexAccountUsageHistory(isRunningTests: false))
        #expect(!store.shouldFetchNativeCodexAccountUsageHistory(isRunningTests: true))
        let legacyStore = self.makeStore(provider: .codex, nativeDesignEnabled: false)
        legacyStore.settings.costUsageEnabled = true
        #expect(!legacyStore.shouldFetchNativeCodexAccountUsageHistory(isRunningTests: false))
    }

    private func makeStore(provider: UsageProvider, nativeDesignEnabled: Bool = true) -> UsageStore {
        let settings = testSettingsStore(
            suiteName: "NativeLocalUsageRefreshPolicy",
            userDefaults: InMemoryUserDefaults(),
            nativeDesignEnabled: nativeDesignEnabled)
        settings.costUsageEnabled = false
        settings.claudeSwapEnabled = false
        settings.claudeUsageDataSource = .web
        enableTestProviders([provider], settings: settings)
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            planUtilizationHistoryStore: .init(directoryURL: home.appendingPathComponent("history")),
            startupBehavior: .testing,
            environmentBase: ["HOME": home.path])
        store._cancelPlanUtilizationHistoryLoadForTesting()
        return store
    }
}
