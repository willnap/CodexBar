import AppKit

struct NativePageControlPage: Identifiable, Equatable {
    let id: String
    let label: String
}

struct NativePageControlPointer {
    enum Phase { case down, dragged, up }
    let phase: Phase
    let position: CGPoint
}

/// One AppKit input/accessibility element over the SwiftUI artwork. This supplies real mouse capture, wheel
/// phases, first-click handling, keyboard focus, and adjustable VoiceOver actions without a row of buttons.
@MainActor
final class NativePageControlInputControl: NSControl {
    var pages: [NativePageControlPage] = [] {
        didSet {
            self.currentIndex = min(self.currentIndex, max(0, self.pages.count - 1))
            self.synchronizeAccessibility()
        }
    }

    var currentIndex = 0 {
        didSet { self.synchronizeAccessibility() }
    }

    var reversed = false
    var vertical = false
    var controlFrame = CGRect.zero {
        didSet {
            self.noteFocusRingMaskChanged()
            self.updateTrackingAreas()
        }
    }

    var onPointer: (NativePageControlPointer) -> Void = { _ in }
    var onSelect: (Int) -> Void = { _ in }
    var onHover: (Bool) -> Void = { _ in }
    var onCancel: () -> Void = {}
    private(set) var interaction = NativePageControlInteraction.none
    private var trackingPointer = false
    private var hoverArea: NSTrackingArea?
    private var wheel = NativePageControlWheel()

    override init(frame: NSRect) {
        super.init(frame: frame)
        self.focusRingType = .none
        self.setAccessibilityElement(true)
        self.setAccessibilityRole(.slider)
        self.synchronizeAccessibility()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override var isFlipped: Bool {
        true
    }

    override var acceptsFirstResponder: Bool {
        self.isEnabled && !self.pages.isEmpty
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }
    override var focusRingMaskBounds: NSRect {
        self.controlFrame
    }

    override func drawFocusRingMask() {
        self.capsule.fill()
    }

    private var capsule: NSBezierPath {
        NSBezierPath(
            roundedRect: self.controlFrame,
            xRadius: min(self.controlFrame.width, self.controlFrame.height) / 2,
            yRadius: min(self.controlFrame.width, self.controlFrame.height) / 2)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard self.isEnabled, !self.isHidden, !self.pages.isEmpty,
              self.capsule.contains(self.convert(point, from: self.superview)) else { return nil }
        return self
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { self.removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: self.controlFrame,
            options: [.mouseEnteredAndExited, .activeInActiveApp],
            owner: self)
        self.addTrackingArea(area)
        self.hoverArea = area
    }

    override func mouseEntered(with _: NSEvent) { self.onHover(true) }
    override func mouseExited(with _: NSEvent) { self.onHover(false) }

    override func mouseDown(with event: NSEvent) {
        let position = self.convert(event.locationInWindow, from: nil)
        guard self.isEnabled, !self.pages.isEmpty, self.capsule.contains(position) else { return }
        self.window?.makeFirstResponder(self)
        self.trackingPointer = true
        self.onPointer(.init(phase: .down, position: position))
    }

    override func mouseDragged(with event: NSEvent) {
        guard self.trackingPointer, self.isEnabled else { return }
        self.onPointer(.init(phase: .dragged, position: self.convert(event.locationInWindow, from: nil)))
    }

    override func mouseUp(with event: NSEvent) {
        guard self.trackingPointer else { return }
        self.trackingPointer = false
        guard self.isEnabled else { self.onCancel(); return }
        self.onPointer(.init(phase: .up, position: self.convert(event.locationInWindow, from: nil)))
    }

    override func cancelOperation(_ sender: Any?) {
        if self.trackingPointer {
            self.trackingPointer = false
            self.onCancel()
        } else {
            super.cancelOperation(sender)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard self.acceptsFirstResponder else { return }
        if event.phase.contains(.began) { self.wheel.reset() }
        let delta = self.vertical ? event.scrollingDeltaY
            : abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        let step = self.wheel.consume(delta: delta, precise: event.hasPreciseScrollingDeltas)
        if step != 0 { self.move(self.reversed ? -step : step, interaction: .continuous) }
        if event.phase.contains(.cancelled) || event.momentumPhase.contains(.ended) { self.wheel.reset() }
    }

    override func keyDown(with event: NSEvent) {
        guard self.acceptsFirstResponder else { return }
        switch event.keyCode {
        case 115: self.select(0)
        case 119: self.select(self.pages.count - 1)
        case 116: self.move(-1)
        case 121: self.move(1)
        case 123, 124, 125, 126:
            let forward = event.keyCode == 124 || event.keyCode == 125
            let delta = (forward ? 1 : -1) * (self.reversed ? -1 : 1)
            if event.modifierFlags.contains(.command) {
                self.select(delta > 0 ? self.pages.count - 1 : 0)
            } else {
                self.move(delta * (event.modifierFlags.contains(.option) ? 10 : 1))
            }
        case 53: self.cancelOperation(nil)
        default: super.keyDown(with: event)
        }
    }

    override func accessibilityPerformIncrement() -> Bool { self.move(1) }
    override func accessibilityPerformDecrement() -> Bool { self.move(-1) }

    @discardableResult
    private func move(_ delta: Int, interaction: NativePageControlInteraction = .discrete) -> Bool {
        self.select(self.currentIndex + delta, interaction: interaction)
    }

    @discardableResult
    private func select(_ index: Int, interaction: NativePageControlInteraction = .discrete) -> Bool {
        guard self.acceptsFirstResponder else { return false }
        let next = min(self.pages.count - 1, max(0, index))
        guard next != self.currentIndex else { return false }
        self.interaction = interaction
        self.currentIndex = next
        self.onSelect(next)
        return true
    }

    private func synchronizeAccessibility() {
        let index = min(max(0, self.currentIndex), max(0, self.pages.count - 1))
        self.setAccessibilityMinValue(self.pages.isEmpty ? 0 : 1)
        self.setAccessibilityMaxValue(self.pages.count)
        self.setAccessibilityValue(self.pages.isEmpty ? 0 : index + 1)
        let label = self.pages.indices.contains(index) ? self.pages[index].label : ""
        self.setAccessibilityValueDescription("\(label), \(self.pages.isEmpty ? 0 : index + 1) / \(self.pages.count)")
    }
}
