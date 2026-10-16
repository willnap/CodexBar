import AppKit
import CoreText
import SwiftUI

/// The existing gauge's native glass material, bounded by the rounded money glyphs themselves.
struct NativeOrbitMoneyReading: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let reading: NativeOrbitMonetaryInstrument.Reading
    let accent: Color
    var lanes = 0

    static func size(lanes: Int) -> CGSize {
        guard lanes > 0 else { return CGSize(width: 192, height: 52) }
        let radius = (NativeOrbitSymbol.radii[min(2, lanes - 1)] - NativeOrbitSymbol.stroke / 2) * 216 / 256 - 5
        let height = min(52, radius * 0.72)
        return CGSize(width: min(144, 2 * sqrt(radius * radius - height * height / 4)), height: height)
    }

    var body: some View {
        let shape = NativeOrbitMoneyShape(value: self.reading.value)
        let ink = Self.contrasting(self.accent)
        Group {
            if self.reduceTransparency || self.reading.amount == nil {
                shape.fill(self.reading.amount == nil ? Color.secondary : ink)
            } else {
                // Keep narrow strokes, especially the currency glyph, solid enough to read. The native
                // material supplies the reflection; an extra bright outline closes the glyph's counters.
                shape.fill(ink.opacity(0.80))
                    .glassEffect(.regular.tint(ink.opacity(0.78)), in: shape)
                    .allowedDynamicRange(.standard)
            }
        }
        .frame(width: Self.size(lanes: self.lanes).width, height: Self.size(lanes: self.lanes).height)
        .help(self.reading.help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(self.reading.help)
    }

    private static func contrasting(_ accent: Color) -> Color {
        let base = NSColor(accent)
        return Color(nsColor: NSColor(name: nil) { appearance in
            var result = base
            appearance.performAsCurrentDrawingAppearance {
                guard let rgb = base.usingColorSpace(.sRGB) else { return }
                let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                let brightness = dark ? max(0.78, rgb.brightnessComponent) : min(0.58, rgb.brightnessComponent)
                result = NSColor(
                    calibratedHue: rgb.hueComponent,
                    saturation: rgb.saturationComponent,
                    brightness: brightness,
                    alpha: rgb.alphaComponent)
            }
            return result
        })
    }
}

struct NativeOrbitMoneyShape: Shape {
    let value: String

    func path(in rect: CGRect) -> Path {
        let base = NSFont.systemFont(ofSize: 64, weight: .bold)
        let descriptor = base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor
        let font = NSFont(descriptor: descriptor, size: 64) ?? base
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: self.value,
            attributes: [.font: font]))
        let outline = CGMutablePath()
        // CoreText returns an array containing only CTRun objects.
        // swiftlint:disable:next force_cast
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
            let runFont = unsafeDowncast(
                (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as AnyObject,
                to: CTFont.self)
            for index in glyphs.indices {
                guard let glyph = CTFontCreatePathForGlyph(runFont, glyphs[index], nil) else { continue }
                outline.addPath(glyph, transform: CGAffineTransform(
                    translationX: positions[index].x, y: positions[index].y))
            }
        }
        let bounds = outline.boundingBoxOfPath
        guard bounds.width > 0, bounds.height > 0 else { return Path() }
        // A missing reading is a typographic dash, whose shallow ink bounds must not expand to fill the face.
        let maximumScale = self.value == "—" ? rect.height / 64 : CGFloat.infinity
        let scale = min(rect.width / bounds.width, rect.height / bounds.height, maximumScale)
        let transform = CGAffineTransform(
            a: scale,
            b: 0,
            c: 0,
            d: -scale,
            tx: rect.midX - bounds.midX * scale,
            ty: rect.midY + bounds.midY * scale)
        return Path(outline).applying(transform)
    }
}
