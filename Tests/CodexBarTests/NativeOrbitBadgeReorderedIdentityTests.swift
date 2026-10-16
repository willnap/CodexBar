import Foundation
import FoundationModels
import Testing
@testable import CodexBar

@MainActor struct NativeOrbitBadgeReorderedIdentityTests {
    private static func choices(_ label: String, _ alias: String) throws -> [String] {
        let data = try JSONEncoder().encode(NativeOrbitBadgeModel.interpretationSchema(label: label, alias: alias))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let properties = try #require(object["properties"] as? [String: [String: Any]])
        return try #require(properties["source"]?["enum"] as? [String])
    }

    @Test(arguments: [
        ("Mateo Silva", "silva.mateo"), ("Hana Mori", "mori.hana"),
        ("Mateo Silva", "s.mateo"), ("Hana Mori", "m.hana"),
        ("Elena Petrov", "petrov2.elena7.third"), ("Clara Alice Torres", "t.clara.a"),
        ("Elena Ethan", "e.e"), ("Elena Ethan", "e.elena"), ("মৌসম রেকর্ড", "রেকর্ড.মৌসম"),
    ])
    func separatedIdentityTokensHaveNoIndependentSource(_ input: (String, String)) async throws {
        let fields = NativeOrbitBadgeModel.interpretationFields(label: input.0, alias: input.1)
        #expect(fields["label"] == input.0)
        #expect(fields["alias"]?.isEmpty == true)
        #expect(try Self.choices(input.0, input.1) == ["label", "none"])
        let account = NativeOrbitBadgeModel.Account(id: "target", text: "", label: input.0, alias: input.1)
        let prepared = await NativeOrbitBadgeModel.prepare([account]) { _ in
            (source: "alias", terms: ["flowers", "tree", "dog"])
        }
        #expect(prepared.purposes["target"]?.isEmpty == true)
        #expect(prepared.retrievalQueries["target"]?.isEmpty == true)
        #expect(NativeOrbitBadgeModel.ownedFallbackSource(account) != input.1)
    }

    @Test(arguments: [
        ("Elena Petrov", "elena.elena"), ("Elena Petrov", "e.e"),
        ("Elena Petrov", "p.p2"), ("Elena Petrov", "petrov.elena.garden"),
        ("Research", "meteor.shower"), ("Elena Petrov", "petrov.OAuth2"),
    ])
    func distinctPositionsAndExtraDescriptiveWordsRemainRequired(_ input: (String, String)) throws {
        #expect(NativeOrbitBadgeModel.interpretationFields(label: input.0, alias: input.1)["alias"] == input.1)
        #expect(try Self.choices(input.0, input.1).contains("alias"))
    }

    @Test(arguments: [
        ("Elena Petrov", "petrovelena"), ("Elena Petrov", "pelena"),
        ("Elena Petrov", "petrove"), ("Elena Petrov", "petrovelena2"),
        ("Project Cedar", "cedarproject"), ("Aa Aa", "aaaa"),
    ])
    func exactReverseCompactFormsCanBeUniquelyOwned(_ input: (String, String)) throws {
        #expect(NativeOrbitBadgeModel.interpretationFields(label: input.0, alias: input.1)["alias"]?.isEmpty == true)
        #expect(try Self.choices(input.0, input.1) == ["label", "none"])
    }

    @Test(arguments: [
        ("A Aa", "aaa"), ("Aa Aa", "aaa"), ("Clara Alice Torres", "cat"),
        ("Elena Petrov", "pe2"), ("Clara Alice Torres", "aliceclaratorres"),
        ("Elena Petrov", "elliep"),
    ])
    func ambiguousAcronymOrArbitraryCompactOrdersStayOffered(_ input: (String, String)) {
        #expect(NativeOrbitBadgeModel.interpretationFields(label: input.0, alias: input.1)["alias"] == input.1)
    }

    @Test func reversedAliasCannotSupplyAFabricatedMergerPurpose() async throws {
        func row(_ id: String, _ label: String, _ email: String) -> NativeOrbitAccountPresentation {
            .init(
                id: id,
                label: label,
                email: email,
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
        let rows = [
            row("target", "Mateo Silva", "s.mateo@gmail.com"),
            row("peer", "Cooking", "cooking@gmail.com"),
        ]
        let accounts = NativeOrbitBadgeResolver.modelAccounts(rows)
        let prepared = await NativeOrbitBadgeModel.prepare(accounts) { _ in (source: "alias", terms: ["dog"]) }
        let entry = try #require(NativeOrbitBadgeModel.entries.first { $0.symbol == "dog.fill" })
        let merged = NativeOrbitBadgeResolver.mergedBadges(
            [.init(accountID: "target", key: entry.key, symbol: entry.symbol, evidence: "s mateo", searchQuery: "dog")],
            for: rows,
            purposes: prepared.purposes)
        #expect(prepared.purposes["target"]?.isEmpty == true)
        #expect(merged["target"] != "dog.fill")
    }
}
