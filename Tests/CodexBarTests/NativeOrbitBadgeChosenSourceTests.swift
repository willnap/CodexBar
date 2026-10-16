import Testing
@testable import CodexBar

/// Synthetic source-selection regressions. These tests never invoke the language model.
@MainActor
struct NativeOrbitBadgeChosenSourceTests {
    @Test func rawCombinedGateConfusesCurrentLabelsWithSwappedHistoricalAliases() throws {
        let contexts = NativeOrbitBadgeResolver.modelAccounts(Self.accounts())
        let target = try #require(contexts.first { $0.id == "current-garden" })
        let peer = try #require(contexts.first { $0.id == "current-photo" })
        let chosen = NativeOrbitBadgeModel.selectedSource("label", label: target.label, alias: target.alias)
        let peerChosen = NativeOrbitBadgeModel.selectedSource("label", label: peer.label, alias: peer.alias)

        #expect(!NativeOrbitBadgeSearch.hasDistinctMeaning(in: target.text, peers: [peer.text]))
        #expect(NativeOrbitBadgeSearch.hasDistinctMeaning(in: chosen, peers: [peerChosen]))
        #expect(NativeOrbitBadgeSearch.evidence(in: chosen, peers: [peerChosen]) != nil)
        #expect(NativeOrbitBadgeModel.candidateKeys(for: target, peers: [peer.text], query: chosen).isEmpty)
    }

    /// The selected current source must determine semantic distinctness, despite a peer's stale alias.
    @Test func actualMergerPreservesDistinctChosenCurrentSources() {
        let badges = NativeOrbitBadgeResolver.mergedBadges(
            [Self.gardeningProposal()],
            for: Self.accounts(),
            purposes: Self.currentPurposes)

        #expect(badges["current-garden"] == "leaf.fill")
    }

    /// Extra alias tokens permit retrieval, isolating the later raw-peer clue guard from the first gate.
    @Test func actualMergerDoesNotTreatHistoricalPeerAliasAsItsChosenSubject() throws {
        let accounts = Self.accounts(distinctAliasSuffixes: true)
        let contexts = NativeOrbitBadgeResolver.modelAccounts(accounts)
        let target = try #require(contexts.first { $0.id == "current-photo" })
        let peer = try #require(contexts.first { $0.id == "current-garden" })
        #expect(NativeOrbitBadgeSearch.hasDistinctMeaning(in: target.text, peers: [peer.text]))
        #expect(NativeOrbitBadgeModel.candidateKeys(
            for: target,
            peers: ["gardening"],
            source: "photography",
            query: "photography").contains("photo"))

        let badges = NativeOrbitBadgeResolver.mergedBadges(
            [
                .init(
                    accountID: "current-photo",
                    key: "photo",
                    symbol: "camera.fill",
                    evidence: "Now photography",
                    searchQuery: "photography"),
            ],
            for: accounts,
            purposes: Self.currentPurposes)

        #expect(badges["current-photo"] == "camera.fill")
    }

    /// Choosing semantic context cannot waive the original account's literal ownership requirement.
    @Test func actualMergerStillRejectsEvidenceOwnedOnlyByAnotherAccount() {
        let proposal = NativeOrbitBadgeModel.Proposal(
            accountID: "current-garden",
            key: "leaf",
            symbol: "leaf.fill",
            evidence: "Now photography",
            searchQuery: "gardening")
        let badges = NativeOrbitBadgeResolver.mergedBadges(
            [proposal],
            for: Self.accounts(),
            purposes: Self.currentPurposes)

        #expect(badges["current-garden"] != "leaf.fill")
    }

    /// Chosen sources that actually share a subject remain ineligible, regardless of distinct aliases.
    @Test func actualMergerStillRejectsSharedChosenSubject() {
        let badges = NativeOrbitBadgeResolver.mergedBadges(
            [Self.gardeningProposal()],
            for: Self.accounts(distinctAliasSuffixes: true),
            purposes: ["current-garden": "gardening", "current-photo": "gardening"])

        #expect(badges["current-garden"] != "leaf.fill")
    }

    private static let currentPurposes = [
        "current-garden": "gardening",
        "current-photo": "photography",
    ]

    private static func gardeningProposal() -> NativeOrbitBadgeModel.Proposal {
        .init(
            accountID: "current-garden",
            key: "leaf",
            symbol: "leaf.fill",
            evidence: "Now gardening",
            searchQuery: "gardening")
    }

    private static func accounts(distinctAliasSuffixes: Bool = false) -> [NativeOrbitAccountPresentation] {
        [
            self.account(
                "current-garden",
                label: "Now gardening",
                email: distinctAliasSuffixes ? "old.photography.cobalt@gmail.com" : "old.photography@gmail.com"),
            self.account(
                "current-photo",
                label: "Now photography",
                email: distinctAliasSuffixes ? "old.gardening.orbit@gmail.com" : "old.gardening@gmail.com"),
        ]
    }

    private static func account(_ id: String, label: String, email: String) -> NativeOrbitAccountPresentation {
        .init(
            id: id,
            label: label,
            email: email,
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
