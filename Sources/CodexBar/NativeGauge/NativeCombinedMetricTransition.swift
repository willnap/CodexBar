import SwiftUI

/// One clock for a unit change: the dial, account marks, comparison lines and selected complication.
enum NativeCombinedMetricTransition {
    static let duration = 0.35
    static var animation: Animation {
        .smooth(duration: self.duration)
    }
}

/// A round-ended capsule centered on the complications' actual circle at every presentation instant.
struct NativeCombinedMetricPill: Shape {
    let degrees: Double
    let length: CGFloat

    func path(in rect: CGRect) -> Path {
        let radius = NativeOrbitComplicationStyle.radius
        let half = Double(max(0, self.length - 26) / 2 / radius) * 180 / Double.pi
        var path = Path()
        path.addArc(
            center: CGPoint(x: rect.midX, y: rect.midY),
            radius: radius,
            startAngle: .degrees(self.degrees - half),
            endAngle: .degrees(self.degrees + half),
            clockwise: false)
        return path.strokedPath(StrokeStyle(lineWidth: 26, lineCap: .round))
    }
}

/// The presentation angle drives both the solid pill and the text-inversion mask in the same render pass.
/// Ink changes only where the traveling pill covers a glyph, including while reversing mid-animation.
struct NativeCombinedMetricSelectionInk: View, Animatable {
    nonisolated var degrees: Double
    nonisolated var length: CGFloat
    let money: String
    let tokens: String
    let moneyValue: Double?
    let tokenValue: Double?

    nonisolated var animatableData: AnimatablePair<Double, CGFloat> {
        get { .init(self.degrees, self.length) }
        set { (self.degrees, self.length) = (newValue.first, newValue.second) }
    }

    var body: some View {
        let pill = NativeCombinedMetricPill(degrees: self.degrees, length: self.length)
        ZStack {
            pill.fill(.primary)
            self.readouts
            self.readouts.colorInvert()
                .padding(24)
                .mask {
                    pill.fill(.white).frame(width: 224, height: 224).padding(24)
                }
                .padding(-24)
        }
        .frame(width: 224, height: 224)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var readouts: some View {
        ZStack {
            NativeOrbitArcText(value: self.money, corner: .topLeading, numericValue: self.moneyValue)
            NativeOrbitArcText(
                value: self.tokens, corner: .topTrailing, monospaced: true, numericValue: self.tokenValue)
        }
        .frame(width: 224, height: 224)
    }
}
