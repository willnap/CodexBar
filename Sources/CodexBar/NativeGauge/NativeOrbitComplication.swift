import AppKit
import CodexBarCore
import CoreText
import SwiftUI
import Synchronization

/// Corner readouts share the dial's center and follow its outer circumference.
enum NativeOrbitComplicationStyle {
    static let radius: CGFloat = 118
    static let idle = Color.secondary
    static let unavailable = Color.secondary.opacity(0.55)

    static func point(degrees: Double, radius: CGFloat = radius) -> CGPoint {
        let angle = degrees * .pi / 180
        return CGPoint(x: 112 + radius * cos(angle), y: 112 + radius * sin(angle))
    }
}

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

    /// Primary ink throughout: the readout inks its own placeholder, so a "—" rolling in or out keeps its colour.
    var body: some View {
        NativeOrbitInstrumentElement(corner: self.corner, help: self.help) {
            NativeOrbitArcText(
                value: self.value,
                corner: self.corner,
                monospaced: self.monospaced,
                numericValue: self.numericValue)
                .foregroundStyle(Color.primary)
        }
    }
}

/// A corner readout bent along the dial. It is one `Text` with SwiftUI's numeric content transition, the one Apple's
/// money and counter readouts use: only the characters that change animate, rolling up as the value grows and down as
/// it shrinks. `NativeOrbitArcTextRenderer` lays each glyph onto the corner's arc. While the chart is scrubbed the
/// readout follows the pointer in place, as Apple's scrubbed charts do; a transition at every step would leave the
/// changing digits a permanent blur.
struct NativeOrbitArcText: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var cadence: NativeOrbitReadoutCadence
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
        radius: CGFloat = NativeOrbitComplicationStyle.radius,
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
        self._cadence = State(initialValue: NativeOrbitReadoutCadence(initialValue: value))
    }

    static let placeholder = "—"

    private struct FontKey: Hashable, Sendable {
        let monospaced: Bool
        let size: CGFloat
    }

    private nonisolated static let fonts = Mutex<[FontKey: NSFont]>([:])

    /// SF Mono for counts and SF Rounded for money, semibold, both with tabular figures as `.monospacedDigit()` sets
    /// them: a digit's width never moves the characters a change keeps. These fonts are immutable and shared.
    nonisolated static func font(monospaced: Bool, size: CGFloat) -> NSFont {
        let key = FontKey(monospaced: monospaced, size: size)
        return Self.fonts.withLock { fonts in
            if let font = fonts[key] { return font }
            let font: NSFont
            if monospaced {
                font = NSFont.monospacedSystemFont(ofSize: size, weight: .semibold)
            } else {
                let base = NSFont.systemFont(ofSize: size, weight: .semibold)
                let rounded = base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor
                let tabular = rounded.addingAttributes([.featureSettings: [[
                    NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                    NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
                ]]])
                font = NSFont(descriptor: tabular, size: size) ?? base
            }
            if fonts.count >= 128 { fonts.removeAll(keepingCapacity: true) }
            fonts[key] = font
            return font
        }
    }

    /// The value the transition compares to pick each change's direction: the caller's number, else the readout's own
    /// (compact suffixes included). A readout without one counts as zero, so a value appearing rolls up and one
    /// vanishing rolls down.
    static func transitionValue(_ value: String, numericValue: Double?) -> Double {
        numericValue ?? NativeOrbitReadoutNumber.value(in: value) ?? 0
    }

    var body: some View {
        let font = Self.font(monospaced: self.monospaced, size: self.fontSize)
        let cadence = self.cadence
        let value = self.value
        let reduceMotion = self.reduceMotion
        return Text(self.value)
            .font(Font(font as CTFont))
            .foregroundStyle(self.value == Self.placeholder ? NativeOrbitComplicationStyle.unavailable : Color.primary)
            .lineLimit(1)
            .fixedSize()
            .contentTransition(.numericText(
                value: Self.transitionValue(self.value, numericValue: self.numericValue)))
            .textRenderer(NativeOrbitArcTextRenderer(
                corner: self.corner,
                radius: self.radius,
                maximumSpan: self.maximumSpan,
                capHeight: font.capHeight))
            .frame(width: 224, height: 224)
            .accessibilityHidden(true)
            .transaction(value: value) { [value, reduceMotion, cadence] transaction in
                cadence.prepareTransaction(
                    &transaction,
                    value: value,
                    now: ProcessInfo.processInfo.systemUptime,
                    reduceMotion: reduceMotion)
            }
    }
}

