import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct NativeCodexSessionWindowAttributionTests {
    private let calendar = CostUsageBucketTimeZone.calendar(identifier: "UTC")
    /// 2026-10-12 12:00:00 UTC.
    private let noon = Date(timeIntervalSince1970: 1_791_806_400)
    private var windowA: Date {
        self.noon.addingTimeInterval(5 * 86400)
    }

    private var windowB: Date {
        self.noon.addingTimeInterval(4 * 86400 + 3600)
    }

    @Test
    func `each account receives only the requests its own weekly window served`() throws {
        let slices = [
            self.slice(-3600, tokens: 100, cost: 1),
            self.slice(-1800, tokens: 200, cost: 2),
            self.slice(-600, tokens: 400, cost: 4),
        ]
        let timeline = self.timeline([(-3600, self.windowA), (-1800, self.windowB), (-600, self.windowA)])
        let result = NativeCodexSessionWindowAttribution.attribute(
            reports: [self.report(slices)],
            timeline: timeline,
            evidence: ["a": [self.windowA.addingTimeInterval(30)], "b": [self.windowB]],
            calendar: self.calendar)
        let first = try #require(result.reports["a"])
        let second = try #require(result.reports["b"])
        #expect(first.daily.map(\.totalTokens) == [500])
        #expect(first.daily.map(\.costUSD) == [5])
        #expect(first.quotaSlices.count == 2)
        #expect(second.daily.map(\.totalTokens) == [200])
        #expect(second.daily.map(\.costUSD) == [2])
        #expect(result.unattributedDays.isEmpty)
        #expect(first.bucketTimeZoneIdentifier == self.calendar.timeZone.identifier)
        #expect(first.historyIsFullyScanned)
    }

    @Test
    func `a session created by another login is counted for the account whose window served it`() {
        // One long-running rollout: its first requests ran under account B, later ones under account A.
        let slices = (0..<6).map { self.slice(Double($0 * 60) - 3600, tokens: 10, cost: 0.5) }
        let events = (0..<6).map { (Double($0 * 60) - 3600, $0 < 2 ? self.windowB : self.windowA) }
        let result = NativeCodexSessionWindowAttribution.attribute(
            reports: [self.report(slices)],
            timeline: self.timeline(events),
            evidence: ["a": [self.windowA], "b": [self.windowB]],
            calendar: self.calendar)
        #expect(result.reports["a"]?.daily.first?.totalTokens == 40)
        #expect(result.reports["b"]?.daily.first?.totalTokens == 20)
    }

    @Test
    func `a window recorded by several accounts stays unattributed and marks its day partial`() {
        let slices = [self.slice(-3600, tokens: 100, cost: 1), self.slice(-60, tokens: 50, cost: 1)]
        let timeline = self.timeline([(-3600, self.windowA), (-60, self.windowB)])
        let result = NativeCodexSessionWindowAttribution.attribute(
            reports: [self.report(slices)],
            timeline: timeline,
            evidence: ["a": [self.windowA, self.windowB], "b": [self.windowB.addingTimeInterval(-20)]],
            calendar: self.calendar)
        #expect(result.reports["a"]?.daily.first?.totalTokens == 100)
        #expect(result.reports["a"]?.daily.first?.costIsPartial == true)
        #expect(result.reports["b"]?.daily.isEmpty == true)
        #expect(result.unattributedDays == ["2026-10-12"])
        #expect(result.unattributedSliceCount == 1)
    }

    @Test
    func `requests without their own event take the nearest event window only within the gap`() {
        let slices = [
            self.slice(-3600 + 1, tokens: 7, cost: nil),
            self.slice(-3600 + NativeCodexSessionWindowAttribution.maximumEventGap + 60, tokens: 9, cost: 1),
        ]
        let result = NativeCodexSessionWindowAttribution.attribute(
            reports: [self.report(slices)],
            timeline: self.timeline([(-3600, self.windowA)]),
            evidence: ["a": [self.windowA]],
            calendar: self.calendar)
        #expect(result.reports["a"]?.daily.first?.totalTokens == 7)
        // The unpriced request leaves a known-incomplete cost rather than a fabricated zero.
        #expect(result.reports["a"]?.daily.first?.costUSD == nil)
        #expect(result.reports["a"]?.daily.first?.costIsPartial == true)
        #expect(result.unattributedSliceCount == 1)
    }

    @Test
    func `conflicting windows at one instant and requests before coverage are never attributed`() {
        let slices = [self.slice(-40 * 86400, tokens: 1, cost: 1), self.slice(-60, tokens: 5, cost: 1)]
        let result = NativeCodexSessionWindowAttribution.attribute(
            reports: [self.report(slices)],
            timeline: self.timeline([(-60, self.windowA), (-60, self.windowB)]),
            evidence: ["a": [self.windowA], "b": [self.windowB]],
            calendar: self.calendar)
        #expect(result.reports["a"]?.daily.isEmpty == true)
        #expect(result.reports["b"]?.daily.isEmpty == true)
        #expect(result.unattributedSliceCount == 1)
        #expect(result.attributedSliceCount == 0)
    }

    @Test
    func `accounts without evidence get no report and incomplete scans stay partial`() {
        var report = self.report([self.slice(-60, tokens: 5, cost: 1)])
        report = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: nil,
            last30DaysCostUSD: nil,
            historyDays: 365,
            historyCoverageIsEstablished: false,
            daily: report.daily,
            quotaSlices: report.quotaSlices,
            updatedAt: self.noon)
        let result = NativeCodexSessionWindowAttribution.attribute(
            reports: [report],
            timeline: self.timeline([(-60, self.windowA)]),
            evidence: ["a": [self.windowA], "b": []],
            calendar: self.calendar)
        #expect(result.reports["b"] == nil)
        #expect(result.reports["a"]?.historyCoverageIsEstablished == false)
    }

    @Test
    func `timeline keeps only main weekly windows from session observations`() {
        let weekly = RateWindow(usedPercent: 12, windowMinutes: 10080, resetsAt: self.windowA, resetDescription: nil)
        let session = RateWindow(usedPercent: 3, windowMinutes: 300, resetsAt: self.noon, resetDescription: nil)
        let spark = NamedRateWindow(
            id: CodexAdditionalRateLimitMapper.sparkWeeklyWindowID,
            title: "Spark",
            window: RateWindow(usedPercent: 1, windowMinutes: 10080, resetsAt: self.windowB, resetDescription: nil))
        let observations = [
            NativeCodexQuotaSessionObservation(
                legacyCreatorAccountID: nil,
                snapshot: UsageSnapshot(primary: session, secondary: weekly, updatedAt: self.noon)),
            NativeCodexQuotaSessionObservation(
                legacyCreatorAccountID: nil,
                snapshot: UsageSnapshot(
                    primary: nil,
                    secondary: nil,
                    extraRateWindows: [spark],
                    updatedAt: self.noon.addingTimeInterval(1))),
        ]
        let timeline = NativeCodexSessionWindowTimeline(
            observations: observations,
            coverageStart: self.noon.addingTimeInterval(-86400),
            coverageEnd: self.noon)
        #expect(timeline.eventCount == 1)
    }

    @Test
    func `account evidence uses closed period starts and ignores unstarted floating windows`() {
        let captured = self.noon
        let floating = PlanUtilizationHistoryEntry(
            capturedAt: captured, usedPercent: 0, resetsAt: captured.addingTimeInterval(7 * 86400))
        let started = PlanUtilizationHistoryEntry(
            capturedAt: captured, usedPercent: 0, resetsAt: self.windowB)
        let used = PlanUtilizationHistoryEntry(
            capturedAt: captured.addingTimeInterval(60), usedPercent: 4, resetsAt: self.windowA)
        let periodStart = captured.addingTimeInterval(-9 * 86400)
        let closed = PlanUtilizationHistoryEntry(
            capturedAt: captured.addingTimeInterval(-3 * 86400),
            usedPercent: 100,
            resetsAt: captured.addingTimeInterval(-3 * 86400),
            historicalPeriod: .init(startsAt: periodStart, approximate: true, accountingComplete: false))
        let evidence = UsageStore.nativeCodexWeeklyWindowEvidence(
            history: [
                PlanUtilizationSeriesHistory(name: "nativeQuota:secondary", windowMinutes: 10080, entries: [
                    floating, used, closed,
                ]),
                PlanUtilizationSeriesHistory(name: .weekly, windowMinutes: 10080, entries: [started]),
                PlanUtilizationSeriesHistory(name: .session, windowMinutes: 300, entries: [
                    PlanUtilizationHistoryEntry(capturedAt: captured, usedPercent: 9, resetsAt: self.noon),
                ]),
            ],
            snapshot: UsageSnapshot(
                primary: nil,
                secondary: RateWindow(
                    usedPercent: 0,
                    windowMinutes: 10080,
                    resetsAt: captured.addingTimeInterval(7 * 86400 + 30),
                    resetDescription: nil),
                updatedAt: captured))
        #expect(evidence == [periodStart.addingTimeInterval(7 * 86400), self.windowB, self.windowA].sorted())
    }

    private func slice(_ offset: TimeInterval, tokens: Int, cost: Double?) -> CostUsageTimedEntry {
        CostUsageTimedEntry(
            timestamp: self.noon.addingTimeInterval(offset),
            totalTokens: tokens,
            costUSD: cost,
            costIsComplete: cost != nil)
    }

    private func timeline(_ events: [(TimeInterval, Date)]) -> NativeCodexSessionWindowTimeline {
        NativeCodexSessionWindowTimeline(
            events: events.map { (time: self.noon.addingTimeInterval($0.0), weeklyReset: $0.1) },
            coverageStart: self.noon.addingTimeInterval(-32 * 86400),
            coverageEnd: self.noon)
    }

    private func report(_ slices: [CostUsageTimedEntry]) -> CostUsageTokenSnapshot {
        CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: nil,
            last30DaysCostUSD: nil,
            historyDays: 365,
            costProvenance: .listPriceEstimate,
            daily: [],
            quotaSlices: slices,
            updatedAt: self.noon)
    }
}
