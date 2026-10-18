import AppKit
import Testing
@testable import CodexBar

@MainActor
struct NativePageControlLayerTests {
    @Test func `resting symbols contrast with light and dark popup surfaces`() throws {
        for (appearance, surface) in [(NSAppearance.Name.aqua, CGFloat(0.94)), (.darkAqua, CGFloat(0.12))] {
            let view = NativePageControlLayerView(frame: CGRect(x: 0, y: 0, width: 240, height: 36))
            view.appearance = NSAppearance(named: appearance)
            view.update(self.artwork(selected: 0), reduceMotion: true)
            let marks = try #require(self.strip(view)?.sublayers)
            let contrasts = try marks.map { try self.contrast($0, against: surface) }
            #expect(contrasts.allSatisfy { $0 >= 3 })
            #expect(contrasts[0] > contrasts[1])
        }
    }

    @Test func `resting symbol colors follow an appearance change without a selection change`() throws {
        let view = NativePageControlLayerView(frame: CGRect(x: 0, y: 0, width: 240, height: 36))
        view.appearance = NSAppearance(named: .aqua)
        view.update(self.artwork(selected: 0), reduceMotion: true)
        view.appearance = NSAppearance(named: .darkAqua)
        view.viewDidChangeEffectiveAppearance()
        let marks = try #require(self.strip(view)?.sublayers)
        #expect(try self.contrast(marks[0], against: 0.12) >= 3)
        view.appearance = NSAppearance(named: .aqua)
        view.viewDidChangeEffectiveAppearance()
        #expect(try self.contrast(marks[0], against: 0.94) >= 3)
    }