/// Stored by view identity without publishing a second state update for each numeric change.
@MainActor
final class NativeOrbitReadoutCadence {
    static let scrubInterval: TimeInterval = 0.25 * NativeOrbitProjectionStyle.previewAnimationScale
    static let animationDuration: TimeInterval = 0.4 * NativeOrbitProjectionStyle.previewAnimationScale
    private var value: String
    private var changedAt: TimeInterval?
    private var scrubbing = false

    init(initialValue: String) {
        self.value = initialValue
    }

    func prepareTransaction(
        _ transaction: inout Transaction,
        value: String,
        now: TimeInterval,
        reduceMotion: Bool)
    {
        if self.value != value {
            self.scrubbing = self.changedAt.map { now - $0 < Self.scrubInterval } ?? false
            self.changedAt = now
            self.value = value
        }
        if self.scrubbing || reduceMotion {
            transaction.animation = nil
            transaction.disablesAnimations = true
        } else if !transaction.disablesAnimations {
            transaction.animation = .smooth(duration: Self.animationDuration)
        }
    }
}

/// Lays a one-line `Text` onto a corner's arc: each glyph centred where its advance falls along the line, scaled to fit
/// `maximumSpan` of the radius, upright to the arc, with the middle of its cap height on the circle. The text's own
/// centre is the dial's, as the readout is centred in the dial's frame.
struct NativeOrbitArcTextRenderer: TextRenderer {
    let corner: NativeOrbitComplication.Corner
    let radius: CGFloat
    let maximumSpan: CGFloat
    let capHeight: CGFloat

    /// The glyphs land on the arc, far outside the text's own bounds.
    var displayPadding: EdgeInsets {
        EdgeInsets(top: 240, leading: 240, bottom: 240, trailing: 240)
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        let arc = NativeOrbitCornerArc(corner: self.corner, radius: self.radius)
        for line in layout {
            let bounds = line.typographicBounds
            let scale = min(1, self.radius * self.maximumSpan / max(1, bounds.width))
            let center = CGPoint(x: bounds.rect.midX, y: bounds.rect.midY)
            for run in line {
                for slice in run {
                    let glyph = slice.typographicBounds
                    let distance = (glyph.rect.midX - bounds.rect.midX) * scale
                    let point = arc.point(along: distance, height: 0)
                    // Upright to the arc: along its tangent, tops outward on top corners and inward on bottom ones.
                    // Provider-specific by design: CGFloat.pi is the mathematical rotation constant, unrelated to a
                    // provider.
                    let angle = arc.angle(along: distance) + (self.corner.isTop ? 1 : -1) * CGFloat.pi / 2
                    var placed = context
                    placed.translateBy(x: center.x + point.x, y: center.y + point.y)
                    placed.rotate(by: .radians(angle))
                    placed.scaleBy(x: scale, y: scale)
                    placed.translateBy(x: -glyph.rect.midX, y: -(glyph.origin.y - self.capHeight / 2))
                    placed.draw(slice)
                }
            }
        }
    }
}

/// The number a corner readout shows, which its numeric transition compares to roll each change the right way.
enum NativeOrbitReadoutNumber {
    /// A character's place relative to the number in its readout. Indices count away from the decimal separator.
    enum Place: Hashable {
        /// Characters before the first digit, counted leftward from it ("$", "US$", "—").
        case prefix(Int)
        /// Integer digits and their grouping separators, counted leftward from the ones digit.
        case integer(Int)
        /// The decimal separator.
        case separator
        /// Fraction digits, counted rightward from the separator.
        case fraction(Int)
        /// Characters after the number, counted rightward from it ("M", " credits").
        case suffix(Int)
    }

    /// The decimal separator the readouts are formatted with.
    static var localSeparator: Character {
        Locale.autoupdatingCurrent.decimalSeparator?.first ?? "."
    }

