import AppKit
import SwiftUI

/// UIPageControl configures custom symbol images as Footnote / Small and retains each symbol's natural width.
/// System symbols all keep that one size. Custom art (provider marks, mail and project symbols, website masks) is
/// drawn to fill a fixed box, so a wide mark came out short and small beside the system ones; it is scaled to cover
/// the same ink area a system symbol of its weight does.
@MainActor
struct NativePageControlSymbol {
    static let pointSize: CGFloat = 13
    /// A system circle's ink at that size: custom marks cover the same area, the way SF Symbols balance shapes.
    nonisolated static let opticalSide: CGFloat = 11
    /// The widest system marks at that size (house, envelope) stop about here.
    nonisolated static let maximumInk: CGFloat = 14

    private static var images: [String: NativePageControlSymbol] = [:]
    private static var websiteImages: [String: (source: NSImage, symbol: NativePageControlSymbol)] = [:]
    let image: NSImage
    let size: CGSize
    /// How far the drawn ink's center sits from the image's center (y downward). Marks are placed by their ink, so
    /// glyphs whose art is padded unevenly still line up with the rest.
    private(set) var inkOffset: CGSize = .zero

    init(_ indicator: NativeCombinedAccounts.Indicator, configuration: NativePageControlConfiguration) {
        let selectedSymbol = indicator.selected ? indicator.currentSymbol ?? configuration.preferredCurrentSymbol : nil
        let name = selectedSymbol ?? indicator.symbol ?? configuration.preferredSymbol
        let key = selectedSymbol ??
            (indicator.accountID == nil ? indicator.provider.map { "provider:\($0.rawValue)" } : nil)
            ?? name ?? "circle.fill"
        if key.hasPrefix("account.website.") {
            guard let source = NativeOrbitBadgeResolver.websiteIcons.image(for: key) else {
                self.init(system: "globe")
                return
            }
            if let cached = Self.websiteImages[key], cached.source === source {
                self = cached.symbol
                return
            }
            self.init(artwork: source)
            Self.websiteImages[key] = (source, self)
            return
        }
        if let cached = Self.images[key] {
            self = cached
            return
        }
        if let provider = indicator.provider, indicator.accountID == nil, selectedSymbol == nil {
            if let mark = NativeProviderSymbol.image(for: provider, pointSize: Self.pointSize) {
                self.init(custom: mark)
            } else {
                self.init(system: "square.stack.3d.up")
            }
        } else if let name, NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil {
            self.init(system: name)
        } else if let name, let custom = NSImage(named: name) ?? Bundle.main.image(forResource: name)
            ?? Bundle.module.image(forResource: name)
        {
            self.init(custom: custom)
        } else {
            self.init(system: "circle.fill")
        }
        Self.images[key] = self
    }

    private init(system name: String) {
        let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)!
        self.init(symbol: symbol, scale: 1)
    }

    /// A custom symbol, reconfigured at the point size that gives its ink a system symbol's optical area.
    private init(custom symbol: NSImage) {
        let measured = symbol.withSymbolConfiguration(Self.configuration(scale: 1)).flatMap(Self.ink)
        self.init(symbol: symbol, scale: measured.map { Self.opticalScale($0.size) } ?? 1)
    }

    private init(symbol: NSImage, scale: CGFloat) {
        let configured = symbol.withSymbolConfiguration(Self.configuration(scale: scale))
        self.image = configured ?? symbol
        self.size = NativePageControlImageMetrics.size(
            self.image.size,
            alignmentWidth: self.image.alignmentRect.width,
            isSymbol: configured != nil)
        self.inkOffset = Self.offset(of: Self.ink(self.image), in: self.image.size, drawnAt: self.size)
    }

    private static func offset(of ink: CGRect?, in imageSize: CGSize, drawnAt size: CGSize) -> CGSize {
        guard let ink, imageSize.width > 0, imageSize.height > 0 else { return .zero }
        return CGSize(
            width: (ink.midX - imageSize.width / 2) * size.width / imageSize.width,
            height: (ink.midY - imageSize.height / 2) * size.height / imageSize.height)
    }

    /// A bitmap mask: its drawn size is chosen from its ink, so its empty margins scale with it.
    private init(artwork: NSImage) {
        self.image = artwork
        guard let ink = Self.ink(artwork), ink.width > 0, ink.height > 0 else {
            self.size = NativePageControlImageMetrics.size(artwork.size, alignmentWidth: 0, isSymbol: false)
            return
        }
        let scale = Self.opticalScale(ink.size)
        self.size = CGSize(width: artwork.size.width * scale, height: artwork.size.height * scale)
        self.inkOffset = Self.offset(of: ink, in: artwork.size, drawnAt: self.size)
    }

    private static func configuration(scale: CGFloat) -> NSImage.SymbolConfiguration {
        NSImage.SymbolConfiguration(
            pointSize: (self.pointSize * scale * 2).rounded() / 2,
            weight: .regular,
            scale: .small)
    }

    /// The factor that makes ink of this size cover a system circle's area, without passing the widest system mark.
    nonisolated static func opticalScale(_ ink: CGSize) -> CGFloat {
        guard ink.width > 0, ink.height > 0 else { return 1 }
        return min(
            self.opticalSide / (ink.width * ink.height).squareRoot(),
            self.maximumInk / max(ink.width, ink.height))
    }

    /// The image's drawn ink, in points from its top left, ignoring its transparent margins.
    static func ink(_ image: NSImage) -> CGRect? {
        let density: CGFloat = 4
        let width = Int((image.size.width * density).rounded(.up))
        let height = Int((image.size.height * density).rounded(.up))
        var rect = CGRect(x: 0, y: 0, width: width, height: height)
        guard width > 0, height > 0, width <= 4096, height <= 4096,
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: width,
                  space: CGColorSpaceCreateDeviceGray(),
                  bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue),
              let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let data = context.data
        else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        let alpha = data.assumingMemoryBound(to: UInt8.self)
        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height {
            for x in 0..<width where alpha[y * width + x] > 38 {
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        // A bitmap context's first row is the image's top.
        return CGRect(
            x: CGFloat(minX) / density,
            y: CGFloat(minY) / density,
            width: CGFloat(maxX - minX + 1) / density,
            height: CGFloat(maxY - minY + 1) / density)
    }
}
