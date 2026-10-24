import AppKit
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
struct NativeCombinedMetricContrastTests {
    @Test func `moving selection keeps glyphs contrasting with the actual pill coverage`() throws {
        for scheme in [ColorScheme.light, .dark] {
            let glyphs = try self.render(self.readouts, scheme: scheme, transparent: true)
            for (index, angle) in [-135.0, -112.5, -90, -67.5, -45].enumerated() {
                let ink = NativeCombinedMetricSelectionInk(
                    degrees: angle, length: 65, money: "$3.25", tokens: "1.7M", moneyValue: 3.25, tokenValue: 1_700_000)
                let rendered = try self.render(ink, scheme: scheme)
                let background = try self.render(
                    NativeCombinedMetricPill(degrees: angle, length: 65).fill(.primary), scheme: scheme)
                #expect(rendered.pixelsWide == glyphs.pixelsWide)
                #expect(rendered.pixelsHigh == glyphs.pixelsHigh)
                var minimumContrast = 1.0
                var checked = 0
                for y in 0..<glyphs.pixelsHigh {
                    for x in 0..<glyphs.pixelsWide {
                        guard let glyph = glyphs.colorAt(x: x, y: y), glyph.alphaComponent > 0.7,
                              let back = background.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                              let actual = rendered.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                        let base = self.brightness(back)
                        // Exclude the one-pixel antialiased edge of the moving capsule, where coverage is mixed.
                        guard base < 0.2 || base > 0.8 else { continue }
                        minimumContrast = min(minimumContrast, abs(self.brightness(actual) - base))
                        checked += 1
                    }
                }
                #expect(checked > 100)
                #expect(minimumContrast > 0.35, "\(scheme) angle \(angle), minimum \(minimumContrast)")
                if let path = ProcessInfo.processInfo.environment["CODEXBAR_METRIC_PROOF_DIR"] {
                    let directory = URL(fileURLWithPath: path, isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try rendered.representation(using: .png, properties: [:])?
                        .write(to: directory.appendingPathComponent("\(scheme)-\(index).png"))
                }
            }
        }
    }

    private var readouts: some View {
        ZStack {
            NativeOrbitArcText(value: "$3.25", corner: .topLeading, numericValue: 3.25)
            NativeOrbitArcText(value: "1.7M", corner: .topTrailing, monospaced: true, numericValue: 1_700_000)
        }
        .frame(width: 224, height: 224)
    }

    private func render(_ view: some View, scheme: ColorScheme, transparent: Bool = false) throws -> NSBitmapImageRep {
        let background = transparent ? Color.clear : scheme == .light ? Color.white : Color.black
        let renderer = ImageRenderer(content: view
            .frame(width: 224, height: 224).padding(24)
            .background(background)
            .environment(\.colorScheme, scheme))
        renderer.scale = 2
        return try NSBitmapImageRep(cgImage: #require(renderer.cgImage))
    }

    private func brightness(_ color: NSColor) -> Double {
        Double(0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent)
    }
}
