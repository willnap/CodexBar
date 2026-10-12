import Foundation

/// Typed API billing balance for the account's consumption currency. DIEM is a staking allowance, not money.
enum VeniceAPIBalance {
    static func mapPluginCard(
        _ card: any ProviderPluginValue,
        usage: UsageSnapshot,
        now: Date) throws -> UsageSnapshot
    {
        try ProviderPluginSnapshotMapper.object(card, allowed: ["balance", "unit"], path: "card")
        guard let unitValue = card.property("unit"), unitValue.isString,
              ["USD", "DIEM"].contains(unitValue.stringValue())
        else { throw ProviderPluginError.invalidSnapshot("card.unit must be USD or DIEM") }
        guard let value = card.property("balance"), value.isNumber,
              value.doubleValue().isFinite, value.doubleValue() >= 0
        else { throw ProviderPluginError.invalidSnapshot("card.balance must be a finite nonnegative number") }
        let unit = unitValue.stringValue()
        return usage.with(providerCost: ProviderCostSnapshot(
            used: 0,
            limit: 0,
            currencyCode: unit,
            period: unit == "DIEM" ? "DIEM balance" : "API balance",
            balance: value.doubleValue(),
            balanceUpdatedAt: now,
            usageIsUnavailable: true,
            updatedAt: now))
    }
}
