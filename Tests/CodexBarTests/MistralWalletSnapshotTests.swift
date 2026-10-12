import Foundation
import Testing
@testable import CodexBarCore

struct MistralWalletSnapshotTests {
    private static let observedAt = Date(timeIntervalSince1970: 1_790_000_000)

    @Test(arguments: ["USD", "EUR"])
    func `measured wallet keeps its own currency and observation separate from billed spend`(currency: String) throws {
        let snapshot = Self.snapshot(credits: .init(
            walletAmount: 12.5,
            creditNotesAmount: 2.25,
            ongoingUsageBalance: 1.5,
            currency: currency))
        let usage = snapshot.toUsageSnapshot()
        let wallet = try #require(usage.providerCost)
        #expect(wallet.balance == 13.25)
        #expect(wallet.currencyCode == currency)
        #expect(wallet.balanceUpdatedAt == Self.observedAt)
        #expect(wallet.updatedAt == Self.observedAt)
        #expect(wallet.usageIsUnavailable == true)
        #expect(wallet.spendLimitWindow == nil)
        #expect(usage.mistralUsage?.totalCost == 40)
        #expect(usage.mistralUsage?.currency == "USD")
        #expect(usage.mistralUsage?.totalInputTokens == 100)
        #expect(usage.primary == nil)
    }

    @Test func `confirmed depleted wallet remains an observed zero`() throws {
        let wallet = try #require(Self.snapshot(credits: .init(
            walletAmount: 2,
            creditNotesAmount: 0,
            ongoingUsageBalance: 5,
            currency: "USD")).toUsageSnapshot().providerCost)
        #expect(wallet.balance == 0)
        #expect(wallet.usageIsUnavailable == true)
    }

    @Test func `absent or nonfinite credit inventory does not manufacture a wallet`() {
        #expect(Self.snapshot(credits: nil).toUsageSnapshot().providerCost == nil)
        #expect(Self.snapshot(credits: .init(
            walletAmount: .nan,
            creditNotesAmount: 0,
            ongoingUsageBalance: 0,
            currency: "USD")).toUsageSnapshot().providerCost == nil)
    }

    private static func snapshot(credits: MistralCreditsSnapshot?) -> MistralUsageSnapshot {
        MistralUsageSnapshot(
            totalCost: 40,
            currency: "USD",
            currencySymbol: "$",
            totalInputTokens: 100,
            totalOutputTokens: 20,
            totalCachedTokens: 30,
            modelCount: 1,
            daily: [],
            credits: credits,
            startDate: nil,
            endDate: nil,
            updatedAt: self.observedAt)
    }
}
