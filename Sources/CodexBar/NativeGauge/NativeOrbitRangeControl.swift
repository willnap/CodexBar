import SwiftUI

struct NativeOrbitRangeControl: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selection
    @Binding var days: Int
    let accent: Color
    /// Full "Day · Week · Month" where the bar has room; single letters in a single column.
    var fullWords = false
    private static let ranges = [1, 7, 30]

    var body: some View {
        GlassEffectContainer(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Self.ranges, id: \.self) { range in
                    Button {
                        withAnimation(self.reduceMotion ? nil : .smooth(duration: 0.25)) { self.days = range }
                    } label: {
                        Text(self.fullWords ? Self.word(range) : Self.title(range))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(Self.name(range))
                    .accessibilityLabel(Self.name(range))
                    .background {
                        if self.days == range {
                            Capsule().fill(self.accent.opacity(0.52))
                                .glassEffect(.regular.tint(self.accent).interactive(), in: Capsule())
                                .glassEffectID("period", in: self.selection)
                        }
                    }
                    .accessibilityAddTraits(self.days == range ? .isSelected : [])
                }
            }
            .padding(2)
            .glassEffect(.regular, in: Capsule())
        }
        .animation(self.reduceMotion ? nil : .smooth(duration: 0.28), value: self.days)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("Time period"))
    }

    /// Single-letter Day / Week / Month segments, as in Health; the full period is the help and accessibility label.
    static func title(_ range: Int) -> String {
        switch range {
        case 7: L("native_orbit_range_week")
        case 30: L("native_orbit_range_month")
        default: L("native_orbit_range_day")
        }
    }

    static func word(_ range: Int) -> String {
        switch range {
        case 7: L("Week")
        case 30: L("Month")
        default: L("Day")
        }
    }

    static func name(_ range: Int) -> String {
        switch range {
        case 7: L("Last 7 days")
        case 30: L("Last 30 days")
        default: L("Today")
        }
    }
}
