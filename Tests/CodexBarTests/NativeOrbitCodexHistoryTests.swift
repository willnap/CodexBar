import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct NativeOrbitCodexHistoryTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func `pure history rendering retains verified legacy continuity and every native observation`() throws {
        let store = self.store()
        let account = self.account(workspace: "one")
        let projection = self.projection([account])
        let key = try #require(CodexHistoryOwnership.canonicalKey(for: .providerAccount(id: "one")))
        let legacyKey = UsageStore.codexLegacyPlanUtilizationEmailHashKey(for: account.email)
        let raw = PlanUtilizationSeriesHistory(
            name: "nativeQuota:primary",
            windowMinutes: 300,
            entries: [
                .init(
                    capturedAt: self.now.addingTimeInterval(-120),
                    usedPercent: 50,
                    resetsAt: nil),
                .init(
                    capturedAt: self.now.addingTimeInterval(-60),
                    usedPercent: 55,
                    resetsAt: nil),
                .init(
                    capturedAt: self.now,
                    usedPercent: 60,
                    resetsAt: nil),
            ])
        let old = self.legacy()
        let buckets = PlanUtilizationHistoryBuckets(accounts: [
            key: [raw],
            legacyKey: [old],
        ])
        store.planUtilizationHistory[.codex] = buckets
        let revision = store.planUtilizationHistoryRevision
        let history = store.nativeOrbitCodexHistory(
            account: account,
            projection: projection,
            snapshot: nil,
            canonicalKey: key)
        #expect(history.contains(old))
        #expect(history.first { $0.name.isNativeQuotaObservation } == raw)
        #expect(store.planUtilizationHistory[.codex] == buckets)
        #expect(store.planUtilizationHistoryRevision == revision)
    }

    @Test func `shared email across workspaces cannot borrow a legacy email history`() throws {
        let store = self.store()
        let account = self.account(workspace: "one")
        let key = try #require(CodexHistoryOwnership.canonicalKey(for: .providerAccount(id: "one")))
        store.planUtilizationHistory[.codex] = PlanUtilizationHistoryBuckets(accounts: [
            UsageStore.codexLegacyPlanUtilizationEmailHashKey(for: account.email): [self.legacy()],
        ])
        #expect(store.nativeOrbitCodexHistory(
            account: account,
            projection: self.projection([account, self.account(workspace: "two")]),
            snapshot: nil,
            canonicalKey: key).isEmpty)
    }

    @Test func `missing cached inventory cannot recover unscoped or opaque timelines`() throws {
        let store = self.store()
        let account = self.account(workspace: "one")
        let key = try #require(CodexHistoryOwnership.canonicalKey(for: .providerAccount(id: "one")))
        let canonical = self.legacy()
        let unscoped = PlanUtilizationSeriesHistory(
            name: .weekly,
            windowMinutes: 10080,
            entries: [
                .init(
                    capturedAt: self.now,
                    usedPercent: 99,
                    resetsAt: self.now.addingTimeInterval(3600)),
            ])
        store.planUtilizationHistory[.codex] = PlanUtilizationHistoryBuckets(
            unscoped: [unscoped],
            accounts: [key: [canonical]])
        #expect(store.nativeOrbitCodexHistory(
            account: account,
            projection: self.projection([account]),
            snapshot: nil,
            canonicalKey: key) == [canonical])
        let context = UsageStore.nativeOrbitCodexHistoryOwnership(
            account: account,
            projection: self.projection([account]),
            snapshot: nil,
            cached: nil)
        #expect(context.hasAdjacentMultiAccountVeto)
    }

    @Test func `a marked local archive cannot be adopted through single account continuity`() throws {
        let store = self.store()
        let key = try #require(CodexHistoryOwnership.canonicalKey(for: .providerAccount(id: "one")))
        let archive = PlanUtilizationSeriesHistory(name: "nativeQuota:primary", windowMinutes: 300, entries: [
            .init(capturedAt: self.now, usedPercent: 93, resetsAt: self.now.addingTimeInterval(3600)),
        ])
        let oldAnonymous = PlanUtilizationSeriesHistory(name: .weekly, windowMinutes: 10080, entries: [
            .init(capturedAt: self.now, usedPercent: 83, resetsAt: self.now.addingTimeInterval(3600)),
        ])
        let owned = self.legacy()
        var buckets = PlanUtilizationHistoryBuckets(
            preferredAccountKey: key, unscoped: [archive, oldAnonymous], accounts: [key: [owned]])
        let original = buckets
        let ownership = CodexOwnershipContext(
            canonicalKey: key,
            canonicalEmailHashKey: nil,
            historicalLegacyEmailHash: nil,
            planUtilizationLegacyEmailHash: nil,
            currentWeeklyResetAt: nil,
            hasAdjacentMultiAccountVeto: false,
            hasAdjacentEmailScopeAmbiguity: false)
        #expect(store.materializeCodexPlanUtilizationHistoryIfNeeded(
            into: key,
            ownership: ownership,
            shouldAdoptUnscopedHistory: true,
            providerBuckets: &buckets) == key)
        #expect(buckets == original)
    }

    private func legacy() -> PlanUtilizationSeriesHistory {
        PlanUtilizationSeriesHistory(
            name: .session,
            windowMinutes: 300,
            entries: [
                .init(
                    capturedAt: self.now.addingTimeInterval(-7200),
                    usedPercent: 20,
                    resetsAt: nil),
            ])
    }

    private func account(workspace: String) -> CodexVisibleAccount {
        CodexVisibleAccount(
            id: workspace,
            email: "fixture@example.com",
            workspaceAccountID: workspace,
            storedAccountID: nil,
            selectionSource: .profileHome(path: "/tmp/native-" + workspace),
            isActive: false,
            isLive: false,
            canReauthenticate: false,
            canRemove: false)
    }

    private func projection(_ accounts: [CodexVisibleAccount]) -> CodexVisibleAccountProjection {
        CodexVisibleAccountProjection(
            visibleAccounts: accounts,
            activeVisibleAccountID: nil,
            liveVisibleAccountID: nil,
            hasUnreadableAddedAccountStore: false)
    }

    private func store() -> UsageStore {
        let settings = testSettingsStore(
            suiteName: "NativeOrbitCodexHistory",
            userDefaults: InMemoryUserDefaults(),
            nativeDesignEnabled: true)
        enableTestProviders(
            [.codex],
            settings: settings)
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
