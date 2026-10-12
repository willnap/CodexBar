import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct NativeOrbitHistoricalMetricPersistenceTests {
    private let now = Date(timeIntervalSince1970: 1_791_740_000)

    @Test func `UTC provider coverage cannot prove an unobserved following UTC day in London`() throws {
        let observed = try #require(ISO8601DateParser.parse("2026-10-12T23:30:00Z"))
        let tomorrow = try #require(ISO8601DateParser.parse("2026-10-13T00:10:00Z"))
        let snapshot = try ProviderPluginSnapshotMapper.map(
            JSONProviderPluginValue([
                "costUsage": [
                    "currency": "USD", "historyDays": 1, "windowEnd": "2026-10-12",
                    "metrics": ["totalTokens": true, "cost": true], "entries": [],
                ],
            ]),
            provider: .lithosai,
            now: observed)
        var london = Calendar(identifier: .gregorian)
        london.timeZone = try #require(TimeZone(identifier: "Europe/London"))
        let summary = NativeOrbitAccountMetrics(usage: snapshot.costUsage)
            .summary(days: 1, now: tomorrow, calendar: london)
        #expect(summary.tokens == nil)
        #expect(summary.cost == nil)
        #expect(summary.isPartial)
    }

    @Test func `known same day plugin prices survive unpriced rows as an explicitly partial subtotal`() throws {
        let snapshot = try ProviderPluginSnapshotMapper.map(
            JSONProviderPluginValue([
                "costUsage": [
                    "currency": "USD", "historyDays": 11, "windowEnd": "2026-10-11",
                    "entries": [
                        ["date": "2026-10-11", "totalTokens": 100, "cost": 3.0],
                        ["date": "2026-10-11", "totalTokens": 40],
                    ],
                ],
            ]),
            provider: .bifrost,
            now: self.now)
        let metrics = NativeOrbitAccountMetrics(usage: snapshot.costUsage)
        #expect(metrics.summary(days: 1, now: self.now).tokens == 140)
        #expect(metrics.summary(days: 1, now: self.now).cost == 3)
        #expect(metrics.summary(days: 1, now: self.now).costIsPartial)
    }

    @Test func `partial source period totals retain their warning and estimated spending`() {
        let report = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: 300,
            last30DaysCostUSD: 3,
            historyDays: 30,
            historyCoverageIsEstablished: false,
            historyScanIsPartial: true,
            historyLabel: "Gateway last 30 days",
            costProvenance: .listPriceEstimate,
            daily: [],
            updatedAt: self.now)
        let metrics = NativeOrbitAccountMetrics(usage: report)
        #expect(metrics.providerPeriodTokenReading(now: self.now)?.isPartial == true)
        #expect(metrics.providerPeriodSpendReading(now: self.now)?.cost == 3)
        #expect(metrics.providerPeriodSpendReading(now: self.now)?.estimated == true)
        #expect(metrics.providerPeriodSpendReading(now: self.now)?.isPartial == true)
        #expect(metrics.providerPeriodSpendReading(now: self.now.addingTimeInterval(-1)) == nil)
    }

    @Test func `complete empty profile retains historical zero without fabricating unknown prices`() {
        for partial in [false, true] {
            let usage = CostUsageTokenSnapshot(
                sessionTokens: nil,
                sessionCostUSD: nil,
                last30DaysTokens: 0,
                last30DaysCostUSD: 0,
                historyDays: 30,
                historyScanIsPartial: partial,
                daily: [],
                updatedAt: self.now)
            let summary = NativeOrbitAccountMetrics(usage: usage).summary(
                days: 7,
                now: self.now.addingTimeInterval(-3600))
            #expect(summary.cost == (partial ? nil : 0))
            #expect(summary.tokens == (partial ? nil : 0))
            #expect(summary.requests == nil)
            #expect(NativeOrbitAccountMetrics(usage: usage).summary(
                days: 30,
                now: self.now.addingTimeInterval(-86400)).cost == nil)
        }
    }

    @Test func `dated provider token and money readings survive history persistence and corrections`() throws {
        let captured = self.now.addingTimeInterval(-60)
        let day = CostUsageLocalDay.key(from: self.now, calendar: .current)
        func report(_ tokens: Int, _ cost: Double, at date: Date) -> CostUsageTokenSnapshot {
            CostUsageTokenSnapshot(
                sessionTokens: nil,
                sessionCostUSD: nil,
                last30DaysTokens: tokens,
                last30DaysCostUSD: cost,
                historyDays: 30,
                daily: [.init(
                    date: day,
                    inputTokens: nil,
                    outputTokens: nil,
                    totalTokens: tokens,
                    costUSD: cost,
                    modelsUsed: nil,
                    modelBreakdowns: nil)],
                updatedAt: date)
        }
        let prior = UsageSnapshot(
            primary: nil,
            secondary: nil,
            costUsage: report(
                10,
                1,
                at: captured),
            updatedAt: captured)
        let histories = UsageStore.nativeOrbitHistoryIncludingCurrentSnapshot([], provider: .groq, snapshot: prior)
        let restored = try JSONDecoder().decode(
            [PlanUtilizationSeriesHistory].self,
            from: JSONEncoder().encode(histories))
        let metrics = NativeOrbitAccountMetrics(usage: report(100, 10, at: self.now))
        let historical = metrics.at(captured, observedAt: self.now, history: restored)
            .summary(days: 1, now: captured)
        #expect(historical.tokens == 10)
        #expect(historical.cost == 1)
        let restarted = NativeOrbitAccountMetrics.empty.at(nil, observedAt: nil, history: restored)
        #expect(restarted.summary(days: 1, now: captured).tokens == 10)
    }

    @Test func `historical provider receipts preserve incomplete prices and exclude newer corrections`() throws {
        let day = CostUsageLocalDay.key(from: self.now, calendar: .current)
        let report = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: 10,
            last30DaysCostUSD: 5,
            historyDays: 30,
            daily: [.init(
                date: day,
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: 10,
                costUSD: 5,
                modelsUsed: ["model-without-price"],
                modelBreakdowns: [.init(
                    modelName: "model-without-price",
                    costUSD: nil,
                    totalTokens: 10)])],
            updatedAt: self.now)
        let snapshot = UsageSnapshot(primary: nil, secondary: nil, costUsage: report, updatedAt: self.now)
        let histories = UsageStore.nativeOrbitHistoryIncludingCurrentSnapshot([], provider: .groq, snapshot: snapshot)
        let restored = try JSONDecoder().decode(
            [PlanUtilizationSeriesHistory].self,
            from: JSONEncoder().encode(histories))
        let archived = NativeOrbitAccountMetrics.empty.at(nil, observedAt: nil, history: restored)
        #expect(archived.summary(days: 1, now: self.now).cost == 5)
        #expect(archived.summary(days: 1, now: self.now).costIsPartial)
        let current = NativeOrbitAccountMetrics(usage: report)
        #expect(current.at(self.now.addingTimeInterval(-1), observedAt: self.now, history: restored).usage == nil)
    }

    @Test func `unchanged empty daily receipts retain newly observed coverage on the next day`() {
        func snapshot(at date: Date) -> UsageSnapshot {
            UsageSnapshot(
                primary: nil,
                secondary: nil,
                costUsage: CostUsageTokenSnapshot(
                    sessionTokens: nil,
                    sessionCostUSD: nil,
                    last30DaysTokens: 0,
                    last30DaysCostUSD: 0,
                    historyDays: 30,
                    daily: [],
                    updatedAt: date),
                updatedAt: date)
        }
        let first = UsageStore.nativeOrbitHistoryIncludingCurrentSnapshot(
            [],
            provider: .groq,
            snapshot: snapshot(at: self.now))
        let tomorrow = self.now.addingTimeInterval(86400)
        let later = UsageStore.nativeOrbitHistoryIncludingCurrentSnapshot(
            first,
            provider: .groq,
            snapshot: snapshot(at: tomorrow))
        let restored = NativeOrbitAccountMetrics.empty.at(nil, observedAt: nil, history: later)
        #expect(restored.usage?.updatedAt == tomorrow)
        #expect(restored.summary(days: 1, now: tomorrow).tokens == 0)
        #expect(!restored.summary(days: 1, now: tomorrow).isPartial)
    }

    @Test func `aggregate token readings preserve their reported period instead of inventing selected day buckets`() {
        let report = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: 300,
            last30DaysCostUSD: nil,
            historyDays: 14,
            historyCoverageIsEstablished: false,
            historyLabel: "CloudWatch last 14 days",
            daily: [],
            updatedAt: self.now)
        let metrics = NativeOrbitAccountMetrics(usage: report)
        #expect(metrics.summary(days: 1, now: self.now).tokens == nil)
        #expect(metrics.providerPeriodTokenReading(now: self.now)?.tokens == 300)
        #expect(metrics.providerPeriodTokenReading(now: self.now)?.period == "CloudWatch last 14 days")
        #expect(metrics.providerPeriodTokenReading(now: self.now.addingTimeInterval(-1)) == nil)
    }

    @Test func `signed provider wallet debt remains an observed balance`() {
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: .init(
                used: 0,
                limit: 0,
                currencyCode: "USD",
                balance: -12.5,
                usageIsUnavailable: true,
                updatedAt: self.now),
            updatedAt: self.now)
        let metrics = NativeOrbitAccountMetrics.make(
            provider: .atlascloud,
            snapshot: snapshot,
            usage: nil,
            now: self.now)
        #expect(metrics.reportedBalance?.value == -12.5)
        #expect(metrics.reportedSpend == nil)
    }

    @Test func `Codex credit cap is additional usage with credit units`() {
        let credits = CreditsSnapshot(
            remaining: 75,
            events: [],
            updatedAt: self.now,
            codexCreditLimit: .init(
                used: 25,
                limit: 100,
                remainingPercent: 75,
                resetsAt: self.now.addingTimeInterval(86400),
                updatedAt: self.now))
        let metrics = NativeOrbitAccountMetrics.make(
            provider: .codex,
            snapshot: nil,
            usage: nil,
            now: self.now,
            credits: credits)
        #expect(metrics.reportedSpend?.currencyCode == "Credits")
        #expect(metrics.extraUsageFraction == 0.25)
        #expect(metrics.summary(days: 1, now: self.now).cost == nil)
    }

    @Test func `current snapshot preserves independently dated reset and spend observations`() throws {
        let captured = self.now.addingTimeInterval(-600)
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: .init(
                used: 20,
                limit: 100,
                currencyCode: "USD",
                updatedAt: captured),
            claudeResetCredits: .init(
                expirations: [nil],
                updatedAt: captured,
                usedExpirations: [nil]),
            updatedAt: self.now)
        let histories = UsageStore.nativeOrbitHistoryIncludingCurrentSnapshot(
            [], provider: .claude, snapshot: snapshot)
        let spend = try #require(histories.first { $0.name.rawValue == "nativeMetric:spend" })
        let resets = try #require(histories.first { $0.name.rawValue == "nativeMetric:resets" })
        #expect(spend.entries.first?.capturedAt == captured)
        #expect(resets.entries.first?.capturedAt == captured)
        #expect(spend.hasSupportedCadence)
        #expect(resets.hasSupportedCadence)
        let metrics = NativeOrbitAccountMetrics.make(
            provider: .claude,
            snapshot: snapshot,
            usage: nil,
            now: self.now)
        #expect(metrics.at(captured, observedAt: self.now, history: histories).bankedResets == 1)
    }

    @Test func `historical observation restores spend and inventory until the lane's next poll is overdue`() {
        let captured = self.now.addingTimeInterval(-600)
        let prior = UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: .init(
                used: 20,
                limit: 100,
                currencyCode: "USD",
                balance: 5,
                updatedAt: captured),
            claudeResetCredits: .init(
                expirations: [captured.addingTimeInterval(30)],
                updatedAt: captured,
                usedExpirations: [nil]),
            updatedAt: captured)
        let histories = UsageStore.nativeOrbitHistoryIncludingCurrentSnapshot([], provider: .claude, snapshot: prior)
        let current = UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: .init(
                used: 80,
                limit: 100,
                currencyCode: "USD",
                updatedAt: self.now),
            updatedAt: self.now)
        let metrics = NativeOrbitAccountMetrics.make(
            provider: .claude,
            snapshot: current,
            usage: nil,
            now: self.now)
        let historical = metrics.at(captured, observedAt: self.now, history: histories)
        #expect(historical.reportedSpend?.used == 20)
        #expect(historical.reportedBalance?.value == 5)
        #expect(historical.extraUsageFraction == 0.2)
        #expect(historical.bankedResets == 1)
        #expect(historical.usedResets == 1)
        #expect(metrics.at(captured.addingTimeInterval(-1), observedAt: self.now, history: histories)
            .reportedSpend == nil)
        for seconds in [60.0, 840] {
            // The latest reading stands until its next poll is overdue; its banked reset expired at +30 s.
            let between = metrics.at(captured.addingTimeInterval(seconds), observedAt: self.now, history: histories)
            #expect(between.reportedSpend?.used == 20)
            #expect(between.reportedSpend?.updatedAt == captured)
            #expect(between.reportedBalance?.value == 5)
            #expect(between.bankedResets == 0)
            #expect(between.usedResets == 1)
        }
        let gap = metrics.at(captured.addingTimeInterval(901), observedAt: self.now, history: histories)
        #expect(gap.reportedSpend == nil)
        #expect(gap.reportedBalance == nil)
        #expect(gap.bankedResets == nil)
        #expect(gap.usedResets == 0)
    }

    @Test func `hover reaches independently recorded complications without inventing quota observations`() throws {
        let captured = self.now.addingTimeInterval(-3600.25)
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: .init(
                used: 20,
                limit: 100,
                currencyCode: "USD",
                balance: 5,
                updatedAt: captured),
            claudeResetCredits: .init(
                expirations: [nil],
                updatedAt: captured),
            updatedAt: captured)
        var histories = UsageStore.nativeOrbitHistoryIncludingCurrentSnapshot([], provider: .claude, snapshot: snapshot)
        histories.append(.init(name: "nativeQuota:primary", windowMinutes: 300, entries: [
            .init(capturedAt: captured.addingTimeInterval(-1800), usedPercent: 20, resetsAt: nil),
            .init(capturedAt: captured.addingTimeInterval(1800), usedPercent: 40, resetsAt: nil),
        ]))
        let widget = NativeOrbitHistoryWidget(histories: histories, now: self.now, provider: .claude)
        let selected = widget.inspectionDate(at: captured.addingTimeInterval(1), plotWidth: 200)
        #expect(selected == captured)
        let restored = NativeOrbitAccountMetrics.empty.at(selected, observedAt: self.now, history: histories)
        #expect(restored.reportedSpend?.used == 20)
        #expect(restored.reportedBalance?.value == 5)
        #expect(restored.bankedResets == 1)
        let lane = try #require(widget.lanes.first)
        let quota = try #require(widget.nearest(lane, to: selected))
        #expect(quota.id.capturedAt != selected)
        #expect(widget.seriesHelp(lane, selectedDate: selected).contains("Interpolated"))
        let secondsPerPoint = self.now.timeIntervalSince(widget.start) / 200
        let gap = captured.addingTimeInterval(-secondsPerPoint * 3.01)
        #expect(widget.inspectionDate(at: gap, plotWidth: 200) == gap)
        #expect(NativeOrbitAccountMetrics.empty.at(gap, observedAt: self.now, history: histories).reportedSpend == nil)
    }

    @Test func `metric-only history exposes real complication timestamps at every range`() {
        let captured = self.now.addingTimeInterval(-3600.25)
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: .init(
                used: 20,
                limit: 100,
                currencyCode: "USD",
                updatedAt: captured),
            updatedAt: captured)
        let histories = UsageStore.nativeOrbitHistoryIncludingCurrentSnapshot([], provider: .claude, snapshot: snapshot)
        for days in [1, 7, 30] {
            let widget = NativeOrbitHistoryWidget(histories: histories, now: self.now, days: days, provider: .claude)
            let secondsPerPoint = self.now.timeIntervalSince(widget.start) / 200
            let selected = widget.inspectionDate(at: captured.addingTimeInterval(secondsPerPoint * 2.5), plotWidth: 200)
            #expect(selected == captured)
            #expect(NativeOrbitAccountMetrics.empty.at(selected, observedAt: self.now, history: histories)
                .reportedSpend?.used == 20)
            let gap = captured.addingTimeInterval(-secondsPerPoint * 3.01)
            #expect(widget.inspectionDate(at: gap, plotWidth: 200) == gap)
        }
    }

    @Test func `stale live inventory cannot leak its expired count into an earlier gap`() {
        let captured = self.now.addingTimeInterval(-7200)
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            claudeResetCredits: .init(
                expirations: [captured.addingTimeInterval(3600)],
                updatedAt: captured),
            updatedAt: captured)
        let histories = UsageStore.nativeOrbitHistoryIncludingCurrentSnapshot(
            [], provider: .claude, snapshot: snapshot)
        let metrics = NativeOrbitAccountMetrics.make(
            provider: .claude,
            snapshot: snapshot,
            usage: nil,
            now: self.now)
        #expect(metrics.bankedResets == 0)
        #expect(metrics.at(captured.addingTimeInterval(1800), observedAt: captured, history: histories)
            .bankedResets == nil)
    }

    @Test func `metric persistence keeps fractional inventory deadlines and source observations`() throws {
        let captured = self.now.addingTimeInterval(-60.25)
        let expiration = captured.addingTimeInterval(30.75)
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            claudeResetCredits: .init(
                expirations: [expiration],
                updatedAt: captured),
            updatedAt: captured)
        let histories = UsageStore.nativeOrbitHistoryIncludingCurrentSnapshot(
            [], provider: .claude, snapshot: snapshot)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = PlanUtilizationHistoryStore(directoryURL: directory)
        #expect(persistence.save([.claude: .init(accounts: ["owner": histories])]).isEmpty)
        let reloaded = try #require(persistence.load()[.claude]?.accounts["owner"])
        #expect(reloaded.first?.entries.first?.capturedAt == captured)
        let metrics = NativeOrbitAccountMetrics.empty.at(
            captured, observedAt: nil, history: reloaded)
        #expect(metrics.bankedResets == 1)
        #expect(metrics.nextResetCreditExpiry == expiration)
    }

    @Test func `account dated credit usage is retained alongside independent credit balance observations`() {
        let credits = CreditsSnapshot(
            remaining: 0,
            events: [.init(
                date: self.now.addingTimeInterval(-3600),
                service: "Codex",
                creditsUsed: 4)],
            updatedAt: self.now)
        let snapshot = UsageSnapshot(primary: nil, secondary: nil, updatedAt: self.now)
        let histories = UsageStore.nativeOrbitHistoryIncludingCurrentSnapshot(
            [], provider: .codex, snapshot: snapshot, credits: credits)
        #expect(histories.contains { $0.name.rawValue == "nativeMetric:creditEvents" })
    }

    @Test func `dated credit usage does not count polls or future events as consumption`() {
        let event = CreditEvent(date: self.now.addingTimeInterval(-3600.25), service: "Codex", creditsUsed: 4)
        let credits = CreditsSnapshot(remaining: 0, events: [event, event], updatedAt: self.now)
        let snapshot = UsageSnapshot(primary: nil, secondary: nil, updatedAt: self.now)
        let once = UsageStore.nativeOrbitHistoryIncludingCurrentSnapshot(
            [], provider: .codex, snapshot: snapshot, credits: credits)
        let twice = UsageStore.nativeOrbitHistoryIncludingCurrentSnapshot(
            once, provider: .codex, snapshot: snapshot, credits: credits)
        let metrics = NativeOrbitAccountMetrics.make(
            provider: .codex,
            snapshot: snapshot,
            usage: nil,
            now: self.now,
            credits: credits)
        let reading = metrics.at(nil, observedAt: self.now, history: twice)
        #expect(reading.recordedCreditUsage(days: 7, now: self.now) == 8)
        #expect(reading.recordedCreditUsage(days: 7, now: event.date.addingTimeInterval(-1)) == nil)
        #expect(reading.creditUsageEvents.count == 2)
    }

    @Test func `restart preserves exact billing and balance observation timestamps`() throws {
        let captured = self.now.addingTimeInterval(-60.25)
        let deadline = self.now.addingTimeInterval(3600.75)
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: .init(
                used: 20,
                limit: 100,
                currencyCode: "USD",
                resetsAt: deadline,
                balance: 5,
                balanceUpdatedAt: captured,
                updatedAt: captured),
            updatedAt: captured)
        let histories = UsageStore.nativeOrbitHistoryIncludingCurrentSnapshot(
            [], provider: .claude, snapshot: snapshot)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = PlanUtilizationHistoryStore(directoryURL: directory)
        #expect(persistence.save([.claude: .init(accounts: ["owner": histories])]).isEmpty)
        let reloaded = try #require(persistence.load()[.claude]?.accounts["owner"])
        let reading = NativeOrbitAccountMetrics.empty.at(captured, observedAt: nil, history: reloaded)
        #expect(reading.reportedSpend?.updatedAt == captured)
        #expect(reading.reportedSpend?.resetsAt == deadline)
        #expect(reading.reportedBalance?.updatedAt == captured)
    }
}
