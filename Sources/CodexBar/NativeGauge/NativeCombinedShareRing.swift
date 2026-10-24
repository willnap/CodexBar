import SwiftUI

/// The combined overview's dial: each account's share of the range's tokens as one rounded glass island on the
/// outer lane of the account dials, in that account's colour and marked with its service.
struct NativeCombinedShareRing: View {
    struct Segment: Identifiable, Equatable {
        let id: String
        let fraction: Double
        let accent: Color
        let productID: String
        var companyID: String?
        var accountSymbol: String?
        let help: String
    }

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let segments: [Segment]
    var size: CGFloat = 216

    private var scale: CGFloat {
        self.size / NativeOrbitSymbol.canvas
    }

    private var radius: CGFloat {
        90 * self.scale
    }

    private var width: CGFloat {
        54 * self.scale
    }

    /// One physical separator width, measured perpendicular to each boundary at both rails.
    var gap: CGFloat {
        let positive = self.segments.map(\.fraction).filter { $0 > 0 }
        guard positive.count > 1 else { return 0 }
        // Each sector limits its own cut if necessary. A tiny account must not close every other separator.
        return 4 * self.scale
    }

    private var arcs: [(segment: Segment, start: Angle, end: Angle)] {
        var start = -Double.pi / 2
        return self.segments.map { segment in
            let sweep = segment.fraction * 2 * Double.pi
            defer { start += sweep }
            return (
                segment,
                .radians(start),
                .radians(start + sweep))
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
                        NativeCombinedShareSector(
                            segment: arc.segment,
                            start: arc.start.radians,
                            end: arc.end.radians,
                            gap: self.gap,
                            radius: self.radius,
                            width: self.width,
                            scale: self.scale,
                            size: self.size)
                    }
                }
            }
        }
        .frame(width: self.size, height: self.size)
    }
}

/// Interpolate angles once. The glass silhouette and every icon consume that same presentation geometry;
/// icons follow the circle instead of interpolating Cartesian offsets through the neighboring bands.
struct NativeCombinedShareSector: View, Animatable {
    let segment: NativeCombinedShareRing.Segment
    nonisolated var start: Double
    nonisolated var end: Double
    nonisolated var gap: CGFloat
    let radius: CGFloat
    let width: CGFloat
    let scale: CGFloat
    let size: CGFloat

    nonisolated var animatableData: AnimatablePair<AnimatablePair<Double, Double>, CGFloat> {
        get { .init(.init(self.start, self.end), self.gap) }
        set {
            self.start = newValue.first.first
            self.end = newValue.first.second
            self.gap = newValue.second
        }
    }

    var shape: NativeCombinedShareShape {
        NativeCombinedShareShape(
            start: .radians(self.start),
            end: .radians(self.end),
            radius: self.radius,
            width: self.width,
            corner: NativeOrbitSymbol.cutCorner * self.scale,
            gap: self.gap)
    }

    var body: some View {
        let middle = (self.start + self.end) / 2
        let available = max(0, CGFloat(self.end - self.start) * self.radius - self.gap - 8 * self.scale)
        return ZStack {
            ZStack {
                self.identity(available: available)
            }
            .frame(width: self.size, height: self.size)
            // Leave the foreground unset so native glass supplies its adaptive vibrant ink to every template icon.
            .glassEffect(.regular.tint(self.segment.accent.opacity(0.8)), in: self.shape)
            .allowedDynamicRange(.high)
            .allowsHitTesting(false)
            self.shape.fill(Color.clear).contentShape(self.shape).help(self.segment.help)
        }
        .environment(\.nativeCombinedIdentityAngle, middle)
        .accessibilityElement()
        .accessibilityLabel(self.segment.help)
        .accessibilityHidden(self.segment.fraction <= 0)
        // A second implicit animation toward each intermediate angle would leave glass and ink trailing behind.
        .transaction { $0.animation = nil }
    }

    @ViewBuilder
    private func identity(available: CGFloat) -> some View {
        let layout = NativeCombinedRingIdentityLayout(
            available: available, scale: self.scale)
        NativeCombinedRingIcon(
            radius: self.radius, distance: self.segment.accountSymbol == nil ? 0 : layout.productDistance)
        {
            Image(NativeOrbitProviderArtwork.name(for: self.segment.productID))
                .renderingMode(.template).resizable().scaledToFit()
                .frame(width: layout.productSize, height: layout.productSize)
        }
        .opacity(layout.productVisibility)
        if let company = self.segment.companyID {
            NativeCombinedRingIcon(radius: self.radius, distance: layout.companyDistance) {
                Image(NativeOrbitProviderArtwork.name(for: company)).renderingMode(.template).resizable().scaledToFit()
                    .frame(width: 14 * self.scale, height: 14 * self.scale)
            }
            .opacity(layout.full * layout.secondaryVisibility * 0.65)
        }
        if let badge = self.segment.accountSymbol {
            NativeCombinedRingIcon(radius: self.radius, distance: layout.accountDistance) {
                NativeOrbitAccountBadgeImage(symbol: badge)
                    .font(.system(size: 15 * self.scale))
                    .frame(width: 17 * self.scale, height: 17 * self.scale)
            }
            .opacity(layout.fit(from: 17, to: 20) * layout.accountVisibility * 0.8)
        }
    }
}

/// Keep the company, service and account in a stable order along the arc. Reversing that order at the vertical
/// extrema makes the marks collide and requires hiding account identities even on otherwise spacious sectors.
struct NativeCombinedRingIdentityLayout {
    let available: CGFloat
    let scale: CGFloat

    var pair: CGFloat {
        self.fit(from: 44, to: 58)
    }

