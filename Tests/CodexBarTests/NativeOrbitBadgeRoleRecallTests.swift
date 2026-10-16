import Testing
@testable import CodexBar

@MainActor
struct NativeOrbitBadgeRoleRecallTests {
    private static func entry(_ key: String, _ title: String, _ symbol: String) -> NativeOrbitBadgeCatalog.Entry {
        .init(key: key, title: title, symbol: symbol, kind: .meaning, domains: [], clues: [title])
    }

    private static let entries = [
        entry("work", "work office", "briefcase.fill"),
        entry("personal", "personal private", "person.crop.square.fill"),
        entry("family", "family parents", "figure.2.and.child.holdinghands"),
        entry("records", "records documents notes archive", "doc.text.fill"),
        entry("map", "atlas map", "map.fill"),
    ]

    /// Recovery queries may omit the role, but the original source still contains the actual distinction.
    @Test func uniqueRolesSurviveAQueryContainingOnlyTheSharedSubject() {
        let work = NativeOrbitBadgeSearch.candidates(
            text: "Work records", peers: ["Personal records"], query: "records", entries: Self.entries, limit: 1)
        let personal = NativeOrbitBadgeSearch.candidates(
            text: "Personal records", peers: ["Work records"], query: "records", entries: Self.entries, limit: 1)
        #expect(work.first?.entry.key == "work")
        #expect(personal.first?.entry.key == "personal")
    }

    /// A known concrete token must not hide a contrasting role used as part of a named account.
    @Test func namedConceptKeepsItsUniqueRoleQualifier() {
        let candidates = NativeOrbitBadgeSearch.candidates(
            text: "Atlas Work", peers: ["Atlas Personal"], query: "Atlas work", entries: Self.entries, limit: 1)
        #expect(candidates.first?.entry.key == "work")
    }

    /// Many shared subject matches cannot spend all of the budget before the owned unique role.
    @Test func multipleSharedSubjectWordsDoNotCrowdOutAUniqueRole() {
        let candidates = NativeOrbitBadgeSearch.candidates(
            text: "Family records documents notes archive",
            peers: ["Work records documents notes archive"],
            query: "records documents notes archive",
            entries: Self.entries,
            limit: 1)
        #expect(candidates.first?.entry.key == "family")
    }

    /// Recovery must not invent a unique role when that role belongs to the peer as well.
    @Test func sharedRolesStaySuppressedWhenConcreteSubjectsDiffer() {
        let candidates = NativeOrbitBadgeSearch.candidates(
            text: "Work records", peers: ["Work atlas"], query: "work records", entries: Self.entries, limit: 8)
        #expect(candidates.contains { $0.entry.key == "records" })
        #expect(!candidates.contains { $0.entry.key == "work" })
    }

    /// Recovering an omitted generic context must not invent extra hits beside a distinct concrete subject.
    @Test func uniqueConcreteSubjectDoesNotRecoverAnUnqueriedLesson() {
        let entries = [
            Self.entry("cycling", "cycle cycling bicycle", "bicycle"),
            Self.entry("indoor-cycling", "indoor cycling", "figure.indoor.cycle"),
            Self.entry("lessons", "lessons textbooks learning", "books.vertical.fill"),
        ]
        let candidates = NativeOrbitBadgeSearch.candidates(
            text: "Cycling lessons",
            peers: ["Pottery workshop"],
            query: "cycling instruction",
            entries: entries,
            limit: 8)

        #expect(candidates.contains { $0.entry.key == "cycling" })
        #expect(!candidates.contains { $0.entry.key == "lessons" })
    }

    /// Broad expansion tags must leave the literal activity available in the actual symbol inventory.
    @Test func uniqueActivitySurvivesBroadEducationExpansion() {
        let candidates = NativeOrbitBadgeSearch.candidates(
            text: "Cycling lessons",
            peers: ["Pottery workshop"],
            query: "cycling instruction education",
            entries: NativeOrbitBadgeVocabulary.entries,
            limit: 8)

        #expect(candidates.contains { $0.entry.symbol == "bicycle" })
    }

    /// A shared generic context cannot become distinguishing just because the subject is concrete.
    @Test func sharedContextIsNotRecoveredAlongsideDistinctSubjects() {
        let entries = [
            Self.entry("cycling", "cycle cycling bicycle", "bicycle"),
            Self.entry("lessons", "lessons textbooks learning", "books.vertical.fill"),
        ]
        let candidates = NativeOrbitBadgeSearch.candidates(
            text: "Cycling lessons",
            peers: ["Pottery lessons"],
            query: "cycling instruction",
            entries: entries,
            limit: 8)

        #expect(candidates.first?.entry.key == "cycling")
        #expect(!candidates.contains { $0.entry.key == "lessons" })
    }

    /// Contrasting roles remain deterministic across inventory order and all public bounds.
    @Test func recoveredRolesPreserveOrderStabilityAndLimits() {
        for limit in [-1, 0, 1, 3, 8] {
            let first = NativeOrbitBadgeSearch.candidates(
                text: "Work records",
                peers: ["Personal records"],
                query: "records",
                entries: Self.entries,
                limit: limit)
            let reversed = NativeOrbitBadgeSearch.candidates(
                text: "Work records",
                peers: ["Personal records"],
                query: "records",
                entries: Self.entries.reversed(),
                limit: limit)
            #expect(first.map(\.entry.key) == reversed.map(\.entry.key))
            #expect(first.count <= max(0, limit))
        }
    }
}
