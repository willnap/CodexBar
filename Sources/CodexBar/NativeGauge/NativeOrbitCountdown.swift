import Foundation

/// Popup segments represent days for multi-day quotas and hours for shorter quotas.
/// The compact menu bar may group days; the full-size dial has room for the actual calendar units.
struct NativeOrbitCountdown {
    let window: UsageWindow

    var segments: Int {
        guard let countdown = self.window.countdown else { return 1 }
        let period = Double(countdown.units) * countdown.secondsPerUnit
        guard period.isFinite, period >= 3600 else { return 1 }
        let unit: Double = period >= 2 * 86400 ? 86400 : 3600
        return max(1, Int(min(31, (period / unit).rounded(.up))))
    }

    func value(at now: Date) -> Double? {
        guard let countdown = self.window.countdown, countdown.isReliable,
              let deadline = countdown.nextReset else { return nil }
        let period = Double(countdown.units) * countdown.secondsPerUnit
        guard period.isFinite, period > 0 else { return nil }
        let remaining = min(period, max(0, deadline.timeIntervalSince(now)))
        return ceil(remaining / (period / Double(self.segments))) / Double(self.segments)
    }

    var description: String {
        guard let countdown = self.window.countdown, countdown.secondsPerUnit.isFinite,
              Double(countdown.units) * countdown.secondsPerUnit >= 3600
        else { return "Countdown scale unavailable" }
        let seconds = Double(countdown.units) * countdown.secondsPerUnit / Double(self.segments)
        let unit = seconds >= 86400 ? "\((seconds / 86400).formatted()) day" : "\((seconds / 3600).formatted()) hour"
        return "\(self.segments) segments · \(unit) per segment"
    }
}
