import SwiftUI
import Testing
@testable import CodexBar

@MainActor
struct NativeCombinedRingIdentityLayoutTests {
    @Test func `compact segments always retain their service identity`() {
        for available in [25.0, 32, 44, 47, 50, 54, 58, 78, 108] {
            let layout = NativeCombinedRingIdentityLayout(available: available, scale: 1)
            #expect(layout.productVisibility > 0.99)
            #expect(layout.productSize <= available)
            #expect(layout.productSize <= 30)
        }
    }

    @Test func `tiny sectors survive a full size separator without closing other gaps`() {
        let rect = CGRect(x: 0, y: 0, width: 256, height: 256)
        for fraction in [0.000001, 0.001, 0.005, 0.015, 0.1] {
            let tiny = NativeCombinedShareShape(
                start: .zero,
                end: .radians(fraction * 2 * .pi),
                radius: 90,
                width: 54,
                corner: 3.5,
                gap: 4)
            let angle = fraction * .pi
            #expect(tiny.path(in: rect).contains(CGPoint(x: 128 + 90 * cos(angle), y: 128 + 90 * sin(angle))))
        }
        let ring = NativeCombinedShareRing(segments: [
            .init(id: "tiny", fraction: 0.000001, accent: .red, productID: "codex", help: "Tiny"),
            .init(id: "first", fraction: 0.499999, accent: .blue, productID: "codex", help: "First"),
            .init(id: "second", fraction: 0.5, accent: .green, productID: "claude", help: "Second"),
        ], size: 256)
        let large = NativeCombinedShareShape(
            start: .zero, end: .degrees(180), radius: 90, width: 54, corner: 3.5, gap: ring.gap)
        #expect(!large.path(in: rect).contains(CGPoint(x: 218, y: 129)))
        #expect(large.path(in: rect).contains(CGPoint(x: 218, y: 134)))
    }

    @Test func `zero shares stay empty beside a full ring`() {
        let rect = CGRect(x: 0, y: 0, width: 256, height: 256)
        for start in [0.0, Double.pi, 2 * Double.pi] {
            let empty = NativeCombinedShareShape(
                start: .radians(start),
                end: .radians(start),
                radius: 90,
                width: 54,
                corner: 3.5)
            #expect(empty.path(in: rect).isEmpty)
        }
        let full = NativeCombinedShareShape(
            start: .zero,
            end: .degrees(360),
            radius: 90,
            width: 54,
            corner: 3.5)
        #expect(full.path(in: rect).contains(CGPoint(x: 218, y: 128)))
        #expect(!full.path(in: rect).contains(CGPoint(x: 128, y: 128)))
    }

    @Test func `native glass sector geometry exposes its interpolated cut angles`() {
        var shape = NativeCombinedShareShape(
            start: .zero,
            end: .degrees(90),
            radius: 90,
            width: 54,
            corner: 3.5,
            gap: 4)
        let target = NativeCombinedShareShape(
            start: .degrees(90),
            end: .degrees(180),
            radius: 90,
            width: 54,
            corner: 3.5,
            gap: 6)
        var step = target.animatableData - shape.animatableData
        step.scale(by: 0.5)
        shape.animatableData += step
        let path = shape.path(in: CGRect(x: 0, y: 0, width: 256, height: 256))
        #expect(path.contains(CGPoint(x: 83, y: 205.9423)))
        #expect(!path.contains(CGPoint(x: 214.9333, y: 151.2937)))
    }

    @Test func `marks remain separated around the whole circle`() {
        let scale: CGFloat = 216 / 256
        let radius: CGFloat = 90 * scale
        for degrees in stride(from: -180.0, through: 180.0, by: 0.5) {
            for available in [20.0, 44, 47, 50, 51, 54, 57, 58, 78, 108, 180] {
                let angle = degrees * .pi / 180
                let layout = NativeCombinedRingIdentityLayout(
                    available: available * scale, scale: scale)
                func distance(_ first: CGFloat, _ second: CGFloat) -> CGFloat {
                    let a = angle + first / radius
                    let b = angle + second / radius
                    return hypot(cos(a) - cos(b), sin(a) - sin(b)) * radius
                }
                if layout.full == 1, layout.secondaryVisibility > 0 {
                    #expect(distance(layout.companyDistance, layout.productDistance) > 22 * scale)
                }
                if layout.productVisibility > 0, layout.accountVisibility > 0 {
                    #expect(distance(layout.accountDistance, layout.productDistance) > 23.5 * scale)
                }
            }
        }
    }

    @Test func `larger segments give secondary marks breathing room within the segment`() {
        let compact = NativeCombinedRingIdentityLayout(available: 78, scale: 1)
        let spacious = NativeCombinedRingIdentityLayout(available: 108, scale: 1)
        #expect(abs(spacious.companyDistance) == 35)
        #expect(spacious.accountDistance == 35)
        #expect(abs(spacious.companyDistance) > abs(compact.companyDistance))
        #expect(spacious.accountDistance > compact.accountDistance)
        #expect(spacious.accountDistance + 8.5 < spacious.available / 2)
    }

    @Test func `spacious sectors retain company and account marks at every angle`() {
        let layout = NativeCombinedRingIdentityLayout(available: 108, scale: 1)
        #expect(layout.secondaryVisibility == 1)
        #expect(layout.accountVisibility == 1)
        #expect(layout.companyDistance < layout.productDistance)
        #expect(layout.accountDistance > layout.productDistance)
    }
}
