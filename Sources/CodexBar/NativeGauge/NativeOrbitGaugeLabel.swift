import AppKit
import SwiftUI

/// Small system lettering follows the dial, with a little more ink where the quota passes beneath it.
struct NativeOrbitGaugeLabel: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let title: String
    let radius: CGFloat
    let size: CGFloat
    var remaining: Double?

    var body: some View {
        let font = NSFont.systemFont(ofSize: 8, weight: .medium)
        Text(self.title.uppercased())
            .font(Font(font))
            .foregroundStyle(Color.primary)
            .textRenderer(NativeOrbitGaugeLabelRenderer(
                radius: self.radius,
                capHeight: font.capHeight,
                remaining: self.remaining ?? 0,
                emptyOpacity: self.reduceTransparency ? 0.62 : self.colorScheme == .dark ? 0.36 : 0.32,
                filledOpacity: self.reduceTransparency ? 0.78 : self.colorScheme == .dark ? 0.66 : 0.52))
            .fixedSize()
            .frame(width: self.size, height: self.size)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct NativeOrbitGaugeLabelRenderer: TextRenderer {
    let radius: CGFloat
    let capHeight: CGFloat
    var remaining: Double
    let emptyOpacity: Double
    let filledOpacity: Double

    var animatableData: Double {
        get { self.remaining }
        set { self.remaining = newValue }
    }

    var displayPadding: EdgeInsets {
        .init(top: 128, leading: 128, bottom: 128, trailing: 128)
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            let bounds = line.typographicBounds
            // Preserve complete model names while keeping every label in the bottom quarter of its lane.
            let scale = min(1, self.radius * .pi / 2 / max(1, bounds.width))
            for run in line {
                for slice in run {
                    let glyph = slice.typographicBounds
                    let distance = (glyph.rect.midX - bounds.rect.midX) * scale
                    let angle = CGFloat.pi / 2 - distance / self.radius
                    var placed = context
                    let fraction = self.remaining.isFinite ? min(1, max(0, self.remaining)) : 0
                    let filled = fraction > 0 && angle >= (130 - 260 * fraction) * .pi / 180
                    placed.opacity *= filled ? self.filledOpacity : self.emptyOpacity
                    placed.translateBy(
                        x: bounds.rect.midX + self.radius * cos(angle),
                        y: bounds.rect.midY + self.radius * sin(angle))
                    placed.rotate(by: .radians(angle - .pi / 2))
                    placed.scaleBy(x: scale, y: scale)
                    placed.translateBy(x: -glyph.rect.midX, y: -(glyph.origin.y - self.capHeight / 2))
                    placed.draw(slice)
                }
            }
        }
    }
}
