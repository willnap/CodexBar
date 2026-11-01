import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

/// These tests exercise the native delegate wiring without presenting a popup or loading provider content.
@MainActor
@Suite(.serialized)
struct NativeOrbitStartupControllerTests {
    @Test func `preparing combined account data does not construct a hidden standalone popup`() throws {
        let fixture = try self.fixture(launch: NativeOrbitStartupLaunch(), installView: false)
        defer { self.cleanUp(fixture) }
        #expect(!fixture.controller.isViewLoaded)
        fixture.controller.prepare()
        #expect(!fixture.controller.orbitState.accounts.isEmpty)
        #expect(!fixture.controller.isViewLoaded)
        fixture.controller.beginCombinedPresentation()
        #expect(!fixture.controller.isViewLoaded)
        fixture.controller.endCombinedPresentation()
    }

    @Test func `notifications without a popup do not arm or consume the launch`() throws {
        let launch = NativeOrbitStartupLaunch()
        let fixture = try self.fixture(launch: launch)
        defer { self.cleanUp(fixture) }
        fixture.controller.popoverWillShow(Notification(name: NSPopover.willShowNotification))
        fixture.controller.popoverDidShow(Notification(name: NSPopover.didShowNotification))
        #expect(fixture.controller.orbitState.startup == .live)
        #expect(!launch.hasShown)
        let otherOwner = UUID()
        #expect(launch.reserve(otherOwner), "A nil notification must not retain a launch reservation")
        launch.cancel(otherOwner)
    }

    @Test func `real popup notifications arm before display and consume only after display`() throws {
        let launch = NativeOrbitStartupLaunch()
        let fixture = try self.fixture(launch: launch)
        defer { self.cleanUp(fixture) }
        let popup = NSPopover()
        fixture.controller.popoverWillShow(Notification(name: NSPopover.willShowNotification, object: popup))
        #expect(fixture.controller.orbitState.startup.isActive)
        #expect(fixture.controller.orbitState.startupCheckpoint == 0)
        #expect(!fixture.controller.orbitState.isBulbCheck)
        #expect(!launch.hasShown)
        fixture.controller.popoverDidShow(Notification(name: NSPopover.didShowNotification, object: popup))
        #expect(launch.hasShown)
        #expect(!launch.reserve(UUID()))
    }

    @Test func `closing immediately cancels the queued startup and reopening cannot replay it`() async throws {
        let launch = NativeOrbitStartupLaunch()
        let fixture = try self.fixture(launch: launch)
        defer { self.cleanUp(fixture) }
        let popup = NSPopover()
        fixture.controller.popoverWillShow(Notification(name: NSPopover.willShowNotification, object: popup))
        fixture.controller.popoverDidShow(Notification(name: NSPopover.didShowNotification, object: popup))
        fixture.controller.popoverWillClose(Notification(name: NSPopover.willCloseNotification, object: popup))
        #expect(fixture.controller.orbitState.startup == .live)
        #expect(fixture.controller.orbitState.startupCheckpoint == 0)
        await Task.yield()
        #expect(fixture.controller.orbitState.startup == .live)
        fixture.controller.popoverDidClose(Notification(name: NSPopover.didCloseNotification, object: popup))
        #expect(fixture.controller.presentationClockTask == nil)
        fixture.controller.popoverWillShow(Notification(name: NSPopover.willShowNotification, object: popup))
        fixture.controller.popoverDidShow(Notification(name: NSPopover.didShowNotification, object: popup))
        await Task.yield()
        #expect(fixture.controller.orbitState.startup == .live)
        #expect(fixture.controller.orbitState.startupCheckpoint == 0)
        #expect(!fixture.controller.orbitState.isBulbCheck)
        #expect(launch.hasShown)
    }

    @Test func `closing before display releases the reservation to another controller`() throws {
        let launch = NativeOrbitStartupLaunch()
        let first = try self.fixture(launch: launch)
        defer { self.cleanUp(first) }
        let second = try self.fixture(launch: launch)
        defer { self.cleanUp(second) }
        let firstPopup = NSPopover(), secondPopup = NSPopover()
        first.controller.popoverWillShow(Notification(name: NSPopover.willShowNotification, object: firstPopup))
        #expect(first.controller.orbitState.startup.isActive)
        #expect(!launch.hasShown)
        first.controller.popoverWillClose(Notification(name: NSPopover.willCloseNotification, object: firstPopup))
        #expect(first.controller.orbitState.startup == .live)
        second.controller.popoverWillShow(Notification(name: NSPopover.willShowNotification, object: secondPopup))
        #expect(second.controller.orbitState.startup.isActive)
        // A late did-close from the first owner must not cancel the second owner's reservation.
        first.controller.popoverDidClose(Notification(name: NSPopover.didCloseNotification, object: firstPopup))
        second.controller.popoverDidShow(Notification(name: NSPopover.didShowNotification, object: secondPopup))
        #expect(launch.hasShown)
        #expect(second.controller.orbitState.startup.isActive)
    }

    private struct Fixture {
        let controller: NativeServicePopoverController
        let statusItem: NSStatusItem
    }

    private func fixture(launch: NativeOrbitStartupLaunch, installView: Bool = true) throws -> Fixture {
        _ = NSApplication.shared
        let settings = testSettingsStore(
            suiteName: "NativeOrbitStartupController",
            userDefaults: InMemoryUserDefaults(),
            keychainAccessPolicy: .init(setDisabled: { _ in }, isExplicitlyDisabled: { true }))
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else {
            NSStatusBar.system.removeStatusItem(statusItem)
            throw MissingStatusButton()
        }
        let actions = NativeServicePopoverController.Actions(
            refresh: { Issue.record("Lifecycle notification unexpectedly requested a refresh") },
            signIn: { Issue.record("Lifecycle notification unexpectedly requested sign in") },
            dashboard: { Issue.record("Lifecycle notification unexpectedly requested a dashboard") },
            settings: { Issue.record("Lifecycle notification unexpectedly requested settings") },
            advanced: { Issue.record("Lifecycle notification unexpectedly requested advanced settings") },
            quit: { Issue.record("Lifecycle notification unexpectedly requested quit") },
            selectCodexAccount: { _ in Issue.record("Lifecycle notification unexpectedly selected an account") },
            selectTokenAccount: { _ in Issue.record("Lifecycle notification unexpectedly selected an account") },
            selectClaudeSwapAccount: { _ in Issue.record("Lifecycle notification unexpectedly selected an account") })
        let controller = NativeServicePopoverController(
            provider: .kimi,
            store: store,
            settings: settings,
            button: button,
            actions: actions,
            canSignIn: false,
            signInTitle: "Fixture",
            hasDashboard: { false },
            startupLaunch: launch)
        // Exercise AppKit's delegate lifecycle without invoking the content-loading path.
        if installView { controller.view = NSView(frame: CGRect(x: 0, y: 0, width: 240, height: 480)) }
        return Fixture(controller: controller, statusItem: statusItem)
    }

    private func cleanUp(_ fixture: Fixture) {
        fixture.controller.popoverDidClose(Notification(name: NSPopover.didCloseNotification))
        NSStatusBar.system.removeStatusItem(fixture.statusItem)
    }

    private struct MissingStatusButton: Error {}
}
