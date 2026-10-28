import Foundation

enum NativeGaugeStyle: String, CaseIterable, Identifiable {
    case laurel
    case legacy

    var id: String {
        self.rawValue
    }

    var label: String {
        switch self {
        case .laurel: L("Redesign")
        case .legacy: L("Original")
        }
    }
}

enum NativeGaugePreferences {
    static func prepare(defaults: UserDefaults, isNative: Bool) {
        guard isNative else { return }
        if defaults.string(forKey: "refreshFrequency").flatMap(RefreshFrequency.init(rawValue:)) == nil {
            defaults.set(RefreshFrequency.adaptive.rawValue, forKey: "refreshFrequency")
        }
        if defaults.object(forKey: "launchAtLogin") == nil {
            defaults.set(true, forKey: "launchAtLogin")
        }
    }
}

extension SettingsStore {
    var nativeGaugeStyle: NativeGaugeStyle {
        get { NativeGaugeStyle(rawValue: self.defaultsState.nativeGaugeStyleRaw) ?? .laurel }
        set { self.setDefault(\.nativeGaugeStyleRaw, newValue.rawValue, key: "nativeGaugeStyle") }
    }

    /// Off keeps one gauge per service until more than three are connected.
    var nativeCombinesAllServices: Bool {
        get { self.defaultsState.nativeCombinesAllServices }
        set { self.setDefault(\.nativeCombinesAllServices, newValue, key: "nativeCombinesAllServices") }
    }

    var usesNativeGauges: Bool {
        self.nativeDesignEnabled && self.nativeGaugeStyle == .laurel
    }
}
