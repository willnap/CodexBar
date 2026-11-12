import Foundation

/// What a ChatGPT subscription costs, as OpenAI reports it. The account's subscription names its plan, its billing
/// period and the country its price is set for; the pricing table for that country lists the plan's amount.
enum CodexPlanPrice {
    struct Subscription: Decodable {
        let planType: String?
        let billingPeriod: String?
        let priceCountry: String?
        let billingCurrency: String?

        enum CodingKeys: String, CodingKey {
            case planType = "plan_type"
            case billingPeriod = "billing_period"
            case priceCountry = "price_country"
            case billingCurrency = "billing_currency"
        }

        /// The country whose pricing table to read: two capital letters, safe to put in a path. A subscription
        /// that names none is priced in its billing currency's own country: the first two letters of an ISO 4217
        /// code are that country's ISO 3166 code (USD → US, JPY → JP). A shared currency names no country (EUR →
        /// "EU"), and its table is then refused or absent, so no price is shown rather than one country's guessed.
        var country: String? {
            func code(_ text: String?, length: Int) -> String? {
                guard let text = text?.uppercased(), text.utf8.count == length,
                      text.utf8.allSatisfy({ $0 >= 65 && $0 <= 90 }) else { return nil }
                return String(text.prefix(2))
            }
            guard let country = code(self.priceCountry, length: 2) ?? code(self.billingCurrency, length: 3),
                  country != "EU" else { return nil }
            return country
        }
    }

    /// Keys the pricing table uses where they differ from the subscription's plan type.
    private static let pricingKeys = ["team": "business", "pro_lite": "prolite", "pro-lite": "prolite"]
    /// Every paid ChatGPT tier that carries "Pro" in its name is sold as ChatGPT Pro; the price tells them apart.
    private static let names = [
        "go": "ChatGPT Go", "plus": "ChatGPT Plus", "pro": "ChatGPT Pro", "prolite": "ChatGPT Pro",
        "promax": "ChatGPT Pro", "business": "ChatGPT Business", "team": "ChatGPT Business",
    ]

    static func details(subscription: Subscription, pricing: Data, now: Date) -> ProviderPlanDetails? {
        guard let plan = subscription.planType?.lowercased(), !plan.isEmpty, plan != "free",
              let root = try? JSONSerialization.jsonObject(with: pricing) as? [String: Any],
              let table = root["currency_config"] as? [String: Any],
              let currency = table["symbol_code"] as? String
        else { return nil }
        // The table must be in the currency the account is billed in, or it is some other country's.
        if let billed = subscription.billingCurrency, billed.uppercased() != currency.uppercased() { return nil }
        let key = Self.pricingKeys[plan] ?? plan
        let yearly = ["yearly", "annual", "year"].contains(subscription.billingPeriod?.lowercased() ?? "")
        guard let periods = table[key] as? [String: Any],
              let listed = periods[yearly ? "year" : "month"] as? [String: Any],
              let amount = (listed["amount"] as? NSNumber)?.doubleValue, amount > 0,
              let price = ProviderPlanPrice(
                  monthlyAmount: amount,
                  currencyCode: currency,
                  billedEvery: yearly ? .year : .month,
                  includesTax: (listed["tax"] as? String).flatMap { ["inclusive": true, "exclusive": false][$0] })
        else { return nil }
        let former = CodexPlanFormatting.displayName(plan)
        return ProviderPlanDetails(
            company: "OpenAI",
            name: Self.names[key],
            // The multiplier names ("Pro 20x") are what these plans were sold as.
            formerNames: former.map { $0.contains(where: \.isNumber) ? [$0] : [] } ?? [],
            price: price,
            updatedAt: now)
    }
}

/// A price changes rarely and costs two requests, so each account's is read a few times a day and each country's
/// table once a day. Readings of one account that overlap share a single read. A failure is retried soon, says why
/// in the log, and never replaces a price already known.
actor CodexPlanPriceCache {
    static let shared = CodexPlanPriceCache()
    static let priceLifetime: TimeInterval = 6 * 3600
    static let tableLifetime: TimeInterval = 24 * 3600
    static let retryInterval: TimeInterval = 3 * 60
    private static let log = CodexBarLog.logger(LogCategories.codexPlanPrice)

    private var plans: [String: (details: ProviderPlanDetails?, checkedAt: Date, succeeded: Bool)] = [:]
    private var tables: [String: (data: Data, fetchedAt: Date)] = [:]
    private var reads: [String: Task<ProviderPlanDetails?, Never>] = [:]

    func details(
        accountID: String,
        now: Date = Date(),
        subscription: @escaping @Sendable () async throws -> CodexPlanPrice.Subscription,
        pricing: @escaping @Sendable (String) async throws -> Data) async -> ProviderPlanDetails?
    {
        if let known = self.plans[accountID],
           now.timeIntervalSince(known.checkedAt) < (known.succeeded ? Self.priceLifetime : Self.retryInterval)
        {
            return known.details
        }
        if let read = self.reads[accountID] { return await read.value }
        let read = Task { await self.read(accountID: accountID, now: now, subscription: subscription, pricing: pricing)
        }
        self.reads[accountID] = read
        let details = await read.value
        self.reads[accountID] = nil
        return details
    }

    private func read(
        accountID: String,
        now: Date,
        subscription: @Sendable () async throws -> CodexPlanPrice.Subscription,
        pricing: @Sendable (String) async throws -> Data) async -> ProviderPlanDetails?
    {
        let previous = self.plans[accountID]?.details
        func failed(_ reason: String) -> ProviderPlanDetails? {
            Self.log.warning("Codex plan price unavailable: \(reason)")
            self.plans[accountID] = (previous, now, false)
            return previous
        }
        let read: CodexPlanPrice.Subscription
        do {
            read = try await subscription()
        } catch {
            return failed("subscription read failed (\(Self.describe(error)))")
        }
        guard let country = read.country else {
            return failed("subscription names no pricing country or single-country currency")
        }
        var table = self.tables[country]
        if table.map({ now.timeIntervalSince($0.fetchedAt) >= Self.tableLifetime }) ?? true {
            do {
                table = try await (pricing(country), now)
                self.tables[country] = table
            } catch {
                // An older table still prices the plan; without one there is nothing to price it with.
                if table == nil {
                    return failed("pricing table for \(country) failed (\(Self.describe(error)))")
                }
            }
        }
        guard let table, let details = CodexPlanPrice.details(subscription: read, pricing: table.data, now: now)
        else {
            return failed("no listed price for plan \(read.planType ?? "nil") in \(country)")
        }
        self.plans[accountID] = (details, now, true)
        return details
    }

    /// The kind of failure only: a response body or URL can carry an account identifier.
    private static func describe(_ error: any Error) -> String {
        switch error {
        case CodexOAuthFetchError.unauthorized: "unauthorized"
        case let CodexOAuthFetchError.serverError(status, _): "HTTP \(status)"
        case CodexOAuthFetchError.networkError: "network"
        case CodexOAuthFetchError.invalidResponse: "invalid response"
        case is CancellationError: "cancelled"
        case is DecodingError: "unexpected shape"
        default: String(describing: type(of: error))
        }
    }
}
