import Foundation

/// Kimi's booster wallet uses fixed-point currency balances and separately reports monthly cents.
/// Contract: MoonshotAI/kimi-code packages/oauth/src/managed-usage.ts, parseBoosterWallet/parseMoney.
struct KimiBoosterWallet: Decodable, Sendable {
    let balance: Balance?
    let monthlyUsed: Money?
    let monthlyChargeLimit: Money?
    let monthlyChargeLimitEnabled: Bool?

    private enum CodingKeys: String, CodingKey {
        case balance, monthlyUsed, monthlyChargeLimit, monthlyChargeLimitEnabled
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.balance = try? values.decode(Balance.self, forKey: .balance)
        self.monthlyUsed = try? values.decode(Money.self, forKey: .monthlyUsed)
        self.monthlyChargeLimit = try? values.decode(Money.self, forKey: .monthlyChargeLimit)
        self.monthlyChargeLimitEnabled = try? values.decode(Bool.self, forKey: .monthlyChargeLimitEnabled)
    }

    func costSnapshot(at date: Date) -> ProviderCostSnapshot? {
        guard self.balance?.type == "BOOSTER" else { return nil }
        let used = self.monthlyUsed?.normalized
        let configuredLimit = self.monthlyChargeLimit?.normalized
        guard let currency = used?.currency ?? configuredLimit?.currency else { return nil }
        let balance = self.balance?.currencyBalance
        guard used != nil || balance != nil else { return nil }
        let limit = self.monthlyChargeLimitEnabled == true && configuredLimit?.currency == currency
            ? configuredLimit?.amount ?? 0 : 0
        return ProviderCostSnapshot(
            used: used?.amount ?? 0,
            limit: limit,
            currencyCode: currency,
            period: "Monthly",
            balance: balance,
            balanceUpdatedAt: date,
            usageIsUnavailable: used == nil ? true : nil,
            updatedAt: date)
    }

    struct Balance: Decodable, Sendable {
        let type: String?
        let unit: String?
        let amountLeft: Amount?

        private enum CodingKeys: String, CodingKey {
            case type, unit, amountLeft
        }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            self.type = try? values.decode(String.self, forKey: .type)
            self.unit = values.contains(.unit)
                ? (try? values.decode(String.self, forKey: .unit)) ?? "UNRECOGNIZED"
                : nil
            self.amountLeft = try? values.decode(Amount.self, forKey: .amountLeft)
        }

        var currencyBalance: Double? {
            guard self.unit == nil || self.unit == "UNIT_CURRENCY",
                  let raw = self.amountLeft?.value else { return nil }
            // One cent is 1,000,000 fixed-point units; one dollar is 100 cents.
            return raw / 100_000_000
        }
    }

    struct Money: Decodable, Sendable {
        let currency: String?
        let priceInCents: Amount?

        var normalized: (currency: String, amount: Double)? {
            guard let currency = self.currency?.uppercased(),
                  Locale.commonISOCurrencyCodes.contains(currency),
                  let cents = self.priceInCents?.value else { return nil }
            return (currency, cents / 100)
        }
    }

    struct Amount: Decodable, Sendable {
        let value: Double

        init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer()
            let number = (try? raw.decode(Double.self))
                ?? (try? raw.decode(String.self)).flatMap(Double.init)
            guard let number, number.isFinite, number >= 0 else {
                throw DecodingError.dataCorruptedError(in: raw, debugDescription: "Invalid Kimi currency amount")
            }
            self.value = number
        }
    }
}
