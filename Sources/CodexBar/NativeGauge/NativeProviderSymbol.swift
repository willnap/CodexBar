import AppKit
import CodexBarCore
import SwiftUI

@MainActor
enum NativeProviderSymbol {
    static func image(for provider: UsageProvider, pointSize: CGFloat = 18) -> NSImage? {
        let name = ServiceIdentity.find(provider.rawValue)?.symbol(Double(pointSize))
        let symbol = name.flatMap { name in
            NSImage(named: name)
                ?? Bundle.main.image(forResource: name)
                ?? Bundle.module.image(forResource: name)
        } ?? NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: nil)
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        let image = symbol?.withSymbolConfiguration(configuration) ?? symbol
        image?.isTemplate = true
        return image
    }
}

/// Use the same optical sizing and alignment as the menu bar's reviewed identity specimens.
struct NativeProviderSymbolView: View {
    let provider: UsageProvider
    var size: Double = 18

    var body: some View {
        if let service = ServiceIdentity.find(self.provider.rawValue) {
            ServiceIdentityIcon(service: service, size: self.size, monochrome: true)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: self.size * 0.7))
                .frame(width: self.size, height: self.size)
                .accessibilityHidden(true)
        }
    }
}
