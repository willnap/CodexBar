import Testing
@testable import CodexBar

@MainActor
struct NativeOrbitBadgeSearchRankingTests {
    private static func entry(_ key: String, _ title: String, _ symbol: String) -> NativeOrbitBadgeCatalog.Entry {
        .init(key: key, title: title, symbol: symbol, kind: .meaning, domains: [], clues: [title])
    }

    private static let activities = [
        entry("a-qualified", "running treadmill", "figure.run.treadmill"),
        entry("z-direct", "running", "figure.run"),
    ]

    /// An extra unmentioned subtype cannot beat the direct glyph because its key sorts first.
    @Test func unqualifiedActivityWinsLexicalTieBySymbolMeaningCoverage() {
        for query in [nil, "Running"] as [String?] {
            let results = NativeOrbitBadgeSearch.candidates(
                text: "Running", peers: [], query: query, entries: Self.activities, limit: 1)
            #expect(results.first?.entry.key == "z-direct")
        }
    }

    /// Family deduplication must retain the subtype when its explicit qualifier raises the lexical score.
    @Test func explicitQualifierKeepsTheQualifiedFamilyRepresentative() {
        for query in [nil, "Running treadmill"] as [String?] {
            let results = NativeOrbitBadgeSearch.candidates(
                text: "Running treadmill", peers: [], query: query, entries: Self.activities, limit: 2)
            #expect(results.map(\.entry.key) == ["a-qualified"])
        }
    }

    /// Literal circle and fill variants must not consume the budget before another visual family.
    @Test func duplicateLiteralVariantsLeaveRoomForAnotherFamily() {
        let entries = [
            Self.entry("a-run", "running", "figure.run"),
            Self.entry("b-run-circle", "running", "figure.run.circle"),
            Self.entry("c-run-circle-fill", "running", "figure.run.circle.fill"),
            Self.entry("z-shoe", "running", "shoe.fill"),
        ]
        for query in [nil, "Running"] as [String?] {
            let results = NativeOrbitBadgeSearch.candidates(
                text: "Running", peers: [], query: query, entries: entries, limit: 2)
            #expect(results.map(\.entry.key) == ["a-run", "z-shoe"])
        }
    }

    /// Input enumeration cannot change semantic tie breaks or the final family budget.
    @Test func rankingRemainsPermutationStableAndBounded() {
        for limit in [-1, 0, 1, 2, 8] {
            let first = NativeOrbitBadgeSearch.candidates(
                text: "Running", peers: [], entries: Self.activities, limit: limit)
            let reversed = NativeOrbitBadgeSearch.candidates(
                text: "Running", peers: [], entries: Self.activities.reversed(), limit: limit)
            #expect(first.map(\.entry.key) == reversed.map(\.entry.key))
            #expect(first.count <= max(0, limit))
            #expect(first.count <= 1)
        }
    }
}
