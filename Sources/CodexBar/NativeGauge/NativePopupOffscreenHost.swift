import AppKit

/// Holds a popup's content in a window nobody can see until its popover has been shown once.
///
/// A SwiftUI hosting view that has never been in a window has not really been rendered: the first time
/// `NSPopover.show` puts it in the popover's window, every dial and chart is evaluated and rasterised before the
/// window can appear, which took a quarter of a second after the first click of a launch (and far longer on a busy
/// Mac). Rendering it here, on the screen and in the appearance the popover will use, leaves the popover nothing
/// to do but take the view. Once a popover has shown the view it keeps it in its own window, and this one goes.
@MainActor
final class NativePopupOffscreenHost {
    private var window: NSWindow?

    /// Lays `view` out, in this host's window when no popover has taken it yet.
    func render(_ view: NSView, size: NSSize, screen: NSScreen?, appearance: NSAppearance?) {
        // Tests lay the view out without any window of ours.
        if view.window == nil, !SettingsStore.isRunningTests {
            self.adopt(view, size: size, screen: screen, appearance: appearance)
        }
        if view.frame.size != size { view.setFrameSize(size) }
        guard let window, view.window === window else {
            view.layoutSubtreeIfNeeded()
            return
        }
        if window.frame.size != size { window.setContentSize(size) }
        if let appearance, window.appearance != appearance { window.appearance = appearance }
        // On screen for the length of this call, fully transparent: layers are only drawn for a window that is.
        window.orderBack(nil)
        window.layoutIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
        window.orderOut(nil)
    }

    /// Call once a popover has shown the view: the window it left is of no further use.
    func releaseIfVacated(by view: NSView) {
        guard let window, view.window !== window else { return }
        window.orderOut(nil)
        self.window = nil
    }

    private func adopt(_ view: NSView, size: NSSize, screen: NSScreen?, appearance: NSAppearance?) {
        let origin = (screen ?? NSScreen.main)?.visibleFrame.origin ?? .zero
        let window = NSWindow(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: .borderless,
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        window.sharingType = .none
        window.appearance = appearance
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        window.contentView = container
        view.frame = container.bounds
        container.addSubview(view)
        self.window = window
    }
}
