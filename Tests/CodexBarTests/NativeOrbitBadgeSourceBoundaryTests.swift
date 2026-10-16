import Testing
@testable import CodexBar

@MainActor struct NativeOrbitBadgeSourceBoundaryTests {
    private enum Failure: Error { case transport }

    @Test func expandedTopicsCannotReintroduceAWithheldLabel() async {
        let account = NativeOrbitBadgeModel.Account(
            id: "target", text: "", label: "Client eleven", alias: "quilting.patterns")
        let result = await NativeOrbitBadgeModel.prepare([account]) { _ in
            (source: "alias", terms: ["eleven"])
        }
        #expect(result.purposes["target"] == "quilting patterns")
        #expect(result.retrievalQueries["target"] == "quilting patterns; eleven")
        #expect(account.label == "Client eleven")
        #expect(account.text == "Client eleven\nquilting.patterns")
    }

    @Test(arguments: ["Client eleven", "Entry eight"])
    func transportAndPeerFallbacksCannotReintroduceAWithheldLabel(_ label: String) async {
        let account = NativeOrbitBadgeModel.Account(
            id: "target", text: "", label: label, alias: "quilting.patterns")
        let result = await NativeOrbitBadgeModel.prepare([account]) { _ in throw Failure.transport }
        #expect(result.purposes["target"] == "quilting patterns")
        #expect(result.retrievalQueries["target"] == "quilting patterns")
        #expect(result.errors["target"] != nil)
        #expect(!result.complete)
        #expect(NativeOrbitBadgeModel.ownedFallbackSource(account) == "quilting patterns")
        #expect(NativeOrbitBadgeModel.peerSource(account, selected: nil) == "quilting patterns")
        #expect(NativeOrbitBadgeModel.peerSource(account, selected: "") == "quilting patterns")
    }

    @Test func explicitCurrentUseKeepsPrecedenceInPreparationAndFallback() async {
        let account = NativeOrbitBadgeModel.Account(
            id: "current", text: "", label: "Now violin repairs", alias: "old.weaving")
        let result = await NativeOrbitBadgeModel.prepare([account]) { _ in (source: "label", terms: ["weaving"]) }
        #expect(result.purposes["current"] == "violin repairs")
        #expect(NativeOrbitBadgeModel.ownedFallbackSource(account) == "violin repairs")
        #expect(NativeOrbitBadgeModel.peerSource(account, selected: nil) == "violin repairs")
        let failed = await NativeOrbitBadgeModel.prepare([account]) { _ in throw Failure.transport }
        #expect(failed.purposes["current"] == "violin repairs")
    }

    @Test(arguments: ["label", "none", "invented"])
    func rejectedChoicesStayEmptyWhilePeersRetainTheActualOfferedClue(_ kind: String) async {
        let account = NativeOrbitBadgeModel.Account(
            id: "target", text: "", label: "Entry eight", alias: "ceramics.practice")
        let result = await NativeOrbitBadgeModel.prepare([account]) { _ in (source: kind, terms: ["eight"]) }
        #expect(result.purposes["target"]?.isEmpty == true)
        #expect(result.retrievalQueries["target"]?.isEmpty == true)
        #expect(NativeOrbitBadgeModel.peerSource(account, selected: result.purposes["target"]) == "ceramics practice")
    }

    @Test func personalNameFallbackStillRetainsOnlyOwnedAliasData() {
        let account = NativeOrbitBadgeModel.Account(
            id: "person", text: "", label: "Jordan Shaw", alias: "ceramics.practice")
        #expect(NativeOrbitBadgeModel.ownedFallbackSource(account) == "ceramics practice")
        #expect(NativeOrbitBadgeModel.peerSource(account, selected: "ceramics practice") == "ceramics practice")
    }
}
