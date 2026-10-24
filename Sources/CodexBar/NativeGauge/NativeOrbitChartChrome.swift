import SwiftUI

/// Shared time labels, reference line and inspection detail for every native history graph.
struct NativeOrbitChartAxisRow: View {
    let dates: [Date]
    let now: Date
    let frame: CGRect
    let accent: Color
    let inspecting: Bool
    let label: (Date) -> String

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                if self.frame.width > 0 {
                    ForEach(Array(self.dates.enumerated()), id: \.offset) { index, date in
                        let emphasized = date == self.now && !self.inspecting
                        let text = Text(self.label(date))
                            .font(.system(size: 10, weight: emphasized ? .bold : .regular))
                            .monospacedDigit()
                            .foregroundStyle(emphasized ? self.accent : .secondary)
                            .lineLimit(1).fixedSize()
                        if index == 0 {
                            text.frame(maxWidth: .infinity, alignment: .leading).padding(.leading, self.frame.minX)
                        } else if index == self.dates.count - 1 {
                            text.frame(maxWidth: .infinity, alignment: .trailing)
                                .padding(.trailing, max(0, geometry.size.width - self.frame.maxX))
                        } else {
                            text.position(x: self.frame.midX, y: 7)
                        }
                    }
                }
            }
        }
        .frame(height: 16)
        .padding(.top, 3)
        .accessibilityHidden(true)
    }
}

struct NativeOrbitChartMarkerLine: View {
    @Environment(\.colorScheme) private var colorScheme
    let accent: Color
    let inspecting: Bool
    let height: CGFloat

    var body: some View {
        Capsule()
            .fill(self.accent.gradient)
            .overlay {
                Capsule().strokeBorder(
                    Color.primary.opacity(self.colorScheme == .dark ? 0.5 : 0.18), lineWidth: 0.65)
            }
            .shadow(color: .black.opacity(0.25), radius: 1, x: 0, y: 0.5)
            .frame(width: self.inspecting ? 2.5 : 3.5, height: self.height)
    }
}

struct NativeOrbitInspectionPill: View {
    let time: String
    var event: NativeOrbitMarkedEvent?
    var accent = Color.primary

    var body: some View {
        HStack(spacing: 5) {
            if let event {
                if let symbol = event.symbol {
                    Image(systemName: symbol).symbolRenderingMode(.hierarchical)
                        .foregroundStyle(event.isScheduled ? Color.secondary : self.accent)
                }
                Text(event.title).foregroundStyle(.primary)
            }
            Text(self.time).foregroundStyle(self.event == nil ? Color.primary : .secondary)
        }
        .font(.system(size: 12, weight: .semibold)).monospacedDigit().lineLimit(1)
        .padding(.horizontal, 10).frame(height: 22)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .fixedSize().offset(y: -4)
        .transition(.opacity.combined(with: .scale(scale: 0.92)))
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(self.event.map { "\($0.title), \(self.time)" } ?? self.time)
    }
}
