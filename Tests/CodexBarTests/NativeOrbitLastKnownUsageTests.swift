import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
@Suite(.serialized)
struct NativeOrbitLastKnownUsageTests {
    /// 2026-10-12 12:00:00 UTC.
    private let noon = Date(timeIntervalSince1970: 1_791_806_400)
    private let organization = "11111111-1111-1111-1111-111111111111"
    private let otherOrganization = "22222222-2222-2222-2222-222222222222"

    // MARK: - Persistence

    @Test func `persisted reports round trip every reading the dial derives`() throws {
        let report = self.richReport()
        let usage = NativeOrbitLocalUsage(
            snapshot: report,
            scope: .localMachine,
            bucketTimeZoneIdentifier: "Europe/London",
            isAccountAttributed: true,
            isStale: false,
            unattributedDays: ["2026-10-11"])
        let directory = try self.temporaryDirectory()
        #expect(NativeOrbitLastKnownUsageFile.save(
            ["owner": usage],
            provider: .codex,
            directory: directory,
            savedAt: self.noon))
        let loaded = try #require(NativeOrbitLastKnownUsageFile.load(
            .codex, directory: directory, now: self.noon, maximumAge: 86400)["owner"])
        let restored = loaded.snapshot
        #expect(restored.daily.count == report.daily.count)
        // Daily entries keep their model breakdowns (incomplete requests, invalid prices) and coverage counters.
        #expect(restored.daily.dropLast() == report.daily.dropLast())
        let poisoned = try #require(restored.daily.last?.modelBreakdowns?.first?.costUSD)
        #expect(poisoned.isNaN)
        #expect(restored.quotaSlices == report.quotaSlices)
        #expect(restored.last30DaysTokens == report.last30DaysTokens)
        #expect(restored.last30DaysCostUSD == report.last30DaysCostUSD)
        #expect(restored.last30DaysRequests == report.last30DaysRequests)
        #expect(restored.currencyCode == report.currencyCode)
        #expect(restored.historyDays == report.historyDays)
        #expect(restored.historyCoverageIsEstablished == report.historyCoverageIsEstablished)
        #expect(restored.historyScanIsPartial == report.historyScanIsPartial)
        #expect(restored.historyLabel == report.historyLabel)
        #expect(restored.bucketTimeZoneIdentifier == report.bucketTimeZoneIdentifier)
        #expect(restored.coverageThrough == report.coverageThrough)
        #expect(restored.costProvenance == report.costProvenance)
        #expect(restored.updatedAt == report.updatedAt)
        #expect(loaded.scope == .localMachine)
        #expect(loaded.bucketTimeZoneIdentifier == "Europe/London")
        #expect(loaded.isAccountAttributed)
        #expect(!loaded.isStale)
        #expect(loaded.unattributedDays == ["2026-10-11"])

        // Every period summary and hovered instant reads the same from the restored report.
        let original = NativeOrbitAccountMetrics.make(
            provider: .codex, snapshot: nil, usage: nil, now: self.noon, localUsage: usage)
        let copy = NativeOrbitAccountMetrics.make(
            provider: .codex, snapshot: nil, usage: nil, now: self.noon, localUsage: loaded)
        for days in [1, 7, 30] {
            self.expectSameSummary(
                original.summary(days: days, now: self.noon),
                copy.summary(days: days, now: self.noon))
            for offset: TimeInterval in [-1800, -5 * 3600, -26 * 3600, -6 * 86400] {
                let instant = self.noon.addingTimeInterval(offset)
                self.expectSameSummary(
                    original.at(instant, observedAt: self.noon).summary(days: days, now: instant),
                    copy.at(instant, observedAt: self.noon).summary(days: days, now: instant))
            }
        }
    }

    @Test func `other versions, foreign providers, old readings and damaged files are ignored`() throws {
        let directory = try self.temporaryDirectory()
        let usage = NativeOrbitLocalUsage(
            snapshot: self.richReport(),
            scope: .localMachine,
            bucketTimeZoneIdentifier: nil)
        #expect(NativeOrbitLastKnownUsageFile.save(
            ["owner": usage],
            provider: .kimi,
            directory: directory,
            savedAt: self.noon))
        let url = NativeOrbitLastKnownUsageFile.url(for: .kimi, in: directory)
        #expect(NativeOrbitLastKnownUsageFile.load(.kimi, directory: directory, now: self.noon, maximumAge: 86400)
            .count == 1)
        // Owner-only file; only opaque digests name the entries.
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)

        // A reading older than the maximum age describes no selectable period.
        #expect(NativeOrbitLastKnownUsageFile.load(
            .kimi, directory: directory, now: self.noon.addingTimeInterval(3 * 86400), maximumAge: 86400).isEmpty)

        // Another schema version is not decoded as this one.
        let data = try Data(contentsOf: url)
        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["version"] = NativeOrbitLastKnownUsageDocument.currentVersion + 1
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        #expect(NativeOrbitLastKnownUsageFile.load(.kimi, directory: directory, now: self.noon, maximumAge: 86400)
            .isEmpty)

        // A document written for one provider never feeds another.
        json["version"] = NativeOrbitLastKnownUsageDocument.currentVersion
        json["provider"] = UsageProvider.codex.rawValue
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        #expect(NativeOrbitLastKnownUsageFile.load(.kimi, directory: directory, now: self.noon, maximumAge: 86400)
            .isEmpty)

        try Data("not json".utf8).write(to: url)
        #expect(NativeOrbitLastKnownUsageFile.load(.kimi, directory: directory, now: self.noon, maximumAge: 86400)
            .isEmpty)
    }

    @Test func `remembered readings survive a relaunch and never replace a newer live one`() async throws {
        let directory = try self.temporaryDirectory()
        let report = self.richReport()
        let first = NativeOrbitLastKnownUsageStore(directory: directory)
        first.record(.kimi, owner: "owner", usage: NativeOrbitLocalUsage(
            snapshot: report, scope: .localMachine, bucketTimeZoneIdentifier: "UTC"))
        first.flushSynchronously()

        let relaunched = NativeOrbitLastKnownUsageStore(directory: directory)
        relaunched.loadPersisted(now: self.noon)
        await relaunched.waitForLoad()
        let restored = try #require(relaunched.usage(.kimi, owner: "owner"))
        #expect(restored.lastKnownAt == report.updatedAt)
        // A remembered total is a lower bound of the account's current total.
        #expect(restored.usage.isStale)
        #expect(restored.usage.snapshot.quotaSlices == report.quotaSlices)
        #expect(relaunched.usage(.kimi, owner: "other") == nil)
        #expect(relaunched.usage(.codex, owner: "owner") == nil)
        #expect(relaunched.revision == 1)

        let newer = self.richReport(updatedAt: self.noon.addingTimeInterval(600))
        let racing = NativeOrbitLastKnownUsageStore(directory: directory)
        racing.record(.kimi, owner: "owner", usage: NativeOrbitLocalUsage(
            snapshot: newer, scope: .localMachine, bucketTimeZoneIdentifier: "UTC"))
        racing.loadPersisted(now: self.noon)
        await racing.waitForLoad()
        #expect(racing.usage(.kimi, owner: "owner")?.lastKnownAt == newer.updatedAt)
    }

    // MARK: - Claude

    @Test func `a remembered Claude report reaches only its own organization owner`() throws {
        let store = self.claudeStore()
        let owner = self.claudeAccount(slot: "1", email: "owner@example.com", organization: self.organization)
        let other = self.claudeAccount(slot: "2", email: "other@example.com", organization: self.otherOrganization)
        store.claudeSwapAccountSnapshots = [owner, other]
        let zone = store.settings.costUsageBucketCalendar.timeZone.identifier
        let key = try #require(UsageStore.nativeOrbitClaudeLastKnownOwner(
            account: owner, accounts: [owner, other], bucketTimeZoneIdentifier: zone))
        let report = self.richReport(zone: zone)
        store.nativeLastKnownUsage.adopt([.claude: [key: NativeOrbitLocalUsage(
            snapshot: report, scope: .localMachine, bucketTimeZoneIdentifier: zone)]])

        let restored = try #require(store.nativeOrbitClaudeResolvedLocalUsage(owner))
        #expect(restored.lastKnownAt == report.updatedAt)
        #expect(restored.usage.isStale)
        #expect(store.nativeOrbitClaudeResolvedLocalUsage(other) == nil)
        let row = try #require(store.nativeOrbitAccounts(for: .claude).first { $0.id.hasSuffix(":1") })
        #expect(row.usageLastKnownAt == report.updatedAt)
        #expect(row.metrics.summary(days: 30, now: self.noon).tokens != nil)
        #expect(store.nativeOrbitAccounts(for: .claude).first { $0.id.hasSuffix(":2") }?.usageLastKnownAt == nil)

        // The same slot now holding another organization or another login, or an organization shared by two
        // visible rows, cannot prove which account produced the transcripts.
        let moved = self.claudeAccount(slot: "1", email: "owner@example.com", organization: self.otherOrganization)
        store.claudeSwapAccountSnapshots = [moved]
        #expect(store.nativeOrbitClaudeResolvedLocalUsage(moved) == nil)
        let replaced = self.claudeAccount(slot: "1", email: "new@example.com", organization: self.organization)
        store.claudeSwapAccountSnapshots = [replaced, other]
        #expect(store.nativeOrbitClaudeResolvedLocalUsage(replaced) == nil)
        let sibling = self.claudeAccount(slot: "2", email: "other@example.com", organization: self.organization)
        store.claudeSwapAccountSnapshots = [owner, sibling]
        #expect(store.nativeOrbitClaudeResolvedLocalUsage(owner) == nil)

        // Another bucket time zone buckets the same transcripts into other days.
        store.claudeSwapAccountSnapshots = [owner, other]
        #expect(store.nativeOrbitClaudeResolvedLocalUsage(owner) != nil)
        store.settings.costUsageBucketTimeZoneIdentifier = zone == "Asia/Tokyo" ? "America/New_York" : "Asia/Tokyo"
        #expect(store.nativeOrbitClaudeResolvedLocalUsage(owner) == nil)
    }

    @Test func `live Claude publications replace remembered reports and are remembered in turn`() throws {
        let store = self.claudeStore()
        let owner = self.claudeAccount(slot: "1", email: "owner@example.com", organization: self.organization)
        store.claudeSwapAccountSnapshots = [owner]
        let zone = store.settings.costUsageBucketCalendar.timeZone.identifier
        let key = try #require(UsageStore.nativeOrbitClaudeLastKnownOwner(
            account: owner, accounts: [owner], bucketTimeZoneIdentifier: zone))
        let remembered = self.richReport(zone: zone, updatedAt: self.noon.addingTimeInterval(-3600))
        store.nativeLastKnownUsage.adopt([.claude: [key: NativeOrbitLocalUsage(
            snapshot: remembered, scope: .localMachine, bucketTimeZoneIdentifier: zone)]])
        #expect(store.nativeOrbitClaudeResolvedLocalUsage(owner)?.lastKnownAt == remembered.updatedAt)

        let live = self.richReport(zone: zone, updatedAt: self.noon)
        store.claudeOrganizationUsagePublication = ClaudeOrganizationUsagePublication(
            owners: [owner.id: self.organization], bucketTimeZoneIdentifier: zone, reports: [self.organization: live])
        let current = try #require(store.nativeOrbitClaudeResolvedLocalUsage(owner))
        #expect(current.lastKnownAt == nil)
        #expect(!current.usage.isStale)
        #expect(current.usage.snapshot.updatedAt == live.updatedAt)
        #expect(store.nativeOrbitAccounts(for: .claude).first?.usageLastKnownAt == nil)

        // A projection that served this owner is authoritative even without a report for it.
        store.claudeOrganizationUsagePublication = ClaudeOrganizationUsagePublication(
            owners: [owner.id: self.organization], bucketTimeZoneIdentifier: zone, reports: [:])
        #expect(store.nativeOrbitClaudeResolvedLocalUsage(owner) == nil)

        // While the projection is pending again, the newest live report stands in, labelled with its time.
        store.claudeOrganizationUsagePublication = nil
        #expect(store.nativeOrbitClaudeResolvedLocalUsage(owner)?.lastKnownAt == live.updatedAt)
        #expect(store.nativeLastKnownUsage.rememberedUsages(.claude)[key]?.snapshot.updatedAt == live.updatedAt)
    }

    // MARK: - Codex

    @Test func `remembered Codex attribution waits for the same account set and settled scans`() async throws {
        let store = try UsageStoreSpendDashboardCodexCostCatchUpTests.makeStore(suite: "last-known-codex")
        let managedID = try #require(UUID(uuidString: "C1C5A87B-9DF8-4806-BE68-D5292DC10B9B"))
        let live = self.codexAccount(id: "live", source: .liveSystem, storedAccountID: managedID)
        let profile = self.codexAccount(id: "profile", source: .profileHome(path: "/tmp/codexbar-last-known-profile"))
        let windowLive = self.noon.addingTimeInterval(5 * 86400)
        let windowProfile = self.noon.addingTimeInterval(3 * 86400)
        let liveHome = self.sliceReport([(-7200, 1000, 2.5), (-3600, 300, 1.0), (-60, 50, 0.25)])
        store.spendDashboardPublication = self.codexPublication(
            zone: store.settings.costUsageBucketTimeZoneIdentifier,
            reports: ["codex:live": liveHome, "codex:profile": self.sliceReport([])])
        store.nativeCodexSessionAttribution.update(timeline: NativeCodexSessionWindowTimeline(
            events: [
                (time: self.noon.addingTimeInterval(-7200), weeklyReset: windowProfile),
                (time: self.noon.addingTimeInterval(-3600), weeklyReset: windowLive),
                (time: self.noon.addingTimeInterval(-60), weeklyReset: windowLive),
            ],
            coverageStart: self.noon.addingTimeInterval(-32 * 86400),
            coverageEnd: self.noon))
        let contexts = [
            (account: live, history: [self.weeklyLane(windowLive)], snapshot: UsageSnapshot?.none),
            (account: profile, history: [self.weeklyLane(windowProfile)], snapshot: UsageSnapshot?.none),
        ]
        #expect(store.nativeOrbitCodexResolvedLocalUsages(contexts).isEmpty)
        await store.nativeCodexSessionAttribution.waitForPendingAttribution()
        let current = store.nativeOrbitCodexResolvedLocalUsages(contexts)
        #expect(current["live"]?.lastKnownAt == nil)
        #expect(current["live"]?.usage.snapshot.quotaSlices.map(\.totalTokens) == [300, 50])
        #expect(current["profile"]?.usage.snapshot.quotaSlices.map(\.totalTokens) == [1000])

        // The spend scan reloads (or the app relaunches): each account keeps its own remembered attribution.
        store.spendDashboardPublication = .empty
        let remembered = store.nativeOrbitCodexResolvedLocalUsages(contexts)
        let liveRemembered = try #require(remembered["live"])
        #expect(liveRemembered.lastKnownAt == current["live"]?.usage.snapshot.updatedAt)
        #expect(liveRemembered.usage.isStale)
        #expect(liveRemembered.usage.isAccountAttributed)
        #expect(liveRemembered.usage.snapshot.quotaSlices.map(\.totalTokens) == [300, 50])
        #expect(remembered["profile"]?.usage.snapshot.quotaSlices.map(\.totalTokens) == [1000])

        // Activating another login changes this account from live to its managed home. Its retained attribution
        // still belongs to the same account and must remain visible while the replacement scan is pending.
        let dormant = self.codexAccount(id: "live", source: .managedAccount(id: managedID), storedAccountID: managedID)
        let switchedContexts = [
            (account: dormant, history: [self.weeklyLane(windowLive)], snapshot: UsageSnapshot?.none),
            (account: profile, history: [self.weeklyLane(windowProfile)], snapshot: UsageSnapshot?.none),
        ]
        let afterSwitch = store.nativeOrbitCodexResolvedLocalUsages(switchedContexts)
        #expect(afterSwitch["live"]?.usage.snapshot.quotaSlices.map(\.totalTokens) == [300, 50])
        #expect(afterSwitch["profile"]?.usage.snapshot.quotaSlices.map(\.totalTokens) == [1000])

        // A first profile activation creates a managed identity. Only the explicitly verified importer alias can
        // carry that profile's own report across; the other account's cohort reading follows the transaction too.
        let importedID = try #require(UUID(uuidString: "1F37E0F8-B130-4769-9575-E060696C4BAA"))
        let imported = CodexVisibleAccount(
            id: "imported-profile",
            email: profile.email,
            workspaceAccountID: profile.workspaceAccountID,
            authFingerprint: profile.authFingerprint,
            storedAccountID: importedID,
            selectionSource: .managedAccount(id: importedID),
            isActive: false,
            isLive: false,
            canReauthenticate: false,
            canRemove: false)
        store.nativeCodexAccountSwitchPresentation = .init(
            projection: .init(
                visibleAccounts: [live, profile],
                activeVisibleAccountID: live.id,
                liveVisibleAccountID: live.id,
                hasUnreadableAddedAccountStore: false),
            snapshots: [],
            localUsages: remembered)
        let importedContexts = [
            (account: live, history: [self.weeklyLane(windowLive)], snapshot: UsageSnapshot?.none),
            (account: imported, history: [self.weeklyLane(windowProfile)], snapshot: UsageSnapshot?.none),
        ]
        #expect(store.nativeOrbitCodexResolvedLocalUsages(importedContexts)["imported-profile"] == nil)
        store.nativeCodexAccountSwitchPresentation?.importedAccounts[profile.id] = imported
        // Cleanup explicitly migrates the alias without waiting for any intervening popup render.
        store.settings.cachedCodexAccountMenuProjection = .init(
            activeSource: store.settings.codexActiveSource,
            loadedAt: Date(),
            projection: .init(
                visibleAccounts: [live, imported],
                activeVisibleAccountID: live.id,
                liveVisibleAccountID: live.id,
                hasUnreadableAddedAccountStore: false))
        let switchToken = try #require(store.nativeCodexAccountSwitchPresentation?.token)
        store.finishNativeCodexAccountSwitchPresentation(token: switchToken)
        #expect(store.nativeCodexAccountSwitchPresentation == nil)
        let afterImport = store.nativeOrbitCodexResolvedLocalUsages(importedContexts)
        #expect(afterImport["imported-profile"]?.usage.snapshot.quotaSlices.map(\.totalTokens) == [1000])
        #expect(afterImport["live"]?.usage.snapshot.quotaSlices.map(\.totalTokens) == [300, 50])

        // Attribution split the shared home between exactly these accounts; another account set must wait.
        let third = self.codexAccount(id: "third", source: .profileHome(path: "/tmp/codexbar-last-known-third"))
        let widened = contexts + [(account: third, history: [], snapshot: UsageSnapshot?.none)]
        #expect(store.nativeOrbitCodexResolvedLocalUsages(widened).isEmpty)

        // A settled scan without reports is the live reading; nothing remembered stands in for it.
        store.spendDashboardPublication = self.codexPublication(
            zone: store.settings.costUsageBucketTimeZoneIdentifier, reports: [:], emptySourceIDs: [
                "codex:live", "codex:profile",
            ])
        #expect(store.nativeOrbitCodexResolvedLocalUsages(contexts).isEmpty)

        // Turning cost tracking off hides remembered spend as well.
        store.spendDashboardPublication = .empty
        store.settings.costUsageEnabled = false
        store.settings.codexLocalSessionCostLedgerEnabled = false
        #expect(store.nativeOrbitCodexResolvedLocalUsages(contexts).isEmpty)
    }

    // MARK: - Kimi

    @Test func `the remembered Kimi wire report stands in until the first scan publishes`() throws {
        let store = self.kimiStore()
        let configuration = self.kimiConfiguration(store)
        let key = try #require(UsageStore.nativeKimiLastKnownOwner(configuration))
        let remembered = self.richReport(zone: configuration.bucketTimeZoneIdentifier)
        let usage = NativeOrbitLocalUsage(
            snapshot: remembered,
            scope: .localMachine,
            bucketTimeZoneIdentifier: configuration.bucketTimeZoneIdentifier)
        store.nativeLastKnownUsage.adopt([.kimi: [key: usage]])
        #expect(store.nativeOrbitKimiResolvedLocalUsage()?.lastKnownAt == remembered.updatedAt)
        let row = try #require(store.nativeOrbitAccounts(for: .kimi).first)
        #expect(row.usageLastKnownAt == remembered.updatedAt)
        #expect(row.metrics.summary(days: 30, now: self.noon).tokens != nil)

        let live = self.richReport(
            zone: configuration.bucketTimeZoneIdentifier,
            updatedAt: self.noon.addingTimeInterval(60))
        store.nativeKimiLocalUsageReport = NativeKimiLocalUsagePublication(configuration: configuration, snapshot: live)
        #expect(store.nativeOrbitKimiResolvedLocalUsage()?.lastKnownAt == nil)
        #expect(store.nativeOrbitAccounts(for: .kimi).first?.usageLastKnownAt == nil)

        // Another bucket zone is another configuration: neither the live nor the remembered report applies.
        store.nativeKimiLocalUsageReport = nil
        let zone = configuration.bucketTimeZoneIdentifier == "Asia/Tokyo" ? "America/New_York" : "Asia/Tokyo"
        store.settings.costUsageBucketTimeZoneIdentifier = zone
        #expect(store.nativeOrbitKimiResolvedLocalUsage() == nil)
    }

    // MARK: - Fixtures

    private func expectSameSummary(
        _ lhs: NativeOrbitMetricSummary,
        _ rhs: NativeOrbitMetricSummary,
        sourceLocation: SourceLocation = #_sourceLocation)
    {
        #expect(lhs.tokens == rhs.tokens, sourceLocation: sourceLocation)
        #expect(lhs.cost == rhs.cost, sourceLocation: sourceLocation)
        #expect(lhs.requests == rhs.requests, sourceLocation: sourceLocation)
        #expect(lhs.currencyCode == rhs.currencyCode, sourceLocation: sourceLocation)
        #expect(lhs.isPartial == rhs.isPartial, sourceLocation: sourceLocation)
        #expect(lhs.costIsPartial == rhs.costIsPartial, sourceLocation: sourceLocation)
        #expect(lhs.costIsEstimated == rhs.costIsEstimated, sourceLocation: sourceLocation)
        #expect(lhs.usageScope == rhs.usageScope, sourceLocation: sourceLocation)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-last-known-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func day(_ offset: Int, zone: String) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone) ?? .current
        let date = calendar.date(byAdding: .day, value: offset, to: self.noon) ?? self.noon
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Daily totals with model breakdowns, unpriced and incomplete requests, mixed-completeness event slices,
    /// established coverage, a source zone, a coverage end and mixed provenance.
    private func richReport(zone: String = "Europe/London", updatedAt: Date? = nil) -> CostUsageTokenSnapshot {
        let updatedAt = updatedAt ?? self.noon
        let daily = (-8...0).map { offset in
            CostUsageDailyReport.Entry(
                date: self.day(offset, zone: zone),
                inputTokens: 100,
                outputTokens: 50,
                totalTokens: 1000 + offset,
                requestCount: 4,
                costUSD: 1.25,
                modelsUsed: ["fixture-model"],
                modelBreakdowns: [.init(
                    modelName: "fixture-model",
                    costUSD: offset == 0 ? .nan : 1.25,
                    totalTokens: 1000 + offset,
                    incompleteRequestCount: offset == -3 ? 1 : nil)],
                unpricedRequestCount: offset == -2 ? 1 : nil,
                unmeteredRequestCount: nil,
                costIsPartial: offset == -1 ? true : nil)
        }
        let slices = [-6 * 86400.0, -26 * 3600, -5 * 3600, -1800, -60].enumerated().map { index, offset in
            CostUsageTimedEntry(
                timestamp: self.noon.addingTimeInterval(offset),
                totalTokens: index == 2 ? nil : 10 * (index + 1),
                costUSD: index == 3 ? nil : 0.5,
                tokensAreComplete: index != 1,
                costIsComplete: true)
        }
        return CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: 9000,
            last30DaysCostUSD: 11.25,
            last30DaysRequests: 36,
            historyDays: 365,
            historyCoverageIsEstablished: true,
            historyScanIsPartial: false,
            historyLabel: "Fixture history",
            bucketTimeZoneIdentifier: zone,
            coverageThrough: updatedAt,
            costProvenance: .mixed,
            daily: daily,
            quotaSlices: slices,
            updatedAt: updatedAt)
    }

    private func sliceReport(_ slices: [(TimeInterval, Int, Double)]) -> CostUsageTokenSnapshot {
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

    private func claudeStore() -> UsageStore {
        let settings = testSettingsStore(
            suiteName: "native-last-known-claude", userDefaults: InMemoryUserDefaults(), nativeDesignEnabled: true)
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

    private func claudeAccount(slot: String, email: String, organization: String) -> ProviderAccountUsageSnapshot {
        ProviderAccountUsageSnapshot(
            id: .init(source: "claude-swap", opaqueID: slot),
            provider: .claude,
            displayLabel: "Fixture \(slot)",
            accountEmail: email,
            sourceOrganizationID: organization,
            isActive: slot == "1",
            snapshot: UsageSnapshot(
                primary: RateWindow(usedPercent: 25, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: self.noon.addingTimeInterval(-600),
                identity: .init(
                    providerID: .claude, accountEmail: email, accountOrganization: nil, loginMethod: "claude-swap")),
            error: nil,
            sourceLabel: "fixture")
    }

    private func codexAccount(
        id: String,
        source: CodexActiveSource,
        storedAccountID: UUID? = nil) -> CodexVisibleAccount
    {
        let live = source == .liveSystem
        return CodexVisibleAccount(
            id: id,
            email: "\(id)@example.com",
            workspaceAccountID: "workspace-\(id)",
            authFingerprint: "fingerprint-\(id)",
            storedAccountID: storedAccountID,
            selectionSource: source,
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

    private func codexPublication(
        zone: String,
        reports: [String: CostUsageTokenSnapshot],
        emptySourceIDs: [String] = []) -> SpendDashboardPublication
    {
        let ids = reports.keys.sorted()
        return SpendDashboardPublication(
            revision: 1,
            generation: 1,
            configuration: SpendDashboardConfiguration(
                costUsageEnabled: true,
                providerIDs: ["codex"],
                codexAccountIdentities: [],
                bucketTimeZoneIdentifier: zone),
            loadedAt: self.noon,
            isRefreshing: false,
            inputs: ids.map { .init(id: $0, provider: .codex, displayName: $0, snapshot: reports[$0]!) },
            sources: ids.map {
                .init(id: $0, provider: .codex, displayName: $0, role: .subscription, state: .available)
            } + emptySourceIDs.map {
                .init(id: $0, provider: .codex, displayName: $0, role: .subscription, state: .confirmedEmpty)
            })
    }

    private func kimiStore() -> UsageStore {
        let settings = testSettingsStore(
            suiteName: "native-last-known-kimi", userDefaults: InMemoryUserDefaults(), nativeDesignEnabled: true)
        enableTestProviders([.kimi], settings: settings)
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        store._cancelPlanUtilizationHistoryLoadForTesting()
        return store
    }

    private func kimiConfiguration(_ store: UsageStore) -> NativeKimiLocalUsageConfiguration {
        NativeKimiLocalUsageConfiguration(
            provider: .kimi,
            sessionsRootPath: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".kimi-code/sessions").path,
            bucketTimeZoneIdentifier: store.settings.costUsageBucketTimeZoneIdentifier,
            sourceMode: store.settings.kimiUsageDataSource,
            region: store.settings.kimiRegion,
            selectedAccountID: nil)
    }
}
