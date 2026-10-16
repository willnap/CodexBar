import Foundation
import Testing
@testable import CodexBar

@MainActor
struct NativeOrbitInspectedInstantTests {
    @Test func `inspection clock preserves relative and distant dates across daylight saving`() throws {
        let clock = NativeOrbitInspectedInstantFormatter()
        for zone in ["UTC", "Europe/London", "America/New_York"] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try #require(TimeZone(identifier: zone))
            let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 29, hour: 12)))
            for locale in [Locale(identifier: "en_US"), Locale(identifier: "fr_FR")] {
                for hours in [-73.0, -36, -24, -12, 0, 12, 24, 36, 73] {
                    let date = now.addingTimeInterval(hours * 3600)
                    #expect(clock.string(from: date, now: now, calendar: calendar, locale: locale)
                        == self.reference(date, now: now, calendar: calendar, locale: locale))
                }
            }
        }
    }

    @Test func `inspection clock refreshes its nearby days when the origin crosses midnight`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 23)))
        let date = now.addingTimeInterval(26 * 3600)
        let clock = NativeOrbitInspectedInstantFormatter()
        let locale = Locale(identifier: "en_GB")
        for origin in [now, now.addingTimeInterval(2 * 3600), now] {
            #expect(clock.string(from: date, now: origin, calendar: calendar, locale: locale)
                == self.reference(date, now: origin, calendar: calendar, locale: locale))
        }
    }

    private func reference(_ date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        let nearby = [-1, 0, 1].contains { offset in
            calendar.date(byAdding: .day, value: offset, to: now).map { calendar.isDate(date, inSameDayAs: $0) }
                ?? false
        }
        if nearby {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.doesRelativeDateFormatting = true
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return formatter.string(from: date)
        }
        var style = Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale, calendar: calendar)
            .weekday(.abbreviated)
        style.timeZone = calendar.timeZone
        return date.formatted(style.year(.omitted))
    }
}
