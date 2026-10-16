import AppKit
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
struct NativeOrbitPaletteTests {
    @Test
    func `unchanged quota tints retain identity across inspection updates and aliases`() {
        let accent = Color(red: 0.13, green: 0.37, blue: 0.61)
        let first = NativeOrbitPalette.color(accent: accent, id: "session", period: 18000)
        for _ in 0..<120 {
            #expect(NativeOrbitPalette.color(accent: accent, id: "primary", period: 18000) == first)
            #expect(NativeOrbitPalette.color(accent: accent, id: "nativeQuota:session5h", period: 0) == first)
        }
        #expect(NativeOrbitPalette.color(accent: accent, id: "weekly", period: 604_800) != first)
    }

    @Test
    func `native observation aliases match the same gauge quota tone`() {
        for id in ["primary", "secondary", "tertiary", "session", "weekly", "session5h", "kimi-monthly"] {
            for period in [0.0, 18000, 86400, 604_800, 2_592_000] {
                #expect(NativeOrbitPalette.tone(id: id, period: period)
                    == NativeOrbitPalette.tone(id: "nativeQuota:" + id, period: period))
            }
        }
        #expect(NativeOrbitPalette.tone(id: "primary", period: 18000)
            == NativeOrbitPalette.tone(id: "session", period: 18000))
        #expect(NativeOrbitPalette.tone(id: "secondary", period: 604_800)
            == NativeOrbitPalette.tone(id: "weekly", period: 604_800))
        #expect(NativeOrbitPalette.tone(id: "primary", period: 604_800)
            == NativeOrbitPalette.tone(id: "weekly", period: 604_800))
        #expect(NativeOrbitPalette.tone(id: "opus", period: 604_800)
            == NativeOrbitPalette.tone(id: "nativeQuota:tertiary", period: 604_800))
    }

    @Test
    func `explicit named quotas keep their tone when cadence is absent or changes`() {
        let aliases: [(String, NativeOrbitPalette.Tone)] = [
            ("session5h", .session), ("session", .session), ("weekly", .weekly),
            ("daily", .daily), ("monthly", .monthly), ("kimi-monthly", .monthly),
        ]
        for (id, expected) in aliases {
            for period in [0.0, 1, 18000, 604_800, 2_592_000] {
                #expect(NativeOrbitPalette.tone(id: id, period: period) == expected)
            }
        }
        #expect(NativeOrbitPalette.tone(id: "optional-model", period: 18000)
            == NativeOrbitPalette.tone(id: "optional-model", period: 604_800))
    }

    @Test
    func `inactive account variants stay neutral`() throws {
        for id in ["primary", "secondary", "tertiary", "kimi-monthly", "session5h"] {
            let color = NativeOrbitPalette.color(accent: .gray, id: id, period: 18000)
            let rgb = try #require(NSColor(color).usingColorSpace(.sRGB))
            #expect(abs(rgb.redComponent - rgb.greenComponent) < 0.001)
            #expect(abs(rgb.greenComponent - rgb.blueComponent) < 0.001)
        }
    }

    @Test
    func `dark appearance lifts every quota tone while preserving provider hue`() throws {
        let accent = Color(.sRGB, red: 0.12, green: 0.42, blue: 0.50, opacity: 1)
        for id in ["weekly", "session", "daily", "monthly", "tertiary"] {
            let color = NativeOrbitPalette.color(accent: accent, id: id, period: 18000)
            let light = try Self.resolve(color, appearance: .aqua)
            let dark = try Self.resolve(color, appearance: .darkAqua)
            #expect(dark.brightnessComponent > light.brightnessComponent)
            #expect(abs(dark.hueComponent - light.hueComponent) < 0.01)
        }
    }

    private static func resolve(_ color: Color, appearance: NSAppearance.Name) throws -> NSColor {
        let appearance = try #require(NSAppearance(named: appearance))
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            resolved = NSColor(color).usingColorSpace(.sRGB)
        }
        return try #require(resolved)
    }
}
