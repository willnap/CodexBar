import Foundation
import Testing
@testable import CodexBar

@MainActor struct NativeOrbitBadgeModelTests {
    @Test func `one large grapheme cannot evade the model byte budget`() {
        let text = "a" + String(repeating: "\u{301}", count: 10000)
        let value = NativeOrbitBadgeModel.bounded(text, characters: 96, bytes: 256)
        #expect(value.utf8.count <= 256)
        #expect(value.isEmpty || text.hasPrefix(value))
    }

    @Test func `account model text bounds both characters and bytes`() {
        let account = NativeOrbitBadgeModel.Account(id: "a", text: String(repeating: "界", count: 500))
        #expect(account.text.count <= 96)
        #expect(account.text.utf8.count <= 256)
    }

    @Test func `model boundaries preserve ordinary complete labels`() {
        let text = "Swimming lessons / children"
        #expect(NativeOrbitBadgeModel.bounded(text, characters: 96, bytes: 256) == text)
    }

    @Test func `generic account identifiers do not override a meaningful mailbox alias`() {
        #expect(NativeOrbitBadgeModel.purposeLabel("Account A").isEmpty)
        #expect(NativeOrbitBadgeModel.purposeLabel("01").isEmpty)
        #expect(NativeOrbitBadgeModel.purposeLabel("Accounting") == "Accounting")
        #expect(NativeOrbitBadgeModel.purposeLabel("Work photos") == "Work photos")
    }

    @Test func `opaque alphanumeric identifiers never become activities`() {
        #expect(NativeOrbitBadgeModel.purposeLabel("R7").isEmpty)
        #expect(NativeOrbitBadgeModel.purposeLabel("u72").isEmpty)
    }

    @Test func `current subject survives contextual headings and obsolete mailbox uses`() {
        #expect(NativeOrbitBadgeModel.purposeLabel("Research — renewable energy") == "Research — renewable energy")
        #expect(NativeOrbitBadgeModel.purposeLabel("Old school account, now running club admin") == "running club")
        #expect(NativeOrbitBadgeModel.purposeLabel("Former work email — now family photos") == "family photos")
    }

