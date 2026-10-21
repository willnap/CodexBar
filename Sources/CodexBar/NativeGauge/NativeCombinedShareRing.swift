import SwiftUI

/// The combined overview's dial: each account's share of the range's tokens as one rounded glass island on the
/// outer lane of the account dials, in that account's colour and marked with its service.
struct NativeCombinedShareRing: View {
    struct Segment: Identifiable, Equatable {
        let id: String
        let fraction: Double
        let accent: Color
        let productID: String
        let help: String
    }

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let segments: [Segment]
    var size: CGFloat = 216

    private var scale: CGFloat {
        self.size / NativeOrbitSymbol.canvas
    }

    private var radius: CGFloat {
        NativeOrbitSymbol.radii[0] * self.scale
    }

    private var width: CGFloat {
        NativeOrbitSymbol.stroke * self.scale
    }

    /// Clear space between neighbouring islands, along the lane's centre line.
    private var gap: CGFloat {
        6 * self.scale
    }

    private var arcs: [(segment: Segment, start: Angle, end: Angle)] {
        let gapAngle = self.segments.count > 1 ? Double(self.gap / self.radius) : 0
        var start = -Double.pi / 2
        return self.segments.map { segment in
            let sweep = segment.fraction * 2 * Double.pi
            defer { start += sweep }
            return (
                segment,
                .radians(start + gapAngle / 2),
                .radians(start + max(gapAngle / 2, sweep - gapAngle / 2)))
        }
    }

    var body: some View {
        let arcs = self.arcs
        ZStack {
            NativeCombinedShareShape(
                start: .zero,
                end: .degrees(360),
                radius: self.radius,
                width: self.width,
                corner: 0)
                .fill(Color.primary.opacity(self.reduceTransparency ? 0.10 : 0.035))
            GlassEffectContainer(spacing: 0) {
                ZStack {
                    ForEach(arcs, id: \.segment.id) { arc in
                        self.material(
                            NativeCombinedShareShape(
                                start: arc.start,
                                end: arc.end,
                                radius: self.radius,
                                width: self.width,
                                corner: NativeOrbitSymbol.cutCorner * self.scale),
                            accent: arc.segment.accent)
                    }
                }
            }
            ForEach(arcs, id: \.segment.id) { arc in
                self.mark(arc.segment, start: arc.start, end: arc.end)
            }
        }
        .frame(width: self.size, height: self.size)
    }

    @ViewBuilder
    private func material(_ shape: NativeCombinedShareShape, accent: Color) -> some View {
        if self.reduceTransparency {
            shape.fill(accent)
        } else {
            shape.fill(.clear)
                .glassEffect(.clear.tint(accent.opacity(0.8)), in: shape)
                .allowedDynamicRange(.high)
        }
    }

    /// The service's mark at the island's middle, where it fits, and the island's reading on hover.
    private func mark(_ segment: Segment, start: Angle, end: Angle) -> some View {
        let middle = (start.radians + end.radians) / 2
        let fits = (end.radians - start.radians) * Double(self.radius) >= 18
        return ZStack {
            if fits {
                Image(NativeOrbitProviderArtwork.name(for: segment.productID))
                    .resizable().scaledToFit()
                    .frame(width: 10, height: 10)
                    .opacity(0.85)
                    .offset(x: cos(middle) * self.radius, y: sin(middle) * self.radius)
                    .allowsHitTesting(false)
            }
            NativeCombinedShareShape(start: start, end: end, radius: self.radius, width: self.width, corner: 0)
                .fill(Color.clear)
                .contentShape(NativeCombinedShareShape(
                    start: start, end: end, radius: self.radius, width: self.width, corner: 0))
                .help(segment.help)
        }
        .accessibilityElement()
        .accessibilityLabel(segment.help)
    }
}

/// An annular sector of the ring, its four corners rounded like the dial's cut ends.
struct NativeCombinedShareShape: Shape {
    let start: Angle
    let end: Angle
    let radius: CGFloat
    let width: CGFloat
    let corner: CGFloat

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = self.radius + self.width / 2
        let inner = self.radius - self.width / 2
        guard (self.end - self.start).degrees < 359.9 else {
            var ring = Path()
            ring.addEllipse(in: CGRect(x: center.x - outer, y: center.y - outer, width: 2 * outer, height: 2 * outer))
            ring.addEllipse(in: CGRect(x: center.x - inner, y: center.y - inner, width: 2 * inner, height: 2 * inner))
            return ring.normalized(eoFill: true)
        }
        let corner = min(self.corner, self.width / 2, (self.end.radians - self.start.radians) * Double(inner) / 2)
        // Angular room each rounded corner takes on its rail.
        let outerInset = Angle.radians(corner / outer)
        let innerInset = Angle.radians(corner / inner)
        func point(_ radius: CGFloat, _ angle: Angle) -> CGPoint {
            CGPoint(x: center.x + cos(angle.radians) * radius, y: center.y + sin(angle.radians) * radius)
        }
        var path = Path()
        path.move(to: point(outer - corner, self.start))
        path.addQuadCurve(to: point(outer, self.start + outerInset), control: point(outer, self.start))
        path.addArc(
            center: center,
            radius: outer,
            startAngle: self.start + outerInset,
            endAngle: self.end - outerInset,
            clockwise: false)
        path.addQuadCurve(to: point(outer - corner, self.end), control: point(outer, self.end))
        path.addLine(to: point(inner + corner, self.end))
        path.addQuadCurve(to: point(inner, self.end - innerInset), control: point(inner, self.end))
        path.addArc(
            center: center,
            radius: inner,
            startAngle: self.end - innerInset,
            endAngle: self.start + innerInset,
            clockwise: true)
        path.addQuadCurve(to: point(inner + corner, self.start), control: point(inner, self.start))
        path.closeSubpath()
        return path
    }
}
