import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

private actor NativeMonitoringRecorder {
    private(set) var count = 0
    func record() { self.count += 1 }
}

private struct NativeMonitoringStrategy: ProviderFetchStrategy {
    let recorder: NativeMonitoringRecorder
    let id = "native-monitoring-fixture"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_: ProviderFetchContext) async -> Bool { true }

    func fetch(_: ProviderFetchContext) async throws -> ProviderFetchResult {
        await self.recorder.record()
        return self.makeResult(usage: UsageSnapshot(
            primary: RateWindow(usedPercent: 25, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date()), sourceLabel: self.id)
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool { false }
}

@MainActor
struct NativeAllAccountMonitoringTests {
    @Test func `native monitoring refreshes every saved account with automatic source selected`() async throws {
        let store = self.store(native: true)
        store.settings.multiAccountMenuLayout = .segmented
        store.settings.accountWidgetsEnabled = false
        for index in 0..<9 {
            store.settings.addTokenAccount(provider: .cursor, label: "Account \(index)", token: "fixture-\(index)")
        }
        store.settings.updateProviderConfig(provider: .cursor) { $0.cookieSource = .auto }
        let accounts = store.settings.tokenAccounts(for: .cursor)
        #expect(store.settings.effectiveSelectedTokenAccount(for: .cursor) == nil)
        #expect(store.shouldFetchAllTokenAccounts(provider: .cursor, accounts: accounts))
        #expect(store.limitedTokenAccounts(accounts, selected: nil).count == 9)
        let recorder = NativeMonitoringRecorder()
        let base = try #require(store.providerSpecs[.cursor])
        store.providerSpecs[.cursor] = ProviderSpec(
            style: base.style,
            isEnabled: { true },
            descriptor: ProviderDescriptor(
                id: .cursor,
                metadata: base.descriptor.metadata,
                branding: base.descriptor.branding,
                tokenCost: base.descriptor.tokenCost,
                fetchPlan: ProviderFetchPlan(
                    sourceModes: [.auto],
                    pipeline: ProviderFetchPipeline { _ in [NativeMonitoringStrategy(recorder: recorder)] }),
                cli: base.descriptor.cli),
            makeFetchContext: base.makeFetchContext)
        let ambient = UsageSnapshot(
            primary: RateWindow(usedPercent: 82, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date())
        store.snapshots[.cursor] = ambient
        await store.refreshTokenAccounts(provider: .cursor, accounts: accounts)
        #expect(await recorder.count == 9)
        #expect(store.accountSnapshots[.cursor]?.count == 9)
        #expect(store.accountSnapshots[.cursor]?.allSatisfy { $0.snapshot?.primary?.usedPercent == 25 } == true)
        #expect(store.snapshots[.cursor]?.primary?.usedPercent == 82)
        #expect(store.settings.effectiveSelectedTokenAccount(for: .cursor) == nil)
        #expect(store.nativeOrbitAccounts(for: .cursor).allSatisfy { !$0.isActive && !$0.canActivate })
    }

    @Test func `native Codex monitoring removes six account cap and retains PAT guard`() {
        let store = self.store(native: true)
        let accounts = (0..<9).map { index in
            CodexVisibleAccount(
                id: "fixture-\(index)",
                email: "account-\(index)@example.com",
                storedAccountID: nil,
                selectionSource: .profileHome(path: "/tmp/native-monitoring-\(index)"),
                isActive: index == 8,
                isLive: index == 0,
                canReauthenticate: false,
                canRemove: false)
        }
        #expect(store.limitedCodexVisibleAccounts(accounts, activeVisibleAccountID: accounts[8].id).count == 9)
        store.settings.codexUsageDataSource = .pat
        #expect(!store.shouldFetchAllCodexVisibleAccounts())
        let legacy = self.store(native: false)
        #expect(legacy.limitedCodexVisibleAccounts(accounts, activeVisibleAccountID: accounts[8].id).count == 6)
    }

    @Test func `Codex rows use the live login and profile sources cannot activate it`() {
        let store = self.store(native: true)
        let live = CodexVisibleAccount(
            id: "live",
            email: "live@example.com",
            storedAccountID: nil,
            selectionSource: .liveSystem,
            isActive: false,
            isLive: true,
            canReauthenticate: false,
            canRemove: false)
        let monitored = CodexVisibleAccount(
            id: "monitored",
            email: "monitored@example.com",
            storedAccountID: nil,
            selectionSource: .profileHome(path: "/tmp/native-monitored"),
            isActive: true,
            isLive: false,
            canReauthenticate: false,
            canRemove: false)
        let projection = CodexVisibleAccountProjection(
            visibleAccounts: [monitored, live],
            activeVisibleAccountID: monitored.id,
            liveVisibleAccountID: live.id,
            hasUnreadableAddedAccountStore: false)
        let rows = store.nativeOrbitCodexAccounts(projection)
        #expect(rows.first?.id == live.id)
        #expect(rows.first?.isActive == true)
        #expect(rows.last?.isActive == false)
        #expect(rows.allSatisfy { !$0.canActivate && !$0.autoSwitchEligible })
    }

    @Test func `ambiguous Claude login and reconciliation never publish a live gauge`() {
        let store = self.store(native: true)
        store.settings.claudeSwapEnabled = true
        store.settings.claudeSwapShowSingleAccount = false
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 91,
                windowMinutes: 300,
                resetsAt: nil,
                resetDescription: nil),
            secondary: nil,
            updatedAt: Date())
        store.claudeSwapAccountSnapshots = (1...2).map { index in
            ProviderAccountUsageSnapshot(
                id: .init(
                    source: "claude-swap",
                    opaqueID: String(index)),
                provider: .claude,
                displayLabel: "Account \(index)",
                isActive: true,
                snapshot: snapshot,
                error: nil,
                sourceLabel: "fixture")
        }
        let ambiguous = store.nativeServicePresentation(for: .claude)
        #expect(ambiguous.accountID == nil)
        #expect(ambiguous.gauge.resolvedWindows.allSatisfy { $0.usedFraction == nil })
        #expect(store.nativeOrbitAccounts(for: .claude).allSatisfy { !$0.isActive })
        store.claudeSwapAccountSnapshots.removeLast()
        #expect(store.nativeClaudeSwapOwnsPresentation)
        #expect(store.nativeOrbitAccounts(for: .claude).first?.isActive == true)
        store.claudeSwapTransientState.switchPhase = .reconciling
        #expect(store.nativeServiceGauge(for: .claude).resolvedWindows.allSatisfy { $0.usedFraction == nil })
        #expect(store.nativeOrbitAccounts(for: .claude).allSatisfy { !$0.isActive })
    }

    @Test func `Codex automatic activation eligibility requires a successful owned saved account reading`() throws {
        let store = self.store(native: true)
        let id = UUID()
        let saved = CodexVisibleAccount(
            id: id.uuidString,
            email: "saved@example.com",
            authFingerprint: "fixture-fingerprint",
            storedAccountID: id,
            selectionSource: .managedAccount(id: id),
            isActive: true,
            isLive: false,
            canReauthenticate: false,
            canRemove: false)
        let projection = CodexVisibleAccountProjection(
            visibleAccounts: [saved],
            activeVisibleAccountID: saved.id,
            liveVisibleAccountID: nil,
            hasUnreadableAddedAccountStore: false)
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 20, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 30, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            tertiary: RateWindow(usedPercent: 100, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            updatedAt: Date())
        for error in [nil, "Refresh failed"] as [String?] {
            store.codexAccountSnapshots = [CodexAccountUsageSnapshot(
                account: saved,
                snapshot: snapshot,
                error: error,
                sourceLabel: "fixture")]
            let row = try #require(store.nativeOrbitCodexAccounts(projection).first)
            #expect(!row.isActive)
            #expect(row.canActivate)
            #expect(row.autoSwitchEligible == (error == nil))
            #expect(row.autoSwitchWindows.count == 2)
            #expect(row.autoSwitchWindows.compactMap { $0?.usedPercent } == [20, 30])
        }
        store.codexAccountSnapshots = []
        #expect(store.nativeOrbitCodexAccounts(projection).first?.autoSwitchEligible == false)
    }

    @Test func `profile automatic switching requires durable owner and verified credentials`() throws {
        let store = self.store(native: true)
        for (workspace, email, fingerprint, eligible) in [
            ("workspace" as String?, "profile@example.com", "fingerprint" as String?, true),
            (nil, "profile@example.com", "fingerprint", false),
            ("workspace", "", "fingerprint", false),
            ("workspace", "profile@example.com", nil, false),
        ] {
            let profile = CodexVisibleAccount(
                id: "profile",
                email: email,
                workspaceAccountID: workspace,
                authFingerprint: fingerprint,
                storedAccountID: nil,
                selectionSource: .profileHome(path: "/tmp/native-auto-profile"),
                isActive: false,
                isLive: false,
                canReauthenticate: false,
                canRemove: false)
            store.codexAccountSnapshots = [CodexAccountUsageSnapshot(
                account: profile,
                snapshot: UsageSnapshot(
                    primary: RateWindow(usedPercent: 20, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                    secondary: nil,
                    updatedAt: Date()),
                error: nil,
                sourceLabel: "fixture")]
            let projection = CodexVisibleAccountProjection(
                visibleAccounts: [profile],
                activeVisibleAccountID: nil,
                liveVisibleAccountID: nil,
                hasUnreadableAddedAccountStore: false)
            let row = try #require(store.nativeOrbitCodexAccounts(projection).first)
            #expect(row.autoSwitchEligible == eligible)
        }
    }

    @Test func `native multi-token icon cannot follow a monitoring selection`() throws {
        let store = self.store(native: true)
        for index in 0..<2 {
            store.settings.addTokenAccount(provider: .cursor, label: "Account \(index)", token: "fixture-\(index)")
        }
        let accounts = store.settings.tokenAccounts(for: .cursor)
        for (index, account) in accounts.enumerated() {
            store.selectNativeTokenAccount(account.id, for: .cursor)
            store.cacheTokenAccountSnapshot(
                provider: .cursor,
                account: account,
                snapshot: UsageSnapshot(
                    primary: RateWindow(
                        usedPercent: Double(20 + index * 60),
                        windowMinutes: 300,
                        resetsAt: nil,
                        resetDescription: nil),
                    secondary: nil,
                    updatedAt: Date()),
                sourceLabel: "fixture")
            store.activateCachedTokenAccountSnapshot(provider: .cursor, accountID: account.id)
            let owner = try #require(UsageStore.warningTokenAccountDiscriminator(account))
            store.nativeAuthenticationFailures.insert(.init(provider: .cursor, account: owner))
            let presentation = store.nativeServicePresentation(for: .cursor)
            #expect(presentation.accountID == nil)
            #expect(presentation.gaugeOwnershipID == nil)
            #expect(presentation.gauge.health == .unknown)
            #expect(presentation.gauge.resolvedWindows.allSatisfy { $0.usedFraction == nil })
            #expect(presentation.model.metrics.isEmpty)
        }
        let rows = store.nativeOrbitAccounts(for: .cursor).filter { $0.id != "cursor:automatic" }
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { !$0.isActive && !$0.canActivate })
        #expect(Set(rows.compactMap { $0.gauge.resolvedWindows.first?.usedFraction }) == [0.2, 0.8])
    }

    @Test func `native single-token and automatic provider reports retain their usage`() throws {
        let store = self.store(native: true)
        store.settings.addTokenAccount(provider: .cursor, label: "Only account", token: "fixture-only")
        let account = try #require(store.settings.tokenAccounts(for: .cursor).first)
        store.selectNativeTokenAccount(account.id, for: .cursor)
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 42, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date())
        store.cacheTokenAccountSnapshot(provider: .cursor, account: account, snapshot: snapshot, sourceLabel: "fixture")
        store.activateCachedTokenAccountSnapshot(provider: .cursor, accountID: account.id)
        #expect(store.nativeServiceGauge(for: .cursor).resolvedWindows.first?.usedFraction == 0.42)
        store.settings.addTokenAccount(provider: .cursor, label: "Other account", token: "fixture-other")
        store.selectNativeTokenAccount(nil, for: .cursor)
        store.snapshots[.cursor] = snapshot
        #expect(store.settings.effectiveSelectedTokenAccount(for: .cursor) == nil)
        #expect(store.nativeServiceGauge(for: .cursor).resolvedWindows.first?.usedFraction == 0.42)
    }

    @Test func `Claude selected repair slot remains switchable without claiming the live login`() throws {
        let store = self.store(native: true)
        store.settings.claudeSwapEnabled = true
        let identity = ProviderAccountIdentity(source: "claude-swap", opaqueID: "1")
        store.claudeSwapAccountSnapshots = [ProviderAccountUsageSnapshot(
            id: identity,
            provider: .claude,
            displayLabel: "Saved slot with foreign credentials",
            isActive: true,
            canActivate: true,
            snapshot: UsageSnapshot(
                primary: RateWindow(usedPercent: 14, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: Date()),
            error: nil,
            sourceLabel: "fixture")]
        let row = try #require(store.nativeOrbitAccounts(for: .claude).first)
        #expect(!row.isActive)
        #expect(row.canActivate)
        guard case let .claudeSwap(target) = row.selection else {
            Issue.record("A repairable slot must retain the source-owned activation route")
            return
        }
        #expect(target.id == identity)
        let presentation = store.nativeServicePresentation(for: .claude)
        #expect(presentation.accountID == nil)
        #expect(presentation.gauge.resolvedWindows.allSatisfy { $0.usedFraction == nil })
    }

    @Test func `native Antigravity saved account monitoring cannot use the passive CLI login`() async {
        let store = self.store(native: true)
        store.settings.addTokenAccount(provider: .antigravity, label: "First", token: "fixture-first-oauth")
        store.settings.addTokenAccount(provider: .antigravity, label: "Second", token: "fixture-second-oauth")
        store.settings.updateProviderConfig(provider: .antigravity) { $0.source = .cli }
        let accounts = store.settings.tokenAccounts(for: .antigravity)
        #expect(store.settings.effectiveSelectedTokenAccount(for: .antigravity) == nil)
        #expect(store.shouldFetchAllTokenAccounts(provider: .antigravity, accounts: accounts))
        let pipeline = ProviderDescriptorRegistry.descriptor(for: .antigravity).fetchPlan.pipeline
        for account in accounts {
            let context = store.makeFetchContext(
                provider: .antigravity, override: TokenAccountOverride(provider: .antigravity, account: account))
            #expect(context.sourceMode == .oauth)
            #expect(context.selectedTokenAccountID == account.id)
            #expect(context.env[AntigravityOAuthCredentialsStore.environmentCredentialsKey] == account.token)
            let strategies = await pipeline.resolveStrategies(context)
            #expect(strategies.map(\.id) == ["antigravity.oauth"])
        }
        let ambient = store.makeFetchContext(provider: .antigravity, override: nil)
        #expect(ambient.sourceMode == .cli)
        #expect(ambient.selectedTokenAccountID == nil)
        #expect(ambient.env[AntigravityOAuthCredentialsStore.environmentCredentialsKey] == nil)
        let ambientStrategies = await pipeline.resolveStrategies(ambient)
        #expect(ambientStrategies.map(\.id) == [
            "antigravity.app-local", "antigravity.cli-https", "antigravity.ide-local", "antigravity.offline",
        ])
        #expect(store.settings.antigravityUsageDataSource == .cli)
    }

    @Test func `native secondary DeepSeek accounts request the full optional payload and identity`() throws {
        let store = self.store(native: true)
        store.settings.accountWidgetsEnabled = false
        store.settings.costUsageEnabled = true
        store.settings.showOptionalCreditsAndExtraUsage = true
        store.settings.addTokenAccount(provider: .deepseek, label: "Other", token: "fixture-other")
        store.settings.addTokenAccount(provider: .deepseek, label: "Main", token: "fixture-main")
        let other = try #require(store.settings.tokenAccounts(for: .deepseek).first)
        let context = store.makeFetchContext(
            provider: .deepseek, override: TokenAccountOverride(provider: .deepseek, account: other))
        #expect(context.includeOptionalUsage)
        #expect(context.includeAccountIdentity)
        #expect(context.selectedTokenAccountID == other.id)
    }

    @Test func `native saved accounts remain available without an ambient login`() {
        let store = self.store(native: true)
        store.settings.addTokenAccount(provider: .antigravity, label: "Saved", token: "fixture-oauth")
        store.settings.updateProviderConfig(provider: .antigravity) { $0.source = .cli }
        #expect(store.isProviderAvailable(.antigravity))
    }

    @Test func `background monitoring preserves fresh siblings while refreshing main`() async throws {
        let store = self.store(native: true)
        store.settings.addTokenAccount(provider: .zai, label: "Main", token: "fixture-main")
        store.settings.addTokenAccount(provider: .zai, label: "Other", token: "fixture-other")
        let accounts = store.settings.tokenAccounts(for: .zai)
        store.selectNativeTokenAccount(accounts[0].id, for: .zai)
        let reset = Date().addingTimeInterval(3600)
        for (index, account) in accounts.enumerated() {
            store.cacheTokenAccountSnapshot(
                provider: .zai,
                account: account,
                snapshot: UsageSnapshot(
                    primary: RateWindow(
                        usedPercent: Double(index * 50),
                        windowMinutes: 300,
                        resetsAt: reset,
                        resetDescription: nil),
                    secondary: nil,
                    updatedAt: Date()).withAccountLabel(account.label, for: .zai),
                sourceLabel: "previous")
        }
        let recorder = NativeMonitoringRecorder()
        let base = try #require(store.providerSpecs[.zai])
        store.providerSpecs[.zai] = ProviderSpec(
            style: base.style,
            isEnabled: { true },
            descriptor: ProviderDescriptor(
                id: .zai,
                metadata: base.descriptor.metadata,
                branding: base.descriptor.branding,
                tokenCost: base.descriptor.tokenCost,
                fetchPlan: ProviderFetchPlan(sourceModes: [.auto], pipeline: ProviderFetchPipeline { _ in
                    [NativeMonitoringStrategy(recorder: recorder)]
                }),
                cli: base.descriptor.cli),
            makeFetchContext: base.makeFetchContext)
        await store.refreshTokenAccounts(provider: .zai, accounts: accounts)
        #expect(await recorder.count == 1)
        #expect(store.accountSnapshots[.zai]?.count == 2)
        let rows = store.nativeOrbitAccounts(for: .zai)
        #expect(rows.first(where: { $0.id == accounts[0].id.uuidString })?.gauge.resolvedWindows.first?
            .usedFraction == 0.25)
        #expect(rows.first(where: { $0.id == accounts[1].id.uuidString })?.gauge.resolvedWindows.first?
            .usedFraction == 0.5)
        #expect(store.accountSnapshots[.zai]?.first(where: { $0.id == accounts[0].id })?
            .snapshot?.primary?.resetsAt == reset)
        await ProviderInteractionContext.$current.withValue(.userInitiated) {
            await store.refreshTokenAccounts(provider: .zai, accounts: accounts)
        }
        #expect(await recorder.count == 3)
        #expect(store.accountSnapshots[.zai]?.allSatisfy { $0.snapshot?.primary?.usedPercent == 25 } == true)
        #expect(store.accountSnapshots[.zai]?.allSatisfy { $0.snapshot?.primary?.resetsAt == reset } == true)
        store.settings.updateTokenAccount(provider: .zai, accountID: accounts[1].id, token: "fixture-replaced")
        await store.refreshTokenAccounts(provider: .zai, accounts: store.settings.tokenAccounts(for: .zai))
        #expect(await recorder.count == 5)
        #expect(store.accountSnapshots[.zai]?.count == 2)
    }

    @Test func `secondary polling uses attempt time without making cached measurements fresh`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = UsageSnapshot(primary: nil, secondary: nil, updatedAt: now.addingTimeInterval(-3600))
        #expect(UsageStore.nativeSecondaryAccountRefreshIsDue(snapshot: nil, lastAttempt: nil, now: now))
        #expect(UsageStore.nativeSecondaryAccountRefreshIsDue(snapshot: old, lastAttempt: nil, now: now))
        #expect(!UsageStore.nativeSecondaryAccountRefreshIsDue(
            snapshot: old, lastAttempt: now.addingTimeInterval(-299), now: now))
        #expect(UsageStore.nativeSecondaryAccountRefreshIsDue(
            snapshot: old, lastAttempt: now.addingTimeInterval(-300), now: now))
        #expect(old.updatedAt == now.addingTimeInterval(-3600))
        let reset = UsageSnapshot(
            primary: nil,
            secondary: nil,
            extraRateWindows: [
                .init(id: "model", title: "Model", window: .init(
                    usedPercent: 100,
                    windowMinutes: 10080,
                    resetsAt: now.addingTimeInterval(-30),
                    resetDescription: nil)),
            ],
            updatedAt: now.addingTimeInterval(-60))
        #expect(UsageStore.nativeSecondaryAccountRefreshIsDue(snapshot: reset, lastAttempt: nil, now: now))
        #expect(!UsageStore.nativeSecondaryAccountRefreshIsDue(
            snapshot: reset, lastAttempt: now.addingTimeInterval(-20), now: now))
    }

    @Test func `Codex secondary polling expires and never throttles a main or changed owner`() {
        let store = self.store(native: true)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func account(fingerprint: String = "first", active: Bool = false, live: Bool = false) -> CodexVisibleAccount {
            CodexVisibleAccount(
                id: "saved",
                email: "saved@example.com",
                authFingerprint: fingerprint,
                storedAccountID: nil,
                selectionSource: .profileHome(path: "/tmp/native-secondary-fixture"),
                isActive: active,
                isLive: live,
                canReauthenticate: false,
                canRemove: false)
        }
        let saved = account()
        let records = [CodexAccountUsageSnapshot(
            account: saved,
            snapshot: UsageSnapshot(
                primary: nil,
                secondary: nil,
                updatedAt: now.addingTimeInterval(-299)),
            error: nil,
            sourceLabel: "fixture")]
        #expect(!store.codexAccountIsDueForNativeRefresh(saved, priorSnapshots: records, now: now))
        #expect(store.codexAccountIsDueForNativeRefresh(
            saved,
            priorSnapshots: records,
            now: now.addingTimeInterval(1)))
        #expect(store.codexAccountIsDueForNativeRefresh(account(active: true), priorSnapshots: records, now: now))
        #expect(store.codexAccountIsDueForNativeRefresh(account(live: true), priorSnapshots: records, now: now))
        #expect(store.codexAccountIsDueForNativeRefresh(
            account(fingerprint: "changed"),
            priorSnapshots: records,
            now: now))
        #expect(store.codexAccountIsDueForNativeRefresh(saved, priorSnapshots: [], now: now))
    }

    @Test func `each DeepSeek account retains its own detailed usage profile while another is main`() throws {
        let store = self.store(native: true)
        store.settings.addTokenAccount(provider: .deepseek, label: "Personal", token: "fixture-personal")
        let personal = try #require(store.settings.selectedTokenAccount(for: .deepseek))
        store.settings.setDeepSeekProfileID("chrome:Personal", apiKey: personal.token)
        store.settings.addTokenAccount(provider: .deepseek, label: "Work", token: "fixture-work")
        let work = try #require(store.settings.selectedTokenAccount(for: .deepseek))
        store.settings.setDeepSeekProfileID("chrome:Work", apiKey: work.token)
        store.settings.updateProviderConfig(provider: .deepseek) { $0.cookieHeader = "fixture-work-session" }
        for (account, profile) in [(personal, "chrome:Personal"), (work, "chrome:Work")] {
            let context = store.makeFetchContext(
                provider: .deepseek, override: .init(provider: .deepseek, account: account))
            #expect(context.env[DeepSeekSettingsReader.profileIDEnvironmentKey] == profile)
            #expect(context.env[DeepSeekSettingsReader.profileScopeEnvironmentKey]
                == DeepSeekSettingsReader.profileScope(selectedTokenAccountID: account.id, apiKey: account.token))
            #expect(context.env[DeepSeekSettingsReader.platformTokenEnvironmentKey]
                == (account.id == work.id ? "fixture-work-session" : nil))
        }
        store.settings.setActiveTokenAccountIndex(0, for: .deepseek)
        #expect(store.settings.deepseekProfileID(apiKey: personal.token) == "chrome:Personal")
        store.settings.updateTokenAccount(provider: .deepseek, accountID: personal.id, token: "fixture-replaced")
        #expect(store.settings.deepseekProfileID(apiKey: "fixture-replaced").isEmpty)
    }

    @Test func `changing DeepSeek profile selection does not relabel another accounts manual session`() throws {
        let store = self.store(native: true)
        store.settings.addTokenAccount(provider: .deepseek, label: "Work", token: "fixture-work")
        let work = try #require(store.settings.selectedTokenAccount(for: .deepseek))
        store.settings.setDeepSeekProfileID("chrome:Work", apiKey: work.token)
        store.settings.updateProviderConfig(provider: .deepseek) { $0.cookieHeader = "fixture-work-session" }
        store.settings.addTokenAccount(provider: .deepseek, label: "Personal", token: "fixture-personal")
        let personal = try #require(store.settings.selectedTokenAccount(for: .deepseek))
        store.settings.setDeepSeekProfileID("chrome:Personal", apiKey: personal.token)
        let context = store.makeFetchContext(
            provider: .deepseek, override: .init(provider: .deepseek, account: personal))
        for key in DeepSeekSettingsReader.platformTokenEnvironmentKeys {
            #expect(context.env[key] == nil)
        }
        let workContext = store.makeFetchContext(
            provider: .deepseek, override: .init(provider: .deepseek, account: work))
        #expect(workContext.env[DeepSeekSettingsReader.platformTokenEnvironmentKey] == "fixture-work-session")
        #expect(workContext.env[DeepSeekSettingsReader.profileIDEnvironmentKey] == "chrome:Work")
    }

    @Test func `DeepSeek bindings migrate legacy selections and survive configuration sync`() throws {
        let store = self.store(native: true)
        store.settings.addTokenAccount(provider: .deepseek, label: "Work", token: "fixture-work")
        let work = try #require(store.settings.selectedTokenAccount(for: .deepseek))
        let workScope = try #require(DeepSeekSettingsReader.profileScope(
            selectedTokenAccountID: work.id, apiKey: work.token))
        store.settings.updateProviderConfig(provider: .deepseek) {
            $0.deepseekProfileID = "chrome:Work"
            $0.deepseekProfileScope = workScope
            $0.cookieHeader = "fixture-work-session"
        }
        store.settings.addTokenAccount(provider: .deepseek, label: "Personal", token: "fixture-personal")
        let personal = try #require(store.settings.selectedTokenAccount(for: .deepseek))
        store.settings.setDeepSeekProfileID("chrome:Personal", apiKey: personal.token)
        let stored = try #require(store.settings.providerConfig(for: .deepseek))
        let restored = try JSONDecoder().decode(ProviderConfig.self, from: JSONEncoder().encode(stored))
        let payload = try JSONDecoder().decode(
            ProviderIntentPayload.self, from: JSONEncoder().encode(ProviderIntentPayload(config: restored)))
        let synced = try payload.applying(to: restored, secretFields: [:], canEnable: { _, _ in true })
        #expect(synced.deepseekProfileID(forScope: workScope) == "chrome:Work")
        let workEnvironment = ProviderEnvironmentResolver.resolve(
            base: [:], provider: .deepseek, config: synced, selectedAccount: work)
        #expect(workEnvironment[DeepSeekSettingsReader.profileIDEnvironmentKey] == "chrome:Work")
        #expect(workEnvironment[DeepSeekSettingsReader.platformTokenEnvironmentKey] == "fixture-work-session")
        let personalEnvironment = ProviderEnvironmentResolver.resolve(
            base: [:], provider: .deepseek, config: synced, selectedAccount: personal)
        #expect(personalEnvironment[DeepSeekSettingsReader.profileIDEnvironmentKey] == "chrome:Personal")
        #expect(personalEnvironment[DeepSeekSettingsReader.platformTokenEnvironmentKey] == nil)
        var olderPayload = payload
        olderPayload.deepseekProfileBindings = nil
        olderPayload.deepseekPlatformTokenScopes = nil
        let preserved = try olderPayload.applying(to: synced, secretFields: [:], canEnable: { _, _ in true })
        #expect(preserved.deepseekProfileBindings == synced.deepseekProfileBindings)
        #expect(preserved.deepseekPlatformTokenScopes == synced.deepseekPlatformTokenScopes)
        olderPayload.deepseekProfileBindings = [:]
        olderPayload.deepseekPlatformTokenScopes = [:]
        let cleared = try olderPayload.applying(to: synced, secretFields: [:], canEnable: { _, _ in true })
        #expect(cleared.deepseekProfileBindings == [:])
        #expect(cleared.deepseekPlatformTokenScopes == [:])
    }

    @Test func `DeepSeek automatic profile returns after removing the last saved account`() throws {
        for apiKey in [nil, "fixture-ambient"] as [String?] {
            let store = self.store(native: true)
            store.settings.setDeepSeekProfileID("chrome:Automatic", apiKey: apiKey)
            store.settings.addTokenAccount(provider: .deepseek, label: "Saved", token: "fixture-saved")
            let saved = try #require(store.settings.selectedTokenAccount(for: .deepseek))
            store.settings.setDeepSeekProfileID("chrome:Saved", apiKey: saved.token)
            store.settings.updateProviderConfig(provider: .deepseek) { $0.cookieHeader = "fixture-saved-session" }
            store.settings.removeTokenAccount(provider: .deepseek, accountID: saved.id)
            #expect(store.settings.deepseekProfileID(apiKey: apiKey) == "chrome:Automatic")
            let base = apiKey.map { [DeepSeekSettingsReader.apiKeyEnvironmentKey: $0] } ?? [:]
            let environment = ProviderEnvironmentResolver.resolve(
                base: base,
                provider: .deepseek,
                config: store.settings.providerConfig(for: .deepseek),
                selectedAccount: nil)
            #expect(environment[DeepSeekSettingsReader.profileIDEnvironmentKey] == "chrome:Automatic")
            #expect(environment[DeepSeekSettingsReader.profileScopeEnvironmentKey]
                == DeepSeekSettingsReader.profileScope(selectedTokenAccountID: nil, apiKey: apiKey))
            #expect(environment[DeepSeekSettingsReader.platformTokenEnvironmentKey] == nil)
        }
    }

    @Test func `DeepSeek standalone browser balance retains its unscoped manual session`() {
        let store = self.store(native: true)
        store.settings.updateProviderConfig(provider: .deepseek) { $0.cookieHeader = "fixture-browser-session" }
        store.settings.setDeepSeekProfileID("chrome:Default", apiKey: nil)
        let environment = ProviderEnvironmentResolver.resolve(
            base: [:], provider: .deepseek, config: store.settings.providerConfig(for: .deepseek), selectedAccount: nil)
        #expect(environment[DeepSeekSettingsReader.platformTokenEnvironmentKey] == "fixture-browser-session")
        #expect(environment[DeepSeekSettingsReader.profileIDEnvironmentKey] == "chrome:Default")
    }

    private func store(native: Bool) -> UsageStore {
        let settings = testSettingsStore(
            suiteName: "NativeAllAccountMonitoring", userDefaults: InMemoryUserDefaults(), nativeDesignEnabled: native)
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        enableTestProviders([.cursor, .codex, .claude], settings: settings)
        return UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
    }
}
