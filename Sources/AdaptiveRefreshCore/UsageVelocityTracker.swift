import Foundation

/// How fast the quotas in use are being consumed, from the readings refreshes already take.
///
/// Pace is consumption relative to the window: 1 means the whole allowance would last exactly one window at the
/// observed rate, 2 that it is gone in half of one. Services report whole percentages, so one reading step says
/// little; the pace is taken across everything seen in the last half hour.
package struct UsageVelocityTracker: Sendable {
    private struct Reading: Sendable {
        let usedPercent: Double
        let at: Date
    }

    private struct Lane: Sendable {
        var windowSeconds: TimeInterval
        var readings: [Reading]
    }

    /// Readings older than this no longer describe what is happening now.
    package static let horizon: TimeInterval = 30 * 60
    /// The shortest stretch of readings a pace is taken from.
    package static let minimumSpan: TimeInterval = 4 * 60
    /// A drop this large is a reset or a different account, not a correction.
    private static let resetDrop = 0.5

    private var lanes: [String: Lane] = [:]

    package init() {}

    /// Records one lane's reading. `key` names the service, account and quota it belongs to.
    package mutating func note(key: String, usedPercent: Double, windowSeconds: TimeInterval, at date: Date) {
        guard usedPercent.isFinite, usedPercent >= 0, windowSeconds.isFinite, windowSeconds > 0,
              date.timeIntervalSinceReferenceDate.isFinite else { return }
        var lane = self.lanes[key] ?? Lane(windowSeconds: windowSeconds, readings: [])
        if lane.windowSeconds != windowSeconds {
            lane = Lane(windowSeconds: windowSeconds, readings: [])
        }
        if let last = lane.readings.last {
            // The same reading published again, or one from before the newest, adds nothing.
            guard date > last.at else { return }
            if usedPercent < last.usedPercent - Self.resetDrop { lane.readings.removeAll() }
        }
        lane.readings.append(Reading(usedPercent: usedPercent, at: date))
        lane.readings.removeAll { date.timeIntervalSince($0.at) > Self.horizon }
        self.lanes[key] = lane
    }

    /// The fastest pace among lanes still being read, or nil when none has enough readings to tell.
    package func fastestPace(now: Date) -> Double? {
        var fastest: Double?
        for lane in self.lanes.values {
            let recent = lane.readings.filter {
                (0...Self.horizon).contains(now.timeIntervalSince($0.at))
            }
            guard let first = recent.first, let last = recent.last else { continue }
            let span = last.at.timeIntervalSince(first.at)
            guard span >= Self.minimumSpan else { continue }
            let consumed = max(0, last.usedPercent - first.usedPercent) / 100
            let pace = consumed / (span / lane.windowSeconds)
            fastest = max(fastest ?? 0, pace)
        }
        return fastest
    }

    /// Forgets lanes that are no longer in use, so an account switched away from stops counting.
    package mutating func retain(keys: Set<String>) {
        self.lanes = self.lanes.filter { keys.contains($0.key) }
    }
}
