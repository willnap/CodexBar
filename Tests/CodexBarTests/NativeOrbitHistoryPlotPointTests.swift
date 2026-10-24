import AppKit
import Foundation
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
struct NativeOrbitHistoryPlotPointTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func `straight receipt runs draw only endpoints without discarding observations`() throws {
        let origin = self.now.addingTimeInterval(-2400)
        let samples = (0..<2400).map { index in
            let offset = Double(index - 2400)
            return self.sample(
                self.entry(at: offset, used: Double(index) / 30),
                at: offset,
                available: 100 - Double(index) / 30,
                origin: origin)
        }
        let lane = self.lane("nativeQuota:primary", samples: samples, start: origin)
        #expect(lane.samples.count == 2400)
        #expect(lane.plotPoints.count == 2)
        #expect(lane.plotPoints.first?.date == samples.first?.date)
        #expect(lane.plotPoints.last?.date == samples.last?.date)
        for sample in samples {
            let reading = try #require(lane.cursorCurve.reading(at: sample.date))
            #expect(abs(reading.available - sample.available) < 1e-9)
        }
    }

    @Test func `straight run thinning preserves bends and both ends of gaps`() throws {
        let readings: [(Double, Double, Int)] = [
            (-240, 90, 0), (-220, 80, 0), (-200, 70, 0), (-180, 60, 0), (-160, 70, 0), (-140, 80, 0),
            (-80, 40, 1), (-60, 35, 1), (-40, 30, 1), (0, 20, 2),
        ]
        let samples = readings.map { offset, available, segment in
            self.sample(
                self.entry(at: offset, used: 100 - available),
                at: offset,
                available: available,
                segment: segment,
                origin: self.now.addingTimeInterval(Double(segment)))
        }
        let lane = self.lane("nativeQuota:primary", samples: samples)
        #expect(lane.plotPoints.map { $0.date.timeIntervalSince(self.now) } == [-240, -180, -140, -80, -40, 0])
        #expect(lane.cursorCurve.reading(at: self.now.addingTimeInterval(-110)) == nil)
        #expect(lane.cursorCurve.reading(at: self.now.addingTimeInterval(-20)) == nil)
        for sample in samples {
            #expect(try abs(#require(lane.cursorCurve.reading(at: sample.date)).available - sample.available) < 1e-9)
        }
    }

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

    @Test func `cursor beads follow rendered reset edges instead of unshifted receipt times`() throws {
        let before = self.entry(at: -120, used: 20)
        let after = self.entry(at: -40, used: 0)
        let lane = self.lane("nativeQuota:primary", samples: [
            self.sample(before, at: -120, available: 80, origin: before.capturedAt),
            self.sample(before, at: -60, available: 80, edge: true, origin: before.capturedAt),
            self.sample(after, at: -60, available: 100, edge: true, origin: before.capturedAt),
            self.sample(after, at: -40, available: 100, origin: before.capturedAt),
        ])
        let widget = NativeOrbitHistoryWidget(histories: [lane.history], now: self.now)
        let date = self.now.addingTimeInterval(-75)
        let bead = try #require(widget.markerReading(lane, at: date))
        // The displayed ramp goes from 80 at -90 seconds to 100 at -60 seconds.
        #expect(bead.date == date)
        #expect(bead.available == 90)
        // Provenance and numerical inspection retain the source reset's real instant.
        #expect(widget.nearest(lane, to: date)?.available == 80)
    }

    @Test func `a visible segment crossing the viewport edge retains its cursor bead`() throws {
        let before = self.entry(at: -87000, used: 20)
        let after = self.entry(at: -85800, used: 60)
        let lane = self.lane(
            "nativeQuota:primary",
            samples: [
                self.sample(before, at: -87000, available: 80, origin: before.capturedAt),
                self.sample(after, at: -85800, available: 40, origin: before.capturedAt),
            ],
            start: self.now.addingTimeInterval(-31 * 86400))
        var widget = NativeOrbitHistoryWidget(histories: [lane.history], now: self.now)
        widget.dataDays = 31
        let bead = try #require(widget.markerReading(lane, at: widget.start))
        #expect(bead.date == widget.start)
        #expect(bead.available == 60)
        #expect(widget.nearest(lane, to: widget.start)?.available == 60)
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

    @Test func `projected beads sample the drawn reset ramp including a reset near the origin`() throws {
        for resetOffset: TimeInterval in [60, 10] {
            let projected = NativeOrbitLaneProjection(
                id: "nativeQuota:primary",
                origin: self.now,
                originUsed: 20,
                rate: 0,
                rateSource: .idle,
                period: 18000,
                reset: self.now.addingTimeInterval(resetOffset),
                lineStart: self.now)
            var widget = NativeOrbitHistoryWidget(histories: [], now: self.now)
            widget.isProjecting = true
            widget.projection = NativeOrbitAccountProjection(
                now: self.now,
                end: widget.chartEnd,
                lastActivity: nil,
                lanes: [projected],
                events: [],
                tokenRate: nil,
                costRate: nil,
                periodSummary: .init(),
                resetInventory: nil,
                liveMetrics: .empty)
            let plotted = widget.projectionPlotPoints(projected, seriesID: "primary:projection")
            #expect(plotted.map(\.date) == plotted.map(\.date).sorted())
            #expect(plotted[1].date == self.now.addingTimeInterval(resetOffset / 2))
            let date = self.now.addingTimeInterval(resetOffset * 0.75)
            let reading = try #require(widget.projectedMarkerReading(projected, at: date))
            #expect(reading.date == date)
            #expect(reading.available == 90)
            #expect(projected.available(at: date) == 80)
        }
    }

    @Test func `inspection at now keeps a bead only when recorded or projected geometry covers it`() throws {
        let receipt = self.entry(at: -60, used: 20)
        let lane = self.lane("nativeQuota:primary", samples: [
            self.sample(receipt, at: -60, available: 80, origin: receipt.capturedAt),
        ])
        var widget = NativeOrbitHistoryWidget(histories: [lane.history], now: self.now)
        widget.selectedDate = self.now
        #expect(widget.markerReading(lane, at: self.now) == nil)
        let projected = NativeOrbitLaneProjection(
            id: lane.id,
            origin: receipt.capturedAt,
            originUsed: 20,
            rate: 0,
            rateSource: .idle,
            period: 18000,
            reset: self.now.addingTimeInterval(3600),
            lineStart: receipt.capturedAt)
        widget.projection = NativeOrbitAccountProjection(
            now: self.now,
            end: self.now.addingTimeInterval(86400),
            lastActivity: nil,
            lanes: [projected],
            events: [],
            tokenRate: nil,
            costRate: nil,
            periodSummary: .init(),
            resetInventory: nil,
            liveMetrics: .empty)
        // A stored projection alone is not geometry: it must actually be displayed.
        #expect(widget.markerReading(lane, at: self.now) == nil)
        widget.isProjecting = true
        #expect(try #require(widget.markerReading(lane, at: self.now)).available == 80)
        #expect(widget.markerReading(lane, at: self.now.addingTimeInterval(-30))?.available == 80)
        #expect(widget.markerReading(lane, at: self.now.addingTimeInterval(-90)) == nil)
    }

    @Test func `cursor curve preserves isolated readings and never crosses a gap or carries stale tails`() {
        let curve = NativeOrbitHistoryCurve(points: [
            .init(date: self.now.addingTimeInterval(-100), available: 20, seriesID: "first"),
            .init(date: self.now.addingTimeInterval(-80), available: 40, seriesID: "first"),
            .init(date: self.now.addingTimeInterval(-20), available: 80, seriesID: "isolated"),
        ])
        #expect(curve.reading(at: self.now.addingTimeInterval(-90))?.available == 30)
        #expect(curve.reading(at: self.now.addingTimeInterval(-50)) == nil)
        #expect(curve.reading(at: self.now.addingTimeInterval(-20))?.available == 80)
        #expect(curve.reading(at: self.now) == nil)
        #expect(curve.reading(at: self.now.addingTimeInterval(-101)) == nil)
    }

    @Test func `pointer motion keeps the retained chart root stable while range changes invalidate it`() {
        let before = self.entry(at: -100, used: 20)
        let after = self.entry(at: 0, used: 60)
        let lane = self.lane("nativeQuota:primary", samples: [
            self.sample(before, at: -100, available: 80, origin: before.capturedAt),
            self.sample(after, at: 0, available: 40, origin: before.capturedAt),
        ])
        var widget = NativeOrbitHistoryWidget(histories: [lane.history], now: self.now)
        widget.selectedDate = self.now.addingTimeInterval(-80)
        let first = widget.revealKey([lane])
        widget.selectedDate = self.now.addingTimeInterval(-20)
        #expect(widget.revealKey([lane]) == first)
        widget.days = 7
        #expect(widget.revealKey([lane]) != first)
    }

    @Test func `animated presentation time keeps the bead on a bend instead of cutting across its chord`() throws {
        let before = self.entry(at: -100, used: 80)
        let bend = self.entry(at: -50, used: 20)
        let after = self.entry(at: 0, used: 80)
        let lane = self.lane("nativeQuota:primary", samples: [
            self.sample(before, at: -100, available: 20, origin: before.capturedAt),
            self.sample(bend, at: -50, available: 80, origin: before.capturedAt),
            self.sample(after, at: 0, available: 20, origin: before.capturedAt),
        ])
        let widget = NativeOrbitHistoryWidget(histories: [lane.history], now: self.now)
        let lower = self.now.addingTimeInterval(-100)
        var cursor = NativeOrbitChartCursor(date: self.now, bounds: lower...self.now) { date, bounds in
            ZStack(alignment: .topLeading) {
                Path {
                    $0.move(to: CGPoint(x: 0, y: 80))
                    $0.addLine(to: CGPoint(x: 50, y: 20))
                    $0.addLine(to: CGPoint(x: 100, y: 80))
                }.stroke(.black, lineWidth: 2)
                if let point = widget.markerReading(lane, at: date, visibleStart: bounds.lowerBound) {
                    Circle().fill(.red).frame(width: 8, height: 8)
                        .position(x: date.timeIntervalSince(bounds.lowerBound), y: 100 - point.available)
                }
            }.frame(width: 100, height: 100).background(.white)
        }
        // Drive the real Animatable view at the halfway presentation of the return-to-now transition.
        cursor.animatableData = .init(
            self.now.addingTimeInterval(-50).timeIntervalSinceReferenceDate,
            .init(lower.timeIntervalSinceReferenceDate, self.now.timeIntervalSinceReferenceDate))
        let renderer = ImageRenderer(content: cursor)
        let rendered = try NSBitmapImageRep(cgImage: #require(renderer.cgImage))
        let bead = try #require(rendered.colorAt(x: 50, y: 20)?.usingColorSpace(.sRGB))
        #expect(bead.redComponent > 0.8 && bead.greenComponent < 0.4 && bead.blueComponent < 0.4)
        let chord = try #require(rendered.colorAt(x: 50, y: 80)?.usingColorSpace(.sRGB))
        #expect(chord.redComponent > 0.8 && chord.greenComponent > 0.8 && chord.blueComponent > 0.8)
        if let path = ProcessInfo.processInfo.environment["CODEXBAR_CURSOR_PROOF_DIR"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try rendered.representation(using: .png, properties: [:])?
                .write(to: directory.appendingPathComponent("cursor-at-bend.png"))
        }
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
