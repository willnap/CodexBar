import Foundation
import SwiftUI

/// The chart cursor's transaction boundary, independent of the dial and static plot animations.
enum NativeOrbitChartCursorMotion {
    static func animation(inspecting: Bool, reduceMotion: Bool) -> Animation? {
        reduceMotion || inspecting ? nil : NativeOrbitProjectionStyle.markerSpring
    }

    static func transaction(_ inherited: Transaction, inspecting: Bool) -> Transaction {
        var transaction = inherited
        if inspecting {
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
        return transaction
    }
}

/// Animate one time and its domain, then evaluate every glyph against that presentation.
/// Child positions never independently tween across corners, resets or unrecorded gaps.
struct NativeOrbitChartCursor<Content: View>: View, Animatable {
    nonisolated var time: TimeInterval
    nonisolated var lower: TimeInterval
    nonisolated var upper: TimeInterval
    @ViewBuilder let content: (Date, ClosedRange<Date>) -> Content

    init(date: Date, bounds: ClosedRange<Date>, @ViewBuilder content: @escaping (Date, ClosedRange<Date>) -> Content) {
        self.time = date.timeIntervalSinceReferenceDate
        self.lower = bounds.lowerBound.timeIntervalSinceReferenceDate
        self.upper = bounds.upperBound.timeIntervalSinceReferenceDate
        self.content = content
    }

    nonisolated var animatableData: AnimatablePair<Double, AnimatablePair<Double, Double>> {
        get { .init(self.time, .init(self.lower, self.upper)) }
        set {
            self.time = newValue.first
            self.lower = newValue.second.first
            self.upper = newValue.second.second
        }
    }

    var body: some View {
        let lower = min(self.lower, self.upper)
        let upper = max(lower + 1, self.upper)
        let bounds = Date(timeIntervalSinceReferenceDate: lower)...Date(timeIntervalSinceReferenceDate: upper)
        let date = Date(timeIntervalSinceReferenceDate: min(upper, max(lower, self.time)))
        self.content(date, bounds)
            .transaction {
                $0.animation = nil
                $0.disablesAnimations = true
            }
    }
}

/// Match the retained chart's compositor sweep without putting hover content inside its native host.
struct NativeOrbitChartCursorReveal: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let progress: Double
    var inspecting = false

    func body(content: Content) -> some View {
        content
            .offset(y: 3 * (1 - self.progress))
            .opacity(self.progress)
            .mask { Rectangle().scaleEffect(x: self.progress, anchor: .leading) }
            .animation(
                self.progress == 0 ? nil : self.reduceMotion ? .easeOut(duration: 0.15)
                    : .timingCurve(0.32, 0, 0.16, 1, duration: 0.64),
                value: self.progress)
            .transaction {
                $0 = NativeOrbitChartCursorMotion.transaction($0, inspecting: self.inspecting)
            }
    }
}
