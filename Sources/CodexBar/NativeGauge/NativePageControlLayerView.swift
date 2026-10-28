import AppKit
import QuartzCore
import SwiftUI

/// Cached symbol masks and compositor animations keep page-control motion independent of SwiftUI layout.
/// Every retarget starts at the presentation layer, including a provider group collapsing mid-transition.
@MainActor
final class NativePageControlLayerView: NSView {
    private final class SymbolCanvas: NSView {
        override var isFlipped: Bool {
            true
        }
    }

    private struct SymbolLayer {
        let layer: CALayer
        let group: String?
        let image: NSImage
    }

    private struct Retirement {
        let mark: SymbolLayer
        let generation: UUID
    }

    private var retiring: [String: Retirement] = [:]
    private var tintAlpha: CGFloat = 0.45
    private var currentTintAlpha: CGFloat = 1
    private var animationsStarted = 0
    private let symbols = CALayer()
    /// A provider's expanded accounts sit with its mark on one platter, below the marks.
    private let platters = CALayer()
    private var platterLayers: [String: CALayer] = [:]
    private let background = NSVisualEffectView()
    private let canvas = SymbolCanvas()
    private var marks: [String: SymbolLayer] = [:]
    private var initialized = false
    private var lastArtwork: NativePageControlArtwork?
    private var lastReduceMotion = false
    private var lastCurrentTint: CGColor?
    private var lastIndicatorTint: CGColor?
    private var displayLink: CADisplayLink?
    private var lastDisplayTime: CFTimeInterval?
    private var previousWasVisible = false
    private var activeUntil: CFTimeInterval = 0
    private(set) var updateCount = 0

    override var isFlipped: Bool {
        true
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        self.wantsLayer = true
        self.layer?.masksToBounds = true
        self.background.material = .hudWindow
        // UIPageControl uses systemChromeMaterialDark for its platter, including in light appearance.
        self.background.appearance = NSAppearance(named: .darkAqua)
        self.background.blendingMode = .withinWindow
        self.background.state = .active
        self.background.wantsLayer = true
        self.background.layer?.cornerRadius = 15
        self.background.layer?.masksToBounds = true
        self.addSubview(self.background)
        self.canvas.wantsLayer = true
        self.addSubview(self.canvas)
        self.symbols.name = "CodexBar.PageControl.Symbols"
        self.platters.name = "CodexBar.PageControl.Platters"
        self.canvas.layer?.addSublayer(self.platters)
        self.canvas.layer?.addSublayer(self.symbols)
        self.setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        guard let artwork = self.lastArtwork else { return }
        self.update(artwork, reduceMotion: self.lastReduceMotion)
    }

