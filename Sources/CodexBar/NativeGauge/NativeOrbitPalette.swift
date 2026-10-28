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

    /// Charts can resolve a tint once per vertex while laying out a range transition. Convert its pigment only
    /// once per appearance, retaining dynamic appearance and system accent changes without repeated ColorSync work.
    private final class Variants: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [NSAppearance.Name: NSColor] = [:]
        private var generation = 0
        private var observer: NSObjectProtocol?

        init() {
            self.observer = NotificationCenter.default.addObserver(
                forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: nil)
            { [weak self] _ in
                guard let self else { return }
                self.lock.withLock {
                    self.generation &+= 1
                    self.values.removeAll(keepingCapacity: true)
                }
            }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }

        func value(for appearance: NSAppearance, build: () -> NSColor) -> NSColor {
            let (cached, generation) = self.lock.withLock { (self.values[appearance.name], self.generation) }
            if let cached { return cached }
            // AppKit and a dynamic accent can synchronously notify a color change. Never call them under the
            // cache lock, or publish a value across an invalidation which occurred while resolving that accent.
            let value = build()
            self.lock.withLock {
                if self.generation == generation { self.values[appearance.name] = value }
            }
            return value
        }
    }

    @MainActor
    static func color(accent: Color, id: String, period: TimeInterval) -> Color {
        let tone = Self.tone(id: id, period: period)
        let key = Key(accent: accent, tone: tone)
        if let color = self.colors[key] { return color }
        let neutral = accent == .gray
        let base = NSColor(accent)
        let variants = Variants()
        let color = Color(nsColor: NSColor(name: nil) { appearance in
            variants.value(for: appearance) {
                var resolved = base
                appearance.performAsCurrentDrawingAppearance {
                    let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    resolved = Self.variant(base, tone: tone, neutral: neutral, dark: dark)
                }
                return resolved
            }
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

    /// Brightness tells a dial's windows apart: tinted glass flattens most of a saturation difference.
    private nonisolated static let lightestStep: CGFloat = 0.12
    private nonisolated static let deepestStep: CGFloat = 0.28
    /// The deepest window's least brightness, so it never turns black.
    private nonisolated static let lightFloor: CGFloat = 0.1
    /// Dark surfaces take lighter pigment and a shorter ladder.
    private nonisolated static let darkLift: CGFloat = 0.14
    private nonisolated static let darkLadder: CGFloat = 0.7
    private nonisolated static let darkFloor: CGFloat = 0.55

    private nonisolated static func variant(_ base: NSColor, tone: Tone, neutral: Bool, dark: Bool) -> NSColor {
        guard let rgb = base.usingColorSpace(.sRGB) else { return base }
        let shade: (saturation: CGFloat, brightness: CGFloat) = switch tone {
        case .weekly: (1, 0)
        case .session: (0.7, 0.12)
        case .daily: (0.9, -0.06)
        case .monthly: (0.85, -0.12)
        case let .extra(index): (0.88 - CGFloat(index) * 0.09, -0.20 - CGFloat(index) * 0.04)
        }
        // The whole ladder stays inside the brightness range; the provider's level moves to fit it. Clamping each
        // window instead made bright accents' windows identical in dark mode (Claude's Fable ring matched Session).
        let scale = dark ? self.darkLadder : 1
        let level = min(
            1 - self.lightestStep * scale,
            max(
                (dark ? self.darkFloor : self.lightFloor) + self.deepestStep * scale,
                rgb.brightnessComponent + (dark ? self.darkLift : 0)))
        if tone == .weekly, !neutral, !dark, level == rgb.brightnessComponent { return rgb }
        let brightness = level + shade.brightness * scale
        let saturation = rgb.saturationComponent
        if neutral || saturation < 0.02 {
            return NSColor(srgbRed: brightness, green: brightness, blue: brightness, alpha: rgb.alphaComponent)
        }
        // Every quota retains the provider hue; saturation and brightness distinguish its windows. Built in the
        // accent's own sRGB space: a calibrated colour converts back with its brightness steps squeezed together.
        return NSColor(
            colorSpace: .sRGB,
            hue: rgb.hueComponent,
            saturation: saturation * shade.saturation,
            brightness: brightness,
            alpha: rgb.alphaComponent)
    }
}
