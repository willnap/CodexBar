import Foundation
import Testing
@testable import CodexBarCore

struct NativeProviderMetricSourceTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func `Groq snapshot carries the original daily tokens costs and requests`() throws {
        let source = GroqConsoleUsageSnapshot(
            daily: [.init(
                day: "2027-01-15",
                startTime: self.now,
                endTime: self.now.addingTimeInterval(86400),
                costUSD: 2.5,
                requests: 7,
                inputTokens: 100,
                cachedInputTokens: 20,
                outputTokens: 40,
                totalTokens: 160,
                models: [])],
            updatedAt: self.now)
        let usage = try #require(source.toUsageSnapshot().costUsage)
        #expect(usage.daily.first?.inputTokens == 100)
        #expect(usage.daily.first?.cacheReadTokens == 20)
        #expect(usage.daily.first?.outputTokens == 40)
        #expect(usage.daily.first?.totalTokens == 160)
        #expect(usage.daily.first?.requestCount == 7)
        #expect(usage.daily.first?.costUSD == 2.5)
        #expect(usage.costProvenance == .vendorMetered)
        #expect(usage.currencyCode == "USD")
        #expect(usage.updatedAt == self.now)
    }

    @Test func `Claude admin snapshot carries vendor measured daily tokens and dollars`() throws {
        let source = ClaudeAdminAPIUsageSnapshot(
            daily: [.init(
                day: "2027-01-15",
                startTime: self.now,
                endTime: self.now.addingTimeInterval(86400),
                costUSD: 2.5,
                inputTokens: 100,
                cacheCreationInputTokens: 10,
                cacheReadInputTokens: 20,
                outputTokens: 40,
                totalTokens: 170,
                costItems: [],
                models: [])],
            updatedAt: self.now)
        let usage = try #require(source.toUsageSnapshot().costUsage)
        #expect(usage.daily.first?.totalTokens == 170)
        #expect(usage.daily.first?.costUSD == 2.5)
        #expect(usage.costProvenance == .vendorMetered)
        #expect(usage.daily.first?.inputTokens == 100)
        #expect(usage.daily.first?.cacheCreationTokens == 10)
        #expect(usage.daily.first?.cacheReadTokens == 20)
        #expect(usage.daily.first?.outputTokens == 40)
        #expect(usage.daily.first?.requestCount == nil)
        #expect(usage.updatedAt == self.now)
    }

    @Test func `DeepSeek typed daily report and independently measured balance survive projection`() throws {
        let report = DeepSeekUsageSummary(
            todayTokens: 170,
            currentMonthTokens: 170,
            todayCost: 2.5,
            currentMonthCost: 2.5,
            requestCount: 7,
            currentMonthRequestCount: 7,
            topModel: nil,
            categoryBreakdown: [],
            daily: [.init(
                date: "2027-01-15",
                totalTokens: 170,
                cost: 2.5,
                requestCount: 7)],
            currency: "CNY",
            updatedAt: self.now)
        let source = DeepSeekUsageSnapshot(
            isAvailable: true,
            currency: "CNY",
            totalBalance: 15,
            grantedBalance: 5,
            toppedUpBalance: 10,
            usageSummary: report,
            updatedAt: self.now.addingTimeInterval(1))
        let snapshot = source.toUsageSnapshot()
        let usage = try #require(snapshot.costUsage)
        #expect(usage.daily.first?.totalTokens == 170)
        #expect(usage.daily.first?.costUSD == 2.5)
        #expect(usage.currencyCode == "CNY")
        #expect(usage.updatedAt == self.now)
        #expect(usage.daily.first?.requestCount == 7)
        #expect(usage.historyCoverageIsEstablished == false)
        #expect(usage.reportingPeriod == .monthToDate)
        #expect(snapshot.providerCost?.balance == 15)
        #expect(snapshot.providerCost?.balanceUpdatedAt == source.updatedAt)
        let removed = snapshot.withoutDeepSeekDetailedUsage()
        #expect(removed.costUsage == nil)
        #expect(removed.providerCost?.balance == 15)
        #expect(removed.providerCost?.usageIsUnavailable == true)
        let balanceOnly = DeepSeekUsageSnapshot(
            isAvailable: true,
            currency: "CNY",
            totalBalance: 15,
            grantedBalance: 5,
            toppedUpBalance: 10,
            updatedAt: self.now).toUsageSnapshot()
        #expect(balanceOnly.providerCost?.usageIsUnavailable == true)
        #expect(balanceOnly.costUsage == nil)
    }

    @Test func `DeepSeek report without measured money retains tokens and independent balance`() throws {
        let report = DeepSeekUsageSummary(
            todayTokens: 170,
            currentMonthTokens: 170,
            todayCost: nil,
            currentMonthCost: nil,
            requestCount: 7,
            currentMonthRequestCount: 7,
            topModel: nil,
            categoryBreakdown: [],
            daily: [.init(
                date: "2027-01-15",
                totalTokens: 170,
                cost: nil,
                requestCount: 7)],
            currency: "CNY",
            updatedAt: self.now)
        let snapshot = DeepSeekUsageSnapshot(
            isAvailable: true,
            currency: "CNY",
            totalBalance: 15,
            grantedBalance: 5,
            toppedUpBalance: 10,
            usageSummary: report,
            updatedAt: self.now.addingTimeInterval(1)).toUsageSnapshot()
        let usage = try #require(snapshot.costUsage)
        #expect(usage.daily.first?.totalTokens == 170)
        #expect(usage.daily.first?.costUSD == nil)
        #expect(usage.sessionCostUSD == nil)
        #expect(usage.last30DaysCostUSD == nil)
        #expect(snapshot.providerCost?.balance == 15)
        #expect(snapshot.providerCost?.usageIsUnavailable == true)
    }

    @Test func `MiniMax billing preserves daily tokens and raw cash without inventing currency or requests`() throws {
        let billing = MiniMaxBillingSummary(
            todayTokens: 160,
            last30DaysTokens: 260,
            todayCash: 2.5,
            last30DaysCash: 3.5,
            daily: [
                .init(
                    day: "2027-01-14",
                    tokens: 100,
                    cash: 1),
                .init(
                    day: "2027-01-15",
                    tokens: 160,
                    cash: 2.5),
            ],
            topMethods: [],
            topModels: [],
            updatedAt: self.now)
        let source = MiniMaxUsageSnapshot(
            planName: nil,
            availablePrompts: nil,
            currentPrompts: nil,
            remainingPrompts: nil,
            windowMinutes: nil,
            usedPercent: nil,
            resetsAt: nil,
            updatedAt: self.now.addingTimeInterval(1),
            billingSummary: billing,
            pointsBalance: 99)
        let usage = try #require(source.toUsageSnapshot().costUsage)
        #expect(usage.sessionTokens == 160)
        #expect(usage.last30DaysTokens == 260)
        #expect(usage.daily.last?.totalTokens == 160)
        #expect(usage.daily.last?.costUSD == 2.5)
        #expect(usage.last30DaysCostUSD == 3.5)
        #expect(usage.currencyCode == "XXX")
        #expect(usage.daily.last?.requestCount == nil)
        #expect(usage.updatedAt == self.now)
        #expect(usage.costProvenance == .vendorMetered)
    }

    @Test func `DeepSeek rolling report and balance keep their separate currencies`() throws {
        let report = DeepSeekUsageSummary(
            todayTokens: 170,
            currentMonthTokens: 170,
            todayCost: 2.5,
            currentMonthCost: 2.5,
            requestCount: 7,
            currentMonthRequestCount: 7,
            topModel: nil,
            categoryBreakdown: [],
            daily: [.init(
                date: "2027-01-15",
                totalTokens: 170,
                cost: 2.5,
                requestCount: 7)],
            currency: "CNY",
            period: .last30Days,
            updatedAt: self.now)
        let snapshot = DeepSeekUsageSnapshot(
            isAvailable: true,
            currency: "USD",
            totalBalance: 15,
            grantedBalance: 5,
            toppedUpBalance: 10,
            usageSummary: report,
            updatedAt: self.now.addingTimeInterval(1)).toUsageSnapshot()
        let usage = try #require(snapshot.costUsage)
        #expect(usage.currencyCode == "CNY")
        #expect(usage.last30DaysCostUSD == 2.5)
        #expect(usage.historyCoverageIsEstablished == true)
        #expect(usage.historyDays == 30)
        #expect(snapshot.providerCost?.currencyCode == "USD")
        #expect(snapshot.providerCost?.balance == 15)
        #expect(snapshot.providerCost?.usageIsUnavailable == true)
    }

    @Test func `MiniMax service billing without cash leaves money unavailable`() throws {
        let billing = MiniMaxBillingSummary(
            todayTokens: 160,
            last30DaysTokens: 160,
            todayCash: nil,
            last30DaysCash: nil,
            daily: [.init(
                day: "2027-01-15",
                tokens: 160,
                cash: nil)],
            topMethods: [],
            topModels: [],
            updatedAt: self.now)
        let source = MiniMaxUsageSnapshot(
            planName: nil,
            availablePrompts: nil,
            currentPrompts: nil,
            remainingPrompts: nil,
            windowMinutes: nil,
            usedPercent: nil,
            resetsAt: nil,
            updatedAt: self.now,
            services: [.init(
                serviceType: "text-generation",
                windowType: "Today",
                timeRange: "",
                usage: 1,
                limit: 10,
                percent: 10,
                resetsAt: nil,
                resetDescription: "")],
            billingSummary: billing)
        let usage = try #require(source.toUsageSnapshot().costUsage)
        #expect(usage.daily.first?.totalTokens == 160)
        #expect(usage.daily.first?.costUSD == nil)
        #expect(usage.sessionCostUSD == nil)
        #expect(usage.last30DaysCostUSD == nil)
        #expect(source.toUsageSnapshot().providerCost == nil)
    }

    @Test func `Wayfinder retains exact thirty day counts and explicitly estimated priced cost`() throws {
        let source = self.wayfinder(priced: true)
        let usage = try #require(source.toUsageSnapshot().costUsage)
        #expect(usage.last30DaysTokens == 170)
        #expect(usage.last30DaysRequests == 7)
        #expect(usage.last30DaysCostUSD == 2.5)
        #expect(usage.costProvenance == .listPriceEstimate)
        #expect(usage.currencyCode == "USD")
        #expect(usage.historyDays == 30)
        #expect(usage.historyLabel == "Last 30 days")
        #expect(usage.daily.isEmpty)
        #expect(usage.sessionTokens == nil)
        #expect(usage.sessionRequests == nil)
        #expect(usage.sessionCostUSD == nil)
        #expect(usage.updatedAt == self.now)
    }

    @Test func `Wayfinder unpriced relative savings do not become money`() throws {
        let usage = try #require(self.wayfinder(priced: false).toUsageSnapshot().costUsage)
        #expect(usage.last30DaysTokens == 170)
        #expect(usage.last30DaysRequests == 7)
        #expect(usage.last30DaysCostUSD == nil)
        #expect(usage.currencyCode == "XXX")
        #expect(usage.costProvenance == .unknown)
    }

    private func wayfinder(priced: Bool) -> WayfinderUsageSnapshot {
        WayfinderUsageSnapshot(
            gatewayStatus: "ok",
            offline: false,
            dryRun: false,
            missingKeys: [],
            modelCount: 1,
            requests: 7,
            tokens: 170,
            realized: 2.5,
            baseline: 5,
            saved: 2.5,
            savedPct: 50,
            priced: priced,
            routes: [],
            avgDecisionMs: nil,
            updatedAt: self.now)
    }

    @Test func `Bedrock cloud watch fourteen day counts remain separate from monthly money`() throws {
        let source = BedrockUsageSnapshot(
            monthlySpend: 12.34,
            monthlyBudget: nil,
            inputTokens: 100,
            outputTokens: 200,
            requestCount: 7,
            region: "fixture-region",
            updatedAt: self.now)
        let usage = source.toUsageSnapshot()
        let report = try #require(usage.costUsage)
        #expect(report.last30DaysTokens == 300)
        #expect(report.last30DaysRequests == 7)
        #expect(report.last30DaysCostUSD == nil)
        #expect(report.daily.isEmpty)
        #expect(report.historyDays == 14)
        #expect(report.historyCoverageIsEstablished == false)
        #expect(report.historyLabel == "CloudWatch last 14 days")
        #expect(report.updatedAt == self.now)
        #expect(usage.providerCost?.used == 12.34)
        #expect(usage.providerCost?.period == "Monthly")
        let unavailable = BedrockUsageSnapshot(
            monthlySpend: 12.34, monthlyBudget: nil, region: "fixture-region", updatedAt: self.now)
        #expect(unavailable.toUsageSnapshot().costUsage == nil)
    }

    @Test func `Bedrock monthly reset remains anchored to its source observation`() {
        let source = BedrockUsageSnapshot(
            monthlySpend: 12.34, monthlyBudget: 20, region: "fixture-region", updatedAt: self.now)
        let snapshot = source.toUsageSnapshot()
        let sourceReset = ISO8601DateFormatter().date(from: "2027-02-01T00:00:00Z")
        #expect(snapshot.providerCost?.resetsAt == sourceReset)
        #expect(snapshot.primary?.resetsAt == sourceReset)
    }
}
