import Testing
@testable import CodexBar

/// Actual-merger regressions for partial source preparation; no language-model calls.
@MainActor struct NativeOrbitBadgePartialSourceTests {
    @Test func `missing selected peer source remains unknown rather than its stale alias`() {
        let badges = NativeOrbitBadgeResolver.mergedBadges(
            [Self.pianoProposal],
            for: Self.accounts(stalePianoAlias: true),
            purposes: ["music-lessons": "Piano lessons"])

        #expect(badges["music-lessons"] == "pianokeys")
    }

    @Test func `shared selected sources still reject even with an expanded query`() {
        let badges = NativeOrbitBadgeResolver.mergedBadges(
            [Self.pianoProposal],
            for: Self.accounts(stalePianoAlias: true),
            purposes: ["music-lessons": "Piano lessons", "tax-records": "Piano lessons"])

        #expect(badges["music-lessons"] != "pianokeys")
    }

    @Test func `missing target source cannot recover raw meaning inside a partial source map`() {
        let badges = NativeOrbitBadgeResolver.mergedBadges(
            [Self.pianoProposal],
            for: Self.accounts(stalePianoAlias: false),
            purposes: ["tax-records": "Tax returns"])

        #expect(badges["music-lessons"] != "pianokeys")
    }

    @Test func `legacy empty source map still uses the distinct raw account sources`() {
        let badges = NativeOrbitBadgeResolver.mergedBadges(
            [Self.pianoProposal], for: Self.accounts(stalePianoAlias: false))

        #expect(badges["music-lessons"] == "pianokeys")
    }

    private static let pianoProposal = NativeOrbitBadgeModel.Proposal(
        accountID: "music-lessons",
        key: "native:pianokeys",
        symbol: "pianokeys",
        evidence: "Piano lessons",
        searchQuery: "Piano lessons; keyboard; musical instrument")

    private static func accounts(stalePianoAlias: Bool) -> [NativeOrbitAccountPresentation] {
        [
            self.account("music-lessons", label: "Piano lessons", email: "learner@gmail.com"),
            self.account(
                "tax-records",
                label: "Tax returns",
                email: stalePianoAlias
                    ? "old.piano.lessons@gmail.com" : "annual.records@gmail.com"),
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