    /// Each character's place, in reading order. The number is the first run of digits together with the single
    /// separators between them (grouping or decimal), the last `separator` among them being the decimal one. A
    /// readout without digits is all prefix.
    static func places(of text: String, separator: Character = Self.localSeparator) -> [Place] {
        let characters = Array(text)
        guard let start = characters.firstIndex(where: \.isWholeNumber) else {
            return characters.indices.map { .prefix(characters.count - 1 - $0) }
        }
        var end = start + 1
        while end < characters.count {
            if characters[end].isWholeNumber {
                end += 1
            } else if !characters[end].isLetter, end + 1 < characters.count, characters[end + 1].isWholeNumber {
                end += 2
            } else {
                break
            }
        }
        let point = characters[start..<end].lastIndex(of: separator)
        let integerEnd = point ?? end
        return characters.indices.map { index in
            if index < start { return .prefix(start - 1 - index) }
            if index < integerEnd { return .integer(integerEnd - 1 - index) }
            if index == point { return .separator }
            if index < end { return .fraction(index - integerEnd - 1) }
            return .suffix(index - end)
        }
    }

    /// The number a readout shows, scaled by a compact suffix ("276.7M"), or nil when it shows none ("—").
    static func value(in text: String, separator: Character = Self.localSeparator) -> Double? {
        var digits = ""
        var suffix = ""
        var sign: Double = 1
        for (place, character) in zip(self.places(of: text, separator: separator), text) {
            switch place {
            case .prefix:
                if character == "-" || character == "\u{2212}" { sign = -1 }
            case .integer, .fraction:
                if let digit = character.wholeNumberValue { digits += String(digit) }
            case .separator:
                digits += "."
            case .suffix:
                suffix.append(character)
            }
        }
        guard let magnitude = Double(digits) else { return nil }
        let multiplier: Double = switch suffix.first {
        case "K": 1e3
        case "M": 1e6
        case "B": 1e9
        case "T": 1e12
        default: 1
        }
        return sign * magnitude * multiplier
    }
}

/// The arc a corner readout follows: distance along it from the corner's centre, and height above the text's middle,
/// map to a point around the dial's centre. Bottom corners run the other way so their text stays upright.
struct NativeOrbitCornerArc {
    let corner: NativeOrbitComplication.Corner
    let radius: CGFloat

    private var direction: CGFloat {
        self.corner.isTop ? 1 : -1
    }

    /// The angle around the dial's centre, in radians, a distance along the arc.
    func angle(along distance: CGFloat) -> CGFloat {
        // Provider-specific by design: pi references here are geometric constants, not the Pi provider.
        CGFloat(self.corner.degrees) * CGFloat.pi / 180 + self.direction * distance / self.radius
    }

    /// How far a height above the text's middle reaches away from the dial's centre: outward on top corners, inward
    /// on bottom ones, whose glyphs stand with their tops toward the centre.
    func outward(height: CGFloat) -> CGFloat {
        self.direction * height
    }

    func point(along distance: CGFloat, height: CGFloat) -> CGPoint {
        let theta = self.angle(along: distance)
        let radial = self.radius + self.outward(height: height)
        return CGPoint(x: radial * cos(theta), y: radial * sin(theta))
    }
}

/// Only the occupied corner captures hover; the concentric gauges keep their own help targets.
struct NativeOrbitCornerRegion: Shape {
    let corner: NativeOrbitComplication.Corner

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addArc(
            center: CGPoint(x: rect.midX, y: rect.midY),
            radius: NativeOrbitComplicationStyle.radius,
            startAngle: .degrees(self.corner.degrees - 27),
            endAngle: .degrees(self.corner.degrees + 27),
            clockwise: false)
        return path.strokedPath(StrokeStyle(lineWidth: 32, lineCap: .round))
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
        NativeOrbitInstrumentElement(corner: .bottomLeading, help: self.help) {
            ZStack {
                switch self.state {
                case .inventory:
                    let glyphs = self.state.glyphs
                    let pitch = min(25, 90 / CGFloat(max(1, glyphs.count - 1)))
                    let iconSize = min(17, pitch * 0.85)
                    ForEach(Array(glyphs.enumerated()), id: \.offset) { index, banked in
                        Image(systemName: banked ? Self.symbol + ".fill" : Self.symbol)
                            .font(.system(size: iconSize, weight: .medium))
                            .foregroundStyle(banked ? self.accent : NativeOrbitComplicationStyle.idle)
                            .position(Self.position(index, count: glyphs.count, pitch: pitch))
                    }
                case .notApplicable:
                    NativeOrbitSlashableGlyph(
                        name: Self.symbol,
                        size: 17,
                        slashed: true,
                        ink: AnyShapeStyle(NativeOrbitComplicationStyle.unavailable))
                        .position(Self.position(0, count: 1, pitch: 25))
                case .unknown:
                    // The readout inks its placeholder secondary itself.
                    NativeOrbitArcText(value: "—", corner: .bottomLeading)
                }
            }
            .frame(width: 224, height: 224)
            .animation(self.reduceMotion ? nil : .smooth(duration: 0.22), value: self.state)
        }
    }

    private static func position(_ index: Int, count: Int, pitch: CGFloat) -> CGPoint {
        let degrees = 135 + (Double(index) - Double(count - 1) / 2) * Double(pitch)
            / NativeOrbitComplicationStyle.radius * 180 / .pi
        return NativeOrbitComplicationStyle.point(degrees: degrees)
    }
}

