import Foundation
import SwiftUI
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct NativeOrbitClaudeComplicationTests {
    private let now = Date(timeIntervalSince1970: 1_791_810_000) // 2026-10-12 13:00 UTC
    private let calendar = CostUsageBucketTimeZone.calendar(identifier: "UTC")

    @Test func `monthly extra usage never stands in for period spend and reads off when disabled`() {
        let disabled = ProviderCostSnapshot(
            used: 0, limit: 0, currencyCode: "USD", period: "Monthly", isDisabled: true, updatedAt: self.now)
        let metrics = NativeOrbitAccountMetrics.make(
            provider: .claude,
            snapshot: UsageSnapshot(primary: nil, secondary: nil, providerCost: disabled, updatedAt: self.now),
            usage: nil,
            now: self.now)
        #expect(metrics.reportedSpend?.isDisabled == true)
        for days in [1, 7, 30] {
            let corners = self.corners(metrics, days: days)
            #expect(corners[.topLeading]?.value == "—")
            #expect(corners[.topLeading]?.help.hasPrefix("No spend data for") == true)
            // The corner stays the additional-usage gauge: empty arc, state in its help.
            #expect(corners[.bottomTrailing]?.value == "gauge:empty")
            #expect(corners[.bottomTrailing]?.help == "Additional usage is off")
        }
    }

    @Test func `enabled zero limit extra usage still reports its measured amount`() {
        let enabled = ProviderCostSnapshot(
            used: 4.5, limit: 0, currencyCode: "USD", period: "Monthly", updatedAt: self.now)
        let metrics = NativeOrbitAccountMetrics.make(
            provider: .claude,
            snapshot: UsageSnapshot(primary: nil, secondary: nil, providerCost: enabled, updatedAt: self.now),
            usage: nil,
            now: self.now)
        let corners = self.corners(metrics, days: 7)
        #expect(corners[.topLeading]?.value == "—")
        #expect(corners[.bottomTrailing]?.value == "gauge:empty")
        #expect(corners[.bottomTrailing]?.help == "$4.50 of additional usage this month")
    }

    @Test func `organization estimate fills spend and tokens with local machine provenance`() {
        let report = self.organizationReport()
        let monthly = ProviderCostSnapshot(
            used: 0, limit: 0, currencyCode: "USD", period: "Monthly", isDisabled: true, updatedAt: self.now)
        let metrics = NativeOrbitAccountMetrics.make(
            provider: .claude,
            snapshot: UsageSnapshot(primary: nil, secondary: nil, providerCost: monthly, updatedAt: self.now),
            usage: nil,
            now: self.now,
            localUsage: NativeOrbitLocalUsage(snapshot: report, scope: .localMachine, bucketTimeZoneIdentifier: "UTC"))
        let today = self.corners(metrics, days: 1)
        #expect(today[.topLeading]?.value.hasSuffix("3.00") == true)
        #expect(today[.topLeading]?.help.contains("spent today on this Mac") == true)
        #expect(today[.topLeading]?.help.hasSuffix(", at list prices") == true)
        #expect(today[.topTrailing]?.value == "3K")
        let week = self.corners(metrics, days: 7)
        #expect(week[.topLeading]?.value.hasSuffix("10.00") == true)
        #expect(week[.topTrailing]?.value == "10K")
        #expect(week[.topLeading]?.help.hasPrefix("At least") == false)
        // Attribution began nine days ago, so a 30-day total is a recorded subtotal.
        let month = self.corners(metrics, days: 30)
        #expect(month[.topLeading]?.help.hasPrefix("At least") == true)
        #expect(month[.bottomTrailing]?.help == "Additional usage is off")
    }

    @Test func `idle covered organization day reads zero, not unknown`() {
        let report = self.organizationReport(includeToday: false)
        let metrics = NativeOrbitAccountMetrics.make(
            provider: .claude,
            snapshot: nil,
            usage: nil,
            now: self.now,
            localUsage: NativeOrbitLocalUsage(snapshot: report, scope: .localMachine, bucketTimeZoneIdentifier: "UTC"))
        let summary = metrics.summary(days: 1, now: self.now, calendar: self.calendar)
        // The organization's transcripts are covered for today and contain no usage: a measured zero.
        #expect(summary.tokens == 0)
        #expect(summary.cost == 0)
        #expect(!summary.isPartial)
        let corners = self.corners(metrics, days: 1)
        #expect(corners[.topLeading]?.value.hasSuffix("0.00") == true)
        #expect(corners[.topTrailing]?.value == "0")
        #expect(metrics.summary(days: 30, now: self.now, calendar: self.calendar).isPartial)
    }

    @Test func `history reconstructs a past day up to the inspected instant from dated events`() {
        let report = self.organizationReport()
        let metrics = NativeOrbitAccountMetrics.make(
            provider: .claude,
            snapshot: nil,
            usage: nil,
            now: self.now,
            localUsage: NativeOrbitLocalUsage(snapshot: report, scope: .localMachine, bucketTimeZoneIdentifier: "UTC"))
        // Two days ago at 10:30: only the 10:00 slice of that day has happened.
        let inspected = self.calendar.startOfDay(for: self.now).addingTimeInterval(-2 * 86400 + 10.5 * 3600)
        let past = metrics.at(inspected, observedAt: self.now).summary(
            days: 1, now: inspected, calendar: self.calendar)
        #expect(past.tokens == 1000)
        #expect(past.cost == 1)
    }

    @Test func `quiet history instants read zero only when the day's dated events survive`() {
        func tokens(at inspected: Date, prunedDayOffset: Int?) -> Int? {
            let report = self.organizationReport(prunedDayOffset: prunedDayOffset)
            let metrics = NativeOrbitAccountMetrics.make(
                provider: .claude,
                snapshot: nil,
                usage: nil,
                now: self.now,
                localUsage: NativeOrbitLocalUsage(
                    snapshot: report,
                    scope: .localMachine,
                    bucketTimeZoneIdentifier: "UTC"))
            return metrics.at(inspected, observedAt: self.now)
                .summary(days: 1, now: inspected, calendar: self.calendar).tokens
        }
        // Three days ago at 09:00, before that day's first request at 10:00.
        let quiet = self.calendar.startOfDay(for: self.now).addingTimeInterval(-3 * 86400 + 9 * 3600)
        #expect(tokens(at: quiet, prunedDayOffset: nil) == 0)
        // Only the archived day total survives: its 2,000 tokens could have run before 09:00.
        #expect(tokens(at: quiet, prunedDayOffset: -3) == nil)
        #expect(tokens(at: quiet.addingTimeInterval(86400), prunedDayOffset: -3) == 0)
    }

    @Test func `grouped organization events keep per render history reconstruction cheap`() {
        // A busy month: 100,000 requests, which previously became 100,000 dated events per account.
        let start = self.calendar.startOfDay(for: self.now).addingTimeInterval(-29 * 86400)
        let raw = (0..<100_000).map { index in
            CostUsageTimedEntry(
                timestamp: start.addingTimeInterval(Double(index) * 25.9),
                totalTokens: 1000,
                costUSD: 0.01)
        }
        let grouped = CostUsageScanner.coarsenedQuotaSlices(
            raw,
            interval: CostUsageScanner.claudeOrganizationSliceInterval)
        #expect(grouped.count <= 30 * 288)
        #expect(grouped.compactMap(\.totalTokens).reduce(0, +) == 100_000_000)
        #expect(abs(grouped.compactMap(\.costUSD).reduce(0, +) - 1000) < 1e-6)
        var entries: [String: Int] = [:]
        for slice in raw {
            entries[CostUsageLocalDay.key(from: slice.timestamp, calendar: self.calendar), default: 0] += 1000
        }
        let report = CostUsageFetcher.tokenSnapshot(
            from: CostUsageDailyReport(
                data: entries.keys.sorted().map { day in
                    CostUsageDailyReport.Entry(
                        date: day,
                        inputTokens: entries[day],
                        outputTokens: 0,
                        totalTokens: entries[day],
                        requestCount: nil,
                        costUSD: Double(entries[day] ?? 0) / 100_000,
                        modelsUsed: nil,
                        modelBreakdowns: nil)
                },
                summary: nil,
                quotaSlices: grouped),
            now: self.now,
            historyDays: 30,
            calendar: self.calendar,
            costProvenance: .listPriceEstimate)
        let metrics = NativeOrbitAccountMetrics.make(
            provider: .claude,
            snapshot: nil,
            usage: nil,
            now: self.now,
            localUsage: NativeOrbitLocalUsage(snapshot: report, scope: .localMachine, bucketTimeZoneIdentifier: "UTC"))
        let inspected = self.now.addingTimeInterval(-3 * 86400 - 1800)
        let elapsed = ContinuousClock().measure {
            // One popup render reads three periods at the pointer.
            for days in [1, 7, 30] {
                _ = metrics.at(inspected, observedAt: self.now)
                    .summary(days: days, now: inspected, calendar: self.calendar)
            }
        }
        print("[claude-history-render] slices=\(grouped.count) elapsed=\(elapsed)")
        #expect(elapsed < .milliseconds(250))
    }

    // MARK: - Fixtures

    /// Ten covered days (attribution began nine days ago): 2,000/2,000/3,000 tokens on the three previous days (two
    /// dated events each at 10:00 and 14:00) and 3,000 tokens today, one dollar per thousand tokens.
    private func organizationReport(includeToday: Bool = true, prunedDayOffset: Int? = nil) -> CostUsageTokenSnapshot {
        let today = self.calendar.startOfDay(for: self.now)
        var entries: [CostUsageDailyReport.Entry] = []
        var slices: [CostUsageTimedEntry] = []
        let plan: [(offset: Int, tokens: [Int])] = [(-3, [1000, 1000]), (-2, [1000, 1000]), (-1, [1000, 2000])]
            + (includeToday ? [(0, [3000])] : [])
        for day in plan {
            let start = today.addingTimeInterval(Double(day.offset) * 86400)
            let total = day.tokens.reduce(0, +)
            entries.append(CostUsageDailyReport.Entry(
                date: CostUsageLocalDay.key(from: start, calendar: self.calendar),
                inputTokens: total,
                outputTokens: 0,
                totalTokens: total,
                requestCount: day.tokens.count,
                costUSD: Double(total) / 1000,
                modelsUsed: ["claude-sonnet-4-5"],
                modelBreakdowns: nil))
            for (index, tokens) in day.tokens.enumerated() where day.offset != prunedDayOffset {
                slices.append(CostUsageTimedEntry(
                    timestamp: start.addingTimeInterval(Double(10 + 4 * index) * 3600),
                    totalTokens: tokens,
                    costUSD: Double(tokens) / 1000))
            }
        }
        let report = CostUsageDailyReport(data: entries, summary: nil, quotaSlices: slices)
        return CostUsageFetcher.tokenSnapshot(
            from: report,
            now: self.now,
            historyDays: 10,
            calendar: self.calendar,
            historyCoverageIsEstablished: true,
            costProvenance: .listPriceEstimate,
            historyLabel: "Organization-attributed local transcripts since fixture")
    }

    private struct Corner {
        let value: String
        let help: String
    }

    private func corners(_ metrics: NativeOrbitAccountMetrics, days: Int) -> [NativeOrbitComplication.Corner: Corner] {
        let account = NativeOrbitAccountPresentation(
            id: "claude-fixture",
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
        let view = NativeOrbitInstruments(account: account, days: days, now: self.now, accent: .blue)
        var result: [NativeOrbitComplication.Corner: Corner] = [:]
        for (corner, reading) in Self.complications(view.body) {
            result[corner] = reading
        }
        return result
    }

    private static func complications(
        _ value: Any,
        depth: Int = 0) -> [(NativeOrbitComplication.Corner, Corner)]
    {
        if let view = value as? NativeOrbitComplication {
            return [(view.corner, Corner(value: view.value, help: view.help))]
        }
        if let gauge = value as? NativeOrbitExtraUsageComplication {
            let fill = gauge.fraction.map { "gauge:\($0)" } ?? "gauge:empty"
            return [(.bottomTrailing, Corner(value: fill, help: gauge.help))]
        }
        guard depth < 30 else { return [] }
        return Mirror(reflecting: value).children.flatMap { self.complications($0.value, depth: depth + 1) }
    }
}
