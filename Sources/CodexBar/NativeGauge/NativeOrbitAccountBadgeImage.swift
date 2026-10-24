import SwiftUI

/// Fit native/custom symbols and cached website masks to the same tinted account-badge slot.
struct NativeOrbitAccountBadgeImage: View {
    let symbol: String

    var body: some View {
        Group {
            if self.symbol.hasPrefix("account.website.") {
                if let image = NativeOrbitBadgeResolver.websiteIcons.image(for: self.symbol) {
                    Image(nsImage: image).resizable().renderingMode(.template).scaledToFit()
                } else {
                    Image(systemName: "globe").resizable().scaledToFit()
                }
            } else if self.symbol.hasPrefix("account.") {
                Image(self.symbol).renderingMode(.template).resizable().scaledToFit()
            } else {
                Image(systemName: self.symbol).resizable().scaledToFit().symbolVariant(.fill)
            }
        }
        .frame(width: 15, height: 15)
        .symbolRenderingMode(.monochrome)
        .accessibilityHidden(true)
    }
}
