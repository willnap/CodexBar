import Foundation
import Testing
@testable import CodexBarCore

struct CodexPlanPriceTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let pricing = Data("""
    {"country_code":"GB","currency_config":{"symbol_code":"GBP","symbol":"£","amount_per_credit":0.04,
     "plus":{"month":{"amount":20.0,"tax":"inclusive"},"year":{"amount":16.67,"tax":"inclusive"}},
     "pro":{"month":{"amount":200.0,"tax":"inclusive","psp_override":{"amount":166.67,"tax":"exclusive"}}},
     "prolite":{"month":{"amount":89.0,"tax":"inclusive"}},
     "business":{"month":{"amount":18.0,"tax":"exclusive"},"year":{"amount":15.0,"tax":"exclusive"}}}}
    """.utf8)

    private func subscription(
        _ plan: String?, period: String? = "monthly", country: String? = "GB", currency: String? = "GBP")
        -> CodexPlanPrice.Subscription
    {
        .init(planType: plan, billingPeriod: period, priceCountry: country, billingCurrency: currency)
    }

    @Test func `the price is the plan's amount in the table for the account's country`() {
        let pro = CodexPlanPrice.details(subscription: self.subscription("pro"), pricing: self.pricing, now: self.now)
        #expect(pro?.company == "OpenAI")
        #expect(pro?.name == "ChatGPT Pro")
        #expect(pro?.formerNames == ["Pro 20x"])
        #expect(pro?.price?.monthlyAmount == 200)
        #expect(pro?.price?.currencyCode == "GBP")
        #expect(pro?.price?.includesTax == true)
        #expect(pro?.price?.source == .reported)
        let lite = CodexPlanPrice.details(
            subscription: self.subscription("prolite"), pricing: self.pricing, now: self.now)
        #expect(lite?.price?.monthlyAmount == 89)
        #expect(lite?.formerNames == ["Pro 5x"])
        let yearly = CodexPlanPrice.details(
            subscription: self.subscription("plus", period: "yearly"), pricing: self.pricing, now: self.now)
        #expect(yearly?.price?.monthlyAmount == 16.67)
        #expect(yearly?.price?.billedEvery == .year)
        #expect(yearly?.formerNames == [])
        let team = CodexPlanPrice.details(subscription: self.subscription("team"), pricing: self.pricing, now: self.now)
        #expect(team?.price?.monthlyAmount == 18)
        #expect(team?.price?.includesTax == false)
    }

    @Test func `no price is made up for a free plan, an unlisted plan or another currency's table`() {
        func details(_ subscription: CodexPlanPrice.Subscription) -> ProviderPlanDetails? {
            CodexPlanPrice.details(subscription: subscription, pricing: self.pricing, now: self.now)
        }
        #expect(details(self.subscription("free")) == nil)
        #expect(details(self.subscription(nil)) == nil)
        #expect(details(self.subscription("enterprise")) == nil)
        #expect(details(self.subscription("pro", currency: "USD")) == nil)
        #expect(details(self.subscription("business", period: "weekly"))?.price?.billedEvery == .month)
        #expect(self.subscription("pro", country: "gb").country == "GB")
        // No pricing country: the billing currency's own country, and none for a currency many countries share.
        #expect(self.subscription("prolite", country: nil, currency: "USD").country == "US")
        #expect(self.subscription("pro", country: "../x", currency: "jpy").country == "JP")
        #expect(self.subscription("pro", country: nil, currency: "EUR").country == nil)
        #expect(self.subscription("pro", country: nil, currency: nil).country == nil)
        #expect(self.subscription("pro", country: "../x", currency: "U$D").country == nil)
        #expect(CodexPlanPrice.details(
            subscription: self.subscription("pro"), pricing: Data("[]".utf8), now: self.now) == nil)
    }

    @Test func `a price is read rarely and a failed read keeps the price already known`() async {
        let cache = CodexPlanPriceCache()
        let reads = Counter()
        let pricing = self.pricing
        let subscription = self.subscription("pro")
        func details(at offset: TimeInterval, failing: Bool = false) async -> ProviderPlanDetails? {
            await cache.details(
                accountID: "a",
                now: self.now.addingTimeInterval(offset),
                subscription: {
                    await reads.add()
                    if failing { throw CancellationError() }
                    return subscription
                },
                pricing: { _ in pricing })
        }
        #expect(await details(at: 0)?.price?.monthlyAmount == 200)
        #expect(await details(at: 60)?.price?.monthlyAmount == 200)
        #expect(await reads.value == 1)
        // Past its lifetime it is read again; a failure then keeps what was known and retries sooner.
        let later = CodexPlanPriceCache.priceLifetime + 1
        #expect(await details(at: later, failing: true)?.price?.monthlyAmount == 200)
        #expect(await reads.value == 2)
        #expect(await details(at: later + 60, failing: true)?.price?.monthlyAmount == 200)
        #expect(await reads.value == 2)
        #expect(await details(at: later + CodexPlanPriceCache.retryInterval + 1)?.price?.monthlyAmount == 200)
        #expect(await reads.value == 3)
    }

    @Test func `readings of one account that overlap share a single read`() async {
        let cache = CodexPlanPriceCache()
        let reads = Counter()
        let pricing = self.pricing
        let subscription = self.subscription("prolite", country: nil, currency: "GBP")
        async let first = cache.details(
            accountID: "a",
            now: self.now,
            subscription: {
                await reads.add()
                try await Task.sleep(for: .milliseconds(80))
                return subscription
            },
            pricing: { _ in pricing })
        async let second = cache.details(
            accountID: "a",
            now: self.now,
            subscription: {
                await reads.add()
                try await Task.sleep(for: .milliseconds(80))
                return subscription
            },
            pricing: { _ in pricing })
        let prices = await [first?.price?.monthlyAmount, second?.price?.monthlyAmount]
        #expect(prices == [89, 89])
        #expect(await reads.value == 1)
    }

    private actor Counter {
        var value = 0
        func add() { self.value += 1 }
    }
}
