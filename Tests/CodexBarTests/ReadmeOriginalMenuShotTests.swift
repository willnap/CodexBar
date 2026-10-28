import AppKit
import Foundation
import XCTest
@testable import CodexBar
@testable import CodexBarCore

/// Opens the original design's Claude menu with the README showcase's three fictional Claude logins, at default
/// settings, so the README can compare it with the redesign on the same data. Opt-in: set
/// `CODEXBAR_README_ORIGINAL_MENU_DIR`; the menu opens over `CODEXBAR_README_WALLPAPER`, away from the pointer, and the
/// test writes the screen rectangle to capture (`x,y,w,h` from the top left, in points) to `region.txt`, then closes
/// the menu once something writes `done`. `CODEXBAR_README_DARK=1` uses the dark appearance and
/// `CODEXBAR_README_VERSION` the app version the About item names, which a test process can't read.
@MainActor
final class ReadmeOriginalMenuShotTests: XCTestCase {
    func test_originalClaudeMenu() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let directoryPath = environment["CODEXBAR_README_ORIGINAL_MENU_DIR"] else {
            throw XCTSkip("Set CODEXBAR_README_ORIGINAL_MENU_DIR to open the original menu for a README capture.")
        }
        guard SettingsStore.isRunningTests,
              environment["CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS"] == "1",
              environment[CodexCredentialFileAccess.isolationEnvironmentKey] == "1",
              environment["CODEXBAR_TEST_SESSION_FILE_ISOLATION"] == "1",
              environment["CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS"] != "1"
        else {
            return XCTFail("The README capture requires credential and session isolation.")
        }
        let directory = URL(fileURLWithPath: directoryPath, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixture = try CodexWorkspacesNavigationFixture(userDefaults: InMemoryUserDefaults())
        defer { fixture.cleanup() }
        Self.seed(fixture)

        let oldRendering = StatusItemController.menuCardRenderingEnabled
        StatusItemController.menuCardRenderingEnabled = true
        defer { StatusItemController.menuCardRenderingEnabled = oldRendering }
        let controller = fixture.makeController()
        defer { controller.releaseStatusItemsForTesting() }
        let menu = controller.makeMenu(for: .claude)
        let appearance = NSAppearance(named: environment["CODEXBAR_README_DARK"] == "1" ? .darkAqua : .aqua)
        menu.appearance = appearance
        let version = environment["CODEXBAR_README_VERSION"]

        let application = NSApplication.shared
        application.appearance = appearance
        XCTAssertTrue(application.setActivationPolicy(.accessory))
        application.finishLaunching()
        // A wallpaper window under the menu, on whichever side of the screen the pointer isn't, so no row is hovered.
        let screen = try XCTUnwrap(NSScreen.main)
        let visible = screen.visibleFrame
        let size = NSSize(width: 520, height: min(visible.height, 900))
        let pointerOnLeft = NSEvent.mouseLocation.x < visible.midX
        let host = NSWindow(
            contentRect: NSRect(
                x: pointerOnLeft ? visible.maxX - size.width : visible.minX,
                y: visible.maxY - size.height,
                width: size.width,
                height: size.height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        host.isReleasedWhenClosed = false
        host.appearance = appearance
        if let path = environment["CODEXBAR_README_WALLPAPER"], let image = NSImage(contentsOfFile: path) {
            let view = NSView(frame: NSRect(origin: .zero, size: size))
            view.wantsLayer = true
            view.layer?.contents = image
            view.layer?.contentsGravity = .resizeAspectFill
            host.contentView = view
        }
        host.orderFront(nil)
        defer { host.close() }
        let screenTop = screen.frame.maxY

        let done = directory.appendingPathComponent("done").path
        let deadline = Date().addingTimeInterval(120)
        let tracking = ReadmeMenuTracking(menu: menu)
        let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let menu = tracking.menu else { return }
                // The menu fills in as it opens; name the app's version rather than the test runner's.
                if let version, let about = menu.items.first(where: { $0.title.hasPrefix(L("About CodexBar")) }) {
                    about.title = L("About CodexBar") + " (v\(version))"
                }
                let window = menu.items.compactMap { $0.view?.window }.first
                if window != nil, tracking.opened == nil { tracking.opened = Date() }
                // Give the card a moment to lay out before announcing where to capture.
                if let window, let opened = tracking.opened, Date().timeIntervalSince(opened) > 1.5 {
                    let frame = window.frame.insetBy(dx: -32, dy: -32)
                    let region = [frame.minX, screenTop - frame.maxY, frame.width, frame.height]
                        .map { String(Int($0.rounded())) }.joined(separator: ",")
                    try? region.write(
                        to: directory.appendingPathComponent("region.txt"), atomically: true, encoding: .utf8)
                }
                if FileManager.default.fileExists(atPath: done) || Date() >= deadline { menu.cancelTracking() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        defer { timer.invalidate() }
        menu.popUp(positioning: nil, at: NSPoint(x: 48, y: size.height - 64), in: host.contentView)
        XCTAssertTrue(FileManager.default.fileExists(atPath: done), "The README capture timed out")
    }

    /// The accounts scene's logins: Claude Max 20x in use, Max 5x and Team idle, with the same plans and readings.
    private static func seed(_ fixture: CodexWorkspacesNavigationFixture) {
        let settings = fixture.settings
        for (provider, enabled) in [(UsageProvider.claude, true), (.codex, false)] {
            settings.setProviderEnabled(
                provider: provider,
                metadata: ProviderDescriptorRegistry.descriptor(for: provider).metadata,
                enabled: enabled)
        }
        settings.selectedMenuProvider = .claude
        settings.statusChecksEnabled = true
        settings.costUsageEnabled = true
        let logins = [
            ReadmeLogin(label: "maya@northwind.dev", plan: "Max 20x", session: 31, weekly: 52, extra: 14),
            ReadmeLogin(label: "maya.okafor@icloud.com", plan: "Max 5x", session: 0, weekly: 24, extra: nil),
            ReadmeLogin(label: "maya@studio-ops.dev", plan: "Team", session: 0, weekly: 12, extra: nil),
        ]
        for (index, login) in logins.enumerated() {
            settings.addTokenAccount(provider: .claude, label: login.label, token: "fixture-oauth-\(index)")
        }
        settings.setActiveTokenAccountIndex(0, for: .claude)
        let now = Date()
        let snapshots = zip(settings.tokenAccounts(for: .claude), logins).map { account, login in
            let snapshot = UsageSnapshot(
                primary: RateWindow(
                    usedPercent: login.session,
                    windowMinutes: 300,
                    resetsAt: now.addingTimeInterval(4.1 * 3600),
                    resetDescription: nil),
                secondary: RateWindow(
                    usedPercent: login.weekly,
                    windowMinutes: 10080,
                    resetsAt: now.addingTimeInterval(5.7 * 86400),
                    resetDescription: nil),
                providerCost: login.extra.map {
                    ProviderCostSnapshot(used: $0, limit: 50, currencyCode: "USD", period: "Monthly", updatedAt: now)
                },
                updatedAt: now,
                identity: ProviderIdentitySnapshot(
                    providerID: .claude, accountEmail: login.label, accountOrganization: nil, loginMethod: login.plan))
            return TokenAccountUsageSnapshot(
                account: account,
                snapshot: snapshot,
                error: nil,
                sourceLabel: "oauth",
                cacheKey: fixture.store.tokenAccountSnapshotCacheKey(provider: .claude, account: account))
        }
        fixture.store.accountSnapshots[.claude] = snapshots
        fixture.store._setSnapshotForTesting(snapshots.first?.snapshot, provider: .claude)
        fixture.store._setTokenSnapshotForTesting(
            CostUsageTokenSnapshot(
                sessionTokens: 1_900_000_000,
                sessionCostUSD: 974.91,
                last30DaysTokens: 38_400_000_000,
                last30DaysCostUSD: 19820.40,
                daily: [],
                updatedAt: now),
            provider: .claude)
        fixture.store.statusComponents[.claude] = [
            ProviderStatusComponent(id: "claude", name: "Claude.ai", indicator: .none, status: "operational"),
        ]
    }
}

@MainActor
private final class ReadmeMenuTracking {
    weak var menu: NSMenu?
    var opened: Date?

    init(menu: NSMenu) {
        self.menu = menu
    }
}

private struct ReadmeLogin {
    let label: String
    let plan: String
    let session: Double
    let weekly: Double
    let extra: Double?
}