    @Test func `weak display label cannot hide the meaningful alias`() {
        #expect(NativeOrbitBadgeModel
            .selectedSource("alias", label: "Main", alias: "pottery.lessons") == "pottery lessons")
        #expect(NativeOrbitBadgeModel
            .selectedSource("alias", label: "Mailbox A", alias: "garden.club") == "garden club")
    }

    @Test func `retrieval preserves current label alongside conflicting old alias`() {
        #expect(NativeOrbitBadgeModel
            .selectedSource("label", label: "Now photography", alias: "old.finance") == "photography")
        #expect(NativeOrbitBadgeModel
            .selectedSource("alias", label: "Project Aquila", alias: "bird.mail") == "bird mail")
    }

    @Test func `capitalized ordinary project subjects retain their stated meaning`() {
        #expect(NativeOrbitBadgeModel
            .selectedSource("label", label: "Project Management", alias: "") == "Project Management")
        #expect(NativeOrbitBadgeModel.selectedSource("none", label: "Project Aquila", alias: "bird").isEmpty)
    }

    @Test func `explicit current purpose excludes conflicting aliases before interpretation`() {
        #expect(NativeOrbitBadgeModel
            .interpretationFields(label: "Current use: bicycle repairs", alias: "old.cooking")["alias"]?
            .isEmpty == true)
        #expect(NativeOrbitBadgeModel.interpretationFields(label: "Now pottery", alias: "old.fitness")["alias"]?
            .isEmpty == true)
        #expect(NativeOrbitBadgeModel
            .interpretationFields(label: "Main", alias: "cycling.club")["alias"] == "cycling.club")
    }

    @Test(arguments: ["Account Q", "Mailbox Q", "Profile 7", "Z", "014", "R9"])
    func identifiersCannotCompeteWithMeaningfulAliasDuringInterpretation(_ label: String) {
        let fields = NativeOrbitBadgeModel.interpretationFields(label: label, alias: "ceramics.workshop")
        #expect(fields["label"]?.isEmpty == true)
        #expect(fields["alias"] == "ceramics.workshop")
    }

    @Test(arguments: ["label", "alias", "none"])
    func aSingleUsableFieldRemainsAnOwnedClueRatherThanAnEmptyIdentifier(_ choice: String) {
        #expect(NativeOrbitBadgeModel.selectedSource(choice, label: "Mailbox Q", alias: "ceramics.workshop")
            == "ceramics workshop")
        #expect(NativeOrbitBadgeModel.selectedSource(choice, label: "Z", alias: "r9") == "r9")
    }

    @Test(arguments: ["Current use: Gardening", "Current: Gardening", "Now: Gardening", "Current purpose — Gardening"])
    func explicitCurrentHeadingsPreserveTheSameComparisonPurpose(_ label: String) {
        #expect(NativeOrbitBadgeModel.purposeLabel(label) == "Gardening")
    }

    @Test(arguments: ["Work — records", "Personal: records", "Family | records"])
    func contextualHeadingsRemainAvailableAsDistinctiveSource(_ label: String) {
        #expect(NativeOrbitBadgeModel.purposeLabel(label) == label)
    }

    @Test func `final classification sees only the chosen owned source`() throws {
        let account = NativeOrbitBadgeModel.Account(
            id: "a",
            text: "Now pottery\nold.finance",
            label: "Now pottery",
            alias: "old.finance")
        let context = try NativeOrbitBadgeModel.selectionContext(
            account: account,
            peers: ["Reading"],
            source: "pottery")
        #expect(context.contains("pottery"))
        #expect(!context.contains("old.finance"))
        #expect(!context.contains("Now pottery"))
    }

    @Test func `closed choices retain concrete meanings with opaque option IDs`() throws {
        let candidate = NativeOrbitBadgeSearch.Candidate(
            entry: .init(
                key: "native:case.fill",
                title: "case briefcase carry equipment luggage",
                symbol: "case.fill",
                kind: .meaning,
                domains: [],
                clues: ["case"]),
            evidence: "case")
        let options = try NativeOrbitBadgeModel.optionDefinitions([candidate])
        #expect(options.contains("handled carrying case"))
        #expect(!options.contains("case.fill"))
        #expect(options.contains("none"))
    }

    @Test func `closed native and verified website choices use opaque option IDs`() throws {
        let entries: [NativeOrbitBadgeCatalog.Entry] = [
            .init(
                key: "native:pianokeys",
                title: "keyboard",
                symbol: "pianokeys",
                kind: .meaning,
                domains: [],
                clues: []),
            .init(
                key: "website_123",
                title: "Untrusted Website",
                symbol: "account.website.123",
                kind: .mail,
                domains: ["fixture.example"],
                clues: []),
        ]
        let definitions = try NativeOrbitBadgeModel.optionDefinitions(entries.map {
            NativeOrbitBadgeSearch.Candidate(entry: $0, evidence: "source")
        })
        let options = try #require(JSONSerialization.jsonObject(with: Data(definitions.utf8)) as? [[String: String]])
        #expect(options.compactMap { $0["id"] } == ["A", "B", "none"])
        #expect(options[0]["meaning"]?.contains("keyboard") == true)
        #expect(options[1]["meaning"]?.contains("verified") == true)
    }

    @Test(arguments: ["书", "猫", "木", "책", "집", "집".decomposedStringWithCanonicalMapping])
    func singleGlyphSubjectsRemainOfferedSources(_ word: String) {
        #expect(NativeOrbitBadgeModel.purposeLabel(word) == word)
        #expect(NativeOrbitBadgeModel.interpretationFields(label: word, alias: "")["label"] == word)
    }

    @Test(arguments: ["A", "Ж", "Δ", "一", "二", "三", "7", "Account 2"])
    func singleLetterAndNumericIdentifiersStillHaveNoPurpose(_ identifier: String) {
        #expect(NativeOrbitBadgeModel.purposeLabel(identifier).isEmpty)
        #expect(NativeOrbitBadgeModel.interpretationFields(label: identifier, alias: "")["label"]?.isEmpty == true)
    }
}
