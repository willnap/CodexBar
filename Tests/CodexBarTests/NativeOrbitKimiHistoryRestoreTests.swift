import Foundation
import SwiftUI
import Testing
@testable import CodexBar
@testable import CodexBarCore

/// Historical complication restore (shared Kimi/Codex lanes), hover snapping, the legacy Kimi history fold,
/// Kimi's estimated list-price spend, and zero readings proven by a complete local scan.
@MainActor
struct NativeOrbitKimiHistoryRestoreTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Restore tolerance

    @Test func `lanes stamped microseconds apart by one refresh restore together`() {
        let captured = self.now.addingTimeInterval(-600)
        let histories = [
            self.lane("nativeMetric:balance", [self.balance(5, at: captured)]),
            self.lane("nativeMetric:resets", [self.resets(1, at: captured.addingTimeInterval(0.000009))]),
        ]
        for date in [captured, captured.addingTimeInterval(0.000009)] {
            let restored = NativeOrbitAccountMetrics.empty.at(date, observedAt: self.now, history: histories)
            #expect(restored.reportedBalance?.value == 5)
            #expect(restored.bankedResets == 1)
            #expect(restored.resetInventoryObservedAt == captured.addingTimeInterval(0.000009))
        }
    }

    @Test func `a reading stays restorable until its lane's next poll is overdue`() {
        // Codex-style lanes polled every two minutes for twenty minutes.
        let last = self.now.addingTimeInterval(-7200)
        let times = (0...10).map { last.addingTimeInterval(-Double(10 - $0) * 120) }
        let histories = [
            self.lane("nativeMetric:balance", times.map { self.balance(7, at: $0) }),
            self.lane("nativeMetric:resets", times.map { self.resets(2, at: $0.addingTimeInterval(0.4)) }),
        ]
        let between = NativeOrbitAccountMetrics.empty.at(
            last.addingTimeInterval(600), observedAt: self.now, history: histories)
        #expect(between.reportedBalance?.value == 7)
        #expect(between.reportedBalance?.updatedAt == last)
        #expect(between.bankedResets == 2)
        let outage = NativeOrbitAccountMetrics.empty.at(
            last.addingTimeInterval(3 * 3600), observedAt: self.now, history: histories)
        #expect(outage.reportedBalance == nil)
        #expect(outage.bankedResets == nil)
        let beforeFirst = NativeOrbitAccountMetrics.empty.at(
            times[0].addingTimeInterval(-1), observedAt: self.now, history: histories)
        #expect(beforeFirst.reportedBalance == nil)
        #expect(beforeFirst.bankedResets == nil)
        #expect(NativeOrbitAccountMetrics.restoreTolerance(histories[0].entries) == 900)
    }

    @Test func `Kimi hover on a quota sample a second after its refresh restores that refresh's spend`() {
        let captured = self.now.addingTimeInterval(-3600)
        let spend = ProviderCostSnapshot(used: 0, limit: 0, currencyCode: "USD", period: "Monthly", updatedAt: captured)
        let histories = [
            self.lane("nativeMetric:spend", [.init(
                capturedAt: captured,
                usedPercent: 0,
                resetsAt: nil,
                nativeMetrics: .init(spend: spend))]),
            PlanUtilizationSeriesHistory(name: "nativeQuota:secondary", windowMinutes: 300, entries: [
                .init(capturedAt: captured.addingTimeInterval(-7200), usedPercent: 10, resetsAt: nil),
                .init(capturedAt: captured.addingTimeInterval(0.8), usedPercent: 12, resetsAt: nil),
            ]),
        ]
        let widget = NativeOrbitHistoryWidget(histories: histories, now: self.now, provider: .kimi)
        #expect(widget.inspectionDate(at: captured.addingTimeInterval(0.8), plotWidth: 200) == captured)
        let restored = NativeOrbitAccountMetrics.empty.at(
            captured.addingTimeInterval(0.8), observedAt: self.now, history: histories)
        #expect(restored.reportedSpend?.used == 0)
        #expect(restored.reportedSpend?.period == "Monthly")
        #expect(restored.reportedSpend?.updatedAt == captured)
        // A quota-only instant before the first complication reading has no spend to restore.
        let quotaOnly = NativeOrbitAccountMetrics.empty.at(
            captured.addingTimeInterval(-7200), observedAt: self.now, history: histories)
        #expect(quotaOnly.reportedSpend == nil)
    }

    // MARK: - Legacy Kimi owner buckets

    @Test func `legacy per-token Kimi buckets fold into the stable owner only with one credential`() throws {
        let start = self.now.addingTimeInterval(-3600)
        var buckets = PlanUtilizationHistoryBuckets()
        buckets.preferredAccountKey = "owner"
        buckets.accounts["owner"] = [
            self.quota("nativeQuota:kimi-monthly", 43200, at: [start, start.addingTimeInterval(120)], percent: 58.1),
            self.lane("nativeMetric:spend", [.init(
                capturedAt: start,
                usedPercent: 0,
                resetsAt: nil,
                nativeMetrics: .init(spend: .init(used: 0, limit: 0, currencyCode: "USD", updatedAt: start)))]),
        ]
        buckets.accounts["token-a"] = [
            self.quota("nativeQuota:kimi-monthly", 43200, at: [start.addingTimeInterval(-7200)], percent: 57.98),
        ]
        buckets.accounts["token-b"] = [
            self.quota("nativeQuota:kimi-monthly", 43200, at: [start.addingTimeInterval(-600)], percent: 58.0),
            self.quota("session", 300, at: [start.addingTimeInterval(-599)], percent: 10),
        ]
        buckets.accounts["later"] = [
            self.quota("nativeQuota:kimi-monthly", 43200, at: [start.addingTimeInterval(60)], percent: 90),
        ]
        let folded = try #require(UsageStore.nativeKimiFoldedLegacyHistory(buckets, credentialCount: 1))
        #expect(Set(folded.accounts.keys) == ["owner", "later"])
        let monthly = try #require(folded.accounts["owner"]?.first { $0.name.rawValue == "nativeQuota:kimi-monthly" })
        #expect(monthly.entries.map(\.capturedAt) == [
            start.addingTimeInterval(-7200), start.addingTimeInterval(-600), start, start.addingTimeInterval(120),
        ])
        #expect(folded.accounts["owner"]?.contains { $0.name.rawValue == "session" } == true)
        #expect(UsageStore.nativeKimiFoldedLegacyHistory(folded, credentialCount: 1) == nil)
        #expect(UsageStore.nativeKimiFoldedLegacyHistory(buckets, credentialCount: 2) == nil)
        var twoOwners = buckets
        twoOwners.accounts["other-owner"] = [self.lane("nativeMetric:spend", [.init(
            capturedAt: start.addingTimeInterval(-60),
            usedPercent: 0,
            resetsAt: nil,
            nativeMetrics: .init())])]
        #expect(UsageStore.nativeKimiFoldedLegacyHistory(twoOwners, credentialCount: 1) == nil)
    }

    @Test func `a saved Kimi web account prevents the legacy fold`() async {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let store = self.store(home: home)
        let start = self.now.addingTimeInterval(-3600)
        var buckets = PlanUtilizationHistoryBuckets()
        buckets.preferredAccountKey = "owner"
        buckets.accounts["owner"] = [self.lane("nativeMetric:spend", [.init(
            capturedAt: start,
            usedPercent: 0,
            resetsAt: nil,
            nativeMetrics: .init())])]
        buckets.accounts["token-a"] = [
            self.quota("nativeQuota:kimi-monthly", 43200, at: [start.addingTimeInterval(-60)], percent: 57.98),
        ]
        #expect(store.nativeKimiConfiguredCredentialCount() == 1)
        store.settings.addTokenAccount(provider: .kimi, label: "Web", token: "fixture-kimi-auth")
        #expect(store.nativeKimiConfiguredCredentialCount() == 2)
        store.planUtilizationHistory[.kimi] = buckets
        await store.foldLegacyNativeKimiHistoryIfNeeded()
        #expect(store.planUtilizationHistory[.kimi] == buckets)
        let single = self.store(home: home.appendingPathComponent("single"))
        single.planUtilizationHistory[.kimi] = buckets
        await single.foldLegacyNativeKimiHistoryIfNeeded()
        #expect(single.planUtilizationHistory[.kimi]?.accounts.keys.sorted() == ["owner"])
    }

    // MARK: - Estimated spend

    @Test func `Kimi spend is the estimated list price of priced turns with unpriced routes marked partial`() throws {
        let lines = [
            self.wire(
                time: 1_799_999_000_000,
                model: "kimi-code/k3",
                input: 1_000_000,
                output: 100_000,
                read: 2_000_000),
            self.wire(time: 1_799_999_100_000, model: "kimi-code/kimi-for-coding", input: 500, output: 50, read: 0),
        ].joined(separator: "\n")
        let snapshot = NativeKimiLocalUsageParser.snapshot(
            data: Data(lines.utf8),
            now: self.now,
            bucketTimeZoneIdentifier: "UTC",
            pricingCatalog: Self.catalog)
        let day = try #require(snapshot.daily.last)
        #expect(abs((day.costUSD ?? 0) - 5.1) < 1e-9)
        #expect(day.pricedRequestCount == 1)
        #expect(day.unpricedRequestCount == 1)
        #expect(day.costIsPartial == true)
        #expect(day.modelsUsed == ["kimi-code/k3", "kimi-code/kimi-for-coding"])
        #expect(snapshot.costProvenance == .listPriceEstimate)
        #expect(snapshot.quotaSlices.map { $0.costUSD != nil } == [true, false])
        let metrics = try NativeOrbitAccountMetrics.make(
            provider: .kimi,
            snapshot: self.kimiSnapshot(),
            usage: nil,
            now: self.now,
            localUsage: .init(snapshot: snapshot, scope: .localMachine, bucketTimeZoneIdentifier: "UTC"))
        let summary = metrics.summary(days: 1, now: self.now)
        #expect(abs((summary.cost ?? 0) - 5.1) < 1e-9)
        #expect(summary.costIsEstimated)
        #expect(summary.costIsPartial)
        let labels = Self.cornerLabels(NativeOrbitInstruments(
            account: self.account(metrics),
            days: 1,
            now: self.now,
            accent: .blue).body)
        #expect(labels
            .contains { $0.contains("$5.10 spent") && $0.hasSuffix("at list prices") && $0.contains("this Mac") })
        #expect(labels.contains { $0.contains("additional usage") && $0.contains("$0.00") })
        // Plan routes priced at zero on models.dev never become a $0 estimate on their own.
        let planOnly = NativeKimiLocalUsageParser.snapshot(
            data: Data(lines.utf8),
            now: self.now,
            bucketTimeZoneIdentifier: "UTC",
            pricingCatalog: ModelsDevCatalog(providers: ["kimi-code-plan-global": Self.planProvider]))
        #expect(planOnly.last30DaysCostUSD == nil)
        #expect(planOnly.costProvenance == .unknown)
    }

    @Test func `only an unambiguous Moonshot model prices a Kimi Code route`() {
        #expect(NativeKimiListPricing.listPrice(model: "kimi-code/k3", catalog: Self.catalog)?.modelID == "kimi-k3")
        #expect(NativeKimiListPricing.listPrice(model: "kimi-code/kimi-for-coding", catalog: Self.catalog) == nil)
        #expect(NativeKimiListPricing.listPrice(model: "kimi-code/kimi-for-coding-highspeed", catalog: Self.catalog)
            == nil)
        #expect(NativeKimiListPricing.listPrice(model: "openai/k3", catalog: Self.catalog) == nil)
    }

    // MARK: - Zero readings from a complete scan

    @Test func `a complete scan proves quiet periods are zero now and at a past instant`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        // Activity yesterday, then today only after 07:00 UTC; now is 08:00 UTC.
        let yesterday = self.wire(time: 1_799_920_000_000, model: "kimi-code/k3", input: 10, output: 7, read: 31)
        let today = self.wire(time: 1_799_996_400_000, model: "kimi-code/k3", input: 20, output: 7, read: 31)
        let wire = root.appendingPathComponent("p/s/agents/main/wire.jsonl")
        try FileManager.default.createDirectory(at: wire.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((yesterday + "\n" + today + "\n").utf8).write(to: wire)
        try FileManager.default.setAttributes([.modificationDate: self.now], ofItemAtPath: wire.path)
        let scanner = NativeKimiLocalUsageScanner()
        let snapshot = try #require(await scanner.scan(
            sessionsRoot: root,
            now: self.now,
            bucketTimeZoneIdentifier: "UTC"))
        #expect(snapshot.historyIsFullyScanned)
        let metrics = NativeOrbitAccountMetrics.make(
            provider: .kimi,
            snapshot: nil,
            usage: nil,
            now: self.now,
            localUsage: .init(snapshot: snapshot, scope: .localMachine, bucketTimeZoneIdentifier: "UTC"))
        let current = metrics.summary(days: 1, now: self.now)
        #expect(current.tokens == 58)
        #expect(!current.isPartial)
        // Yesterday 05:30 UTC: after midnight, before that day's only turn at 09:46.
        let quietMorning = Date(timeIntervalSince1970: 1_799_904_600)
        let morning = metrics.at(quietMorning, observedAt: self.now).summary(days: 1, now: quietMorning)
        #expect(morning.tokens == 0)
        // Today 05:30 UTC: the week holds yesterday's completed day only.
        let todayMorning = Date(timeIntervalSince1970: 1_799_991_000)
        let week = metrics.at(todayMorning, observedAt: self.now).summary(days: 7, now: todayMorning)
        #expect(week.tokens == 48)
        // A quiet stretch earlier today, before today's first turn, is a known zero too.
        let quietToday = metrics.at(todayMorning, observedAt: self.now).summary(days: 1, now: todayMorning)
        #expect(quietToday.tokens == 0)
        // A day with no activity at all inside a complete scan is a known zero, not an unknown.
        let emptyDay = Date(timeIntervalSince1970: 1_800_000_000 - 3 * 86400)
        #expect(metrics.at(emptyDay, observedAt: self.now).summary(days: 1, now: emptyDay).tokens == 0)
        // Before today's first turn, the live dial reads a complete zero rather than an unknown.
        try Data((yesterday + "\n").utf8).write(to: wire)
        try FileManager.default.setAttributes([.modificationDate: self.now], ofItemAtPath: wire.path)
        let quiet = try #require(await NativeKimiLocalUsageScanner().scan(
            sessionsRoot: root,
            now: self.now,
            bucketTimeZoneIdentifier: "UTC"))
        let live = NativeOrbitAccountMetrics.make(
            provider: .kimi,
            snapshot: nil,
            usage: nil,
            now: self.now,
            localUsage: .init(snapshot: quiet, scope: .localMachine, bucketTimeZoneIdentifier: "UTC"))
            .summary(days: 1, now: self.now)
        #expect(live.tokens == 0)
        #expect(!live.isPartial)
    }

    // MARK: - Fixtures

    private static let planProvider = ModelsDevProvider(id: "kimi-code-plan-global", name: "Kimi For Coding", models: [
        "k3": ModelsDevModel(id: "k3", name: "Kimi K3", cost: .init(input: 0, output: 0, cacheRead: 0, cacheWrite: 0)),
        "kimi-for-coding": ModelsDevModel(
            id: "kimi-for-coding",
            name: "kimi-for-coding",
            cost: .init(input: 0, output: 0, cacheRead: 0, cacheWrite: 0)),
        "kimi-for-coding-highspeed": ModelsDevModel(
            id: "kimi-for-coding-highspeed",
            name: "Kimi For Coding HighSpeed",
            cost: .init(input: 0, output: 0, cacheRead: 0, cacheWrite: 0)),
    ])

    private static let catalog = ModelsDevCatalog(providers: [
        "kimi-code-plan-global": Self.planProvider,
        "moonshotai": ModelsDevProvider(id: "moonshotai", name: "Moonshot AI", models: [
            "kimi-k3": ModelsDevModel(
                id: "kimi-k3",
                name: "Kimi K3",
                cost: .init(input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3)),
            "kimi-k2.7-code": ModelsDevModel(
                id: "kimi-k2.7-code",
                name: "Kimi K2.7 Code",
                cost: .init(input: 0.95, output: 4, cacheRead: 0.19)),
            "kimi-k2.7-code-highspeed": ModelsDevModel(
                id: "kimi-k2.7-code-highspeed",
                name: "Kimi K2.7 Code HighSpeed",
                cost: .init(input: 1.9, output: 8, cacheRead: 0.38)),
        ]),
    ])

    private func wire(time: Int64, model: String, input: Int, output: Int, read: Int) -> String {
        """
        {"type":"usage.record","agentId":"agent-1","model":"\(model)","time":\(time),"usageScope":"turn",\
        "usage":{"inputOther":\(input),"output":\(output),"inputCacheRead":\(read),"inputCacheCreation":0}}
        """
    }

    private func lane(_ name: String, _ entries: [PlanUtilizationHistoryEntry]) -> PlanUtilizationSeriesHistory {
        PlanUtilizationSeriesHistory(name: .init(rawValue: name), windowMinutes: 0, entries: entries)
    }

    private func quota(_ name: String, _ minutes: Int, at dates: [Date], percent: Double)
        -> PlanUtilizationSeriesHistory
    {
        PlanUtilizationSeriesHistory(
            name: .init(rawValue: name),
            windowMinutes: minutes,
            entries: dates.map { .init(capturedAt: $0, usedPercent: percent, resetsAt: nil) })
    }

    private func balance(_ value: Double, at date: Date) -> PlanUtilizationHistoryEntry {
        .init(capturedAt: date, usedPercent: 0, resetsAt: nil, nativeMetrics: .init(balance: .init(
            value: value, unit: "USD", isWorkspace: false, updatedAt: date)))
    }

    private func resets(_ count: Int, at date: Date) -> PlanUtilizationHistoryEntry {
        .init(capturedAt: date, usedPercent: 0, resetsAt: nil, nativeMetrics: .init(resets: .init(
            availableExpirations: Array(repeating: nil, count: count))))
    }

    private func kimiSnapshot() throws -> UsageSnapshot {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let reset = formatter.string(from: self.now.addingTimeInterval(3600))
        let payload: [String: Any] = [
            "limits": [[
                "window": ["duration": 300, "timeUnit": "TIME_UNIT_MINUTE"],
                "detail": ["limit": "100", "used": "10", "remaining": "90", "resetTime": reset],
            ]],
            "usages": ["limit_5h": ["used_ratio": 0.099, "reset_time": reset]],
            "booster_wallet": [
                "balance": ["type": "BOOSTER", "unit": "UNIT_CURRENCY"],
                "monthlyUsed": ["currency": "USD", "priceInCents": "0"],
            ],
        ]
        return try KimiUsageFetcher.parseCodeAPIUsage(
            from: JSONSerialization.data(withJSONObject: payload), now: self.now).toUsageSnapshot()
    }

    private func account(_ metrics: NativeOrbitAccountMetrics) -> NativeOrbitAccountPresentation {
        NativeOrbitAccountPresentation(
            id: "kimi-fixture",
            label: "Fixture",
            email: nil,
            symbol: "person",
            isActive: true,
            canActivate: false,
            gauge: .init(),
            updatedAt: self.now,
            history: [],
            odometer: nil,
            odometerHelp: nil,
            statusText: nil,
            selection: .none,
            metrics: metrics)
    }

    private func store(home: URL) -> UsageStore {
        let settings = testSettingsStore(
            suiteName: "NativeOrbitKimiHistoryRestore", userDefaults: InMemoryUserDefaults(), nativeDesignEnabled: true)
        enableTestProviders([.kimi], settings: settings)
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            planUtilizationHistoryStore: .init(directoryURL: home.appendingPathComponent("history")),
            startupBehavior: .testing,
            environmentBase: [:])
        store._cancelPlanUtilizationHistoryLoadForTesting()
        return store
    }

    /// Traverse the constructed SwiftUI corner views; assertions inspect their consumer-visible readouts.
    private static func cornerLabels(_ value: Any, depth: Int = 0) -> [String] {
        if let view = value as? NativeOrbitComplication { return [view.help] }
        if let view = value as? NativeOrbitResetComplication { return [view.help] }
        if let view = value as? NativeOrbitExtraUsageComplication { return [view.help] }
        guard depth < 30 else { return [] }
        return Mirror(reflecting: value).children.flatMap { self.cornerLabels($0.value, depth: depth + 1) }
    }
}
