import CryptoKit
import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
@Suite(.serialized)
struct NativeOrbitCodexLocalAttributionTests {
    /// 2026-10-12 12:00:00 UTC.
    private let noon = Date(timeIntervalSince1970: 1_791_806_400)

    @Test
    func `shared local sessions split between accounts by the window each request reported`() async throws {
        let store = try UsageStoreSpendDashboardCodexCostCatchUpTests.makeStore(suite: "local-attribution")
        let live = self.account(id: "live", live: true)
        let managed = self.account(id: "managed", live: false)
        let windowLive = self.noon.addingTimeInterval(5 * 86400)
        let windowManaged = self.noon.addingTimeInterval(3 * 86400)
        // The live home holds both accounts' rollouts; the managed probe home holds none.
        let liveHome = self.report(slices: [
            (-7200, 1000, 2.5), (-3600, 300, 1.0), (-60, 50, 0.25),
        ])
        store.spendDashboardPublication = self.publication(
            zone: store.settings.costUsageBucketTimeZoneIdentifier,
            reports: ["codex:live": liveHome, "codex:managed": self.report(slices: [])])
        store.nativeCodexSessionAttribution.update(timeline: NativeCodexSessionWindowTimeline(
            events: [
                (time: self.noon.addingTimeInterval(-7200), weeklyReset: windowManaged),
                (time: self.noon.addingTimeInterval(-3600), weeklyReset: windowLive),
                (time: self.noon.addingTimeInterval(-60), weeklyReset: windowLive),
            ],
            coverageStart: self.noon.addingTimeInterval(-32 * 86400),
            coverageEnd: self.noon))
        let contexts = [
            (account: live, history: [self.weeklyLane(windowLive)], snapshot: UsageSnapshot?.none),
            (account: managed, history: [self.weeklyLane(windowManaged)], snapshot: UsageSnapshot?.none),
        ]

        // Until the background pass lands, neither account may claim the shared live home.
        let pending = store.nativeOrbitCodexLocalUsages(contexts)
        #expect(pending["live"] == nil)
        #expect(pending["managed"] == nil)
        await store.nativeCodexSessionAttribution.waitForPendingAttribution()

        let usages = store.nativeOrbitCodexLocalUsages(contexts)
        let liveUsage = try #require(usages["live"])
        let managedUsage = try #require(usages["managed"])
        #expect(liveUsage.isAccountAttributed)
        #expect(liveUsage.scope == .localMachine)
        #expect(liveUsage.snapshot.quotaSlices.map(\.totalTokens) == [300, 50])
        #expect(managedUsage.snapshot.quotaSlices.map(\.totalTokens) == [1000])
        let liveSpend = NativeOrbitAccountMetrics.make(
            provider: .codex, snapshot: nil, usage: nil, now: self.noon, localUsage: liveUsage)
            .summary(days: 1, now: self.noon)
        #expect(liveSpend.cost == 1.25)
        #expect(liveSpend.tokens == 350)
        let managedSpend = NativeOrbitAccountMetrics.make(
            provider: .codex, snapshot: nil, usage: nil, now: self.noon, localUsage: managedUsage)
            .summary(days: 1, now: self.noon)
        #expect(managedSpend.cost == 2.5)
        // Rendering again with unchanged inputs reuses the finished pass.
        #expect(store.nativeOrbitCodexLocalUsages(contexts)["live"]?.snapshot == liveUsage.snapshot)
    }

    @Test
    func `the persisted session archive attributes spend before this launch drains every rollout`() async throws {
        let store = try UsageStoreSpendDashboardCodexCostCatchUpTests.makeStore(suite: "local-archive-seed")
        let live = self.account(id: "live", live: true)
        let managed = self.account(id: "managed", live: false)
        let windowLive = self.noon.addingTimeInterval(5 * 86400)
        let windowManaged = self.noon.addingTimeInterval(3 * 86400)
        store.spendDashboardPublication = self.publication(
            zone: store.settings.costUsageBucketTimeZoneIdentifier,
            reports: ["codex:live": self.report(slices: [(-7200, 1000, 2.5), (-60, 50, 0.25)])])
        var buckets = PlanUtilizationHistoryBuckets()
        buckets.unscoped = [PlanUtilizationSeriesHistory(name: "nativeQuota:secondary", windowMinutes: 10080, entries: [
            PlanUtilizationHistoryEntry(
                capturedAt: self.noon.addingTimeInterval(-7200),
                usedPercent: 40,
                resetsAt: windowManaged),
            PlanUtilizationHistoryEntry(
                capturedAt: self.noon.addingTimeInterval(-60),
                usedPercent: 3,
                resetsAt: windowLive),
        ])]
        store.planUtilizationHistory[.codex] = buckets
        store.planUtilizationHistoryLoaded = true
        let contexts = [
            (account: live, history: [self.weeklyLane(windowLive)], snapshot: UsageSnapshot?.none),
            (account: managed, history: [self.weeklyLane(windowManaged)], snapshot: UsageSnapshot?.none),
        ]
        _ = store.nativeOrbitCodexLocalUsages(contexts)
        await store.nativeCodexSessionAttribution.waitForTimelineSeed()
        #expect(store.nativeCodexSessionAttribution.timeline?.eventCount == 2)
        _ = store.nativeOrbitCodexLocalUsages(contexts)
        await store.nativeCodexSessionAttribution.waitForPendingAttribution()
        let usages = store.nativeOrbitCodexLocalUsages(contexts)
        #expect(usages["live"]?.snapshot.quotaSlices.map(\.totalTokens) == [50])
        #expect(usages["managed"]?.snapshot.quotaSlices.map(\.totalTokens) == [1000])
    }

