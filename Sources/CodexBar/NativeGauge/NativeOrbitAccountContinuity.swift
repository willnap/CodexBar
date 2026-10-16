import CodexBarCore
import Foundation

/// The last verified inventory and coherent readings during one explicit login switch, never a general fallback.
struct NativeCodexAccountSwitchPresentation {
    let token = UUID()
    let projection: CodexVisibleAccountProjection
    let snapshots: [CodexAccountUsageSnapshot]
    var localUsages: [String: NativeOrbitResolvedLocalUsage] = [:]
    /// Populated only after the importer verifies the old profile and newly managed credential are the same owner.
    var importedAccounts: [String: CodexVisibleAccount] = [:]
}

extension UsageStore {
    var nativeCodexAccountSwitchPresentation: NativeCodexAccountSwitchPresentation? {
        get { self.nativeLastKnownUsage.codexSwitchPresentation }
        set { self.nativeLastKnownUsage.codexSwitchPresentation = newValue }
    }

    func finishNativeCodexAccountSwitchPresentation(token: UUID) {
        guard self.nativeCodexAccountSwitchPresentation?.token == token else { return }
        // Explicit activation may invalidate inventory. Resolve it once and migrate verified aliases even when
        // no popup frame rendered during a fast switch; rendering itself never reads authentication files.
        self.prepareNativeAccountInventory(for: .codex)
        if let projection = self.nativeCodexAccountProjection {
            _ = self.nativeCodexSwitchLocalUsages(for: projection)
        }
        self.nativeCodexAccountSwitchPresentation = nil
    }

    func nativeCodexSwitchLocalUsages(
        for projection: CodexVisibleAccountProjection) -> [String: NativeOrbitResolvedLocalUsage]
    {
        let rows = self.nativeOrbitCodexAccounts(projection)
        let contexts = rows.compactMap { row
            -> (account: CodexVisibleAccount, history: [PlanUtilizationSeriesHistory], snapshot: UsageSnapshot?)? in
            guard case let .codex(account) = row.selection else { return nil }
            return (
                account: account,
                history: row.history,
                snapshot: self.nativeCodexPresentationRecord(for: account)?.snapshot)
        }
        return self.nativeOrbitCodexResolvedLocalUsages(contexts)
    }

    func nativeCodexSwitchRetainedLocalUsage(for account: CodexVisibleAccount) -> NativeOrbitResolvedLocalUsage? {
        guard let switching = self.nativeCodexAccountSwitchPresentation else { return nil }
        let owners = switching.projection.visibleAccounts.filter { previous in
            guard switching.localUsages[previous.id] != nil else { return false }
            let expected = switching.importedAccounts[previous.id] ?? previous
            guard expected.storedAccountID == account.storedAccountID,
                  expected.storedAccountID != nil || expected.id == account.id,
                  expected.authFingerprint == account.authFingerprint else { return false }
            return NativeAccountActivationVerification.codexOwnerEvidenceMatches(expected, account: account)
        }
        guard owners.count == 1, let owner = owners.first,
              let local = switching.localUsages[owner.id] else { return nil }
        var usage = local.usage
        usage.isStale = true
        return NativeOrbitResolvedLocalUsage(usage: usage, lastKnownAt: usage.snapshot.updatedAt)
    }

    func nativeCodexPresentationRecord(for account: CodexVisibleAccount) -> CodexAccountUsageSnapshot? {
        let current = Self.nativeCodexUniquePresentationRecord(for: account, in: self.codexAccountSnapshots)
        let retained = Self.nativeCodexUniquePresentationRecord(
            for: account, in: self.nativeCodexAccountSwitchPresentation?.snapshots ?? [])
        guard let current, let retained else { return current ?? retained }
        return CodexAccountUsageSnapshot(
            account: account,
            snapshot: current.snapshot,
            error: current.error,
            sourceLabel: current.sourceLabel ?? retained.sourceLabel,
            credits: current.credits ?? retained.credits,
            weeklyResetCandidate: current.weeklyResetCandidate,
            accountUsageHistory: current.accountUsageHistory ?? retained.accountUsageHistory)
    }

