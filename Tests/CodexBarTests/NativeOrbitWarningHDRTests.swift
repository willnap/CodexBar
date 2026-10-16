import AppKit
import Testing
@testable import CodexBar

@MainActor
struct NativeOrbitWarningHDRTests {
    @Test func `catalogue colours remain saturated when their luminous core enters HDR`() {
        func linear(_ value: Double) -> Float {
            Float(value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4))
        }
        let catalogue: [(NativeOrbitWarningHDRColor, [Double], Int)] = [
            (.caution, [232, 158, 0], 0), (.critical, [255, 59, 48], 0), (.opportunity, [51, 199, 89], 1),
        ]
        for (color, channels, dominant) in catalogue {
            let sdr = color.emission(headroom: 1, darkAppearance: false)
            let hdr = color.emission(headroom: 4, darkAppearance: false)
            for channel in 0..<3 {
                #expect(abs(sdr[channel] - linear(channels[channel] / 255)) < 0.002)
                if channel != dominant { #expect(hdr[channel] == sdr[channel]) }
            }
            #expect(hdr[dominant] > 1)
        }
    }

    @Test func `filled symbol variants retain solid interiors in the warning raster`() {
        func raster(_ symbol: String) -> [Float16] {
            NativeOrbitWarningHDRRaster.pixels(
                items: [.init(id: "fill", symbol: symbol, position: .zero, color: .caution)],
                size: CGSize(width: 64, height: 64),
                scale: 2,
                headroom: 1,
                darkAppearance: true)
        }
        let pixels = raster("circle")
        #expect(pixels[(64 * 128 + 64) * 4 + 3] > 0.9)
        #expect(pixels == raster("circle.fill"))
    }

    @Test func `symbols without a filled counterpart remain visible`() throws {
        let image = try #require(NativeOrbitWarningHDRRaster.symbolImage("waveform.path.ecg"))
        #expect(image.size.width > 0 && image.size.height > 0)
        let pixels = NativeOrbitWarningHDRRaster.pixels(
            items: [.init(id: "fallback", symbol: "waveform.path.ecg", position: .zero, color: .caution)],
            size: CGSize(width: 64, height: 64),
            scale: 2,
            headroom: 1,
            darkAppearance: true)
        #expect(pixels.enumerated().contains { $0.offset % 4 == 3 && $0.element > 0 })
    }

    @Test func `both appearances retain identical clean glyph coverage and extended range cores`() {
        let items = [NativeOrbitWarningHDRItem(
            id: "edge", symbol: "exclamationmark.triangle", position: .zero, color: .caution)]
        let size = CGSize(width: 64, height: 64)
        let light = NativeOrbitWarningHDRRaster.pixels(
            items: items, size: size, scale: 2, headroom: 4, darkAppearance: false)
        let dark = NativeOrbitWarningHDRRaster.pixels(
            items: items, size: size, scale: 2, headroom: 4, darkAppearance: true)
        #expect(light.enumerated().contains { $0.offset % 4 != 3 && $0.element > 1 })
        #expect(light[0..<4].allSatisfy { $0 == 0 })
        let darkCoverage = (0..<(128 * 128)).filter { dark[$0 * 4 + 3] > 0 }
        let lightCoverage = (0..<(128 * 128)).filter { light[$0 * 4 + 3] > 0 }
        #expect(lightCoverage == darkCoverage)
        #expect(!lightCoverage.isEmpty)
    }

    @Test func `HDR source contains luminous pixels above SDR white with transparent surroundings`() {
        let pixels = self.pixels(headroom: 4)
        #expect(pixels.enumerated().contains { $0.offset % 4 != 3 && $0.element > 1 })
        #expect(pixels[0..<4].allSatisfy { $0 == 0 })
        #expect(pixels.enumerated().filter { $0.offset % 4 == 3 }.allSatisfy { $0.element <= 1 })
    }

