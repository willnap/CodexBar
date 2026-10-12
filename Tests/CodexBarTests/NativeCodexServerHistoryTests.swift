import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct NativeCodexServerHistoryTests {
    @Test
    func `a later period total does not change the current measured legend`() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let measured = PlanUtilizationHistoryEntry(
            capturedAt: now.addingTimeInterval(-3600),
            usedPercent: 20,
            resetsAt: nil)
        let aggregate = PlanUtilizationHistoryEntry(
            capturedAt: now.addingTimeInterval(-1800),
            usedPercent: 95,
            resetsAt: nil,
            historicalPeriod: .init(
                startsAt: now.addingTimeInterval(-7 * 86400),
                approximate: true,
                accountingComplete: true))
        let history = PlanUtilizationSeriesHistory(
            name: "nativeQuota:secondary",
            windowMinutes: 10080,
            entries: [measured, aggregate])
        let widget = NativeOrbitHistoryWidget(histories: [history], now: now, days: 30)
        let lane = try #require(widget.lanes.first)
        #expect(widget.legendSample(lane, selectedDate: nil)?.available == 80)
        #expect(lane.renderSamples.last?.id == measured)
    }

    @Test
    func `period point selection cannot replace a later exact measured observation`() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let aggregate = PlanUtilizationHistoryEntry(
            capturedAt: now.addingTimeInterval(-86400),
            usedPercent: 95,
            resetsAt: nil,
            historicalPeriod: .init(
                startsAt: now.addingTimeInterval(-8 * 86400),
                approximate: true,
                accountingComplete: true))
        let measured = PlanUtilizationHistoryEntry(
            capturedAt: aggregate.capturedAt.addingTimeInterval(1800),
            usedPercent: 20,
            resetsAt: nil)
        let history = PlanUtilizationSeriesHistory(
            name: "nativeQuota:secondary",
            windowMinutes: 10080,
            entries: [aggregate, measured])
        let widget = NativeOrbitHistoryWidget(histories: [history], now: now, days: 30)
        let lane = try #require(widget.lanes.first)
        #expect(widget.nearest(lane, to: measured.capturedAt)?.id == measured)
        let pointerDate = measured.capturedAt.addingTimeInterval(30)
        #expect(widget.nearest(lane, to: pointerDate) == nil)
        let selectedDate = widget.inspectionDate(at: pointerDate, plotWidth: 300)
        #expect(selectedDate == measured.capturedAt)
        #expect(widget.nearest(lane, to: selectedDate)?.id == measured)
    }

    @Test
    func `measured readings outrank server totals regardless of fragment order`() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let observed = PlanUtilizationHistoryEntry(capturedAt: date, usedPercent: 91, resetsAt: nil)
        let aggregate = PlanUtilizationHistoryEntry(
            capturedAt: date,
            usedPercent: 98,
            resetsAt: nil,
            historicalPeriod: .init(
                startsAt: date.addingTimeInterval(-7 * 86400),
                approximate: true,
                accountingComplete: false))
        #expect(UsageStore.nativeOrbitMergedRawEntries([observed], [aggregate]) == [observed])
        #expect(UsageStore.nativeOrbitMergedRawEntries([aggregate], [observed]) == [observed])
        let fragments = [observed, aggregate].map {
            PlanUtilizationSeriesHistory(name: "nativeQuota:secondary", windowMinutes: 10080, entries: [$0])
        }
        #expect(UsageStore.nativeOrbitCoalescedQuotaHistories(fragments).first?.entries == [observed])
        #expect(UsageStore.nativeOrbitCoalescedQuotaHistories(fragments.reversed()).first?.entries == [observed])
    }

    @Test
    func `period totals are isolated points and never held as current quota`() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let entry = PlanUtilizationHistoryEntry(
            capturedAt: now.addingTimeInterval(-86400),
            usedPercent: 97.5,
            resetsAt: nil,
            historicalPeriod: .init(
                startsAt: now.addingTimeInterval(-8 * 86400),
                approximate: true,
                accountingComplete: false))
        let history = PlanUtilizationSeriesHistory(
            name: "nativeQuota:secondary",
            windowMinutes: 10080,
            entries: [entry])
        let widget = NativeOrbitHistoryWidget(histories: [history], now: now, days: 30)
        let lane = try #require(widget.lanes.first)
        #expect(lane.renderSamples.isEmpty)
        #expect(widget.nearest(lane, to: now) == nil)
        #expect(widget.nearest(lane, to: entry.capturedAt)?.id == entry)
        #expect(widget.seriesHelp(lane, selectedDate: entry.capturedAt).contains("Server period total"))
    }

    @Test
    func `neither a prior aggregate nor an old observation paints the selected period`() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let observed = PlanUtilizationHistoryEntry(
            capturedAt: now.addingTimeInterval(-3 * 86400),
            usedPercent: 20,
            resetsAt: nil)
        let aggregate = PlanUtilizationHistoryEntry(
            capturedAt: now.addingTimeInterval(-2 * 86400),
            usedPercent: 95,
            resetsAt: nil,
            historicalPeriod: .init(
                startsAt: now.addingTimeInterval(-9 * 86400),
                approximate: true,
                accountingComplete: true))
        let history = PlanUtilizationSeriesHistory(
            name: "nativeQuota:secondary",
            windowMinutes: 10080,
            entries: [observed, aggregate])
        let widget = NativeOrbitHistoryWidget(histories: [history], now: now, days: 1)
        let lane = try #require(widget.lanes.first)
        #expect(lane.samples.map(\.id) == [observed])
        #expect(lane.renderSamples.isEmpty)
    }

    @Test
    func `server period totals retain their provenance and do not invent opening readings`() throws {
        let data = Data(#"""
        {"data_as_of":"2026-10-11T00:00:00Z","approximate":true,"periods":[
          {"id":"week","window_minutes":10080,"starts_at":"2026-09-20T11:31:14.291000Z",
           "ends_at":"2026-09-26T17:08:46Z","accounting_complete":false,"used_basis_points":10017.738335},
          {"id":"missing","window_minutes":10080,"starts_at":"2026-10-10T00:00:00Z",
           "ends_at":"2026-10-17T00:00:00Z","used_basis_points":null}
        ]}
        """#.utf8)
        let now = try Date("2026-10-11T12:00:00Z", strategy: .iso8601)
        let history = try CodexPlanLimitHistory.decode(data)
        let samples = UsageStore.nativeCodexServerHistorySamples(history, now: now)
        #expect(samples.count == 1)
        let sample = try #require(samples.first)
        #expect(sample.name.rawValue == "nativeQuota:secondary")
        #expect(sample.windowMinutes == 10080)
        #expect(sample.entry.usedPercent == 100.17738335)
        #expect(sample.entry.capturedAt == history.periods[0].endsAt)
        #expect(sample.entry.historicalPeriod?.startsAt == history.periods[0].startsAt)
        #expect(sample.entry.historicalPeriod?.approximate == true)
        #expect(sample.entry.historicalPeriod?.accountingComplete == false)
    }

    @Test
    func `historical source metadata survives durable history round trips`() throws {
        let entry = PlanUtilizationHistoryEntry(
            capturedAt: Date(timeIntervalSince1970: 1_790_000_000.125),
            usedPercent: 99.7720383,
            resetsAt: Date(timeIntervalSince1970: 1_790_000_000.125),
            historicalPeriod: .init(
                startsAt: Date(timeIntervalSince1970: 1_789_400_000.291),
                approximate: true,
                accountingComplete: false,
                boundaryToleranceSeconds: 60,
                coverageComplete: false,
                coverageStart: Date(timeIntervalSince1970: 1_788_000_000.291),
                dataAsOf: Date(timeIntervalSince1970: 1_790_000_001.125),
                sourcePeriodID: "period-id"))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoded = try encoder.encode(entry)
        let decoded = try decoder.decode(PlanUtilizationHistoryEntry.self, from: encoded)
        #expect(decoded == entry)
    }
}
