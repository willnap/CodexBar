import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct NativeOrbitClaudeDataTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test(arguments: [false, true], [false, true])
    func `latest Claude quota inventory does not resurrect removed base limits`(
        ambientIsNewer: Bool, keepWeekly: Bool) throws
    {
        let session = RateWindow(usedPercent: 25, windowMinutes: 300, resetsAt: nil, resetDescription: nil)
        let weekly = RateWindow(usedPercent: 42, windowMinutes: 10080, resetsAt: nil, resetDescription: nil)
        let older = UsageSnapshot(primary: session, secondary: weekly, updatedAt: self.now)
        let newer = UsageSnapshot(
            primary: keepWeekly ? nil : session,
            secondary: keepWeekly ? weekly : nil,
            updatedAt: self.now.addingTimeInterval(60))
        let merged = try #require(UsageStore.nativeOrbitClaudeMergedSnapshot(
            adapter: ambientIsNewer ? older : newer,
            ambient: ambientIsNewer ? newer : older))
        #expect(merged.primary == (keepWeekly ? nil : session))
        #expect(merged.secondary == (keepWeekly ? weekly : nil))
        let gauge = NativeUsageGaugeProjection.state(provider: .claude, snapshot: merged)
        #expect(gauge.resolvedWindows.map(\.id) == [keepWeekly ? "secondary" : "primary"])
    }

    @Test func `Claude adjuncts require one matching active owner and reject foreign organizations`() throws {
        let owner = self.account()
        let ambient = self.snapshot()
        #expect(UsageStore.nativeOrbitClaudeOwnedAmbientSnapshot(
            account: owner, accounts: [owner], snapshot: ambient)?.updatedAt == self.now)
        for snapshot in [
            self.snapshot(email: "foreign@example.com"), self.snapshot(organization: "Other"),
            self.snapshot(organization: nil), self.snapshot(organization: "  "),
        ] {
            #expect(UsageStore.nativeOrbitClaudeOwnedAmbientSnapshot(
                account: owner, accounts: [owner], snapshot: snapshot) == nil)
        }
        #expect(UsageStore.nativeOrbitClaudeOwnedAmbientSnapshot(
            account: owner, accounts: [owner], snapshot: self.snapshot(organization: " team ")) != nil)
        #expect(UsageStore.nativeOrbitClaudeOwnedAmbientSnapshot(
            account: owner, accounts: [owner, self.account(slot: "2", active: false)], snapshot: ambient) == nil)
        let inactive = self.account(active: false)
        #expect(UsageStore.nativeOrbitClaudeOwnedAmbientSnapshot(
            account: inactive, accounts: [inactive], snapshot: ambient) == nil)
        let merged = try #require(UsageStore.nativeOrbitClaudeMergedSnapshot(
            adapter: owner.snapshot, ambient: ambient))
        #expect(merged.primary?.usedPercent == 42)
        #expect(merged.providerCost?.balance == 8)
        #expect(merged.extraRateWindows?.first?.id == "model")
        #expect(merged.updatedAt == self.now)
    }

    @Test func `a personal organization named after the email matches a reading whose scrape dropped it`() {
        // claude-swap keeps "name@example.com's Organization"; the CLI scrape drops a name that starts with the email.
        let personal = self.account(organization: "Owner@Example.com's Organization")
        for organization in [nil, "owner@example.com's Organization"] {
            #expect(UsageStore.nativeOrbitClaudeOwnedAmbientSnapshot(
                account: personal, accounts: [personal], snapshot: self.snapshot(organization: organization)) != nil)
        }
        #expect(
            UsageStore.nativeOrbitClaudeOwnedAmbientSnapshot(
                account: personal, accounts: [personal], snapshot: self.snapshot(organization: "Team")) == nil,
            "A team login of the same email is another owner")
        let team = self.account()
        #expect(UsageStore.nativeOrbitClaudeOwnedAmbientSnapshot(
            account: team,
            accounts: [team],
            snapshot: self.snapshot(organization: "owner@example.com's Organization")) == nil)
    }

    @Test func `popup retains timestamped last known Claude readings through a switch`() throws {
        let store = self.store()
        let retained = self.account(lastKnown: true)
        store.claudeSwapAccountSnapshots = [retained]
        let row = try #require(store.nativeOrbitAccounts(for: .claude).first)
        #expect(row.gauge.resolvedWindows.first?.usedFraction == 0.25)
        #expect(row.updatedAt == retained.snapshot?.updatedAt)
        #expect(row.statusText != nil)
        #expect(!row.autoSwitchEligible)
        // The column holds still while a switch is under way; each slot's reading stays its own.
        store.claudeSwapTransientState.switchPhase = .activating
        let switching = try #require(store.nativeOrbitAccounts(for: .claude).first)
        #expect(switching.gauge.resolvedWindows.first?.usedFraction == 0.25)
        #expect(switching.updatedAt == retained.snapshot?.updatedAt)
        #expect(!switching.autoSwitchEligible)
    }

    @Test func `switching retains each verified Claude adjunct until its next measurement`() throws {
        let store = self.store()
        let owner = self.account()
        let sibling = self.account(slot: "2", email: "other@example.com", active: false)
        store.claudeSwapAccountSnapshots = [owner, sibling]
        store.snapshots[.claude] = self.snapshot()
        let before = try #require(store.nativeOrbitAccounts(for: .claude).first { $0.isActive })
        #expect(before.gauge.resolvedWindows.contains { $0.id == "model" })
        #expect(before.metrics.reportedSpend?.balance == 8)

        // The adapter changes only which login is active. Its narrower payload must not erase remembered inputs.
        store.claudeSwapAccountSnapshots = [
            self.account(active: false),
            self.account(slot: "2", email: "other@example.com"),
        ]
        store.snapshots[.claude] = nil
        let switched = store.nativeOrbitAccounts(for: .claude)
        let retained = try #require(switched.first { $0.id == "claude-swap:1" })
        #expect(retained.gauge.resolvedWindows.contains { $0.id == "model" })
        #expect(retained.metrics.reportedSpend?.balance == 8)
        #expect(retained.updatedAt == self.now)
        #expect(switched.first { $0.id == "claude-swap:2" }?.metrics.reportedSpend == nil)

        // A recycled slot, changed organization, and duplicate slot cannot inherit the previous owner's adjuncts.
        for replacement in [
            self.account(email: "replacement@example.com", active: false),
            self.account(organization: "Different", active: false),
        ] {
            store.claudeSwapAccountSnapshots = [replacement]
            #expect(store.nativeOrbitAccounts(for: .claude).first?.metrics.reportedSpend == nil)
        }
        store.claudeSwapAccountSnapshots = [owner, owner]
        #expect(store.nativeOrbitAccounts(for: .claude).isEmpty)
    }

    @Test func `new Claude adjuncts replace remembered reset credits and subscription state`() throws {
        let store = self.store()
        let owner = self.account()
        store.claudeSwapAccountSnapshots = [owner]
        func reading(resets: Int, active: Bool, at date: Date) -> UsageSnapshot {
            UsageSnapshot(
                primary: nil,
                secondary: nil,
                claudeResetCredits: .init(expirations: Array(repeating: nil, count: resets), updatedAt: date),
                subscriptionIsActive: active,
                updatedAt: date,
                identity: self.snapshot().identity)
        }
        _ = store.nativeOrbitClaudePresentationSnapshot(
            for: owner, ambient: reading(resets: 1, active: false, at: self.now))
        let refreshed = try #require(store.nativeOrbitClaudePresentationSnapshot(
            for: owner, ambient: reading(resets: 2, active: true, at: self.now.addingTimeInterval(60))))
        #expect(refreshed.claudeResetCredits?.expirations.count == 2)
        #expect(refreshed.subscriptionIsActive == true)
        let retained = try #require(store.nativeOrbitClaudePresentationSnapshot(for: owner, ambient: nil))
        #expect(retained.claudeResetCredits?.expirations.count == 2)
        #expect(retained.subscriptionIsActive == true)
        let olderAdapter = self.account(usage: nil)
        let stale = ProviderAccountUsageSnapshot(
            id: olderAdapter.id,
            provider: .claude,
            displayLabel: olderAdapter.displayLabel,
            accountEmail: olderAdapter.accountEmail,
            accountOrganizationName: olderAdapter.accountOrganizationName,
            isActive: false,
            snapshot: reading(resets: 1, active: false, at: self.now),
            error: nil,
            sourceLabel: "fixture")
        store.claudeSwapAccountSnapshots = [stale]
        let afterSwitch = try #require(store.nativeOrbitClaudePresentationSnapshot(for: stale, ambient: nil))
        #expect(afterSwitch.claudeResetCredits?.expirations.count == 2)
        #expect(afterSwitch.subscriptionIsActive == true)
    }

    @Test func `newer Claude spend retains an independent balance but respects confirmed absence`() throws {
        let balance = ProviderCostSnapshot(
            used: 2, limit: 10, currencyCode: "USD", balance: 8, updatedAt: self.now)
        let spend = ProviderCostSnapshot(
            used: 3, limit: 10, currencyCode: "USD", updatedAt: self.now.addingTimeInterval(60))
        let merged = try #require(UsageStore.nativeOrbitClaudeMergedCost(spend, balance))
        #expect(merged.used == 3)
        #expect(merged.updatedAt == spend.updatedAt)
        #expect(merged.balance == 8)
        #expect(merged.balanceUpdatedAt == balance.updatedAt)
        let absent = ProviderCostSnapshot(
            used: 2,
            limit: 10,
            currencyCode: "USD",
            balance: nil,
            balanceUpdatedAt: self.now.addingTimeInterval(120),
            updatedAt: self.now)
        #expect(UsageStore.nativeOrbitClaudeMergedCost(spend, absent)?.balance == nil)
    }

    @Test func `Claude account rows cannot borrow machine totals across logins`() throws {
        let store = self.store()
        store.settings.costUsageEnabled = true
        let owner = self.account()
        let inactive = self.account(slot: "2", email: "other@example.com", active: false)
        store.claudeSwapAccountSnapshots = [owner, inactive]
        store.installCachedTokenSnapshot(self.report(), for: .claude)
        #expect(store.nativeOrbitClaudeLocalUsage(owner) == nil)
        #expect(store.nativeOrbitClaudeLocalUsage(inactive) == nil)
        let sibling = try #require(store.nativeOrbitAccounts(for: .claude).first { !$0.isActive })
        #expect(sibling.metrics.usage == nil)
        #expect(sibling.metrics.localCostUsage == nil)
        let row = try #require(store.nativeOrbitAccounts(for: .claude).first { $0.isActive })
        #expect(row.metrics.usage == nil)
        #expect(row.metrics.localCostUsage == nil)
        #expect(store.nativeOrbitClaudeLocalUsage()?.scope == .localMachine)
        store.snapshots[.claude] = self.snapshot(email: "foreign@example.com")
        #expect(store.nativeOrbitClaudeLocalUsage(owner) == nil)
        store.snapshots[.claude] = nil
        store.settings.costUsageSettingsRevision &+= 1
        #expect(store.nativeOrbitClaudeLocalUsage(owner) == nil)
    }

    @Test func `shared machine reports reject foreign and ambiguous adapter rows`() {
        let store = self.store()
        store.settings.costUsageEnabled = true
        store.installCachedTokenSnapshot(self.report(), for: .claude)
        let owner = self.account()
        store.claudeSwapAccountSnapshots = [owner]
        #expect(store.nativeOrbitClaudeLocalUsage(self.account(slot: "2")) == nil)
        #expect(store.nativeOrbitClaudeLocalUsage(self.account(provider: .codex)) == nil)
        #expect(store.nativeOrbitClaudeLocalUsage(self.account(source: "foreign")) == nil)
        store.claudeSwapAccountSnapshots = [owner, owner]
        #expect(store.nativeOrbitClaudeLocalUsage(owner) == nil)
        store.claudeSwapAccountSnapshots = [owner]
        store.claudeSwapTransientState.switchPhase = .activating
        #expect(store.nativeOrbitClaudeLocalUsage(owner) == nil)
    }

    @Test func `saved Claude token rows never inherit the machine report`() {
        let store = self.store()
        store.settings.claudeSwapEnabled = false
        store.settings.costUsageEnabled = true
        store.settings.addTokenAccount(provider: .claude, label: "First", token: "fixture-first")
        store.settings.addTokenAccount(provider: .claude, label: "Second", token: "fixture-second")
        store.installCachedTokenSnapshot(self.report(), for: .claude)
        let rows = store.nativeOrbitAccounts(for: .claude).filter { !$0.id.hasSuffix(":automatic") }
        #expect(rows.count == 2)
        for row in rows {
            #expect(row.metrics.usage == nil)
            #expect(row.metrics.localCostUsage == nil)
            #expect(row.history.isEmpty)
        }
    }

    @Test func `Claude rows retain their distinct account reports and spend`() throws {
        let store = self.store()
        store.settings.costUsageEnabled = true
        let first = self.report()
        let second = self.report(tokens: 3200, cost: 0.75)
        store.claudeSwapAccountSnapshots = [
            self.account(usage: first, spend: 2),
            self.account(slot: "2", email: "other@example.com", active: false, usage: second, spend: 7),
        ]
        store.installCachedTokenSnapshot(self.report(tokens: 9999, cost: 99), for: .claude)
        let rows = store.nativeOrbitAccounts(for: .claude)
        let main = try #require(rows.first { $0.isActive })
        let secondary = try #require(rows.first { !$0.isActive })
        #expect(main.metrics.usage == first)
        #expect(secondary.metrics.usage == second)
        #expect(main.metrics.usageScope == .account)
        #expect(secondary.metrics.usageScope == .account)
        #expect(main.metrics.reportedSpend?.used == 2)
        #expect(secondary.metrics.reportedSpend?.used == 7)
        #expect(main.metrics.localCostUsage == nil)
        #expect(secondary.metrics.localCostUsage == nil)
    }

    @Test func `accepted owner history bridge preserves earlier OAuth observations without ambient guessing`() throws {
        let store = self.store()
        let owner = self.account()
        store.claudeSwapAccountSnapshots = [owner]
        let key = try #require(UsageStore.nativeOrbitClaudeHistoryKey(owner))
        let earlier = PlanUtilizationSeriesHistory(name: "nativeQuota:primary", windowMinutes: 300, entries: [
            .init(capturedAt: self.now.addingTimeInterval(-7200), usedPercent: 12, resetsAt: nil),
        ])
        var buckets = PlanUtilizationHistoryBuckets(
            preferredAccountKey: "opaque-unrelated", unscoped: [earlier], accounts: ["opaque-unrelated": [earlier]])
        store.planUtilizationHistory[.claude] = buckets
        #expect(store.nativeOrbitClaudeHistory(owner, ambient: self.snapshot()).isEmpty)
        store.bridgeNativeClaudeHistory(
            snapshot: self.snapshot(email: "foreign@example.com"),
            histories: [earlier],
            buckets: &buckets)
        #expect(buckets.accounts[key] == nil)
        store.bridgeNativeClaudeHistory(snapshot: self.snapshot(), histories: [earlier], buckets: &buckets)
        #expect(buckets.accounts[key] == [earlier])
        #expect(buckets.unscoped == [earlier])
        #expect(buckets.preferredAccountKey == "opaque-unrelated")
        store.planUtilizationHistory[.claude] = buckets
        #expect(store.nativeOrbitClaudeHistory(owner, ambient: nil) == [earlier])
    }

    private func account(
        slot: String = "1",
        email: String = "owner@example.com",
        organization: String = "Team",
        active: Bool = true,
        lastKnown: Bool = false,
        provider: UsageProvider = .claude,
        source: String = "claude-swap",
        usage: CostUsageTokenSnapshot? = nil,
        spend: Double? = nil) -> ProviderAccountUsageSnapshot
    {
        ProviderAccountUsageSnapshot(
            id: .init(source: source, opaqueID: slot),
            provider: provider,
            displayLabel: "Fixture",
            accountEmail: email,
            accountOrganizationName: organization,
            isActive: active,
            usesLastKnownUsage: lastKnown,
            snapshot: UsageSnapshot(
                primary: RateWindow(usedPercent: 25, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                providerCost: spend.map { .init(used: $0, limit: 100, currencyCode: "USD", updatedAt: self.now) },
                costUsage: usage,
                updatedAt: self.now.addingTimeInterval(-3600),
                identity: .init(
                    providerID: .claude,
                    accountEmail: email,
                    accountOrganization: nil,
                    loginMethod: "claude-swap")),
            error: nil,
            sourceLabel: "fixture")
    }

    private func snapshot(email: String = "owner@example.com", organization: String? = "Team") -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(usedPercent: 42, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            extraRateWindows: [.init(
                id: "model",
                title: "Model",
                window: RateWindow(
                    usedPercent: 20, windowMinutes: 10080, resetsAt: nil, resetDescription: nil))],
            providerCost: .init(used: 2, limit: 10, currencyCode: "USD", balance: 8, updatedAt: self.now),
            updatedAt: self.now,
            identity: .init(
                providerID: .claude,
                accountEmail: email,
                accountOrganization: organization,
                loginMethod: "Pro"))
    }

    private func report(tokens: Int = 1200, cost: Double = 0.25) -> CostUsageTokenSnapshot {
        CostUsageTokenSnapshot(
            sessionTokens: tokens,
            sessionCostUSD: cost,
            last30DaysTokens: tokens,
            last30DaysCostUSD: cost,
            daily: [],
            updatedAt: self.now)
    }

    private func store() -> UsageStore {
        let settings = testSettingsStore(
            suiteName: "native-claude-data", userDefaults: InMemoryUserDefaults(), nativeDesignEnabled: true)
        enableTestProviders([.claude], settings: settings)
        settings.claudeSwapEnabled = true
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
