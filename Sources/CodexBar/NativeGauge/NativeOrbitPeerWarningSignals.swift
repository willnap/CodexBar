import Foundation

enum NativeOrbitPeerWarningSignals {
    struct Account {
        let id: String
        let provider: String
        let label: String
        let isActive: Bool
        /// Only measured, still-current limits. Unknown accounts supply an empty dictionary.
        let limits: [String: Double]
    }

    static func lights(for account: Account, peers: [Account]) -> [NativeOrbitWarningLight] {
        let cohort = peers.filter { $0.provider == account.provider }
        guard !cohort.isEmpty else { return [] }
        if cohort.count > 1, cohort.allSatisfy({ $0.limits.values.contains { $0.isFinite && $0 >= 1 } }) {
            return [.init(.allExhausted, .critical, "All accounts have an exhausted allowance.")]
        }
        guard account.isActive else { return [] }
        let pressured = account.limits.filter { $0.value.isFinite && $0.value >= 0.9 }.keys
        guard !pressured.isEmpty else { return [] }
        if let peer = cohort.first(where: { peer in
            peer.id != account.id && !peer.limits.values.contains { !$0.isFinite || $0 >= 1 }
                && pressured.allSatisfy { id in
                    peer.limits[id].map { $0.isFinite && $0 >= 0 && $0 < 0.5 } == true
                }
        }) {
            return [.init(
                .switching,
                .opportunity,
                "\(peer.label) has over 50% of this allowance left.",
                tooltipDetail: "Another account has over 50% of this allowance left.")]
        }
        return []
    }
}
