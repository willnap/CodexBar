import Foundation

enum NativePageControlDirection: Equatable {
    case natural, leftToRight, rightToLeft, topToBottom, bottomToTop

    var isVertical: Bool {
        self == .topToBottom || self == .bottomToTop
    }

    func isReversed(rightToLeft: Bool) -> Bool {
        self == .rightToLeft || self == .bottomToTop || (self == .natural && rightToLeft)
    }
}

enum NativePageControlBackgroundStyle {
    case automatic, prominent, minimal
}

enum NativePageControlInteraction: Equatable {
    case none, discrete, continuous
}

enum NativePageControlImageMetrics {
    static func size(_ size: CGSize, alignmentWidth: CGFloat, isSymbol: Bool) -> CGSize {
        guard size.width > 0, size.height > 0 else { return CGSize(width: 10, height: 10) }
        if isSymbol { return CGSize(width: alignmentWidth, height: size.height) }
        let scale = min(14 / size.width, 14 / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    static func length(_ size: CGSize, vertical: Bool) -> CGFloat {
        vertical ? size.height : size.width
    }
}

/// Port of the native page control's moving viewport. Its window stays put until the current mark reaches a
/// shrinking edge. Default dot metrics reproduce the measured Catalyst control; SF Symbols use a wider pitch.
struct NativePageControlLayout {
    struct Mark {
        let index: Int
        let position: CGFloat
        let scale: CGFloat
    }

    enum Hit: Equatable {
        case indicator(Int)
        case step(Int)
    }

    let count: Int
    let selection: Int
    let availableLength: CGFloat
    let pitch: CGFloat
    let glyphSize: CGFloat
    let reversed: Bool
    let length: CGFloat
    let offset: CGFloat
    let maximumOffset: CGFloat
    private let inset: CGFloat
    private let centers: [CGFloat]
    private let widths: [CGFloat]
    private let firstVisible: Int
    private let visibleCount: Int
    private let gap: CGFloat

    init(
        count: Int,
        selection: Int,
        availableLength: CGFloat,
        previousOffset: CGFloat = 0,
        reversed: Bool = false,
        expanded _: Bool = false,
        pitch: CGFloat = 20,
        glyphSize: CGFloat = 12,
        symbolWidths: [CGFloat]? = nil)
    {
        self.count = max(0, count)
        self.selection = min(max(0, selection), max(0, count - 1))
        self.availableLength = availableLength.isFinite ? max(0, availableLength) : 0
        self.pitch = pitch.isFinite ? max(1, pitch) : 20
        self.glyphSize = glyphSize.isFinite ? max(1, glyphSize) : 12
        self.reversed = reversed
        let custom = symbolWidths.flatMap { $0.count == max(0, count) ? $0 : nil }
        let widths = custom ?? Array(repeating: self.glyphSize, count: self.count)
        let gap = custom == nil ? max(0, self.pitch - self.glyphSize) : 8
        self.widths = widths
        self.gap = gap
        var centers: [CGFloat] = []
        var origins: [CGFloat] = []
        var cursor: CGFloat = 0
        for width in widths {
            origins.append(cursor)
            centers.append(ceil((cursor + width / 2) * 2) / 2)
            cursor += width + gap
        }
        self.centers = centers
        let strip = max(0, cursor - gap)
        var visible = min(10, self.count)
        var longest: CGFloat = 0
        while visible >= 1 {
            longest = (0...max(0, self.count - visible)).map { first in
                origins[first + visible - 1] + widths[first + visible - 1] - origins[first]
            }.max() ?? 0
            if longest + 28 <= self.availableLength || visible == 1 { break }
            visible -= 1
        }
        self.visibleCount = visible
        self.length = self.count < 1 ? 0 : min(longest + 28, self.availableLength)
        self.inset = min(14, max(0, (self.length - self.glyphSize) / 2))
        self.maximumOffset = max(0, strip + 2 * self.inset - self.length)
        let maximumFirst = max(0, self.count - visible)
        var offsets: [CGFloat] = []
        if visible >= 1 {
            for first in 0...maximumFirst {
                let span = origins[first + visible - 1] + widths[first + visible - 1] - origins[first]
                offsets.append(min(self.maximumOffset, max(0, origins[first] - (longest - span) / 2)))
            }
        }
        let previous = previousOffset.isFinite ? max(0, previousOffset) : 0
        var first = offsets.indices.min { abs(offsets[$0] - previous) < abs(offsets[$1] - previous) } ?? 0
        let shrinking = min(2, max(0, (visible - 1) / 2))
        if self.selection > (first == maximumFirst ? self.count - 1 : first + visible - 1 - shrinking) {
            first = self.selection - max(0, visible - 1 - shrinking)
        } else if self.selection < (first == 0 ? 0 : first + shrinking) {
            first = self.selection - shrinking
        }
        self.firstVisible = min(maximumFirst, max(0, first))
        self.offset = offsets.indices.contains(self.firstVisible) ? offsets[self.firstVisible] : 0
    }

    var start: CGFloat {
        ceil((self.availableLength - self.length) / 2 * 2) / 2
    }

    var end: CGFloat {
        self.start + self.length
    }

    func position(of index: Int) -> CGFloat {
        guard self.centers.indices.contains(index) else { return self.start }
        let position = self.inset + self.centers[index] - self.offset
        return self.start + (self.reversed ? self.length - position : position)
    }

    var marks: [Mark] {
        guard self.count >= 1, self.length > 0 else { return [] }
        let first = max(0, self.firstVisible - 2)
        let last = min(self.count - 1, self.firstVisible + self.visibleCount + 1)
        return (first...last).map { index in
            let position = self.position(of: index)
            var scale: CGFloat = 1
            let anchors: [CGFloat] = [0, 0.44609, 0.75877, 1]
            if self.offset > 0 { scale = min(scale, anchors[min(3, max(0, index - self.firstVisible + 1))]) }
            if self.offset < self.maximumOffset {
                scale = min(scale, anchors[min(3, max(0, self.firstVisible + self.visibleCount - index))])
            }
            return Mark(index: index, position: position, scale: index == self.selection ? 1 : scale)
        }
    }

    func scale(at position: CGFloat) -> CGFloat {
        let local = self.reversed ? self.end - position : position - self.start
        var scale: CGFloat = 1
        if self.offset > 0 { scale = min(scale, self.edgeScale(distance: local)) }
        if self.offset < self.maximumOffset { scale = min(scale, self.edgeScale(distance: self.length - local)) }
        return scale
    }

    private func edgeScale(distance: CGFloat) -> CGFloat {
        // Measured native anchors: zero, 0.44609, 0.75877, and full size, one pitch apart.
        let fraction = min(3, max(0, (distance - 1) / self.pitch))
        let anchors: [CGFloat] = [0, 0.44609, 0.75877, 1]
        let lower = min(2, Int(floor(fraction)))
        return anchors[lower] + (anchors[lower + 1] - anchors[lower]) * (fraction - CGFloat(lower))
    }

    func hit(at position: CGFloat) -> Hit? {
        guard self.count >= 1, self.length > 0, position >= self.start, position <= self.end else { return nil }
        if let nearest = self.marks.min(by: { abs($0.position - position) < abs($1.position - position) }),
           nearest.scale > 0.2, abs(nearest.position - position) <= (self.widths[nearest.index] + self.gap) / 2
        {
            return .indicator(nearest.index)
        }
        let currentPosition = self.position(of: self.selection)
        let physical = position < currentPosition ? -1 : 1
        return .step(self.reversed ? -physical : physical)
    }
}
