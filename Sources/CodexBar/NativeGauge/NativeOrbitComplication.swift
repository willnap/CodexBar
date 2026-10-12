import AppKit
import CodexBarCore
import CoreText
import SwiftUI

/// Corner readouts share the dial's center and follow its outer circumference.
struct NativeOrbitComplication: View {
    enum Corner {
        case topLeading, topTrailing, bottomLeading, bottomTrailing

        var degrees: Double {
            switch self {
            case .topLeading: -135
            case .topTrailing: -45
            case .bottomLeading: 135
            case .bottomTrailing: 45
            }
        }

        var isTop: Bool {
            self == .topLeading || self == .topTrailing
        }
    }

    let value: String
    let corner: Corner
    let help: String
    var monospaced = false
    var numericValue: Double?

    var body: some View {
        NativeOrbitArcText(
            value: self.value,
            corner: self.corner,
            monospaced: self.monospaced,
            numericValue: self.numericValue)
            .foregroundStyle(self.value == "—" ? Color.secondary : Color.primary)
            .contentShape(NativeOrbitCornerRegion(corner: self.corner))
            .help(self.help)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(self.help)
    }
}

struct NativeOrbitArcText: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var displayedValue: String
    @State private var previousNumber: Double?
    @State private var increasing = true
    let value: String
    let corner: NativeOrbitComplication.Corner
    let radius: CGFloat
    let monospaced: Bool
    let fontSize: CGFloat
    let maximumSpan: CGFloat
    let numericValue: Double?

    init(
        value: String,
        corner: NativeOrbitComplication.Corner,
        radius: CGFloat = 118,
        monospaced: Bool = false,
        fontSize: CGFloat = 16,
        maximumSpan: CGFloat = 0.75,
        numericValue: Double? = nil)
    {
        self.value = value
        self.corner = corner
        self.radius = radius
        self.monospaced = monospaced
        self.fontSize = fontSize
        self.maximumSpan = maximumSpan
        self.numericValue = numericValue
        self._displayedValue = State(initialValue: value)
        self._previousNumber = State(initialValue: numericValue)
    }

    var body: some View {
        ZStack {
            NativeOrbitArcTextShape(
                value: self.displayedValue,
                corner: self.corner,
                radius: self.radius,
                monospaced: self.monospaced,
                fontSize: self.fontSize,
                maximumSpan: self.maximumSpan)
                .fill()
                .id(self.displayedValue)
                .transition(self.reduceMotion ? .opacity : .asymmetric(
                    insertion: .offset(y: self.increasing ? 12 : -12).combined(with: .opacity),
                    removal: .offset(y: self.increasing ? -12 : 12).combined(with: .opacity)))
        }
        .frame(width: 224, height: 224)
        .accessibilityHidden(true)
        .onChange(of: self.value) { _, value in
            self.increasing = (self.numericValue ?? 0) >= (self.previousNumber ?? 0)
            self.previousNumber = self.numericValue
            withAnimation(self.reduceMotion ? nil : .smooth(duration: 0.22)) {
                self.displayedValue = value
            }
        }
    }
}

/// Bend the actual font outlines onto one continuous baseline, rather than rotate separate text tiles.
private struct NativeOrbitArcTextShape: Shape {
    let value: String
    let corner: NativeOrbitComplication.Corner
    let radius: CGFloat
    let monospaced: Bool
    let fontSize: CGFloat
    let maximumSpan: CGFloat

    func path(in rect: CGRect) -> Path {
        let base = self.monospaced
            ? NSFont.monospacedSystemFont(ofSize: self.fontSize, weight: .semibold)
            : NSFont.systemFont(ofSize: self.fontSize, weight: .semibold)
        let font = self.monospaced ? base : NSFont(
            descriptor: base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor,
            size: self.fontSize) ?? base
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: self.value, attributes: [.font: font]))
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let scale = min(1, self.radius * self.maximumSpan / max(1, width))
        let direction: CGFloat = self.corner.isTop ? 1 : -1
        // Provider-specific by design: pi references here are geometric constants, not the Pi provider.
        let angle = CGFloat(self.corner.degrees) * CGFloat.pi / 180
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let runFont = attributes[kCTFontAttributeName] as? NSFont ?? font
            let outlineFont = CTFontCreateWithName(runFont.fontName as CFString, self.fontSize, nil)
            for index in 0..<count {
                guard let outline = CTFontCreatePathForGlyph(outlineFont, glyphs[index], nil) else { continue }
                let origin = positions[index]
                let middle = CTFontGetCapHeight(outlineFont) / 2
                func point(_ source: CGPoint) -> CGPoint {
                    let offset = (origin.x + source.x - width / 2) * scale
                    let theta = angle + direction * offset / self.radius
                    let radial = self.radius + direction * (origin.y + source.y - middle) * scale
                    return CGPoint(x: center.x + radial * cos(theta), y: center.y + radial * sin(theta))
                }
                outline.applyWithBlock { element in
                    let segment = element.pointee
                    switch segment.type {
                    case .moveToPoint: path.move(to: point(segment.points[0]))
                    case .addLineToPoint: path.addLine(to: point(segment.points[0]))
                    case .addQuadCurveToPoint:
                        path.addQuadCurve(to: point(segment.points[1]), control: point(segment.points[0]))
                    case .addCurveToPoint:
                        path.addCurve(
                            to: point(segment.points[2]),
                            control1: point(segment.points[0]),
                            control2: point(segment.points[1]))
                    case .closeSubpath: path.closeSubpath()
                    @unknown default: break
                    }
                }
            }
        }
        return path
    }
}

