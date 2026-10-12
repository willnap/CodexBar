import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct NativeOrbitHistoryMetricsTests {
    private let now = Date(timeIntervalSince1970: 1_786_363_200)

    @Test func `historical totals stop at the hovered event instead of including later usage`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 18)))
        let date = now.addingTimeInterval(-3600)
        let usage = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: 900,
            last30DaysCostUSD: 9,
            daily: [.init(
                date: "2026-10-11",
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: 900,
                costUSD: 9,
                modelsUsed: nil,
                modelBreakdowns: nil)],
            quotaSlices: [
                .init(timestamp: date.addingTimeInterval(-60), totalTokens: 100, costUSD: 1),
                .init(timestamp: date, totalTokens: 200, costUSD: 2),
                .init(timestamp: date.addingTimeInterval(60), totalTokens: 600, costUSD: 6),
            ], updatedAt: now)
        let metrics = NativeOrbitAccountMetrics(usage: usage)
        let historical = metrics.summary(days: 1, now: date, calendar: calendar)
        #expect(historical.tokens == 300)
        #expect(historical.cost == 3)
        #expect(metrics.summary(days: 1, now: now, calendar: calendar).tokens == 900)
    }

    @Test func `daily aggregates cannot claim to describe an earlier intraday point`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let usage = self.costSnapshot(daily: [
            self.entry(date: self.now, tokens: 900, cost: 9, requests: 10, calendar: calendar),
        ])
        let metrics = NativeOrbitAccountMetrics(usage: usage)
        let historical = metrics.summary(days: 1, now: self.now.addingTimeInterval(-60), calendar: calendar)
        #expect(historical.tokens == nil)
        #expect(historical.cost == nil)
        #expect(historical.requests == nil)
    }

    @Test func `historical inspection retains completed daily buckets without borrowing the inspection day`() throws {
        let calendar = CostUsageBucketTimeZone.calendar(identifier: "UTC")
        let observed = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 10)))
        let inspected = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 12)))
        let usage = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: nil,
            last30DaysCostUSD: nil,
            historyCoverageIsEstablished: false,
            daily: [
                .init(
                    date: "2026-10-09",
                    inputTokens: nil,
                    outputTokens: nil,
                    totalTokens: 100,
                    costUSD: 1,
                    modelsUsed: nil,
                    modelBreakdowns: nil),
                .init(
                    date: "2026-10-10",
                    inputTokens: nil,
                    outputTokens: nil,
                    totalTokens: 200,
                    costUSD: 2,
                    modelsUsed: nil,
                    modelBreakdowns: nil),
                .init(
                    date: "2026-10-11",
                    inputTokens: nil,
                    outputTokens: nil,
                    totalTokens: 900,
                    costUSD: 9,
                    modelsUsed: nil,
                    modelBreakdowns: nil),
            ], updatedAt: observed)
        let metrics = NativeOrbitAccountMetrics(usage: usage, bucketTimeZoneIdentifier: "UTC")
        for days in [7, 30] {
            let historical = metrics.summary(days: days, now: inspected, calendar: calendar)
            #expect(historical.tokens == 300)
            #expect(historical.cost == 3)
            #expect(historical.isPartial)
        }
        #expect(metrics.summary(days: 1, now: inspected, calendar: calendar).tokens == nil)
    }

    @Test func `native token account charts retain every measured lane and exact observation times`() async throws {
        let store = self.store()
        store.settings.historicalTrackingEnabled = false
        store.settings.addTokenAccount(provider: .kimi, label: "One", token: "fixture-one")
        store.settings.addTokenAccount(provider: .kimi, label: "Two", token: "fixture-two")
        let accounts = store.settings.tokenAccounts(for: .kimi)
        let first = self.snapshot(at: self.now, used: 88)
        let second = self.snapshot(at: self.now.addingTimeInterval(120), used: 12)
        for snapshot in [first, second] {
            await store.recordPlanUtilizationHistorySample(
                provider: .kimi,
                snapshot: snapshot,
                account: accounts[0],
                shouldUpdatePreferredAccountKey: false,
                shouldAdoptUnscopedHistory: false,
                now: self.now.addingTimeInterval(3600))
        }
        let rows = store.nativeOrbitAccounts(for: .kimi)
        let owner = try #require(rows.first { $0.id == accounts[0].id.uuidString })
        let native = owner.history.filter(\.name.isNativeQuotaObservation)
        #expect(Set(native.map(\.name.rawValue)) == [
            "nativeQuota:primary", "nativeQuota:secondary", "nativeQuota:tertiary", "nativeQuota:kimi-monthly",
        ])
        let primary = try #require(native.first { $0.name.rawValue == "nativeQuota:primary" })
        #expect(primary.entries.map(\.capturedAt) == [first.updatedAt, second.updatedAt])
        #expect(primary.entries.map(\.usedPercent) == [88, 12])
        #expect(primary.entries.count == 2)
        #expect(rows.first { $0.id == accounts[1].id.uuidString }?.history.isEmpty == true)
        #expect(native.first { $0.name.rawValue == "nativeQuota:tertiary" }?.hasSupportedCadence == true)
        await store.recordPlanUtilizationHistorySample(
            provider: .kimi, snapshot: second, account: accounts[0], now: self.now.addingTimeInterval(7200))
        let repeated = store.nativeOrbitAccounts(for: .kimi).first { $0.id == accounts[0].id.uuidString }?
            .history.first { $0.name.rawValue == "nativeQuota:primary" }
        #expect(repeated?.entries.count == 2)
    }

    @Test func `Claude adapter records isolated observed owner histories and retains a replaced slot`() async throws {
        let store = self.store()
        store.settings.claudeSwapEnabled = true
        let old = self.claudeAccount(email: "first@example.com", organization: "One")
        store.claudeSwapAccountSnapshots = [old]
        await store.recordNativeClaudeSwapHistory([old])
        let oldKey = try #require(UsageStore.nativeOrbitClaudeHistoryKey(old))
        let oldHistory = try #require(store.planUtilizationHistory[.claude]?.accounts[oldKey])
        #expect(store.nativeOrbitAccounts(for: .claude).first?.history.isEmpty == false)
        let new = self.claudeAccount(email: "second@example.com", organization: "Two")
        store.claudeSwapAccountSnapshots = [new]
        await store.recordNativeClaudeSwapHistory([new])
        let newKey = try #require(UsageStore.nativeOrbitClaudeHistoryKey(new))
        #expect(oldKey != newKey)
        #expect(store.planUtilizationHistory[.claude]?.accounts[oldKey] == oldHistory)
        #expect(store.planUtilizationHistory[.claude]?.accounts[newKey]?.isEmpty == false)
        let newHistory = try #require(store.planUtilizationHistory[.claude]?.accounts[newKey])
        #expect(store.planUtilizationHistory[.claude]?.unscoped.isEmpty == true)
        let retained = self.claudeAccount(email: "third@example.com", organization: "Three", lastKnown: true)
        store.claudeSwapAccountSnapshots = [retained]
        await store.recordNativeClaudeSwapHistory([retained])
        #expect(store.nativeOrbitAccounts(for: .claude).first?.updatedAt == retained.snapshot?.updatedAt)
        #expect(store.planUtilizationHistory[.claude]?.accounts[
            UsageStore.nativeOrbitClaudeHistoryKey(retained) ?? "",
        ] == nil)
        #expect(store.planUtilizationHistory[.claude]?.accounts[newKey] == newHistory)
    }

    @Test func `Codex fanout records each published account without moving the preferred history owner`() async throws {
        let store = self.store()
        let active = self.codexAccount(id: "active", email: "active@example.com", live: true)
        let sibling = self.codexAccount(id: "sibling", email: "sibling@example.com", live: false)
        let projection = CodexVisibleAccountProjection(
            visibleAccounts: [active, sibling],
            activeVisibleAccountID: active.id,
            liveVisibleAccountID: active.id,
            hasUnreadableAddedAccountStore: false)
        let records = [active, sibling].enumerated().map { index, account in
            CodexAccountUsageSnapshot(
                account: account,
                snapshot: self.snapshot(
                    at: self.now,
                    used: Double(20 + index * 30)),
                error: nil,
                sourceLabel: "fixture")
        }
        let activeKey = try #require(CodexHistoryOwnership.canonicalKey(for: .providerAccount(id: active.id)))
        store.planUtilizationHistory[.codex] = PlanUtilizationHistoryBuckets(preferredAccountKey: activeKey)
        store.codexAccountSnapshots = records
        await store.recordNativeCodexAccountHistory(records, projection: projection)
        let rows = store.nativeOrbitCodexAccounts(projection)
        for (index, account) in [active, sibling].enumerated() {
            let row = try #require(rows.first { $0.id == account.id })
            let primary = try #require(row.history.first { $0.name.rawValue == "nativeQuota:primary" })
            #expect(primary.entries.map(\.capturedAt) == [self.now])
            #expect(primary.entries.map(\.usedPercent) == [Double(20 + index * 30)])
        }
        #expect(store.planUtilizationHistory[.codex]?.preferredAccountKey == activeKey)
        #expect(store.planUtilizationHistory[.codex]?.unscoped.isEmpty == true)
        await store.recordNativeCodexAccountHistory(records, projection: projection)
        #expect(store.nativeOrbitCodexAccounts(projection).allSatisfy {
            $0.history.allSatisfy { $0.entries.count == 1 }
        })
    }

    @Test func `Codex fanout cannot record stale unpublished or failed account observations`() async {
        let store = self.store()
        let account = self.codexAccount(id: "sibling", email: "sibling@example.com", live: false)
        let projection = CodexVisibleAccountProjection(
            visibleAccounts: [account],
            activeVisibleAccountID: nil,
            liveVisibleAccountID: nil,
            hasUnreadableAddedAccountStore: false)
        let earlier = CodexAccountUsageSnapshot(
            account: account, snapshot: self.snapshot(at: self.now, used: 30), error: nil, sourceLabel: "fixture")
        let failed = CodexAccountUsageSnapshot(
            account: account, snapshot: earlier.snapshot, error: "Offline", sourceLabel: "fixture")
        store.codexAccountSnapshots = [failed]
        await store.recordNativeCodexAccountHistory([earlier, failed], projection: projection)
        #expect(store.planUtilizationHistory[.codex]?.isEmpty != false)
        let newer = CodexAccountUsageSnapshot(
            account: account,
            snapshot: self.snapshot(
                at: self.now.addingTimeInterval(60),
                used: 40),
            error: nil,
            sourceLabel: "fixture")
        store.codexAccountSnapshots = [newer]
        await store.recordNativeCodexAccountHistory([earlier], projection: projection)
        #expect(store.planUtilizationHistory[.codex]?.isEmpty != false)
        await store.recordNativeCodexAccountHistory([newer], projection: projection)
        #expect(store.nativeOrbitCodexAccounts(projection).first?.history.first?.entries.first?.capturedAt
            == self.now.addingTimeInterval(60))
    }

    @Test func `account metrics report observed daily coverage and mark incomplete selected periods`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let today = self.entry(date: self.now, tokens: 10, cost: 1, requests: 2, calendar: calendar)
        let yesterday = self.entry(
            date: self.now.addingTimeInterval(-86400), tokens: 20, cost: 2, requests: 3, calendar: calendar)
        let older = self.entry(
            date: self.now.addingTimeInterval(-14 * 86400), tokens: 40, cost: 4, requests: 5, calendar: calendar)
        let metrics = NativeOrbitAccountMetrics(usage: self.costSnapshot(daily: [today, yesterday, older]))
        #expect(metrics.summary(days: 1, now: self.now, calendar: calendar).tokens == 10)
        #expect(metrics.summary(days: 7, now: self.now, calendar: calendar).cost == 3)
        #expect(metrics.summary(days: 30, now: self.now, calendar: calendar).requests == 10)
        #expect(metrics.summary(days: 30, now: self.now, calendar: calendar).costIsEstimated)
        let tooShort = NativeOrbitAccountMetrics(usage: self.costSnapshot(daily: [today], days: 1))
        #expect(tooShort.summary(days: 30, now: self.now, calendar: calendar).tokens == 10)
        #expect(tooShort.summary(days: 30, now: self.now, calendar: calendar).isPartial)
        let aggregate = NativeOrbitAccountMetrics(usage: self.costSnapshot(daily: [], days: 7))
        #expect(aggregate.summary(days: 7, now: self.now, calendar: calendar).tokens == 999)
        #expect(aggregate.summary(days: 1, now: self.now, calendar: calendar).tokens == nil)
        #expect(aggregate.summary(days: 30, now: self.now, calendar: calendar).tokens == nil)
        let partial = NativeOrbitAccountMetrics(usage: self.costSnapshot(daily: [today], partial: true))
        #expect(partial.summary(days: 1, now: self.now, calendar: calendar).cost == 1)
        #expect(partial.summary(days: 1, now: self.now, calendar: calendar).isPartial)
        let missing = self.entry(date: self.now, tokens: nil, cost: nil, requests: nil, calendar: calendar)
        let unknown = NativeOrbitAccountMetrics(usage: self.costSnapshot(daily: [missing]))
        #expect(unknown.summary(days: 1, now: self.now, calendar: calendar).tokens == nil)
        #expect(unknown.summary(days: 1, now: self.now, calendar: calendar).cost == nil)
    }

    @Test func `known priced daily subtotals survive missing prices without marking complete tokens partial`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let today = CostUsageDailyReport.Entry(
            date: CostUsageLocalDay.key(from: self.now, calendar: calendar),
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: 100,
            requestCount: 3,
            costUSD: 1.25,
            modelsUsed: nil,
            modelBreakdowns: nil,
            unpricedRequestCount: 1)
        let yesterday = self.entry(
            date: self.now.addingTimeInterval(-86400), tokens: 200, cost: nil, requests: 2, calendar: calendar)
        let metrics = NativeOrbitAccountMetrics(usage: self.costSnapshot(daily: [today, yesterday]))
        let day = metrics.summary(days: 1, now: self.now, calendar: calendar)
        #expect(day.cost == 1.25)
        #expect(day.costIsPartial)
        #expect(day.tokens == 100)
        #expect(!day.isPartial)
        let week = metrics.summary(days: 7, now: self.now, calendar: calendar)
        #expect(week.cost == 1.25)
        #expect(week.costIsPartial)
        #expect(week.tokens == 300)
        #expect(!week.isPartial)
    }

    @Test func `unknown or invalid prices never fabricate zero and reported zero remains real`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        for cost in [nil, Double.nan, Double.infinity, -1] as [Double?] {
            let entry = self.entry(date: self.now, tokens: 10, cost: cost, requests: 1, calendar: calendar)
            let metrics = NativeOrbitAccountMetrics(usage: self.costSnapshot(daily: [entry]))
            let summary = metrics.summary(days: 1, now: self.now, calendar: calendar)
            #expect(summary.cost == nil)
            #expect(summary.costIsPartial)
            #expect(summary.tokens == 10)
            #expect(!summary.isPartial)
        }
        let zero = self.entry(date: self.now, tokens: 10, cost: 0, requests: 1, calendar: calendar)
        let metrics = NativeOrbitAccountMetrics(usage: self.costSnapshot(daily: [zero]))
        #expect(metrics.summary(days: 1, now: self.now, calendar: calendar).cost == 0)
        #expect(!metrics.summary(days: 1, now: self.now, calendar: calendar).costIsPartial)
    }

    @Test func `account billing spend remains separate from selected calendar totals`() {
        let spend = ProviderCostSnapshot(
            used: 12.5,
            limit: 100,
            currencyCode: "USD",
            period: "Monthly",
            resetsAt: self.now.addingTimeInterval(86400),
            updatedAt: self.now)
        let snapshot = UsageSnapshot(primary: nil, secondary: nil, providerCost: spend, updatedAt: self.now)
        let metrics = NativeOrbitAccountMetrics.make(provider: .claude, snapshot: snapshot, usage: nil, now: self.now)
        #expect(metrics.reportedSpend == spend)
        for days in [1, 7, 30] {
            #expect(metrics.summary(days: days, now: self.now).cost == nil)
            #expect(metrics.summary(days: days, now: self.now).tokens == nil)
        }
        #expect(metrics.bankedResets == nil)
        let balance = UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: ProviderCostSnapshot(used: 50, limit: 0, currencyCode: "Points", updatedAt: self.now),
            updatedAt: self.now)
        #expect(NativeOrbitAccountMetrics.make(provider: .minimax, snapshot: balance, usage: nil, now: self.now)
            .reportedSpend == nil)
    }

    @Test func `shared extra usage arc compares pooled spending against its own limit`() {
        let cost = ProviderCostSnapshot(
            used: 900, limit: 1000, currencyCode: "USD", personalUsed: 10, updatedAt: self.now)
        let metrics = NativeOrbitAccountMetrics(reportedSpend: cost)
        #expect(metrics.extraUsageFraction == 0.9)
        let uncapped = NativeOrbitAccountMetrics(reportedSpend: ProviderCostSnapshot(
            used: 10, limit: 0, currencyCode: "USD", updatedAt: self.now))
        #expect(uncapped.extraUsageFraction == nil)
    }

    @Test func `unidentified Kimi ambient chart shows only its actual current observations`() {
        let store = self.store()
        store.planUtilizationHistory[.kimi] = PlanUtilizationHistoryBuckets(unscoped: [
            PlanUtilizationSeriesHistory(name: "nativeQuota:primary", windowMinutes: 300, entries: [
                .init(capturedAt: self.now.addingTimeInterval(-3600), usedPercent: 99, resetsAt: nil),
            ]),
        ])
        store.snapshots[.kimi] = self.snapshot(at: self.now, used: 42)
        let first = store.nativeOrbitAccounts(for: .kimi)[0]
        #expect(first.history.filter { $0.name.rawValue.hasPrefix("nativeQuota:") }.count == 4)
        #expect(first.history.first { $0.name.rawValue == "nativeMetric:allowances" }?
            .entries.first?.nativeMetrics?.requestQuotas?.isEmpty == true)
        #expect(first.history.allSatisfy { $0.entries.count == 1 && $0.entries.first?.capturedAt == self.now })
        #expect(first.history.first { $0.name.rawValue == "nativeQuota:primary" }?.entries.first?.usedPercent == 42)
        let next = self.now.addingTimeInterval(120)
        store.snapshots[.kimi] = self.snapshot(at: next, used: 50)
        #expect(store.nativeOrbitAccounts(for: .kimi)[0].history.allSatisfy {
            $0.entries.count == 1 && $0.entries.first?.capturedAt == next
        })
        #expect(store.planUtilizationHistory[.kimi]?.unscoped.first?.entries.first?.usedPercent == 99)
    }

    @Test func `Claude current observation appears before history persistence and deduplicates afterward`() async {
        let store = self.store()
        store.settings.claudeSwapEnabled = true
        let account = self.claudeAccount(email: "fixture@example.com", organization: "One")
        store.claudeSwapAccountSnapshots = [account]
        let pending = store.nativeOrbitAccounts(for: .claude)[0].history
        #expect(!pending.isEmpty)
        #expect(pending.allSatisfy { $0.entries.count == 1 && $0.entries.first?.capturedAt == self.now })
        await store.recordNativeClaudeSwapHistory([account])
        #expect(store.nativeOrbitAccounts(for: .claude)[0].history == pending)
    }

    @Test func `banked resets count only real unexpired inventory and remain absent for unsupported providers`() {
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            claudeResetCredits: ClaudeRateLimitResetCreditsSnapshot(
                expirations: [nil, self.now.addingTimeInterval(-1), self.now.addingTimeInterval(3600)],
                updatedAt: self.now),
            updatedAt: self.now)
        let claude = NativeOrbitAccountMetrics.make(provider: .claude, snapshot: snapshot, usage: nil, now: self.now)
        #expect(claude.bankedResets == 2)
        #expect(claude.nextResetCreditExpiry == self.now.addingTimeInterval(3600))
        #expect(NativeOrbitAccountMetrics.make(provider: .kimi, snapshot: snapshot, usage: nil, now: self.now)
            .bankedResets == nil)
    }

    @Test func `Codex history restores each account credit cap without borrowing the active owner`() async throws {
        let store = self.store()
        let accounts = [
            self.codexAccount(id: "active", email: "active@example.com", live: true),
            self.codexAccount(id: "sibling", email: "sibling@example.com", live: false),
        ]
        let projection = CodexVisibleAccountProjection(
            visibleAccounts: accounts,
            activeVisibleAccountID: "active",
            liveVisibleAccountID: "active",
            hasUnreadableAddedAccountStore: false)
        let captured = self.now.addingTimeInterval(-600)
        func records(at date: Date, amounts: [Double]) -> [CodexAccountUsageSnapshot] {
            accounts.enumerated().map { index, account in
                .init(
                    account: account,
                    snapshot: self.snapshot(at: date, used: 10),
                    error: nil,
                    sourceLabel: "fixture",
                    credits: .init(
                        remaining: 100 - amounts[index],
                        events: [],
                        updatedAt: date,
                        codexCreditLimit: .init(
                            used: amounts[index],
                            limit: 100,
                            remainingPercent: 100 - amounts[index],
                            resetsAt: self.now.addingTimeInterval(86400),
                            updatedAt: date)))
            }
        }
        let prior = records(at: captured, amounts: [20, 60])
        store.codexAccountSnapshots = prior
        await store.recordNativeCodexAccountHistory(prior, projection: projection)
        let current = records(at: self.now, amounts: [80, 90])
        store.codexAccountSnapshots = current
        await store.recordNativeCodexAccountHistory(current, projection: projection)
        let rows = store.nativeOrbitCodexAccounts(projection)
        for (index, account) in accounts.enumerated() {
            let row = try #require(rows.first { $0.id == account.id })
            let historical = row.metrics.at(captured, observedAt: row.updatedAt, history: row.history)
            #expect(historical.reportedSpend?.used == [20.0, 60.0][index])
            #expect(historical.reportedSpend?.currencyCode == "Credits")
            #expect(row.metrics.extraUsageFraction == [0.8, 0.9][index])
            #expect(row.history.first { $0.name.rawValue == "nativeMetric:spend" }?.entries.count == 2)
        }
    }

    @Test func `anonymous auxiliary observations are not adopted by a newly selected account`() async throws {
        let store = self.store()
        store.settings.addTokenAccount(provider: .grok, label: "Owner", token: "fixture")
        let account = try #require(store.settings.tokenAccounts(for: .grok).first)
        let anonymous = UsageStore.nativeOrbitHistoryIncludingCurrentSnapshot(
            [],
            provider: .grok,
            snapshot: .init(
                primary: nil,
                secondary: nil,
                providerCost: .init(used: 25, limit: 100, currencyCode: "USD", updatedAt: self.now),
                updatedAt: self.now))
        store.planUtilizationHistory[.grok] = .init(unscoped: anonymous)
        await store.recordPlanUtilizationHistorySample(
            provider: .grok,
            snapshot: self.snapshot(at: self.now, used: 10),
            account: account,
            now: self.now)
        #expect(store.planUtilizationHistory[.grok]?.unscoped == anonymous)
        let owned = store.planUtilizationHistory[.grok]?.accounts.values.flatMap(\.self) ?? []
        #expect(!owned.contains { $0.name.rawValue == "nativeMetric:spend" })
    }

    private func codexAccount(id: String, email: String, live: Bool) -> CodexVisibleAccount {
        CodexVisibleAccount(
            id: id,
            email: email,
            workspaceAccountID: id,
            authFingerprint: "fixture-" + id,
            storedAccountID: nil,
            selectionSource: .profileHome(path: "/tmp/history-" + id),
            isActive: live,
            isLive: live,
            canReauthenticate: false,
            canRemove: false)
    }

    private func snapshot(at date: Date, used: Double) -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(usedPercent: used, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 24, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            tertiary: RateWindow(usedPercent: 43, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            extraRateWindows: [
                NamedRateWindow(id: "kimi-monthly", title: "Monthly", window: RateWindow(
                    usedPercent: 60, windowMinutes: 43200, resetsAt: nil, resetDescription: nil)),
                NamedRateWindow(
                    id: "unknown",
                    title: "Unavailable",
                    window: RateWindow(
                        usedPercent: 0,
                        windowMinutes: 300,
                        resetsAt: nil,
                        resetDescription: nil),
                    usageKnown: false),
            ],
            updatedAt: date)
    }

    private func claudeAccount(email: String, organization: String, lastKnown: Bool = false)
    -> ProviderAccountUsageSnapshot {
        ProviderAccountUsageSnapshot(
            id: .init(source: "claude-swap", opaqueID: "1"),
            provider: .claude,
            displayLabel: email,
            accountEmail: email,
            accountOrganizationName: organization,
            isActive: true,
            usesLastKnownUsage: lastKnown,
            snapshot: self.snapshot(at: self.now, used: 42),
            error: nil,
            sourceLabel: "fixture")
    }

    private func costSnapshot(daily: [CostUsageDailyReport.Entry], days: Int = 30, partial: Bool = false)
    -> CostUsageTokenSnapshot {
        CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: 999,
            last30DaysCostUSD: 999,
            historyDays: days,
            historyScanIsPartial: partial,
            costProvenance: .listPriceEstimate,
            daily: daily,
            updatedAt: self.now)
    }

    private func entry(date: Date, tokens: Int?, cost: Double?, requests: Int?, calendar: Calendar)
    -> CostUsageDailyReport.Entry {
        CostUsageDailyReport.Entry(
            date: CostUsageLocalDay.key(from: date, calendar: calendar),
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: tokens,
            requestCount: requests,
            costUSD: cost,
            modelsUsed: nil,
            modelBreakdowns: nil)
    }

    private func store() -> UsageStore {
        let settings = testSettingsStore(
            suiteName: "NativeOrbitHistoryMetrics", userDefaults: InMemoryUserDefaults(), nativeDesignEnabled: true)
        enableTestProviders([.kimi, .claude, .codex], settings: settings)
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
