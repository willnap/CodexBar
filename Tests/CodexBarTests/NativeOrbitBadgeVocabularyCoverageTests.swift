import Testing
@testable import CodexBar

@MainActor
struct NativeOrbitBadgeVocabularyCoverageTests {
    /// Ordinary subjects absent from raw native names must reach their recognizable glyph families.
    @Test(arguments: [
        ("justice", "building.columns.fill"),
        ("foam roller", "figure.rolling"),
        ("ergometer", "figure.rower"),
        ("wireless network", "wifi"),
        ("tethering", "personalhotspot"),
        ("shuttlecock", "figure.badminton"),
        ("interval training", "figure.highintensity.intervaltraining"),
        ("spacebar", "space"),
        ("dehumidifying", "dehumidifier.fill"),
        ("financial savings", "banknote.fill"),
    ])
    func ordinaryMeaningsRetrieveRecognizableGlyphs(query: String, symbol: String) {
        let results = NativeOrbitBadgeSearch.candidates(
            text: query, peers: [], entries: NativeOrbitBadgeVocabulary.entries, limit: 8)
        let equivalents = symbol == "figure.rower" ? ["figure.rower", "figure.indoor.rowing"] : [symbol]
        #expect(results.contains { equivalents.contains($0.entry.symbol) })
    }

    /// A calibration weight must not masquerade as balance scales in a legal context.
    @Test func justiceDoesNotRetrieveACalibrationWeight() {
        let results = NativeOrbitBadgeSearch.candidates(
            text: "justice", peers: [], entries: NativeOrbitBadgeVocabulary.entries, limit: 8)
        #expect(!results.contains { $0.entry.symbol == "scalemass.fill" })
    }

    /// Indoor rowing machines cannot advertise watercraft-only clues.
    @Test func boatCrewDoesNotRetrieveAnIndoorRowingMachine() {
        let results = NativeOrbitBadgeSearch.candidates(
            text: "boat crew", peers: [], entries: NativeOrbitBadgeVocabulary.entries, limit: 8)
        #expect(results.contains { $0.entry.symbol == "figure.outdoor.rowing" })
        #expect(!results.contains { $0.entry.symbol == "figure.rower" })
    }
}
