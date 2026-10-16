import Testing
@testable import CodexBar

@MainActor
struct NativeOrbitBadgeVisualAliasTests {
    @Test func canonicalizationChangesOnlyTheVerifiedAlias() {
        #expect(NativeOrbitBadgeSearch.canonicalArtworkSymbol("figure.indoor.rowing") == "figure.rower")
        for symbol in ["figure.rower", "figure.outdoor.rowing", "figure.rolling", "figure.indoor.cycle"] {
            #expect(NativeOrbitBadgeSearch.canonicalArtworkSymbol(symbol) == symbol)
        }
    }

    /// Both names are offered by the inventory, but their verified identical pixels spend one slot.
    @Test func actualInventoryDeduplicatesVerifiedIndoorRowingAliases() {
        let keys: Set = ["native:figure.rower", "native:figure.indoor.rowing"]
        let entries = NativeOrbitBadgeVocabulary.entries.filter { keys.contains($0.key) }
        #expect(entries.count == 2)
        for query in [nil, "indoor rowing ergometer"] as [String?] {
            let candidates = NativeOrbitBadgeSearch.candidates(
                text: "Indoor rowing ergometer",
                peers: [],
                query: query,
                entries: entries,
                limit: 8)
            #expect(candidates.count == 1)
            let reversed = NativeOrbitBadgeSearch.candidates(
                text: "Indoor rowing ergometer",
                peers: [],
                query: query,
                entries: entries.reversed(),
                limit: 8)
            #expect(candidates.map(\.entry.key) == reversed.map(\.entry.key))
        }
    }

    /// Different retrieval queries can select either alias; the final set still cannot show duplicate pixels.
    @Test func actualMergerRejectsVerifiedIndoorRowingAliasCollision() {
        let accounts = [
            Self.account("rower", label: "Indoor rower competition"),
            Self.account("ergometer", label: "Ergometer workout planning"),
        ]
        let contexts = NativeOrbitBadgeResolver.modelAccounts(accounts)
        for context in contexts {
            let query = context.id == "rower" ? "rower" : "ergometer workout"
            let expectedKey = context.id == "rower" ? "native:figure.rower" : "native:figure.indoor.rowing"
            #expect(NativeOrbitBadgeModel.candidateKeys(
                for: context,
                peers: contexts.filter { $0.id != context.id }.map(\.label),
                source: context.label,
                query: query).contains(expectedKey))
        }
        let badges = NativeOrbitBadgeResolver.mergedBadges(
            [
                .init(
                    accountID: "rower",
                    key: "native:figure.rower",
                    symbol: "figure.rower",
                    evidence: "Indoor rower competition",
                    searchQuery: "rower"),
                .init(
                    accountID: "ergometer",
                    key: "native:figure.indoor.rowing",
                    symbol: "figure.indoor.rowing",
                    evidence: "Ergometer workout planning",
                    searchQuery: "ergometer workout"),
            ],
            for: accounts,
            purposes: ["rower": "Indoor rower competition", "ergometer": "Ergometer workout planning"])

        #expect(badges["rower"] != "figure.rower")
        #expect(badges["ergometer"] != "figure.indoor.rowing")
    }

    /// The outdoor boat and foam roller depict different objects and must remain usable beside an ergometer.
    @Test(arguments: [
        ("Outdoor rowing club", "native:figure.outdoor.rowing", "figure.outdoor.rowing", "outdoor rowing boat"),
        ("Foam roller recovery", "native:figure.rolling", "figure.rolling", "foam roller recovery"),
    ])
    func actualMergerPreservesUnrelatedRowingAndRollingGlyphs(_ peer: (String, String, String, String)) {
        let accounts = [Self.account("rower", label: "Indoor rower competition"), Self.account("peer", label: peer.0)]
        let badges = NativeOrbitBadgeResolver.mergedBadges(
            [
                .init(
                    accountID: "rower",
                    key: "native:figure.rower",
                    symbol: "figure.rower",
                    evidence: "Indoor rower competition",
                    searchQuery: "rower"),
                .init(accountID: "peer", key: peer.1, symbol: peer.2, evidence: peer.0, searchQuery: peer.3),
            ],
            for: accounts,
            purposes: ["rower": "Indoor rower competition", "peer": peer.0])

        #expect(badges["rower"] == "figure.rower")
        #expect(badges["peer"] == peer.2)
    }

    /// Previously accepted aliases must not collide when a partial retry retains a successful peer.
    @Test func retainedSuccessesRejectVerifiedAliasCollision() {
        let accounts = [
            Self.account("rower", label: "Indoor rower competition"),
            Self.account("peer", label: "Ergometer workout"),
        ]
        let previous = NativeOrbitBadgeResolver.Refinement(
            badges: ["rower": "figure.rower"], complete: false, accepted: ["rower": "figure.rower"])
        let incoming = NativeOrbitBadgeResolver.Refinement(
            badges: ["peer": "figure.indoor.rowing"],
            complete: false,
            accepted: ["peer": "figure.indoor.rowing"],
            failed: ["rower"])
        let merged = NativeOrbitBadgeResolver.retainingSuccesses(previous, incoming: incoming, accounts: accounts)

        #expect(merged.accepted.isEmpty)
        #expect(!merged.badges.values.contains("figure.rower"))
        #expect(!merged.badges.values.contains("figure.indoor.rowing"))
    }

    private static func account(_ id: String, label: String) -> NativeOrbitAccountPresentation {
        .init(
            id: id,
            label: label,
            email: id + "@gmail.com",
            symbol: "gearshape",
            isActive: false,
            canActivate: false,
            gauge: ComputeGauge.State(),
            updatedAt: nil,
            history: [],
            odometer: nil,
            odometerHelp: nil,
            statusText: nil,
            selection: .none)
    }
}
