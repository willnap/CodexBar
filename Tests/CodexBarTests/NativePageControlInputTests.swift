import AppKit
import Testing
@testable import CodexBar

@MainActor
struct NativePageControlInputTests {
    @Test func `accessibility increments use one stable control and handle repeated actions immediately`() {
        let control = self.control()
        var selected: [Int] = []
        control.onSelect = { selected.append($0) }
        #expect(control.accessibilityPerformIncrement())
        #expect(control.accessibilityPerformIncrement())
        #expect(selected == [2, 3])
        #expect(control.currentIndex == 3)
        #expect(control.accessibilityValueDescription()?.contains("Account 3") == true)
        #expect(control.accessibilityPerformDecrement())
        #expect(control.currentIndex == 2)
    }

    @Test func `keyboard follows physical direction and supports first and last page`() throws {
        let control = self.control()
        control.reversed = true
        try control.keyDown(with: self.key(123))
        #expect(control.currentIndex == 2)
        try control.keyDown(with: self.key(124))
        #expect(control.currentIndex == 1)
        try control.keyDown(with: self.key(119))
        #expect(control.currentIndex == 4)
        #expect(!control.accessibilityPerformIncrement())
        try control.keyDown(with: self.key(115))
        #expect(control.currentIndex == 0)
        #expect(!control.accessibilityPerformDecrement())
    }

    @Test func `mouse tracking retains drag and release beyond the capsule`() throws {
        let control = self.control()
        var phases: [NativePageControlPointer.Phase] = []
        control.onPointer = { phases.append($0.phase) }
        try control.mouseDown(with: self.mouse(.leftMouseDown, x: 100))
        try control.mouseDragged(with: self.mouse(.leftMouseDragged, x: 300))
        try control.mouseUp(with: self.mouse(.leftMouseUp, x: 300))
        try control.mouseDragged(with: self.mouse(.leftMouseDragged, x: 310))
        #expect(phases == [.down, .dragged, .up])
        #expect(control.acceptsFirstMouse(for: nil))
    }

    @Test func `disabled controls ignore clicks keyboard and accessibility`() throws {
        let control = self.control()
        control.isEnabled = false
        var events = 0
        control.onPointer = { _ in events += 1 }
        control.onSelect = { _ in events += 1 }
        try control.mouseDown(with: self.mouse(.leftMouseDown, x: 100))
        try control.keyDown(with: self.key(124))
        #expect(!control.accessibilityPerformIncrement())
        #expect(events == 0)
        #expect(!control.acceptsFirstResponder)
    }

    @Test func `shrinking or removing pages clamps accessibility and selection`() {
        let control = self.control()
        control.currentIndex = 4
        control.pages = Array(control.pages.prefix(2))
        #expect(control.currentIndex == 1)
        control.pages = []
        #expect(control.currentIndex == 0)
        #expect(!control.acceptsFirstResponder)
        #expect(!control.accessibilityPerformIncrement())
    }

    private func control() -> NativePageControlInputControl {
        let control = NativePageControlInputControl(frame: NSRect(x: 0, y: 0, width: 240, height: 36))
        control.controlFrame = NSRect(x: 70, y: 3, width: 100, height: 30)
        control.pages = (0..<5).map { .init(id: String($0), label: "Account \($0)") }
        control.currentIndex = 1
        return control
    }

    private func key(_ code: UInt16) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: code))
    }

    private func mouse(_ type: NSEvent.EventType, x: CGFloat) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type,
            location: NSPoint(x: x, y: 18),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1))
    }
}
