import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct NativeProviderSettingsOwnershipTests {
    @Test func `Claude settings uses its actual swap owner instead of an ambient reading`() throws {
        let store = self.store()
        let owner = self.account(slot: "1", used: 20)
        store.claudeSwapAccountSnapshots = [owner]
        let pane = ProvidersPane(settings: store.settings, store: store)
        let model = pane._test_menuCardModel(for: .claude)
        #expect(model.email == "owner1@example.test")
        #expect(try #require(model.metrics.first).percent == 80)
        #expect(pane._test_providerErrorDisplay(for: .claude) == nil)
        #expect(pane._test_providerSubtitle(.claude).contains(ClaudeSwapAccountProjection.sourceLabel))
        #expect(!pane._test_providerSubtitle(.claude).contains(L("last_fetch_failed")))
        let info = ProviderDetailInfoRows(
            provider: .claude, store: store, isEnabled: true, versionText: nil, model: model)
        #expect(info.sourceText == ClaudeSwapAccountProjection.sourceLabel)
        #expect(try info.updatedText == UsageFormatter.updatedString(from: #require(owner.snapshot).updatedAt))
    }

    @Test func `missing and ambiguous Claude swap owners never borrow ambient settings usage`() {
        let store = self.store()
        for accounts in [
            [self.account(slot: "1", used: 20, active: false)],
            [self.account(slot: "1", used: 20), self.account(slot: "2", used: 40)],
        ] {
            store.claudeSwapAccountSnapshots = accounts
            let pane = ProvidersPane(settings: store.settings, store: store)
            #expect(pane._test_menuCardModel(for: .claude).metrics.isEmpty)
            #expect(pane._test_menuCardModel(for: .claude).email.isEmpty)
            #expect(pane._test_providerErrorDisplay(for: .claude)?.full == L("No active account"))
            let info = ProviderDetailInfoRows(
                provider: .claude,
                store: store,
                isEnabled: true,
                versionText: nil,
                model: pane._test_menuCardModel(for: .claude))
            #expect(info.updatedText == L("Not fetched yet"))
        }
    }

    @Test func `swap settings errors and retained usage stay attached to their owner`() throws {
        let store = self.store()
        store.claudeSwapAccountSnapshots = [self.account(slot: "1", used: 20, error: "Owner unavailable")]
        let pane = ProvidersPane(settings: store.settings, store: store)
        #expect(pane._test_providerErrorDisplay(for: .claude)?.full == "Owner unavailable")
        #expect(try #require(pane._test_menuCardModel(for: .claude).metrics.first).percent == 80)
        #expect(pane._test_menuCardModel(for: .claude).lastKnownUsageText?.contains("last-known usage") == true)
        #expect(pane._test_providerSubtitle(.claude).contains(L("last_fetch_failed")))
    }

    @Test func `legacy app settings retains ambient Claude source presentation`() throws {
        let store = self.store(native: false)
        store.claudeSwapAccountSnapshots = [self.account(slot: "1", used: 20)]
        let pane = ProvidersPane(settings: store.settings, store: store)
        #expect(try #require(pane._test_menuCardModel(for: .claude).metrics.first).percent == 20)
        #expect(pane._test_providerErrorDisplay(for: .claude)?.full == "Ambient failure")
    }

    private func store(native: Bool = true) -> UsageStore {
        let settings = testSettingsStore(
            suiteName: "NativeSettingsOwnership", userDefaults: InMemoryUserDefaults(), nativeDesignEnabled: native)
        enableTestProviders([.claude], settings: settings)
        settings.claudeSwapEnabled = true
        settings.claudeSwapShowSingleAccount = true
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        store.snapshots[.claude] = UsageSnapshot(
            primary: RateWindow(usedPercent: 80, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date().addingTimeInterval(-3600))
        store._setErrorForTesting("Ambient failure", provider: .claude)
        return store
    }

    private func account(
        slot: String, used: Double, active: Bool = true, error: String? = nil) -> ProviderAccountUsageSnapshot
    {
        ProviderAccountUsageSnapshot(
            id: ProviderAccountIdentity(source: "claude-swap", opaqueID: slot),
            provider: .claude,
            displayLabel: "owner\(slot)@example.test",
            isActive: active,
            usesLastKnownUsage: error != nil,
            snapshot: UsageSnapshot(
                primary: RateWindow(usedPercent: used, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: Date()),
            error: error,
            sourceLabel: "claude-swap")
    }
}
