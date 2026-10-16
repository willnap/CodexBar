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
        func luminance(_ values: [CGFloat]) -> CGFloat {
            let linear = values.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
        }
        guard luminance(components) < 0.30 else { return color }
        var lower: CGFloat = 0
        var upper: CGFloat = 1
        for _ in 0..<12 {
            let blend = (lower + upper) / 2
            if luminance(components.map { $0 + (1 - $0) * blend }) < 0.30 {
                lower = blend
            } else {
                upper = blend
            }
        }
        let values = components.map { $0 + (1 - $0) * upper }
        return Color(.sRGB, red: values[0], green: values[1], blue: values[2], opacity: rgb.alphaComponent)
    }
}
