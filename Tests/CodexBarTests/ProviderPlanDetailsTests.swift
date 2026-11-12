import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct ProviderPlanDetailsTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func `a price is refused unless it is a real amount in a real currency code`() {
        #expect(ProviderPlanPrice(monthlyAmount: 200, currencyCode: "gbp")?.currencyCode == "GBP")
        #expect(ProviderPlanPrice(monthlyAmount: -1, currencyCode: "USD") == nil)
        #expect(ProviderPlanPrice(monthlyAmount: .infinity, currencyCode: "USD") == nil)
        #expect(ProviderPlanPrice(monthlyAmount: 20, currencyCode: "US") == nil)
        #expect(ProviderPlanPrice(monthlyAmount: 20, currencyCode: "U$D") == nil)
    }

    @Test func `former names never repeat the current name or each other`() {
        let plan = ProviderPlanDetails(
            name: " ChatGPT Pro ",
            formerNames: ["Pro 20x", "pro 20X", "chatgpt pro", " "],
            price: nil,
            updatedAt: self.now)
        #expect(plan.name == "ChatGPT Pro")
        #expect(plan.formerNames == ["Pro 20x"])
    }

    @Test func `the badge shows the price in the currency paid and the tooltip names the plan`() throws {
        let pounds = try #require(ProviderPlanPrice(
            monthlyAmount: 200, currencyCode: "GBP", billedEvery: .month, includesTax: true))
        #expect(NativeOrbitPlanBadge.text(price: pounds) == "£200")
        let yearly = try #require(ProviderPlanPrice(monthlyAmount: 16.67, currencyCode: "USD", billedEvery: .year))
        #expect(NativeOrbitPlanBadge.text(price: yearly) == "$16.67")
        let plan = ProviderPlanDetails(
            company: "OpenAI", name: "ChatGPT Pro", formerNames: ["Pro 20x"], price: pounds, updatedAt: self.now)
        #expect(NativeOrbitPlanBadge.help(plan, plan: "Pro 20x", service: "Codex")
            == "OpenAI ChatGPT Pro, £200 a month\nPreviously Pro 20x")
        let plus = ProviderPlanDetails(company: "OpenAI", name: "ChatGPT Plus", price: yearly, updatedAt: self.now)
        #expect(NativeOrbitPlanBadge.help(plus, plan: "Plus", service: "Codex")
            == "OpenAI ChatGPT Plus, $16.67 a month billed yearly")
        // No details: the plan's name as before.
        #expect(NativeOrbitPlanBadge.help(nil, plan: "Kimi Ultra", service: "Kimi") == "Kimi Ultra")
    }

    @Test func `a reported plan wins and a named plan falls back to its published price in a listed currency`() {
        func snapshot(currency: String?, plan: ProviderPlanDetails? = nil) -> UsageSnapshot {
            UsageSnapshot(
                primary: nil,
                secondary: nil,
                providerCost: currency.map {
                    ProviderCostSnapshot(used: 0, limit: 0, currencyCode: $0, isDisabled: true, updatedAt: self.now)
                },
                updatedAt: self.now).with(providerPlan: plan)
        }
        let max = snapshot(currency: "USD").planDetails(for: .claude, planName: "Claude Max 20x")
        #expect(max?.price?.monthlyAmount == 200)
        #expect(max?.price?.source == .listed)
        #expect(max?.name == "Claude Max")
        #expect(max?.formerNames == ["Max 20x"])
        // The provider's present name for the plan replaces the catalogue's.
        let ultra = snapshot(currency: "USD")
            .planDetails(for: .claude, planName: "Claude Max 20x", currentName: "Ultra")
        #expect(ultra?.name == "Claude Ultra")
        #expect(ultra.map { NativeOrbitPlanBadge.help($0, plan: "Claude Max 20x", service: "Claude") }
            == "Anthropic Claude Ultra, $200 a month at list price\nPreviously Max 20x")
        #expect(snapshot(currency: "USD").planDetails(for: .claude, planName: "Max 5x")?.price?.monthlyAmount == 100)
        #expect(snapshot(currency: "USD").planDetails(for: .claude, planName: "Claude Pro")?.price?.monthlyAmount == 20)
        // An unlisted currency, an unknown one, a plan the table does not name, or a provider with no entries: no
        // guessed price.
        #expect(snapshot(currency: "GBP").planDetails(for: .claude, planName: "Claude Max 20x") == nil)
        #expect(snapshot(currency: nil).planDetails(for: .claude, planName: "Claude Max 20x") == nil)
        #expect(snapshot(currency: "USD").planDetails(for: .claude, planName: "Claude Team") == nil)
        #expect(snapshot(currency: "USD").planDetails(for: .claude, planName: "Max") == nil)
        #expect(snapshot(currency: "USD").planDetails(for: .codex, planName: "Pro") == nil)
        #expect(snapshot(currency: "Credits").planDetails(for: .claude, planName: "Pro") == nil)
        let reported = ProviderPlanDetails(name: "Reported", price: nil, updatedAt: self.now)
        #expect(snapshot(currency: "USD", plan: reported).planDetails(for: .claude, planName: "Max 20x") == reported)
    }

    @Test func `every provider's published prices come from the one catalogue`() {
        func listed(_ provider: UsageProvider, _ plan: String, _ currency: String?) -> ProviderPlanDetails? {
            ProviderPlanCatalog.details(provider: provider, planName: plan, currencyCode: currency, updatedAt: self.now)
        }
        let kimi = listed(.kimi, "Ultra", "USD")
        #expect(kimi?.price?.monthlyAmount == 199)
        #expect(kimi?.company == "Moonshot AI")
        #expect(kimi?.name == "Kimi Ultra")
        #expect(kimi.map { NativeOrbitPlanBadge.text(price: $0.price!) } == "$199")
        #expect(listed(.kimi, "kimi pro", "usd")?.price?.monthlyAmount == 39)
        // The same word is a different plan at a different provider, and nothing at one with no entries.
        #expect(listed(.claude, "Pro", "USD")?.price?.monthlyAmount == 20)
        #expect(listed(.kimi, "Ultra", "CNY") == nil)
        #expect(listed(.kimi, "Allegretto", "USD") == nil)
        #expect(listed(.zai, "Pro", "USD") == nil)
    }

    @Test func `the plan survives a snapshot copy and its cache`() throws {
        let price = try #require(ProviderPlanPrice(monthlyAmount: 89, currencyCode: "GBP", billedEvery: .month))
        let plan = ProviderPlanDetails(company: "OpenAI", name: "ChatGPT Pro", price: price, updatedAt: self.now)
        let snapshot = UsageSnapshot(primary: nil, secondary: nil, updatedAt: self.now).with(providerPlan: plan)
        #expect(snapshot.with(tertiary: nil).providerPlan == plan)
        let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded.providerPlan == plan)
    }
}
