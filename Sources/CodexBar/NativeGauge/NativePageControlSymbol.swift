import AppKit
import SwiftUI

/// UIPageControl configures custom symbol images as Footnote / Small and retains each symbol's natural width.
@MainActor
struct NativePageControlSymbol {
    private static var images: [String: NativePageControlSymbol] = [:]
    let image: NSImage
    let size: CGSize

    init(_ indicator: NativeCombinedAccounts.Indicator, configuration: NativePageControlConfiguration) {
        let selectedSymbol = indicator.selected ? indicator.currentSymbol ?? configuration.preferredCurrentSymbol : nil
        let name = selectedSymbol ?? indicator.symbol ?? configuration.preferredSymbol
        let key = selectedSymbol ??
            (indicator.accountID == nil ? indicator.provider.map { "provider:\($0.rawValue)" } : nil)
            ?? name ?? "circle.fill"
        if let cached = Self.images[key] {
            self = cached
            return
        }
        let source: NSImage? = if let selectedSymbol {
            Self.image(named: selectedSymbol)
        } else if let provider = indicator.provider, indicator.accountID == nil {
            NativeProviderSymbol.image(for: provider, pointSize: 13)
        } else {
            name.flatMap(Self.image(named:))
        }
        let symbol = source ?? NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)!
        let font = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular, scale: .small)
        let configured = symbol.withSymbolConfiguration(font)
        self.image = configured ?? symbol
        self.size = NativePageControlImageMetrics.size(
            self.image.size,
            alignmentWidth: self.image.alignmentRect.width,
            isSymbol: configured != nil)
        if !key.hasPrefix("account.website.") { Self.images[key] = self }
    }

    private static func image(named name: String) -> NSImage? {
        if name.hasPrefix("account.website.") { return NativeOrbitBadgeResolver.websiteIcons.image(for: name) }
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)
            ?? NSImage(named: name) ?? Bundle.main.image(forResource: name) ?? Bundle.module.image(forResource: name)
    }
}
