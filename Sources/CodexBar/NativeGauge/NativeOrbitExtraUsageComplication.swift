import SwiftUI

/// The bottom-trailing icon: tinted while additional usage accrues, plain when it applies at zero, slashed when it
/// does not apply (turned off, or never reported), and faint while no reading covers the instant.
enum NativeOrbitExtraUsageIconState: Equatable {
    case unknown
    case notApplicable
    case zero
    case active
}

struct NativeOrbitExtraUsageComplication: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    nonisolated static let symbol = "creditcard.rewards.fill"
    let fraction: Double?
    let icon: NativeOrbitExtraUsageIconState
    let accent: Color
    let help: String

    private var ink: AnyShapeStyle {
        switch self.icon {
        case .active: AnyShapeStyle(self.accent)
        case .zero: AnyShapeStyle(NativeOrbitComplicationStyle.idle)
        case .notApplicable, .unknown: AnyShapeStyle(NativeOrbitComplicationStyle.unavailable)
        }
    }

    var body: some View {
        NativeOrbitInstrumentElement(corner: .bottomTrailing, help: self.help) {
            ZStack {
                NativeOrbitCornerGauge(fraction: 1)
                    .stroke(Color.primary.opacity(0.035), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                // Present at zero too, so a reading arriving draws its arc in from the origin.
                if let fraction, fraction.isFinite {
                    NativeOrbitCornerGauge(fraction: min(1, max(0, fraction)))
                        .stroke(self.accent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .animation(self.reduceMotion ? nil : .smooth(duration: 0.22), value: fraction)
                }
                // The card precedes the fixed 54° origin. Its smaller footprint leaves a clear gap
                // from the round cap, and shares the other complications’ radius and margins.
                NativeOrbitSlashableGlyph(
                    name: Self.symbol,
                    size: 12,
                    slashed: self.icon == .notApplicable,
                    ink: self.ink)
                    .position(NativeOrbitComplicationStyle.point(degrees: 65))
                    .animation(self.reduceMotion ? nil : .smooth(duration: 0.22), value: self.icon)
            }
            .frame(width: 224, height: 224)
        }
    }
}

private struct NativeOrbitCornerGauge: Shape {
    var fraction: Double

    var animatableData: Double {
        get { self.fraction }
        set { self.fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        // An empty allowance draws nothing, not a round cap's dot.
        guard self.fraction > 0 else { return path }
        path.addArc(
            center: CGPoint(x: rect.midX, y: rect.midY),
            radius: NativeOrbitComplicationStyle.radius,
            startAngle: .degrees(54),
            endAngle: .degrees(54 - 30 * self.fraction),
            clockwise: true)
        return path
    }
}
