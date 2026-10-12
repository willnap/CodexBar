import Foundation

/// Stable groups keep services in use at the front without discarding the user's custom order.
enum ProviderSettingsOrdering {
    static func prioritized<ID>(
        _ providers: [ID],
        enabled: (ID) -> Bool,
        configured: (ID) -> Bool,
        usedFirst: Bool = true) -> [ID]
    {
        guard usedFirst else { return providers }
        return providers.filter(enabled)
            + providers.filter { !enabled($0) && configured($0) }
            + providers.filter { !enabled($0) && !configured($0) }
    }

    /// Reorder one visible group while leaving the other providers in their original slots.
    static func reordered<ID: Hashable>(
        _ providers: [ID],
        visible: [ID],
        fromOffsets: IndexSet,
        toOffset: Int) -> [ID]
    {
        let offsets = fromOffsets.filter { visible.indices.contains($0) }
        let moving = offsets.map { visible[$0] }
        var reordered = visible.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        let destination = min(max(0, toOffset - offsets.count(where: { $0 < toOffset })), reordered.count)
        reordered.insert(contentsOf: moving, at: destination)
        let visibleIDs = Set(visible)
        var iterator = reordered.makeIterator()
        return providers.map { visibleIDs.contains($0) ? (iterator.next() ?? $0) : $0 }
    }
}
