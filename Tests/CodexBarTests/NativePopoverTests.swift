import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct NativePopoverTests {
    @Test func `prepared popup keeps its native host and separate account columns between opens`() throws {
        let settings = testSettingsStore(suiteName: "NativePopover", userDefaults: InMemoryUserDefaults())
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.mergeIcons = false
        enableTestProviders([.kimi], settings: settings)
        settings.addTokenAccount(provider: .kimi, label: "First", token: "fixture-first")
        settings.addTokenAccount(provider: .kimi, label: "Second", token: "fixture-second")
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        store.snapshots[.kimi] = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 25,
                windowMinutes: 300,
                resetsAt: nil,
                resetDescription: nil),
            secondary: nil,
            updatedAt: Date())
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(
                email: nil,
                plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            menuCardRenderingEnabled: false,
            menuRefreshEnabled: false)
        defer { controller.releaseStatusItemsForTesting() }
        let button = try #require(controller.statusItems[.kimi]?.button)
        let started = ContinuousClock.now
        let first = controller.nativePopover(for: .kimi, button: button)
        let second = controller.nativePopover(for: .kimi, button: button)
        print("Native popup preparation: \(started.duration(to: .now))")
        #expect(first === second, "Reopening must reuse the prepared native popup")
        let content = try #require(first.contentViewController as? NativeServicePopoverController)
        content.popoverDidShow(Notification(name: NSPopover.didShowNotification))
        #expect(content.presentationClockTask != nil)
        content.popoverDidClose(Notification(name: NSPopover.didCloseNotification))
        #expect(content.presentationClockTask == nil)
        content.orbitState.now = Date.distantPast
        content.popoverWillShow(Notification(name: NSPopover.willShowNotification))
        #expect(abs(content.orbitState.now.timeIntervalSinceNow) < 2)
        content.popoverDidClose(Notification(name: NSPopover.didCloseNotification))
        #expect(controller.manualRefreshTasks.isEmpty)

        #expect(first.animates, "The popup uses the standard native presentation animation")
        #expect(content.orbitState.accounts.count >= 2)
        #expect(first.contentSize.height == 551, "The host fits the account separator and flush toolbar")
        #expect(first.contentSize.width > 480, "Accounts occupy separate columns")
    }

    @Test func `retained native popup observes usage updates without reconstructing its controller`() async throws {
        let settings = testSettingsStore(suiteName: "NativePopoverUpdates", userDefaults: InMemoryUserDefaults())
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        enableTestProviders([.kimi], settings: settings)
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(
                email: nil,
                plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            menuCardRenderingEnabled: false,
            menuRefreshEnabled: false)
        defer { controller.releaseStatusItemsForTesting() }
        let button = try #require(controller.statusItem.button)
        let popup = controller.nativePopover(for: .kimi, button: button)
        let viewController = try #require(popup.contentViewController as? NativeServicePopoverController)
        let root = viewController.view
        viewController.hiddenPresentationDelay = .milliseconds(200)
        store.snapshots[.kimi] = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 73,
                windowMinutes: 300,
                resetsAt: nil,
                resetDescription: nil),
            secondary: nil,
            updatedAt: Date())
        // A closed popup coalesces background updates so clicks never wait behind them.
        for _ in 0..<120 {
            if viewController.orbitState.accounts.first?.gauge.resolvedWindows.first?.usedFraction == 0.73 { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        #expect(viewController.orbitState.accounts.first?.gauge.resolvedWindows.first?.usedFraction == 0.73)
        #expect(controller.nativePopover(for: .kimi, button: button).contentViewController === viewController)
        #expect(viewController.view === root)
        #expect(controller.manualRefreshTasks.isEmpty, "Preparing and publishing usage must not start a fetch")
        let started = ContinuousClock.now
        for _ in 0..<100 {
            _ = controller.nativePopover(for: .kimi, button: button)
        }
        print("100 warmed native popup lookups: \(started.duration(to: .now))")
    }

    @Test func `an opening popup draws its prepared columns and applies pending changes once shown`() async throws {
        let settings = testSettingsStore(suiteName: "NativePopoverOpening", userDefaults: InMemoryUserDefaults())
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        enableTestProviders([.kimi], settings: settings)
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        func publish(_ used: Double) {
            store.snapshots[.kimi] = UsageSnapshot(
                primary: RateWindow(usedPercent: used, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: Date())
        }
        publish(25)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            menuCardRenderingEnabled: false,
            menuRefreshEnabled: false)
        defer { controller.releaseStatusItemsForTesting() }
        let button = try #require(controller.statusItem.button)
        let popup = controller.nativePopover(for: .kimi, button: button)
        let viewController = try #require(popup.contentViewController as? NativeServicePopoverController)
        var used: Double? {
            viewController.orbitState.accounts.first?.gauge.resolvedWindows.first?.usedFraction
        }
        func waitForUsed(_ expected: Double) async {
            for _ in 0..<120 where used != expected {
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        #expect(used == 0.25)

        publish(73)
        try? await Task.sleep(for: .milliseconds(100))
        viewController.popoverWillShow(Notification(name: NSPopover.willShowNotification))
        try? await Task.sleep(for: .milliseconds(300))
        #expect(used == 0.25, "The opening frame must not wait behind a rebuild")
        viewController.popoverDidShow(Notification(name: NSPopover.didShowNotification))
        await waitForUsed(0.73)
        #expect(used == 0.73)
        viewController.popoverDidClose(Notification(name: NSPopover.didCloseNotification))

        publish(50)
        try? await Task.sleep(for: .milliseconds(100))
        viewController.beginCombinedPresentation()
        try? await Task.sleep(for: .milliseconds(300))
        #expect(used == 0.73, "A combined popup also opens on its prepared columns")
        viewController.combinedPresentationDidShow()
        await waitForUsed(0.5)
        #expect(used == 0.5)
        viewController.endCombinedPresentation()
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { self.descendants($0) }
    }

    @Test func `native Claude columns preserve the active login after a failed switch`() throws {
        let settings = testSettingsStore(suiteName: "NativeClaudeInspection", userDefaults: InMemoryUserDefaults())
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.hidePersonalInfo = false
        settings.claudeSwapEnabled = true
        settings.claudeSwapShowSingleAccount = true
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        let active = ProviderAccountIdentity(source: "claude-swap", opaqueID: "1")
        let failed = ProviderAccountIdentity(source: "claude-swap", opaqueID: "2")
        store.claudeSwapAccountSnapshots = [
            .init(
                id: active,
                provider: .claude,
                displayLabel: "Active login",
                isActive: true,
                snapshot: UsageSnapshot(
                    primary: RateWindow(usedPercent: 12, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                    secondary: nil,
                    updatedAt: Date()),
                error: nil,
                sourceLabel: "fixture"),
            .init(
                id: failed,
                provider: .claude,
                displayLabel: "Failed login",
                isActive: false,
                snapshot: nil,
                error: "Credentials unavailable",
                sourceLabel: "fixture"),
        ]
        store.claudeSwapTransientState.lastErrorAccountID = failed
        store.claudeSwapTransientState.lastError = "Activation failed"
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            menuCardRenderingEnabled: false,
            menuRefreshEnabled: false)
        defer { controller.releaseStatusItemsForTesting() }
        let popup = try controller.nativePopover(for: .claude, button: #require(controller.statusItem.button))
        let content = try #require(popup.contentViewController as? NativeServicePopoverController)
        #expect(content.orbitState.accounts.first?.id == "claude-swap:1")
        #expect(content.orbitState.accounts.first?.isActive == true)
        #expect(content.orbitState.accounts.first?.gauge.resolvedWindows.first?.usedFraction == 0.12)
        let failedAccount = try #require(content.orbitState.accounts.first { $0.id == "claude-swap:2" })
        #expect(failedAccount.gauge.resolvedWindows.allSatisfy { $0.usedFraction == nil })
        #expect(failedAccount.statusText != nil)
        #expect(controller.manualRefreshTasks.isEmpty)
    }

    @Test func `native account menu preserves separate identities with the same label`() throws {
        let settings = testSettingsStore(suiteName: "NativeDuplicateAccounts", userDefaults: InMemoryUserDefaults())
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.hidePersonalInfo = false
        settings.addTokenAccount(provider: .kimi, label: "Same label", token: "fixture-first")
        settings.addTokenAccount(provider: .kimi, label: "Same label", token: "fixture-second")
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(
                email: nil,
                plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            menuCardRenderingEnabled: false,
            menuRefreshEnabled: false)
        defer { controller.releaseStatusItemsForTesting() }
        let popup = try controller.nativePopover(for: .kimi, button: #require(controller.statusItem.button))
        let content = try #require(popup.contentViewController as? NativeServicePopoverController)
        let expectedIDs = Set(settings.tokenAccounts(for: .kimi).map(\.id.uuidString))
        let actualIDs = Set(content.orbitState.accounts.map(\.id))
        #expect(expectedIDs.isSubset(of: actualIDs))
        #expect(actualIDs.count == content.orbitState.accounts.count)
    }

    @Test func `Codex anonymous recovery remains a separate archive and never enters a Claude popup`() throws {
        let settings = testSettingsStore(suiteName: "NativeCodexArchive", userDefaults: InMemoryUserDefaults())
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        enableTestProviders([.codex, .claude], settings: settings)
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        let history = PlanUtilizationSeriesHistory(name: "nativeQuota:secondary", windowMinutes: 10080, entries: [
            .init(capturedAt: Date(), usedPercent: 37, resetsAt: nil),
        ])
        store.planUtilizationHistory[.codex] = .init(unscoped: [history])
        store.planUtilizationHistoryLoaded = true
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            menuCardRenderingEnabled: false,
            menuRefreshEnabled: false)
        defer { controller.releaseStatusItemsForTesting() }
        let button = try #require(controller.statusItem.button)
        let codexPopup = controller.nativePopover(for: .codex, button: button)
        let codex = try #require(codexPopup.contentViewController as? NativeServicePopoverController)
        #expect(codex.orbitState.codexLocalArchiveHistory == [history])
        #expect(codexPopup.contentSize.width == 240, "Recovered archives do not add visible columns")
        #expect(codex.orbitState.claudeLocalArchiveHistory.isEmpty)
        #expect(codex.orbitState.accounts.allSatisfy { !$0.history.contains(history) })
        let claudePopup = controller.nativePopover(for: .claude, button: button)
        let claude = try #require(claudePopup.contentViewController as? NativeServicePopoverController)
        #expect(claude.orbitState.codexLocalArchiveHistory.isEmpty)
    }
}
