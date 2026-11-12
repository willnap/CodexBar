import SwiftUI

/// The spans a chart can show. Day, week and month are always in the range control; a pinch can rest on any whole
/// number of hours or days, and the control then gains that one span for as long as it is selected.
enum NativeOrbitRange {
    static let standard = [1, 7, 30]
    static let shortest: TimeInterval = 3600
    static let longest: TimeInterval = 30 * 86400

    /// The span a pinch has reached. Spreading the fingers magnifies: the same width shows less time.
    static func span(from origin: TimeInterval, magnification: CGFloat) -> TimeInterval {
        guard magnification.isFinite, magnification > 0, origin.isFinite else { return origin }
        return min(self.longest, max(self.shortest, origin / Double(magnification)))
    }

    /// Where a pinch comes to rest: on day, week or month when it is within a tenth of one, otherwise on whole
    /// hours under a day and whole days above.
    static func snapped(_ span: TimeInterval) -> TimeInterval {
        let span = min(self.longest, max(self.shortest, span))
        for days in self.standard where abs(span / (Double(days) * 86400) - 1) < 0.1 {
            return Double(days) * 86400
        }
        let unit: TimeInterval = span < 86400 ? 3600 : 86400
        return max(unit, (span / unit).rounded() * unit)
    }

    /// The whole days that cover a span: what the corners total and what is prepared for the chart.
    static func days(covering span: TimeInterval) -> Int {
        min(30, max(1, Int((span / 86400).rounded(.up))))
    }

    /// The control's segments in seconds: day, week and month, with the current span among them when it is another.
    static func segments(selected span: TimeInterval) -> [TimeInterval] {
        let standard = self.standard.map { Double($0) * 86400 }
        return standard.contains(span) ? standard : (standard + [span]).sorted()
    }

    /// "6H" under a day, "2W" for whole weeks, otherwise "3D".
    static func shortTitle(_ span: TimeInterval) -> String {
        if span < 86400 { return "\(Int((span / 3600).rounded()))H" }
        let days = Int((span / 86400).rounded())
        return days.isMultiple(of: 7) ? "\(days / 7)W" : "\(days)D"
    }

    static func word(_ span: TimeInterval) -> String {
        if span < 86400 {
            let hours = Int((span / 3600).rounded())
            return hours == 1 ? "1 Hour" : "\(hours) Hours"
        }
        let days = Int((span / 86400).rounded())
        return days.isMultiple(of: 7) ? "\(days / 7) Weeks" : "\(days) Days"
    }

    static func name(_ span: TimeInterval) -> String {
        if span < 86400 {
            let hours = Int((span / 3600).rounded())
            return hours == 1 ? "Last hour" : "Last \(hours) hours"
        }
        return "Last \(Int((span / 86400).rounded())) days"
    }
}

/// Where a pinch on a chart sends its span: every step while the fingers move, and where it came to rest.
struct NativeOrbitRangePinchTarget {
    let span: @MainActor () -> TimeInterval
    let track: @MainActor (TimeInterval) -> Void
    let settle: @MainActor (TimeInterval) -> Void
}

extension EnvironmentValues {
    @Entry var nativeOrbitRangePinch: NativeOrbitRangePinchTarget?
}

/// Pinching a chart zooms its time span about now. The span follows the fingers directly, with no animation of its
/// own between steps; only when they lift does it ease onto whole hours or days, and the range settle with it.
private struct NativeOrbitRangePinch: ViewModifier {
    @Environment(\.nativeOrbitRangePinch) private var target
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The span when the fingers came down; every step is measured from it.
    @State private var origin: TimeInterval?

    func body(content: Content) -> some View {
        content.simultaneousGesture(
            MagnifyGesture(minimumScaleDelta: 0)
                .onChanged { value in
                    guard let target else { return }
                    let origin = self.origin ?? target.span()
                    if self.origin == nil { self.origin = origin }
                    let span = NativeOrbitRange.span(from: origin, magnification: value.magnification)
                    var transaction = Transaction(animation: nil)
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { target.track(span) }
                }
                .onEnded { value in
                    guard let target, let origin = self.origin else { return }
                    self.origin = nil
                    let span = NativeOrbitRange.span(from: origin, magnification: value.magnification)
                    withAnimation(self.reduceMotion ? nil : .smooth(duration: 0.22)) { target.settle(span) }
                })
    }
}

extension View {
    func nativeOrbitRangePinch() -> some View {
        self.modifier(NativeOrbitRangePinch())
    }
}
