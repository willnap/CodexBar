import AppKit
import SwiftUI

struct NativePageControlConfiguration {
    /// A lit mark's ink: its page is in the window.
    static let litAlpha: CGFloat = 0.85

    var direction = NativePageControlDirection.natural
    var backgroundStyle = NativePageControlBackgroundStyle.automatic
    var allowsContinuousInteraction = true
    var hidesForSinglePage = false
    var indicatorTint: Color?
    var currentIndicatorTint: Color?
    var preferredSymbol: String?
    var preferredCurrentSymbol: String?

    @MainActor
    func resolvedTints(appearance: NSAppearance, showsBackground: Bool) -> (indicator: CGColor, current: CGColor) {
        var result: (indicator: CGColor, current: CGColor)!
        appearance.performAsCurrentDrawingAppearance {
            let ink = showsBackground ? NSColor.white : NSColor.labelColor
            // Resting marks keep 3:1 contrast with the popup; lit ones stay a little translucent, a guide above the
            // dials rather than a headline.
            let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            let alpha: CGFloat = contrast ? 0.7 : showsBackground ? 0.45 : 0.55
            let indicator = self.indicatorTint.map(NSColor.init) ?? ink.withAlphaComponent(alpha)
            let current = self.currentIndicatorTint.map(NSColor.init)
                ?? ink.withAlphaComponent(contrast || showsBackground ? 1 : Self.litAlpha)
            result = (
                (indicator.usingColorSpace(.sRGB) ?? indicator).cgColor,
                (current.usingColorSpace(.sRGB) ?? current).cgColor)
        }
        return result
    }
}

/// Static reference artwork for offline fixture exports. The live control uses NativePageControlLayerView.
struct NativePageControlArtwork: View {
    struct VisibleMark: Identifiable {
        let indicator: NativeCombinedAccounts.Indicator
        let geometry: NativePageControlLayout.Mark
        var id: String {
            self.indicator.id
        }
    }

    let indicators: [NativeCombinedAccounts.Indicator]
    let layout: NativePageControlLayout
    var configuration = NativePageControlConfiguration()
    var expanded = false
    var hovered = false
    var enabled = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var vertical: Bool {
        self.configuration.direction.isVertical
    }

    private var thickness: CGFloat {
        max(
            26,
            self.indicators.map {
                let size = NativePageControlSymbol($0, configuration: self.configuration).size
                return self.vertical ? size.width : size.height
            }
            .max().map { $0 + 16 } ?? 26)
    }

    private var size: CGSize {
        self.vertical ? CGSize(width: 36, height: self.layout.availableLength)
            : CGSize(width: self.layout.availableLength, height: 36)
    }

    var controlFrame: CGRect {
        self.vertical
            ? CGRect(
                x: (36 - self.thickness) / 2,
                y: self.layout.start,
                width: self.thickness,
                height: self.layout.length)
            : CGRect(
                x: self.layout.start,
                y: (36 - self.thickness) / 2,
                width: self.layout.length,
                height: self.thickness)
    }

    private var visibleMarks: [VisibleMark] {
        self.layout.marks.compactMap { mark in
            guard self.indicators.indices.contains(mark.index), mark.scale > 0 else { return nil }
            return .init(indicator: self.indicators[mark.index], geometry: mark)
        }
    }

    private var showsBackground: Bool {
        switch self.configuration.backgroundStyle {
        case .automatic: self.expanded
        case .prominent: true
        case .minimal: false
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if self.showsBackground {
                Capsule()
                    .fill(self.reduceTransparency ? AnyShapeStyle(Color.black.opacity(0.85))
                        : AnyShapeStyle(.regularMaterial))
                    .environment(\.colorScheme, .dark)
                    .frame(width: self.controlFrame.width, height: self.controlFrame.height)
                    .position(x: self.controlFrame.midX, y: self.controlFrame.midY)
                    .transition(.opacity)
            }
            ForEach(self.layout.groups, id: \.id) { group in
                let thickness = NativePageControlLayout.platterThickness
                Capsule()
                    .fill(self.showsBackground ? Color.white.opacity(0.45 * 0.22) : Color.primary.opacity(0.55 * 0.22))
                    .frame(
                        width: self.vertical ? thickness : group.upper - group.lower,
                        height: self.vertical ? group.upper - group.lower : thickness)
                    .position(
                        x: self.vertical ? 18 : (group.lower + group.upper) / 2,
                        y: self.vertical ? (group.lower + group.upper) / 2 : 18)
            }
            ForEach(self.visibleMarks) { mark in
                let selected = mark.geometry.index == self.layout.selection
                let lit = selected ? 1 : mark.indicator.visibility
                let shift = NativePageControlSymbol(mark.indicator, configuration: self.configuration).inkOffset
                self.glyph(mark.indicator, selected: selected)
                    .foregroundStyle(self.showsBackground ? Color.white : Color.primary)
                    .opacity(self.showsBackground ? 0.45 + 0.55 * lit
                        : 0.55 + (NativePageControlConfiguration.litAlpha - 0.55) * lit)
                    .scaleEffect(mark.geometry.scale)
                    .position(
                        x: (self.vertical ? 18 : mark.geometry.position) - shift.width * mark.geometry.scale,
                        y: (self.vertical ? mark.geometry.position : 18) - shift.height * mark.geometry.scale)
            }
        }
        .frame(width: self.size.width, height: self.size.height)
        .clipped()
        .opacity(self.enabled ? 1 : 0.45)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private func glyph(_ indicator: NativeCombinedAccounts.Indicator, selected _: Bool) -> some View {
        let symbol = NativePageControlSymbol(indicator, configuration: self.configuration)
        return Image(nsImage: symbol.image)
            .resizable()
            .renderingMode(.template)
            .frame(width: symbol.size.width, height: symbol.size.height)
            .contentTransition(self.reduceMotion ? .identity : .symbolEffect(.replace))
    }
}

/// Enabled only by the synthetic fixture; samples compositor presentation layers without screen reads.
@MainActor
enum NativePageControlMotionTrace {
    static var enabled = false
    static var intermediateTintSamples = 0
    static var positions: [String: Set<CGFloat>] = [:]
    static var invalidForegroundSamples = 0
    static var displayIntervals: [Double] = []
    static var displayBudgets: [Double] = []

    static func record(id: String, x: CGFloat, selection: CGFloat) {
        guard self.enabled else { return }
        if selection > 0.001, selection < 0.999 {
            self.intermediateTintSamples += 1
        }
        if self.positions[id, default: []].count < 1000 { self.positions[id, default: []].insert(x) }
    }
}
