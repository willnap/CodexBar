import SwiftUI

/// Native Liquid Glass follows the interpolated quota silhouette supplied to the native renderer.
struct NativeOrbitSymbol: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    nonisolated static let radii: [CGFloat] = [108, 82, 56]
    nonisolated static let stroke: CGFloat = 18
    nonisolated static let countdownStroke: CGFloat = 12
    nonisolated static let canvas: CGFloat = 256

    let remaining: Double?
    let countdown: Double?
    let segments: Int
    let lane: Int
    var size: CGFloat = 256
    var accent = Color.primary
    var startup: NativeOrbitStartupPhase = .live

    var body: some View {
        let startupActive = self.startup.isActive
        let motionReduced = self.reduceMotion
        ZStack {
            NativeOrbitArtworkShape(lane: self.lane)
                .fill(Color.primary.opacity(self.reduceTransparency ? 0.10 : 0.035))
            NativeOrbitCountdownShape(lane: self.lane, segments: self.segments, value: 1)
                .fill(Color.primary.opacity(self.reduceTransparency ? 0.10 : 0.035))
            // Keep these views present at zero: reaching empty animates on the same clock as every other amount.
            self.usageGlass
                .transaction(value: self.remaining) { [startupActive, motionReduced] transaction in
                    if !startupActive, !transaction.disablesAnimations {
                        transaction.animation = motionReduced ? nil : .smooth(duration: 0.22)
                    }
                }
            NativeOrbitAnimatedGlass(
                lane: self.lane,
                value: self.startup.fraction(self.countdown),
                segments: self.segments,
                continuous: self.startup.isActive,
                accent: self.accent,
                reduceTransparency: self.reduceTransparency)
                .transaction(value: self.countdown) { [startupActive, motionReduced] transaction in
                    if !startupActive, !transaction.disablesAnimations {
                        transaction.animation = motionReduced ? nil : .smooth(duration: 0.22)
                    }
                }
        }
        .frame(width: self.size, height: self.size)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The same presentation value drives the native material boundary and its content.
    var usageGlass: NativeOrbitAnimatedGlass {
        NativeOrbitAnimatedGlass(
            lane: self.lane,
            value: self.startup.fraction(self.remaining),
            segments: nil,
            continuous: self.startup.isActive,
            accent: self.accent,
            reduceTransparency: self.reduceTransparency)
    }

    nonisolated static func resetStart(lane: Int) -> Double {
        let radius = self.radii[min(2, max(0, lane))]
        return 130 + (asin(9 / radius) + 8 / radius) * 180 / .pi
    }
}

struct NativeOrbitAnimatedGlass: View, Animatable {
    let lane: Int
    nonisolated var value: Double
    let segments: Int?
    let continuous: Bool
    let accent: Color
    let reduceTransparency: Bool

    nonisolated var animatableData: Double {
        get { self.value }
        set { self.value = newValue }
    }

    /// This exact shape is passed into glassEffect(in:). An external mask is insufficient when a native
    /// glass container collects its silhouettes independently of the surrounding SwiftUI content.
    var usageSilhouette: NativeOrbitArtworkShape {
        NativeOrbitArtworkShape(lane: self.lane, remaining: self.value)
    }

    var body: some View {
        Group {
            if let segments {
                // Refract one uninterrupted surface, then cut it, as in the original segmented rail.
                let envelope = NativeOrbitCountdownShape(lane: self.lane, segments: 1, value: 1)
                self.material(
                    in: envelope,
                    accent: self.accent.mix(with: .white, by: 0.24))
                    .mask(NativeOrbitCountdownShape(
                        lane: self.lane,
                        segments: segments,
                        value: self.value,
                        continuous: self.continuous))
            } else {
                self.material(in: self.usageSilhouette, accent: self.accent)
            }
        }
        // The parent interpolates the value once. Native glass and its cuts consume that presentation value
        // directly instead of starting another animation toward each intermediate frame.
        .transaction { $0.animation = nil }
    }

    @ViewBuilder
    private func material(in shape: some Shape, accent: Color) -> some View {
        if self.reduceTransparency {
            shape.fill(accent)
        } else {
            // Regular glass retains its adaptive body and refraction even against a dark, uniform popover.
            // Let the system supply every reflection at the display's normal dynamic range.
            shape.fill(.clear)
                .glassEffect(.regular.tint(accent.opacity(0.8)), in: shape)
        }
    }
}

/// A slimmer countdown rail separates time from the heavier usage arc sharing its radius.
struct NativeOrbitCountdownShape: Shape {
    let lane: Int
    let segments: Int
    var value: Double
    var continuous: Bool = false
    /// Reveal the fixed native material without rebuilding its silhouette or intersecting paths each frame.
    var cutsOnly = false

