import AppKit
import SwiftUI

/// The future's visual vocabulary. History desaturates the accent; the projection oversaturates it, draws dashed lines
/// and tints its half of the chart, so a predicted value never reads as a recorded one.
enum NativeOrbitProjectionStyle {
    /// Saturation gain of the future accent: the same hue, clearly more vivid.
    nonisolated static let saturationGain: CGFloat = 1.45
    nonisolated static let saturationLift: CGFloat = 0.06

    /// The accent of the future: hue kept, saturation and brightness raised, resolved per appearance. `strength`
    /// 1 is the standard future accent; custom strengths adjust its intensity.
    static func future(_ accent: Color, strength: CGFloat = 1) -> Color {
        let base = NSColor(accent)
        return Color(nsColor: NSColor(name: nil) { appearance in
            var resolved = base
            appearance.performAsCurrentDrawingAppearance {
                resolved = Self.vivid(base, strength: strength)
            }
            return resolved
        })
    }

    nonisolated static func vivid(_ color: NSColor, strength: CGFloat = 1) -> NSColor {
        guard let rgb = color.usingColorSpace(.sRGB) else { return color }
        let saturation = rgb.saturationComponent
        // A neutral accent has no hue to intensify; keep it neutral rather than invent one.
        guard saturation >= 0.02 else { return rgb }
        let gain = 1 + (Self.saturationGain - 1) * strength
        return NSColor(
            colorSpace: .sRGB,
            hue: rgb.hueComponent,
            saturation: min(1, saturation * gain + Self.saturationLift * strength),
            brightness: min(1, rgb.brightnessComponent * (1 + 0.04 * strength) + 0.02 * strength),
            alpha: rgb.alphaComponent)
    }

    /// How far the inspected moment sits from now across the chart: -1 at its start, 1 at its end, nil at rest.
    /// Quantized to tenths, so a sweep repaints the chart's colours a few times instead of on every pointer move.
    static func temporalOffset(_ date: Date?, now: Date, start: Date, end: Date) -> Double? {
        guard let date else { return nil }
        let raw = date > now
            ? date.timeIntervalSince(now) / max(1, end.timeIntervalSince(now))
            : -now.timeIntervalSince(date) / max(1, now.timeIntervalSince(start))
        let clamped = min(1, max(-1, raw))
        // Any step off now lands on the first tenth: crossing into the past or future always reads at once.
        return clamped >= 0 ? max(0.1, (clamped * 10).rounded(.up) / 10)
            : min(-0.1, (clamped * 10).rounded(.down) / 10)
    }

    /// Each tenth of the inspected span has a stable colour identity while retaining its distance from now.
    @MainActor
    static func temporalAccent(_ live: Color, offset: Double?) -> Color {
        guard let offset else { return live }
        let key = TemporalAccentKey(live: live, offset: offset)
        if let accent = self.temporalAccents[key] { return accent }
        let accent = offset > 0
            ? Self.future(live, strength: 0.6 + 0.8 * CGFloat(offset))
            : Self.past(live, fade: 0.16 + 0.22 * CGFloat(min(1, -offset)))
        if self.temporalAccents.count >= 256 { self.temporalAccents.removeAll() }
        self.temporalAccents[key] = accent
        return accent
    }

    private struct TemporalAccentKey: Hashable {
        let live: Color
        let offset: Double
    }

    @MainActor private static var temporalAccents: [TemporalAccentKey: Color] = [:]

    private static func past(_ live: Color, fade: CGFloat) -> Color {
        let base = NSColor(live)
        return Color(nsColor: NSColor(name: nil) { appearance in
            var resolved = base
            appearance.performAsCurrentDrawingAppearance {
                resolved = Self.muted(base, by: fade)
            }
            return resolved
        })
    }

    /// The accent of history: hue kept, saturation reduced by `fraction` (never to grey) and brightness eased.
    nonisolated static func muted(_ color: NSColor, by fraction: CGFloat) -> NSColor {
        guard let rgb = color.usingColorSpace(.sRGB) else { return color }
        return NSColor(
            colorSpace: .sRGB,
            hue: rgb.hueComponent,
            saturation: rgb.saturationComponent * (1 - min(0.7, max(0, fraction))),
            brightness: rgb.brightnessComponent * (1 - 0.06 * fraction),
            alpha: rgb.alphaComponent)
    }

