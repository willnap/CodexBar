import AppKit
import CoreText
import Foundation
import SwiftUI
import Testing
@testable import CodexBar

struct NativeOrbitReadoutNumberTests {
    private typealias Number = NativeOrbitReadoutNumber

    @Test func `places count away from the decimal separator`() {
        #expect(Number.places(of: "$1,234.56", separator: ".") == [
            .prefix(0),
            .integer(4), .integer(3), .integer(2), .integer(1), .integer(0),
            .separator,
            .fraction(0), .fraction(1),
        ])
        #expect(Number.places(of: "12.34 credits", separator: ".") == [
            .integer(1), .integer(0), .separator, .fraction(0), .fraction(1),
            .suffix(0), .suffix(1), .suffix(2), .suffix(3), .suffix(4), .suffix(5), .suffix(6), .suffix(7),
        ])
        #expect(Number.places(of: "US$5", separator: ".") == [.prefix(2), .prefix(1), .prefix(0), .integer(0)])
        #expect(Number.places(of: "—", separator: ".") == [.prefix(0)])
    }

    @Test func `the locale's decimal separator decides which separator is decimal`() {
        #expect(Number.value(in: "1.234,5 €", separator: ",") == 1234.5)
        #expect(Number.value(in: "1,5K", separator: ",") == 1500)
    }

    @Test func `readouts parse to their values including compact suffixes`() {
        #expect(Number.value(in: "$1,234.5", separator: ".") == 1234.5)
        #expect(Number.value(in: "1.5K", separator: ".") == 1500)
        #expect(Number.value(in: "2.5M", separator: ".") == 2_500_000)
        #expect(Number.value(in: "2B", separator: ".") == 2_000_000_000)
        #expect(Number.value(in: "12.5 credits", separator: ".") == 12.5)
        #expect(Number.value(in: "-$4.25", separator: ".") == -4.25)
        #expect(Number.value(in: "—", separator: ".") == nil)
    }

    @Test func `the transition rolls by the caller's number, else the readout's, from zero when there is none`() {
        // A count crossing into billions rolls up although "1.2B" reads smaller than "276.7M" digit by digit.
        #expect(NativeOrbitArcText.transitionValue("1.2B", numericValue: nil)
            > NativeOrbitArcText.transitionValue("276.7M", numericValue: nil))
        #expect(NativeOrbitArcText.transitionValue("$9.99", numericValue: 12) == 12)
        #expect(NativeOrbitArcText.transitionValue("—", numericValue: nil) == 0)
    }
}

/// The corner readouts as SwiftUI sets and draws them on the dial.
@MainActor
struct NativeOrbitArcTextTests {
    private typealias Corner = NativeOrbitComplication.Corner

    @Test func `numeric text animates its first change and changes after a pause but rapid scrubs are immediate`() {
        let cadence = NativeOrbitReadoutCadence(initialValue: "10")
        let interval = NativeOrbitReadoutCadence.scrubInterval
        var first = Transaction(animation: nil)
        cadence.prepareTransaction(&first, value: "11", now: 10, reduceMotion: false)
        #expect(first.animation == .smooth(duration: NativeOrbitReadoutCadence.animationDuration))
        #expect(!first.disablesAnimations)
        var rapid = Transaction(animation: .smooth(duration: 3))
        cadence.prepareTransaction(&rapid, value: "12", now: 10 + interval / 2, reduceMotion: false)
        #expect(rapid.animation == nil)
        #expect(rapid.disablesAnimations)
        var paused = Transaction(animation: nil)
        cadence.prepareTransaction(&paused, value: "13", now: 10 + interval * 2, reduceMotion: false)
        #expect(paused.animation == .smooth(duration: NativeOrbitReadoutCadence.animationDuration))
        #expect(!paused.disablesAnimations)
    }

