import AppKit
import Testing
@testable import CodexBar

@MainActor
struct NativeOrbitWarningCatalogueLayoutsTests {
    @Test func `every prepared catalogue retains distinct lamps inside its calibrated ring`() throws {
        #expect(NativeOrbitWarningCatalogueLayouts.coordinates.count == 40)
        for key in NativeOrbitWarningCatalogueLayouts.coordinates.keys {
            let scale = try #require(Double(key.prefix { $0 != ":" }))
            let bounds = NativeOrbitWarningCatalogueLayouts.inkBounds.map {
                $0.applying(CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))
            }
            let positions = try #require(NativeOrbitWarningCatalogueLayouts.positions(
                for: key, bounds: bounds, symbolScale: scale))
            #expect(positions.count == NativeOrbitWarningLight.Kind.allCases.count)
            #expect(Set(positions.map { "\($0.x),\($0.y)" }).count == positions.count)
            for (point, ink) in zip(positions, bounds) {
                let rect = ink.offsetBy(dx: point.x, dy: point.y)
                let extent = max(
                    hypot(rect.minX, rect.minY),
                    hypot(rect.maxX, rect.minY),
                    hypot(rect.minX, rect.maxY),
                    hypot(rect.maxX, rect.maxY))
                #expect(extent < NativeOrbitWarningLayout.radius(lanes: 3), "\(key): \(point)")
            }
        }
    }

    @Test func `unknown geometry and changed system glyphs fall back to the measured layout solver`() throws {
        let key = try #require(NativeOrbitWarningCatalogueLayouts.coordinates.keys.first)
        let scale = try #require(Double(key.prefix { $0 != ":" }))
        let bounds = NativeOrbitWarningCatalogueLayouts.inkBounds.map {
            $0.applying(CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))
        }
        #expect(NativeOrbitWarningCatalogueLayouts.positions(
            for: "unrecorded geometry", bounds: bounds, symbolScale: scale) == nil)
        #expect(NativeOrbitWarningCatalogueLayouts.positions(
            for: key, bounds: Array(bounds.dropLast()), symbolScale: scale) == nil)
        var changed = bounds
        changed[0].size.width += 0.25 / scale
        #expect(NativeOrbitWarningCatalogueLayouts.positions(
            for: key, bounds: changed, symbolScale: scale) == nil)
    }
}