    /// Development only (`--native-popup-preview-provider` with `CODEXBAR_PREVIEW_ANIMATION_SCALE`): slows the chart's
    /// animations so a range switch can be inspected frame by frame.
    nonisolated static let previewAnimationScale: Double = {
        guard CommandLine.arguments.contains("--native-popup-preview-provider") else { return 1 }
        return ProcessInfo.processInfo.environment["CODEXBAR_PREVIEW_ANIMATION_SCALE"].flatMap(Double.init) ?? 1
    }()

    /// The future's blur grows with the span it predicts: a month ahead is less certain than a day, a little.
    static func blurScale(days: Int) -> CGFloat {
        days >= 30 ? 1.5 : days >= 7 ? 1.25 : 1
    }

    /// Blur at `fraction` of the way from now to the end of the projected span: it eases in, staying near sharp for
    /// the first stretch and growing toward the end (3.2 pt on Day).
    static func blurRadius(fraction: Double, days: Int) -> CGFloat {
        3.2 * self.blurScale(days: days) * CGFloat(pow(min(1, max(0, fraction)), 1.6))
    }

    /// Chart blur at now and each third of the way to the end of the projected span.
    static func chartBlurRadii(days: Int) -> [CGFloat] {
        [0, 1.0 / 3, 2.0 / 3, 1].map { Self.blurRadius(fraction: $0, days: days) }
    }

    /// The dial's blur while the pointer reads `fraction` of the way through the projected span (0 at now). The
    /// dial's numbers and rings are larger than the chart's lines: the same uncertainty, a little less blur.
    static func dialBlur(fraction: Double, days: Int) -> CGFloat {
        self.blurRadius(fraction: fraction, days: days) * 0.8
    }

    /// Projected quota lines: dashed in every lane, each lane keeping its own rhythm.
    static func stroke(styleIndex: Int) -> StrokeStyle {
        let dash: [CGFloat] = switch styleIndex {
        case 0: [5, 3]
        case 1: [2, 3]
        case 2: [0.5, 2.5]
        default: [6, 2, 1, 2]
        }
        return StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round, dash: dash)
    }

    /// Scheduled events ahead: the window reset keeps the quiet rule of a recorded one, dashed more openly.
    static func eventStroke(_ kind: NativeOrbitScheduledEvent.Kind) -> StrokeStyle {
        switch kind {
        case .windowReset: StrokeStyle(lineWidth: 0.75, lineCap: .round, dash: [3, 3])
        case .bankedResetExpiry: StrokeStyle(lineWidth: 0.75, lineCap: .round, dash: [1, 2])
        case .additionalUsageCycle, .planExpiry: StrokeStyle(lineWidth: 0.75, lineCap: .round, dash: [4, 2])
        }
    }

    static func eventOpacity(_ kind: NativeOrbitScheduledEvent.Kind) -> Double {
        kind == .windowReset ? 0.4 : 0.55
    }

    /// Glyphs on the events' rules, outlined because nothing has happened yet. A scheduled window reset is the
    /// window's planned end and has only its rule, as in the recorded history.
    static func eventSymbol(_ kind: NativeOrbitScheduledEvent.Kind) -> String? {
        switch kind {
        case .windowReset: nil
        case .bankedResetExpiry: "hourglass.circle"
        case .additionalUsageCycle: "creditcard.circle"
        case .planExpiry: "calendar.circle"
        }
    }

    static func eventShortTitle(_ kind: NativeOrbitScheduledEvent.Kind) -> String {
        switch kind {
        case .windowReset: "Window resets"
        case .bankedResetExpiry: "Banked reset expires"
        case .additionalUsageCycle: "Additional usage resets"
        case .planExpiry: "Plan expires"
        }
    }

    /// The now marker follows the pointer with a spring and returns to now when the pointer leaves.
    static let markerSpring = Animation.spring(response: 0.32, dampingFraction: 0.82)
    /// Switching between the centered and the right-edge now animates like a range change.
    static let axisAnimation = Animation.smooth(duration: 0.35)
}