    @Test func `repeated transaction passes do not change numeric cadence or restart its pause clock`() {
        let cadence = NativeOrbitReadoutCadence(initialValue: "10")
        let interval = NativeOrbitReadoutCadence.scrubInterval
        var first = Transaction()
        cadence.prepareTransaction(&first, value: "11", now: 0, reduceMotion: false)
        var repeated = Transaction()
        cadence.prepareTransaction(&repeated, value: "11", now: interval * 0.75, reduceMotion: false)
        #expect(repeated.animation != nil)
        #expect(!repeated.disablesAnimations)
        var threshold = Transaction()
        cadence.prepareTransaction(&threshold, value: "12", now: interval, reduceMotion: false)
        #expect(threshold.animation != nil)
        #expect(!threshold.disablesAnimations)
        var rapid = Transaction()
        cadence.prepareTransaction(&rapid, value: "13", now: interval * 1.5, reduceMotion: false)
        var repeatedRapid = Transaction(animation: .smooth(duration: 3))
        cadence.prepareTransaction(&repeatedRapid, value: "13", now: interval * 3, reduceMotion: false)
        #expect(repeatedRapid.animation == nil)
        #expect(repeatedRapid.disablesAnimations)
    }

    @Test func `reduced motion suppresses first and slow numeric transitions and upstream disabling is respected`() {
        let cadence = NativeOrbitReadoutCadence(initialValue: "10")
        for (value, now) in [("11", 0.0), ("12", 10.0)] {
            var transaction = Transaction(animation: .smooth(duration: 3))
            cadence.prepareTransaction(&transaction, value: value, now: now, reduceMotion: true)
            #expect(transaction.animation == nil)
            #expect(transaction.disablesAnimations)
        }
        var disabled = Transaction()
        disabled.disablesAnimations = true
        cadence.prepareTransaction(&disabled, value: "13", now: 20, reduceMotion: false)
        #expect(disabled.animation == nil)
        #expect(disabled.disablesAnimations)
    }

    @Test func `tabular figures keep the characters a change keeps where they were`() {
        // SF Rounded's own figures run from 7.87pt for a 1 to 10.61pt for a 0.
        for monospaced in [false, true] {
            let font = NativeOrbitArcText.font(monospaced: monospaced, size: 16)
            for (old, new) in [("$84.18", "$84.98"), ("$1.11", "$7.77"), ("$10.00", "$19.91"), ("276.7M", "111.1M")] {
                #expect(Self.offsets(old, font: font) == Self.offsets(new, font: font), "\(old) to \(new)")
            }
        }
    }

    @Test func `immutable arc fonts preserve each size design and tabular glyph metrics`() {
        for monospaced in [false, true] {
            for size: CGFloat in [8, 12, 16, 24, 32] {
                let reference: NSFont
                if monospaced {
                    reference = NSFont.monospacedSystemFont(ofSize: size, weight: .semibold)
                } else {
                    let base = NSFont.systemFont(ofSize: size, weight: .semibold)
                    let rounded = base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor
                    let tabular = rounded.addingAttributes([.featureSettings: [[
                        NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                        NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
                    ]]])
                    reference = NSFont(descriptor: tabular, size: size) ?? base
                }
                let font = NativeOrbitArcText.font(monospaced: monospaced, size: size)
                #expect(font === NativeOrbitArcText.font(monospaced: monospaced, size: size))
                #expect(font.pointSize == size)
                #expect(font.fontDescriptor == reference.fontDescriptor)
                for text in ["$84.18", "CA$1,234.56", "12.34 credits", "276.7M", "—"] {
                    #expect(Self.offsets(text, font: font) == Self.offsets(text, font: reference))
                }
            }
        }
    }

