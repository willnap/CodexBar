import Testing
@testable import CodexBar

@MainActor struct NativeOrbitBadgeDistinctionTests {
    @Test func `a shared role plus different counters is not a purpose distinction`() {
        #expect(!NativeOrbitBadgeSearch.hasDistinctMeaning(
            in: "Consulting 1\nconsult.1",
            peers: ["Consulting 2\nconsult.2"]))
    }

    @Test func `account priority does not imply backups or search`() {
        #expect(!NativeOrbitBadgeSearch.hasDistinctMeaning(
            in: "Personal primary\nsam.primary",
            peers: ["Personal spare\nsam.spare"]))
    }

    @Test func `ordinary personal names alone do not request invented interests`() {
        #expect(!NativeOrbitBadgeSearch.hasDistinctMeaning(
            in: "Jordan Shaw\njordan.shaw",
            peers: ["Alice Morgan\nalice.morgan"]))
    }

    @Test func `organization and place names remain eligible mnemonic sources`() {
        #expect(NativeOrbitBadgeSearch.hasDistinctMeaning(in: "Microsoft\nm", peers: ["Nvidia\nn"]))
        #expect(NativeOrbitBadgeSearch.hasDistinctMeaning(in: "Cambridge", peers: ["Oxford"]))
    }

    @Test func `project and concept names remain eligible mnemonic sources`() {
        #expect(NativeOrbitBadgeSearch.hasDistinctMeaning(in: "Project Orion", peers: ["Project Lotus"]))
        #expect(NativeOrbitBadgeSearch.hasDistinctMeaning(in: "Orion", peers: ["Lotus"]))
    }

    @Test func `explicitly named projects do not become ordinary personal name only sources`() {
        #expect(NativeOrbitBadgeSearch.hasDistinctMeaning(
            in: "Project Jordan Shaw", peers: ["Project Alice Morgan"]))
        #expect(NativeOrbitBadgeSearch.hasDistinctMeaning(
            in: "Studio Jordan Shaw", peers: ["Studio Alice Morgan"]))
    }

    @Test func `an ordinary English mnemonic query can retrieve for a named project`() {
        let tree = NativeOrbitBadgeCatalog.Entry(
            key: "tree", title: "tree woodland", symbol: "tree.fill", kind: .meaning, domains: [], clues: [])
        let candidates = NativeOrbitBadgeSearch.candidates(
            text: "Project Cedar", peers: ["Project Maple"], query: "tree", entries: [tree])
        #expect(candidates.first?.entry.symbol == "tree.fill")
    }

    @Test func `a meaningful mailbox alias survives generic display labels`() {
        #expect(NativeOrbitBadgeSearch.hasDistinctMeaning(in: "Main\nsam.pottery", peers: ["Spare\nsam.reading"]))
        #expect(NativeOrbitBadgeSearch.hasDistinctMeaning(in: "Work", peers: ["Personal"]))
    }

    @Test func `punctuated aliases and camel case preserve actual subject boundaries`() {
        #expect(NativeOrbitBadgeSearch.words("sam.pottery+lessons").isSuperset(of: ["sam", "pottery", "lesson"]))
        #expect(NativeOrbitBadgeSearch.hasDistinctMeaning(in: "Main\nPotteryLessons", peers: ["Spare\nBookReviews"]))
    }
}
