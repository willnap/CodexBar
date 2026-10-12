import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct NativeOrbitQuotaCompletenessTests {
    private let now = Date(timeIntervalSince1970: 1_786_363_200)

    @Test func `quota labels retain provider roles and measured cadences`() {
        let cases: [(provider: UsageProvider, titles: [String], minutes: [Int])] = [
            (.codex, ["Session", "Weekly", "Additional"], [300, 10080, 0]),
            (.claude, ["Session", "Weekly", "Sonnet"], [300, 10080, 0]),
            (.kimi, ["7-day usage", "5-hour usage", "Additional"], [10080, 300, 0]),
            (.langdock, ["Session", "Weekly", "Additional"], [300, 10080, 0]),
        ]
        for fixture in cases {
            let snapshot = UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 20, windowMinutes: fixture.minutes[0], resetsAt: nil, resetDescription: nil),
                secondary: RateWindow(
                    usedPercent: 30, windowMinutes: fixture.minutes[1], resetsAt: nil, resetDescription: nil),
                tertiary: RateWindow(
                    usedPercent: 40, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                extraRateWindows: [.init(
                    id: "measured-extra",
                    title: "Measured extra",
                    window: RateWindow(usedPercent: 50, windowMinutes: 1440, resetsAt: nil, resetDescription: nil))],
                updatedAt: self.now)
            let windows = UsageStore.nativeOrbitQuotaWindows(provider: fixture.provider, snapshot: snapshot)
            #expect(windows.map(\.id) == ["primary", "secondary", "tertiary", "measured-extra"])
            #expect(windows.map(\.title) == fixture.titles + ["Measured extra"])
            let samples = UsageStore.nativeOrbitQuotaSamples(provider: fixture.provider, snapshot: snapshot)
            #expect(samples.map(\.windowMinutes) == fixture.minutes + [1440])
            #expect(samples.map(\.entry.usedPercent) == [20, 30, 40, 50])
        }
    }

    @Test func `native measured overage survives persistence while legacy utilization stays normalized`() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-quota-overage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let captured = self.now.addingTimeInterval(0.125)
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 125, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            extraRateWindows: [.init(
                id: "measured-extra",
                title: "Measured extra",
                window: RateWindow(usedPercent: 140, windowMinutes: nil, resetsAt: nil, resetDescription: nil))],
            updatedAt: captured)
        let store = self.store()
        await store.recordPlanUtilizationHistorySample(provider: .codex, snapshot: snapshot, now: captured)
        let histories = try #require(store.planUtilizationHistory[.codex]?.unscoped)
        let primary = try #require(histories.first { $0.name == "nativeQuota:primary" })
        let extra = try #require(histories.first { $0.name == "nativeQuota:measured-extra" })
        #expect(primary.entries == [.init(capturedAt: captured, usedPercent: 125, resetsAt: nil)])
        #expect(extra.entries == [.init(capturedAt: captured, usedPercent: 140, resetsAt: nil)])
        #expect(histories.first { $0.name == .session }?.entries.first?.usedPercent == 100)
        let disk = PlanUtilizationHistoryStore(directoryURL: directory)
        #expect(disk.save(store.planUtilizationHistory).isEmpty)
        let restored = try #require(disk.load()[.codex]?.unscoped)
        #expect(restored.first { $0.name == "nativeQuota:primary" }?.entries == primary.entries)
        #expect(restored.first { $0.name == "nativeQuota:measured-extra" }?.entries == extra.entries)
        #expect(restored.first { $0.name == .session }?.entries.first?.usedPercent == 100)
    }

    @Test func `native quota recording works when legacy provider history is unavailable`() async {
        let store = self.store()
        #expect(!ProviderDescriptorRegistry.descriptor(for: .langdock).history.supportsPlanUtilization)
        let first = self.snapshot(at: self.now, owner: "first@example.com")
        let second = self.snapshot(at: self.now.addingTimeInterval(120), owner: "first@example.com")
        store.snapshots[.langdock] = second
        for snapshot in [first, second] {
            await store.recordPlanUtilizationHistorySample(
                provider: .langdock,
                snapshot: snapshot,
                now: snapshot.updatedAt)
        }
        let selection = store.planUtilizationHistorySelection(for: .langdock, readOnly: true)
        #expect(selection.accountKey != nil)
        #expect(selection.histories.filter(\.name.isNativeQuotaObservation).count == 4)
        #expect(selection.histories.allSatisfy { $0.entries.count == 2 })
        #expect(store.supportsPlanUtilizationHistory(for: .langdock))
        #expect(store.planUtilizationHistorySelection(for: .langdock, snapshotOverride: second).histories
            == selection.histories)
        let another = self.snapshot(at: self.now.addingTimeInterval(240), owner: "other@example.com")
        await store.recordPlanUtilizationHistorySample(provider: .langdock, snapshot: another, now: another.updatedAt)
        #expect(store.planUtilizationHistorySelection(for: .langdock, snapshotOverride: another).histories
            .allSatisfy { $0.entries.count == 1 })
        #expect(store.planUtilizationHistorySelection(for: .langdock, snapshotOverride: second).histories
            == selection.histories)
    }

    @Test func `native quotas keep a single timeline when their reset cadence changes`() throws {
        var histories: [PlanUtilizationSeriesHistory] = []
        for (index, minutes) in [nil, 300, 600, nil].enumerated() {
            let snapshot = UsageSnapshot(
                primary: RateWindow(
                    usedPercent: Double(index * 10),
                    windowMinutes: minutes,
                    resetsAt: nil,
                    resetDescription: nil),
                secondary: nil,
                updatedAt: self.now.addingTimeInterval(Double(index * 120)))
            histories = UsageStore.updatedPlanUtilizationHistories(
                existingHistories: histories,
                samples: UsageStore.nativeOrbitQuotaSamples(provider: .langdock, snapshot: snapshot)) ?? histories
        }
        #expect(histories.count == 1)
        let lane = try #require(histories.first)
        #expect(lane.name.rawValue == "nativeQuota:primary")
        #expect(lane.windowMinutes == 600)
        #expect(lane.entries.map(\.usedPercent) == [0, 10, 20, 30])
        #expect(lane.entries.map(\.capturedAt) == (0..<4).map { self.now.addingTimeInterval(Double($0 * 120)) })
    }

    @Test func `existing cadence fragments merge without changing legacy role histories`() throws {
        let earlier = PlanUtilizationHistoryEntry(capturedAt: self.now, usedPercent: 20, resetsAt: nil)
        let latest = PlanUtilizationHistoryEntry(
            capturedAt: self.now.addingTimeInterval(120), usedPercent: 30, resetsAt: nil)
        let existing = [
            PlanUtilizationSeriesHistory(name: "nativeQuota:primary", windowMinutes: 0, entries: [earlier]),
            PlanUtilizationSeriesHistory(name: "nativeQuota:primary", windowMinutes: 300, entries: [latest]),
            PlanUtilizationSeriesHistory(name: .session, windowMinutes: 300, entries: [earlier]),
            PlanUtilizationSeriesHistory(name: .session, windowMinutes: 600, entries: [latest]),
        ]
        let updated = try #require(UsageStore.updatedPlanUtilizationHistories(
            existingHistories: existing,
            samples: [.init(
                name: "nativeQuota:primary",
                windowMinutes: 600,
                entry: .init(
                    capturedAt: self.now.addingTimeInterval(240),
                    usedPercent: 40,
                    resetsAt: nil))]))
        #expect(updated.filter(\.name.isNativeQuotaObservation).count == 1)
        #expect(updated.first { $0.name.isNativeQuotaObservation }?.entries.map(\.usedPercent) == [20, 30, 40])
        #expect(updated.filter { $0.name == .session }.count == 2)
    }

    @Test func `every measured raw gauge records its quota even without a reset duration`() {
        let snapshot = self.snapshot(at: self.now, owner: "first@example.com")
        let samples = UsageStore.nativeOrbitQuotaSamples(provider: .langdock, snapshot: snapshot)
        #expect(Set(samples.map(\.name.rawValue)) == [
            "nativeQuota:primary", "nativeQuota:secondary", "nativeQuota:tertiary", "nativeQuota:additional",
        ])
        #expect(samples.first { $0.name.rawValue == "nativeQuota:tertiary" }?.windowMinutes == 0)
        #expect(samples.allSatisfy { $0.entry.capturedAt == snapshot.updatedAt })
        let gauge = NativeUsageGaugeProjection.state(provider: .langdock, snapshot: snapshot)
        #expect(gauge.resolvedWindows.filter { $0.usedFraction != nil }.allSatisfy { window in
            samples.contains { $0.name.rawValue == "nativeQuota:" + window.id }
        })
    }

    @Test func `Codex weekly only readings keep the weekly quota identity when session data arrives`() {
        let weeklyOnly = UsageSnapshot(
            primary: RateWindow(usedPercent: 20, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: self.now)
        let both = UsageSnapshot(
            primary: RateWindow(usedPercent: 30, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 100, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            updatedAt: self.now.addingTimeInterval(120))
        var histories: [PlanUtilizationSeriesHistory] = []
        for snapshot in [weeklyOnly, both] {
            histories = UsageStore.updatedPlanUtilizationHistories(
                existingHistories: histories,
                samples: UsageStore.nativeOrbitQuotaSamples(provider: .codex, snapshot: snapshot)) ?? histories
        }
        #expect(histories.count == 2)
        #expect(histories.first { $0.name.rawValue == "nativeQuota:secondary" }?.entries.map(\.usedPercent) == [
            20,
            100,
        ])
        #expect(histories.first { $0.name.rawValue == "nativeQuota:primary" }?.entries.map(\.usedPercent) == [30])
        let legacySlot = PlanUtilizationSeriesHistory(
            name: "nativeQuota:primary",
            windowMinutes: 10080,
            entries: [.init(capturedAt: self.now, usedPercent: 20, resetsAt: nil)])
        let canonical = UsageStore.nativeOrbitCanonicalQuotaHistories(provider: .codex, histories: [legacySlot])
        #expect(canonical.first?.name.rawValue == "nativeQuota:secondary")
        #expect(canonical.first?.entries == legacySlot.entries)
    }

    @Test func `Codex credit only gauge records its measured monthly source timestamp`() throws {
        let captured = self.now.addingTimeInterval(120)
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: ProviderCostSnapshot(
                used: 25,
                limit: 100,
                currencyCode: CodexExtraUsageCost.currencyCode,
                resetsAt: self.now.addingTimeInterval(86400),
                updatedAt: captured),
            updatedAt: self.now)
        let samples = UsageStore.nativeOrbitQuotaSamples(provider: .codex, snapshot: snapshot)
        #expect(samples.count == 1)
        let monthly = try #require(samples.first)
        #expect(monthly.name.rawValue == "nativeQuota:monthly")
        #expect(monthly.entry.usedPercent == 25)
        #expect(monthly.entry.capturedAt == captured)
        #expect(monthly.windowMinutes == 0)
        #expect(UsageStore.nativeOrbitQuotaLabels(provider: .codex, snapshot: snapshot)["nativeQuota:monthly"]
            == "Monthly credit limit")
        #expect(UsageStore.nativeOrbitQuotaSamples(provider: .langdock, snapshot: snapshot).isEmpty)
    }

    @Test func `Codex credit only account row gives its gauge an immediate source paired history line`() throws {
        let store = self.store()
        let account = CodexVisibleAccount(
            id: "fixture-credit-owner",
            email: "fixture@example.com",
            workspaceAccountID: "fixture-credit-owner",
            authFingerprint: "fixture-auth",
            storedAccountID: nil,
            selectionSource: .profileHome(path: "/tmp/fixture-credit-owner"),
            isActive: false,
            isLive: false,
            canReauthenticate: false,
            canRemove: false)
        let snapshot = UsageSnapshot(primary: nil, secondary: nil, updatedAt: self.now)
        let credits = CreditsSnapshot(
            remaining: 0,
            events: [],
            updatedAt: self.now,
            codexCreditLimit: .init(
                used: 25,
                limit: 100,
                remainingPercent: 75,
                resetsAt: self.now.addingTimeInterval(86400),
                updatedAt: self.now))
        store.codexAccountSnapshots = [.init(
            account: account, snapshot: snapshot, error: nil, sourceLabel: "fixture", credits: credits)]
        let projection = CodexVisibleAccountProjection(
            visibleAccounts: [account],
            activeVisibleAccountID: nil,
            liveVisibleAccountID: nil,
            hasUnreadableAddedAccountStore: false)
        let row = try #require(store.nativeOrbitCodexAccounts(projection).first)
        #expect(row.gauge.resolvedWindows.first?.id == "monthly")
        #expect(row.gauge.resolvedWindows.first?.usedFraction == 0.25)
        #expect(row.history.first { $0.name.rawValue == "nativeQuota:monthly" }?.entries.first?.usedPercent == 25)
        #expect(row.quotaWindows["nativeQuota:monthly"]?.usedPercent == 25)
        #expect(store.codexAccountSnapshots.first?.snapshot?.providerCost == nil)
    }

    @Test func `anonymous quota history survives restart without transferring to a recorded account`() async throws {
        let store = self.store()
        let first = UsageSnapshot(
            primary: RateWindow(usedPercent: 20, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: self.now)
        let second = UsageSnapshot(
            primary: RateWindow(usedPercent: 30, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: self.now.addingTimeInterval(120))
        for snapshot in [first, second] {
            await store.recordPlanUtilizationHistorySample(
                provider: .langdock,
                snapshot: snapshot,
                now: snapshot.updatedAt)
        }
        // Hourly fragments from this same unknown-owner source must not provide an indirect adoption path.
        store.planUtilizationHistory[.langdock]?.unscoped.append(.init(
            name: .session,
            windowMinutes: 300,
            entries: [first, second].map {
                .init(capturedAt: $0.updatedAt, usedPercent: $0.primary?.usedPercent ?? 0, resetsAt: nil)
            }))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = PlanUtilizationHistoryStore(directoryURL: directory)
        disk.save(store.planUtilizationHistory)
        let restarted = self.store()
        restarted.planUtilizationHistory = disk.load()
        restarted.snapshots[.langdock] = second
        let anonymous = try #require(restarted.nativeOrbitAccounts(for: .langdock).first)
        #expect(anonymous.history.first?.entries.map(\.usedPercent) == [20, 30])
        #expect(anonymous.historySourceLabel == "Account not recorded")
        let identified = self.snapshot(at: self.now.addingTimeInterval(240), owner: "first@example.com")
        await restarted.recordPlanUtilizationHistorySample(
            provider: .langdock,
            snapshot: identified,
            now: identified.updatedAt)
        #expect(restarted.planUtilizationHistorySelection(for: .langdock, snapshotOverride: identified).histories
            .filter(\.name.isNativeQuotaObservation).allSatisfy { $0.entries.count == 1 })
        #expect(!restarted.planUtilizationHistorySelection(for: .langdock, snapshotOverride: identified).histories
            .contains { $0.name == .session })
        #expect(restarted.planUtilizationHistory[.langdock]?.unscoped.first?.entries.count == 2)
        #expect(restarted.planUtilizationHistory[.langdock]?.unscoped.first { $0.name == .session }?.entries.count == 2)
        let token = ProviderTokenAccount(id: UUID(), label: "Named owner", token: "fixture", addedAt: 0, lastUsed: nil)
        await restarted.recordPlanUtilizationHistorySample(
            provider: .langdock,
            snapshot: second,
            account: token,
            now: second.updatedAt)
        #expect(restarted.planUtilizationHistorySelection(for: .langdock, account: token).histories
            .filter(\.name.isNativeQuotaObservation).allSatisfy { $0.entries.count == 1 })
        #expect(!restarted.planUtilizationHistorySelection(for: .langdock, account: token).histories
            .contains { $0.name == .session })
        let laterAnonymous = UsageSnapshot(
            primary: RateWindow(usedPercent: 40, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: self.now.addingTimeInterval(360))
        await restarted.recordPlanUtilizationHistorySample(
            provider: .langdock,
            snapshot: laterAnonymous,
            now: laterAnonymous.updatedAt)
        restarted.snapshots[.langdock] = laterAnonymous
        let latest = try #require(restarted.nativeOrbitAccounts(for: .langdock).first)
        #expect(latest.history.first?.entries.map(\.usedPercent) == [20, 30, 40])
        #expect(restarted.planUtilizationHistorySelection(for: .langdock, snapshotOverride: identified).histories
            .filter(\.name.isNativeQuotaObservation).allSatisfy { $0.entries.count == 1 })
    }

    private func snapshot(at date: Date, owner: String) -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(usedPercent: 20, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 30, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            tertiary: RateWindow(usedPercent: 40, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            extraRateWindows: [
                NamedRateWindow(id: "additional", title: "Additional quota", window: RateWindow(
                    usedPercent: 50, windowMinutes: nil, resetsAt: nil, resetDescription: nil)),
                NamedRateWindow(
                    id: "unknown",
                    title: "Unknown",
                    window: RateWindow(usedPercent: 0, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                    usageKnown: false),
            ],
            updatedAt: date,
            identity: ProviderIdentitySnapshot(
                providerID: .langdock,
                accountEmail: owner,
                accountOrganization: nil,
                loginMethod: nil))
    }

    private func store() -> UsageStore {
        let settings = testSettingsStore(
            suiteName: "NativeOrbitQuotaCompleteness", userDefaults: InMemoryUserDefaults(), nativeDesignEnabled: true)
        settings.historicalTrackingEnabled = false
        enableTestProviders([.langdock, .codex], settings: settings)
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