    var animatableData: Double {
        get { self.value }
        set { self.value = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let count = min(31, max(1, self.segments))
        let value = self.value.isFinite ? min(1, max(0, self.value)) : 0
        let progress = value * Double(count)
        let filled = self.continuous ? Int(ceil(progress)) : Int(floor(progress + 0.5))
        guard filled > 0 else { return Path() }
        let radius = NativeOrbitSymbol.radii[min(2, max(0, self.lane))]
        let start = NativeOrbitSymbol.resetStart(lane: self.lane) * .pi / 180
        let end = 2 * Double.pi - start
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let step = (end - start) / Double(count)
        let gap = count > 1 ? min(3.2 / radius, step * 0.40) : 0
        var cuts = Path()
        for segment in 0..<filled {
            let a = start + Double(segment) * step + (segment > 0 ? gap / 2 : 0)
            var b = start + Double(segment + 1) * step - (segment < count - 1 ? gap / 2 : 0)
            if self.continuous, progress < Double(segment + 1) {
                // Preserve the established segment cuts while moving the last segment's draw front each frame.
                b = a + (b - a) * (progress - Double(segment))
            }
            let extent = max(rect.width, rect.height)
            if self.cutsOnly {
                // Each countdown sector spans less than a right angle. Its outer chord lies beyond every corner
                // of the dial, so this bounded triangle has exactly the same visible coverage as the circular cut.
                cuts.addPath(NativeOrbitRevealPolygon.path([
                    center,
                    CGPoint(x: center.x + cos(a) * extent, y: center.y + sin(a) * extent),
                    CGPoint(x: center.x + cos(b) * extent, y: center.y + sin(b) * extent),
                ], clippedTo: rect))
            } else {
                var sector = Path()
                sector.move(to: center)
                sector.addArc(
                    center: center,
                    radius: extent,
                    startAngle: .radians(a),
                    endAngle: .radians(b),
                    clockwise: false)
                sector.closeSubpath()
                cuts.addPath(sector)
            }
        }
        guard !self.cutsOnly else { return cuts }
        let scale = min(rect.width, rect.height) / NativeOrbitSymbol.canvas
        let inset = asin(NativeOrbitSymbol.countdownStroke / 2 / radius)
        var arc = Path()
        arc.addArc(
            center: center,
            radius: radius * scale,
            startAngle: .radians(start + inset),
            endAngle: .radians(end - inset),
            clockwise: false)
        let envelope = arc.strokedPath(StrokeStyle(
            lineWidth: NativeOrbitSymbol.countdownStroke * scale, lineCap: .round))
        return envelope.intersection(cuts)
    }
}

/// A radial reveal clips the established outline; native glass does not have to solve a new boundary per frame.
struct NativeOrbitUsageRevealMask: Shape {
    var value: Double

    var animatableData: Double {
        get { self.value }
        set { self.value = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let value = self.value.isFinite ? min(1, max(0, self.value)) : 0
        guard value > 0 else { return Path() }
        guard value < 1 else { return Path(rect) }
        let side = min(rect.width, rect.height)
        let start = (130 - 260 * value) * Double.pi / 180
        let end = 150 * Double.pi / 180
        let steps = Int(ceil((end - start) / (Double.pi / 12)))
        var points = [CGPoint(x: rect.midX, y: rect.midY)]
        for step in 0...steps {
            let angle = start + (end - start) * Double(step) / Double(steps)
            points.append(CGPoint(
                x: rect.midX + cos(angle) * side * 2,
                y: rect.midY + sin(angle) * side * 2))
        }
        return NativeOrbitRevealPolygon.path(points, clippedTo: rect)
    }
}

/// Clip the reveal's polygon before rendering its mask. Off-dial vertices otherwise inflate the animated mask's
/// drawing bounds to nearly fifteen dial areas; the fixed native glass can only use pixels inside this rectangle.
private enum NativeOrbitRevealPolygon {
    nonisolated static func path(_ points: [CGPoint], clippedTo rect: CGRect) -> Path {
        guard rect.width > 0, rect.height > 0 else { return Path() }
        var points = points
        for edge in 0..<4 {
            guard let last = points.last else { return Path() }
            let boundary = [rect.minX, rect.maxX, rect.minY, rect.maxY][edge]
            func coordinate(_ point: CGPoint) -> CGFloat { edge < 2 ? point.x : point.y }
            func inside(_ point: CGPoint) -> Bool {
                edge.isMultiple(of: 2) ? coordinate(point) >= boundary : coordinate(point) <= boundary
            }
            var clipped: [CGPoint] = []
            var previous = last
            for point in points {
                if inside(point) != inside(previous) {
                    let fraction = (boundary - coordinate(previous)) / (coordinate(point) - coordinate(previous))
                    let intersection = CGPoint(
                        x: previous.x + fraction * (point.x - previous.x),
                        y: previous.y + fraction * (point.y - previous.y))
                    clipped.append(edge < 2
                        ? CGPoint(x: boundary, y: intersection.y) : CGPoint(x: intersection.x, y: boundary))
                }
                if inside(point) { clipped.append(point) }
                previous = point
            }
            points = clipped
        }
        guard let first = points.first else { return Path() }
        var path = Path()
        path.move(to: first)
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        path.closeSubpath()
        return path
    }
}
