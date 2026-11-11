import AppKit

/// When the person last moved the pointer, scrolled, dragged or clicked in one of the app's windows.
///
/// A refresh publishes many changes over half a minute, and applying one rebuilds every dial and chart of the open
/// popup. Doing that under a moving pointer is what made scrolling and panning stutter, so a popup lets a change
/// wait until the hand has been still for a moment.
@MainActor
enum NativePopupInteraction {
    /// How long after the last event the person still counts as interacting.
    static let quietPeriod: TimeInterval = 0.6

    private static var monitor: Any?
    private(set) static var lastEventAt: Date = .distantPast

    static var isActive: Bool {
        Date().timeIntervalSince(self.lastEventAt) < self.quietPeriod
    }

    /// Starts watching the app's own events. They are observed, never changed or consumed.
    static func startMonitoring() {
        guard self.monitor == nil else { return }
        self.monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .scrollWheel, .leftMouseDragged, .leftMouseDown, .leftMouseUp, .magnify])
        { event in
            MainActor.assumeIsolated { self.lastEventAt = Date() }
            return event
        }
    }

    #if DEBUG
    static func noteEventForTesting(at date: Date) {
        self.lastEventAt = date
    }
    #endif
}
