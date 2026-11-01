import Foundation
import Observation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct NativeOrbitAccountPresentationTests {
    @Test(arguments: [false, true])
    func `native Codex columns honor renamed accounts while privacy hides their names`(duringSwitch: Bool) throws {
        let store = self.store()
        let account = self.codexAccount(id: "named", email: "owner@example.test", active: true)
        let projection = CodexVisibleAccountProjection(
            visibleAccounts: [account],
            activeVisibleAccountID: account.id,
            liveVisibleAccountID: account.id,
            hasUnreadableAddedAccountStore: false)
        store.settings.renameCodexAccount(account, to: "Personal projects")
        if duringSwitch {
            store.nativeCodexAccountSwitchPresentation = .init(projection: projection, snapshots: [])
        } else {
            store.settings.cachedCodexAccountMenuProjection = .init(
                activeSource: store.settings.codexActiveSource, loadedAt: Date(), projection: projection)
        }
        let visible = try #require(store.nativeOrbitAccounts(for: .codex).first)
        #expect(visible.label == "Personal projects")
        #expect(visible.id == account.id)
        #expect(visible.isActive)
        store.settings.hidePersonalInfo = true
        let hidden = try #require(store.nativeOrbitAccounts(for: .codex).first)
        #expect(hidden.label == "Account 1")
        #expect(hidden.email == nil)
        #expect(hidden.id == visible.id)
    }

    @Test(arguments: [false, true])
    func `a sole Kimi account never offers login switching`(savedToken: Bool) throws {
        let store = self.store()
        if savedToken {
            store.settings.addTokenAccount(provider: .kimi, label: "Personal", token: "fixture-kimi")
            let account = try #require(store.settings.tokenAccounts(for: .kimi).first)
            store.cacheTokenAccountSnapshot(
                provider: .kimi, account: account, snapshot: self.snapshot(used: 25), sourceLabel: "fixture")
        } else {
            store.snapshots[.kimi] = self.snapshot(used: 25)
        }
        let rows = store.nativeOrbitAccounts(for: .kimi)
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        let status = NativeAccountUsePresentation.resolve(account: row, controllerAvailable: false)
        #expect(!status.showsUse)
        #expect(!status.isEnabled)
        #expect(status.unavailableReason == nil)
    }

    @Test func `token accounts stay separate without claiming a machine login`() {
        let store = self.store()
        store.settings.addTokenAccount(
            provider: .kimi,
            label: "First",
            token: "fixture-first")
        store.settings.addTokenAccount(
            provider: .kimi,
            label: "Second",
            token: "fixture-second")
        let accounts = store.settings.tokenAccounts(for: .kimi)
        store.settings.setActiveTokenAccountIndex(
            1,
            for: .kimi)
        store.cacheTokenAccountSnapshot(
            provider: .kimi,
            account: accounts[0],
            snapshot: self.snapshot(used: 25),
            sourceLabel: "fixture")
        store.snapshots[.kimi] = self.snapshot(used: 99)
        let rows = store.nativeOrbitAccounts(for: .kimi)
        let selected = rows.first { $0.id == accounts[1].id.uuidString }
        let monitored = rows.first { $0.id == accounts[0].id.uuidString }
        #expect(rows.allSatisfy { !$0.isActive && !$0.canActivate })
        #expect(selected?.gauge.health == .unknown)
        #expect(selected?.updatedAt == nil)
        #expect(monitored?.gauge.resolvedWindows.first?.usedFraction == 0.25)
        #expect(Set(rows.map(\.symbol)).count == rows.count)
        #expect(rows.allSatisfy { $0.odometer == nil })
    }

    @Test func `invalid cache ownership cannot reuse an ambient account reading`() {
        let store = self.store()
        store.settings.addTokenAccount(
            provider: .kimi,
            label: "First",
            token: "fixture-first")
        let account = store.settings.tokenAccounts(for: .kimi)[0]
        store.accountSnapshots[.kimi] = [TokenAccountUsageSnapshot(
            account: account,
            snapshot: self.snapshot(used: 75),
            error: nil,
            sourceLabel: "fixture",
            cacheKey: "invalid-owner")]
        store.snapshots[.kimi] = self.snapshot(used: 99)
        let row = store.nativeOrbitAccounts(for: .kimi)[0]
        #expect(row.gauge.health == .unknown)
        #expect(row.updatedAt == nil)
    }

    @Test func `Codex inactive account never borrows active or unscoped data`() {
        let store = self.store()
        let first = self.codexAccount(
            id: "first",
            email: "first@example.com",
            active: false)
        let second = self.codexAccount(
            id: "second",
            email: "second@example.com",
            active: true)
        let projection = CodexVisibleAccountProjection(
            visibleAccounts: [first, second],
            activeVisibleAccountID: second.id,
            liveVisibleAccountID: second.id,
            hasUnreadableAddedAccountStore: false)
        store.snapshots[.codex] = self.snapshot(used: 99)
        store._cancelPlanUtilizationHistoryLoadForTesting()
        store.planUtilizationHistory[.codex] = PlanUtilizationHistoryBuckets(unscoped: [self.history()])
        store.codexAccountSnapshots = [CodexAccountUsageSnapshot(
            account: self.codexAccount(
                id: "first",
                email: "foreign@example.com",
                active: false),
            snapshot: self.snapshot(used: 75),
            error: nil,
            sourceLabel: "fixture")]
        let rows = store.nativeOrbitCodexAccounts(projection)
        #expect(rows.map(\.id) == ["second", "first"])
        #expect(rows.allSatisfy { $0.gauge.health == .unknown && $0.history.isEmpty })
        #expect(store.planUtilizationHistory[.codex]?.unscoped.count == 1)
    }

    @Test func `a live Codex refresh retains the cached quota before credits finish publishing`() throws {
        let store = self.store()
        let account = self.codexAccount(id: "live", email: "owner@example.com", active: true)
        let cached = self.snapshot(used: 25)
        store.codexAccountSnapshots = [CodexAccountUsageSnapshot(
            account: account, snapshot: cached, error: nil, sourceLabel: "fixture")]
        store.lastCodexUsagePublicationGuard = UsageStore.codexScopedRefreshGuard(for: account)
        store.snapshots[.codex] = nil
        store.credits = CreditsSnapshot(
            remaining: 80,
            events: [],
            updatedAt: Date(),
            codexCreditLimit: .init(used: 20, limit: 100, remainingPercent: 80, resetsAt: nil, updatedAt: Date()))
        let projection = CodexVisibleAccountProjection(
            visibleAccounts: [account],
            activeVisibleAccountID: account.id,
            liveVisibleAccountID: account.id,
            hasUnreadableAddedAccountStore: false)
        let row = try #require(store.nativeOrbitCodexAccounts(projection).first)
        #expect(row.gauge.resolvedWindows.first?.id == "session")
        #expect(row.gauge.resolvedWindows.first?.usedFraction == 0.25)
        #expect(row.updatedAt == cached.updatedAt)
        store.settings.cachedCodexAccountMenuProjection = .init(
            activeSource: store.settings.codexActiveSource, loadedAt: Date(), projection: projection)
        let service = store.nativeServicePresentation(for: .codex)
        #expect(service.gauge.resolvedWindows.first?.id == "session")
        #expect(service.gauge.resolvedWindows.first?.usedFraction == 0.25)
    }

    @Test func `Codex switch inventory survives invalidation and yields to verified removal`() {
        let store = self.store()
        let account = self.codexAccount(id: "live", email: "owner@example.com", active: true)
        let projection = CodexVisibleAccountProjection(
            visibleAccounts: [account],
            activeVisibleAccountID: account.id,
            liveVisibleAccountID: account.id,
            hasUnreadableAddedAccountStore: false)
        store.nativeCodexAccountSwitchPresentation = .init(projection: projection, snapshots: [])
        store.settings.cachedCodexAccountMenuProjection = nil
        #expect(store.nativeOrbitAccounts(for: .codex).map(\.id) == ["live"])
        let removed = CodexVisibleAccountProjection(
            visibleAccounts: [],
            activeVisibleAccountID: nil,
            liveVisibleAccountID: nil,
            hasUnreadableAddedAccountStore: false)
        store.settings.cachedCodexAccountMenuProjection = .init(
            activeSource: store.settings.codexActiveSource, loadedAt: Date(), projection: removed)
        #expect(!store.nativeOrbitAccounts(for: .codex).contains { $0.id == "live" })
        store.settings.cachedCodexAccountMenuProjection = nil
        store.nativeCodexAccountSwitchPresentation = nil
        #expect(!store.nativeOrbitAccounts(for: .codex).contains { $0.id == "live" })
    }

    @Test func `Codex switch fills a partial owner receipt and releases absent windows afterward`() throws {
        let store = self.store()
        let account = self.codexAccount(id: "live", email: "owner@example.com", active: true)
        let projection = CodexVisibleAccountProjection(
            visibleAccounts: [account],
            activeVisibleAccountID: account.id,
            liveVisibleAccountID: account.id,
            hasUnreadableAddedAccountStore: false)
        let complete = UsageSnapshot(
            primary: RateWindow(usedPercent: 25, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 60, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            updatedAt: Date().addingTimeInterval(-60),
            identity: .init(
                providerID: .codex,
                accountEmail: account.email,
                accountOrganization: nil,
                loginMethod: "Pro"))
        let partial = self.snapshot(used: 30)
        let previous = CodexAccountUsageSnapshot(
            account: account, snapshot: complete, error: nil, sourceLabel: "fixture")
        store.nativeCodexAccountSwitchPresentation = .init(projection: projection, snapshots: [previous])
        store.codexAccountSnapshots = [CodexAccountUsageSnapshot(
            account: account, snapshot: partial, error: nil, sourceLabel: "fixture")]
        store.snapshots[.codex] = partial
        store.lastCodexUsagePublicationGuard = UsageStore.codexScopedRefreshGuard(for: account)
        let during = try #require(store.nativeOrbitCodexAccounts(projection).first)
        #expect(during.gauge.resolvedWindows.contains { $0.id == "session" && $0.usedFraction == 0.30 })
        #expect(during.gauge.resolvedWindows.contains { $0.id == "weekly" && $0.usedFraction == 0.60 })
        store.nativeCodexAccountSwitchPresentation = nil
        let settled = try #require(store.nativeOrbitCodexAccounts(projection).first)
        #expect(!settled.gauge.resolvedWindows.contains { $0.id == "weekly" })
    }

    @Test func `ClaudeSwap missing and foreign provider readings stay unknown`() {
        let store = self.store()
        store.settings.claudeSwapEnabled = true
        store.settings.claudeSwapShowSingleAccount = true
        store.snapshots[.claude] = self.snapshot(used: 99)
        store.claudeSwapAccountSnapshots = [
            ProviderAccountUsageSnapshot(
                id: .init(
                    source: "claude-swap",
                    opaqueID: "1"),
                provider: .claude,
                displayLabel: "Missing",
                isActive: true,
                snapshot: nil,
                error: nil,
                sourceLabel: "fixture"),
            ProviderAccountUsageSnapshot(
                id: .init(
                    source: "claude-swap",
                    opaqueID: "2"),
                provider: .codex,
                displayLabel: "Foreign",
                isActive: false,
                snapshot: self.snapshot(used: 80),
                error: nil,
                sourceLabel: "fixture"),
        ]
        let rows = store.nativeOrbitAccounts(for: .claude)
        #expect(rows.count == 1)
        #expect(rows.first?.gauge.health == .unknown)
        #expect(rows.first?.history.isEmpty == true)
    }

    @Test func `Codex canonical history remains attached to its owner`() throws {
        let store = self.store()
        store._cancelPlanUtilizationHistoryLoadForTesting()
        let first = self.codexAccount(
            id: "first",
            email: "first@example.com",
            active: false)
        let second = self.codexAccount(
            id: "second",
            email: "second@example.com",
            active: true)
        let key = try #require(CodexHistoryOwnership.canonicalKey(
            for: .emailOnly(normalizedEmail: first.email)))
        store.planUtilizationHistory[.codex] = PlanUtilizationHistoryBuckets(
            unscoped: [self.history()],
            accounts: [key: [self.history()]])
        let projection = CodexVisibleAccountProjection(
            visibleAccounts: [first, second],
            activeVisibleAccountID: second.id,
            liveVisibleAccountID: second.id,
            hasUnreadableAddedAccountStore: false)
        let rows = store.nativeOrbitCodexAccounts(projection)
        #expect(rows[0].history.isEmpty)
        #expect(rows[1].history.count == 1)
        #expect(store.planUtilizationHistory[.codex]?.unscoped.count == 1)
    }

    @Test func `account symbols survive active selection changes and privacy hides emails`() {
        let store = self.store()
        store.settings.addTokenAccount(
            provider: .kimi,
            label: "first@example.com",
            token: "fixture-first")
        store.settings.addTokenAccount(
            provider: .kimi,
            label: "second@example.com",
            token: "fixture-second")
        let before = store.nativeOrbitAccounts(for: .kimi)
        store.settings.setActiveTokenAccountIndex(
            0,
            for: .kimi)
        store.settings.hidePersonalInfo = true
        let after = store.nativeOrbitAccounts(for: .kimi)
        for row in after {
            #expect(row.email == nil)
            #expect(!row.label.contains("@"))
            #expect(row.symbol == before.first { $0.id == row.id }?.symbol)
        }
    }

    @Test func `empty Codex inventory retains an honest unknown column`() {
        let store = self.store()
        store.snapshots[.codex] = self.snapshot(used: 99)
        let projection = CodexVisibleAccountProjection(
            visibleAccounts: [],
            activeVisibleAccountID: nil,
            liveVisibleAccountID: nil,
            hasUnreadableAddedAccountStore: false)
        let rows = store.nativeOrbitCodexAccounts(projection)
        #expect(rows.count == 1)
        #expect(rows.first?.gauge.health == .unknown)
        #expect(rows.first?.updatedAt == nil)
        #expect(rows.first?.history.isEmpty == true)
        #expect(rows.first?.isActive == false)
    }

    @Test func `Automatic remains monitoring only without borrowing a saved account reading`() throws {
        let store = self.store()
        enableTestProviders([.cursor], settings: store.settings)
        store.settings.addTokenAccount(provider: .cursor, label: "Saved", token: "fixture-cursor")
        let account = try #require(store.settings.tokenAccounts(for: .cursor).first)
        store.selectNativeTokenAccount(account.id, for: .cursor)
        store.cacheTokenAccountSnapshot(
            provider: .cursor,
            account: account,
            snapshot: self.snapshot(used: 73),
            sourceLabel: "fixture")
        store.activateCachedTokenAccountSnapshot(provider: .cursor, accountID: account.id)
        let rows = store.nativeOrbitAccounts(for: .cursor)
        let automatic = try #require(rows.first { $0.id == "cursor:automatic" })
        #expect(!automatic.isActive)
        #expect(!automatic.canActivate)
        #expect(automatic.gauge.health == .unknown)
        #expect(automatic.updatedAt == nil)
        #expect(automatic.history.isEmpty)
        #expect(automatic.odometer == nil)
        guard case .none = automatic.selection else {
            Issue.record("A monitoring source cannot switch a machine login")
            return
        }
        store.selectNativeTokenAccount(nil, for: .cursor)
        let returned = try #require(store.nativeOrbitAccounts(for: .cursor).first { $0.id == automatic.id })
        #expect(!returned.isActive)
        #expect(!returned.canActivate)
        #expect(returned.gauge.health == .unknown)
    }

    @Test func `history observation subscribes before persisted history has loaded`() {
        let store = self.store()
        store.settings.addTokenAccount(provider: .kimi, label: "Saved", token: "fixture-kimi")
        store.planUtilizationHistoryLoaded = false
        let changes = NativeOrbitObservationChanges()
        withObservationTracking {
            _ = store.nativeOrbitAccounts(for: .kimi)
        } onChange: {
            MainActor.assumeIsolated { changes.count += 1 }
        }
        store.planUtilizationHistoryRevision &+= 1
        #expect(changes.count == 1)
    }

    @Test(arguments: [true, false])
    func `imported profile copies retain durable owner identity across credential rotation`(hasWorkspace: Bool) throws {
        let store = self.store()
        let storedID = UUID()
        let workspace = hasWorkspace ? "workspace-owner" : nil
        func account(id: String, managed: Bool, workspace: String?, fingerprint: String?) -> CodexVisibleAccount {
            CodexVisibleAccount(
                id: id,
                email: "same@example.com",
                workspaceAccountID: workspace,
                authFingerprint: fingerprint,
                storedAccountID: managed ? storedID : nil,
                selectionSource: managed ? .liveSystem : .profileHome(path: "/tmp/import-copy-\(id)"),
                isActive: managed,
                isLive: managed,
                canReauthenticate: managed,
                canRemove: managed)
        }
        let managed = account(id: "managed", managed: true, workspace: workspace, fingerprint: "same-auth")
        let exact = account(id: "exact-copy", managed: false, workspace: workspace, fingerprint: "same-auth")
        let rotated = account(id: "rotated", managed: false, workspace: workspace, fingerprint: "new-auth")
        let sibling = account(id: "sibling", managed: false, workspace: "workspace-other", fingerprint: "same-auth")
        let unknown = account(id: "unknown", managed: false, workspace: nil, fingerprint: nil)
        let projection = CodexVisibleAccountProjection(
            visibleAccounts: [exact, rotated, sibling, unknown, managed],
            activeVisibleAccountID: managed.id,
            liveVisibleAccountID: managed.id,
            hasUnreadableAddedAccountStore: false)
        let rows = store.nativeOrbitCodexAccounts(projection)
        #expect(rows.count == (hasWorkspace ? 3 : 4))
        #expect(rows.first?.id == managed.id)
        #expect(rows.first?.isActive == true)
        #expect(!rows.contains { $0.id == exact.id })
        #expect(rows.contains { $0.id == rotated.id } == !hasWorkspace)
        for profile in hasWorkspace ? [sibling] : [rotated, sibling] {
            let row = try #require(rows.first { $0.id == profile.id })
            #expect(row.canActivate)
            #expect(!row.autoSwitchEligible)
        }
        #expect(rows.first { $0.id == unknown.id }?.canActivate == false)
        #expect(projection.visibleAccounts.count == 5)
        let secondManaged = account(
            id: "another-managed",
            managed: true,
            workspace: workspace,
            fingerprint: "same-auth")
        let ambiguous = CodexVisibleAccountProjection(
            visibleAccounts: [managed, secondManaged, exact],
            activeVisibleAccountID: managed.id,
            liveVisibleAccountID: managed.id,
            hasUnreadableAddedAccountStore: false)
        #expect(store.nativeOrbitCodexAccounts(ambiguous).contains { $0.id == exact.id })
    }

    private func snapshot(used: Double) -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(
                usedPercent: used,
                windowMinutes: 300,
                resetsAt: Date().addingTimeInterval(3600),
                resetDescription: nil),
            secondary: nil,
            updatedAt: Date())
    }

    private func history() -> PlanUtilizationSeriesHistory {
        PlanUtilizationSeriesHistory(
            name: .session,
            windowMinutes: 300,
            entries: [.init(
                capturedAt: Date(),
                usedPercent: 80,
                resetsAt: nil)])
    }

    private func codexAccount(
        id: String,
        email: String,
        active: Bool) -> CodexVisibleAccount
    {
        CodexVisibleAccount(
            id: id,
            email: email,
            storedAccountID: nil,
            selectionSource: .profileHome(path: "/tmp/orbit-\(id)"),
            isActive: active,
            isLive: active,
            canReauthenticate: false,
            canRemove: false)
    }

    @Test func `saved account preserves its typed provider token history`() throws {
        let store = self.store()
        store.settings.addTokenAccount(provider: .openai, label: "API", token: "fixture-admin")
        let account = try #require(store.settings.tokenAccounts(for: .openai).first)
        let now = Date()
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now)
        let day = CostUsageLocalDay.key(from: now, calendar: calendar)
        let previousMonth = try #require(calendar.dateInterval(of: .month, for: now)?.start)
            .addingTimeInterval(-86400)
        store.settings.costReportingPeriod = .monthToDate
        let api = OpenAIAPIUsageSnapshot(
            daily: [.init(
                day: day,
                startTime: start,
                endTime: start.addingTimeInterval(86400),
                costUSD: 2.5,
                requests: 7,
                inputTokens: 100,
                cachedInputTokens: 20,
                outputTokens: 40,
                totalTokens: 140,
                lineItems: [],
                models: []), .init(
                day: CostUsageLocalDay.key(
                    from: previousMonth,
                    calendar: calendar),
                startTime: previousMonth,
                endTime: previousMonth.addingTimeInterval(86400),
                costUSD: 1,
                requests: 2,
                inputTokens: 10,
                cachedInputTokens: 0,
                outputTokens: 5,
                totalTokens: 15,
                lineItems: [],
                models: [])],
            updatedAt: now)
        store.cacheTokenAccountSnapshot(
            provider: .openai,
            account: account,
            snapshot: api.toUsageSnapshot(),
            sourceLabel: "fixture")
        let row = try #require(store.nativeOrbitAccounts(for: .openai).first)
        #expect(row.metrics.usage?.daily.map(\.totalTokens) == [15, 140])
        #expect(row.metrics.summary(days: 1, now: now).tokens == 140)
        #expect(row.metrics.summary(days: 1, now: now).cost == 2.5)
    }

    private func store() -> UsageStore {
        let settings = testSettingsStore(
            suiteName: "native-orbit",
            userDefaults: InMemoryUserDefaults())
        enableTestProviders(
            [.kimi, .codex, .claude],
            settings: settings)
        return UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
    }
}

@MainActor
private final class NativeOrbitObservationChanges {
    var count = 0
}
