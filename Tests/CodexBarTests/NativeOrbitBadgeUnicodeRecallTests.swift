import Testing
@testable import CodexBar

@MainActor struct NativeOrbitBadgeUnicodeRecallTests {
    @Test(arguments: ["मौसम", "रिकॉर्ड", "আবহাওয়ার", "বই", "อากาศ", "طَقْس"])
    func completeScriptWordsKeepTheirCombiningMarks(_ word: String) {
        #expect(NativeOrbitBadgeSearch.words(word).contains(word))
    }

    @Test func hindiSubjectsRemainDistinctBeforeRetrieval() {
        let peers = ["ड्राइविंग कक्षाएँ", "पुस्तक समीक्षा"]
        #expect(NativeOrbitBadgeSearch.comparisonWords("मौसम का रिकॉर्ड").contains("मौसम"))
        #expect(NativeOrbitBadgeSearch.comparisonWords("मौसम का रिकॉर्ड").contains("रिकॉर्ड"))
        #expect(NativeOrbitBadgeSearch.hasDistinctMeaning(in: "मौसम का रिकॉर्ड", peers: peers))
        #expect(!NativeOrbitBadgeSearch.hasDistinctMeaning(in: "मौसम का रिकॉर्ड", peers: ["मौसम का रिकॉर्ड"]))
    }

    @Test func nativeScriptHyphenCompoundsRetainTheirFullSpelling() {
        #expect(NativeOrbitBadgeSearch.words("मौसम-रिकॉर्ड").contains("मौसमरिकॉर्ड"))
        #expect(NativeOrbitBadgeSearch.words("আবহাওয়ার-বই").contains("আবহাওয়ারবই"))
    }

    @Test func latinAccentEquivalenceAndEmojiSeparationRemainIntact() {
        #expect(NativeOrbitBadgeSearch.words("Café") == ["cafe"])
        #expect(NativeOrbitBadgeSearch.words("Cafe\u{301}") == ["cafe"])
        #expect(NativeOrbitBadgeSearch.words("🌧️ मौसम ☔️") == ["मौसम"])
        #expect(NativeOrbitBadgeSearch.words("🌧️☔️").isEmpty)
    }

    @Test func oversizedCombiningGraphemesStillStopAtTheRealAccountBoundary() {
        let oversized = "क" + String(repeating: "\u{093f}", count: 100_000)
        let account = NativeOrbitBadgeModel.Account(id: "bounded", text: "", label: oversized, alias: "")
        #expect(account.label.isEmpty)
        #expect(NativeOrbitBadgeSearch.words(account.label).isEmpty)
    }
}
