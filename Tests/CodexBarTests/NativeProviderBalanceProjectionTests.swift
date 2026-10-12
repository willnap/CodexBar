import Foundation
import Testing
@testable import CodexBarCore

struct NativeProviderBalanceProjectionTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func `Devin overage balance survives without becoming reported spending`() throws {
        let source = try DevinUsageParser.parse(
            [
                "daily_percentage": 12,
                "weekly_percentage": 42,
                "overage_balance_cents": 1234,
            ],
            organization: nil,
            now: self.now)
        let cost = try #require(source.toUsageSnapshot().providerCost)
        #expect(cost.balance == 12.34)
        #expect(cost.currencyCode == "USD")
        #expect(cost.balanceUpdatedAt == self.now)
        #expect(cost.usageIsUnavailable == true)
    }

    @Test func `OpenCode Go Zen wallet survives without becoming reported spending`() throws {
        let source = OpenCodeGoUsageSnapshot.zenBalanceOnly(balanceUSD: 12.34, updatedAt: self.now)
        let cost = try #require(source.toUsageSnapshot().providerCost)
        #expect(cost.balance == 12.34)
        #expect(cost.currencyCode == "USD")
        #expect(cost.balanceUpdatedAt == self.now)
        #expect(cost.usageIsUnavailable == true)
    }

    @Test func `MiMo preserves balance currency and skips fabricated local fallback balances`() throws {
        let source = MiMoUsageSnapshot(balance: 12.34, currency: "CNY", updatedAt: self.now)
        let cost = try #require(source.toUsageSnapshot().providerCost)
        #expect(cost.balance == 12.34)
        #expect(cost.currencyCode == "CNY")
        #expect(cost.balanceUpdatedAt == self.now)
        #expect(cost.usageIsUnavailable == true)
        #expect(source.toUsageSnapshot(includeBalance: false).providerCost == nil)
    }

    @Test func `Amp personal dollars remain distinct from workspace dollars`() throws {
        let source = try AmpUsageParser.parse(displayText: """
        Individual credits: $12.34 remaining
        Workspace Team: $90.00 remaining
        """, now: self.now)
        let cost = try #require(source.toUsageSnapshot(now: self.now).providerCost)
        #expect(cost.balance == 12.34)
        #expect(cost.currencyCode == "USD")
        #expect(cost.balanceUpdatedAt == self.now)
        #expect(cost.balanceIsWorkspace != true)
        #expect(cost.usageIsUnavailable == true)
    }

    @Test func `Amp single workspace balance keeps its proven shared scope`() throws {
        let source = try AmpUsageParser.parse(displayText: "Workspace Team: $90.00 remaining", now: self.now)
        let cost = try #require(source.toUsageSnapshot(now: self.now).providerCost)
        #expect(cost.balance == 90)
        #expect(cost.currencyCode == "USD")
        #expect(cost.balanceIsWorkspace == true)
        #expect(cost.usageIsUnavailable == true)
    }

    @Test func `Amp does not combine independent workspace balances`() throws {
        let source = try AmpUsageParser.parse(displayText: """
        Workspace First: $90.00 remaining
        Workspace Second: $10.00 remaining
        """, now: self.now)
        #expect(source.toUsageSnapshot(now: self.now).providerCost == nil)
    }

    @Test func `Kilo explicitly denominated dollar blocks retain spend and balance`() throws {
        let source = try self.kiloSnapshot(#"{"creditBlocks":[{"amount_mUsd":20000000,"balance_mUsd":12500000}]}"#)
        let cost = try #require(source.toUsageSnapshot().providerCost)
        #expect(cost.used == 7.5)
        #expect(cost.limit == 20)
        #expect(cost.balance == 12.5)
        #expect(cost.currencyCode == "USD")
        #expect(cost.balanceUpdatedAt == source.updatedAt)
        #expect(cost.usageIsUnavailable != true)
    }

    @Test func `Kilo total dollar balance alone does not establish zero spending`() throws {
        for (rawBalance, balance) in [(0, 0.0), (12_500_000, 12.5)] {
            let source = try self.kiloSnapshot("{\"creditBlocks\":[],\"totalBalance_mUsd\":\(rawBalance)}")
            let cost = try #require(source.toUsageSnapshot().providerCost)
            #expect(cost.balance == balance)
            #expect(cost.currencyCode == "USD")
            #expect(cost.balanceUpdatedAt == source.updatedAt)
            #expect(cost.usageIsUnavailable == true)
        }
    }

    @Test func `Kilo generic credits retain their unit without becoming dollars`() throws {
        let source = try self.kiloSnapshot(
            #"{"usedCredits":7.5,"totalCredits":20,"remainingCredits":12.5}"#,
            pass: #"{"used":2,"total":5,"remaining":3}"#)
        let snapshot = source.toUsageSnapshot()
        let cost = try #require(snapshot.providerCost)
        #expect(cost.balance == 12.5)
        #expect(cost.currencyCode == "Credits")
        #expect(snapshot.secondary?.resetDescription == "2.00 / 5.00 Credits")
    }

    @Test func `Kilo measured monthly pass spending stays separate from wallet balance`() throws {
        let source = try self.kiloSnapshot(
            #"{"creditBlocks":[],"totalBalance_mUsd":12500000}"#,
            pass: """
            {"subscription":{"currentPeriodUsageUsd":3,"currentPeriodBaseCreditsUsd":20,
            "nextBillingAt":"2027-02-01T00:00:00Z"}}
            """)
        let cost = try #require(source.toUsageSnapshot().providerCost)
        #expect(cost.used == 3)
        #expect(cost.limit == 20)
        #expect(cost.balance == 12.5)
        #expect(cost.currencyCode == "USD")
        #expect(cost.period == "Monthly")
        #expect(cost.resetsAt == Date(timeIntervalSince1970: 1_801_440_000))
        #expect(cost.usageIsUnavailable != true)
    }

    @Test func `Kilo fallback micro dollar pass fields retain their explicit denomination`() throws {
        let source = try self.kiloSnapshot(
            #"{"creditBlocks":[],"totalBalance_mUsd":12500000}"#,
            pass: #"{"used_mUsd":3000000,"amount_mUsd":20000000}"#)
        let cost = try #require(source.toUsageSnapshot().providerCost)
        #expect(cost.currencyCode == "USD")
        #expect(cost.used == 3)
        #expect(cost.limit == 20)
        #expect(cost.balance == 12.5)
        #expect(cost.usageIsUnavailable != true)
    }

    @Test func `MiniMax points balance retains its measured unit without becoming cash`() throws {
        let source = MiniMaxUsageSnapshot(
            planName: nil,
            availablePrompts: nil,
            currentPrompts: nil,
            remainingPrompts: nil,
            windowMinutes: nil,
            usedPercent: nil,
            resetsAt: nil,
            updatedAt: self.now,
            pointsBalance: 99)
        let cost = try #require(source.toUsageSnapshot().providerCost)
        #expect(cost.balance == 99)
        #expect(cost.currencyCode == "Points")
        #expect(cost.balanceUpdatedAt == self.now)
        #expect(cost.usageIsUnavailable == true)
    }

    @Test func `Factory wallet retains balance and source time in both billing modes`() throws {
        let window = FactoryBillingWindow(usedPercent: 10, windowEnd: nil, secondsRemaining: 3600)
        let pool = FactoryLimitPool(fiveHour: window, weekly: window, monthly: window)
        let modes: [FactoryTokenRateLimits?] = [nil, .init(standard: pool, core: nil)]
        for limits in modes {
            let source = FactoryStatusSnapshot(
                standardUserTokens: 170,
                standardOrgTokens: 200,
                standardAllowance: 1000,
                premiumUserTokens: 0,
                premiumOrgTokens: 0,
                premiumAllowance: 0,
                periodStart: nil,
                periodEnd: nil,
                planName: nil,
                tier: nil,
                organizationName: nil,
                accountEmail: nil,
                userId: nil,
                rawJSON: nil,
                tokenRateLimits: limits,
                extraUsageBalanceCents: 1234,
                updatedAt: self.now)
            let usage = source.toUsageSnapshot()
            let cost = try #require(usage.providerCost)
            #expect(cost.balance == 12.34)
            #expect(cost.currencyCode == "USD")
            #expect(cost.balanceUpdatedAt == self.now)
            #expect(cost.usageIsUnavailable == true)
            #expect(usage.updatedAt == self.now)
            #expect(usage.costUsage == nil)
        }
    }

    @Test func `Factory legacy measured user tokens retain their actual billing period`() throws {
        let source = FactoryStatusSnapshot(
            standardUserTokens: 170,
            standardOrgTokens: 9999,
            standardAllowance: 1000,
            premiumUserTokens: 30,
            premiumOrgTokens: 9999,
            premiumAllowance: 100,
            periodStart: self.now.addingTimeInterval(-29 * 86400),
            periodEnd: self.now.addingTimeInterval(86400),
            planName: nil,
            tier: nil,
            organizationName: nil,
            accountEmail: nil,
            userId: nil,
            rawJSON: nil,
            updatedAt: self.now)
        let usage = try #require(source.toUsageSnapshot().costUsage)
        #expect(usage.last30DaysTokens == 200)
        #expect(usage.last30DaysCostUSD == nil)
        #expect(usage.sessionTokens == nil)
        #expect(usage.daily.isEmpty)
        #expect(usage.historyLabel != nil)
        #expect(usage.historyCoverageIsEstablished == false)
        #expect(usage.updatedAt == self.now)
    }

    private func kiloSnapshot(_ credits: String, pass: String = "{}") throws -> KiloUsageSnapshot {
        try KiloUsageFetcher._parseSnapshotForTesting(Data("""
        [{"result":{"data":\(credits)}},
         {"result":{"data":\(pass)}},
         {"result":{"data":{}}}]
        """.utf8))
    }
}
