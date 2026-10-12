import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct NativeGaugeClockTests {
    @Test func `live native weekly pace schedules a clock tick without a provider fetch`() {
        let settings = testSettingsStore(
            suiteName: "NativePaceClock", userDefaults: InMemoryUserDefaults(), nativeDesignEnabled: true)
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.paceVisible = true
        enableTestProviders([.kimi], settings: settings)
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        let now = Date()
        store.snapshots[.kimi] = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 25,
                windowMinutes: 10080,
                resetsAt: now.addingTimeInterval(3 * 86400),
                resetDescription: nil),
            secondary: nil,
            updatedAt: now)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            menuCardRenderingEnabled: false,
            menuRefreshEnabled: false)
        defer { controller.releaseStatusItemsForTesting() }
        controller.scheduleMenuBarCountdownRefreshIfNeeded(now: now)
        #expect(controller.menuBarCountdownRefreshTask != nil)
        #expect(controller.manualRefreshTasks.isEmpty)
        settings.paceVisible = false
        controller.scheduleMenuBarCountdownRefreshIfNeeded(now: now)
        #expect(controller.menuBarCountdownRefreshTask == nil)
    }
}
