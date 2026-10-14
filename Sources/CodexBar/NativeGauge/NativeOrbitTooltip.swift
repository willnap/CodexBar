import Foundation

/// The popup's tooltip voice. A tooltip says what the hovered thing means in one plain line, two at most: the exact
/// figure the face rounds, what it covers, and the one caveat that changes how to read it. It never chains metadata,
/// never repeats a visible label, and leaves out internal terms, seconds, years and time zones.
enum NativeOrbitTooltip {
    /// A moment as briefly as it reads unambiguously: "3:42 PM" on the same day, "Tue 3:42 PM" within a week either
    /// way, "Oct 20" further out.
    static func moment(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(.dateTime.hour().minute())
        }
        if abs(date.timeIntervalSince(now)) < 6 * 86400 {
            return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// `moment` worded to follow a verb: "at 3:42 PM" on the same day, otherwise "Tue 3:42 PM" or "Oct 20".
    static func at(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let text = self.moment(date, now: now, calendar: calendar)
        return calendar.isDate(date, inSameDayAs: now) ? "at \(text)" : text
    }

    /// "today" or "in the last 7 days", to end a sentence about the selected range.
    static func during(days: Int) -> String {
        days == 1 ? "today" : "in the last \(days) days"
    }

    /// "today" or "the last 7 days", as the object of "for".
    static func range(days: Int) -> String {
        days == 1 ? "today" : "the last \(days) days"
    }

    /// Where the figure comes from, when that is narrower than the whole account.
    static func scope(_ scope: NativeOrbitUsageScope) -> String {
        switch scope {
        case .account: ""
        case .localProfile: " in this profile on this Mac"
        case .localMachine: " on this Mac"
        }
    }

    /// "2h 14m", "4d 3h" or "12m" until a moment ahead.
    static func countdown(to date: Date, now: Date) -> String {
        let minutes = max(1, Int((date.timeIntervalSince(now) / 60).rounded(.up)))
        let days = minutes / 1440
        let hours = minutes % 1440 / 60
        if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
        if hours > 0 { return minutes % 60 > 0 ? "\(hours)h \(minutes % 60)m" : "\(hours)h" }
        return "\(minutes)m"
    }
}
