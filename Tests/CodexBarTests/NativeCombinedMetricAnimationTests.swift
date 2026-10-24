import SwiftUI
import Testing
@testable import CodexBar

@MainActor
struct NativeCombinedMetricAnimationTests {
    @Test func `moving pill stays on the complications circle without crossing the pie`() {
        let rect = CGRect(x: 0, y: 0, width: 224, height: 224)
        let radius = NativeOrbitComplicationStyle.radius
        for degrees in stride(from: -135.0, through: -45.0, by: 0.5) {
            for length in [40.0, 65, 108] {
                let shape = NativeCombinedMetricPill(degrees: degrees, length: length)
                let path = shape.path(in: rect)
                let angle = degrees * Double.pi / 180
                #expect(path.contains(CGPoint(x: 112 + radius * cos(angle), y: 112 + radius * sin(angle))))
                #expect(!path.contains(CGPoint(x: 112 + 99 * cos(angle), y: 112 + 99 * sin(angle))))
            }
        }
    }

    @Test func `text inversion mask covers only the pill at every switch position`() {
        let rect = CGRect(x: 0, y: 0, width: 224, height: 224)
        let money = NativeOrbitComplicationStyle.point(degrees: -135)
        let tokens = NativeOrbitComplicationStyle.point(degrees: -45)
        let first = NativeCombinedMetricPill(degrees: -135, length: 65).path(in: rect)
        let middle = NativeCombinedMetricPill(degrees: -90, length: 65).path(in: rect)
        let last = NativeCombinedMetricPill(degrees: -45, length: 65).path(in: rect)
        #expect(first.contains(money) && !first.contains(tokens))
        #expect(!middle.contains(money) && !middle.contains(tokens))
        #expect(last.contains(tokens) && !last.contains(money))
    }
}
