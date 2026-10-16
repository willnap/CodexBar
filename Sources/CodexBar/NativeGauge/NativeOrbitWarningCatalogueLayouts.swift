import AppKit

/// Offline solutions of the existing catalogue packing problem for every production identity and money frame.
/// Coordinates retain the established layout. A glyph-bound guard rejects them when system artwork changes.
/// Generated on macOS 27.0.1; regenerate with Scripts/generate_warning_catalogue_layouts.py.
@MainActor
enum NativeOrbitWarningCatalogueLayouts {
    static func positions(for key: String, bounds: [CGRect], symbolScale: CGFloat) -> [CGPoint]? {
        guard let coordinates = self.coordinates[key], bounds.count == self.inkBounds.count,
              coordinates.count == bounds.count * 2 else { return nil }
        for (current, expected) in zip(bounds, self.inkBounds) {
            guard abs(current.minX * symbolScale - expected.minX) < 0.001,
                  abs(current.minY * symbolScale - expected.minY) < 0.001,
                  abs(current.width * symbolScale - expected.width) < 0.001,
                  abs(current.height * symbolScale - expected.height) < 0.001 else { return nil }
        }
        return stride(from: 0, to: coordinates.count, by: 2).map {
            CGPoint(x: coordinates[$0], y: coordinates[$0 + 1])
        }
    }
}
