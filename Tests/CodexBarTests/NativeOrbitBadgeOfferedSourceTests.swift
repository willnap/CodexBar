import Foundation
import FoundationModels
import Testing
@testable import CodexBar

@MainActor struct NativeOrbitBadgeOfferedSourceTests {
    @Test(arguments: [
        ("Client eleven", "quilting.patterns", ["alias", "none"]),
        ("Project Cedar", "old.cycling", ["label", "alias", "none"]),
        ("Now violin repairs", "old.weaving", ["label", "none"]),
        ("", "", ["none"]),
        ("Online2", "", ["label", "none"]),
        ("Jordan Shaw", "ceramics.practice", ["label", "alias", "none"]),
    ])
    func schemaOnlyOffersPresentFieldsAndPreservesSourceFirstOrder(_ input: (String, String, [String])) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let schema = NativeOrbitBadgeModel.interpretationSchema(label: input.0, alias: input.1)
        let data = try encoder.encode(schema)
        let repeated = try encoder.encode(NativeOrbitBadgeModel.interpretationSchema(label: input.0, alias: input.1))
        #expect(data == repeated)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let properties = try #require(object["properties"] as? [String: [String: Any]])
        #expect(properties["source"]?["enum"] as? [String] == input.2)
        #expect(properties["terms"]?["maxItems"] as? Int == 4)
        #expect(object["x-order"] as? [String] == ["source", "terms"])
        #expect(object["required"] as? [String] == ["source", "terms"])
    }

    @Test(arguments: ["Client eleven", "Entry eight", "Main", "One"])
    func aMissingLabelCannotBeResurrectedByTheSourceEnum(_ label: String) async {
        let account = NativeOrbitBadgeModel.Account(id: "target", text: "", label: label, alias: "quilting.patterns")
        let result = await NativeOrbitBadgeModel.prepare([account]) { _ in
            (source: "label", terms: ["quilting", "textiles"])
        }
        #expect(result.purposes["target"]?.isEmpty == true)
        #expect(result.retrievalQueries["target"]?.isEmpty == true)
        #expect(result.complete)
    }

    @Test func aMissingAliasCannotRecoverACompetingLabel() async {
        let account = NativeOrbitBadgeModel.Account(id: "target", text: "", label: "Pottery orders", alias: "")
        let result = await NativeOrbitBadgeModel.prepare([account]) { _ in (source: "alias", terms: ["pottery"]) }
        #expect(result.purposes["target"]?.isEmpty == true)
        #expect(result.retrievalQueries["target"]?.isEmpty == true)
    }

    @Test(arguments: ["none", "invented", "", "LABEL"])
    func abstentionAndInvalidKindsNeverRecoverAnAlias(_ kind: String) async {
        let account = NativeOrbitBadgeModel.Account(id: "target", text: "", label: "Mailbox C", alias: "bread.baking")
        let result = await NativeOrbitBadgeModel.prepare([account]) { _ in (source: kind, terms: ["bread"]) }
        #expect(result.purposes["target"]?.isEmpty == true)
        #expect(result.retrievalQueries["target"]?.isEmpty == true)
        #expect(result.complete)
    }

    @Test func aSuppressedHistoricalAliasCannotOverrideCurrentUse() async {
        let account = NativeOrbitBadgeModel.Account(
            id: "current", text: "", label: "Now violin repairs", alias: "old.weaving")
        let result = await NativeOrbitBadgeModel.prepare([account]) { _ in (source: "alias", terms: ["weaving"]) }
        #expect(result.purposes["current"]?.isEmpty == true)
        #expect(result.retrievalQueries["current"]?.isEmpty == true)
    }

    @Test func validOwnedChoicesRetainDescriptiveAndCurrentNameProtections() async {
        let accounts = [
            NativeOrbitBadgeModel.Account(id: "project", text: "", label: "Project Cedar", alias: "old.cycling"),
            NativeOrbitBadgeModel.Account(id: "current", text: "", label: "Now violin repairs", alias: "old.weaving"),
            NativeOrbitBadgeModel.Account(
                id: "alias",
                text: "",
                label: "Client eleven",
                alias: "GlassBlowing.practice"),
        ]
        let result = await NativeOrbitBadgeModel.prepare(accounts) { account in
            switch account.id {
            case "project": (source: "label", terms: ["cycling"])
            case "current": (source: "label", terms: ["weaving"])
            default: (source: "alias", terms: ["glass", "blowing"])
            }
        }
        #expect(result.purposes["project"] == "Project Cedar")
        #expect(result.purposes["current"] == "violin repairs")
        #expect(result.purposes["alias"] == "Glass Blowing practice")
        #expect(result.complete)
    }

    @Test func anOfferedAliasRetainsOwnedEvidenceAndSeparatesExpandedTopics() async {
        let account = NativeOrbitBadgeModel.Account(
            id: "owned", text: "", label: "Mailbox thirteen", alias: "quilting.patterns")
        let result = await NativeOrbitBadgeModel.prepare([account]) { _ in
            (source: "alias", terms: ["quilting", "textiles", "invented subject"])
        }
        #expect(result.purposes["owned"] == "quilting patterns")
        #expect(result.retrievalQueries["owned"] == "quilting patterns; quilting; textiles; invented subject")
        #expect(result.proposals.isEmpty)
        #expect(result.complete)
    }
}
