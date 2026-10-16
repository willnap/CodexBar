import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct NativeAccountPresentationTests {
    @Test func `Claude model scoped lane appears only when available quota is below full`() {
        let store = self.store()
        let fableID = "claude-weekly-scoped-fable"
        store.snapshots[.claude] = UsageSnapshot(
            primary: RateWindow(usedPercent: 62, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 44, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            extraRateWindows: [NamedRateWindow(
                id: fableID,
                title: "Fable only",
                window: RateWindow(
                    usedPercent: 0, windowMinutes: 10080, resetsAt: nil, resetDescription: nil))],
            updatedAt: Date())
        let defaults = store.nativeServicePresentation(for: .claude)
        #expect(defaults.model.metrics.contains { $0.id == fableID })
        #expect(defaults.gauge.resolvedWindows.count == 2)
        #expect(!defaults.gauge.resolvedWindows.contains { $0.id == fableID })
        #expect(store.nativeOrbitAccounts(for: .claude).first?.gauge.resolvedWindows.map(\.id)
            == ["secondary", "primary"])
        store.snapshots[.claude] = UsageSnapshot(
            primary: RateWindow(usedPercent: 62, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 44, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            extraRateWindows: [NamedRateWindow(id: fableID, title: "Fable only", window: RateWindow(
                usedPercent: 5, windowMinutes: 10080, resetsAt: nil, resetDescription: nil))],
            updatedAt: Date())
        let optedIn = store.nativeServicePresentation(for: .claude)
        #expect(optedIn.gauge.resolvedWindows.count == 3)
        #expect(optedIn.gauge.resolvedWindows.map(\.id) == ["secondary", fableID, "primary"])
        #expect(store.nativeOrbitAccounts(for: .claude).first?.gauge.resolvedWindows.map(\.id)
            == ["secondary", fableID, "primary"])
        #expect(defaults.iconSignature != optedIn.iconSignature)
    }

    private func store() -> UsageStore {
        let settings = testSettingsStore(
            suiteName: "NativePresentation", userDefaults: InMemoryUserDefaults())
        return UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
    }

    private func snapshot(_ percent: Double, extras: [NamedRateWindow] = []) -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(usedPercent: percent, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            extraRateWindows: extras,
            updatedAt: Date())
    }

    @Test func `automatic login keeps saved accounts selectable by stable identity`() {
        let store = self.store()
        let settings = store.settings
        settings.addTokenAccount(provider: .cursor, label: "Personal", token: "fixture-personal")
        settings.addTokenAccount(provider: .cursor, label: "Work", token: "fixture-work")
        settings.updateProviderConfig(provider: .cursor) { $0.cookieSource = .auto }
        let accounts = settings.tokenAccounts(for: .cursor)
        #expect(settings.effectiveSelectedTokenAccount(for: .cursor) == nil)
        #expect(settings.nativeTokenAccountOptions(for: .cursor).map(\.id)
            == ["automatic", accounts[0].id.uuidString, accounts[1].id.uuidString])
        store.snapshots[.cursor] = self.snapshot(91)
        store.selectNativeTokenAccount(accounts[0].id, for: .cursor)
        #expect(settings.effectiveSelectedTokenAccount(for: .cursor)?.id == accounts[0].id)
        #expect(store.snapshots[.cursor] == nil)
        store.selectNativeTokenAccount(nil, for: .cursor)
        #expect(settings.effectiveSelectedTokenAccount(for: .cursor) == nil)
        #expect(settings.nativeTokenAccountOptions(for: .cursor).count == 3)
    }

    @Test func `selecting a passive account enables its fetch source`() throws {
        let store = self.store()
        let settings = store.settings
        settings.addTokenAccount(provider: .antigravity, label: "Saved", token: "fixture-oauth")
        settings.updateProviderConfig(provider: .antigravity) { $0.source = .cli }
        let account = try #require(settings.tokenAccounts(for: .antigravity).first)
        #expect(settings.effectiveSelectedTokenAccount(for: .antigravity) == nil)
        store.selectNativeTokenAccount(account.id, for: .antigravity)
        #expect(settings.effectiveSelectedTokenAccount(for: .antigravity)?.id == account.id)
        store.selectNativeTokenAccount(nil, for: .antigravity)
        #expect(settings.effectiveSelectedTokenAccount(for: .antigravity) == nil)
    }

    @Test func `Claude switch failure stays attached to the requested account`() {
        let store = self.store()
        store.settings.claudeSwapEnabled = true
        let first = ProviderAccountIdentity(source: "claude-swap", opaqueID: "1")
        let second = ProviderAccountIdentity(source: "claude-swap", opaqueID: "2")
        store.claudeSwapAccountSnapshots = [
            ProviderAccountUsageSnapshot(
                id: first,
                provider: .claude,
                displayLabel: "Personal",
                isActive: true,
                canActivate: false,
                snapshot: self.snapshot(12),
                error: nil,
                sourceLabel: "fixture"),
            ProviderAccountUsageSnapshot(
                id: second,
                provider: .claude,
                displayLabel: "Work",
                isActive: false,
                canActivate: true,
                snapshot: self.snapshot(89),
                error: nil,
                sourceLabel: "fixture"),
        ]
        store.claudeSwapTransientState.switchingAccountID = second
        store.claudeSwapRevision += 1
        let pending = store.nativeServicePresentation(for: .claude)
        #expect(pending.accountID == "1")
        #expect(pending.model.email == "Personal")
        #expect(pending.gauge.resolvedWindows[0].usedFraction == 0.12)
        store.claudeSwapTransientState.switchingAccountID = nil
        store.claudeSwapTransientState.lastErrorAccountID = second
        store.claudeSwapTransientState.lastError = "Fixture activation failed"
        store.claudeSwapRevision += 1
        let failed = store.nativeServicePresentation(for: .claude)
        #expect(failed.accountID == "1")
        #expect(failed.model.email == "Personal")
        #expect(failed.gauge.resolvedWindows[0].usedFraction == 0.12)
        #expect(!failed.model.subtitleText.contains("Fixture activation failed"))
        let inspected = store.nativeServicePresentation(for: .claude, inspectedAccountID: second)
        #expect(inspected.accountID == "1")
        #expect(inspected.gauge.resolvedWindows[0].usedFraction == 0.12)
    }

    @Test func `monthly quota and reset changes invalidate the native redraw signature`() {
        let store = self.store()
        let deadline = Date().addingTimeInterval(86400)
        func monthly(_ percent: Double, reset: Date) -> NamedRateWindow {
            NamedRateWindow(id: "kimi-monthly", title: "Monthly", window: RateWindow(
                usedPercent: percent, windowMinutes: 43200, resetsAt: reset, resetDescription: nil))
        }
        store.snapshots[.kimi] = self.snapshot(12, extras: [monthly(34, reset: deadline)])
        let initial = store.nativeServicePresentation(for: .kimi)
        store.snapshots[.kimi] = self.snapshot(12, extras: [monthly(89, reset: deadline)])
        let changed = store.nativeServicePresentation(for: .kimi)
        #expect(initial.iconSignature != changed.iconSignature)
        #expect(changed.gauge.resolvedWindows.first?.usedFraction == 0.89)
        store.snapshots[.kimi] = self.snapshot(12, extras: [monthly(89, reset: deadline.addingTimeInterval(3600))])
        #expect(changed.iconSignature != store.nativeServicePresentation(for: .kimi).iconSignature)
    }

    @Test func `more than three quotas keep the binding quota visible without invalidating the symbol`() {
        let store = self.store()
        store.snapshots[.claude] = UsageSnapshot(
            primary: RateWindow(usedPercent: 12, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 34, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            tertiary: RateWindow(usedPercent: 56, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            extraRateWindows: [NamedRateWindow(id: "binding-quota", title: "Additional", window: RateWindow(
                usedPercent: 100, windowMinutes: 43200, resetsAt: nil, resetDescription: nil))], updatedAt: Date())
        let presentation = store.nativeServicePresentation(for: .claude)
        #expect(presentation.model.metrics.count == 4)
        #expect(presentation.gauge.resolvedWindows.count == 3)
        #expect(presentation.gauge.resolvedWindows.contains { $0.id == "binding-quota" && $0.usedFraction == 1 })
        #expect(presentation.gauge.resolvedWindows.allSatisfy { $0.id != "invalid" })
    }
}

@MainActor
extension CodexAccountScopedRefreshTests {
    @Test func `native Codex gauge never borrows a sibling workspace or its credits`() async throws {
        try await self.withSelectedAccountRetentionFixture(sameEmail: true) { store, _, accounts in
            let prior = accounts[0]
            let live = CodexVisibleAccount(
                id: prior.id,
                email: prior.email,
                workspaceAccountID: prior.workspaceAccountID,
                authFingerprint: prior.authFingerprint,
                storedAccountID: prior.storedAccountID,
                selectionSource: prior.selectionSource,
                isActive: false,
                isLive: true,
                canReauthenticate: false,
                canRemove: false)
            store.settings.cachedCodexAccountMenuProjection = .init(
                activeSource: store.settings.codexActiveSource,
                loadedAt: Date(),
                projection: .init(
                    visibleAccounts: [live, accounts[1]],
                    activeVisibleAccountID: accounts[1].id,
                    liveVisibleAccountID: live.id,
                    hasUnreadableAddedAccountStore: false))
            store.snapshots[.codex] = self.codexSnapshot(email: "wrong@example.com", usedPercent: 91)
            store.credits = self.credits(remaining: 999)
            store.lastCodexUsagePublicationGuard = UsageStore.codexScopedRefreshGuard(for: accounts[1])
            let selected = store.nativeServicePresentation(for: .codex)
            #expect(selected.accountID == accounts[0].id)
            #expect(selected.gauge.resolvedWindows[0].usedFraction == 0.17)
            #expect(selected.model.email == accounts[0].email)
            #expect(selected.model.creditsRemaining != 999)
            store.codexAccountSnapshots.removeAll { $0.id == accounts[0].id }
            let empty = store.nativeServicePresentation(for: .codex)
            #expect(empty.gauge.resolvedWindows[0].usedFraction == nil)
            #expect(empty.model.metrics.isEmpty)
            #expect(empty.model.creditsText == nil)
            store.settings.cachedCodexAccountMenuProjection = nil
            let reconciling = store.nativeServicePresentation(for: .codex)
            #expect(reconciling.gauge.resolvedWindows[0].usedFraction == nil)
            #expect(reconciling.model.metrics.isEmpty)
        }
    }

    @Test func `native Codex live account retains usage when its publication owner matches`() throws {
        let settings = self.makeSettingsStore(suite: "NativeLiveCodex")
        settings._test_liveSystemCodexAccount = self.liveAccount(
            email: "solo@example.com", identity: .providerAccount(id: "solo"))
        settings.codexUsageDataSource = .oauth
        let store = self.makeUsageStore(settings: settings)
        let account = try #require(settings.codexVisibleAccountProjection.visibleAccounts.first)
        store.snapshots[.codex] = self.codexSnapshot(email: account.email, usedPercent: 23)
        store.lastCodexUsagePublicationGuard = UsageStore.codexScopedRefreshGuard(for: account)
        store.credits = self.credits(remaining: 42)
        let presentation = store.nativeServicePresentation(for: .codex)
        #expect(presentation.gauge.resolvedWindows[0].usedFraction == 0.23)
        #expect(presentation.model.creditsRemaining == 42)
        settings.cachedCodexAccountMenuProjection = nil
        #expect(store.nativeServicePresentation(for: .codex).gauge.resolvedWindows[0].usedFraction == nil)
        _ = settings.codexVisibleAccountProjection
        store.snapshots[.codex] = nil
        store.credits = CreditsSnapshot(
            remaining: 73,
            events: [],
            updatedAt: Date(),
            codexCreditLimit: CodexCreditLimitSnapshot(
                used: 27, limit: 100, remainingPercent: 73, resetsAt: nil, updatedAt: Date()))
        let creditOnly = store.nativeServicePresentation(for: .codex)
        #expect(creditOnly.gauge.resolvedWindows[0].id == "monthly")
        #expect(creditOnly.gauge.resolvedWindows[0].usedFraction == 0.27)
        store.lastCreditsError = "Credits refresh failed"
        #expect(store.nativeServicePresentation(for: .codex).gauge.health == .stale)
        store.lastSourceLabels[.codex] = CodexUsageDataSource.pat.sourceLabel
        #expect(store.nativeCodexAccountProjection == nil)
    }
}
