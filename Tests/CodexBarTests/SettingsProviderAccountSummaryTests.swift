import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct SettingsProviderAccountSummaryTests {
    @Test func `native Codex sidebar identifies the actual login while legacy keeps its monitoring selection`() {
        let store = self.store()
        let settings = store.settings
        settings.codexUsageDataSource = .oauth
        let monitored = CodexVisibleAccount(
            id: "monitored",
            email: "monitored@example.test",
            storedAccountID: nil,
            selectionSource: settings.codexActiveSource,
            isActive: true,
            isLive: false,
            canReauthenticate: false,
            canRemove: false)
        let live = CodexVisibleAccount(
            id: "live",
            email: "live@example.test",
            storedAccountID: nil,
            selectionSource: .liveSystem,
            isActive: false,
            isLive: true,
            canReauthenticate: false,
            canRemove: false)
        settings.cachedCodexAccountMenuProjection = CachedCodexAccountMenuProjection(
            activeSource: settings.codexActiveSource,
            loadedAt: Date(),
            projection: CodexVisibleAccountProjection(
                visibleAccounts: [monitored, live],
                activeVisibleAccountID: monitored.id,
                liveVisibleAccountID: live.id,
                hasUnreadableAddedAccountStore: false))
        #expect(store.settingsAccountLabel(for: .codex) == live.displayName)
        settings.nativeGaugeStyle = .legacy
        #expect(store.settingsAccountLabel(for: .codex) == monitored.displayName)
        #expect(store.accountInfoCache.isEmpty)
    }

    @Test func `Codex search includes the displayed workspace and drops pending identity`() {
        let store = self.store()
        let settings = store.settings
        settings.codexUsageDataSource = .oauth
        let account = CodexVisibleAccount(
            id: "fixture-account",
            email: "jade@example.test",
            workspaceLabel: "Acme",
            storedAccountID: nil,
            selectionSource: settings.codexActiveSource,
            isActive: true,
            isLive: true,
            canReauthenticate: false,
            canRemove: false)
        settings.cachedCodexAccountMenuProjection = CachedCodexAccountMenuProjection(
            activeSource: settings.codexActiveSource,
            loadedAt: Date(),
            projection: CodexVisibleAccountProjection(
                visibleAccounts: [account],
                activeVisibleAccountID: account.id,
                liveVisibleAccountID: account.id,
                hasUnreadableAddedAccountStore: false))
        #expect(store.settingsAccountLabel(for: .codex) == account.displayName)
        #expect(SettingsSearchIndex.matches(query: "Acme", text: store.settingsAccountLabel(for: .codex) ?? ""))
        settings.cachedCodexAccountMenuProjection = nil
        #expect(store.settingsAccountLabel(for: .codex) == nil)
        #expect(store.accountInfoCache.isEmpty)
    }

    @Test func `selected saved account label is searchable without usage or email`() {
        let store = self.store()
        store.settings.addTokenAccount(provider: .kimi, label: "Work", token: "fixture-token")
        #expect(store.settingsAccountLabel(for: .kimi) == "Work")
        #expect(SettingsSearchIndex.matches(
            query: "kimi work", text: "Kimi \(store.settingsAccountLabel(for: .kimi) ?? "")"))
    }

    @Test func `settings identity does not populate the live account cache`() {
        let store = self.store()
        store.settings.codexUsageDataSource = .pat
        #expect(store.accountInfoCache.isEmpty)
        _ = store.settingsAccountLabel(for: .codex)
        #expect(store.accountInfoCache.isEmpty)
    }

    @Test func `private and disabled account labels are omitted`() {
        let store = self.store()
        store.settings.addTokenAccount(provider: .kimi, label: "Work", token: "fixture-token")
        store.settings.hidePersonalInfo = true
        #expect(store.settingsAccountLabel(for: .kimi) == nil)
        store.settings.hidePersonalInfo = false
        enableTestProviders([.codex], settings: store.settings)
        #expect(store.settingsAccountLabel(for: .kimi) == nil)
    }

    private func store() -> UsageStore {
        let settings = testSettingsStore(
            suiteName: "SettingsAccountSummary", userDefaults: InMemoryUserDefaults(), nativeDesignEnabled: true)
        enableTestProviders([.codex, .kimi], settings: settings)
        return UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
    }
}
