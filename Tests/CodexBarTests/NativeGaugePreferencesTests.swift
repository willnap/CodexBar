import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct NativeGaugePreferencesTests {
    @Test func `native defaults replace invalid cadence and survive a subsequent opt out`() {
        let defaults = InMemoryUserDefaults(values: ["refreshFrequency": "obsolete"])
        NativeGaugePreferences.prepare(defaults: defaults, isNative: true)
        let settings = testSettingsStore(suiteName: "NativeDefaults", userDefaults: defaults)
        #expect(settings.refreshFrequency == .adaptive)
        #expect(settings.launchAtLogin)
        #expect(!settings.refreshAllProvidersOnMenuOpen)
        settings.refreshFrequency = .manual
        settings.launchAtLogin = false
        NativeGaugePreferences.prepare(defaults: defaults, isNative: true)
        let restored = testSettingsStore(suiteName: "NativeDefaults", userDefaults: defaults)
        #expect(restored.refreshFrequency == .manual)
        #expect(!restored.launchAtLogin)
    }

    @Test func `native style persists while invalid styles recover to custom gauges`() {
        let defaults = InMemoryUserDefaults(values: ["nativeGaugeStyle": "removed-layout"])
        let settings = testSettingsStore(
            suiteName: "NativeStyle", userDefaults: defaults, nativeDesignEnabled: true)
        #expect(settings.nativeGaugeStyle == .laurel)
        #expect(settings.usesNativeGauges)
        settings.nativeGaugeStyle = .legacy
        let restored = testSettingsStore(
            suiteName: "NativeStyle", userDefaults: defaults, nativeDesignEnabled: true)
        #expect(restored.nativeGaugeStyle == .legacy)
        #expect(!restored.usesNativeGauges)
        restored.nativeGaugeStyle = .laurel
        #expect(defaults.string(forKey: "nativeGaugeStyle") == "laurel")
    }

    @Test func `native preparation preserves explicit refresh and login choices`() {
        let defaults = InMemoryUserDefaults(values: [
            "refreshFrequency": "twoMinutes",
            "launchAtLogin": false,
            "refreshAllProvidersOnMenuOpen": true,
        ])
        NativeGaugePreferences.prepare(defaults: defaults, isNative: true)
        let settings = testSettingsStore(suiteName: "NativeExplicit", userDefaults: defaults)
        #expect(settings.refreshFrequency == .twoMinutes)
        #expect(!settings.launchAtLogin)
        #expect(settings.refreshAllProvidersOnMenuOpen)
    }
}