/// SF Symbols' slash modifier atop a glyph. `.symbolVariant(.slash)` silently draws the plain glyph when a symbol has
/// no slash variant (the reset and rewards-card glyphs have none), so those are composed into one template image: the
/// glyph, cut clear along the slash layer of `circle.slash`, with that slash drawn in, as the UsageIndicator component
/// draws its modifiers. Inked as one symbol, glyph and slash render alike, vibrancy in a dark popover included; a
/// slash overlaid on a masked glyph took the popover's vibrancy while the glyph lost it.
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
            } else if let slashed = Self.slashedTemplate(self.name, size: self.size, weight: self.nsWeight) {
                Image(nsImage: slashed)
                    .renderingMode(.template)
                    .foregroundStyle(self.ink)
                    .transition(.opacity)
            } else {
                self.glyph
                    .transition(.opacity)
            }
        }
    }

    private var glyph: some View {
        Image(systemName: self.name)
            .font(.system(size: self.size, weight: self.weight))
            .foregroundStyle(self.ink)
    }

    private var nsWeight: NSFont.Weight {
        switch self.weight {
        case .ultraLight: .ultraLight
        case .thin: .thin
        case .light: .light
        case .regular: .regular
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        case .black: .black
        default: .medium
        }
    }

    private struct TemplateKey: Hashable {
        let name: String
        let size: CGFloat
        let weight: CGFloat
    }

    @MainActor private static var templates: [TemplateKey: NSImage] = [:]

    /// `name` with the system slash across it, centred where the plain symbol would be, as a template image.
    @MainActor
    static func slashedTemplate(_ name: String, size: CGFloat, weight: NSFont.Weight) -> NSImage? {
        let key = TemplateKey(name: name, size: size, weight: weight.rawValue)
        if let template = self.templates[key] { return template }
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        // The palette keeps only the slash layer; the circle layer is clear.
        guard let glyph = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration),
            let slash = NSImage(systemSymbolName: "circle.slash", accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration.applying(.init(paletteColors: [.black, .clear])))
        else { return nil }
        let canvas = NSSize(
            width: max(glyph.size.width, slash.size.width),
            height: max(glyph.size.height, slash.size.height))
        func centred(_ image: NSImage, offset: CGPoint = .zero) -> NSRect {
            NSRect(
                x: (canvas.width - image.size.width) / 2 + offset.x,
                y: (canvas.height - image.size.height) / 2 + offset.y,
                width: image.size.width,
                height: image.size.height)
        }
        let gap = max(1, size * 0.06)
        let template = NSImage(size: canvas, flipped: false) { _ in
            glyph.draw(in: centred(glyph))
            // A clearance as wide as `gap` either side of the slash.
            for index in 0..<8 {
                let angle = Double(index) * Double.pi / 4
                slash.draw(
                    in: centred(slash, offset: CGPoint(x: gap * cos(angle), y: gap * sin(angle))),
                    from: .zero,
                    operation: .destinationOut,
                    fraction: 1)
            }
            slash.draw(in: centred(slash))
            return true
        }
        template.isTemplate = true
        self.templates[key] = template
        return template
    }
}
