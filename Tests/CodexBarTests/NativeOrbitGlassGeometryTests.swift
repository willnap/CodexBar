import SwiftUI
import Testing
@testable import CodexBar

/// The silhouettes handed to native glass: the authored rails, cut radially with softly rounded corners.
@MainActor
struct NativeOrbitGlassGeometryTests {
    private let rect = CGRect(x: 0, y: 0, width: 256, height: 256)

    @Test func `full usage glass covers the authored outline`() {
        let half = Double(NativeOrbitSymbol.stroke) / 2
        for lane in 0...2 {
            let radius = Double(NativeOrbitSymbol.radii[lane])
            let authored = NativeOrbitArtworkShape(lane: lane).path(in: self.rect)
            let glass = NativeOrbitUsageShape(lane: lane).path(in: self.rect)
            var compared = 0
            for x in stride(from: 0.25, to: 256, by: 1.5) {
                for y in stride(from: 0.25, to: 256, by: 1.5) {
                    let dx = x - 128, dy = y - 128
                    let degrees = atan2(dy, dx) * 180 / .pi
                    // Distance from the ideal outline: the arc between the cap centres, or the nearer round cap.
                    // Path containment flattens long curves by up to about half a unit, so skip points that close.
                    let edge: Double
                    if abs(degrees) <= 130 {
                        edge = abs(abs(hypot(dx, dy) - radius) - half)
                    } else {
                        let cap = (degrees > 0 ? 130.0 : -130.0) * .pi / 180
                        edge = abs(hypot(dx - radius * cos(cap), dy - radius * sin(cap)) - half)
                    }
                    guard edge > 1 else { continue }
                    let point = CGPoint(x: x, y: y)
                    #expect(glass.contains(point) == authored.contains(point), "Lane \(lane) at \(x), \(y)")
                    compared += 1
                }
            }
            #expect(compared > 20000)
        }
    }

    @Test func `usage draw front is a radial cut with softly rounded corners`() {
        let half = Double(NativeOrbitSymbol.stroke) / 2
        let corner = Double(NativeOrbitSymbol.cutCorner)
        for lane in 0...2 {
            let radius = Double(NativeOrbitSymbol.radii[lane])
            for remaining in [0.2, 0.5, 0.85] {
                let front = 130 - 260 * remaining
                let glass = NativeOrbitUsageShape(lane: lane, remaining: remaining).path(in: self.rect)
                let degree = 180 / Double.pi / radius
                // The reading ends exactly at the front: no cap reaches past it.
                #expect(glass.contains(self.point(radius: radius, degrees: front + 0.3 * degree)))
                #expect(!glass.contains(self.point(radius: radius, degrees: front - 0.3 * degree)))
                // A square front would fill its outer corner; the rounded one leaves it open.
                #expect(!glass.contains(self.point(radius: radius + half - 0.3, degrees: front + 0.3 * degree)))
                #expect(glass.contains(self.point(radius: radius + half - 0.8, degrees: front + 2 * corner * degree)))
                // The rounding is partial: most of the cut stays a straight radial edge.
                #expect(glass.contains(self.point(radius: radius + half - corner - 1, degrees: front + 0.3 * degree)))
                // The lower terminal keeps the authored round cap.
                #expect(glass.contains(self.point(radius: radius, degrees: 130 + 0.8 * half * degree)))
            }
        }
    }

    @Test func `countdown cuts are radial with softly rounded corners`() {
        let half = Double(NativeOrbitSymbol.countdownStroke) / 2
        let corner = Double(NativeOrbitSymbol.cutCorner)
        for lane in 0...2 {
            let radius = Double(NativeOrbitSymbol.radii[lane])
            let degree = 180 / Double.pi / radius
            let start = NativeOrbitSymbol.resetStart(lane: lane)
            let end = 360 - start
            let capCentres = (start + asin(half / radius) * 180 / .pi, end - asin(half / radius) * 180 / .pi)
            for count in [1, 4, 7, 12, 31] {
                let full = NativeOrbitCountdownShape(lane: lane, segments: count, value: 1).path(in: self.rect)
                let step = (end - start) / Double(count)
                let gap = count > 1 ? min(3.2 * degree, step * 0.40) : 0
                for segment in 0..<count {
                    let a = start + Double(segment) * step + (segment > 0 ? gap / 2 : 0)
                    let b = start + Double(segment + 1) * step - (segment < count - 1 ? gap / 2 : 0)
                    // At each cut the centreline spans the segment's whole reading, and nothing in the gap. The
                    // rail's own extremes are its authored caps.
                    if segment > 0 {
                        #expect(full.contains(self.point(radius: radius, degrees: a + (b - a) * 0.05)))
                    }
                    if segment < count - 1 {
                        #expect(full.contains(self.point(radius: radius, degrees: b - (b - a) * 0.05)))
                        #expect(!full.contains(self.point(radius: radius, degrees: b + gap / 2)))
                    }
                    // An interior cut on the straight sides, with room for its corners, is rounded only partly.
                    let straight = b > capCentres.0 && b < capCentres.1 && a > capCentres.0
                    if segment < count - 1, straight, (b - a) / degree > 4 * corner {
                        #expect(!full.contains(self.point(radius: radius + half - 0.3, degrees: b - 0.3 * degree)))
                        #expect(full.contains(self.point(
                            radius: radius + half - corner - 1, degrees: b - 0.3 * degree)))
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
