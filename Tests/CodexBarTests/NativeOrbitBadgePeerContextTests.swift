import Foundation
import FoundationModels
import Testing
@testable import CodexBar

/// Deterministic contracts only: every interpreter below is injected; no model session is created.
@Suite(.serialized)
@MainActor
struct NativeOrbitBadgePeerContextTests {
    @Test func normalizedPeerLabelsReachInterpretation() {
        let input = Self.input(peers: ["Connected 2"])
        #expect(input["peerLabels"] as? [String] == ["Connected 2"])
    }

    @Test func peerContextRetainsTheTargetsOwnedFields() {
        let input = Self.input(peers: ["Connected 2"])
        #expect(input["label"] as? String == "Connected 1")
        #expect(input["alias"] as? String == "orchard.pruning")
    }

    @Test func peerOrderAndDuplicateLabelsDoNotChangeInput() throws {
        let labels = ["Research 3", "Research 1", "Research 2", "Research 1"]
        let forward = try Self.encoded(Self.input(peers: labels))
        let reversed = try Self.encoded(Self.input(peers: Array(labels.reversed())))
        #expect(forward == reversed)
        #expect(Self.input(peers: labels)["peerLabels"] as? [String] == [
            "Research 1", "Research 2", "Research 3",
        ])
    }

    @Test func privacySentinelsAreOmittedFromPeerContext() {
        let input = Self.input(peers: ["Account 1", "Account 24", "Account 0003"])
        #expect(input["peerLabels"] == nil)
    }

    @Test func anEmptyVisibleFirstLineCannotExposeAHiddenSecondLine() {
        // Regression: split(whereSeparator:) skipped the empty first line and exposed the next one.
        for separator in ["\n", "\r", "\r\n", "\u{2028}", "\u{2029}"] {
            let input = Self.input(peers: [separator + "private.second.line"])
            #expect(input["peerLabels"] == nil)
        }
    }

    @Test func peerContextUsesOnlyTheVisibleFirstLine() {
        for separator in ["\n", "\r", "\r\n", "\u{2028}", "\u{2029}"] {
            let input = Self.input(peers: ["Volcanic samples" + separator + "private.mailbox.alias"])
            #expect(input["peerLabels"] as? [String] == ["Volcanic samples"])
        }
    }

    @Test func peerContextAddsNeitherPeerAliasesNorIdentifiersAsSourceFields() {
        let input = Self.input(peers: ["Connected 2"])
        #expect(Set(input.keys) == Set(["label", "alias", "peerLabels"]))
    }

    @Test func currentUseNormalizationStillSuppressesTheHistoricalAlias() {
        let input = Self.input("Old sailing — now choral singing", "old.sailing", peers: ["Now drawing"])
        #expect(input["label"] as? String == "choral singing")
        #expect((input["alias"] as? String)?.isEmpty == true)
    }

    @Test func projectLabelsRemainOwnedLiteralSourceClues() {
        let input = Self.input("Project Cedar", "pc", peers: ["Project Lagoon"])
        #expect(input["label"] as? String == "Project Cedar")
        #expect(input["alias"] as? String == "pc")
    }

    @Test func personalNamesArePreservedWithoutInventedAttributes() {
        let input = Self.input("Nolan Avery", "nv7", peers: ["Elena Shaw"])
        #expect(input["label"] as? String == "Nolan Avery")
        #expect(input["alias"] as? String == "nv7")
        #expect(input["terms"] == nil)
    }

    @Test func emptyPeerListsOmitOptionalContext() {
        #expect(Self.input(peers: [])["peerLabels"] == nil)
    }

    @Test func twoThrough24AccountsRetainAllShortPeerLabels() {
        for accountCount in 2...24 {
            let labels = (1..<accountCount).map { "Subject \($0)" }
            let peers = Self.input(peers: labels)["peerLabels"] as? [String]
            #expect(peers?.count == labels.count)
            #expect(Set(peers ?? []) == Set(labels))
        }
    }

    @Test func worstCaseCompleteInputFits2048SerializedBytes() throws {
        for input in Self.worstCaseInputs() {
            let data = try Self.encoded(input)
            #expect(data.count <= 2048)
            #expect((input["label"] as? String)?.utf8.count ?? 0 <= 256)
            #expect((input["alias"] as? String)?.utf8.count ?? 0 <= 256)
        }
    }

    @Test func worstCasePeerArrayFits768SerializedBytes() throws {
        for input in Self.worstCaseInputs() {
            let data = try Self.encoded(input["peerLabels"] ?? [String]())
            #expect(data.count <= 768)
        }
    }

    @Test func hostileInputNormalizationCompletesWithinFiveSeconds() throws {
        let start = ContinuousClock.now
        for input in Self.worstCaseInputs() {
            _ = try Self.encoded(input)
        }
        #expect(start.duration(to: .now) < .seconds(5))
    }

    @Test func currentOwnedLabelSurvivesConflictingHistoricalTopicTags() async {
        let account = NativeOrbitBadgeModel.Account(
            id: "current", text: "", label: "Previously finance — now cello practice", alias: "old.finance")
        let result = await NativeOrbitBadgeModel.prepare([account]) { _ in
            (source: "label", terms: ["finance"])
        }
        #expect(result.purposes["current"] == "cello practice")
        #expect(result.complete)
        #expect(result.proposals.isEmpty)
    }

    @Test func successfulNoneCannotBeResurrectedByGeneratedTopics() async {
        let account = NativeOrbitBadgeModel.Account(id: "opaque", text: "", label: "Nolan Avery", alias: "nv7")
        let result = await NativeOrbitBadgeModel.prepare([account]) { _ in
            (source: "none", terms: ["astronomy"])
        }
        #expect(result.purposes["opaque"]?.isEmpty == true)
        #expect(result.retrievalQueries["opaque"]?.isEmpty == true)
        #expect(result.complete)
    }

    @Test func anUnavailableSourceFieldCannotRecoverAnAlias() async {
        let account = NativeOrbitBadgeModel.Account(
            id: "missing-label", text: "", label: "Mailbox twelve", alias: "garden.pruning")
        let result = await NativeOrbitBadgeModel.prepare([account]) { _ in
            (source: "label", terms: ["garden"])
        }
        #expect(result.purposes["missing-label"]?.isEmpty == true)
        #expect(result.retrievalQueries["missing-label"]?.isEmpty == true)
        #expect(result.complete)
    }

    @Test func cancellationPreventsTheInjectedInterpreterFromRunning() async {
        let account = NativeOrbitBadgeModel.Account(id: "cancelled", text: "", label: "Nolan Avery", alias: "nv7")
        var calls = 0
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await NativeOrbitBadgeModel.prepare([account]) { _ in
                calls += 1
                return (source: "label", terms: [])
            }
        }
        let result = await task.value
        #expect(result.cancelled)
        #expect(calls == 0)
        #expect(result.proposals.isEmpty)
    }

    @Test func all24PrivacyRowsStayBlankAndNeverReachInterpretation() async {
        let accounts = NativeOrbitBadgeResolver.modelAccounts(Self.privateRows())
        #expect(accounts.count == 24)
        #expect(accounts.allSatisfy {
            $0.label.isEmpty && $0.alias.isEmpty && $0.text.isEmpty && $0.brand == nil
        })
        var calls = 0
        let result = await NativeOrbitBadgeModel.prepare(accounts) { _ in
            calls += 1
            return (source: "alias", terms: ["medical"])
        }
        #expect(calls == 0)
        #expect(result.purposes.isEmpty)
        #expect(result.retrievalQueries.isEmpty)
        #expect(result.complete)
    }

    @Test func adaptedPrivacyPeersContributeNoHiddenMailboxContext() {
        let accounts = NativeOrbitBadgeResolver.modelAccounts(Self.privateRows())
        let peers = accounts.dropFirst().map(\.label)
        let input = Self.input(peers: peers)
        #expect(input["peerLabels"] == nil)
        #expect(input["alias"] as? String == "orchard.pruning")
    }

    @Test func excessPeersOmitOptionalContextInsteadOfSelectingAnArbitraryPrefix() {
        let input = Self.input(peers: Array(repeating: "Research", count: 24))
        #expect(input["peerLabels"] == nil)
        #expect(input["label"] as? String == "Connected 1")
        #expect(input["alias"] as? String == "orchard.pruning")
    }

    @Test func dynamicSchemaOffersOnlyAvailableOwnedFields() throws {
        let schema = NativeOrbitBadgeModel.interpretationSchema(label: "Mailbox twelve", alias: "garden.pruning")
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(schema)) as? [String: Any])
        let properties = try #require(object["properties"] as? [String: [String: Any]])
        #expect(properties["source"]?["enum"] as? [String] == ["alias", "none"])
        #expect(Set(properties.keys) == Set(["source", "terms"]))
        #expect(object["x-order"] as? [String] == ["source", "terms"])
    }

    @Test func selectedDescriptiveLabelsCannotRebindToStaleAliasTags() async {
        let account = NativeOrbitBadgeModel.Account(
            id: "descriptive", text: "", label: "Ceramic glazing", alias: "old.sailing")
        let result = await NativeOrbitBadgeModel.prepare([account]) { _ in
            (source: "label", terms: ["sailing"])
        }
        #expect(result.purposes["descriptive"] == "Ceramic glazing")
        #expect(result.complete)
    }

    private static func input(
        _ label: String = "Connected 1", _ alias: String = "orchard.pruning", peers: [String]) -> [String: Any]
    {
        NativeOrbitBadgeModel.interpretationInput(label: label, alias: alias, peerLabels: peers)
    }

    private static func encoded(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    private static func worstCaseInputs() -> [[String: Any]] {
        let multibyte = String(repeating: "花", count: 66000) // 198000 UTF-8 bytes.
        let combining = "a" + String(repeating: "\u{0301}", count: 50000) // One 100001-byte grapheme.
        return [
            Self.input(multibyte, combining, peers: (0..<23).map { "\($0) " + multibyte }),
            Self.input(
                String(repeating: "\u{0001}", count: 10000),
                String(repeating: "\u{0002}", count: 10000),
                peers: (0..<23).map { "\($0) " + String(repeating: "\u{0003}", count: 10000) }),
        ]
    }

    private static func privateRows() -> [NativeOrbitAccountPresentation] {
        (1...24).map { index in
            .init(
                id: "private-\(index)",
                label: "Account \(index)",
                email: "person+medical\(index)@example.invalid",
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
    }
}
