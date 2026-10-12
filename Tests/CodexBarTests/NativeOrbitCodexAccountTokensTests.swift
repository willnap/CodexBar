import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct NativeOrbitCodexAccountTokensTests {
    private let utc = CostUsageBucketTimeZone.calendar(identifier: "UTC")
    /// 2026-10-12 14:30:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_791_815_400)

    @Test
    func `a lagging account day takes the larger real-time attributed local count`() throws {
        let server = try self.serverHistory(
            [("2026-10-11", 1_211_426_983), ("2026-10-12", 71_568_415)],
            fetchedAt: self.now.addingTimeInterval(-900))
        let local = self.attributed([
            ("2026-10-11", 1_163_400_000, 285.42),
            ("2026-10-12", 504_013_566, 82.26),
        ])
        var metrics = NativeOrbitAccountMetrics.make(
            provider: .codex, snapshot: nil, usage: server.tokenSnapshot(), now: self.now, localUsage: local)
        metrics.accountUsageHistory = server
        let today = metrics.summary(days: 1, now: self.now, calendar: self.utc)
        #expect(today.tokens == 504_013_566)
        #expect(today.isPartial)
        #expect(today.usageScope == .account)
        #expect(today.cost == 82.26)
        #expect(today.costUsageScope == .localMachine)
        // A completed day where the account total (other machines included) is larger keeps the account total.
        let twoDays = metrics.summary(days: 2, now: self.now, calendar: self.utc)
        #expect(twoDays.tokens == 1_211_426_983 + 504_013_566)
        #expect(twoDays.cost.map { abs($0 - 367.68) < 0.0001 } == true)
    }

    @Test
    func `an empty probe home is not spend evidence beside reported account tokens`() throws {
        let server = try self.serverHistory(
            [("2026-10-09", 714_916_440), ("2026-10-10", 785_890_479)],
            fetchedAt: self.now)
        let probe = CostUsageTokenSnapshot(
            sessionTokens: 0,
            sessionCostUSD: 0,
            last30DaysTokens: 0,
            last30DaysCostUSD: 0,
            historyDays: 365,
            daily: [],
            updatedAt: self.now)
        let zero = NativeOrbitLocalUsage(snapshot: probe, scope: .localProfile, bucketTimeZoneIdentifier: "UTC")
        let metrics = NativeOrbitAccountMetrics.make(
            provider: .codex, snapshot: nil, usage: server.tokenSnapshot(), now: self.now, localUsage: zero)
        let week = metrics.summary(days: 7, now: self.now, calendar: self.utc)
        #expect(week.tokens == 1_500_806_919)
        #expect(week.cost == nil)
        // Attributed local history with older activity is a known zero for this week; it is still not this
        // account's spend while the account itself reported tokens.
        let quiet = self.attributed([("2026-09-20", 256_100_000, 316.33)])
        let attributed = NativeOrbitAccountMetrics.make(
            provider: .codex, snapshot: nil, usage: server.tokenSnapshot(), now: self.now, localUsage: quiet)
        #expect(attributed.summary(days: 7, now: self.now, calendar: self.utc).cost == nil)
        #expect(attributed.summary(days: 30, now: self.now, calendar: self.utc).cost == 316.33)
    }

    @Test
    func `buckets adding up to lifetime make a missing account day a measured zero`() throws {
        let server = try self.serverHistory(
            [("2026-10-09", 714_916_440), ("2026-10-10", 785_890_479)],
            fetchedAt: self.now)
        let snapshot = try #require(server.tokenSnapshot())
        #expect(snapshot.historyCoverageIsEstablished)
        #expect(snapshot.bucketTimeZoneIdentifier == "UTC")
        let today = NativeOrbitAccountMetrics(usage: snapshot).summary(days: 1, now: self.now, calendar: self.utc)
        #expect(today.tokens == 0)
        #expect(today.usageScope == .account)
        #expect(today.isPartial)
        let unproven = try self.serverHistory(
            [("2026-10-09", 714_916_440), ("2026-10-10", 785_890_479)],
            fetchedAt: self.now,
            lifetime: 18_198_548_584)
        #expect(try #require(unproven.tokenSnapshot()).historyCoverageIsEstablished == false)
        #expect(NativeOrbitAccountMetrics(usage: unproven.tokenSnapshot())
            .summary(days: 1, now: self.now, calendar: self.utc).tokens == nil)
        // Lagging statistics do not prove today's absence.
        let lagging = try self.serverHistory(
            [("2026-10-09", 714_916_440), ("2026-10-10", 785_890_479)],
            fetchedAt: self.now,
            statsAsOf: "2026-10-11")
        #expect(NativeOrbitAccountMetrics(usage: lagging.tokenSnapshot())
            .summary(days: 1, now: self.now, calendar: self.utc).tokens == nil)
    }

    @Test
    func `account buckets are read as UTC days across the London midnight boundary`() throws {
        // 2026-10-12 23:30 UTC is already 2026-10-13 in London.
        let late = Date(timeIntervalSince1970: 1_791_847_800)
        let server = try self.serverHistory([("2026-10-12", 42)], fetchedAt: late)
        var london = Calendar(identifier: .gregorian)
        london.timeZone = try #require(TimeZone(identifier: "Europe/London"))
        let today = NativeOrbitAccountMetrics(usage: server.tokenSnapshot())
            .summary(days: 1, now: late, calendar: london)
        #expect(today.tokens == 42)
    }

    @Test
    func `history inspection reads completed account days fetched later and local requests for the day`() throws {
        let fetchedAt = self.now
        let server = try self.serverHistory(
            [("2026-10-05", 10), ("2026-10-08", 20), ("2026-10-09", 4000), ("2026-10-12", 7)],
            fetchedAt: fetchedAt)
        // 2026-10-09 12:00 UTC, before any account response was fetched.
        let inspected = Date(timeIntervalSince1970: 1_791_547_200)
        let local = self.attributed(
            [("2026-10-09", 150, 1.5)],
            slices: [(inspected.addingTimeInterval(-7200), 100, 1), (inspected.addingTimeInterval(3600), 50, 0.5)])
        var metrics = NativeOrbitAccountMetrics.make(
            provider: .codex, snapshot: nil, usage: server.tokenSnapshot(), now: self.now, localUsage: local)
        metrics.accountUsageHistory = server
        let past = metrics.at(inspected, observedAt: nil, history: [])
        let week = past.summary(days: 7, now: inspected, calendar: self.utc)
        // Completed 10-05 and 10-08 plus requests on 10-09 before the instant; the full 10-09 bucket is later data.
        #expect(week.tokens == 10 + 20 + 100)
        let day = past.summary(days: 1, now: inspected, calendar: self.utc)
        #expect(day.tokens == 100)
        #expect(day.cost == 1)
        // A quiet inspected day with no account bucket and no local request before the instant is a zero.
        let quiet = Date(timeIntervalSince1970: 1_791_288_000)
        let quietDay = metrics.at(quiet, observedAt: nil, history: []).summary(days: 1, now: quiet, calendar: self.utc)
        #expect(quietDay.tokens == 0)
    }

    @Test
    func `stale retained Codex home reports remain usable as partial lower bounds`() throws {
        let local = NativeOrbitLocalUsage(
            snapshot: self.attributed([("2026-10-12", 500, 2)]).snapshot,
            scope: .localMachine,
            bucketTimeZoneIdentifier: "UTC",
            isStale: true)
        let metrics = NativeOrbitAccountMetrics.make(
            provider: .codex, snapshot: nil, usage: nil, now: self.now, localUsage: local)
        let today = metrics.summary(days: 1, now: self.now, calendar: self.utc)
        #expect(today.tokens == 500)
        #expect(today.cost == 2)
        #expect(today.isPartial)
        #expect(today.costIsPartial)
        let attributedStale = NativeOrbitLocalUsage(
            snapshot: local.snapshot,
            scope: .localMachine,
            bucketTimeZoneIdentifier: "UTC",
            isAccountAttributed: true,
            isStale: true)
        let server = try self.serverHistory([("2026-10-11", 9)], fetchedAt: self.now)
        let combined = NativeOrbitAccountMetrics.make(
            provider: .codex,
            snapshot: nil,
            usage: server.tokenSnapshot(),
            now: self.now,
            localUsage: attributedStale)
        let summary = combined.summary(days: 1, now: self.now, calendar: self.utc)
        #expect(summary.tokens == 500)
        #expect(summary.isPartial)
        #expect(summary.costIsPartial)
    }

    private func attributed(
        _ days: [(String, Int, Double)],
        slices: [(Date, Int, Double)] = []) -> NativeOrbitLocalUsage
    {
        let report = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: nil,
            last30DaysCostUSD: nil,
            historyDays: 33,
            historyLabel: "Local sessions served by this account",
            bucketTimeZoneIdentifier: "UTC",
            costProvenance: .listPriceEstimate,
            daily: days.map {
                CostUsageDailyReport.Entry(
                    date: $0.0,
                    inputTokens: nil,
                    outputTokens: nil,
                    totalTokens: $0.1,
                    costUSD: $0.2,
                    modelsUsed: nil,
                    modelBreakdowns: nil)
            },
            quotaSlices: slices.map { CostUsageTimedEntry(timestamp: $0.0, totalTokens: $0.1, costUSD: $0.2) },
            updatedAt: self.now)
        return NativeOrbitLocalUsage(
            snapshot: report,
            scope: .localMachine,
            bucketTimeZoneIdentifier: "UTC",
            isAccountAttributed: true)
    }

    private func serverHistory(
        _ days: [(String, Int)],
        fetchedAt: Date,
        statsAsOf: String = "2026-10-12",
        lifetime: Int? = nil) throws -> NativeCodexAccountUsageHistory
    {
        let stats: [String: Any] = [
            "daily_usage_buckets": days.map { ["start_date": $0.0, "tokens": $0.1] as [String: Any] },
            "lifetime_tokens": lifetime ?? days.reduce(0) { $0 + $1.1 },
        ]
        let response = try CodexAccountUsageHistory.decode(JSONSerialization.data(withJSONObject: [
            "stats": stats, "metadata": ["stats_as_of": statsAsOf],
        ]))
        return try #require(NativeCodexAccountUsageHistory.merging(response, previous: nil, fetchedAt: fetchedAt))
    }
}
