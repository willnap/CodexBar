import Foundation
import Testing
@testable import CodexBarCore

/// A report lists one entry for every request instant, and several such lists are alive at once.
struct CostUsageTimedEntryTests {
    private let instant = Date(timeIntervalSince1970: 1_800_000_000)

    @Test
    func `an entry packs into four words`() {
        #expect(MemoryLayout<CostUsageTimedEntry>.stride <= 32)
    }

    @Test
    func `absent and present values, and their completeness, come back as given`() {
        let both = CostUsageTimedEntry(timestamp: self.instant, totalTokens: 12, costUSD: 0.5)
        #expect(both.totalTokens == 12)
        #expect(both.costUSD == 0.5)
        #expect(both.tokensAreComplete)
        #expect(both.costIsComplete)

        let neither = CostUsageTimedEntry(timestamp: self.instant, totalTokens: nil, costUSD: nil)
        #expect(neither.totalTokens == nil)
        #expect(neither.costUSD == nil)
        #expect(!neither.tokensAreComplete)
        #expect(!neither.costIsComplete)
        // A known zero is not an absent value.
        let zero = CostUsageTimedEntry(timestamp: self.instant, totalTokens: 0, costUSD: 0)
        #expect(zero.totalTokens == 0)
        #expect(zero.costUSD == 0)
        #expect(zero != neither)
        #expect(zero.tokensAreComplete)

        let partial = CostUsageTimedEntry(
            timestamp: self.instant, totalTokens: 7, costUSD: 1, tokensAreComplete: false, costIsComplete: false)
        #expect(partial.totalTokens == 7)
        #expect(!partial.tokensAreComplete)
        #expect(!partial.costIsComplete)
        #expect(partial != CostUsageTimedEntry(timestamp: self.instant, totalTokens: 7, costUSD: 1))
        // Values that cannot be complete are never marked so.
        let invalid = CostUsageTimedEntry(timestamp: self.instant, totalTokens: -1, costUSD: .infinity)
        #expect(invalid.totalTokens == -1)
        #expect(invalid.costUSD == .infinity)
        #expect(!invalid.tokensAreComplete)
        #expect(!invalid.costIsComplete)
        #expect(both == CostUsageTimedEntry(timestamp: self.instant, totalTokens: 12, costUSD: 0.5))
    }
}
