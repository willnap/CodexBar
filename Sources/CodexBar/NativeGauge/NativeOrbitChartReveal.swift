import AppKit
import QuartzCore
import SwiftUI

/// Reveal a retained native chart entirely in the compositor. Native view frames stay fixed throughout the sweep,
/// keeping clipping and translation out of NSHostingView's layout. Selection and data still update hosted content.
struct NativeOrbitChartReveal<Key: Equatable, Content: View>: NSViewRepresentable {
    @Environment(\.nativeOrbitPlotIsVisible) private var isVisible
    let phase: NativeOrbitStartupPhase
    let contentKey: Key
    @ViewBuilder let content: Content

    final class Coordinator {
        var key: Key?
        var wasVisible = true
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NativeOrbitChartRevealView {
        context.coordinator.key = self.contentKey
        return NativeOrbitChartRevealView(content: AnyView(self.content), phase: self.phase)
    }

    func updateNSView(_ view: NativeOrbitChartRevealView, context: Context) {
        // Stop at the outer hosting boundary: replacing even its axis wrapper schedules expensive Charts
        // layout for every warmed account. Keep the last key so entering the viewport applies the newest range.
        guard self.isVisible else {
            context.coordinator.wasVisible = false
            return
        }
        let wasVisible = context.coordinator.wasVisible
        context.coordinator.wasVisible = true
        if context.coordinator.key != self.contentKey {
            context.coordinator.key = self.contentKey
            var transaction = context.transaction
            if !wasVisible {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
            withTransaction(transaction) {
                view.presentation.content = AnyView(self.content)
            }
        }
        view.reveal(
            self.phase,
            animated: wasVisible && context.transaction.animation != nil
                && !context.transaction.disablesAnimations)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: NativeOrbitChartRevealView,
        context: Context) -> CGSize?
    {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 224, height: 224))
    }
}

final class NativeOrbitChartRevealView: NSView {
    @Observable final class Presentation {
        var content: AnyView

        init(content: AnyView) {
            self.content = content
        }
    }

    private struct RetainedChart: View {
        let presentation: Presentation

        var body: some View {
            self.presentation.content
        }
    }

    let presentation: Presentation
    let host: NSHostingView<AnyView>
    let clip = NativeOrbitChartClipView()
    let revealMask = CALayer()
    private(set) var phase: NativeOrbitStartupPhase
    private var layoutSize = CGSize(width: 224, height: 224)

    override var isFlipped: Bool {
        true
    }

    init(content: AnyView, phase: NativeOrbitStartupPhase) {
        let presentation = Presentation(content: content)
        self.presentation = presentation
        // Retain the outer hosting graph too: assigning rootView forces a fresh native layout traversal before
        // the inner chart can present its first animated frame, even when its dimensions stay unchanged.
        self.host = NSHostingView(rootView: AnyView(RetainedChart(presentation: presentation)))
        self.phase = phase
        super.init(frame: CGRect(x: 0, y: 0, width: 224, height: 224))
        self.wantsLayer = true
        self.clip.wantsLayer = true
        self.clip.clipsToBounds = true
        self.host.sizingOptions = []
        self.host.wantsLayer = true
        self.addSubview(self.clip)
        self.clip.addSubview(self.host)
        self.clip.frame = self.bounds
        self.host.frame = self.bounds
        self.revealMask.anchorPoint = .zero
        self.revealMask.position = .zero
        self.revealMask.backgroundColor = NSColor.black.cgColor
        self.clip.layer?.mask = self.revealMask
        self.apply(animated: false, previous: phase)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        guard self.layoutSize != self.bounds.size else { return }
        self.layoutSize = self.bounds.size
        self.clip.frame = self.bounds
        self.host.frame = CGRect(origin: .zero, size: self.bounds.size)
        self.apply(animated: false, previous: self.phase)
    }

    func reveal(_ phase: NativeOrbitStartupPhase, animated: Bool) {
        guard self.phase != phase else { return }
        let previous = self.phase
        self.phase = phase
        if previous.graphReveal == phase.graphReveal {
            // A real inspection can finish startup before its opening animation ends. Reveal the inspected chart
            // immediately; intermediate startup checkpoints leave the current compositor animation alone.
            if phase == .live { self.apply(animated: false, previous: previous) }
            return
        }
        self.apply(animated: animated && phase.graphReveal > 0, previous: previous)
    }

    private func apply(animated: Bool, previous: NativeOrbitStartupPhase) {
        guard let clipLayer = self.clip.layer, let hostLayer = self.host.layer else { return }
        let progress = self.phase.graphReveal
        let width = self.bounds.width * progress
        let translation = 3 * (1 - progress)
        let oldWidth = self.revealMask.presentation()?.bounds.width ?? self.revealMask.bounds.width
        let oldOpacity = clipLayer.presentation()?.opacity ?? clipLayer.opacity
        let oldTranslation = hostLayer.presentation()?.transform.m42 ?? hostLayer.transform.m42

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.revealMask.removeAnimation(forKey: "startupReveal")
        clipLayer.removeAnimation(forKey: "startupReveal")
        hostLayer.removeAnimation(forKey: "startupReveal")
        self.revealMask.bounds = CGRect(x: 0, y: 0, width: width, height: self.bounds.height)
        clipLayer.opacity = Float(progress)
        hostLayer.transform = CATransform3DMakeTranslation(0, translation, 0)
        if animated {
            self.animate(self.revealMask, keyPath: "bounds.size.width", from: oldWidth, to: width, previous: previous)
            self.animate(clipLayer, keyPath: "opacity", from: oldOpacity, to: Float(progress), previous: previous)
            self.animate(
                hostLayer,
                keyPath: "transform.translation.y",
                from: oldTranslation,
                to: translation,
                previous: previous)
        }
        CATransaction.commit()
    }

    private func animate(_ layer: CALayer, keyPath: String, from: Any, to: Any, previous: NativeOrbitStartupPhase) {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = previous == .reduced ? 0.15 : 0.64
        animation.timingFunction = previous == .reduced
            ? CAMediaTimingFunction(name: .easeOut)
            : CAMediaTimingFunction(controlPoints: 0.32, 0, 0.16, 1)
        let maximum = Float(max(
            1,
            self.window?.screen?.maximumFramesPerSecond
                ?? NSScreen.main?.maximumFramesPerSecond ?? 60))
        animation.preferredFrameRateRange = CAFrameRateRange(
            minimum: min(60, maximum), maximum: maximum, preferred: maximum)
        layer.add(animation, forKey: "startupReveal")
    }
}

final class NativeOrbitChartClipView: NSView {
    override var isFlipped: Bool {
        true
    }
}