    var full: CGFloat {
        self.fit(from: 64, to: 78)
    }

    private var breathingRoom: CGFloat {
        8 * self.fit(from: 78, to: 108)
    }

    var secondaryVisibility: CGFloat {
        self.clearanceVisibility(min(
            abs(self.companyDistance - self.productDistance),
            abs(self.accountDistance - self.productDistance)))
    }

    var accountVisibility: CGFloat {
        // The service remains the primary identity. Add the account only when its bounds clear the service.
        self.pair * self.clearanceVisibility(abs(self.accountDistance - self.productDistance))
    }

    var productSize: CGFloat {
        min(30 * self.scale, max(0, self.available))
    }

    var productVisibility: CGFloat {
        self.fit(from: 12, to: 18)
    }

    var productDistance: CGFloat {
        -10 * self.scale * self.pair * (1 - self.full)
    }

    var companyDistance: CGFloat {
        -(27 + self.breathingRoom) * self.scale
    }

    var accountDistance: CGFloat {
        self.scale * (18 * self.pair + (9 + self.breathingRoom) * self.full)
    }

    private func clearanceVisibility(_ distance: CGFloat) -> CGFloat {
        // Fade out before the artwork bounds touch, rather than leaving translucent overlapping marks.
        let value = min(1, max(0, (distance / self.scale - 24) / 3))
        return value * value * (3 - 2 * value)
    }

    func fit(from: CGFloat, to: CGFloat) -> CGFloat {
        let value = min(1, max(0, (self.available / self.scale - from) / (to - from)))
        return value * value * (3 - 2 * value)
    }
}

extension EnvironmentValues {
    @Entry var nativeCombinedIdentityAngle = 0.0
}

private struct NativeCombinedRingIcon<Content: View>: View {
    @Environment(\.nativeCombinedIdentityAngle) private var middle
    let radius: CGFloat
    let distance: CGFloat
    @ViewBuilder var content: () -> Content

    var body: some View {
        let angle = self.middle + self.distance / self.radius
        self.content().offset(x: cos(angle) * self.radius, y: sin(angle) * self.radius)
    }
}

/// An annular sector of the ring, its four corners rounded like the dial's cut ends.
struct NativeCombinedShareShape: Shape {
    nonisolated var start: Angle
    nonisolated var end: Angle
    let radius: CGFloat
    let width: CGFloat
    let corner: CGFloat
    nonisolated var gap: CGFloat = 0

    nonisolated var animatableData: AnimatablePair<AnimatablePair<Double, Double>, CGFloat> {
        get { .init(.init(self.start.radians, self.end.radians), self.gap) }
        set {
            self.start = .radians(newValue.first.first)
            self.end = .radians(newValue.first.second)
            self.gap = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        guard self.end > self.start else { return Path() }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = self.radius + self.width / 2
        let inner = self.radius - self.width / 2
        guard self.gap > 0 || (self.end - self.start).degrees < 359.9999999 else {
            var ring = Path()
            ring.addEllipse(in: CGRect(x: center.x - outer, y: center.y - outer, width: 2 * outer, height: 2 * outer))
            ring.addEllipse(in: CGRect(x: center.x - inner, y: center.y - inner, width: 2 * inner, height: 2 * inner))
            return ring.normalized(eoFill: true)
        }
        guard inner > 0, outer > inner else { return Path() }
        let sweep = (self.end - self.start).radians
        // Preserve a positive island without reducing the cuts on unrelated sectors.
        let halfGap = min(max(0, self.gap / 2), inner * sin(min(Double.pi, sweep) / 2) / 2)
        let reach = sin(min(Double.pi / 4, sweep / 2))
        let corner = max(0, min(
            self.corner,
            self.width / 2,
            (inner * reach - halfGap) / max(0.001, 1 - reach) * 0.98))
        func point(_ radius: CGFloat, _ angle: Angle) -> CGPoint {
            CGPoint(x: center.x + cos(angle.radians) * radius, y: center.y + sin(angle.radians) * radius)
        }
        let outerInset = Angle.radians(asin(min(1, (halfGap + corner) / (outer - corner))))
        let innerInset = Angle.radians(asin(min(1, (halfGap + corner) / (inner + corner))))
        let outerStart = self.start + outerInset
        let outerEnd = self.end - outerInset
        let innerStart = self.start + innerInset
        let innerEnd = self.end - innerInset
        guard innerEnd > innerStart else { return Path() }
        var path = Path()
        path.move(to: point(outer, outerStart))
        path.addArc(center: center, radius: outer, startAngle: outerStart, endAngle: outerEnd, clockwise: false)
        if corner > 0 {
            path.addArc(
                center: point(outer - corner, outerEnd),
                radius: corner,
                startAngle: outerEnd,
                endAngle: self.end + .degrees(90),
                clockwise: false)
            path.addArc(
                center: point(inner + corner, innerEnd),
                radius: corner,
                startAngle: self.end + .degrees(90),
                endAngle: innerEnd + .degrees(180),
                clockwise: false)
        } else {
            path.addLine(to: point(inner, innerEnd))
        }
        path.addArc(center: center, radius: inner, startAngle: innerEnd, endAngle: innerStart, clockwise: true)
        if corner > 0 {
            path.addArc(
                center: point(inner + corner, innerStart),
                radius: corner,
                startAngle: innerStart + .degrees(180),
                endAngle: self.start + .degrees(270),
                clockwise: false)
            path.addArc(
                center: point(outer - corner, outerStart),
                radius: corner,
                startAngle: self.start - .degrees(90),
                endAngle: outerStart,
                clockwise: false)
        } else {
            path.addLine(to: point(outer, outerStart))
        }
        path.closeSubpath()
        return path
    }
}
