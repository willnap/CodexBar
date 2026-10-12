import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct NativeOrbitResetLineTests {
    private let now = Date(timeIntervalSince1970: 1_791_800_000)

    @Test func `a window reset joins the line with a vertical rise at the scheduled reset`() throws {
        let session = self.lane("nativeQuota:primary", minutes: 300, [
            (-7500, 60, self.now.addingTimeInterval(-7200)),
            (-6900, 10, self.now.addingTimeInterval(-6900 + 5 * 3600)),
        ])
        let widget = NativeOrbitHistoryWidget(histories: [session], now: self.now, provider: .claude)
        let lane = try #require(widget.lanes.first)
        #expect(lane.resetEvents.map(\.kind) == [.natural])
        #expect(lane.samples.map(\.date) == [-7500, -7200, -7200, -6900].map { self.now.addingTimeInterval($0) })
        #expect(lane.samples.map(\.available) == [40, 40, 100, 90])
        #expect(lane.samples.map(\.isResetEdge) == [false, true, true, false])
        #expect(Set(lane.samples.map(\.segment)).count == 1)
        // The reset marker sits at the rise.
        #expect(lane.resetEvents.first?.date == self.now.addingTimeInterval(-7200))
        // Edges are drawn, never counted as observations.
        #expect(widget.coverage(lane).observationCount == 2)
        #expect(lane.renderSamples.count == 4)
        #expect(lane.latestMeasuredSample?.date == self.now.addingTimeInterval(-6900))

        // Hover matches the drawn line: the old window before the instant, the new one from it on.
        #expect(widget.nearest(lane, to: self.now.addingTimeInterval(-7201))?.available == 40)
        #expect(widget.nearest(lane, to: self.now.addingTimeInterval(-7201))?.id.resetsAt
            == self.now.addingTimeInterval(-7200))
        let reset = try #require(widget.nearest(lane, to: self.now.addingTimeInterval(-7200)))
        #expect(reset.available == 100)
        let after = try #require(widget.nearest(lane, to: self.now.addingTimeInterval(-7050)))
        #expect(after.available == 95)
        #expect(after.id.resetsAt == self.now.addingTimeInterval(-6900 + 5 * 3600))
    }

    @Test func `an early reset rises where the new window started inside the bracket`() throws {
        let weekly = self.lane("nativeQuota:secondary", minutes: 10080, [
            (-3600, 98, self.now.addingTimeInterval(86400)),
            (-1800, 5, self.now.addingTimeInterval(-2700 + 7 * 86400)),
        ])
        let widget = NativeOrbitHistoryWidget(histories: [weekly], now: self.now, provider: .codex)
        let lane = try #require(widget.lanes.first)
        let event = try #require(lane.resetEvents.first)
        #expect(event.kind == .early)
        #expect(event.date == self.now.addingTimeInterval(-2700))
        #expect(event.earliest == self.now.addingTimeInterval(-3600))
        #expect(lane.samples.map(\.date) == [-3600, -2700, -2700, -1800].map { self.now.addingTimeInterval($0) })
        #expect(lane.samples.map(\.available) == [2, 2, 100, 95])
        #expect(Set(lane.samples.map(\.segment)).count == 1)
    }

    @Test func `a reset first seen in a reading rises at that reading`() throws {
        let weekly = self.lane("nativeQuota:secondary", minutes: 10080, [
            (-3600, 100, self.now.addingTimeInterval(86400)),
            (-3300, 0, nil),
        ])
        let widget = NativeOrbitHistoryWidget(histories: [weekly], now: self.now, provider: .codex)
        let lane = try #require(widget.lanes.first)
        #expect(lane.resetEvents.first?.date == self.now.addingTimeInterval(-3300))
        // The held reading ends at the reading that shows the reset; no edge duplicates that reading.
        #expect(lane.samples.map(\.date) == [-3600, -3300, -3300].map { self.now.addingTimeInterval($0) })
        #expect(lane.samples.map(\.available) == [0, 0, 100])
        #expect(lane.samples.map(\.isResetEdge) == [false, true, false])
        #expect(Set(lane.samples.map(\.renderIdentity)).count == 3)
        #expect(widget.nearest(lane, to: self.now.addingTimeInterval(-3300))?.isResetEdge == false)
        #expect(widget.nearest(lane, to: self.now.addingTimeInterval(-3300))?.available == 100)
        #expect(widget.nearest(lane, to: self.now.addingTimeInterval(-3301))?.available == 0)
    }

    @Test func `a reset beyond the recording gap limit on either side stays a break`() throws {
        // Five-minute polling sets a 15-minute gap limit.
        let postReset: [(TimeInterval, Double, Date?)] = (0..<4).map {
            (-19900 + Double($0) * 300, 0, self.now.addingTimeInterval(-19900 + 5 * 3600))
        }
        let farBefore = self.lane("nativeQuota:primary", minutes: 300, [
            (-30000, 50, self.now.addingTimeInterval(-20000)),
        ] + postReset)
        let widget = NativeOrbitHistoryWidget(histories: [farBefore], now: self.now, provider: .claude)
        let lane = try #require(widget.lanes.first)
        #expect(!lane.samples.map(\.isResetEdge).contains(true))
        #expect(lane.samples[0].segment != lane.samples[1].segment)
        #expect(widget.nearest(lane, to: self.now.addingTimeInterval(-25000)) == nil)
        // The reset is still marked.
        #expect(lane.resetEvents.map(\.kind) == [.natural])

        let farAfter = self.lane("nativeQuota:primary", minutes: 300, [
            (-20300, 50, self.now.addingTimeInterval(-20000)),
        ] + postReset.map { ($0.0 + 5000, $0.1, $0.2.map { $0.addingTimeInterval(5000) }) })
        let gapped = try #require(NativeOrbitHistoryWidget(histories: [farAfter], now: self.now, provider: .claude)
            .lanes.first)
        #expect(!gapped.samples.map(\.isResetEdge).contains(true))
        #expect(gapped.samples[0].segment != gapped.samples[1].segment)
    }

    @Test func `a drop without a known schedule stays a break with no rise`() throws {
        let legacy = self.lane("nativeQuota:secondary", minutes: 10080, [
            (-3600, 80, nil), (-3300, 0, nil),
        ])
        let lane = try #require(NativeOrbitHistoryWidget(histories: [legacy], now: self.now, provider: .codex)
            .lanes.first)
        #expect(!lane.samples.map(\.isResetEdge).contains(true))
        #expect(lane.samples[0].segment != lane.samples[1].segment)
        #expect(lane.resetEvents.isEmpty)
    }

    @Test func `a reset before the range still joins the reading preceding the range`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let start = NativeOrbitHistoryWidget(histories: [], now: self.now, calendar: calendar).start
        let session = PlanUtilizationSeriesHistory(name: "nativeQuota:primary", windowMinutes: 300, entries: [
            .init(
                capturedAt: start.addingTimeInterval(-400),
                usedPercent: 60,
                resetsAt: start.addingTimeInterval(-100)),
            .init(
                capturedAt: start.addingTimeInterval(200),
                usedPercent: 10,
                resetsAt: start.addingTimeInterval(200 + 5 * 3600)),
        ])
        let widget = NativeOrbitHistoryWidget(
            histories: [session], now: self.now, days: 1, calendar: calendar, provider: .claude)
        let lane = try #require(widget.lanes.first)
        #expect(lane.samples.map(\.date) == [-400, -100, -100, 200].map { start.addingTimeInterval($0) })
        #expect(lane.samples.map(\.isResetEdge) == [false, true, true, false])
        #expect(Set(lane.samples.map(\.segment)).count == 1)
        // Only resets inside the range are marked.
        #expect(!lane.resetEvents.contains { $0.date < widget.start })
    }

    @Test func `idle windows that run out add no visible rise`() throws {
        let session = self.lane("nativeQuota:primary", minutes: 300, [
            (-7500, 0, self.now.addingTimeInterval(-7200)),
            (-6900, 0, nil),
        ])
        let lane = try #require(NativeOrbitHistoryWidget(histories: [session], now: self.now, provider: .claude)
            .lanes.first)
        #expect(lane.resetEvents.isEmpty)
        #expect(lane.samples.map(\.available).allSatisfy { $0 == 100 })
        #expect(Set(lane.samples.map(\.segment)).count == 1)
    }

    private func lane(
        _ name: String,
        minutes: Int,
        _ points: [(TimeInterval, Double, Date?)]) -> PlanUtilizationSeriesHistory
    {
        .init(name: .init(rawValue: name), windowMinutes: minutes, entries: points.map {
            .init(capturedAt: self.now.addingTimeInterval($0.0), usedPercent: $0.1, resetsAt: $0.2)
        })
    }
}
