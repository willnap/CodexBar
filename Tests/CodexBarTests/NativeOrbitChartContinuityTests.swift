import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

/// Lines stay continuous: across idle polling, and under the same name when the range changes, so Charts morphs each
/// line into itself instead of into another stretch of history.
@MainActor
struct NativeOrbitChartContinuityTests {
    @Test
    func `idle polling between dense refreshes stays one line while a missed refresh breaks it`() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // Mostly 10-minute polling, then an idle stretch at the slowest regular refresh (30 min plus jitter).
        let dense = Array(stride(from: -36000.0, through: -18000, by: 600))
        let idle = [-16194.0, -14388, -12582]
        let resumed = [-6000.0, -5400]
        let history = self.history("nativeQuota:primary", minutes: 300, dates: dense + idle + resumed, now: now)
        let widget = NativeOrbitHistoryWidget(histories: [history], now: now, days: 7)
        let lane = try #require(widget.lanes.first)
        #expect(lane.isolatedSamples.isEmpty, "Readings 30 minutes apart are drawn as a line, never as lone dots")
        let segments = lane.samples.filter { $0.date >= widget.start }.map(\.segment)
        // The 110-minute silence before polling resumed is a gap.
        #expect(Set(segments).count == 2)
    }

    @Test
    func `a stretch of history keeps its series name in every range`() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // Ten-minute readings over twelve days with an overnight gap each day: the wider ranges see more breaks first.
        var dates: [TimeInterval] = []
        for day in 0..<12 {
            let dayStart = -Double(day + 1) * 86400
            dates += stride(from: dayStart + 8 * 3600, through: dayStart + 23 * 3600, by: 600).map(\.self)
        }
        dates += stride(from: -6 * 3600.0, through: 0, by: 600).map(\.self)
        let history = self.history("nativeQuota:primary", minutes: 300, dates: dates.sorted(), now: now)
        func names(_ days: Int) throws -> [Date: String] {
            let widget = NativeOrbitHistoryWidget(histories: [history], now: now, days: days)
            let lane = try #require(widget.lanes.first)
            return Dictionary(lane.samples.filter { !$0.isResetEdge }.map { ($0.date, lane.seriesID($0)) }) { a, _ in
                a
            }
        }
        let day = try names(1)
        let week = try names(7)
        let month = try names(30)
        #expect(!day.isEmpty)
        for (date, name) in day {
            #expect(week[date] == name)
            #expect(month[date] == name)
        }
        // A new reading five minutes later extends today's line under the same name (dates are relative to `now`).
        let extended = self.history(
            "nativeQuota:primary",
            minutes: 300,
            dates: dates.sorted().map { $0 - 300 } + [0],
            now: now.addingTimeInterval(300))
        let widget = NativeOrbitHistoryWidget(histories: [extended], now: now.addingTimeInterval(300), days: 1)
        let lane = try #require(widget.lanes.first)
        let latest = try #require(lane.samples.last)
        #expect(lane.seriesID(latest) == day[now])
    }

    @Test
    func `a reset's two edges are drawn in a fixed order so an animated zoom never swaps them`() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(-7200)
        let history = PlanUtilizationSeriesHistory(name: "nativeQuota:primary", windowMinutes: 300, entries: [
            .init(capturedAt: now.addingTimeInterval(-7500), usedPercent: 60, resetsAt: reset),
            .init(
                capturedAt: now.addingTimeInterval(-6900),
                usedPercent: 10,
                resetsAt: reset.addingTimeInterval(18000)),
        ])
        let lane = try #require(NativeOrbitHistoryWidget(histories: [history], now: now, days: 1).lanes.first)
        let edges = lane.samples.filter(\.isResetEdge)
        #expect(edges.count == 2)
        #expect(edges[0].date == edges[1].date, "The data keeps both edges at the reset's instant")
        #expect(edges[0].renderDate < edges[1].renderDate, "but the held edge is drawn first")
        #expect(edges[1].date.timeIntervalSince(edges[0].renderDate) <= NativeOrbitHistoryWidget.edgeSeparation)
        let draws = lane.samples.map(\.renderDate)
        #expect(draws == draws.sorted(), "Drawn order is the data order")

        let projected: [NativeOrbitLaneProjection.Point] = [
            .init(date: now, available: 50),
            .init(date: reset.addingTimeInterval(18000), available: 20, isResetEdge: true),
            .init(date: reset.addingTimeInterval(18000), available: 100, isResetEdge: true),
            .init(date: now.addingTimeInterval(86400), available: 60),
        ]
        let keyed = NativeOrbitHistoryWidget.keyedPoints(projected)
        #expect(keyed[1].renderDate < keyed[2].renderDate)
        #expect(keyed.map(\.renderDate) == keyed.map(\.renderDate).sorted())
    }

    private func history(_ name: String, minutes: Int, dates: [TimeInterval], now: Date)
    -> PlanUtilizationSeriesHistory {
        PlanUtilizationSeriesHistory(name: .init(rawValue: name), windowMinutes: minutes, entries: dates.map {
            .init(capturedAt: now.addingTimeInterval($0), usedPercent: 25, resetsAt: nil)
        })
    }
}
