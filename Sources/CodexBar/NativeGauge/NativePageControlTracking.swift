import Foundation

/// Gesture coordinates follow the complete logical page sequence, independently of provider expansion or
/// viewport motion. Inserting account marks under a moving pointer therefore cannot change its target.
struct NativePageControlTracking {
    let pageIDs: [String]
    let startPosition: CGFloat
    let lowerEdge: CGFloat
    let upperEdge: CGFloat
    let reversed: Bool
    let allowsContinuousInteraction: Bool
    let pitch: CGFloat
    private let startIndex: Int
    private var edgeOffset = 0
    private var lastPosition: CGFloat
    private(set) var index: Int
    private(set) var interaction = NativePageControlInteraction.discrete
    private(set) var movedBeyondClick = false

    init(
        pageIDs: [String],
        selectedID: String,
        touchedID: String,
        position: CGFloat,
        lowerEdge: CGFloat,
        upperEdge: CGFloat,
        reversed: Bool = false,
        allowsContinuousInteraction: Bool = true,
        pitch: CGFloat = 22)
    {
        self.pageIDs = pageIDs
        self.startPosition = position
        self.lastPosition = position
        self.lowerEdge = lowerEdge
        self.upperEdge = upperEdge
        self.reversed = reversed
        self.allowsContinuousInteraction = allowsContinuousInteraction
        self.pitch = max(1, pitch)
        self.index = pageIDs.firstIndex(of: selectedID) ?? 0
        self.startIndex = pageIDs.firstIndex(of: touchedID) ?? self.index
    }

    var selectedID: String? {
        self.pageIDs.indices.contains(self.index) ? self.pageIDs[self.index] : nil
    }

    var edgeDirection: Int {
        guard self.interaction == .continuous else { return 0 }
        let direction = self.lastPosition < self.lowerEdge ? -1 : self.lastPosition > self.upperEdge ? 1 : 0
        return self.reversed ? -direction : direction
    }

    mutating func update(position: CGFloat, forceContinuous: Bool = false) -> String? {
        guard position.isFinite, !self.pageIDs.isEmpty else { return nil }
        self.lastPosition = position
        self.movedBeyondClick = self.movedBeyondClick || abs(position - self.startPosition) >= 4
        guard self.allowsContinuousInteraction, self.movedBeyondClick || forceContinuous
            || self.interaction == .continuous else { return nil }
        let beginning = self.interaction != .continuous
        self.interaction = .continuous
        let displacement = ((position - self.startPosition) / self.pitch).rounded() * (self.reversed ? -1 : 1)
        let next = Int(min(CGFloat(self.pageIDs.count - 1), max(
            0,
            CGFloat(self.startIndex + self.edgeOffset) + displacement)))
        guard next != self.index || beginning else { return nil }
        self.index = next
        return self.selectedID
    }

    mutating func advanceEdge() -> String? {
        let direction = self.edgeDirection
        guard direction != 0, !self.pageIDs.isEmpty else { return nil }
        let next = min(self.pageIDs.count - 1, max(0, self.index + direction))
        guard next != self.index else { return nil }
        self.index = next
        self.edgeOffset += direction
        return self.selectedID
    }
}

struct NativePageControlWheel {
    private var remainder: CGFloat = 0

    mutating func reset() { self.remainder = 0 }

    mutating func consume(delta: CGFloat, precise: Bool) -> Int {
        guard delta.isFinite else { return 0 }
        if !precise {
            self.remainder = 0
            return -Int(min(10, max(-10, delta.rounded())))
        }
        self.remainder += delta
        let steps = Int(min(10, max(-10, (self.remainder / 20).rounded(.towardZero))))
        self.remainder -= CGFloat(steps) * 20
        return -steps
    }
}

/// A completed edge timer may restart in the same direction; an older cancelled timer must never clear its successor.
struct NativePageControlRepeatState {
    private(set) var direction = 0
    private var generation: UUID?

    mutating func begin(direction: Int) -> UUID? {
        guard direction != 0, self.direction != direction || self.generation == nil else { return nil }
        let generation = UUID()
        self.direction = direction
        self.generation = generation
        return generation
    }

    @discardableResult
    mutating func finish(_ generation: UUID) -> Bool {
        guard self.generation == generation else { return false }
        self.cancel()
        return true
    }

    mutating func cancel() {
        self.direction = 0
        self.generation = nil
    }
}

/// Keep the requested highlight stable during an animated jump, then adopt native truth if the user interrupts it.
struct NativePageControlNavigation {
    struct Request: Equatable {
        /// The page brought to the leading edge.
        let id: String
        let interaction: NativePageControlInteraction
        /// The page selected once it is there: the same page, unless resuming where the pages were left.
        var selects: String?
        let generation = UUID()

        var selectionID: String {
            self.selects ?? self.id
        }
    }

    private(set) var selectionID: String
    private(set) var visibleID: String
    private(set) var request: Request?

    init(selectionID: String) {
        self.selectionID = selectionID
        self.visibleID = selectionID
    }

    mutating func select(_ id: String, interaction: NativePageControlInteraction) {
        self.selectionID = id
        self.request = Request(id: id, interaction: interaction)
    }

    /// Bring `leadingID` back to the leading edge with `selectionID` selected, where a showing left them.
    mutating func resume(selectionID: String, leadingID: String) {
        self.selectionID = selectionID
        self.request = Request(id: leadingID, interaction: .continuous, selects: selectionID)
    }

    mutating func inventoryChanged(validIDs: [String], fallbackID: String) {
        let target = validIDs.contains(self.selectionID) ? self.selectionID
            : validIDs.contains(fallbackID) ? fallbackID : validIDs.first
        guard let target else { self.request = nil; return }
        self.select(target, interaction: .continuous)
    }

    mutating func observe(_ id: String?, validIDs: [String]) {
        guard let id, validIDs.contains(id) else { return }
        self.visibleID = id
        if self.request == nil || self.request?.selectionID == id { self.selectionID = id }
    }

    mutating func interrupt(at id: String?, validIDs: [String]) {
        self.request = nil
        self.observe(id, validIDs: validIDs)
        if validIDs.contains(self.visibleID) { self.selectionID = self.visibleID }
    }

    mutating func settle(at id: String?, validIDs: [String]) {
        self.observe(id, validIDs: validIDs)
        if self.request?.selectionID == self.visibleID { self.request = nil }
        if self.request == nil, validIDs.contains(self.visibleID) { self.selectionID = self.visibleID }
    }
}
