import SwiftUI
import Testing
@testable import CodexBar

@MainActor
struct NativeOrbitChartCursorTests {
    @Test func `continuous pointer tracking bypasses inherited and descendant animations`() {
        let inherited = Transaction(animation: .spring(response: 1))
        let tracking = NativeOrbitChartCursorMotion.transaction(inherited, inspecting: true)
        #expect(tracking.animation == nil)
        #expect(tracking.disablesAnimations)
        #expect(NativeOrbitChartCursorMotion.animation(inspecting: true, reduceMotion: false) == nil)
    }

    @Test func `discrete chart transitions retain their own animation and reduce motion is respected`() {
        let inherited = Transaction(animation: .smooth(duration: 0.35))
        let discrete = NativeOrbitChartCursorMotion.transaction(inherited, inspecting: false)
        #expect(discrete.animation == inherited.animation)
        #expect(!discrete.disablesAnimations)
        #expect(NativeOrbitChartCursorMotion.animation(inspecting: false, reduceMotion: false) != nil)
        #expect(NativeOrbitChartCursorMotion.animation(inspecting: false, reduceMotion: true) == nil)
    }
}
