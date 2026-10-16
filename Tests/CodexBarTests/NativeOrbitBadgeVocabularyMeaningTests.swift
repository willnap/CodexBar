import Testing
@testable import CodexBar

@MainActor
struct NativeOrbitBadgeVocabularyMeaningTests {
    /// Selector lookups use catalog keys; raw native names must not accidentally serve as lookup keys.
    @Test func concreteMeaningsAreAvailableByExistingCandidateKey() throws {
        let space = try #require(NativeOrbitBadgeVocabulary.meanings["native:space"])
        #expect(space.contains("keyboard spacebar"))
        #expect(NativeOrbitBadgeVocabulary.meanings["space"] == nil)
        let finance = try #require(NativeOrbitBadgeVocabulary.meanings["finance"])
        #expect(finance.contains("banknote"))
        #expect(NativeOrbitBadgeVocabulary.meanings["banknote.fill"] == nil)
    }

    /// Every offered vocabulary candidate needs its own bounded description for an opaque-ID prompt.
    @Test func allCandidateKeysHaveIndependentBoundedDefinitions() {
        #expect(Set(NativeOrbitBadgeVocabulary.meanings.keys) == Set(NativeOrbitBadgeVocabulary.entries.map(\.key)))
        for entry in NativeOrbitBadgeVocabulary.entries {
            let meaning = NativeOrbitBadgeVocabulary.meanings[entry.key] ?? ""
            #expect(!meaning.isEmpty)
            #expect(meaning.count <= 240)
            #expect(meaning.utf8.count <= 512)
            #expect(meaning != entry.title)
            if entry.symbol.contains(".") {
                #expect(!meaning.localizedCaseInsensitiveContains(entry.symbol))
            }
        }
    }

    /// Similar native identifiers cannot substitute a different physical depiction.
    @Test func knownAmbiguitiesDescribeTheActualGlyph() throws {
        let carrying = try #require(NativeOrbitBadgeVocabulary.meanings["native:case.fill"])
        #expect(carrying.contains("carrying case"))
        #expect(!carrying.contains("legal"))
        let foam = try #require(NativeOrbitBadgeVocabulary.meanings["native:figure.rolling"])
        #expect(foam.contains("foam roller"))
        #expect(!foam.contains("wheelchair"))
        let machine = try #require(NativeOrbitBadgeVocabulary.meanings["native:figure.rower"])
        #expect(machine.contains("rowing machine"))
        #expect(!machine.contains("boat"))
    }
}