    @Test func `a readout at rest sits where CoreText sets the line, bent onto the arc, uncut`() throws {
        // The longest readouts reach past the 224pt dial frame ("A$1,234.56" by most at the bottom corners).
        let readouts: [(value: String, monospaced: Bool)] = [
            ("$84.18", false), ("CA$1,234.56", false), ("12.34 credits", false), ("A$1,234.56", false),
            ("NT$1,234.56", false), ("276.7M", true), ("—", false),
        ]
        for readout in readouts {
            for corner in [Corner.topLeading, .topTrailing, .bottomLeading, .bottomTrailing] {
                let drawn = try Self.alpha(NativeOrbitArcText(
                    value: readout.value,
                    corner: corner,
                    monospaced: readout.monospaced))
                let expected = try Self.alpha(ReferenceLine(
                    value: readout.value,
                    corner: corner,
                    monospaced: readout.monospaced)
                    .fill(readout.value == NativeOrbitArcText.placeholder ? NativeOrbitComplicationStyle
                        .unavailable : Color.primary))
                let (drawnCentre, drawnInk) = Self.centroid(drawn)
                let (expectedCentre, expectedInk) = Self.centroid(expected)
                // Within a point of the reference (2px at 2x), and all of it: a clipped glyph would lose ink. Text
                // rasterizes a little heavier than a filled outline.
                let offset = hypot(drawnCentre.x - expectedCentre.x, drawnCentre.y - expectedCentre.y)
                #expect(offset < 2, "\(readout.value) at \(corner) is \(offset)px off")
                #expect(
                    drawnInk > expectedInk * 0.95 && drawnInk < expectedInk * 1.2,
                    "\(readout.value) at \(corner): \(drawnInk) against \(expectedInk)")
            }
        }
    }

    private static func offsets(_ text: String, font: NSFont) -> [CGFloat] {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        return (0...text.utf16.count).map { CTLineGetOffsetForStringIndex(line, $0, nil) }
    }

    /// The alpha-weighted centre of what was drawn, in pixels, and the total ink.
    private static func centroid(_ alpha: [UInt8]) -> (CGPoint, Double) {
        let width = 600
        var x = 0.0, y = 0.0, ink = 0.0
        for (index, value) in alpha.enumerated() where value > 0 {
            let weight = Double(value)
            x += Double(index % width) * weight
            y += Double(index / width) * weight
            ink += weight
        }
        return (CGPoint(x: x / max(1, ink), y: y / max(1, ink)), ink / 255)
    }

    /// Each pixel's alpha, drawn at 2x in a 300pt frame with room around the dial.
    private static func alpha(_ view: some View) throws -> [UInt8] {
        let renderer = ImageRenderer(content: view.frame(width: 300, height: 300))
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        #expect(drawn)
        return stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] }
    }
}

/// The corners' line as CoreText sets it, every glyph outline bent onto the arc around the frame's centre.
private struct ReferenceLine: Shape {
    let value: String
    let corner: NativeOrbitComplication.Corner
    let monospaced: Bool

    func path(in rect: CGRect) -> Path {
        let lineFont = NativeOrbitArcText.font(monospaced: self.monospaced, size: 16)
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: self.value,
            attributes: [.font: lineFont]))
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let scale = min(1, 118 * 0.75 / max(1, width))
        let arc = NativeOrbitCornerArc(corner: self.corner, radius: 118)
        var path = Path()
        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var origins = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &origins)
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let font = (attributes[kCTFontAttributeName] as? NSFont ?? lineFont) as CTFont
            let middle = CTFontGetCapHeight(font) / 2
            for (glyph, origin) in zip(glyphs, origins) {
                guard let outline = CTFontCreatePathForGlyph(font, glyph, nil) else { continue }
                func point(_ source: CGPoint) -> CGPoint {
                    let bent = arc.point(
                        along: (origin.x + source.x - width / 2) * scale,
                        height: (origin.y + source.y - middle) * scale)
                    return CGPoint(x: rect.midX + bent.x, y: rect.midY + bent.y)
                }
                // Path is not a Sequence; its forEach walks the outline's elements.
                // swiftformat:disable:next preferForLoop
                Path(outline).forEach { element in
                    switch element {
                    case let .move(to): path.move(to: point(to))
                    case let .line(to): path.addLine(to: point(to))
                    case let .quadCurve(to, control): path.addQuadCurve(to: point(to), control: point(control))
                    case let .curve(to, control1, control2):
                        path.addCurve(to: point(to), control1: point(control1), control2: point(control2))
                    case .closeSubpath: path.closeSubpath()
                    }
                }
            }
        }
        return path
    }
}
