import Foundation

/// The usage API's typed money is independent of extra-usage enablement and quota percentages.
struct ClaudeMonthlySpend: Decodable {
    private struct Money: Decodable {
        let amountMinor: Double
        let exponent: Int
        let currency: String

        private enum CodingKeys: String, CodingKey {
            case amountMinor = "amount_minor"
            case exponent, currency
        }

        var amount: Double? {
            guard self.amountMinor.isFinite, self.amountMinor >= 0, (0...9).contains(self.exponent),
                  Locale.commonISOCurrencyCodes.contains(self.currency.uppercased()) else { return nil }
            return self.amountMinor / pow(10, Double(self.exponent))
        }
    }

    private let enabled: Bool
    private let used: Money
    private let limit: Money?

    private enum CodingKeys: String, CodingKey { case enabled, used, limit }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try container.decode(Bool.self, forKey: .enabled)
        self.used = try container.decode(Money.self, forKey: .used)
        // A disabled spending cap is not part of the measured money; its schema may be unavailable.
        self.limit = try? container.decodeIfPresent(Money.self, forKey: .limit)
    }

    func cost(updatedAt: Date) -> ProviderCostSnapshot? {
        guard let used = self.used.amount else { return nil }
        var limit = 0.0
        if self.enabled {
            guard let money = self.limit, let amount = money.amount, amount > 0,
                  money.currency.uppercased() == self.used.currency.uppercased() else { return nil }
            limit = amount
        }
        return ProviderCostSnapshot(
            used: used,
            limit: limit,
            currencyCode: self.used.currency.uppercased(),
            period: "Monthly",
            updatedAt: updatedAt)
    }

    static func parse(_ raw: Any?, updatedAt: Date) -> ProviderCostSnapshot? {
        guard let raw, JSONSerialization.isValidJSONObject(raw),
              let data = try? JSONSerialization.data(withJSONObject: raw),
              let spend = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        return spend.cost(updatedAt: updatedAt)
    }
}