    func nativeCodexPresentationSnapshot(
        for account: CodexVisibleAccount,
        live: UsageSnapshot?,
        record: CodexAccountUsageSnapshot?) -> UsageSnapshot?
    {
        guard let switching = self.nativeCodexAccountSwitchPresentation else { return live ?? record?.snapshot }
        let retained = Self.nativeCodexUniquePresentationRecord(for: account, in: switching.snapshots)?.snapshot
        let cached = Self.nativeCodexSwitchSnapshot(current: record?.snapshot, retained: retained)
        return Self.nativeCodexSwitchSnapshot(current: live, retained: cached)
    }

    private nonisolated static func nativeCodexUniquePresentationRecord(
        for account: CodexVisibleAccount,
        in records: [CodexAccountUsageSnapshot]) -> CodexAccountUsageSnapshot?
    {
        let matches = records.filter { Self.codexPriorSnapshotAccountMatches($0.account, account: account) }
        let exact = matches.filter { $0.id == account.id }
        if !exact.isEmpty { return exact.count == 1 ? exact.first : nil }
        return matches.count == 1 ? matches.first : nil
    }

    /// Missing fields are filled only inside the credential transaction. Once it settles the complete receipt is
    /// authoritative, including absent windows; the cache cannot resurrect a removed subscription limit.
    private nonisolated static func nativeCodexSwitchSnapshot(
        current: UsageSnapshot?, retained: UsageSnapshot?) -> UsageSnapshot?
    {
        guard let current else { return retained }
        guard let retained else { return current }
        var extras = current.extraRateWindows ?? []
        let ids = Set(extras.map(\.id))
        extras += (retained.extraRateWindows ?? []).filter { !ids.contains($0.id) }
        let identity = current.identity.map { identity in
            ProviderIdentitySnapshot(
                providerID: identity.providerID,
                accountEmail: identity.accountEmail ?? retained.identity?.accountEmail,
                accountOrganization: identity.accountOrganization ?? retained.identity?.accountOrganization,
                loginMethod: identity.loginMethod ?? retained.identity?.loginMethod,
                accountID: identity.accountID ?? retained.identity?.accountID,
                historyOwnerAliases: identity.historyOwnerAliases,
                widgetAccountOwnerID: identity.widgetAccountOwnerID)
        } ?? retained.identity
        return UsageSnapshot(
            primary: current.primary ?? retained.primary,
            secondary: current.secondary ?? retained.secondary,
            tertiary: current.tertiary ?? retained.tertiary,
            extraRateWindows: extras.isEmpty ? nil : extras,
            providerCost: current.providerCost ?? retained.providerCost,
            costUsage: current.costUsage ?? retained.costUsage,
            details: current.details.isEmpty ? retained.details : current.details,
            codexResetCredits: current.codexResetCredits ?? retained.codexResetCredits,
            subscriptionStatus: current.subscriptionStatus ?? retained.subscriptionStatus,
            subscriptionIsActive: current.subscriptionIsActive ?? retained.subscriptionIsActive,
            subscriptionExpiresAt: current.subscriptionExpiresAt ?? retained.subscriptionExpiresAt,
            subscriptionRenewsAt: current.subscriptionRenewsAt ?? retained.subscriptionRenewsAt,
            subscriptionRenewsAtIsDateOnly: current.subscriptionRenewsAt == nil
                ? retained.subscriptionRenewsAtIsDateOnly : current.subscriptionRenewsAtIsDateOnly,
            subscriptionExpiresAtIsDateOnly: current.subscriptionExpiresAt == nil
                ? retained.subscriptionExpiresAtIsDateOnly : current.subscriptionExpiresAtIsDateOnly,
            updatedAt: current.updatedAt,
            identity: identity,
            dataConfidence: current.dataConfidence)
    }
}
