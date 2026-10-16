import AppKit
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
struct NativeOrbitInstrumentSurfaceTests {
    @Test func `shared instrument ink preserves the ordinary four corners in light and dark appearances`() throws {
        for scheme in [ColorScheme.light, .dark] {
            for text in ["$84.18", "CA$1,234.56", "276.7M", "—"] {
                let content = self.readouts(text)
                let original = try self.pixels(content.environment(\.colorScheme, scheme))
                let shared = try self.pixels(NativeOrbitInstrumentSurface { content }
                    .environment(\.colorScheme, scheme))
                #expect(stride(from: 3, to: original.count, by: 4).contains { original[$0] > 0 })
                #expect(stride(from: 3, to: shared.count, by: 4).contains { shared[$0] > 0 })
                #expect(original == shared, "\(text), \(scheme)")
            }
        }
    }

    @Test func `target role constructs no instrument ink`() throws {
        let count = ConstructionCount()
        let element = NativeOrbitInstrumentElement(corner: .topLeading, help: "Fixture help") {
            self.countedInk(count)
        }
        _ = try self.pixels(element.environment(\.nativeOrbitInstrumentRole, .targets))
        #expect(count.value == 0)
        _ = try self.pixels(element.environment(\.nativeOrbitInstrumentRole, .ink))
        #expect(count.value > 0)
    }

    @Test func `instrument surface builds prepared readout values once`() throws {
        let count = ConstructionCount()
        let surface = NativeOrbitInstrumentSurface {
            self.preparedReadouts(count)
        }
        #expect(count.value == 1)
        _ = try self.pixels(surface)
        #expect(count.value == 1)
    }

    @Test func `shared reset and additional usage ink preserves every glyph state`() throws {
        let resets: [NativeOrbitResetCornerState] = [
            .unknown, .notApplicable, .inventory(available: 0, used: 0), .inventory(available: 3, used: 2),
        ]
        let extras: [NativeOrbitExtraUsageIconState] = [.unknown, .notApplicable, .zero, .active]
        for (reset, extra) in zip(resets, extras) {
            let content = ZStack {
                NativeOrbitResetComplication(state: reset, accent: .cyan, help: "Reset fixture")
                NativeOrbitExtraUsageComplication(fraction: 0.65, icon: extra, accent: .cyan, help: "Extra fixture")
            }
            let original = try self.pixels(content)
            let shared = try self.pixels(NativeOrbitInstrumentSurface { content })
            #expect(stride(from: 3, to: original.count, by: 4).contains { original[$0] > 0 })
            #expect(original == shared)
        }
    }

    private final class ConstructionCount {
        var value = 0
    }

    private func countedInk(_ count: ConstructionCount) -> Text {
        count.value += 1
        return Text("Visible ink")
    }

    private func preparedReadouts(_ count: ConstructionCount) -> some View {
        count.value += 1
        return self.readouts("12.34 credits")
    }

    private func readouts(_ text: String) -> some View {
        ZStack {
            NativeOrbitComplication(value: text, corner: .topLeading, help: "Spend fixture")
            NativeOrbitComplication(value: text, corner: .topTrailing, help: "Tokens fixture", monospaced: true)
            NativeOrbitResetComplication(state: .unknown, accent: .cyan, help: "Reset fixture")
            NativeOrbitExtraUsageComplication(fraction: 0.65, icon: .active, accent: .cyan, help: "Extra fixture")
        }.frame(width: 224, height: 224)
    }

    private func pixels(_ view: some View) throws -> [UInt8] {
        let renderer = ImageRenderer(content: view.frame(width: 400, height: 400))
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let rendered = pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        #expect(rendered)
        return pixels
    }
}
