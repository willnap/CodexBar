import AppKit
import CodexBarCore

/// Preferences belong to the explicit AppKit controller. Reject SwiftUI's empty Settings placeholder and
/// AppKit Settings shells restored from older versions without the live controller's hosted preferences.
enum PlaceholderSettingsWindowDecision {
    /// SwiftUI names the window of a `Settings` scene with this fragment (identifier and frame autosave name).
    static let swiftUISettingsNameFragment = "com_apple_SwiftUI_Settings"

    /// An unowned Settings window that must not appear during launch or session restoration.
    static func shouldClose(identifier: String?, frameAutosaveName: String, isKnownSettingsWindow: Bool) -> Bool {
        guard !isKnownSettingsWindow else { return false }
        // A saved AppKit Settings shell is not the live controller's window and has no configured content.
        if identifier == SettingsWindowIdentity.identifier { return true }
        if let identifier, identifier.contains(self.swiftUISettingsNameFragment) { return true }
        return frameAutosaveName.contains(self.swiftUISettingsNameFragment)
    }
}

/// Dismisses unowned Settings windows so the explicit AppKit controller remains the only preferences surface.
@MainActor
final class PlaceholderSettingsWindowGuard {
    typealias WindowsProvider = @MainActor () -> [NSWindow]
    typealias WindowPredicate = @MainActor (NSWindow) -> Bool
    typealias WindowAction = @MainActor (NSWindow) -> Void

    private let windows: WindowsProvider
    private let isKnownSettingsWindow: WindowPredicate
    private let isVisible: WindowPredicate
    private let closeWindow: WindowAction
    private let logger = CodexBarLog.logger(LogCategories.app)
    private let closedWindows = NSHashTable<NSWindow>(options: [.weakMemory, .objectPointerPersonality])
    private var closingWindows: Set<ObjectIdentifier> = []
    private var isStarted = false

    init(
        windows: @escaping WindowsProvider = { NSApp?.windows ?? [] },
        isKnownSettingsWindow: @escaping WindowPredicate = { _ in false },
        isVisible: @escaping WindowPredicate = { $0.isVisible },
        closeWindow: @escaping WindowAction = { $0.close() })
    {
        self.windows = windows
        self.isKnownSettingsWindow = isKnownSettingsWindow
        self.isVisible = isVisible
        self.closeWindow = closeWindow
    }

    /// Sweeps once and keeps sweeping as window state changes; SwiftUI presents the placeholder after
    /// `applicationWillFinishLaunching`, and window restoration can bring it back later.
    func start() {
        guard !self.isStarted else { return }
        self.isStarted = true
        let center = NotificationCenter.default
        for name in [
            NSApplication.didFinishLaunchingNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.didUpdateNotification,
        ] {
            center.addObserver(
                self,
                selector: #selector(self.windowStateDidChange(_:)),
                name: name,
                object: nil)
        }
        self.sweep()
    }

    @discardableResult
    func sweep() -> Int {
        var closedCount = 0
        for window in self.windows() {
            guard PlaceholderSettingsWindowDecision.shouldClose(
                identifier: window.identifier?.rawValue,
                frameAutosaveName: window.frameAutosaveName,
                isKnownSettingsWindow: self.isKnownSettingsWindow(window))
            else { continue }
            guard self.isVisible(window) || !self.closedWindows.contains(window) else { continue }
            let identity = ObjectIdentifier(window)
            guard self.closingWindows.insert(identity).inserted else { continue }
            defer { self.closingWindows.remove(identity) }
            // Record before closing: close can synchronously trigger another window notification.
            self.closedWindows.add(window)
            window.isRestorable = false
            self.closeWindow(window)
            closedCount += 1
        }
        if closedCount > 0 {
            self.logger.info(
                "Closed unowned Settings window",
                metadata: ["count": "\(closedCount)"])
        }
        return closedCount
    }

    @objc private func windowStateDidChange(_: Notification) {
        // AppKit posts notifications inside makeKeyAndOrderFront; finish ordering before closing.
        DispatchQueue.main.async { [weak self] in
            self?.sweep()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
