import Foundation
import Testing
@testable import CodexBar

/// Real retrieval and merger checks; these tests never call the language-model SDK.
@MainActor struct NativeOrbitBadgeSharedIdentityTests {
    private static let teacherLabels = [
        "Teacher — first login", "Teacher — second login", "Teacher — third login",
    ]

    @Test func `ordinal logins cannot make a shared teacher role meaningfully distinct`() {
        for label in Self.teacherLabels {
            let peers = Self.teacherLabels.filter { $0 != label }
            #expect(!NativeOrbitBadgeSearch.hasDistinctMeaning(in: label, peers: peers))
            let account = NativeOrbitBadgeModel.Account(id: label, text: label)
            #expect(NativeOrbitBadgeModel.candidateKeys(
                for: account, peers: peers, source: label, query: "education instructor pedagogy classroom").isEmpty)
        }
    }

    @Test func `entries with no literal teacher word still reject a wholly shared role`() {
        let entries = NativeOrbitBadgeVocabulary.entries.filter {
            ["studentdesk", "books.vertical.fill", "graduationcap.fill"].contains($0.symbol)
        }
        #expect(entries.count == 3)
        for entry in entries {
            #expect(!NativeOrbitBadgeSearch.isDistinctCandidate(
                entry, source: Self.teacherLabels[0], peers: Array(Self.teacherLabels.dropFirst())))
        }
    }

    @Test func `the actual merger blocks all three unsupported teacher proposals`() {
        let symbols = ["studentdesk", "books.vertical.fill", "books.vertical.fill"]
        let proposals = zip(Self.teacherLabels.indices, symbols).map { index, symbol in
            let entry = NativeOrbitBadgeVocabulary.entries.first { $0.symbol == symbol }!
            return NativeOrbitBadgeModel.Proposal(
                accountID: "teacher-\(index)",
                key: entry.key,
                symbol: symbol,
                evidence: Self.teacherLabels[index],
                searchQuery: "education instructor pedagogy classroom")
        }
        let accounts = Self.teacherLabels.enumerated().map { Self.account("teacher-\($0.offset)", $0.element) }
        let purposes = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0.label) })
        let merged = NativeOrbitBadgeResolver.mergedBadges(proposals, for: accounts, purposes: purposes)
        #expect(merged.count == accounts.count)
        let literal = Set(NativeOrbitBadgeCatalog.all.filter { $0.kind == .letter || $0.kind == .number }.map(\.symbol))
        for index in Self.teacherLabels.indices {
            #expect(!symbols.contains(merged["teacher-\(index)"] ?? ""))
            #expect(literal.contains(merged["teacher-\(index)"] ?? ""))
        }
    }

    @Test func `different actual subjects survive ordinal login normalization`() throws {
        let math = "Teacher — first login Math"
        let art = "Teacher — second login Art"
        #expect(NativeOrbitBadgeSearch.hasDistinctMeaning(in: math, peers: [art]))
        #expect(NativeOrbitBadgeSearch.hasDistinctMeaning(in: art, peers: [math]))
        let mathKeys = NativeOrbitBadgeModel.candidateKeys(
            for: .init(id: "math", text: math), peers: [art], source: math, query: "mathematics function")
        let artKeys = NativeOrbitBadgeModel.candidateKeys(
            for: .init(id: "art", text: art), peers: [math], source: art, query: "art painting")
        let mathEntry = try #require(NativeOrbitBadgeVocabulary.entries.first { $0.symbol == "function" })
        let artEntry = try #require(NativeOrbitBadgeVocabulary.entries.first { $0.symbol == "paintpalette.fill" })
        #expect(mathKeys.contains(mathEntry.key))
        #expect(artKeys.contains(artEntry.key))
    }

    @Test func `first aid stays distinct from botany and keeps its medical candidates`() {
        let source = "First-aid supplies"
        #expect(NativeOrbitBadgeSearch.hasDistinctMeaning(in: source, peers: ["Botany specimens"]))
        let keys = NativeOrbitBadgeModel.candidateKeys(
            for: .init(id: "aid", text: source), peers: ["Botany specimens"], source: source, query: "first aid")
        let medical = Set(NativeOrbitBadgeVocabulary.entries.filter {
            ["cross.case.fill", "bandage.fill", "cross.fill"].contains($0.symbol)
        }.map(\.key))
        #expect(!keys.isDisjoint(with: medical))
        #expect(NativeOrbitBadgeSearch.words(source).contains("first"))
    }

    @Test(arguments: [
        ("Secondhand books", "New books"),
        ("Project 3D", "Project 2D"),
        ("Project OneDrive", "Project ThreeRivers"),
        ("Project ThreeRivers", "Project OneDrive"),
        ("2FA authentication", "OAuth2 authentication"),
    ])
    func `descriptive and named compounds retain their actual distinctions`(_ pair: (String, String)) {
        #expect(NativeOrbitBadgeSearch.hasDistinctMeaning(in: pair.0, peers: [pair.1]))
    }

    @Test(arguments: [
        ("Build 1", "Build 2"),
        ("Prototype one", "Prototype two"),
        ("Prototype twenty-first", "Prototype twenty-second"),
        ("Teacher — 1st login", "Teacher — 2nd login"),
    ])
    func `numeric identity versions cannot invent another semantic subject`(_ pair: (String, String)) {
        #expect(!NativeOrbitBadgeSearch.hasDistinctMeaning(in: pair.0, peers: [pair.1]))
    }

    @Test func `shared identity checks remain bounded from two through twenty four accounts`() {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en")
        formatter.numberStyle = .spellOut
        let clock = ContinuousClock()
        let start = clock.now
        for count in 2...24 {
            let labels = (1...count).map { "Teacher — \(formatter.string(from: NSNumber(value: $0))!) login" }
            for label in labels {
                let peers = labels.filter { $0 != label }
                #expect(!NativeOrbitBadgeSearch.hasDistinctMeaning(in: label, peers: peers))
                let account = NativeOrbitBadgeModel.Account(id: label, text: label)
                #expect(NativeOrbitBadgeModel.candidateKeys(
                    for: account, peers: peers, source: label, query: "education instructor classroom").isEmpty)
            }
        }
        print("Shared identity2...24 account probe elapsed: \(start.duration(to: clock.now))")
    }

    private static func account(_ id: String, _ label: String) -> NativeOrbitAccountPresentation {
        .init(
            id: id,
            label: label,
            email: nil,
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
