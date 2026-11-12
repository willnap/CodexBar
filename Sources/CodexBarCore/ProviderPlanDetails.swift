import Foundation

/// What a plan costs, as the account is charged for it.
public struct ProviderPlanPrice: Codable, Equatable, Hashable, Sendable {
    public enum Period: String, Codable, Sendable {
        case month
        case year
    }

    /// Where the amount came from.
    public enum Source: String, Codable, Sendable {
        /// The provider's own API reported it for this account.
        case reported
        /// The provider reports the plan and its currency but not its price: this is the published price.
        case listed
    }

    /// The price of one month, in major units of `currencyCode`.
    public let monthlyAmount: Double
    /// ISO 4217 code of the currency the account is billed in.
    public let currencyCode: String
    /// How often the account is billed; a yearly plan's `monthlyAmount` is a twelfth of what it pays at once.
    public let billedEvery: Period?
    /// Whether the amount already includes sales tax, when the provider says.
    public let includesTax: Bool?
    public let source: Source

    public init?(
        monthlyAmount: Double,
        currencyCode: String,
        billedEvery: Period? = nil,
        includesTax: Bool? = nil,
        source: Source = .reported)
    {
        let code = currencyCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard monthlyAmount.isFinite, monthlyAmount >= 0, monthlyAmount < 1_000_000,
              code.utf8.count == 3, code.utf8.allSatisfy({ $0 >= 65 && $0 <= 90 })
        else { return nil }
        self.monthlyAmount = monthlyAmount
        self.currencyCode = code
        self.billedEvery = billedEvery
        self.includesTax = includesTax
        self.source = source
    }
}

/// An account's plan in terms every provider shares: who sells it, what it is called now and was called before, and
/// what it costs. Providers rename plans and restate what they include; the price paid is the one figure that stays
/// comparable between plans and over time.
public struct ProviderPlanDetails: Codable, Equatable, Sendable {
    public static let maximumNameLength = 80
    public static let maximumFormerNames = 4

    /// The company that sells the plan ("OpenAI").
    public let company: String?
    /// The plan's current name, with its product ("ChatGPT Pro").
    public let name: String?
    /// Names the same plan has gone by ("Pro 20x").
    public let formerNames: [String]
    public let price: ProviderPlanPrice?
    public let updatedAt: Date

    public init(
        company: String? = nil,
        name: String? = nil,
        formerNames: [String] = [],
        price: ProviderPlanPrice?,
        updatedAt: Date)
    {
        func clean(_ text: String?) -> String? {
            guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return String(text.prefix(Self.maximumNameLength))
        }
        self.company = clean(company)
        self.name = clean(name)
        let current = self.name?.lowercased()
        var seen = Set<String>()
        self.formerNames = Array(formerNames.compactMap(clean).filter {
            $0.lowercased() != current && seen.insert($0.lowercased()).inserted
        }.prefix(Self.maximumFormerNames))
        self.price = price
        self.updatedAt = updatedAt
    }
}

extension UsageSnapshot {
    /// The account's plan: what its provider reported, or else the published price of the plan the provider named,
    /// in the currency the provider says the account is billed in. `currentName` is the provider's present name for
    /// the plan where it reports one apart from the tier.
    public func planDetails(
        for provider: UsageProvider,
        planName: String?,
        currentName: String? = nil) -> ProviderPlanDetails?
    {
        if let providerPlan { return providerPlan }
        return ProviderPlanCatalog.details(
            provider: provider,
            planName: planName ?? self.loginMethod(for: provider),
            // A spend allowance is denominated in the account's billing currency.
            currencyCode: self.providerCost.flatMap { $0.isMonetary ? $0.currencyCode : nil },
            currentName: currentName,
            updatedAt: self.updatedAt)
    }
}

/// Published monthly prices for plans whose provider names the plan and the billing currency but reports no price.
/// One table for every provider. An entry answers only for its own currency: an account billed in any other gets
/// no price rather than a converted guess, and a provider that reports its price never reaches this table.
public enum ProviderPlanCatalog {
    struct Entry {
        let provider: UsageProvider
        /// The plan as the provider names it, lowercased, without the product's own name.
        let tier: String
        let currencyCode: String
        let monthlyAmount: Double
        let company: String
        /// The product the plan belongs to ("Claude"), and the plan's name within it ("Max").
        let product: String
        let name: String
        var formerNames: [String] = []
    }

    static let entries: [Entry] = [
        // anthropic.com/pricing
        Entry(
            provider: .claude,
            tier: "pro",
            currencyCode: "USD",
            monthlyAmount: 20,
            company: "Anthropic",
            product: "Claude",
            name: "Pro"),
        Entry(
            provider: .claude,
            tier: "max 5x",
            currencyCode: "USD",
            monthlyAmount: 100,
            company: "Anthropic",
            product: "Claude",
            name: "Max",
            formerNames: ["Max 5x"]),
        Entry(
            provider: .claude,
            tier: "max 20x",
            currencyCode: "USD",
            monthlyAmount: 200,
            company: "Anthropic",
            product: "Claude",
            name: "Max",
            formerNames: ["Max 20x"]),
        // kimi.ai/help/membership/membership-pricing (plans renamed September 2026)
        Entry(
            provider: .kimi,
            tier: "plus",
            currencyCode: "USD",
            monthlyAmount: 19,
            company: "Moonshot AI",
            product: "Kimi",
            name: "Plus"),
        Entry(
            provider: .kimi,
            tier: "pro",
            currencyCode: "USD",
            monthlyAmount: 39,
            company: "Moonshot AI",
            product: "Kimi",
            name: "Pro"),
        Entry(
            provider: .kimi,
            tier: "max",
            currencyCode: "USD",
            monthlyAmount: 99,
            company: "Moonshot AI",
            product: "Kimi",
            name: "Max"),
        Entry(
            provider: .kimi,
            tier: "ultra",
            currencyCode: "USD",
            monthlyAmount: 199,
            company: "Moonshot AI",
            product: "Kimi",
            name: "Ultra"),
    ]

    public static func details(
        provider: UsageProvider,
        planName: String?,
        currencyCode: String?,
        currentName: String? = nil,
        updatedAt: Date) -> ProviderPlanDetails?
    {
        guard let planName, let code = currencyCode?.uppercased() else { return nil }
        let candidates = self.entries.filter { $0.provider == provider && $0.currencyCode == code }
        guard let product = candidates.first?.product.lowercased() else { return nil }
        // "Claude Max 20x" and "Max 20x" are the same plan; "Claude Team" or a bare "Max" is none of these.
        var tier = planName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if tier.hasPrefix(product + " ") { tier.removeFirst(product.count + 1) }
        guard let entry = candidates.first(where: { $0.tier == tier }),
              let price = ProviderPlanPrice(
                  monthlyAmount: entry.monthlyAmount, currencyCode: code, source: .listed)
        else { return nil }
        let current = currentName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = current.flatMap { $0.isEmpty ? nil : $0 } ?? entry.name
        return ProviderPlanDetails(
            company: entry.company,
            name: name.lowercased().hasPrefix(product) ? name : "\(entry.product) \(name)",
            formerNames: entry.formerNames,
            price: price,
            updatedAt: updatedAt)
    }
}
