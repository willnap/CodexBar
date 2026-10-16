import Foundation

/// Consecutive rules with identical ink can share one plot without changing source layering. A glyph-bearing
/// event always owns its own batch, preserving its original rule-then-annotation order.
struct NativeOrbitHistoryRuleBatch<Event: Identifiable>: Identifiable {
    let prototype: Event
    fileprivate(set) var events: [Event]
    var id: Event.ID {
        self.prototype.id
    }

    fileprivate init(_ event: Event) {
        self.prototype = event
        self.events = [event]
    }
}

struct NativeOrbitHistoryRulePoint {
    let date: Date
    let label: String
}

extension NativeOrbitHistoryWidget {
    static func ruleBatches(_ events: [NativeOrbitResetEvent]) -> [NativeOrbitHistoryRuleBatch<NativeOrbitResetEvent>] {
        self.consecutiveRuleBatches(events) {
            Self.resetSymbol($0.kind) == nil ? "\($0.kind)|\($0.laneIDs)" : $0.id
        }
    }

    static func ruleBatches(
        _ events: [NativeOrbitScheduledEvent]) -> [NativeOrbitHistoryRuleBatch<NativeOrbitScheduledEvent>]
    {
        self.consecutiveRuleBatches(events) {
            NativeOrbitProjectionStyle.eventSymbol($0.kind) == nil ? "\($0.kind)|\($0.laneIDs)" : $0.id
        }
    }

    private static func consecutiveRuleBatches<Event: Identifiable>(
        _ events: [Event], styleKey: (Event) -> String) -> [NativeOrbitHistoryRuleBatch<Event>]
    {
        var result: [NativeOrbitHistoryRuleBatch<Event>] = []
        var previous: String?
        for event in events {
            let key = styleKey(event)
            if previous == key {
                result[result.count - 1].events.append(event)
            } else {
                result.append(NativeOrbitHistoryRuleBatch(event))
                previous = key
            }
        }
        return result
    }
}
