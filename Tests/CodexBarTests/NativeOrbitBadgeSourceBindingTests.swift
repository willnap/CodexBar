import FoundationModels
import Testing
@testable import CodexBar

@MainActor struct NativeOrbitBadgeSourceBindingTests {
    private enum Failure: Error { case transport }

    @Test(arguments: ["Mailbox thirteen", "Compte onze", "Workspace eight"])
    func genericLabelsCannotHideAnAttributableAlias(_ label: String) {
        #expect(NativeOrbitBadgeModel.selectedSource(
            "label", label: label, alias: "quilting.patterns", terms: ["quilting", "textiles"]) == "quilting patterns")
    }

    @Test(arguments: [
        "Pottery orders", "Account security", "Mailbox First Aid", "Workspace architecture", "Client twenty one pilots",
    ])
    func selectedDescriptiveLabelsCannotBeReplacedByStaleAliasTerms(_ label: String) {
        #expect(NativeOrbitBadgeModel.selectedSource(
            "label", label: label, alias: "old.cycling", terms: ["cycling"]) == label)
    }

    @Test(arguments: ["Project Cedar", "Project Copper", "Studio Elara"])
    func selectedProjectNamesCannotBeReplacedByStaleAliasTerms(_ label: String) {
        #expect(NativeOrbitBadgeModel.selectedSource(
            "label", label: label, alias: "old.cycling", terms: ["cycling"]) == label)
    }

    @Test(arguments: [
        "Account twelve", "Mailbox Seven", "Compte neuf", "Postfach zwölf", "Buzón cuatro", "Client eleven",
        "Login 13th", "Entry thirteenth", "Profile 003", "Workspace eight",
    ])
    func numericAndLocalizedUIIdentifiersCanRecoverOwnedAliases(_ label: String) {
        #expect(NativeOrbitBadgeModel.selectedSource(
            "label", label: label, alias: "quilting.patterns", terms: ["quilting"]) == "quilting patterns")
    }

    @Test(arguments: [
        "Second login", "Additional mailbox", "Primary profile twelve", "Thirteenth inbox", "Daily account",
        "three entry", "Spare", "Default", "Account login two",
    ])
    func compositionalUIIdentityModifiersDoNotHideOwnedAliases(_ label: String) {
        #expect(NativeOrbitBadgeModel.selectedSource(
            "label", label: label, alias: "quilting.patterns", terms: ["quilting"]) == "quilting patterns")
    }

    @Test(arguments: ["Work", "Personal", "Primary work account", "Daily pottery inbox"])
    func explicitRolesAndSubjectWordsAreNotGenericUIIdentifiers(_ label: String) {
        let expected = NativeOrbitBadgeModel.purposeLabel(label)
        #expect(NativeOrbitBadgeModel.selectedSource(
            "label", label: label, alias: "old.cycling", terms: ["cycling"]) == expected)
    }

    @Test(arguments: [
        "Mailbox eight repairs",
        "Client four hundred invoices",
        "Entry thirteenth notes",
        "Account login repairs two",
    ])
    func partialNumberParsesCannotEraseDescriptiveLabels(_ label: String) {
        #expect(NativeOrbitBadgeModel.selectedSource(
            "label", label: label, alias: "old.cycling", terms: ["cycling"]) == label)
    }

    @Test(arguments: ["Zymurgy readings", "Mailbox beta", "Project eight"])
    func unknownVocabularyDoesNotMakeASelectedLabelGeneric(_ label: String) {
        #expect(NativeOrbitBadgeModel.selectedSource(
            "label", label: label, alias: "old.cycling", terms: ["cycling"]) == label)
    }

    @Test(arguments: [
        "Konto neun", "Cuenta cuatro", "Boîte onze", "Login B7", "Compte supplémentaire",
    ])
    func unsupportedIdentifierFormsConservativelyRetainTheSelectedLabel(_ label: String) {
        #expect(NativeOrbitBadgeModel.selectedSource(
            "label", label: label, alias: "old.cycling", terms: ["cycling"]) == label)
    }

    @Test func literalOverlapUsesCasePunctuationAndAliasNormalization() {
        #expect(NativeOrbitBadgeModel.selectedSource(
            "label", label: "Entry fourteen", alias: "GlassBlowing.practice", terms: ["GLASS-BLOWING"]) ==
            "Glass Blowing practice")
    }

    @Test func ownedAliasSuffixNormalizationRunsOnce() {
        #expect(NativeOrbitBadgeModel.selectedSource(
            "alias", label: "Mailbox thirteen", alias: "pollinatorclub", terms: []) == "pollinator club")
        let account = NativeOrbitBadgeModel.Account(
            id: "club", text: "", label: "Mailbox B", alias: "pollinatorclub")
        #expect(NativeOrbitBadgeModel.ownedFallbackSource(account) == "pollinator club")
    }

    @Test func uniquelyAttributedLabelCanRepairAnAliasEnum() {
        #expect(NativeOrbitBadgeModel.selectedSource(
            "alias", label: "Polar ice measurements", alias: "old.weaving", terms: ["polar", "ice"]) ==
            "Polar ice measurements")
    }

    @Test func bothFieldsMatchingRetainsTheSelectedField() {
        #expect(NativeOrbitBadgeModel.selectedSource(
            "label", label: "Stone carving", alias: "stone.polishing", terms: ["stone"]) == "Stone carving")
        #expect(NativeOrbitBadgeModel.selectedSource(
            "alias", label: "Stone carving", alias: "stone.polishing", terms: ["stone"]) == "stone polishing")
    }

    @Test(arguments: [[], ["ocean"], ["tree", "pottery"]])
    func emptyUnattributedOrTiedTermsRetainPriorChoice(_ terms: [String]) {
        #expect(NativeOrbitBadgeModel.selectedSource(
            "label", label: "Tree study", alias: "pottery.tools", terms: terms) == "Tree study")
    }

    @Test func explicitCurrentPurposeAlwaysExcludesTheStaleAlias() {
        #expect(NativeOrbitBadgeModel.selectedSource(
            "alias", label: "Now violin repairs", alias: "old.weaving", terms: ["weaving"]) == "violin repairs")
    }

    @Test func usefulHumanAliasCanBeAttributedWithoutInventingPersonalTraits() {
        #expect(NativeOrbitBadgeModel.selectedSource(
            "label", label: "Tessa Rowan", alias: "beekeeping.supplies", terms: ["beekeeping"]) ==
            "beekeeping supplies")
        #expect(NativeOrbitBadgeModel.selectedSource(
            "none", label: "Tessa Rowan", alias: "u5", terms: ["lawyer"]).isEmpty)
    }

    @Test(arguments: ["u5", "r9", "17", "Q"])
    func opaqueAliasesStayEmptyInPreparationAndFallback(_ alias: String) {
        #expect(NativeOrbitBadgeModel.selectedSource(
            "label", label: "Mailbox B", alias: alias, terms: ["astronomy"]).isEmpty)
        let account = NativeOrbitBadgeModel.Account(id: "opaque", text: "", label: "Mailbox B", alias: alias)
        #expect(NativeOrbitBadgeModel.ownedFallbackSource(account).isEmpty)
    }

    @Test(arguments: ["2FA", "OAuth2", "security.alerts"])
    func meaningfulDigitAliasesRemainOwnedData(_ alias: String) {
        #expect(!NativeOrbitBadgeModel.selectedSource(
            "alias", label: "Mailbox B", alias: alias, terms: []).isEmpty)
    }

    @Test func successfulNoneCannotBeReplacedByAUsefulAlias() {
        #expect(NativeOrbitBadgeModel.selectedSource(
            "none", label: "Ceramics", alias: "beekeeping.supplies", terms: ["beekeeping"]).isEmpty)
        #expect(NativeOrbitBadgeModel.selectedSource(
            "none", label: "Now violin repairs", alias: "old.weaving", terms: ["violin"]).isEmpty)
    }

    @Test func identifierOnlyNoneKeepsExistingOwnedAliasRecovery() {
        #expect(NativeOrbitBadgeModel.selectedSource(
            "none", label: "Mailbox C", alias: "bread.baking", terms: ["bread"]) == "bread baking")
        #expect(NativeOrbitBadgeModel.selectedSource("none", label: "Z", alias: "r9") == "r9")
    }

    @Test func invalidEnumCannotGainAFieldThroughTopicTerms() {
        #expect(NativeOrbitBadgeModel.selectedSource(
            "invented", label: "Ceramics", alias: "beekeeping.supplies", terms: ["beekeeping"]).isEmpty)
    }

    @Test func preparationRetainsOwnedSourceAndUsesTopicsOnlyInRetrieval() async {
        let account = NativeOrbitBadgeModel.Account(
            id: "owned", text: "", label: "Mailbox thirteen", alias: "quilting.patterns")
        let result = await NativeOrbitBadgeModel.prepare([account]) { _ in
            (source: "alias", terms: ["quilting", "textiles", "invented subject"])
        }
        #expect(result.purposes["owned"] == "quilting patterns")
        #expect(result.retrievalQueries["owned"]?.contains("invented subject") == true)
        #expect(result.purposes["owned"]?.contains("invented") == false)
        #expect(result.proposals.isEmpty)
    }

    @Test func preparationRefusalsFailClosedAndKeepTheError() async {
        let account = NativeOrbitBadgeModel.Account(id: "blocked", text: "", label: "Comet photography")
        for error in Self.refusals() {
            #expect(NativeOrbitBadgeModel.isPreparationRefusal(error))
            let result = await NativeOrbitBadgeModel.prepare([account]) { _ in throw error }
            #expect(result.purposes[account.id]?.isEmpty == true)
            #expect(result.retrievalQueries[account.id]?.isEmpty == true)
            #expect(result.refusedAccounts.contains(account.id))
            #expect(result.errors[account.id] != nil)
            #expect(result.proposals.isEmpty && !result.cancelled && !result.complete)
        }
    }

    @Test func ordinaryTransportErrorsKeepTheOwnedFallback() async {
        #expect(!NativeOrbitBadgeModel.isPreparationRefusal(Failure.transport))
        let account = NativeOrbitBadgeModel.Account(id: "retry", text: "", label: "Comet photography")
        let result = await NativeOrbitBadgeModel.prepare([account]) { _ in throw Failure.transport }
        #expect(result.purposes[account.id] == "Comet photography")
        #expect(result.refusedAccounts.isEmpty)
        #expect(result.errors[account.id] != nil)
    }

    @Test func decodingFailureKeepsTheOwnedFallback() async {
        let context = LanguageModelSession.GenerationError.Context(debugDescription: "invalid structure")
        let error = LanguageModelSession.GenerationError.decodingFailure(context)
        #expect(!NativeOrbitBadgeModel.isPreparationRefusal(error))
        let account = NativeOrbitBadgeModel.Account(id: "decoding", text: "", label: "Comet photography")
        let result = await NativeOrbitBadgeModel.prepare([account]) { _ in throw error }
        #expect(result.purposes[account.id] == "Comet photography")
        #expect(result.refusedAccounts.isEmpty && result.errors[account.id] != nil)
    }

    private static func refusals() -> [any Error] {
        let context = LanguageModelSession.GenerationError.Context(debugDescription: "blocked")
        var result: [any Error] = [
            LanguageModelSession.GenerationError.guardrailViolation(context),
            LanguageModelSession.GenerationError.refusal(.init(transcriptEntries: []), context),
        ]
        if #available(macOS 27.0, *) {
            result.append(LanguageModelError.guardrailViolation(.init(debugDescription: "blocked")))
            result.append(LanguageModelError.refusal(.init(explanation: "declined", debugDescription: "blocked")))
        }
        return result
    }
}
