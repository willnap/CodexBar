import Foundation
import Testing
@testable import CodexBar

@MainActor
struct NativeOrbitHistoryRuleBatchTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func `recorded batching preserves source order and separates lane ink and glyph annotations`() {
        func event(
            _ kind: NativeOrbitResetEvent.Kind,
            _ index: Int,
            lane: String = "primary") -> NativeOrbitResetEvent
        {
            .init(kind: kind, date: self.now.addingTimeInterval(Double(index)), earliest: nil, laneIDs: [lane])
        }
        let events = [
            event(.natural, 0), event(.natural, 1), event(.natural, 2, lane: "secondary"),
            event(.natural, 3), event(.manual, 4), event(.manual, 5), event(.natural, 6), event(.natural, 7),
        ]
        let batches = NativeOrbitHistoryWidget.ruleBatches(events)
        #expect(batches.map(\.events.count) == [2, 1, 1, 1, 1, 2])
        #expect(batches.flatMap(\.events) == events)
        #expect(batches.map(\.id) == [events[0], events[2], events[3], events[4], events[5], events[6]].map(\.id))
    }

    @Test func `projected batching never crosses another style or merges glyph bearing events`() {
        func event(_ kind: NativeOrbitScheduledEvent.Kind, _ index: Int) -> NativeOrbitScheduledEvent {
            .init(
                id: "event-\(index)",
                date: self.now.addingTimeInterval(Double(index)),
                label: "Event",
                recoveryPercent: nil,
                kind: kind,
                laneIDs: ["primary"])
        }
        let events = [
            event(.windowReset, 0), event(.windowReset, 1), event(.planExpiry, 2),
            event(.bankedResetExpiry, 3), event(.bankedResetExpiry, 4), event(.windowReset, 5),
        ]
        let batches = NativeOrbitHistoryWidget.ruleBatches(events)
        #expect(batches.map(\.events.count) == [2, 1, 1, 1, 1])
        #expect(batches.flatMap(\.events) == events)
    }
}
