import Foundation
import Testing
@testable import CodexBar

@MainActor
struct NativeOrbitToolbarTests {
    private static func label(_ text: String) -> String {
        NativeOrbitToolbar.sentenceCased(text, locale: codexBarLocalizedResourceLocale())
    }

    @Test
    func `refresh age uses coarse units and clamps clock skew`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(NativeOrbitToolbar.age(now.addingTimeInterval(60), now: now) == Self.label(L("just now")))
        #expect(NativeOrbitToolbar.age(now.addingTimeInterval(-59), now: now) == Self.label(L("%ds ago", 30)))
        #expect(NativeOrbitToolbar.age(now.addingTimeInterval(-30), now: now) == Self.label(L("%ds ago", 30)))
        #expect(NativeOrbitToolbar.age(now.addingTimeInterval(-61), now: now) == Self.label(L("%dm ago", 1)))
        #expect(NativeOrbitToolbar.age(now.addingTimeInterval(-3599), now: now) == Self.label(L("%dm ago", 59)))
        #expect(NativeOrbitToolbar.age(now.addingTimeInterval(-3600), now: now) == Self.label(L("%dh ago", 1)))
        #expect(NativeOrbitToolbar.age(now.addingTimeInterval(-86400), now: now) == Self.label(L("%dd ago", 1)))
    }

    @Test
    func `refresh age stays still between display boundaries`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for seconds in [0.0, 10, 29, 29.999] {
            #expect(NativeOrbitToolbar.age(now.addingTimeInterval(-seconds), now: now) == Self.label(L("just now")))
            #expect(NativeOrbitToolbar.displayAgeSeconds(now.addingTimeInterval(-seconds), now: now) == 0)
        }
        for seconds in [30.0, 31, 45, 59.999] {
            #expect(NativeOrbitToolbar.age(now.addingTimeInterval(-seconds), now: now) == Self.label(L("%ds ago", 30)))
            #expect(NativeOrbitToolbar.displayAgeSeconds(now.addingTimeInterval(-seconds), now: now) == 30)
        }
        for seconds in [60.0, 61, 90, 119.999] {
            #expect(NativeOrbitToolbar.age(now.addingTimeInterval(-seconds), now: now) == Self.label(L("%dm ago", 1)))
            #expect(NativeOrbitToolbar.displayAgeSeconds(now.addingTimeInterval(-seconds), now: now) == 60)
        }
        #expect(NativeOrbitToolbar.age(now.addingTimeInterval(-120), now: now) == Self.label(L("%dm ago", 2)))
        #expect(NativeOrbitToolbar.displayAgeSeconds(now.addingTimeInterval(-3661), now: now) == 3600)
        #expect(NativeOrbitToolbar.displayAgeSeconds(now.addingTimeInterval(-86461), now: now) == 86400)
    }

    @Test
    func `standalone age labels start with a capital in every catalog casing`() {
        let english = Locale(identifier: "en")
        #expect(NativeOrbitToolbar.sentenceCased("just now", locale: english) == "Just now")
        #expect(NativeOrbitToolbar.sentenceCased("5m ago", locale: english) == "5m ago")
        #expect(NativeOrbitToolbar.sentenceCased("fa 5min", locale: Locale(identifier: "ca")) == "Fa 5min")
        #expect(NativeOrbitToolbar.sentenceCased("az önce", locale: Locale(identifier: "tr")) == "Az önce")
        #expect(NativeOrbitToolbar.sentenceCased("5分前", locale: Locale(identifier: "ja")) == "5分前")
        #expect(NativeOrbitToolbar.sentenceCased("", locale: english).isEmpty)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let age = NativeOrbitToolbar.age(now, now: now)
        #expect(age.first.map { String($0) == String($0).uppercased() } ?? false)
    }

    @Test
    func `compact age drops ago for a single column`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let english = Locale(identifier: "en_US")
        #expect(NativeOrbitToolbar.compactAge(now.addingTimeInterval(-10), now: now, locale: english) == L("Now"))
        #expect(NativeOrbitToolbar.compactAge(now.addingTimeInterval(-45), now: now, locale: english) == "30s")
        #expect(NativeOrbitToolbar.compactAge(now.addingTimeInterval(-300), now: now, locale: english) == "5m")
        #expect(NativeOrbitToolbar.compactAge(now.addingTimeInterval(-7300), now: now, locale: english) == "2h")
        #expect(NativeOrbitToolbar.compactAge(now.addingTimeInterval(-3 * 86400), now: now, locale: english) == "3d")
        let german = NativeOrbitToolbar.compactAge(
            now.addingTimeInterval(-300), now: now, locale: Locale(identifier: "de"))
        #expect(german.contains("5"))
        #expect(!german.localizedCaseInsensitiveContains("vor"))
    }
}
