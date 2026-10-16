import Foundation
import Testing
@testable import CodexBar

@MainActor
struct NativeOrbitHistoryPlotPointTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func `vectorized quota geometry retains reset edges gaps and distinct aggregate markers`() {
        let before = self.entry(at: -120, used: 20)
        let after = self.entry(at: -40, used: 0)
        let isolated = self.entry(at: 0, used: 70)
        let aggregate = PlanUtilizationHistoryEntry(
            capturedAt: self.now.addingTimeInterval(-30),
            usedPercent: 50,
            resetsAt: nil,
            historicalPeriod: .init(
                startsAt: self.now.addingTimeInterval(-300), approximate: false, accountingComplete: true))
        let samples: [NativeOrbitHistoryWidget.Sample] = [
            self.sample(before, at: -120, available: 80, origin: before.capturedAt),
            self.sample(before, at: -60, available: 80, edge: true, origin: before.capturedAt),
            self.sample(after, at: -60, available: 100, edge: true, origin: before.capturedAt),
            self.sample(after, at: -40, available: 100, origin: before.capturedAt),
            self.sample(aggregate, at: -30, available: 50, segment: 1, origin: aggregate.capturedAt),
            self.sample(isolated, at: 0, available: 30, segment: 2, origin: isolated.capturedAt),
        ]
        let lane = self.lane("nativeQuota:primary", samples: samples)
        let points = lane.plotPoints
        #expect(points.map { $0.date.timeIntervalSince(self.now) } == [-120, -90, -60, -40, 0])
        #expect(points.map(\.available) == [80, 80, 100, 100, 30])
        #expect(Set(points.prefix(4).map(\.seriesID)).count == 1)
        #expect(points.first?.seriesID != points.last?.seriesID)
        #expect(lane.periodSamples.map(\.id) == [aggregate])
        #expect(lane.isolatedSamples.map(\.id) == [isolated])
    }

    @Test func `vectorized series remain separate when different quota lanes share one source origin`() {
        let receipt = self.entry(at: 0, used: 20)
        let samples = [self.sample(receipt, at: 0, available: 80, origin: receipt.capturedAt)]
        let session = self.lane("nativeQuota:primary", samples: samples).plotPoints
        let weekly = self.lane("nativeQuota:secondary", samples: samples).plotPoints
        #expect(session.map(\.date) == weekly.map(\.date))
        #expect(session.map(\.available) == weekly.map(\.available))
        #expect(session.first?.seriesID != weekly.first?.seriesID)
    }

    @Test func `vectorized projection retains the ordered pair on both sides of a reset`() {
        let points: [NativeOrbitLaneProjection.Point] = [
            .init(date: self.now, available: 70),
            .init(date: self.now.addingTimeInterval(60), available: 0, isResetEdge: true),
            .init(date: self.now.addingTimeInterval(60), available: 100, isResetEdge: true),
            .init(date: self.now.addingTimeInterval(120), available: 80),
        ]
        let plotted = NativeOrbitHistoryWidget.projectionPlotPoints(points, seriesID: "session:projection")
        #expect(plotted.map { $0.date.timeIntervalSince(self.now) } == [0, 30, 60, 120])
        #expect(plotted.map(\.available) == [70, 0, 100, 80])
        #expect(plotted.map(\.seriesID) == Array(repeating: "session:projection", count: points.count))
    }

    @Test func `a single marker uses the uncertainty at its exact future position and stays sharp through now`() {
        for days in [1, 7, 30] {
            var widget = NativeOrbitHistoryWidget(histories: [], now: self.now, days: days)
            widget.isProjecting = true
            #expect(widget.markerBlurRadius(at: self.now.addingTimeInterval(-60)) == 0)
            #expect(widget.markerBlurRadius(at: self.now) == 0)
            for fraction in [0.25, 0.5, 0.75, 1] {
                let date = self.now.addingTimeInterval(widget.chartEnd.timeIntervalSince(self.now) * fraction)
                #expect(abs(widget.markerBlurRadius(at: date)
                        - NativeOrbitProjectionStyle.blurRadius(fraction: fraction, days: days)) < 0.000001)
            }
            widget.isProjecting = false
            #expect(widget.markerBlurRadius(at: self.now.addingTimeInterval(60)) == 0)
        }
    }

    @Test func `range changes zoom stable recorded and projected buffers without replacing vertices`() throws {
        let day: TimeInterval = 86400
        let oldest = self.entry(at: -30 * day, used: 20)
        let before = self.entry(at: -7 * day, used: 60)
        let after = self.entry(at: -6 * day, used: 0)
        let latest = self.entry(at: -60, used: 10)
        let samples = [
            self.sample(oldest, at: -30 * day, available: 80, origin: oldest.capturedAt),
            self.sample(before, at: -7 * day, available: 40, origin: oldest.capturedAt),
            self.sample(before, at: -6 * day, available: 40, edge: true, origin: oldest.capturedAt),
            self.sample(after, at: -6 * day, available: 100, edge: true, origin: oldest.capturedAt),
            self.sample(after, at: -6 * day + 60, available: 100, origin: oldest.capturedAt),
            self.sample(latest, at: -60, available: 90, segment: 1, origin: latest.capturedAt),
        ]
        let lane = self.lane("nativeQuota:primary", samples: samples, start: self.now.addingTimeInterval(-31 * day))
        let projected = NativeOrbitLaneProjection(
            id: lane.id,
            origin: self.now,
            originUsed: 20,
            rate: 0.0001,
            rateSource: .observedTrend,
            period: 7 * day,
            reset: self.now.addingTimeInterval(2 * day),
            lineStart: self.now)
        for projecting in [false, true] {
            var recorded: [NativeOrbitHistoryPlotPoint]?
            var future: [NativeOrbitHistoryPlotPoint]?
            var domains: [ClosedRange<Date>] = []
            for days in [1, 7, 30, 1] {
                var widget = NativeOrbitHistoryWidget(histories: [lane.history], now: self.now, days: days)
                widget.preparedLanes = [lane]
                widget.dataDays = 31
                widget.isProjecting = projecting
                let points = widget.quotaPlotPoints(widget.lanes[0])
                #expect(points.map { $0.date.timeIntervalSince(self.now) }
                    == [-30 * day, -7 * day, -6 * day - 30, -6 * day, -6 * day + 60, -60])
                #expect(points.map(\.available) == [80, 40, 40, 100, 100, 90])
                #expect(points[0].seriesID == points[4].seriesID)
                #expect(points[4].seriesID != points[5].seriesID)
                if let recorded { #expect(points == recorded) } else { recorded = points }
                if projecting {
                    let points = widget.projectionPlotPoints(projected, seriesID: "primary:projection")
                    #expect(points.first?.date == self.now)
                    #expect(points.last?.date == self.now.addingTimeInterval(31 * day))
                    #expect(points.contains { $0.date == self.now.addingTimeInterval(2 * day - 30) })
                    #expect(points.contains { $0.date == self.now.addingTimeInterval(2 * day) && $0.available == 100 })
                    if let future { #expect(points == future) } else { future = points }
                }
                domains.append(widget.start...widget.chartEnd)
                if days == 1 {
                    #expect(
                        try #require(points.first?.date) < widget.start,
                        "Offscreen source vertices remain part of the zoom")
                }
            }
            #expect(Set(domains).count == 3)
            #expect(domains.first == domains.last)
        }
    }

    @Test func `range transitions keep their smooth zoom unless reduced motion is requested`() {
        #expect(NativeOrbitHistoryWidget.rangeAnimation(reduceMotion: false) != nil)
        #expect(NativeOrbitHistoryWidget.rangeAnimation(reduceMotion: true) == nil)
    }

    private func entry(at offset: TimeInterval, used: Double) -> PlanUtilizationHistoryEntry {
        .init(capturedAt: self.now.addingTimeInterval(offset), usedPercent: used, resetsAt: nil)
    }

    private func sample(
        _ entry: PlanUtilizationHistoryEntry,
        at offset: TimeInterval,
        available: Double,
        segment: Int = 0,
        edge: Bool = false,
        origin: Date) -> NativeOrbitHistoryWidget.Sample
    {
        .init(
            id: entry,
            date: self.now.addingTimeInterval(offset),
            available: available,
            segment: segment,
            period: 18000,
            isResetEdge: edge,
            seriesOrigin: origin)
    }

    private func lane(
        _ name: PlanUtilizationSeriesName,
        samples: [NativeOrbitHistoryWidget.Sample],
        start: Date? = nil) -> NativeOrbitHistoryWidget.Lane
    {
        .init(
            history: .init(name: name, windowMinutes: 300, entries: samples.map(\.id)),
            samples: samples,
            resetEvents: [],
            start: start ?? self.now.addingTimeInterval(-300),
            now: self.now,
            styleIndex: 0)
    }
}
