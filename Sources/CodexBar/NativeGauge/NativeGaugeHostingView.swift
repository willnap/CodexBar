import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class NativeGaugeRenderState {
    var state = ComputeGauge.State()
    var width: CGFloat = 0
    var height: CGFloat = 0
    var density: CGFloat = 2
    var renderedAt: Date = .now
    private var accountID: String?
    private var hasState = false

    func update(state: ComputeGauge.State, accountID: String?, at now: Date = .now) {
        let newOwner = !self.hasState || self.accountID != accountID || self.state.provider != state.provider
        let recovered = self.state.health != .live && state.health == .live
        var next = state
        next.paceEventAt = newOwner || self.state.pace != state.pace || recovered ? now : self.state.paceEventAt
        next.healthEventAt = newOwner || self.state.health != state.health ? now : self.state.healthEventAt
        self.accountID = accountID
        self.hasState = true
        if next != self.state {
            self.renderedAt = now
            self.state = next
        }
    }
}

private struct NativeGaugeLiveView: View {
    let model: NativeGaugeRenderState

    var body: some View {
        // Keep glyph identity stable when reset metadata appears or disappears. Symbol effects remain finite.
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            self.gauge(at: max(timeline.date, self.model.renderedAt))
        }
    }

    private func gauge(at date: Date) -> some View {
        ComputeGauge(state: self.model.state, size: 20, now: date)
            .environment(\.computeGaugeLayout, .laurel)
            .environment(\.displayScale, self.model.density)
            .foregroundStyle(Color(nsColor: .labelColor))
            .frame(width: self.model.width, height: self.model.height)
    }
}

@MainActor
final class NativeGaugeHostingView: NSHostingView<AnyView> {
    private let model = NativeGaugeRenderState()
    private var hasInstalledRoot = false

    override func hitTest(_: NSPoint) -> NSView? { nil }

    func update(state: ComputeGauge.State, accountID: String? = nil, button: NSStatusBarButton, item: NSStatusItem) {
        item.length = self.update(state: state, accountID: accountID, button: button, x: 1) + 2
    }

    /// Places the gauge `x` points into the button and returns its width. The combined item places several.
    @discardableResult
    func update(state: ComputeGauge.State, accountID: String?, button: NSStatusBarButton, x: CGFloat) -> CGFloat {
        let size: CGFloat = 20
        let width = LaurelGauge.layoutWidth(for: size, windowCount: state.resolvedWindows.count)
        let height = LaurelGauge.layoutHeight(for: size, windowCount: state.resolvedWindows.count)
        let density = button.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        self.sizingOptions = []
        self.model.width = width
        self.model.height = height
        self.model.density = density
        self.model.update(state: state, accountID: accountID)
        if !self.hasInstalledRoot {
            self.rootView = AnyView(NativeGaugeLiveView(model: self.model))
            self.hasInstalledRoot = true
        }
        self.autoresizingMask = [.minYMargin, .maxYMargin]
        self.frame = NSRect(
            x: x,
            y: ((button.bounds.height - height) / 2 * density).rounded() / density,
            width: width,
            height: height)
        return width
    }
}
