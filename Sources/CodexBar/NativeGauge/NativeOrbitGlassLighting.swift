import SwiftUI

/// Stationary reflections give the native material depth without changing the quota silhouette.
struct NativeOrbitGlassLighting: View {
    let lane: Int
    let remaining: Double
    let size: CGFloat

    private var reflection: Color {
        Color.white.exposureAdjust(0.6).headroom(1.52)
    }

    var body: some View {
        let shape = NativeOrbitArtworkShape(lane: self.lane, remaining: self.remaining)
        let scale = self.size / NativeOrbitSymbol.canvas
        let radius = NativeOrbitSymbol.radii[min(2, max(0, self.lane))] * scale
        let halfWidth = NativeOrbitSymbol.stroke * scale / 2
        ZStack {
            // A curved cross-section: a shaded inner lip and a bright outer shoulder.
            shape.fill(RadialGradient(
                stops: [
                    .init(color: .black.opacity(0.18), location: 0),
                    .init(color: self.reflection.opacity(0.24), location: 0.13),
                    .init(color: .clear, location: 0.38),
                    .init(color: .clear, location: 0.60),
                    .init(color: self.reflection.opacity(0.36), location: 0.87),
                    .init(color: self.reflection.opacity(0.12), location: 1),
                ],
                center: .center,
                startRadius: radius - halfWidth,
                endRadius: radius + halfWidth))
                .mask(LinearGradient(
                    colors: [.white, .white.opacity(0.24), .white.opacity(0.65)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing))

            // Keep the brightest reflection narrow so the colored body remains readable.
            shape.stroke(LinearGradient(
                stops: [
                    .init(color: self.reflection.opacity(0.88), location: 0),
                    .init(color: self.reflection.opacity(0.52), location: 0.28),
                    .init(color: .white.opacity(0.06), location: 0.55),
                    .init(color: self.reflection.opacity(0.36), location: 1),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing), lineWidth: max(0.5, scale))
                .mask(shape)
        }
        .frame(width: self.size, height: self.size)
        .allowedDynamicRange(.constrainedHigh)
    }
}
