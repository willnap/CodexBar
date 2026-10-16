import AppKit
import SwiftUI

/// Gauge and history identifiers resolve to the same quota color, independent of display order.
enum NativeOrbitPalette {
    enum Tone: Hashable {
        case weekly, session, daily, monthly, extra(Int)
    }

    private struct Key: Hashable {
        let accent: Color
        let tone: Tone
    }

    @MainActor private static var colors: [Key: Color] = [:]

    @MainActor
    static func color(accent: Color, id: String, period: TimeInterval) -> Color {
        let tone = Self.tone(id: id, period: period)
        let key = Key(accent: accent, tone: tone)
        if let color = self.colors[key] { return color }
        let neutral = accent == .gray
        let base = NSColor(accent)
        let color = Color(nsColor: NSColor(name: nil) { appearance in
            var resolved = base
            appearance.performAsCurrentDrawingAppearance {
                let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                resolved = Self.variant(base, tone: tone, neutral: neutral, dark: dark)
            }
            return resolved
        })
        // A fresh dynamic color has a new identity. Retain it so unchanged glass tints survive pointer updates.
        if self.colors.count >= 512 { self.colors.removeAll(keepingCapacity: true) }
        self.colors[key] = color
        return color
    }

    nonisolated static func tone(id: String, period: TimeInterval) -> Tone {
        let id = id.hasPrefix("nativeQuota:") ? String(id.dropFirst("nativeQuota:".count)) : id
        switch id {
        case "session", "session5h": return .session
        case "weekly": return .weekly
        case "daily": return .daily
        case "monthly", "kimi-monthly": return .monthly
        default: break
        }
        let standard = ["primary", "secondary"].contains(id)
        if standard {
            if period == 604_800 { return .weekly }
            if period == 18000 { return .session }
            if period == 86400 { return .daily }
        }
        if (28 * 86400...31 * 86400).contains(period), standard { return .monthly }
        // Legacy model history uses `opus`; its native observation and gauge use `tertiary`.
        let key = id == "opus" ? "tertiary" : id
        let hash = key.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
        return .extra(Int(hash % 3))
    }

    private nonisolated static func variant(_ base: NSColor, tone: Tone, neutral: Bool, dark: Bool) -> NSColor {
        guard let rgb = base.usingColorSpace(.sRGB) else { return base }
        if tone == .weekly, !neutral, !dark { return base }
        let shade: (saturation: CGFloat, brightness: CGFloat) = switch tone {
        case .weekly: (1, 0)
        case .session: (0.7, 0.12)
        case .daily: (0.9, -0.06)
        case .monthly: (0.85, -0.12)
        case let .extra(index): (0.88 - CGFloat(index) * 0.09, -0.20 - CGFloat(index) * 0.04)
        }
        let saturation = rgb.saturationComponent
        // Dark surfaces need lighter pigment. Darkening the inner quotas hid both their color and glass edges.
        let adjustment = dark ? 0.14 + abs(shade.brightness) : shade.brightness
        let brightness = min(1, max(0, rgb.brightnessComponent + adjustment))
        if neutral || saturation < 0.02 {
            return NSColor(srgbRed: brightness, green: brightness, blue: brightness, alpha: rgb.alphaComponent)
        }
        // Every quota retains the provider hue; saturation and brightness distinguish its windows.
        return NSColor(
            calibratedHue: rgb.hueComponent,
            saturation: saturation * shade.saturation,
            brightness: brightness,
            alpha: rgb.alphaComponent)
    }
}
