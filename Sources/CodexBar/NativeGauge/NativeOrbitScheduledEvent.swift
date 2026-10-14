import Foundation

/// A known event ahead of now: a provider-reported reset deadline, or one of the projection's typed marks.
struct NativeOrbitScheduledEvent: Identifiable, Hashable, Sendable {
    enum Kind: String, Hashable, Sendable {
        /// A quota window's countdown reaches its scheduled reset.
        case windowReset
        /// A banked reset expires unused.
        case bankedResetExpiry
        /// The additional-usage billing cycle starts over.
        case additionalUsageCycle
        /// The plan's subscription ends.
        case planExpiry
    }

    let id: String
    let date: Date
    let label: String
    let recoveryPercent: Double?
    var kind: Kind = .windowReset
    /// Quota lanes the event starts over; empty for account-wide events.
    var laneIDs: [String] = []
    var quantity = 1
}
