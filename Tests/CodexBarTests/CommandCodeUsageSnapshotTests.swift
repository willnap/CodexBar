import Foundation
import Testing
@testable import CodexBarCore

struct CommandCodeUsageSnapshotTests {
    private static let observedAt = Date(timeIntervalSince1970: 1_790_000_000)
    private static let resetAt = Date(timeIntervalSince1970: 1_792_000_000)

    @Test func `reported grant publishes monthly spend and independent spendable balance`() throws {
        let snapshot = Self.snapshot(
            remaining: 12,
            purchased: 7,
            granted: 80,
            plan: CommandCodePlanCatalog.plan(forID: "individual-go"))
        let usage = snapshot.toUsageSnapshot()
        let cost = try #require(usage.providerCost)
        #expect(cost.used == 68)
        #expect(cost.limit == 80)
        #expect(cost.currencyCode == "USD")
        #expect(cost.period == "Monthly")
        #expect(cost.resetsAt == Self.resetAt)
        #expect(cost.balance == 19)
        #expect(cost.balanceUpdatedAt == Self.observedAt)
        #expect(cost.updatedAt == Self.observedAt)
        #expect(cost.usageIsUnavailable != true)
        #expect(usage.commandCodeHasSubscriptionPlan == true)
    }

    @Test func `known subscription allocation remains available without a reported grant`() throws {
        let cost = try #require(Self.snapshot(
            remaining: 8,
            purchased: 3,
            plan: CommandCodePlanCatalog.plan(forID: "individual-go")).toUsageSnapshot().providerCost)
        #expect(cost.used == 2)
        #expect(cost.limit == 10)
        #expect(cost.balance == 11)
    }

    @Test(arguments: [false, true])
    func `unknown grant retains wallet independently of optional subscription enrichment`(failed: Bool) throws {
        let usage = Self.snapshot(
            remaining: 12,
            purchased: 7,
            enrichmentUnavailable: failed).toUsageSnapshot()
        let cost = try #require(usage.providerCost)
        #expect(cost.balance == 19)
        #expect(cost.balanceUpdatedAt == Self.observedAt)
        #expect(cost.usageIsUnavailable == true)
        #expect(cost.spendLimitWindow == nil)
        #expect(usage.commandCodeSubscriptionEnrichmentUnavailable == failed)
        #expect(usage.commandCodeHasSubscriptionPlan == false)
        #expect((usage.tertiary == nil) == failed)
    }

    @Test(arguments: [0.0, -4.0])
    func `zero and signed balances remain observations without synthetic spend`(remaining: Double) throws {
        let cost = try #require(Self.snapshot(
            remaining: remaining,
            purchased: 0).toUsageSnapshot().providerCost)
        #expect(cost.balance == remaining)
        #expect(cost.usageIsUnavailable == true)
    }

    @Test func `observed unspent grant establishes zero spend`() throws {
        let cost = try #require(Self.snapshot(
            remaining: 80,
            purchased: 0,
            granted: 80).toUsageSnapshot().providerCost)
        #expect(cost.used == 0)
        #expect(cost.limit == 80)
        #expect(cost.balance == 80)
        #expect(cost.usageIsUnavailable != true)
    }

    @Test func `nonfinite readings cannot become monetary observations`() {
        #expect(Self.snapshot(
            remaining: .nan,
            purchased: .infinity).toUsageSnapshot().providerCost == nil)
    }

    private static func snapshot(
        remaining: Double,
        purchased: Double,
        granted: Double? = nil,
        plan: CommandCodePlanCatalog.Plan? = nil,
        enrichmentUnavailable: Bool = false) -> CommandCodeUsageSnapshot
    {
        CommandCodeUsageSnapshot(
            monthlyCreditsRemaining: remaining,
            purchasedCredits: purchased,
            premiumMonthlyCredits: remaining,
            opensourceMonthlyCredits: remaining,
            monthlyCreditsGranted: granted,
            plan: plan,
            billingPeriodEnd: self.resetAt,
            subscriptionStatus: plan == nil ? nil : "active",
            subscriptionEnrichmentUnavailable: enrichmentUnavailable,
            updatedAt: self.observedAt)
    }
}
