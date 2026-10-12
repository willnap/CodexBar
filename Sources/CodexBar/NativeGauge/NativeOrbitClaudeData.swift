import CodexBarCore
import Foundation

extension UsageStore {
    /// Cached Claude readings can enrich only a uniquely identified adapter owner.
    func nativeOrbitClaudeOwnedAmbientSnapshot(for account: ProviderAccountUsageSnapshot) -> UsageSnapshot? {
        // Provider-specific by design: ClaudeSwap adjuncts require its uniquely active email and organization owner.
        guard self.claudeSwapTransientState.switchingAccountID == nil,
              self.claudeSwapTransientState.switchPhase == nil else { return nil }
        return Self.nativeOrbitClaudeOwnedAmbientSnapshot(
            account: account, accounts: self.claudeSwapAccountSnapshots, snapshot: self.snapshots[.claude])
    }

    nonisolated static func nativeOrbitClaudeOwnedAmbientSnapshot(
        account: ProviderAccountUsageSnapshot,
        accounts: [ProviderAccountUsageSnapshot],
        snapshot: UsageSnapshot?) -> UsageSnapshot?
    {
        guard account.provider == .claude, account.id.source == ClaudeSwapAccountProjection.sourceName,
              NativeAccountActivationVerification.claudeOwnsLogin(account.id, accounts: accounts),
              let email = CodexIdentityResolver.normalizeEmail(account.accountEmail),
              accounts.count(where: {
                  $0.provider == .claude && CodexIdentityResolver.normalizeEmail($0.accountEmail) == email
              }) == 1,
              let snapshot, let identity = snapshot.identity(for: .claude),
              CodexIdentityResolver.normalizeEmail(identity.accountEmail) == email else { return nil }
        let organization = account.accountOrganizationName?.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let measuredOrganization = identity.accountOrganization?.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let ownerOrganization = organization.flatMap { $0.isEmpty ? nil : $0 }
        let observedOrganization = measuredOrganization.flatMap { $0.isEmpty ? nil : $0 }
        guard ownerOrganization == observedOrganization else { return nil }
        return snapshot
    }

    nonisolated static func nativeOrbitClaudeMergedSnapshot(
        adapter: UsageSnapshot?, ambient: UsageSnapshot?) -> UsageSnapshot?
    {
        guard let ambient else { return adapter }
        guard let adapter else { return ambient }
        let newest = ambient.updatedAt > adapter.updatedAt ? ambient : adapter
        let older = ambient.updatedAt > adapter.updatedAt ? adapter : ambient
        var extras = newest.extraRateWindows ?? []
        let ids = Set(extras.map(\.id))
        extras += (older.extraRateWindows ?? []).filter { !ids.contains($0.id) }
        return UsageSnapshot(
            primary: newest.primary ?? older.primary,
            secondary: newest.secondary ?? older.secondary,
            tertiary: newest.tertiary ?? older.tertiary,
            extraRateWindows: extras.isEmpty ? nil : extras,
            providerCost: Self.nativeOrbitClaudeMergedCost(adapter.providerCost, ambient.providerCost),
            costUsage: newest.costUsage ?? older.costUsage,
            details: newest.details,
            claudeResetCredits: ambient.claudeResetCredits ?? adapter.claudeResetCredits,
            subscriptionExpiresAt: ambient.subscriptionExpiresAt ?? adapter.subscriptionExpiresAt,
            subscriptionRenewsAt: ambient.subscriptionRenewsAt ?? adapter.subscriptionRenewsAt,
            updatedAt: newest.updatedAt,
            identity: newest.identity,
            dataConfidence: newest.dataConfidence)
    }

    /// Spend and prepaid balance are independent observations, even within one provider payload.
    nonisolated static func nativeOrbitClaudeMergedCost(
        _ adapter: ProviderCostSnapshot?,
        _ ambient: ProviderCostSnapshot?) -> ProviderCostSnapshot?
    {
        let costs = [adapter, ambient].compactMap(\.self)
        guard let spend = costs.max(by: { $0.updatedAt < $1.updatedAt }) else { return nil }
        guard let balance = costs.filter({ $0.balance != nil || $0.balanceUpdatedAt != nil }).max(by: {
            ($0.balanceUpdatedAt ?? $0.updatedAt) < ($1.balanceUpdatedAt ?? $1.updatedAt)
        }), balance.currencyCode == spend.currencyCode else { return spend }
        return ProviderCostSnapshot(
            used: spend.used,
            limit: spend.limit,
            currencyCode: spend.currencyCode,
            period: spend.period,
            resetsAt: spend.resetsAt,
            nextRegenAmount: spend.nextRegenAmount,
            personalUsed: spend.personalUsed,
            balance: balance.balance,
            balanceUpdatedAt: balance.balanceUpdatedAt ?? balance.updatedAt,
            balanceIsWorkspace: balance.balanceIsWorkspace,
            usageIsUnavailable: spend.usageIsUnavailable,
            isDisabled: spend.isDisabled,
            updatedAt: spend.updatedAt)
    }
}
