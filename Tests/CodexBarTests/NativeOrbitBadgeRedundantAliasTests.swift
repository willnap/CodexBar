import Foundation
import FoundationModels
import Testing
@testable import CodexBar

@MainActor struct NativeOrbitBadgeRedundantAliasTests {
    private static func sourceChoices(label: String, alias: String) throws -> [String] {
        let encoded = try JSONEncoder().encode(NativeOrbitBadgeModel.interpretationSchema(label: label, alias: alias))
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let properties = try #require(object["properties"] as? [String: [String: Any]])
        return try #require(properties["source"]?["enum"] as? [String])
    }

    private static func account(_ id: String, _ label: String, alias: String = "") -> NativeOrbitAccountPresentation {
        .init(
            id: id,
            label: label,
            email: alias.isEmpty ? nil : alias + "@gmail.com",
            symbol: "person.crop.circle",
            isActive: false,
            canActivate: false,
            gauge: .init(),
            updatedAt: nil,
            history: [],
            odometer: nil,
            odometerHelp: nil,
            statusText: nil,
            selection: .none)
    }

    @Test(arguments: [
        ("Nina Okafor", "nina.o"), ("Hana Mori", "hana.m"), ("Mateo Silva", "mateo.s"),
        ("Elena Petrov", "ELENA+P"), ("Dr Elena Petrov", "elena.p"),
        ("Clara Alice Torres", "c.a.t"),
    ])
    func `ordered display words and initials cannot supply an independent alias`(_ input: (String, String)) throws {
        let fields = NativeOrbitBadgeModel.interpretationFields(label: input.0, alias: input.1)
        #expect(fields["label"] == input.0)
        #expect(fields["alias"]?.isEmpty == true)
        #expect(try Self.sourceChoices(label: input.0, alias: input.1) == ["label", "none"])
    }