    @Test func `SDR screens receive clamped source emission instead of simulated HDR`() {
        let pixels = self.pixels(headroom: 1)
        #expect(pixels.contains { $0 > 0 })
        #expect(pixels.allSatisfy { $0 >= 0 && $0 <= 1 })
        for invalidHeadroom in [CGFloat.nan, -CGFloat.infinity, -1, 0] {
            #expect(NativeOrbitWarningHDRColor.caution.emission(
                headroom: invalidHeadroom, darkAppearance: true).x == NativeOrbitWarningHDRColor.caution.emission(
                headroom: 1, darkAppearance: true).x)
        }
    }

    @Test func `emission respects current screen headroom and keeps all three signal hues distinct`() {
        for color in [NativeOrbitWarningHDRColor.caution, .critical, .opportunity] {
            let emission = color.emission(headroom: 1.5, darkAppearance: true)
            #expect(max(emission.x, emission.y, emission.z) == 1.5)
        }
        let caution = NativeOrbitWarningHDRColor.caution.emission(headroom: 2, darkAppearance: true)
        let critical = NativeOrbitWarningHDRColor.critical.emission(headroom: 2, darkAppearance: true)
        let opportunity = NativeOrbitWarningHDRColor.opportunity.emission(headroom: 2, darkAppearance: true)
        #expect(caution.y > critical.y)
        #expect(opportunity.y > opportunity.x)
        #expect(opportunity.y > opportunity.z)
    }

    @Test func `natural symbol bounds match the image used for source coverage`() throws {
        let symbol = "exclamationmark.triangle"
        let image = try #require(NativeOrbitWarningHDRRaster.symbolImage(symbol))
        #expect(NativeOrbitWarningHDRView.symbolSize(symbol) == image.size)
        #expect(image.size.width > 0)
        #expect(image.size.height > 0)
    }

    @Test func `source coverage follows positive down dial coordinates`() {
        let width = 128
        let pixels = NativeOrbitWarningHDRRaster.pixels(
            items: [.init(id: "position", symbol: "circle.fill", position: CGPoint(x: 20, y: -20), color: .caution)],
            size: CGSize(width: width, height: width),
            scale: 1,
            headroom: 1,
            darkAppearance: true)
        let covered = (0..<(width * width)).filter { pixels[$0 * 4 + 3] > 0 }
        #expect(!covered.isEmpty)
        #expect(covered.allSatisfy { $0 % width > width / 2 && $0 / width < width / 2 })
    }

    @Test func `prepared startup frames retain actual warning severity and every readiness checkpoint`() throws {
        let real: [NativeOrbitWarningLight] = [
            .init(.outage, .caution, "Fixture outage"),
            .init(.partialReading, .critical, "Fixture partial report"),
        ]
        let positions = Dictionary(uniqueKeysWithValues: NativeOrbitWarningLight.Kind.allCases.map {
            ($0, CGPoint(x: $0.rawValue, y: 0))
        })
        for reading in [false, true] {
            for history in [false, true] {
                for status in [false, true] {
                    let readiness = NativeOrbitStartupReadiness(
                        readingReady: reading, historyReady: history, statusReady: status)
                    let frames = NativeOrbitWarningHDRView.startupItems(
                        realLights: real, readiness: readiness, positions: positions)
                    let first = try #require(frames.first)
                    #expect(first.first(where: { $0.id == "outage" })?.color == .caution)
                    #expect(first.first(where: { $0.id == "partialReading" })?.color == .critical)
                    for checkpoint in 0...4 {
                        let expected = NativeOrbitStartupChecks.shown(
                            realLights: real, phase: .sweeping, checkpoint: checkpoint, readiness: readiness)
                            .compactMap { light in
                                positions[light.kind].map { NativeOrbitWarningHDRItem(light: light, position: $0) }
                            }
                        #expect(frames.contains(expected))
                    }
                    #expect(frames.last?.map(\.id) == ["outage", "partialReading"])
                    for (index, frame) in frames.enumerated() {
                        #expect(!frames.prefix(index).contains(frame), "Duplicate checkpoint raster")
                    }
                }
            }
        }
    }

    @Test func `prepared cache retains checkpoint frames across multiple account columns`() {
        let size = CGSize(width: 16, height: 16)
        let items = (0..<36).map { index in
            [NativeOrbitWarningHDRItem(
                id: "prepared-multiple-columns-\(index)", symbol: "circle", position: .zero, color: .caution)]
        }
        let prepared = items.map {
            NativeOrbitWarningHDRRaster.pixels(
                items: $0, size: size, scale: 1, headroom: 1, darkAppearance: true, preparing: true)
        }
        for (item, pixels) in zip(items, prepared) {
            let displayed = NativeOrbitWarningHDRRaster.pixels(
                items: item, size: size, scale: 1, headroom: 1, darkAppearance: true)
            let reused = pixels.withUnsafeBufferPointer { first in
                displayed.withUnsafeBufferPointer { second in first.baseAddress == second.baseAddress }
            }
            #expect(reused, "An earlier account checkpoint was evicted before its animation")
        }
    }

    @Test func `equivalent emitted headroom reuses the exact prepared pixel storage`() {
        let items = [NativeOrbitWarningHDRItem(
            id: "equivalent-headroom", symbol: "circle", position: .zero, color: .opportunity)]
        for dark in [false, true] {
            let capped: CGFloat = dark ? 2 : 1.5
            let first = NativeOrbitWarningHDRRaster.pixels(
                items: items,
                size: CGSize(width: 16, height: 16),
                scale: 1,
                headroom: capped,
                darkAppearance: dark,
                preparing: true)
            let second = NativeOrbitWarningHDRRaster.pixels(
                items: items,
                size: CGSize(width: 16, height: 16),
                scale: 1,
                headroom: 8,
                darkAppearance: dark)
            let reused = first.withUnsafeBufferPointer { lhs in
                second.withUnsafeBufferPointer { rhs in lhs.baseAddress == rhs.baseAddress }
            }
            #expect(first == second)
            #expect(reused)
        }
    }

    @Test func `stable linear HDR source delegates current display adaptation to Core Animation`() {
        for dark in [false, true] {
            let headroom = NativeOrbitWarningHDRColor.renderingHeadroom(8, darkAppearance: dark)
            #expect(headroom == (dark ? 2 : 1.5))
            let layer = CALayer()
            NativeOrbitWarningHDRView.configureDynamicRange(of: layer, sourceHeadroom: headroom)
            #expect(layer.contentsHeadroom == headroom)
            #expect(layer.preferredDynamicRange == .high)
            #expect(layer.toneMapMode == .ifSupported)
        }
        let sdr = CALayer()
        NativeOrbitWarningHDRView.configureDynamicRange(of: sdr, sourceHeadroom: 1)
        #expect(sdr.contentsHeadroom == 1)
        #expect(sdr.preferredDynamicRange == .standard)
        #expect(sdr.toneMapMode == .ifSupported)
    }

    private func pixels(headroom: CGFloat) -> [Float16] {
        NativeOrbitWarningHDRRaster.pixels(
            items: [.init(id: "test", symbol: "exclamationmark.triangle", position: .zero, color: .caution)],
            size: CGSize(width: 64, height: 64),
            scale: 2,
            headroom: headroom,
            darkAppearance: true)
    }
}
