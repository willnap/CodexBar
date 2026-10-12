import Foundation
import Testing
@testable import CodexBar

struct ProviderSettingsOrderingTests {
    @Test
    func `turning used first off restores the saved order`() {
        #expect(ProviderSettingsOrdering.prioritized(
            ["unused", "active", "configured"],
            enabled: { $0 == "active" },
            configured: { $0 == "configured" },
            usedFirst: false) == ["unused", "active", "configured"])
    }

    @MainActor
    @Test
    func `used first defaults on independently of the retired alphabetical preference and persists opt out`() {
        let defaults = InMemoryUserDefaults(values: ["providersSortedAlphabetically": false])
        let settings = testSettingsStore(suiteName: "SettingsProvidersUsedFirst", userDefaults: defaults)
        #expect(settings.settingsProvidersUsedFirst)
        settings.settingsProvidersUsedFirst = false
        let restored = testSettingsStore(suiteName: "SettingsProvidersUsedFirst", userDefaults: defaults)
        #expect(!restored.settingsProvidersUsedFirst)
    }

    @Test
    func `enabled and configured providers precede available providers in stable order`() {
        let providers = ["unused", "codex", "configured", "claude"]
        #expect(ProviderSettingsOrdering.prioritized(
            providers,
            enabled: { ["codex", "claude"].contains($0) },
            configured: { $0 == "configured" }) == ["codex", "claude", "configured", "unused"])
    }

    @Test
    func `reordering enabled providers preserves other provider positions`() {
        let providers = ["unused", "codex", "configured", "claude"]
        #expect(ProviderSettingsOrdering.reordered(
            providers,
            visible: ["codex", "claude"],
            fromOffsets: IndexSet(integer: 1),
            toOffset: 0) == ["unused", "claude", "configured", "codex"])
        #expect(ProviderSettingsOrdering.reordered(
            providers,
            visible: ["codex", "claude"],
            fromOffsets: IndexSet(integer: 0),
            toOffset: 2) == ["unused", "claude", "configured", "codex"])
    }
}
