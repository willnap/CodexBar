import AppKit

/// Actual solid glyph coverage lets the dense bulb check share empty symbol space without erasing small lamps.
@MainActor
enum NativeOrbitWarningInk {
    typealias Kind = NativeOrbitWarningLight.Kind

    struct Mask {
        let pixels: [Bool]
        let minX: Int
        let minY: Int
        let width: Int
        let height: Int
        let count: Int
        let phase: CGPoint

        func offset(_ point: CGPoint) -> (Int, Int) {
            (
                Int((self.phase.x + point.x * 2).rounded() - self.phase.x.rounded()),
                Int((self.phase.y + point.y * 2).rounded() - self.phase.y.rounded()))
        }
    }

    private static var masks: [Kind: Mask] = [:]

    static func mask(_ kind: Kind) -> Mask {
        if let mask = self.masks[kind] { return mask }
        let size = NativeOrbitWarningHDRView.symbolSize(kind.symbol)
        let source = NativeOrbitWarningHDRRaster.pixels(
            items: [.init(id: kind.catalogueKey, symbol: kind.symbol, position: .zero, color: .caution)],
            size: CGSize(width: 64, height: 64),
            scale: 2,
            headroom: 1,
            darkAppearance: false)
        let occupied = (0..<(128 * 128)).filter { source[$0 * 4 + 3] > 0.45 }
        let minX = occupied.map { $0 % 128 }.min() ?? 64
        let maxX = occupied.map { $0 % 128 }.max() ?? 64
        let minY = occupied.map { $0 / 128 }.min() ?? 64
        let maxY = occupied.map { $0 / 128 }.max() ?? 64
        let width = maxX - minX + 1, height = maxY - minY + 1
        var pixels = [Bool](repeating: false, count: width * height)
        for pixel in occupied {
            pixels[(pixel / 128 - minY) * width + pixel % 128 - minX] = true
        }
        let mask = Mask(
            pixels: pixels,
            minX: minX - 64,
            minY: minY - 64,
            width: width,
            height: height,
            count: max(1, occupied.count),
            phase: CGPoint(x: 64 - size.width, y: 64 - size.height))
        self.masks[kind] = mask
        return mask
    }

    static func visibility(_ positions: [Kind: CGPoint]) -> [Kind: CGFloat] {
        var owners = [UInt64](repeating: 0, count: 256 * 256)
        let samples = positions.map { kind, point -> (Kind, [Int]) in
            let mask = self.mask(kind)
            let delta = mask.offset(point)
            let occupied = mask.pixels.enumerated().filter(\.element).map { index, _ in
                (index / mask.width + mask.minY + delta.1 + 128) * 256
                    + index % mask.width + mask.minX + delta.0 + 128
            }
            for pixel in occupied {
                owners[pixel] |= UInt64(1) << kind.rawValue
            }
            return (kind, occupied)
        }
        return Dictionary(uniqueKeysWithValues: samples.map { kind, occupied in
            let bit = UInt64(1) << kind.rawValue
            let free = occupied.filter { owners[$0] == bit }.count
            return (kind, CGFloat(free) / CGFloat(max(1, occupied.count)))
        })
    }
}
