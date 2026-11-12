import AppKit
import CodexBarCore

/// A popup opened from the menu bar has to belong to the active app with a key window: only then does it get
/// trackpad gestures (a pinch on a chart) and set its own cursors. The cooperative `NSApp.activate()` is a
/// request the frontmost app can decline; the popup then opened inert, with whatever cursor the app beneath had
/// last set, until a click inside it made the app active.
@MainActor
enum NativePopupActivation {
    /// Before showing: take activation outright, as a click on the app's own menu bar item warrants.
    static func activate() {
        NSApp.activate(ignoringOtherApps: true)
    }

    /// After showing: make the popup's window key, and ask once more if the app is still not active.
    static func confirm(_ window: NSWindow?) {
        window?.makeKey()
        Task { @MainActor [weak window] in
            await Task.yield()
            if !NSApp.isActive {
                NSRunningApplication.current.activate(options: [.activateAllWindows])
                window?.makeKey()
            }
            CodexBarLog.logger("native-gauges").info(
                "Popup activation",
                metadata: ["active": String(NSApp.isActive), "key": String(window?.isKeyWindow == true)])
        }
    }

    /// The pointer came over a popup that is still inert: claim activation then, before the first gesture.
    static func pointerEntered(_ window: NSWindow?) {
        guard !NSApp.isActive || window?.isKeyWindow != true else { return }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKey()
    }
}
