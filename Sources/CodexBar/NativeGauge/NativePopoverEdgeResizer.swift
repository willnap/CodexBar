import AppKit
import CodexBarCore

/// Popovers have no resize border, so this adds one at the left and right edges: the system's frame-resize cursor,
/// showing which ways the width can still go, and a drag that keeps the dragged edge under the pointer while the
/// popover stays anchored to its button.
@MainActor
final class NativePopoverEdgeResizer: NSView {
    enum Edge {
        case left, right
    }

    /// How far in from each side the edge can be grabbed.
    static let grip: CGFloat = 5

    var width: () -> CGFloat = { 0 }
    var limits: () -> ClosedRange<CGFloat> = { 0...10000 }
    /// Applies a proposed width and returns the width taken.
    var resize: (CGFloat) -> CGFloat = { $0 }
    var began: () -> Void = {}
    var ended: (CGFloat) -> Void = { _ in }

    private struct Drag {
        let edge: Edge
        let startPointer: CGFloat
        let startEdge: CGFloat
        let startWidth: CGFloat
        /// How far the dragged edge moves per point of width: half while the popover grows evenly about its
        /// button, all of it once the screen edge holds the other side.
        var response: CGFloat = 0.5
        var events = 0

        var sign: CGFloat {
            self.edge == .right ? 1 : -1
        }
    }

    private var drag: Drag?
    private var gripAreas: [NSTrackingArea] = []

    override var isFlipped: Bool {
        true
    }

    func host(_ content: NSView) {
        content.frame = self.bounds
        content.autoresizingMask = [.width, .height]
        self.addSubview(content)
    }

    private func gripRect(_ edge: Edge) -> NSRect {
        edge == .left
            ? NSRect(x: 0, y: 0, width: Self.grip, height: self.bounds.height)
            : NSRect(x: self.bounds.maxX - Self.grip, y: 0, width: Self.grip, height: self.bounds.height)
    }

    private func edge(at point: NSPoint) -> Edge? {
        if self.gripRect(.left).contains(point) { return .left }
        if self.gripRect(.right).contains(point) { return .right }
        return nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !self.isHidden, let superview else { return super.hitTest(point) }
        return self.edge(at: self.convert(point, from: superview)) == nil ? super.hitTest(point) : self
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in self.gripAreas {
            self.removeTrackingArea(area)
        }
        self.gripAreas = [Edge.left, .right].map { edge in
            NSTrackingArea(
                rect: self.gripRect(edge),
                options: [.cursorUpdate, .activeAlways],
                owner: self,
                userInfo: nil)
        }
        for area in self.gripAreas {
            self.addTrackingArea(area)
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        let point = self.convert(event.locationInWindow, from: nil)
        guard let edge = self.drag?.edge ?? self.edge(at: point) else { return super.cursorUpdate(with: event) }
        self.resizeCursor(edge).set()
    }

    /// The system cursor for this edge, its arrows limited to the ways the width can still change.
    private func resizeCursor(_ edge: Edge) -> NSCursor {
        let width = self.width()
        let limits = self.limits()
        var directions: NSCursor.FrameResizeDirection.Set = []
        if width < limits.upperBound - 0.5 { directions.insert(.outward) }
        if width > limits.lowerBound + 0.5 { directions.insert(.inward) }
        guard !directions.isEmpty else { return .arrow }
        return NSCursor.frameResize(position: edge == .left ? .left : .right, directions: directions)
    }

    /// The event's own screen position: the popover moves under the pointer while it resizes.
    private static func pointer(_ event: NSEvent) -> CGFloat {
        event.cgEvent?.location.x ?? NSEvent.mouseLocation.x
    }

    private func screenEdge(_ edge: Edge) -> CGFloat? {
        guard let window else { return nil }
        let point = NSPoint(x: edge == .left ? self.bounds.minX : self.bounds.maxX, y: 0)
        return window.convertPoint(toScreen: self.convert(point, to: nil)).x
    }

    override func mouseDown(with event: NSEvent) {
        let point = self.convert(event.locationInWindow, from: nil)
        guard let edge = self.edge(at: point), let start = self.screenEdge(edge) else {
            return super.mouseDown(with: event)
        }
        self.drag = Drag(
            edge: edge,
            startPointer: Self.pointer(event),
            startEdge: start,
            startWidth: self.width())
        self.began()
        self.resizeCursor(edge).set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard var drag = self.drag else { return super.mouseDragged(with: event) }
        // Each width follows from the whole drag so far, so the pointer always bounds it.
        let pull = (Self.pointer(event) - drag.startPointer) * drag.sign
        drag.events += 1
        let width = self.resize(drag.startWidth + pull / drag.response)
        let grew = width - drag.startWidth
        if abs(grew) >= 4, let edge = self.screenEdge(drag.edge) {
            let moved = (edge - drag.startEdge) * drag.sign
            let response = moved / grew
            if response.isFinite, response >= 0.2, response <= 1.05 { drag.response = min(1, response) }
        }
        self.drag = drag
        self.resizeCursor(drag.edge).set()
    }

    override func mouseUp(with event: NSEvent) {
        guard let drag = self.drag else { return super.mouseUp(with: event) }
        self.drag = nil
        let width = self.width()
        self.ended(width)
        CodexBarLog.logger("native-gauges").info(
            "Popup edge drag",
            metadata: [
                "events": String(drag.events),
                "pull": String(format: "%.1f", (Self.pointer(event) - drag.startPointer) * drag.sign),
                "startWidth": String(format: "%.1f", drag.startWidth),
                "width": String(format: "%.1f", width),
                "response": String(format: "%.2f", drag.response),
                "edgeMoved": String(format: "%.1f", ((self.screenEdge(drag.edge) ?? 0) - drag.startEdge) * drag.sign),
            ])
        let point = self.convert(event.locationInWindow, from: nil)
        if self.edge(at: point) == drag.edge { self.resizeCursor(drag.edge).set() } else { NSCursor.arrow.set() }
    }
}
