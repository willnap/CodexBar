import Testing
@testable import CodexBar

@MainActor struct NativeOrbitBadgeSingleGlyphTests {
    @Test(arguments: ["书", "猫", "木", "책", "집", "\u{110e}\u{1162}\u{11a8}"])
    func singleGraphemeHanAndHangulLexemesSurviveTokenization(_ text: String) {
        #expect(NativeOrbitBadgeSearch.isSingleGlyphSubject(text))
        #expect(NativeOrbitBadgeSearch.words(text).contains(text))
        #expect(NativeOrbitBadgeSearch.hasDistinctMeaning(in: text, peers: []))
        #expect(!NativeOrbitBadgeSearch.hasDistinctMeaning(in: text, peers: [text]))
    }

    @Test(arguments: [
        ("书", "book; literature; reading", ["book.fill", "book.closed.fill"]),
        ("猫", "cat; pet; feline", ["cat.fill"]),
        ("木", "tree; wood; plant", ["tree.fill"]),
        ("책", "book; literature; reading", ["book.fill", "book.closed.fill"]),
        ("집", "house; home; dwelling", ["house.fill"]),
    ])
    func suppliedEnglishTagsCanReachActualNativeSubjects(_ input: (String, String, [String])) {
        let entries = NativeOrbitBadgeModel.entries.filter {
            NativeOrbitBadgeSearch.isDistinctCandidate($0, source: input.0, peers: [])
        }
        let pool = NativeOrbitBadgeSearch.candidates(
            text: input.0,
            peers: [],
            query: input.0 + "; " + input.1,
            entries: entries,
            limit: 8)
        #expect(pool.contains { input.2.contains($0.entry.symbol) })
        #expect(pool.count <= 8)
    }

    @Test func scriptPredicateIsAvailableOutsideTheMainActorAndBoundsOversizedGlyphs() async {
        let detached = await Task.detached { NativeOrbitBadgeSearch.isSingleGlyphSubject("书") }.value
        #expect(detached)
        #expect(NativeOrbitBadgeSearch.isSingleGlyphSubject("책") ==
            NativeOrbitBadgeSearch.isSingleGlyphSubject("\u{110e}\u{1162}\u{11a8}"))
        #expect(!NativeOrbitBadgeSearch.isSingleGlyphSubject("木" + String(repeating: "\u{0301}", count: 10000)))
        #expect(!NativeOrbitBadgeSearch.isSingleGlyphSubject("书猫"))
        #expect(!NativeOrbitBadgeSearch.isSingleGlyphSubject(""))
    }

    @Test(arguments: ["A", "q", "Ж", "я", "Ω", "1", "一", "二", "三", "十", "零", "😀", "☔️", "\u{0301}", "\u{093f}"])
    func initialNumericEmojiAndIsolatedMarkControlsStayNonsemantic(_ text: String) {
        #expect(!NativeOrbitBadgeSearch.isSingleGlyphSubject(text))
        #expect(NativeOrbitBadgeSearch.words(text).isEmpty)
        #expect(!NativeOrbitBadgeSearch.hasDistinctMeaning(in: text, peers: []))
    }
}
