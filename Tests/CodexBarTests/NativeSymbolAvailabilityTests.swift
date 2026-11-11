import Foundation
import Testing
@testable import CodexBar

struct NativeSymbolAvailabilityTests {
    @Test
    func `the symbols are asked about once for a system and a list`() throws {
        let suite = "NativeSymbolAvailabilityTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var asked: [String] = []
        func missing(_ symbols: [String], system: String) -> Set<String> {
            NativeSymbolAvailability.missing(among: symbols, defaults: defaults, system: system) {
                asked.append($0)
                return $0 != "not.a.symbol"
            }
        }
        #expect(missing(["gear", "not.a.symbol", "star"], system: "A") == ["not.a.symbol"])
        #expect(asked.sorted() == ["gear", "not.a.symbol", "star"])
        // The same list in another order, on the same system: nothing is asked again.
        asked = []
        #expect(missing(["star", "gear", "not.a.symbol", "gear"], system: "A") == ["not.a.symbol"])
        #expect(asked.isEmpty)
        // A new system, or a list that changed, is asked afresh.
        #expect(missing(["gear", "not.a.symbol", "star"], system: "B") == ["not.a.symbol"])
        #expect(asked.count == 3)
        asked = []
        #expect(missing(["gear", "star"], system: "B").isEmpty)
        #expect(asked.sorted() == ["gear", "star"])
    }

    @Test
    func `without a store every launch asks`() {
        var asked = 0
        for _ in 0..<2 {
            _ = NativeSymbolAvailability.missing(among: ["gear"], defaults: nil, system: "A") { _ in
                asked += 1
                return true
            }
        }
        #expect(asked == 2)
    }
}
