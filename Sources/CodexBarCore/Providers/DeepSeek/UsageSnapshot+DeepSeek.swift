extension UsageSnapshot {
    public func withoutDeepSeekDetailedUsage(
        state: DeepSeekDetailedUsageState = .unavailable) -> UsageSnapshot
    {
        let balanceOnly = self.providerCost.flatMap { cost -> ProviderCostSnapshot? in
            guard let balance = cost.balance else { return nil }
            return ProviderCostSnapshot(
                used: 0,
                limit: 0,
                currencyCode: cost.currencyCode,
                balance: balance,
                balanceUpdatedAt: cost.balanceUpdatedAt,
                usageIsUnavailable: true,
                updatedAt: cost.balanceUpdatedAt ?? cost.updatedAt)
        }
        return self.replacing(
            providerCost: .value(balanceOnly),
            costUsage: .value(nil),
            details: .value([]),
            deepseekDetailedUsageState: .value(state))
    }

    public func preservingDeepSeekPlatformProfiles(from previous: UsageSnapshot?) -> UsageSnapshot {
        guard self.deepseekDetailedUsageState == .unavailable,
              self.deepseekPlatformProfiles.isEmpty,
              let previous,
              !previous.deepseekPlatformProfiles.isEmpty
        else { return self }
        return self.replacing(
            deepseekPlatformProfiles: .value(previous.deepseekPlatformProfiles))
    }
}
