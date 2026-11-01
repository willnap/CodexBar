import CodexBarCore
import Foundation

extension UsageStore {
    /// Cached Claude readings can enrich only a uniquely identified adapter owner.
    func nativeOrbitClaudeOwnedAmbientSnapshot(for account: ProviderAccountUsageSnapshot) -> UsageSnapshot? {
        // Provider-specific by design: ClaudeSwap adjuncts require its uniquely active email and organization owner.
        // That match holds through a switch too: until the list names the new row, a reading of the new login
        // carries the other email and matches no column.
        Self.nativeOrbitClaudeOwnedAmbientSnapshot(
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
        guard Self.nativeOrbitClaudeOwnerOrganization(account.accountOrganizationName, email: email)
            == Self.nativeOrbitClaudeOwnerOrganization(identity.accountOrganization, email: email)
        else { return nil }
        return snapshot
    }

    /// The organization that tells two owners of one email apart, or nil for the email's own personal organization.
    /// Claude names that one after the email ("name@example.com's Organization") and the CLI scrape drops such a
    /// name (`ClaudeStatusProbe`), so a named personal organization and none are the same owner, while any other
    /// organization must match exactly.
    nonisolated static func nativeOrbitClaudeOwnerOrganization(_ name: String?, email: String) -> String? {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !name.isEmpty,
              !name.hasPrefix(email.lowercased()) else { return nil }
        return name
    }

    /// Keeps the richest verified reading under this exact slot owner when the ambient login moves away.
    func nativeOrbitClaudePresentationSnapshot(
        for account: ProviderAccountUsageSnapshot,
        ambient: UsageSnapshot?) -> UsageSnapshot?
    {
        let current = Self.nativeOrbitClaudeMergedSnapshot(adapter: account.snapshot, ambient: ambient)
        guard let historyKey = Self.nativeOrbitClaudeHistoryKey(account),
              account.credentialIssue != .wrongAccount,
              self.claudeSwapAccountSnapshots.count(where: { $0.id == account.id }) == 1 else { return current }
        let owner = NativeOrbitLastKnownUsageStore.ownerDigest([
            historyKey, account.sourceOrganizationID ?? "", self.settings.claudeSwapExecutablePath,
        ])
        // Provider-specific by design: ClaudeSwap’s verified owner bucket retains only Claude adjunct readings.
        let retained = self.nativeLastKnownUsage.accountSnapshot(.claude, owner: owner)
        // The newest accepted reading owns adjuncts. An older adapter payload after switching cannot replace a
        // newer ambient observation; at equal measurement times the current receipt wins.
        let snapshot: UsageSnapshot? = if let current, let retained, retained.updatedAt > current.updatedAt {
            Self.nativeOrbitClaudeMergedSnapshot(adapter: current, ambient: retained)
        } else {
            Self.nativeOrbitClaudeMergedSnapshot(adapter: retained, ambient: current)
        }
        if let snapshot {
            // Provider-specific by design: Publish the merged Claude receipt back to that same verified owner.
            self.nativeLastKnownUsage.recordAccountSnapshot(.claude, owner: owner, snapshot: snapshot)
        }
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
        // The newest receipt owns the base quota inventory, including removed limits. Only adjunct readings
        // are enriched from older payloads; otherwise a disappeared five-hour cap would survive indefinitely.
        return UsageSnapshot(
            primary: newest.primary,
            secondary: newest.secondary,
            tertiary: newest.tertiary ?? older.tertiary,
            extraRateWindows: extras.isEmpty ? nil : extras,
            providerCost: Self.nativeOrbitClaudeMergedCost(adapter.providerCost, ambient.providerCost),
            costUsage: newest.costUsage ?? older.costUsage,
            details: newest.details,
            claudeResetCredits: ambient.claudeResetCredits ?? adapter.claudeResetCredits,
            claudeCloudCredits: ambient.claudeCloudCredits ?? adapter.claudeCloudCredits,
            claudeResetCreditsIneligibleReason: ambient.claudeResetCreditsIneligibleReason
                ?? adapter.claudeResetCreditsIneligibleReason,
            subscriptionStatus: ambient.subscriptionStatus ?? adapter.subscriptionStatus,
            subscriptionIsActive: ambient.subscriptionIsActive ?? adapter.subscriptionIsActive,
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
