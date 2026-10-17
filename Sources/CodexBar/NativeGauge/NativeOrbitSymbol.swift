import SwiftUI

/// Native Liquid Glass follows the interpolated quota silhouette supplied to the native renderer.
struct NativeOrbitSymbol: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    nonisolated static let radii: [CGFloat] = [108, 82, 56]
    nonisolated static let stroke: CGFloat = 18
    nonisolated static let countdownStroke: CGFloat = 18
    /// Corner radius where a radial cut meets a rail's sides: the usage draw front and the countdown cuts.
    nonisolated static let cutCorner: CGFloat = 3.5
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
            // One container renders the lane's neighbouring glass together; glass cannot sample other glass.
            GlassEffectContainer(spacing: 0) {
                ZStack {
                    // Keep these views present at zero: reaching empty animates on the same clock as every other
                    // amount.
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

    /// Where the countdown rail's cap begins: 14 units of arc clear of the usage arc's cap on every lane.
    nonisolated static func resetStart(lane: Int) -> Double {
        let radius = self.radii[min(2, max(0, lane))]
        return 130 + (asin(9 / radius) + 14 / radius) * 180 / .pi
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
    var usageSilhouette: NativeOrbitUsageShape {
        NativeOrbitUsageShape(lane: self.lane, remaining: self.value)
    }

    var body: some View {
        Group {
            if let segments {
                // Every segment is its own rounded island of the one glass shape, so each keeps a complete rim.
                self.material(
                    in: NativeOrbitCountdownShape(
                        lane: self.lane,
                        segments: segments,
                        value: self.value,
                        continuous: self.continuous),
                    accent: self.accent.mix(with: .white, by: 0.24),
                    tint: 0.6)
            } else {
                self.material(in: self.usageSilhouette, accent: self.accent, tint: 0.8)
            }
        }
        // The parent interpolates the value once. Native glass consumes that presentation value directly
        // instead of starting another animation toward each intermediate frame.
        .transaction { $0.animation = nil }
    }

    @ViewBuilder
    private func material(in shape: some Shape, accent: Color, tint: Double) -> some View {
        if self.reduceTransparency {
            shape.fill(accent)
        } else {
            // Clear glass shows the system's lensing and rim light around the rounded bodies; a translucent tint
            // carries the provider colour without turning the material into opaque paint. Usage takes the fuller
            // tint; the countdown stays paler so the two read apart.
            shape.fill(.clear)
                .glassEffect(.clear.tint(accent.opacity(tint)), in: shape)
                .allowedDynamicRange(.high)
        }
    }
}

/// The remaining usage: the authored arc and caps, its radial draw front's corners rounded.
struct NativeOrbitUsageShape: Shape {
    let lane: Int
    var remaining: Double = 1

    var animatableData: Double {
        get { self.remaining }
        set { self.remaining = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let remaining = self.remaining.isFinite ? min(1, max(0, self.remaining)) : 0
        guard remaining > 0 else { return Path() }
        let scale = min(rect.width, rect.height) / NativeOrbitSymbol.canvas
        let radius = NativeOrbitSymbol.radii[min(2, max(0, self.lane))]
        // The authored caps are centred on ±130°; the rail's extremes lie one cap beyond them.
        let cap = asin(NativeOrbitSymbol.stroke / 2 / radius)
        let rail = NativeOrbitRail(
            center: CGPoint(x: rect.midX, y: rect.midY),
            radius: radius * scale,
            halfWidth: NativeOrbitSymbol.stroke / 2 * scale,
            angles: -130 * .pi / 180 - cap...130 * .pi / 180 + cap)
        guard remaining < 1 else { return rail.piece(rail.angles, corners: (0, 0)) }
        // Native Draw advances radially toward the upper terminal, retaining the lower cap.
        return rail.piece(
            (130 - 260 * remaining) * .pi / 180...rail.angles.upperBound,
            corners: (NativeOrbitSymbol.cutCorner * scale, 0))
    }
}

/// A rail along an arc with a round cap at each end: the authored usage and countdown silhouette. Pieces are cut
/// from it radially. A cut's corners are rounded where it crosses the rail's straight sides and stay sharp across
/// a cap, so a cap can span several short segments as in the authored countdown symbols.
struct NativeOrbitRail {
    let center: CGPoint
    let radius: CGFloat
    let halfWidth: CGFloat
    /// The rail's extremes: the tips of its caps.
    let angles: ClosedRange<Double>

    private var capCentres: (Double, Double) {
        let inset = asin(Double(min(1, self.halfWidth / self.radius)))
        return (self.angles.lowerBound + inset, self.angles.upperBound - inset)
    }

    /// The piece between two radial cuts. A cut at a rail extreme follows the cap instead of a corner.
    func piece(_ cuts: ClosedRange<Double>, corners: (start: CGFloat, end: CGFloat)) -> Path {
        let a = max(self.angles.lowerBound, cuts.lowerBound)
        let b = min(self.angles.upperBound, cuts.upperBound)
        guard b > a else { return Path() }
        let (startCap, endCap) = self.capCentres
        let outer = self.radius + self.halfWidth
        let inner = self.radius - self.halfWidth
        let atStart = a <= self.angles.lowerBound
        let atEnd = b >= self.angles.upperBound
        // Corners round only on the straight sides, sharing the piece's straight length so they never overlap.
        var startCorner = !atStart && a >= startCap && a <= endCap ? max(0, corners.start) : 0
        var endCorner = !atEnd && b >= startCap && b <= endCap ? max(0, corners.end) : 0
        let straight = min(b, endCap) - max(a, startCap)
        if startCorner + endCorner > 0, straight > 0 {
            func limit(_ corner: CGFloat) -> CGFloat {
                let share = min(Double.pi / 4, straight * Double(corner / (startCorner + endCorner)))
                return min(corner, self.halfWidth, inner * sin(share) / (1 - sin(share)))
            }
            (startCorner, endCorner) = (limit(startCorner), limit(endCorner))
        } else {
            (startCorner, endCorner) = (0, 0)
        }
        func point(_ distance: CGFloat, _ angle: Double) -> CGPoint {
            CGPoint(x: self.center.x + distance * cos(angle), y: self.center.y + distance * sin(angle))
        }
        func reach(_ corner: CGFloat, _ distance: CGFloat) -> Double {
            corner > 0 ? asin(Double(corner / distance)) : 0
        }
        var path = Path()
        let outerFrom = a + reach(startCorner, outer - startCorner)
        let outerTo = b - reach(endCorner, outer - endCorner)
        path.move(to: self.side(outer: true, at: outerFrom))
        self.addSide(to: &path, outer: true, from: outerFrom, to: outerTo)
        if !atEnd {
            if endCorner > 0 {
                path.addArc(
                    center: point(outer - endCorner, outerTo),
                    radius: endCorner,
                    startAngle: .radians(outerTo),
                    endAngle: .radians(b + .pi / 2),
                    clockwise: false)
                let innerTo = b - reach(endCorner, inner + endCorner)
                path.addArc(
                    center: point(inner + endCorner, innerTo),
                    radius: endCorner,
                    startAngle: .radians(b + .pi / 2),
                    endAngle: .radians(innerTo + .pi),
                    clockwise: false)
            } else {
                path.addLine(to: self.side(outer: false, at: b))
            }
        }
        let innerFrom = b - reach(endCorner, inner + endCorner)
        let innerTo = a + reach(startCorner, inner + startCorner)
        self.addSide(to: &path, outer: false, from: innerFrom, to: innerTo)
        if !atStart {
            if startCorner > 0 {
                path.addArc(
                    center: point(inner + startCorner, innerTo),
                    radius: startCorner,
                    startAngle: .radians(innerTo + .pi),
                    endAngle: .radians(a + .pi * 3 / 2),
                    clockwise: false)
                path.addArc(
                    center: point(outer - startCorner, outerFrom),
                    radius: startCorner,
                    startAngle: .radians(a - .pi / 2),
                    endAngle: .radians(outerFrom),
                    clockwise: false)
            } else {
                path.addLine(to: self.side(outer: true, at: a))
            }
        }
        path.closeSubpath()
        return path
    }

    /// The rail's outer or inner boundary at an angle: a circle about the centre between the caps, a cap beyond.
    private func side(outer: Bool, at angle: Double) -> CGPoint {
        let (startCap, endCap) = self.capCentres
        let distance: CGFloat
        if angle < startCap || angle > endCap {
            let delta = angle - (angle < startCap ? startCap : endCap)
            let radius = Double(self.radius)
            let root = sqrt(max(0, Double(self.halfWidth * self.halfWidth) - radius * radius * sin(delta) * sin(delta)))
            distance = CGFloat(radius * cos(delta) + (outer ? root : -root))
        } else {
            distance = outer ? self.radius + self.halfWidth : self.radius - self.halfWidth
        }
        return CGPoint(x: self.center.x + distance * cos(angle), y: self.center.y + distance * sin(angle))
    }

    /// Follows one boundary between two angles: outward sides run forwards, inner sides backwards.
    private func addSide(to path: inout Path, outer: Bool, from: Double, to: Double) {
        let (startCap, endCap) = self.capCentres
        var stops = [from, to] + [startCap, endCap].filter { $0 > min(from, to) && $0 < max(from, to) }
        stops.sort(by: from < to ? (<) : (>))
        for (p, q) in zip(stops, stops.dropFirst()) where p != q {
            let middle = (p + q) / 2
            if middle < startCap || middle > endCap {
                // Both directions travel the cap the same way round its own centre.
                let centreAngle = middle < startCap ? startCap : endCap
                let centre = CGPoint(
                    x: self.center.x + self.radius * cos(centreAngle),
                    y: self.center.y + self.radius * sin(centreAngle))
                let from = self.side(outer: outer, at: p)
                let to = self.side(outer: outer, at: q)
                let start = Double(atan2(from.y - centre.y, from.x - centre.x))
                let sweep = Double(atan2(to.y - centre.y, to.x - centre.x)) - start
                let turn = 2 * Double.pi
                Self.addArc(
                    to: &path,
                    center: centre,
                    radius: self.halfWidth,
                    from: start,
                    to: start + sweep - turn * floor(sweep / turn))
            } else {
                let radius = outer ? self.radius + self.halfWidth : self.radius - self.halfWidth
                Self.addArc(to: &path, center: self.center, radius: radius, from: p, to: q)
            }
        }
    }

    /// Arcs split at fixed 15° stops, so pieces that overlap share identical curves wherever they meet a cap.
    private static func addArc(to path: inout Path, center: CGPoint, radius: CGFloat, from: Double, to: Double) {
        guard from.isFinite, to.isFinite else { return }
        let step = Double.pi / 12
        let forward = to > from
        // The stop index advances every pass, so rounding at an exact multiple cannot stall the walk.
        var index = forward ? floor(from / step) : ceil(from / step)
        var angle = from
        while angle != to {
            index += forward ? 1 : -1
            let next = forward ? min(to, index * step) : max(to, index * step)
            path.addArc(
                center: center,
                radius: radius,
                startAngle: .radians(angle),
                endAngle: .radians(next),
                clockwise: to < from)
            angle = next
        }
    }
}

/// The countdown rail shares the usage arc's radius and width; radial cuts divide it into time units.
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
        let scale = min(rect.width, rect.height) / NativeOrbitSymbol.canvas
        let rail = NativeOrbitRail(
            center: center,
            radius: radius * scale,
            halfWidth: NativeOrbitSymbol.countdownStroke / 2 * scale,
            angles: start...end)
        let corner = NativeOrbitSymbol.cutCorner * scale
        var path = Path()
        for segment in 0..<filled {
            let a = start + Double(segment) * step + (segment > 0 ? gap / 2 : 0)
            var b = start + Double(segment + 1) * step - (segment < count - 1 ? gap / 2 : 0)
            if self.continuous, progress < Double(segment + 1) {
                // Preserve the established segment cuts while moving the last segment's draw front each frame.
                b = a + (b - a) * (progress - Double(segment))
            }
            if self.cutsOnly {
                // Each countdown sector spans less than a right angle. Its outer chord lies beyond every corner
                // of the dial, so this bounded triangle has exactly the same visible coverage as the circular cut.
                let extent = max(rect.width, rect.height)
                path.addPath(NativeOrbitRevealPolygon.path([
                    center,
                    CGPoint(x: center.x + cos(a) * extent, y: center.y + sin(a) * extent),
                    CGPoint(x: center.x + cos(b) * extent, y: center.y + sin(b) * extent),
                ], clippedTo: rect))
            } else {
                path.addPath(rail.piece(a...max(a, b), corners: (corner, corner)))
            }
        }
        return path
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
