import AppKit

/// Retain the reviewed popup artwork where available, otherwise use the provider's native optical symbol.
@MainActor
enum NativeOrbitProviderArtwork {
    static func name(
        for product: String,
        assetExists: (String) -> Bool = { NSImage(named: NSImage.Name($0)) != nil }) -> String
    {
        let product = UsageProduct.canonicalID(product)
        // Provider-specific by design: the parent mark uses Claude’s established spark, while
        // Claude Code retains its separate product glyph and the company name remains Anthropic.
        let original = product == "anthropic" ? "provider.claude" : "provider.\(product)"
        if assetExists(original) { return original }
        return ServiceIdentity.find(product)?.symbol(22) ?? original
    }
}
