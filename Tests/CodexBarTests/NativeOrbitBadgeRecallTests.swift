import NaturalLanguage
import Testing
@testable import CodexBar

@MainActor
struct NativeOrbitBadgeRecallTests {
    private static func entry(_ key: String, _ title: String, _ symbol: String) -> NativeOrbitBadgeCatalog.Entry {
        .init(key: key, title: title, symbol: symbol, kind: .meaning, domains: [], clues: [title])
    }

    private static let entries = [
        entry("club", "club", "person.3.fill"),
        entry("walking", "walk", "figure.walk"),
        entry("walking-circle", "walk", "figure.walk.circle"),
        entry("walking-circle-fill", "walk", "figure.walk.circle.fill"),
        entry("flower", "flower", "camera.macro"),
        entry("painting", "paint", "paintpalette.fill"),
    ]

    /// A broad literal hit must not suppress an unrepresented activity qualifier.
    @Test func retrievesAnUnmatchedActivityBesideAKnownBroadWord() throws {
        _ = try #require(NLEmbedding.wordEmbedding(for: .english))
        let results = NativeOrbitBadgeSearch.candidates(
            text: "Strolling club", peers: ["Painting"], query: "Strolling club", entries: Self.entries, limit: 8)
        #expect(results.first?.entry.key == "club")
        #expect(results.contains { $0.entry.symbol.hasPrefix("figure.walk") })
    }

    /// An ambiguous broad term may have more literal matches than the final model budget.
    @Test func preservesRecallWhenBroadLiteralMatchesFillTheBudget() throws {
        _ = try #require(NLEmbedding.wordEmbedding(for: .english))
        let broad = (0..<9).map { Self.entry("club-\($0)", "club", "person.\($0)") }
        let results = NativeOrbitBadgeSearch.candidates(
            text: "Strolling club", peers: [], query: "Strolling club", entries: Self.entries + broad, limit: 8)
        #expect(results.count == 8)
        #expect(results.first?.entry.key == "club")
        #expect(results.contains { $0.entry.symbol.hasPrefix("figure.walk") })
    }

    /// A word with any literal vocabulary match must not trigger speculative neighbors.
    @Test func representedActivityDoesNotRequestEmbeddingRecall() {
        let represented = Self.entries + [Self.entry("stroll", "stroll", "shoe.fill")]
        let results = NativeOrbitBadgeSearch.candidates(
            text: "Strolling club", peers: [], query: "Strolling club", entries: represented, limit: 8)
        #expect(results.contains { $0.entry.key == "stroll" })
        #expect(!results.contains { $0.entry.symbol.hasPrefix("figure.walk") })
    }

    /// Name embeddings must not manufacture an interest from a person's name.
    @Test func doesNotWidenHumanNamesIntoObjects() throws {
        _ = try #require(NLEmbedding.wordEmbedding(for: .english))
        let results = NativeOrbitBadgeSearch.candidates(
            text: "Rose and the club", peers: ["Alice"], query: "Rose and the", entries: Self.entries, limit: 8)
        #expect(results.isEmpty)
    }

    /// Model recovery queries may lowercase a name recognized in the original visible label.
    @Test func preservesSourceNameExclusionWhenQueryIsLowercased() throws {
        _ = try #require(NLEmbedding.wordEmbedding(for: .english))
        let results = NativeOrbitBadgeSearch.candidates(
            text: "Rose and the club", peers: ["Alice"], query: "rose and the", entries: Self.entries, limit: 8)
        #expect(results.isEmpty)
    }

    /// Function words cannot supply a semantic subject even if an embedding is installed.
    @Test func doesNotWidenFunctionWords() {
        let results = NativeOrbitBadgeSearch.candidates(
            text: "The and for", peers: [], query: "the and for", entries: Self.entries, limit: 8)
        #expect(results.isEmpty)
    }

    /// Several glyph suffixes for one activity must leave room for other meanings.
    @Test func nearestNeighborsOfferDistinctFamiliesAndRespectLimits() throws {
        _ = try #require(NLEmbedding.wordEmbedding(for: .english))
        let results = NativeOrbitBadgeSearch.candidates(
            text: "Strolling", peers: [], query: "Strolling", entries: Self.entries, limit: 8)
        #expect(results.filter { $0.entry.symbol.hasPrefix("figure.walk") }.count == 1)
        #expect(results.count <= 3)
        for limit in [-1, 0, 1, 2] {
            let bounded = NativeOrbitBadgeSearch.candidates(
                text: "Strolling club", peers: [], query: "Strolling club", entries: Self.entries, limit: limit)
            #expect(bounded.count <= max(0, limit))
        }
    }

    /// Tied literal and embedding scores cannot depend on inventory iteration order.
    @Test func recallOrderingIsStableAcrossInventoryOrder() throws {
        _ = try #require(NLEmbedding.wordEmbedding(for: .english))
        let first = NativeOrbitBadgeSearch.candidates(
            text: "Strolling club", peers: [], query: "Strolling club", entries: Self.entries, limit: 8)
        let reversed = NativeOrbitBadgeSearch.candidates(
            text: "Strolling club", peers: [], query: "Strolling club", entries: Self.entries.reversed(), limit: 8)
        #expect(first.map(\.entry.key) == reversed.map(\.entry.key))
        #expect(first.map(\.evidence) == reversed.map(\.evidence))
    }
}
