import Foundation

enum NativeOrbitChartTimeFormatter {
    /// App language and SwiftUI's display locale must not replace the user's system clock preference.
    static func locale(displayLocale: Locale, systemLocale: Locale = .autoupdatingCurrent) -> Locale {
        var components = Locale.Components(locale: displayLocale)
        components.hourCycle = systemLocale.hourCycle
        return Locale(components: components)
    }

    static func hourLabel(_ date: Date, calendar: Calendar, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("j")
        return formatter.string(from: date)
    }
}
