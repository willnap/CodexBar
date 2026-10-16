import AppKit
import SwiftUI

/// Native controls own both tooltips and clicks; the separate HDR layer only draws the lamps.
struct NativeOrbitWarningHitView: NSViewRepresentable {
    let lights: [NativeOrbitWarningLight]
    let positions: [NativeOrbitWarningLight.Kind: CGPoint]
    let account: String?
    var allowsActions = true
    let activate: (NativeOrbitWarningLight) -> Void

    func makeNSView(context: Context) -> NativeOrbitWarningHitSurface {
        NativeOrbitWarningHitSurface(frame: NSRect(x: 0, y: 0, width: 216, height: 216))
    }

    func updateNSView(_ nsView: NativeOrbitWarningHitSurface, context: Context) {
        nsView.update(
            lights: self.lights,
            positions: self.positions,
            account: self.account,
            allowsActions: self.allowsActions,
            activate: self.activate)
    }

    static func dismantleNSView(_ nsView: NativeOrbitWarningHitSurface, coordinator: ()) {
        nsView.invalidate()
    }
}

@MainActor
final class NativeOrbitWarningHitSurface: NSView, NSViewToolTipOwner {
    private var lights: [NativeOrbitWarningLight.Kind: NativeOrbitWarningLight] = [:]
    private(set) var buttons: [NativeOrbitWarningLight.Kind: NSButton] = [:]
    private var activate: (NativeOrbitWarningLight) -> Void = { _ in }
    private var account: String?
    private var allowsActions = true

    override var isFlipped: Bool {
        true
    }

    func update(
        lights: [NativeOrbitWarningLight],
        positions: [NativeOrbitWarningLight.Kind: CGPoint],
        account: String?,
        allowsActions: Bool = true,
        activate: @escaping (NativeOrbitWarningLight) -> Void)
    {
        self.activate = activate
        self.account = account
        self.allowsActions = allowsActions
        self.removeAllToolTips()
        self.lights = Dictionary(uniqueKeysWithValues: NativeOrbitWarningLight.merged(lights).map { ($0.kind, $0) })
        for kind in Array(self.buttons.keys) where self.lights[kind] == nil || positions[kind] == nil {
            self.buttons.removeValue(forKey: kind)?.removeFromSuperview()
        }
        for light in self.lights.values.sorted(by: { $0.kind < $1.kind }) {
            guard let position = positions[light.kind] else { continue }
            let button: NSButton
            if let existing = self.buttons[light.kind] {
                button = existing
            } else {
                button = NSButton(title: "", target: self, action: #selector(self.press(_:)))
                button.isBordered = false
                button.isTransparent = true
                button.focusRingType = .none
                button.tag = light.kind.rawValue
                button.identifier = .init("warning.\(light.kind.catalogueKey)")
                button.setAccessibilityElement(true)
                button.setAccessibilityRole(.button)
                self.buttons[light.kind] = button
                self.addSubview(button)
            }
            button.isEnabled = allowsActions
            button.frame = NativeOrbitWarningLayout.inkBounds(light.kind)
                .offsetBy(dx: 108 + position.x, dy: 108 + position.y).insetBy(dx: -1.5, dy: -1.5)
            let tooltip = light.tooltip(account: account, includesAction: allowsActions)
            button.setAccessibilityLabel(light.kind.name)
            button.setAccessibilityValue(light.explanation)
            button.setAccessibilityHelp(tooltip)
            self.addToolTip(button.frame, owner: self, userData: nil)
        }
    }

    func invalidate() {
        self.update(lights: [], positions: [:], account: nil, activate: { _ in })
    }

    /// Every overlapping native tooltip region resolves through the same nearest-light rule as a click.
    func tooltip(at point: CGPoint) -> String? {
        guard let button = self.button(at: point),
              let kind = NativeOrbitWarningLight.Kind(rawValue: button.tag), let light = self.lights[kind]
        else { return nil }
        return light.tooltip(account: self.account, includesAction: self.allowsActions)
    }

    func view(
        _ view: NSView,
        stringForToolTip tag: NSView.ToolTipTag,
        point: NSPoint,
        userData: UnsafeMutableRawPointer?) -> String
    {
        self.tooltip(at: point) ?? ""
    }

    /// A crowded lamp's rectangular padding must not mask a neighbour's centre.
    func button(at point: CGPoint) -> NSButton? {
        self.buttons.values.filter { $0.frame.contains(point) }.min { lhs, rhs in
            let left = pow(lhs.frame.midX - point.x, 2) + pow(lhs.frame.midY - point.y, 2)
            let right = pow(rhs.frame.midX - point.x, 2) + pow(rhs.frame.midY - point.y, 2)
            return left == right ? lhs.tag < rhs.tag : left < right
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = self.superview.map { self.convert(point, from: $0) } ?? point
        return self.bounds.contains(local) ? self.button(at: local) : nil
    }

    @objc private func press(_ sender: NSButton) {
        guard self.allowsActions, let kind = NativeOrbitWarningLight.Kind(rawValue: sender.tag),
              self.buttons[kind] === sender,
              let light = self.lights[kind] else { return }
        self.activate(light)
    }
}
