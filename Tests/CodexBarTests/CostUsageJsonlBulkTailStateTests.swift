import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageJsonlBulkTailStateTests {
    @Test(arguments: [
        #"{"a":"plain string","b":[1,2,{"c":"x\"y\\z"}],"d":true,"e":null,"f":-1.5e3}"#,
        #"  "top-level \"escaped\" string with \\ backslash"  "#,
        #"{"tool_output":"line one\nline two\t\"quoted\" \\\\ tail","n":12345}"#,
        #"[true, false, null, 0, -0.25, 6.02e+23, "s"]"#,
        #"tru"#,
        #"{"unterminated":"abc\"#,
        #"12.5"#,
        "{\"emoji\":\"caf\u{e9} \u{1F600}\",\"k\":\"\\u0041\"}",
    ])
    func `bulk tail state matches per-byte state at every split`(text: String) {
        let bytes = Array(text.utf8)
        for split in 0...bytes.count {
            #expect(CostUsageJsonl._tailStateBulkMatchesPerByteForTesting(bytes, splits: [split]))
        }
        #expect(CostUsageJsonl._tailStateBulkMatchesPerByteForTesting(bytes, splits: Array(0...bytes.count)))
    }

    @Test
    func `bulk tail state matches per-byte state on generated payloads`() {
        var generator = SystemRandomNumberGenerator()
        let alphabet = Array(#"{}[]",:\ "abcntu019-+.eE"#.utf8) + [0x0A, 0x09, 0xC3, 0xA9]
        for _ in 0..<300 {
            let length = Int.random(in: 0...200, using: &generator)
            let bytes = (0..<length).map { _ in alphabet.randomElement(using: &generator) ?? 0x20 }
            let splits = (0..<Int.random(in: 0...6, using: &generator)).map { _ in
                Int.random(in: 0...max(0, length), using: &generator)
            }
            #expect(CostUsageJsonl._tailStateBulkMatchesPerByteForTesting(bytes, splits: splits))
        }
    }
}