    @Test
    func `a single visible account keeps its whole live home with machine provenance`() throws {
        let store = try UsageStoreSpendDashboardCodexCostCatchUpTests.makeStore(suite: "local-single")
        let live = self.account(id: "live", live: true)
        let zone = store.settings.costUsageBucketTimeZoneIdentifier
        let home = try #require(CodexHomeScope.normalizedHomePath(store.nativeCodexHomePath(live)))
        // The ownership digest binds the cached report to this account's home, credentials, and bucket zone.
        let material = [live.id, "live", home, "fingerprint-live", zone].joined(separator: "\u{0}")
        let digest = SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
        store.spendDashboardPublication = self.publication(
            zone: zone,
            reports: ["codex:live": self.report(slices: [(-60, 50, 0.25)])],
            identities: ["live|\(digest)"])
        store.nativeCodexSessionAttribution.update(timeline: NativeCodexSessionWindowTimeline(
            events: [], coverageStart: self.noon.addingTimeInterval(-86400), coverageEnd: self.noon))
        let usages = store.nativeOrbitCodexLocalUsages([(account: live, history: [], snapshot: nil)])
        let usage = try #require(usages["live"])
        #expect(!usage.isAccountAttributed)
        #expect(usage.scope == .localMachine)
        #expect(usage.snapshot.quotaSlices.map(\.totalTokens) == [50])
    }