/// Only the occupied corner captures hover; the concentric gauges keep their own help targets.
struct NativeOrbitCornerRegion: Shape {
    let corner: NativeOrbitComplication.Corner

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addArc(
            center: CGPoint(x: rect.midX, y: rect.midY),
            radius: 118,
            startAngle: .degrees(self.corner.degrees - 27),
            endAngle: .degrees(self.corner.degrees + 27),
            clockwise: false)
        var region = path.strokedPath(StrokeStyle(lineWidth: 32, lineCap: .round))
        if self.corner == .bottomTrailing {
            region.addEllipse(in: CGRect(x: rect.midX + 81, y: rect.midY + 81, width: 20, height: 20))
        }
        return region
    }
}

/// What the bottom-leading corner can say about banked resets at the displayed instant.
enum NativeOrbitResetCornerState: Equatable {
    /// No inventory reading covers this instant (still loading, or a gap in the recorded history).
    case unknown
    /// The provider has no banked resets for this account.
    case notApplicable
    /// A received inventory: banked resets still available, and used ones in grants that are still current.
    case inventory(available: Int, used: Int)

    static func resolve(provider: UsageProvider?, metrics: NativeOrbitAccountMetrics) -> Self {
        if let banked = metrics.bankedResets {
            return .inventory(available: max(0, banked), used: max(0, metrics.usedResets))
        }
        return NativeOrbitResetEvent.providerBanksResets(provider) ? .unknown : .notApplicable
    }

    /// One glyph per reset along the arc, filled while banked and outlined once used. An empty inventory is one
    /// outlined glyph, so zero reads the same for every provider.
    var glyphs: [Bool] {
        guard case let .inventory(available, used) = self else { return [] }
        let banked = Array(repeating: true, count: available) + Array(repeating: false, count: used)
        return banked.isEmpty ? [false] : banked
    }
}

