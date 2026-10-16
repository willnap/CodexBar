import Foundation
import Testing
@testable import CodexBar

@MainActor
struct NativeOrbitBadgeSearchTests {
    /// Removing concrete object matches must not leave only a generic occupation or activity.
    @Test
    func retrievesBicycleForRepairWorkshop() {
        let candidates = NativeOrbitBadgeSearch.candidates(
            text: "Bicycle repair workshop",
            peers: ["Pottery kiln"],
            entries: NativeOrbitBadgeVocabulary.entries)

        #expect(candidates.contains { $0.entry.symbol == "bicycle" })
    }

    /// A generic audience must not displace the explicitly named photographic purpose.
    @Test
    func retrievesPhotographyRatherThanOnlyColleagues() {
        let candidates = NativeOrbitBadgeSearch.candidates(
            text: "Colleagues photography",
            peers: ["Community gardening"],
            entries: NativeOrbitBadgeVocabulary.entries)

        #expect(candidates.contains { $0.entry.symbol == "camera.fill" })
        #expect(!candidates.contains { $0.entry.key == "team" })
    }

    /// A shared word is insufficient evidence for a physical sensor control.
    @Test
    func contactDoesNotRetrievePhysicalContactSensor() {
        let candidates = NativeOrbitBadgeSearch.candidates(
            text: "Contact",
            peers: ["Music"],
            entries: NativeOrbitBadgeVocabulary.entries)

        #expect(!candidates.isEmpty)
        #expect(!candidates.contains { $0.entry.symbol.hasPrefix("contact.sensor") })
    }

    /// Raw seat-layout variants must not exhaust the choices for an ordinary ambiguous word.
    @Test
    func driveDoesNotRetrieveSeatLayoutControls() {
        let candidates = NativeOrbitBadgeSearch.candidates(
            text: "Drive",
            peers: ["Archive"],
            entries: NativeOrbitBadgeVocabulary.entries)

        #expect(!candidates.isEmpty)
        #expect(!candidates.contains { $0.entry.symbol.hasPrefix("figure.seated.seatbelt") })
    }

    /// Subtracting the union of peer tokens destroys this distinct combination completely.
    @Test
    func retainsPurposeWhenEachWordOccursInDifferentPeers() {
        let candidates = NativeOrbitBadgeSearch.candidates(
            text: "Library gardening",
            peers: ["Library music", "Office gardening"],
            entries: NativeOrbitBadgeVocabulary.entries)

        #expect(candidates.contains { $0.entry.symbol == "book.closed.fill" })
        #expect(candidates.contains { $0.entry.symbol == "leaf.fill" })
    }

    /// Long labels need a short source-owned distinction, rather than shared boilerplate.
    @Test
    func longLabelEvidenceIsShortOriginalAndDistinct() throws {
        let common = String(
            repeating: "Library members manage shared lending records and annual reading events. ",
            count: 3)
        let text = common + "Bicycle"
        let peers = [common + "Pottery"]
        let candidates = NativeOrbitBadgeSearch.candidates(
            text: text,
            peers: peers,
            entries: NativeOrbitBadgeVocabulary.entries)
        let first = try #require(candidates.first)

        #expect(first.evidence == "Bicycle")
        for candidate in candidates {
            #expect((1...80).contains(candidate.evidence.count))
            #expect(text.contains(candidate.evidence))
            #expect(!peers.contains { $0.localizedCaseInsensitiveContains(candidate.evidence) })
        }
    }

    /// Truncating an opaque overlong token must not manufacture useful-looking evidence.
    @Test
    func skipsOverlongIdentifierForCompletePurposeWord() throws {
        let identifier = String(repeating: "qzx", count: 35)
        let text = identifier + " Bicycle"
        let evidence = try #require(NativeOrbitBadgeSearch.evidence(in: text, peers: []))

        #expect(evidence == "Bicycle")
        #expect(text.contains(evidence))
        #expect(evidence.count <= 80)
    }

    /// A recovery query must not invent differentiation between identical whole labels.
    @Test
    func identicalLabelsHaveNoCandidatesEvenWithQuery() {
        let candidates = NativeOrbitBadgeSearch.candidates(
            text: "Reading circle",
            peers: ["Reading circle"],
            query: "bicycle",
            entries: NativeOrbitBadgeVocabulary.entries)

        #expect(candidates.isEmpty)
    }

    /// Cosmetic whitespace and case must not turn the same label into new evidence.
    @Test
    func cosmeticLabelDifferencesDoNotCreateEvidence() {
        #expect(NativeOrbitBadgeSearch.evidence(
            in: "  SHARED LIBRARY  ",
            peers: ["shared library"]) == nil)
    }

    /// A nil query exercises the lexical path without requiring installed embedding assets.
    @Test
    func lexicalPathRetrievesDiacriticFoldedPurpose() {
        let candidates = NativeOrbitBadgeSearch.candidates(
            text: "Photógraphy",
            peers: ["Gardening"],
            query: nil,
            entries: NativeOrbitBadgeVocabulary.entries)

        #expect(candidates.contains { $0.entry.symbol == "camera.fill" })
    }

    /// Nonpositive limits must return nothing; a positive bound must actually truncate choices.
    @Test
    func respectsCandidateLimits() {
        let entries = NativeOrbitBadgeVocabulary.entries
        let full = NativeOrbitBadgeSearch.candidates(text: "Music", peers: [], entries: entries)
        #expect(full.count > 1)

        for limit in [-4, 0, 1, 3] {
            let candidates = NativeOrbitBadgeSearch.candidates(
                text: "Music", peers: [], entries: entries, limit: limit)
            #expect(candidates.count <= max(0, limit))
            if limit > 0 { #expect(!candidates.isEmpty) }
        }
    }

    /// Inventory enumeration order must not choose between equally scored options.
    @Test
    func candidateOrderIsStableAcrossInventoryOrder() {
        let entries = NativeOrbitBadgeVocabulary.entries
        let first = NativeOrbitBadgeSearch.candidates(
            text: "Music", peers: [], entries: entries).map(\.entry.key)
        let reordered = NativeOrbitBadgeSearch.candidates(
            text: "Music", peers: [], entries: Array(entries.reversed())).map(\.entry.key)
        let repeated = NativeOrbitBadgeSearch.candidates(
            text: "Music", peers: [], entries: entries).map(\.entry.key)

        #expect(first.count > 1)
        #expect(first == reordered)
        #expect(first == repeated)
        #expect(Set(first).count == first.count)
    }
}