    @Test
    func `cold caches finish once at the accelerated rate only when unconstrained`() {
        let cold = CostUsageFetcher.CodexScanCatchUpStatus(
            pending: true, progressKey: "cold", completedFiles: 349, totalFiles: 1420)
        let warm = CostUsageFetcher.CodexScanCatchUpStatus(
            pending: true,
            progressKey: "warm",
            completedFiles: 1419,
            totalFiles: 1420,
            staleSnapshotUpdatedAt: self.noon)
        let done = CostUsageFetcher.CodexScanCatchUpStatus(
            pending: false, progressKey: "done", completedFiles: 1420, totalFiles: 1420)
        func mode(
            _ statuses: [CostUsageFetcher.CodexScanCatchUpStatus],
            requested: CodexCostCatchUpMode = .automatic,
            power: CodexCostCatchUpPowerSource = .ac,
            lowPower: Bool = false,
            thermal: ProcessInfo.ThermalState = .nominal) -> CodexCostCatchUpMode
        {
            CodexCostCatchUpPolicy.coldCacheMode(
                requested: requested,
                statuses: statuses,
                powerSource: power,
                lowPowerModeEnabled: lowPower,
                thermalState: thermal)
        }
        #expect(CodexCostCatchUpPolicy.isColdCache(cold))
        #expect(!CodexCostCatchUpPolicy.isColdCache(warm))
        // A small cold home finishes within a few automatic bursts.
        #expect(!CodexCostCatchUpPolicy.isColdCache(.init(
            pending: true, progressKey: "small", completedFiles: 0, totalFiles: 1)))
        #expect(mode([warm, cold]) == .accelerated)
        #expect(mode([warm, done]) == .automatic)
        #expect(mode([cold], power: .battery) == .automatic)
        #expect(mode([cold], power: .unknown) == .automatic)
        #expect(mode([cold], lowPower: true) == .automatic)
        #expect(mode([cold], thermal: .serious) == .automatic)
        #expect(mode([cold], thermal: .fair) == .accelerated)
        #expect(mode([CostUsageFetcher.CodexScanCatchUpStatus(pending: true, progressKey: "unknown")]) == .automatic)
    }

    @Test
    func `a rebuilt account cache switches the background catch-up to the accelerated rate`() async throws {
        let store = try UsageStoreSpendDashboardCodexCostCatchUpTests.makeStore(suite: "cold-accelerated")
        store.settings.backgroundWorkLowPowerModePreference = .off
        var sleeps: [TimeInterval] = []
        var budgets: [TimeInterval] = []
        store._test_spendDashboardCodexCostCatchUpResourceStateOverride = { (.ac, false, .nominal) }
        store._test_spendDashboardCodexCostCatchUpStatusOverride = { _ in
            .init(pending: true, progressKey: "rebuilt", completedFiles: 349, totalFiles: 1420)
        }
        store._test_codexCostCatchUpBudgetObserver = { budgets.append($0) }
        store._test_spendDashboardCodexCostCatchUpAdvanceOverride = { _, _, _ in
            .init(pending: true, progressKey: "progressed-\(budgets.count)", completedFiles: 400, totalFiles: 1420)
        }
        store._test_spendDashboardCodexCostCatchUpSleepOverride = { delay in
            sleeps.append(delay)
            if sleeps.count == 2 { throw CancellationError() }
        }
        store.startSpendDashboardCodexCostCatchUpIfNeeded(
            accounts: [UsageStoreSpendDashboardCodexCostCatchUpTests.account(id: "live", cacheIdentity: "cache-live")])
        let task = try #require(store.spendDashboardCodexCostCatchUpTask)
        await task.value
        #expect(store.spendDashboardCodexCostCatchUpMode == .accelerated)
        #expect(sleeps == [0, 0])
        #expect(budgets.allSatisfy { $0 == CodexCostCatchUpMode.accelerated.scanDurationPerRefresh() })
    }

    @Test
    func `a warm cache tail stays on the automatic duty cycle`() async throws {
        let store = try UsageStoreSpendDashboardCodexCostCatchUpTests.makeStore(suite: "warm-automatic")
        store.settings.backgroundWorkLowPowerModePreference = .off
        store._test_spendDashboardCodexCostCatchUpResourceStateOverride = { (.ac, false, .nominal) }
        store._test_spendDashboardCodexCostCatchUpStatusOverride = { _ in
            .init(
                pending: true,
                progressKey: "tail",
                completedFiles: 1419,
                totalFiles: 1420,
                staleSnapshotUpdatedAt: Date(timeIntervalSince1970: 1_791_806_400))
        }
        store._test_spendDashboardCodexCostCatchUpAdvanceOverride = { _, _, _ in
            .init(pending: true, progressKey: "tail-progressed", completedFiles: 1419, totalFiles: 1420)
        }
        store._test_spendDashboardCodexCostCatchUpSleepOverride = { _ in throw CancellationError() }
        store.startSpendDashboardCodexCostCatchUpIfNeeded(
            accounts: [UsageStoreSpendDashboardCodexCostCatchUpTests.account(id: "live", cacheIdentity: "cache-live")])
        let task = try #require(store.spendDashboardCodexCostCatchUpTask)
        await task.value
        #expect(store.spendDashboardCodexCostCatchUpMode == .automatic)
    }

    private func account(id: String, live: Bool) -> CodexVisibleAccount {
        CodexVisibleAccount(
            id: id,
            email: "\(id)@example.com",
            workspaceAccountID: "workspace-\(id)",
            authFingerprint: "fingerprint-\(id)",
            storedAccountID: live ? nil : UUID(),
            selectionSource: live ? .liveSystem : .managedAccount(id: UUID()),
            isActive: live,
            isLive: live,
            canReauthenticate: false,
            canRemove: false)
    }

    private func weeklyLane(_ reset: Date) -> PlanUtilizationSeriesHistory {
        PlanUtilizationSeriesHistory(name: .weekly, windowMinutes: 10080, entries: [
            PlanUtilizationHistoryEntry(
                capturedAt: self.noon.addingTimeInterval(-600),
                usedPercent: 20,
                resetsAt: reset),
        ])
    }

    private func report(slices: [(TimeInterval, Int, Double)]) -> CostUsageTokenSnapshot {
        CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: nil,
            last30DaysCostUSD: nil,
            historyDays: 365,
            costProvenance: .listPriceEstimate,
            daily: [],
            quotaSlices: slices.map {
                CostUsageTimedEntry(timestamp: self.noon.addingTimeInterval($0.0), totalTokens: $0.1, costUSD: $0.2)
            },
            updatedAt: self.noon)
    }

    private func publication(
        zone: String,
        reports: [String: CostUsageTokenSnapshot],
        identities: [String] = []) -> SpendDashboardPublication
    {
        let ids = reports.keys.sorted()
        return SpendDashboardPublication(
            revision: 1,
            generation: 1,
            configuration: SpendDashboardConfiguration(
                costUsageEnabled: true,
                providerIDs: ["codex"],
                codexAccountIdentities: identities,
                bucketTimeZoneIdentifier: zone),
            loadedAt: self.noon,
            isRefreshing: false,
            inputs: ids.map { .init(id: $0, provider: .codex, displayName: $0, snapshot: reports[$0]!) },
            sources: ids
                .map { .init(id: $0, provider: .codex, displayName: $0, role: .subscription, state: .available) })
    }
}
