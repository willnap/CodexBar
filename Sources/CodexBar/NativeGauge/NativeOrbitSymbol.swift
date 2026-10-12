import SwiftUI

/// Native SF artwork supplies both the variable symbol and the exact Liquid Glass boundary.
struct NativeOrbitSymbol: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    nonisolated static let radii: [CGFloat] = [108, 82, 56]
    nonisolated static let stroke: CGFloat = 18
    nonisolated static let canvas: CGFloat = 256

    let remaining: Double?
    let countdown: Double?
    let segments: Int
    let lane: Int
    var size: CGFloat = 256
    var accent = Color.primary

    private var prefix: String {
        "compute.popup.lane\(min(2, max(0, self.lane)))"
    }

    private var countdownName: String {
        "\(self.prefix).reset\(min(31, max(1, self.segments)))"
    }

    var body: some View {
        ZStack {
            Image("\(self.prefix).usage", variableValue: 1)
                .symbolVariableValueMode(.draw)
                .foregroundStyle(Color.primary.opacity(0.11))
            if let remaining = Self.normalized(self.remaining), remaining > 0 {
                NativeOrbitUsageGlass(
                    name: "\(self.prefix).usage",
                    lane: self.lane,
                    size: self.size,
                    value: remaining,
                    accent: self.accent,
                    reduceTransparency: self.reduceTransparency)
                    .animation(self.reduceMotion ? nil : .smooth(duration: 0.22), value: remaining)
            }
            Image(self.countdownName, variableValue: 1)
                .symbolVariableValueMode(.color)
                .foregroundStyle(Color.primary.opacity(0.08))
            if let countdown = Self.normalized(self.countdown), countdown > 0 {
                Image(self.countdownName, variableValue: countdown)
                    .symbolVariableValueMode(.color)
                    .foregroundStyle(LinearGradient(
                        colors: [self.accent.mix(with: .white, by: 0.18), self.accent],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing))
                    .frame(width: self.size, height: self.size)
                    .mask(NativeOrbitCountdownMask(segments: self.segments, value: countdown, lane: self.lane))
                    .opacity(0.34)
                    .animation(self.reduceMotion ? nil : .smooth(duration: 0.22), value: countdown)
            }
        }
        .font(.system(size: self.size, weight: .regular))
        .imageScale(.small)
        .symbolRenderingMode(.monochrome)
        .symbolEffectsRemoved(self.reduceMotion)
        .frame(width: self.size, height: self.size)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    nonisolated static func resetStart(lane: Int) -> Double {
        let radius = self.radii[min(2, max(0, lane))]
        return 130 + (asin(9 / radius) + 8 / radius) * 180 / .pi
    }

    private static func normalized(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return min(1, max(0, value))
    }
}

private struct NativeOrbitUsageGlass: View, Animatable {
    let name: String
    let lane: Int
    let size: CGFloat
    nonisolated var value: Double
    let accent: Color
    let reduceTransparency: Bool

    nonisolated var animatableData: Double {
        get { self.value }
        set { self.value = newValue }
    }

    var body: some View {
        let shape = NativeOrbitArtworkShape(lane: self.lane, remaining: self.value)
        let artwork = Image(self.name, variableValue: min(1, max(0, self.value)))
            .symbolVariableValueMode(.draw)
            .foregroundStyle(self.accent.opacity(self.reduceTransparency ? 1 : 0.32))
            .frame(width: self.size, height: self.size)
            // Native Draw leaves a faint undrawn layer; remove it so empty quota is unambiguous.
            .mask(shape)
        if self.reduceTransparency {
            artwork
        } else {
            artwork
                .glassEffect(.regular.tint(self.accent.opacity(0.58)), in: shape)
                .overlay {
                    NativeOrbitGlassLighting(lane: self.lane, remaining: self.value, size: self.size)
                }
                .shadow(color: .black.opacity(0.12), radius: 1.5, x: 0, y: 1)
                .allowedDynamicRange(.constrainedHigh)
        }
    }
}

/// The symbol defines segment outlines and rounding; this mask only hides native inactive layers.
private struct NativeOrbitCountdownMask: Shape {
    let segments: Int
    var value: Double
    let lane: Int

    func path(in rect: CGRect) -> Path {
        let count = min(31, max(1, self.segments))
        let filled = min(count, max(0, Int(floor(self.value * Double(count) + 0.5))))
        guard filled > 0 else { return Path() }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        path.move(to: center)
        path.addArc(
            center: center,
            radius: max(rect.width, rect.height),
            startAngle: .degrees(NativeOrbitSymbol.resetStart(lane: self.lane)),
            endAngle: .degrees(NativeOrbitSymbol.resetStart(lane: self.lane)
                + (360 - 2 * NativeOrbitSymbol.resetStart(lane: self.lane)) * Double(filled) / Double(count)),
            clockwise: false)
        path.closeSubpath()
        return path
    }
}
