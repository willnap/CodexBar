import SwiftUI
import Testing
@testable import CodexBar

@MainActor
struct NativeOrbitStartupGeometryTests {
    private let rect = CGRect(x: 0, y: 0, width: 256, height: 256)

    @Test func `startup countdown advances inside a segment instead of rounding to whole segments`() {
        let earlier = NativeOrbitCountdownShape(lane: 0, segments: 4, value: 0.30, continuous: true)
            .path(in: self.rect)
        let later = NativeOrbitCountdownShape(lane: 0, segments: 4, value: 0.35, continuous: true)
            .path(in: self.rect)
        // 165 degrees lies beyond the 30 percent front but within the 35 percent front.
        let front = self.point(radius: 108, degrees: 165)
        #expect(!earlier.contains(front))
        #expect(later.contains(front))
        #expect(earlier != later)
    }

    @Test func `startup countdown includes the next segment before its halfway rounding threshold`() {
        let path = NativeOrbitCountdownShape(lane: 0, segments: 4, value: 0.30, continuous: true)
            .path(in: self.rect)
        #expect(path.contains(self.point(radius: 108, degrees: 162)))
        #expect(!path.contains(self.point(radius: 108, degrees: 170)))
    }

    @Test func `completed startup countdown matches the regular full extent across lanes and segment counts`() {
        for lane in 0...2 {
            for segments in [1, 4, 12, 31] {
                let startup = NativeOrbitCountdownShape(lane: lane, segments: segments, value: 1, continuous: true)
                    .path(in: self.rect)
                let normal = NativeOrbitCountdownShape(lane: lane, segments: segments, value: 1)
                    .path(in: self.rect)
                #expect(!startup.isEmpty)
                #expect(startup == normal)
            }
        }
    }

    @Test func `startup countdown clamps invalid and out of range values without invalid paths`() {
        for lane in 0...2 {
            for value in [0, -0.5, Double.nan, .infinity, -.infinity] {
                let path = NativeOrbitCountdownShape(lane: lane, segments: 12, value: value, continuous: true)
                    .path(in: self.rect)
                #expect(path.isEmpty)
            }
            let oversized = NativeOrbitCountdownShape(lane: lane, segments: 12, value: 2, continuous: true)
                .path(in: self.rect)
            let full = NativeOrbitCountdownShape(lane: lane, segments: 12, value: 1)
                .path(in: self.rect)
            #expect(oversized == full)
        }
    }

    @Test func `regular countdown retains its existing nearest whole segment behavior`() {
        let belowFirst = NativeOrbitCountdownShape(lane: 0, segments: 4, value: 0.124).path(in: self.rect)
        #expect(belowFirst.isEmpty)
        let atFirst = NativeOrbitCountdownShape(lane: 0, segments: 4, value: 0.125).path(in: self.rect)
        let beforeSecond = NativeOrbitCountdownShape(lane: 0, segments: 4, value: 0.374).path(in: self.rect)
        #expect(!atFirst.isEmpty)
        #expect(atFirst == beforeSecond)
        #expect(atFirst.contains(self.point(radius: 108, degrees: 150)))
        #expect(!atFirst.contains(self.point(radius: 108, degrees: 165)))
        let atSecond = NativeOrbitCountdownShape(lane: 0, segments: 4, value: 0.375).path(in: self.rect)
        #expect(atSecond.contains(self.point(radius: 108, degrees: 170)))
        #expect(atSecond != beforeSecond)
    }

    @Test func `countdown clamps lane and segment inputs in both drawing modes`() {
        for continuous in [false, true] {
            let lower = NativeOrbitCountdownShape(lane: -1, segments: 0, value: 0.4, continuous: continuous)
                .path(in: self.rect)
            let first = NativeOrbitCountdownShape(lane: 0, segments: 1, value: 0.4, continuous: continuous)
                .path(in: self.rect)
            #expect(lower == first)
            let upper = NativeOrbitCountdownShape(lane: 3, segments: 50, value: 0.4, continuous: continuous)
                .path(in: self.rect)
            let last = NativeOrbitCountdownShape(lane: 2, segments: 31, value: 0.4, continuous: continuous)
                .path(in: self.rect)
            #expect(upper == last)
        }
    }

    @Test func `usage reveal preserves quota coverage while its glass outline remains fixed`() {
        for lane in 0...2 {
            let outline = NativeOrbitArtworkShape(lane: lane).path(in: self.rect)
            for value in [0.0, 0.001, 0.125, 0.3, 0.5, 0.875, 0.999, 1, 2, Double.nan, .infinity] {
                let reference = NativeOrbitArtworkShape(lane: lane, remaining: value).path(in: self.rect)
                let reveal = NativeOrbitUsageRevealMask(value: value).path(in: self.rect)
                let changed = (-180..<180).filter { degree in
                    let point = self.point(radius: NativeOrbitSymbol.radii[lane], degrees: Double(degree) + 0.37)
                    return reference.contains(point) != (outline.contains(point) && reveal.contains(point))
                }
                #expect(changed.isEmpty, "Lane \(lane), progress \(value): \(changed)")
            }
        }
    }

    @Test func `countdown reveal preserves rounded and continuous readings on a fixed glass rail`() {
        for lane in 0...2 {
            let rail = NativeOrbitCountdownShape(lane: lane, segments: 1, value: 1).path(in: self.rect)
            for count in [1, 7, 12, 31] {
                for continuous in [false, true] {
                    for value in [0.0, 0.001, 0.125, 0.3, 0.5, 0.875, 0.999, 1, 2, Double.nan, .infinity] {
                        let reference = NativeOrbitCountdownShape(
                            lane: lane, segments: count, value: value, continuous: continuous).path(in: self.rect)
                        let reveal = NativeOrbitCountdownShape(
                            lane: lane, segments: count, value: value, continuous: continuous, cutsOnly: true)
                            .path(in: self.rect)
                        let changed = (-180..<180).filter { degree in
                            let point = self.point(
                                radius: NativeOrbitSymbol.radii[lane], degrees: Double(degree) + 0.37)
                            return reference.contains(point) != (rail.contains(point) && reveal.contains(point))
                        }
                        #expect(changed.isEmpty, "Lane \(lane), count \(count), progress \(value): \(changed)")
                    }
                }
            }
        }
    }

    @Test func `animated reveal mask geometry stays inside its drawing rectangle`() {
        let rectangles = [self.rect, CGRect(x: 11, y: -7, width: 320, height: 180)]
        for rect in rectangles {
            // Path stores single-precision bounds; adding its rounded origin and extent can exceed an edge by ULPs.
            let bounded = rect.insetBy(dx: -0.0001, dy: -0.0001)
            for step in 0...100 {
                let value = Double(step) / 100
                let usage = NativeOrbitUsageRevealMask(value: value).path(in: rect)
                #expect(usage.isEmpty || bounded.contains(usage.boundingRect))
                for lane in 0...2 {
                    for count in [1, 4, 12, 31] {
                        for continuous in [false, true] {
                            let countdown = NativeOrbitCountdownShape(
                                lane: lane, segments: count, value: value, continuous: continuous, cutsOnly: true)
                                .path(in: rect)
                            #expect(countdown.isEmpty || bounded.contains(countdown.boundingRect))
                        }
                    }
                }
            }
        }
    }

    private func point(radius: Double, degrees: Double) -> CGPoint {
        let angle = degrees * .pi / 180
        return CGPoint(x: self.rect.midX + radius * cos(angle), y: self.rect.midY + radius * sin(angle))
    }
}