    @Test func `scrubbing uses light symbols on its dark material in either appearance`() throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let view = NativePageControlLayerView(frame: CGRect(x: 0, y: 0, width: 240, height: 36))
            view.appearance = NSAppearance(named: appearance)
            var artwork = self.artwork(selected: 0)
            artwork.expanded = true
            view.update(artwork, reduceMotion: true)
            let marks = try #require(self.strip(view)?.sublayers)
            #expect(try marks.allSatisfy { try self.contrast($0, against: 0.12) >= 3 })
        }
    }

    @Test func `light ink and dark backing switch together without a gray crossfade`() throws {
        for configuration in [NativePageControlConfiguration(), .init(currentIndicatorTint: .orange)] {
            let view = NativePageControlLayerView(frame: CGRect(x: 0, y: 0, width: 240, height: 36))
            let window = NSWindow(contentRect: view.bounds, styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = view
            view.appearance = NSAppearance(named: .aqua)
            let resting = self.artwork(selected: 0, configuration: configuration)
            view.update(resting, reduceMotion: false)
            var held = resting
            held.expanded = true
            view.update(held, reduceMotion: false)
            let marks = try #require(self.strip(view)?.sublayers)
            let background = try #require(view.subviews.compactMap { $0 as? NSVisualEffectView }.first?.layer)
            #expect(marks.allSatisfy { $0.animation(forKey: "backgroundColor") == nil })
            #expect(background.animation(forKey: "opacity") == nil)
            #expect(background.opacity == 1)
            view.update(resting, reduceMotion: false)
            #expect(marks.allSatisfy { $0.animation(forKey: "backgroundColor") == nil })
            #expect(background.animation(forKey: "opacity") == nil)
            #expect(background.opacity == 0)
            #expect(try self.contrast(marks[1], against: 0.94) >= 3)
        }
    }

    @Test func `selection changes reuse the existing symbol masks`() throws {
        let view = NativePageControlLayerView(frame: CGRect(x: 0, y: 0, width: 240, height: 36))
        view.update(self.artwork(selected: 0), reduceMotion: false)
        let strip = try #require(self.strip(view))
        let original = try #require(strip.sublayers)
        let mask = try #require(original[1].mask)
        view.update(self.artwork(selected: 1), reduceMotion: false)
        let changed = try #require(strip.sublayers)
        #expect(changed.count == 3)
        #expect(changed[1] === original[1])
        #expect(changed[1].mask === mask)
        #expect(changed[1].backgroundColor?.alpha == 1)
        #expect((changed[0].backgroundColor?.alpha ?? 0) > 0.4)
        #expect((changed[0].backgroundColor?.alpha ?? 1) < (changed[1].backgroundColor?.alpha ?? 0))
    }

    @Test func `enabling reduced motion cancels transitions even if model values already match`() throws {
        let view = NativePageControlLayerView(frame: CGRect(x: 0, y: 0, width: 240, height: 36))
        let artwork = self.artwork(selected: 0)
        view.update(artwork, reduceMotion: true)
        let mark = try #require(self.strip(view)?.sublayers?.first)
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 0
        animation.toValue = 1
        animation.duration = 1
        mark.add(animation, forKey: "opacity")
        #expect(mark.animation(forKey: "opacity") != nil)
        view.update(artwork, reduceMotion: true)
        #expect(mark.animation(forKey: "opacity") == nil)
    }

    @Test func `reduced motion removes collapsed marks without leaving animation layers`() throws {
        let view = NativePageControlLayerView(frame: CGRect(x: 0, y: 0, width: 240, height: 36))
        view.update(self.artwork(selected: 0), reduceMotion: true)
        let strip = try #require(self.strip(view))
        view.update(self.artwork(selected: 0, count: 1), reduceMotion: true)
        let marks = try #require(strip.sublayers)
        #expect(marks.count == 1)
        #expect(marks[0].animationKeys()?.isEmpty != false)
        #expect(marks[0].opacity == 1)
        #expect(marks[0].position == CGPoint(x: 120.5, y: 18))
        #expect(view.hitTest(CGPoint(x: 120, y: 18)) == nil)
    }

    @Test func `changing a current-page symbol replaces its mask without retaining obsolete artwork`() throws {
        let view = NativePageControlLayerView(frame: CGRect(x: 0, y: 0, width: 240, height: 36))
        let initial = self.artwork(selected: 1)
        view.update(initial, reduceMotion: true)
        let strip = try #require(self.strip(view))
        let previous = try #require(strip.sublayers?.first)
        var configuration = NativePageControlConfiguration()
        configuration.preferredCurrentSymbol = "sun.max.fill"
        view.update(self.artwork(selected: 0, configuration: configuration), reduceMotion: true)
        let current = try #require(strip.sublayers)
        #expect(current.count == 3)
        #expect(!current.contains { $0 === previous })
        #expect(previous.superlayer == nil)
    }

    private func strip(_ view: NativePageControlLayerView) -> CALayer? {
        func find(_ layer: CALayer) -> CALayer? {
            if layer.name == "CodexBar.PageControl.Symbols" { return layer }
            return layer.sublayers?.compactMap(find).first
        }
        return ([view.layer] + view.subviews.map(\.layer)).compactMap(\.self).compactMap(find).first
    }

    private func contrast(_ mark: CALayer, against background: CGFloat) throws -> CGFloat {
        let cgColor = try #require(mark.backgroundColor)
        let color = try #require(NSColor(cgColor: cgColor)?.usingColorSpace(.deviceRGB))
        func luminance(_ value: CGFloat) -> CGFloat {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let alpha = color.alphaComponent
        let ink = 0.2126 * luminance(color.redComponent * alpha + background * (1 - alpha))
            + 0.7152 * luminance(color.greenComponent * alpha + background * (1 - alpha))
            + 0.0722 * luminance(color.blueComponent * alpha + background * (1 - alpha))
        let paper = luminance(background)
        return (max(ink, paper) + 0.05) / (min(ink, paper) + 0.05)
    }

    private func artwork(
        selected: Int,
        count: Int = 3,
        configuration: NativePageControlConfiguration = .init()) -> NativePageControlArtwork
    {
        let indicators = (0..<count).map { index in
            NativeCombinedAccounts.Indicator(
                id: String(index),
                targetID: String(index),
                provider: nil,
                symbol: ["house", "briefcase", "leaf"][index],
                label: "Fixture",
                selected: index == selected)
        }
        return NativePageControlArtwork(
            indicators: indicators,
            layout: NativePageControlLayout(
                count: count,
                selection: selected,
                availableLength: 240,
                symbolWidths: indicators.map { NativePageControlSymbol($0, configuration: configuration).size.width }),
            configuration: configuration)
    }
}