struct NativeOrbitResetComplication: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    static let symbol = "arrow.uturn.backward.circle"
    let state: NativeOrbitResetCornerState
    let accent: Color
    let help: String

    var body: some View {
        ZStack {
            switch self.state {
            case .inventory:
                let glyphs = self.state.glyphs
                let pitch = min(25, 90 / CGFloat(max(1, glyphs.count - 1)))
                let iconSize = min(17, pitch * 0.85)
                ForEach(Array(glyphs.enumerated()), id: \.offset) { index, banked in
                    Image(systemName: banked ? Self.symbol + ".fill" : Self.symbol)
                        .font(.system(size: iconSize, weight: .medium))
                        .foregroundStyle(banked ? self.accent : Color.secondary.opacity(0.45))
                        .position(Self.position(index, count: glyphs.count, pitch: pitch))
                }
            case .notApplicable:
                NativeOrbitSlashableGlyph(name: Self.symbol, size: 17, slashed: true, ink: AnyShapeStyle(.tertiary))
                    .position(Self.position(0, count: 1, pitch: 25))
            case .unknown:
                NativeOrbitArcText(value: "—", corner: .bottomLeading)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 224, height: 224)
        .animation(self.reduceMotion ? nil : .smooth(duration: 0.22), value: self.state)
        .contentShape(NativeOrbitCornerRegion(corner: .bottomLeading))
        .help(self.help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(self.help)
    }

    private static func position(_ index: Int, count: Int, pitch: CGFloat) -> CGPoint {
        let radius: CGFloat = 118
        let angle = 135 * Double.pi / 180 + (Double(index) - Double(count - 1) / 2) * Double(pitch) / radius
        return CGPoint(x: 112 + radius * cos(angle), y: 112 + radius * sin(angle))
    }
}

/// The bottom-trailing icon: tinted while additional usage accrues, plain when it applies at zero, slashed when it
/// does not apply (turned off, or never reported), and faint while no reading covers the instant.
enum NativeOrbitExtraUsageIconState: Equatable {
    case unknown
    case notApplicable
    case zero
    case active
}

struct NativeOrbitExtraUsageComplication: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    static let symbol = "creditcard.rewards.fill"
    let fraction: Double?
    let icon: NativeOrbitExtraUsageIconState
    let accent: Color
    let help: String

    private var ink: AnyShapeStyle {
        switch self.icon {
        case .active: AnyShapeStyle(self.accent)
        case .zero: AnyShapeStyle(.secondary)
        case .notApplicable: AnyShapeStyle(.tertiary)
        case .unknown: AnyShapeStyle(.quaternary)
        }
    }

    var body: some View {
        ZStack {
            NativeOrbitCornerGauge(fraction: 1)
                .stroke(Color.primary.opacity(0.10), style: StrokeStyle(lineWidth: 6, lineCap: .round))
            if let fraction, fraction.isFinite, fraction > 0 {
                NativeOrbitCornerGauge(fraction: min(1, fraction))
                    .stroke(self.accent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .animation(self.reduceMotion ? nil : .smooth(duration: 0.22), value: fraction)
            }
            NativeOrbitSlashableGlyph(
                name: Self.symbol,
                size: 16,
                slashed: self.icon == .notApplicable,
                ink: self.ink)
                .position(x: 203, y: 203)
                .animation(self.reduceMotion ? nil : .smooth(duration: 0.22), value: self.icon)
        }
        .frame(width: 224, height: 224)
        .contentShape(NativeOrbitCornerRegion(corner: .bottomTrailing))
        .help(self.help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(self.help)
    }
}

/// SF Symbols' slash modifier atop a glyph. `.symbolVariant(.slash)` silently draws the plain glyph when a symbol has
/// no slash variant (the reset and rewards-card glyphs have none), so those get the system slash layer of
/// `circle.slash` drawn over them, with a clearance cut along it, as the UsageIndicator component draws its modifiers.
struct NativeOrbitSlashableGlyph: View {
    let name: String
    let size: CGFloat
    var weight: Font.Weight = .medium
    var slashed = false
    var ink = AnyShapeStyle(.primary)

    static func hasSlashVariant(_ name: String) -> Bool {
        let variant = name.hasSuffix(".fill") ? String(name.dropLast(5)) + ".slash.fill" : name + ".slash"
        return NSImage(systemSymbolName: variant, accessibilityDescription: nil) != nil
    }

    var body: some View {
        ZStack {
            if !self.slashed {
                self.glyph
                    .transition(.opacity)
            } else if Self.hasSlashVariant(self.name) {
                self.glyph
                    .symbolVariant(.slash)
                    .transition(.opacity)
            } else {
                self.glyph
                    .mask { self.clearance }
                    .overlay { self.slash(self.ink) }
                    .transition(.opacity)
            }
        }
    }

    private var glyph: some View {
        Image(systemName: self.name)
            .font(.system(size: self.size, weight: self.weight))
            .foregroundStyle(self.ink)
    }

    /// Palette rendering keeps only the slash layer; the circle layer is clear.
    private func slash(_ ink: some ShapeStyle) -> some View {
        Image(systemName: "circle.slash")
            .font(.system(size: self.size, weight: self.weight))
            .symbolRenderingMode(.palette)
            .foregroundStyle(ink, Color.clear)
    }

    private var clearance: some View {
        let gap = max(1, self.size * 0.06)
        return ZStack {
            Color.white
            ForEach(0..<8, id: \.self) { index in
                let angle = Double(index) * Double.pi / 4
                self.slash(Color.black).offset(x: gap * cos(angle), y: gap * sin(angle))
            }
        }
        .compositingGroup()
        .luminanceToAlpha()
    }
}

private struct NativeOrbitCornerGauge: Shape {
    var fraction: Double

    var animatableData: Double {
        get { self.fraction }
        set { self.fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addArc(
            center: CGPoint(x: rect.midX, y: rect.midY),
            radius: 115,
            startAngle: .degrees(64),
            endAngle: .degrees(64 - 38 * self.fraction),
            clockwise: true)
        return path
    }
}
