import SwiftUI

struct NativeOrbitRangeControl: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selection
    @Binding var days: Int
    /// A span that is not whole days (hours, from a pinch): it is the selection, as a segment of its own.
    var span: TimeInterval?
    let accent: Color
    /// Full "Day · Week · Month" where the bar has room; single letters in a single column.
    var fullWords = false
    static let ranges = NativeOrbitRange.standard

    private var selected: TimeInterval {
        self.span ?? Double(self.days) * 86400
    }

    /// Each segment keeps its width when a pinched-to span joins day, week and month, so the control grows by one.
    static func width(span: TimeInterval, fullWords: Bool) -> CGFloat {
        let segment: CGFloat = fullWords ? 59 : 33
        return 4 + segment * CGFloat(NativeOrbitRange.segments(selected: span).count) - 1
    }

    var body: some View {
        GeometryReader { geometry in
            let ranges = NativeOrbitRange.segments(selected: self.selected)
            let segmentWidth = max(0, (geometry.size.width - 4) / CGFloat(ranges.count))
            let fullWords = self.fullWords && geometry.size.width >= 150
            GlassEffectContainer(spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(ranges, id: \.self) { range in
                        let isSelected = self.selected == range
                        Button {
                            // Only day, week and month can be picked; another span is here because it is selected.
                            guard let days = Self.ranges.first(where: { Double($0) * 86400 == range }) else { return }
                            withAnimation(self.reduceMotion ? nil : .smooth(duration: 0.25)) { self.days = days }
                        } label: {
                            Text(fullWords ? Self.word(range) : Self.title(range))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.primary.opacity(isSelected ? 1 : 0.68))
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                                .frame(width: segmentWidth, height: max(0, geometry.size.height - 4))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help(Self.name(range))
                        .accessibilityLabel(Self.name(range))
                        .background {
                            if isSelected {
                                Capsule()
                                    .fill(self.accent.opacity(0.16))
                                    .glassEffect(.regular.tint(self.accent.opacity(0.28)).interactive(), in: Capsule())
                                    .glassEffectID("period", in: self.selection)
                            }
                        }
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                        .transition(.opacity)
                    }
                }
                .padding(2)
                .glassEffect(.regular, in: Capsule())
            }
        }
        .animation(self.reduceMotion ? nil : .smooth(duration: 0.28), value: self.selected)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("Time period"))
    }

    /// Single-letter Day / Week / Month segments, as in Health; the full period is the help and accessibility label.
    static func title(_ span: TimeInterval) -> String {
        switch span {
        case 86400: L("native_orbit_range_day")
        case 7 * 86400: L("native_orbit_range_week")
        case 30 * 86400: L("native_orbit_range_month")
        default: NativeOrbitRange.shortTitle(span)
        }
    }

    static func word(_ span: TimeInterval) -> String {
        switch span {
        case 86400: L("Day")
        case 7 * 86400: L("Week")
        case 30 * 86400: L("Month")
        default: NativeOrbitRange.word(span)
        }
    }

    static func name(_ span: TimeInterval) -> String {
        switch span {
        case 86400: L("Today")
        case 7 * 86400: L("Last 7 days")
        case 30 * 86400: L("Last 30 days")
        default: NativeOrbitRange.name(span)
        }
    }
}