    override func hitTest(_: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.canvas.frame = self.bounds
        self.symbols.frame = self.canvas.bounds
        self.platters.frame = self.canvas.bounds
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        self.displayLink?.invalidate()
        self.displayLink = nil
        guard self.window != nil, NativePageControlMotionTrace.enabled else { return }
        let link = self.displayLink(target: self, selector: #selector(self.sampleFrame(_:)))
        let rate = Float(self.window?.screen?.maximumFramesPerSecond ?? 60)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
        link.add(to: .main, forMode: .common)
        self.displayLink = link
    }

    @objc private func sampleFrame(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let visible = self.window?.isVisible == true && self.window?.occlusionState.contains(.visible) == true
            && !self.isHiddenOrHasHiddenAncestor && self.window?.screen != nil
        defer { self.lastDisplayTime = now; self.previousWasVisible = visible }
        guard now < self.activeUntil, let previous = self.lastDisplayTime else { return }
        guard visible, self.previousWasVisible else {
            NativePageControlMotionTrace.invalidForegroundSamples += 1
            return
        }
        NativePageControlMotionTrace.displayIntervals.append((now - previous) * 1000)
        NativePageControlMotionTrace.displayBudgets.append((link.targetTimestamp - link.timestamp) * 1000)
        for (id, mark) in self.marks {
            guard let shown = mark.layer.presentation() else { continue }
            NativePageControlMotionTrace.record(
                id: id,
                x: shown.position.x,
                selection: (CGFloat(shown.backgroundColor?.alpha ?? 0) - self.tintAlpha)
                    / max(0.001, self.currentTintAlpha - self.tintAlpha))
        }
    }

    func update(_ artwork: NativePageControlArtwork, reduceMotion: Bool) {
        self.lastArtwork = artwork
        self.lastReduceMotion = reduceMotion
        let indicators = artwork.indicators
        let layout = artwork.layout
        let configuration = artwork.configuration
        let controlFrame = artwork.controlFrame
        let expanded = artwork.expanded
        let enabled = artwork.enabled
        self.updateCount += 1
        let animate = self.initialized && !reduceMotion && self.window != nil
        let animationCount = self.animationsStarted
        if !animate {
            for retirement in self.retiring.values {
                retirement.mark.layer.removeAllAnimations()
                retirement.mark.layer.removeFromSuperlayer()
            }
            self.retiring.removeAll()
        }
        let old = self.marks
        let ids = Set(layout.marks.map { indicators[$0.index].id })
        let duration = 0.25
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.canvas.frame = self.bounds
        self.symbols.frame = self.canvas.bounds
        self.platters.frame = self.canvas.bounds
        self.symbols.opacity = enabled ? 1 : 0.45
        self.platters.opacity = enabled ? 1 : 0.45
        let showBackground = configuration.backgroundStyle == .prominent
            || (configuration.backgroundStyle == .automatic && expanded)
        let palette = configuration.resolvedTints(appearance: self.effectiveAppearance, showsBackground: showBackground)
        let tint = palette.indicator
        let selectedTint = palette.current
        // Changing ink polarity and its backing together avoids an unreadable gray-on-gray crossfade.
        let inkChanged = self.inkChanged(from: self.lastCurrentTint, to: selectedTint)
            || self.inkChanged(from: self.lastIndicatorTint, to: tint)
        self.lastCurrentTint = selectedTint
        self.lastIndicatorTint = tint
        let tintDuration = animate && !inkChanged ? duration : 0
        let backgroundLayer = self.background.layer!
        let previousPosition = backgroundLayer.presentation()?.position ?? backgroundLayer.position
        let previousBounds = backgroundLayer.presentation()?.bounds ?? backgroundLayer.bounds
        let backgroundMoved = self.background.frame != controlFrame
        self.background.frame = controlFrame
        if backgroundMoved || !animate {
            self.animate(
                backgroundLayer,
                key: "position",
                to: backgroundLayer.position,
                duration: animate ? duration : 0,
                from: previousPosition)
            self.animate(
                backgroundLayer,
                key: "bounds",
                to: backgroundLayer.bounds,
                duration: animate ? duration : 0,
                from: previousBounds)
        }
        self.animate(
            self.background.layer!,
            key: "opacity",
            to: showBackground ? Float(1) : Float(0),
            duration: tintDuration)
        self.tintAlpha = tint.alpha
        self.currentTintAlpha = selectedTint.alpha
        for geometry in layout.marks {
            let indicator = indicators[geometry.index]
            let symbol = NativePageControlSymbol(indicator, configuration: configuration)
            // Placed by its ink, so unevenly padded art lines up with the rest at any edge scale.
            let shift = symbol.inkOffset
            let position = CGPoint(
                x: (configuration.direction.isVertical ? 18 : geometry.position) - shift.width * geometry.scale,
                y: (configuration.direction.isVertical ? geometry.position : 18) - shift.height * geometry.scale)
            // Pages in the window light their marks, a page part in by as much of it as shows.
            let ink = Self.mix(tint, selectedTint, indicator.selected ? 1 : indicator.visibility)
            let mark: SymbolLayer
            let reusable = self.marks[indicator.id] ?? self.retiring[indicator.id]?.mark
            if let existing = reusable, existing.image === symbol.image {
                self.retiring.removeValue(forKey: indicator.id)
                self.marks[indicator.id] = existing
                mark = existing
            } else {
                let glyph = CALayer()
                glyph.name = indicator.id
                glyph.bounds = CGRect(origin: .zero, size: symbol.size)
                glyph.contentsScale = self.window?.backingScaleFactor ?? 2
                let mask = CALayer()
                mask.frame = glyph.bounds
                mask.contents = symbol.image.cgImage(forProposedRect: nil, context: nil, hints: nil)
                mask.contentsScale = glyph.contentsScale
                mask.contentsGravity = .resize
                glyph.mask = mask
                glyph.backgroundColor = ink
                // Accounts emerge from their provider logo, rather than popping into their final positions.
                let anchor = old[indicator.group ?? ""]?.layer
                glyph.position = anchor?.presentation()?.position ?? anchor?.position ?? position
                glyph.transform = CATransform3DMakeScale(0.001, 0.001, 1)
                glyph.opacity = 0
                self.symbols.addSublayer(glyph)
                mark = SymbolLayer(layer: glyph, group: indicator.group, image: symbol.image)
                if let replaced = self.marks[indicator.id] {
                    self.retire(replaced, id: UUID().uuidString, at: position, animate: animate)
                }
                self.marks[indicator.id] = mark
            }
            let scale = max(0.001, geometry.scale)
            self.animate(mark.layer, key: "position", to: position, duration: animate ? duration : 0)
            self.animate(
                mark.layer,
                key: "transform",
                to: CATransform3DMakeScale(scale, scale, 1),
                duration: animate ? duration : 0)
            self.animate(
                mark.layer,
                key: "opacity",
                to: geometry.scale > 0 ? Float(1) : Float(0),
                duration: animate ? duration : 0)
            self.animate(
                mark.layer,
                key: "backgroundColor",
                to: ink,
                duration: tintDuration)
        }
        for (id, mark) in old where !ids.contains(id) {
            let anchor = mark.group.flatMap { self.marks[$0]?.layer.position } ?? mark.layer.position
            self.retire(mark, id: id, at: anchor, animate: animate)
            self.marks.removeValue(forKey: id)
        }
        self.updatePlatters(
            layout.groups,
            vertical: configuration.direction.isVertical,
            tint: tint,
            tintDuration: tintDuration,
            animate: animate)
        CATransaction.commit()
        self.initialized = true
        if self.animationsStarted > animationCount { self.activeUntil = CACurrentMediaTime() + duration }
    }

    /// A platter grows out of its provider mark as the accounts emerge, and shrinks back into it as they collapse.
    private func updatePlatters(
        _ groups: [NativePageControlLayout.Group],
        vertical: Bool,
        tint: CGColor,
        tintDuration: Double,
        animate: Bool)
    {
        let thickness = NativePageControlLayout.platterThickness
        let fill = tint.copy(alpha: tint.alpha * 0.22) ?? tint
        let collapsed = CGRect(x: 0, y: 0, width: thickness, height: thickness)
        let duration = animate ? 0.25 : 0
        var live = Set<String>()
        for group in groups {
            live.insert(group.id)
            let span = group.upper - group.lower
            let center = (group.lower + group.upper) / 2
            let position = vertical ? CGPoint(x: 18, y: center) : CGPoint(x: center, y: 18)
            let bounds = vertical
                ? CGRect(x: 0, y: 0, width: thickness, height: span)
                : CGRect(x: 0, y: 0, width: span, height: thickness)
            let platter: CALayer
            if let existing = self.platterLayers[group.id] {
                platter = existing
            } else {
                platter = CALayer()
                platter.name = "platter:\(group.id)"
                platter.cornerRadius = thickness / 2
                platter.cornerCurve = .continuous
                platter.backgroundColor = fill
                let anchor = self.marks[group.id]?.layer
                platter.position = anchor?.presentation()?.position ?? anchor?.position ?? position
                platter.bounds = collapsed
                platter.opacity = 0
                self.platters.addSublayer(platter)
                self.platterLayers[group.id] = platter
            }
            self.animate(platter, key: "position", to: position, duration: duration)
            self.animate(platter, key: "bounds", to: bounds, duration: duration)
            self.animate(platter, key: "opacity", to: Float(1), duration: duration)
            self.animate(platter, key: "backgroundColor", to: fill, duration: tintDuration)
        }
        for (id, platter) in self.platterLayers where !live.contains(id) {
            self.platterLayers.removeValue(forKey: id)
            let anchor = self.marks[id]?.layer.position ?? platter.position
            self.animate(platter, key: "position", to: anchor, duration: duration)
            self.animate(platter, key: "bounds", to: collapsed, duration: duration)
            self.animate(platter, key: "opacity", to: Float(0), duration: duration)
            guard animate else { platter.removeFromSuperlayer(); continue }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(260))
                // Expanding again meanwhile makes a fresh platter; this one only finishes leaving.
                if self?.platterLayers[id] !== platter { platter.removeFromSuperlayer() }
            }
        }
    }

    private func retire(_ mark: SymbolLayer, id: String, at position: CGPoint, animate: Bool) {
        let layer = mark.layer
        self.animate(layer, key: "position", to: position, duration: animate ? 0.25 : 0)
        self.animate(
            layer,
            key: "transform",
            to: CATransform3DMakeScale(0.001, 0.001, 1),
            duration: animate ? 0.25 : 0)
        self.animate(layer, key: "opacity", to: Float(0), duration: animate ? 0.25 : 0)
        if animate {
            let generation = UUID()
            self.retiring[id] = Retirement(mark: mark, generation: generation)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(260))
                guard let self, self.retiring[id]?.generation == generation else { return }
                self.retiring.removeValue(forKey: id)?.mark.layer.removeFromSuperlayer()
            }
        } else {
            layer.removeFromSuperlayer()
        }
    }

    private func animate(_ layer: CALayer, key: String, to value: Any, duration: Double, from: Any? = nil) {
        let target = layer.value(forKeyPath: key)
        let previous = from ?? layer.presentation()?.value(forKeyPath: key) ?? target
        layer.setValue(value, forKeyPath: key)
        // Reduce Motion must also cancel a transition whose model value already equals its target.
        guard duration > 0 else { layer.removeAnimation(forKey: key); return }
        let unchanged = ((from ?? target) as? NSObject)?.isEqual(value) == true
        guard !unchanged else { return }
        let animation = CABasicAnimation(keyPath: key)
        animation.fromValue = previous
        animation.toValue = value
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(animation, forKey: key)
        self.animationsStarted += 1
    }

    /// Both tints are sRGB (`resolvedTints`); a fraction between them blends every component.
    static func mix(_ from: CGColor, _ to: CGColor, _ fraction: Double) -> CGColor {
        let amount = CGFloat(min(1, max(0, fraction)))
        guard amount > 0 else { return from }
        guard amount < 1, let lhs = from.components, let rhs = to.components, lhs.count == rhs.count,
              let space = from.colorSpace else { return amount >= 1 ? to : from }
        let components = zip(lhs, rhs).map { $0 + ($1 - $0) * amount }
        return CGColor(colorSpace: space, components: components) ?? to
    }

    private func inkChanged(from previous: CGColor?, to next: CGColor) -> Bool {
        guard let previous else { return false }
        // resolvedTints normalizes both endpoints to sRGB; opacity alone does not change ink polarity.
        return previous.components?.dropLast() != next.components?.dropLast()
    }
}
