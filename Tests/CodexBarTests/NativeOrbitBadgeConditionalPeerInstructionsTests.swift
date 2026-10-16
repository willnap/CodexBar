import CryptoKit
import Foundation
import Testing
@testable import CodexBar

@Suite(.serialized)
@MainActor
struct NativeOrbitBadgeConditionalPeerInstructionsTests {
    // Runtime instruction bytes from Frozen-v26 and measured comparative v1.1, respectively.
    private static let baseInstructionSHA256 = "e90f9a544c8208b6880e9441ab3630418255d11f091b9bc855e30ae0ee02fa9f"
    private static let comparativeInstructionSHA256 = "9e6f3808946c7424fcc34644f50b8eb36af04366a48623ea39965f7d8b2565b3"

    @Test func actualRequestWithContextRetainsMeasuredComparativeInstructions() throws {
        let request = try NativeOrbitBadgeModel.interpretationRequest(
            Self.account("Project Orion"), peers: [Self.account("Project Lotus", id: "peer")])
        #expect(Self.digest(Data(request.instructions.utf8)) == Self.comparativeInstructionSHA256)
    }

    @Test func aPrivatePeerDoesNotPerturbAnOtherwiseIdenticalNamedTarget() throws {
        let target = Self.account("Project Orion", "po")
        let alone = try NativeOrbitBadgeModel.interpretationRequest(target, peers: [])
        let privatePeer = try NativeOrbitBadgeModel.interpretationRequest(
            target, peers: [Self.account("Account 2", id: "private")])
        #expect(alone.input == privatePeer.input)
        #expect(alone.instructions == privatePeer.instructions)
        #expect(Self.digest(Data(privatePeer.instructions.utf8)) == Self.baseInstructionSHA256)
    }

    @Test func missingEmptyOrInvalidSerializedPeerContextUsesTheBasePolicy() throws {
        for value: [String: Any] in [[:], ["peerLabels": [String]()], ["peerLabels": "not an array"]] {
            let input = try JSONSerialization.data(withJSONObject: value)
            let instructions = NativeOrbitBadgeModel.interpretationInstructions(input: input)
            #expect(Self.digest(Data(instructions.utf8)) == Self.baseInstructionSHA256)
        }
        let instructions = NativeOrbitBadgeModel.interpretationInstructions(input: Data("invalid JSON".utf8))
        #expect(Self.digest(Data(instructions.utf8)) == Self.baseInstructionSHA256)
    }

    @Test func filteredOrExcessPeerLabelsCannotEnableComparativeInstructions() throws {
        let target = Self.account("Project Orion")
        let variants: [[NativeOrbitBadgeModel.Account]] = [
            [], [Self.account("", id: "blank")], [Self.account("\nprivate second line", id: "line")],
            (0..<24).map { Self.account("Research \($0)", id: "peer-\($0)") },
        ]
        for peers in variants {
            let request = try NativeOrbitBadgeModel.interpretationRequest(target, peers: peers)
            let fields = try #require(JSONSerialization.jsonObject(with: request.input) as? [String: Any])
            #expect(fields["peerLabels"] == nil)
            #expect(Self.digest(Data(request.instructions.utf8)) == Self.baseInstructionSHA256)
        }
    }

    @Test func all14MeasuredComparativeInputsAndInstructionsRemainByteIdentical() throws {
        // label, alias, peer label, SHA of the actual v1.1 sorted JSON request.
        let cases: [(String, String, String, String)] = [
            (
                "Connected 1",
                "community.beekeeping",
                "Connected 2",
                "cd1f832ef51c7a80c760dc4212b7909ba159b1a3291c035355a625e24179a2b8"),
            (
                "Connected 2",
                "shore.birdwatching",
                "Connected 1",
                "64c208b0ad531ed64c2f7d2c4c1f169e8e5bca7a7708469c15129345e89a25f8"),
            (
                "Research",
                "meteor.shower",
                "Research",
                "74ec60458b6a5cdc9f9bdc28bdd9dedad651c6ca2cd3d3ccc232e296e62f7621"),
            (
                "Research",
                "cave.mapping",
                "Research",
                "5f340aaf6bce2e2b0997f8b841ee753b35419019d442cf3d472b20852b00b700"),
            (
                "Ceramic glazing notes",
                "old.sailing",
                "Volcanic rock samples",
                "93da753ffe43b52233b4460dadca58b4991136f0821980a5edc6f96c36e5fe10"),
            (
                "Volcanic rock samples",
                "old.cycling",
                "Ceramic glazing notes",
                "00219c6e0c098ad34d78228187def6685b388ed08f2133251a581f20d830a37e"),
            (
                "Project Cedar",
                "pc",
                "Project Lagoon",
                "ba861fada0f405b3a167250bf3731f3e14add9ab8bd29a891ed3a21262354d0b"),
            (
                "Project Lagoon",
                "pl",
                "Project Cedar",
                "0fdd754f6b0462958d5749d6f1d442e92598cf1046c49ec318e979c456efc6ec"),
            (
                "Old invoices — now choral singing",
                "finance.invoices",
                "Currently orchard pruning",
                "6dcaa333c7acd09b4083283d7d3b7617a796ecdf4fa06feb2eca2d3caf7cb94f"),
            (
                "Currently orchard pruning",
                "old.piano",
                "Old invoices — now choral singing",
                "2615d15389525cebb67aaf937eb191c4c05e70a319eef885b90a52d214a6d032"),
            (
                "Mira Ellison",
                "weaving.practice",
                "Nolan Avery",
                "ab0363447bf93b610aeb4aeda6dedf803c2c0913cd492d00879ae901af5fc8d3"),
            ("Nolan Avery", "na7q", "Mira Ellison", "3dbd0054e29748842cd6abc10ecffcbd6a0b721c02cc33809eca1782cbb664b5"),
            (
                "Research team A",
                "rx8",
                "Research team B",
                "46e99dd4da6cfc63a844c701f5cb9d9bf786cf6b48c59e19a1e81a8d3dc34b99"),
            (
                "Research team B",
                "qz4",
                "Research team A",
                "3730e887f65c9580e719deae0592ad11d717910e37f8969ff352eff834b5e854"),
        ]
        #expect(cases.count == 14)
        for (label, alias, peerLabel, expectedInputSHA256) in cases {
            let request = try NativeOrbitBadgeModel.interpretationRequest(
                Self.account(label, alias), peers: [Self.account(peerLabel, id: "peer")])
            #expect(Self.digest(request.input) == expectedInputSHA256)
            #expect(Self.digest(Data(request.instructions.utf8)) == Self.comparativeInstructionSHA256)
        }
    }

    private static func account(
        _ label: String, _ alias: String = "", id: String = "target") -> NativeOrbitBadgeModel.Account
    {
        .init(id: id, text: "", label: label, alias: alias)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