    @Test(arguments: ["elena.p2", "elena2.p", "e7.p9", "elena.petrov.007", "elena.p.second", "elena.p.twenty-first"])
    func `identity counters do not make copied names descriptive`(_ alias: String) {
        #expect(NativeOrbitBadgeModel.interpretationFields(label: "Elena Petrov", alias: alias)["alias"]?
            .isEmpty == true)
    }

    @Test(arguments: [
        ("Project Cedar", "projectc"), ("Elena Petrov", "elenap"),
        ("Elena Petrov", "elenapetrov"), ("Elena Petrov", "elenap2"),
    ])
    func `unambiguous compact whole word and initial forms preserve label ownership`(_ input: (String, String)) {
        let fields = NativeOrbitBadgeModel.interpretationFields(label: input.0, alias: input.1)
        #expect(fields["label"] == input.0)
        #expect(fields["alias"]?.isEmpty == true)
    }

    @Test(arguments: [
        ("Project Cedar", "cp"), ("Aa Aa", "aaa"),
        ("Elena Petrov", "ellie.p"), ("Elena Petrov", "epfirst"),
        ("Project Cedar", "pc"), ("Project Lagoon", "pl"), ("Elena Petrov", "ep2"),
        ("Clara Alice Torres", "cat"),
    ])
    func `reordered ambiguous and nickname forms are not silently discarded`(_ input: (String, String)) {
        #expect(NativeOrbitBadgeModel.interpretationFields(label: input.0, alias: input.1)["alias"] == input.1)
    }

    @Test(arguments: [
        ("Nina Okafor", "ceramics.workshop"), ("Nina Okafor", "nina.ceramics"),
        ("Research", "meteor.shower"), ("Elena Petrov", "elena.OAuth2"),
        ("Elena Petrov", "elena.2FA"), ("Elena Petrov", "elena.FirstAid"),
        ("Elena Petrov", "elena.secondhand.books"), ("Project Cedar", "cedar.irrigation"),
    ])
    func `any new descriptive subject keeps the original alias offered`(_ input: (String, String)) throws {
        #expect(NativeOrbitBadgeModel.interpretationFields(label: input.0, alias: input.1)["alias"] == input.1)
        #expect(try Self.sourceChoices(label: input.0, alias: input.1).contains("alias"))
    }

    @Test(arguments: ["Mailbox C", "Client eleven", "Main", "One"])
    func `generic identities retain meaningful aliases`(_ label: String) async throws {
        let fields = NativeOrbitBadgeModel.interpretationFields(label: label, alias: "garden.pruning")
        #expect(fields["label"]?.isEmpty == true)
        #expect(fields["alias"] == "garden.pruning")
        #expect(try Self.sourceChoices(label: label, alias: "garden.pruning") == ["alias", "none"])
        let input = NativeOrbitBadgeModel.Account(id: "target", text: "", label: label, alias: "garden.pruning")
        let result = await NativeOrbitBadgeModel.prepare([input]) { _ in (source: "alias", terms: ["gardening"]) }
        #expect(result.purposes["target"] == "garden pruning")
    }

    @Test(arguments: ["alias", "none", "invented"])
    func `preparation cannot resurrect a withheld copied name alias`(_ kind: String) async {
        let input = NativeOrbitBadgeModel.Account(id: "target", text: "", label: "Elena Petrov", alias: "elena.p")
        let result = await NativeOrbitBadgeModel.prepare([input]) { _ in (source: kind, terms: ["flowers", "mail"]) }
        #expect(result.purposes["target"]?.isEmpty == true)
        #expect(result.retrievalQueries["target"]?.isEmpty == true)
        #expect(result.complete)
    }

    @Test(arguments: [
        ("Nina Okafor", "nina.o", "envelope.fill"),
        ("Hana Mori", "hana.m", "camera.macro"),
        ("Mateo Silva", "mateo.s", "dog.fill"),
    ])
    func `offered full name labels cannot acquire fabricated topics downstream`(_ input: (
        String,
        String,
        String)) async throws
    {
        let rows = [
            Self.account("person", input.0, alias: input.1),
            Self.account("peer", "Woodworking", alias: "peer.woodworking"),
        ]
        let accounts = NativeOrbitBadgeResolver.modelAccounts(rows)
        let prepared = await NativeOrbitBadgeModel.prepare(accounts) { account in
            (source: "label", terms: account.id == "person" ? ["plant", "mail", "dog"] : ["woodworking"])
        }
        #expect(prepared.purposes["person"] == input.0)
        #expect(!NativeOrbitBadgeSearch.hasDistinctMeaning(in: input.0, peers: ["Woodworking"]))
        let person = try #require(accounts.first { $0.id == "person" })
        #expect(NativeOrbitBadgeModel.candidateKeys(
            for: person,
            peers: ["Woodworking"],
            source: prepared.purposes["person"],
            query: prepared.retrievalQueries["person"]).isEmpty)
        let entry = try #require(NativeOrbitBadgeModel.entries.first { $0.symbol == input.2 })
        let merged = NativeOrbitBadgeResolver.mergedBadges(
            [
                .init(
                    accountID: "person",
                    key: entry.key,
                    symbol: entry.symbol,
                    evidence: input.0,
                    searchQuery: prepared.retrievalQueries["person"]),
            ],
            for: rows,
            purposes: prepared.purposes)
        let identities = Set(NativeOrbitBadgeCatalog.all.filter { $0.kind == .letter || $0.kind == .number }
            .map(\.symbol))
        #expect(try identities.contains(#require(merged["person"])))
        #expect(merged["person"] != entry.symbol)
    }

    @Test func `a named concept keeps its label after the identical alias is omitted`() async throws {
        let rows = [Self.account("project", "Project Orion", alias: "orion"), Self.account("peer", "Cooking")]
        let accounts = NativeOrbitBadgeResolver.modelAccounts(rows)
        let prepared = await NativeOrbitBadgeModel.prepare(accounts) { account in
            (source: "label", terms: account.id == "project" ? ["constellation", "stars"] : ["cooking"])
        }
        #expect(NativeOrbitBadgeModel.interpretationFields(label: "Project Orion", alias: "orion")["alias"]?
            .isEmpty == true)
        #expect(prepared.purposes["project"] == "Project Orion")
        let entry = try #require(NativeOrbitBadgeModel.entries.first { $0.symbol == "star.fill" })
        let merged = NativeOrbitBadgeResolver.mergedBadges(
            [
                .init(
                    accountID: "project",
                    key: entry.key,
                    symbol: entry.symbol,
                    evidence: "Orion",
                    searchQuery: prepared.retrievalQueries["project"]),
            ],
            for: rows,
            purposes: prepared.purposes)
        #expect(merged["project"] == "star.fill")
    }

    @Test func `transport fallback and cancellation retain the same source policy`() async {
        let copied = NativeOrbitBadgeModel.Account(id: "copied", text: "", label: "Nina Okafor", alias: "nina.o")
        let descriptive = NativeOrbitBadgeModel.Account(
            id: "descriptive", text: "", label: "Nina Okafor", alias: "ceramics.workshop")
        let failed = await NativeOrbitBadgeModel.prepare([copied, descriptive]) { _ in
            throw NSError(domain: "Synthetic transport", code: 1)
        }
        #expect(failed.purposes["copied"]?.isEmpty == true)
        #expect(failed.purposes["descriptive"] == "ceramics workshop")
        #expect(failed.errors.count == 2)
        #expect(NativeOrbitBadgeModel.peerSource(copied, selected: "").isEmpty)
        let cancelled = await NativeOrbitBadgeModel.prepare([descriptive]) { _ in throw CancellationError() }
        #expect(cancelled.cancelled)
        #expect(cancelled.purposes.isEmpty)
    }

    @Test(arguments: [
        ("Chloé Dubois", "chloe.d"), ("Chloe\u{301} Dubois", "chloé.d"),
        ("Мария Иванова", "мария.и"), ("민수 김", "민수.김"), ("陈 明", "陈.明"),
        ("书", "书"),
    ])
    func `unicode identity spelling is compared without erasing the offered label`(_ input: (String, String)) {
        let fields = NativeOrbitBadgeModel.interpretationFields(label: input.0, alias: input.1)
        #expect(fields["label"] == input.0)
        #expect(fields["alias"]?.isEmpty == true)
    }

    @Test(arguments: [
        ("मौसम रिकॉर्ड", "मौसम.रिकॉर्ड"),
        ("আবহাওয়ার বই", "আবহাওয়ার.বই"),
    ])
    func `repeated non Latin words retain combining vowels during identity matching`(_ input: (String, String)) throws {
        let fields = NativeOrbitBadgeModel.interpretationFields(label: input.0, alias: input.1)
        #expect(fields["label"] == input.0)
        #expect(fields["alias"]?.isEmpty == true)
        #expect(try Self.sourceChoices(label: input.0, alias: input.1) == ["label", "none"])
    }

    @Test(arguments: [
        ("मौसम रिकॉर्ड", "मसम.रिकॉर्ड"),
        ("मौसम रिकॉर्ड", "मौसम.रकर्ड"),
        ("আবহাওয়ার বই", "আবহওয়র.বই"),
        ("আবহাওয়ার বই", "আবহাওয়ার.বু"),
    ])
    func `different non Latin marks preserve a different alias source`(_ input: (String, String)) throws {
        let fields = NativeOrbitBadgeModel.interpretationFields(label: input.0, alias: input.1)
        #expect(fields["alias"] == input.1)
        #expect(try Self.sourceChoices(label: input.0, alias: input.1).contains("alias"))
    }

    @Test func `current use privacy and opaque alias controls remain intact`() async {
        #expect(NativeOrbitBadgeModel
            .interpretationFields(label: "Now cello practice", alias: "old.sailing")["alias"]?.isEmpty == true)
        let privateRows = [
            Self.account("a", "Account 1", alias: "medical"),
            Self.account("b", "Account 2", alias: "finance"),
        ]
        #expect(NativeOrbitBadgeResolver.modelAccounts(privateRows)
            .allSatisfy { $0.text.isEmpty && $0.alias.isEmpty && $0.brand == nil })
        let code = NativeOrbitBadgeModel.Account(id: "code", text: "", label: "Mailbox C", alias: "u5")
        let prepared = await NativeOrbitBadgeModel.prepare([code]) { _ in (source: "alias", terms: ["flowers"]) }
        #expect(prepared.purposes["code"]?.isEmpty == true)
    }

    @Test func `public field normalization bounds raw labels and aliases before parsing`() {
        let enormous = String(repeating: "x", count: 200_000)
        let fields = NativeOrbitBadgeModel.interpretationFields(label: enormous, alias: enormous)
        #expect((fields["label"]?.utf8.count ?? Int.max) <= 256)
        #expect((fields["alias"]?.utf8.count ?? Int.max) <= 256)
        let combining = "a" + String(repeating: "\u{0301}", count: 2000)
        let combined = NativeOrbitBadgeModel.interpretationFields(label: combining, alias: "ceramics.workshop")
        #expect(combined["label"]?.isEmpty == true)
        #expect(combined["alias"] == "ceramics.workshop")
    }

    @Test func `only the visible first line can establish alias repetition`() {
        let label = "Nina Okafor\nNow pottery"
        let fields = NativeOrbitBadgeModel.interpretationFields(label: label, alias: "pottery")
        #expect(fields["label"] == "Nina Okafor")
        #expect(fields["alias"] == "pottery")
        let account = NativeOrbitBadgeModel.Account(id: "target", text: "", label: label, alias: "pottery")
        #expect(NativeOrbitBadgeModel.ownedFallbackSource(account) == "pottery")
        let started = Date()
        for index in 1...24 {
            let repeated = NativeOrbitBadgeModel.interpretationFields(label: "Nina Okafor", alias: "nina.o\(index)")
            #expect(repeated["alias"]?.isEmpty == true)
        }
        print("24 redundant alias fields elapsed: \(Date().timeIntervalSince(started)) seconds")
    }
}
