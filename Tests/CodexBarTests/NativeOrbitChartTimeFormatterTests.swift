import Foundation
import Testing
@testable import CodexBar

struct NativeOrbitChartTimeFormatterTests {
    @Test func `chart follows the system clock when its display locale prefers another cycle`() throws {
        let calendar = try self.calendar("UTC")
        let date = try self.date("2026-10-23T13:00:00Z")
        #expect(self.label(date, calendar: calendar, display: "en_GB", system: "en_US") == "1 pm")
        #expect(self.label(date, calendar: calendar, display: "en_US", system: "en_US") == "1 PM")
        #expect(self.label(date, calendar: calendar, display: "en_US", system: "en_GB") == "13")
    }

    @Test func `explicit system hour cycle overrides the regional default in either direction`() throws {
        let calendar = try self.calendar("UTC")
        let date = try self.date("2026-10-23T01:00:00Z")
        #expect(self.label(date, calendar: calendar, display: "en_GB", system: "en_GB@hours=h12") == "1 am")
        #expect(self.label(date, calendar: calendar, display: "en_US", system: "en_US@hours=h23") == "01")
    }

    @Test func `twelve hour labels distinguish midnight and noon without a leading zero`() throws {
        let calendar = try self.calendar("UTC")
        for (instant, expected) in [
            ("2026-10-23T00:00:00Z", "12 am"),
            ("2026-10-23T01:00:00Z", "1 am"),
            ("2026-10-23T12:00:00Z", "12 pm"),
            ("2026-10-23T13:00:00Z", "1 pm"),
        ] {
            #expect(try self.label(self.date(instant), calendar: calendar, display: "en_GB", system: "en_US")
                == expected)
        }
    }

    @Test func `chart keeps its calendar time zone across a daylight saving transition`() throws {
        let calendar = try self.calendar("Europe/London")
        for (instant, expected) in [
            ("2026-03-29T00:00:00Z", "12 am"),
            ("2026-03-29T01:00:00Z", "2 am"),
            ("2026-10-25T00:00:00Z", "1 am"),
            ("2026-10-25T01:00:00Z", "1 am"),
        ] {
            #expect(try self.label(self.date(instant), calendar: calendar, display: "en_GB", system: "en_US")
                == expected)
        }
    }

    @Test func `clock preference preserves the selected language and region`() {
        let locale = NativeOrbitChartTimeFormatter.locale(
            displayLocale: Locale(identifier: "fr_CA"), systemLocale: Locale(identifier: "en_US"))
        #expect(locale.language.languageCode?.identifier == "fr")
        #expect(locale.region?.identifier == "CA")
        #expect(locale.hourCycle == .oneToTwelve)
    }

    private func label(_ date: Date, calendar: Calendar, display: String, system: String) -> String {
        let locale = NativeOrbitChartTimeFormatter.locale(
            displayLocale: Locale(identifier: display), systemLocale: Locale(identifier: system))
        return NativeOrbitChartTimeFormatter.hourLabel(date, calendar: calendar, locale: locale)
            .replacingOccurrences(of: "\u{202F}", with: " ")
    }

    private func calendar(_ zone: String) throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: zone))
        return calendar
    }

    private func date(_ value: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: value))
    }
}
