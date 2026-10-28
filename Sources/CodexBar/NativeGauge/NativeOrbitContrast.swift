import AppKit
import SwiftUI

/// Thin graph strokes need more light than a large tinted surface in dark appearance.
enum NativeOrbitContrast {
    static func foreground(_ color: Color, for scheme: ColorScheme) -> Color {
        guard scheme == .dark else { return color }
        var resolved: NSColor?
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            resolved = NSColor(color).usingColorSpace(.sRGB)
        }
        guard let rgb = resolved else { return color }
        let components = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent]
        guard self.luminance(components) < 0.30 else { return color }
        var lower: CGFloat = 0
        var upper: CGFloat = 1
        for _ in 0..<12 {
            let blend = (lower + upper) / 2
            if self.luminance(components.map { $0 + (1 - $0) * blend }) < 0.30 {
                lower = blend
            } else {
                upper = blend
            }
        }
        let values = components.map { $0 + (1 - $0) * upper }
        return Color(.sRGB, red: values[0], green: values[1], blue: values[2], opacity: rgb.alphaComponent)
    }

    /// The colour itself, darkened only as far as white type on it needs for 4.5:1 contrast.
    static func fill(underWhiteText color: Color, for scheme: ColorScheme) -> Color {
        var resolved: NSColor?
        NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            resolved = NSColor(color).usingColorSpace(.sRGB)
        }
        guard let rgb = resolved else { return color }
        let components = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent]
        // White on a colour of relative luminance 0.183 is 4.5:1.
        let darkest: CGFloat = 0.183
        guard self.luminance(components) > darkest else { return Color(nsColor: rgb) }
        var lower: CGFloat = 0
        var upper: CGFloat = 1
        for _ in 0..<12 {
            let blend = (lower + upper) / 2
            if self.luminance(components.map { $0 * (1 - blend) }) > darkest {
                lower = blend
            } else {
                upper = blend
            }
        }
        let values = components.map { $0 * (1 - upper) }
        return Color(.sRGB, red: values[0], green: values[1], blue: values[2])
    }

    private static func luminance(_ values: [CGFloat]) -> CGFloat {
        let linear = values.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
    }
}
