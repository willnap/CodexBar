import Testing
@testable import CodexBar

@MainActor
struct NativeOrbitBadgeNormalizationTests {
    /// The same English spelling must remain searchable in noun and verb contexts.
    @Test func exactSurfaceSurvivesContextDependentLemmas() {
        #expect(NativeOrbitBadgeSearch.words("Gardening club").contains("gardening"))
        #expect(NativeOrbitBadgeSearch.words("plants gardening foliage").contains("gardening"))
        #expect(NativeOrbitBadgeSearch.words("Drawings archive").contains("drawings"))
        #expect(NativeOrbitBadgeSearch.words("drawing pencil sketch").contains("drawing"))
    }

    /// Identical owned spelling must match a vocabulary description regardless of sentence-level lemma choice.
    @Test func contextDependentLemmaCannotHideTheExactVocabularyWord() {
        let entry = NativeOrbitBadgeCatalog.Entry(
            key: "garden",
            title: "plants gardening foliage",
            symbol: "leaf.fill",
            kind: .meaning,
            domains: [],
            clues: [])
        let candidates = NativeOrbitBadgeSearch.candidates(text: "Gardening club", peers: [], entries: [entry])
        #expect(candidates.first?.entry.symbol == "leaf.fill")
    }

    /// Inflections of one purpose must not manufacture a difference between accounts.
    @Test func nounInflectionsRemainOneSharedPurpose() {
        #expect(NativeOrbitBadgeSearch.purposeWords("Drawings") == NativeOrbitBadgeSearch.purposeWords("Drawing"))
        #expect(!NativeOrbitBadgeSearch.hasDistinctMeaning(in: "Drawings", peers: ["Drawing"]))
    }

    /// Semantic comparison must ignore inflection even while lexical retrieval preserves original spellings.
    @Test func comparisonWordsUseOnlyStableCanonicalForms() {
        #expect(NativeOrbitBadgeSearch.comparisonWords("Drawings") == ["draw"])
        #expect(NativeOrbitBadgeSearch.comparisonWords("Drawing") == ["draw"])
        #expect(NativeOrbitBadgeSearch.comparisonWords("Gardening club") == ["garden", "club"])
        #expect(NativeOrbitBadgeSearch.words("Drawings").contains("drawings"))
    }

    /// Cache insertion and vocabulary order must not change normalization or retrieval.
    @Test func normalizedRetrievalIsStableAcrossWordAndEntryOrder() {
        let first = NativeOrbitBadgeSearch.words("gardening")
        _ = NativeOrbitBadgeSearch.words("plants gardening foliage")
        _ = NativeOrbitBadgeSearch.words("Gardening club")
        #expect(NativeOrbitBadgeSearch.words("gardening") == first)
        let entries: [NativeOrbitBadgeCatalog.Entry] = [
            .init(
                key: "garden",
                title: "plants gardening foliage",
                symbol: "leaf.fill",
                kind: .meaning,
                domains: [],
                clues: []),
            .init(
                key: "drawing",
                title: "drawing pencil sketch",
                symbol: "pencil",
                kind: .meaning,
                domains: [],
                clues: []),
        ]
        let normal = NativeOrbitBadgeSearch.candidates(text: "Gardening club", peers: [], entries: entries)
        let reversed = NativeOrbitBadgeSearch.candidates(text: "Gardening club", peers: [], entries: entries.reversed())
        #expect(normal.map(\.entry.key) == reversed.map(\.entry.key))
    }
}
