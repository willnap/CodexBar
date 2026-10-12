import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct NativeProviderRoutingTests {
    @Test func `Kimi credential failure keeps its native popup route and error presentation`() throws {
        let settings = testSettingsStore(
            suiteName: "NativeKimiRouting",
            userDefaults: InMemoryUserDefaults(),
            nativeDesignEnabled: true)
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        enableTestProviders([.kimi], settings: settings)
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        let error = "Kimi Code CLI credential invalid or expired."
        store.errors[.kimi] = error
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            menuCardRenderingEnabled: false,
            menuRefreshEnabled: false)
        defer { controller.releaseStatusItemsForTesting() }

        let item = try #require(controller.statusItems[.kimi])
        let button = try #require(item.button)
        let popup = controller.nativePopover(for: .kimi, button: button)
        let content = try #require(popup.contentViewController as? NativeServicePopoverController)
        #expect(store.snapshots[.kimi] == nil)
        #expect(controller.isVisible(.kimi))
        #expect(item.menu == nil)
        #expect(button.target === controller)
        #expect(button.action == #selector(StatusItemController.nativeServiceClicked(_:)))
        #expect(content.orbitState.accounts.first?.statusText == error)

        controller.updateIcons()
        #expect(controller.nativeServicePopovers[.kimi] === popup)
        #expect(button.action == #selector(StatusItemController.nativeServiceClicked(_:)))
        #expect(item.menu == nil)
        #expect(content.orbitState.accounts.first?.statusText == error)
        #expect(controller.manualRefreshTasks.isEmpty)
    }
}
