import CodexBarCore
import Foundation

extension UsageStore {
    /// Apply continuity rules to a copy. The central materializer keeps marked anonymous archives unowned.
    /// Rendering never migrates storage or refreshes auth evidence.
    func nativeOrbitCodexHistory(
        account: CodexVisibleAccount,
        projection: CodexVisibleAccountProjection,
        snapshot: UsageSnapshot?,
        canonicalKey: String?) -> [PlanUtilizationSeriesHistory]
    {
        _ = self.planUtilizationHistoryRevision
        guard self.planUtilizationHistoryLoaded, let canonicalKey else { return [] }
        // Provider-specific by design: Codex legacy history carries email/workspace continuity evidence.
        var buckets = self.planUtilizationHistory[.codex] ?? PlanUtilizationHistoryBuckets()
        let cached = self.settings.cachedCodexAccountReconciliationSnapshot?.snapshot
        let ownership = Self.nativeOrbitCodexHistoryOwnership(
            account: account, projection: projection, snapshot: snapshot, cached: cached)
        if ownership.hasAdjacentEmailScopeAmbiguity {
            return canonicalKey == ownership.canonicalEmailHashKey ? [] : buckets.accounts[canonicalKey] ?? []
        }
        let key = self.materializeCodexPlanUtilizationHistoryIfNeeded(
            into: canonicalKey, ownership: ownership, shouldAdoptUnscopedHistory: true, providerBuckets: &buckets)
        return buckets.accounts[key] ?? []
    }

    nonisolated static func nativeOrbitCodexHistoryOwnership(
        account: CodexVisibleAccount,
        projection: CodexVisibleAccountProjection,
        snapshot: UsageSnapshot?,
        cached: CodexAccountReconciliationSnapshot?) -> CodexOwnershipContext
    {
        var owners = Set<String>()
        var emailOwners: [String: Set<String>] = [:]
        func append(_ identity: CodexIdentity, email: String?, fallback: String) {
            let key = CodexHistoryOwnership.canonicalKey(for: identity) ?? "unresolved:" + fallback
            owners.insert(key)
            if let email = CodexIdentityResolver.normalizeEmail(email) { emailOwners[email, default: []].insert(key) }
        }
        for visible in projection.visibleAccounts {
            append(Self.codexScopedRefreshGuard(for: visible).identity, email: visible.email, fallback: visible.id)
        }
        if let cached {
            for stored in cached.storedAccounts {
                append(
                    cached.managedRemoteIdentity(for: stored),
                    email: cached.runtimeEmail(for: stored),
                    fallback: stored.id.uuidString)
                append(
                    cached.runtimeIdentity(for: stored),
                    email: cached.runtimeEmail(for: stored),
                    fallback: stored.id.uuidString)
            }
            for observed in cached.profileHomeAccounts + [cached.liveSystemAccount].compactMap(\.self) {
                append(cached.runtimeIdentity(for: observed), email: observed.email, fallback: observed.codexHomePath)
            }
        }
        let email = CodexIdentityResolver.normalizeEmail(account.email)
        let unreadable = projection.hasUnreadableAddedAccountStore || cached?.hasUnreadableAddedAccountStore == true
        let weekly = [snapshot?.secondary, snapshot?.primary].compactMap(\.self)
            .first { $0.windowMinutes == 10080 }
        return CodexOwnershipContext(
            canonicalKey: CodexHistoryOwnership.canonicalKey(for: Self.codexScopedRefreshGuard(for: account).identity),
            canonicalEmailHashKey: email.map { CodexHistoryOwnership.canonicalEmailHashKey(for: $0) },
            historicalLegacyEmailHash: email.map { CodexHistoryOwnership.legacyEmailHash(normalizedEmail: $0) },
            planUtilizationLegacyEmailHash: email.map(Self.codexLegacyPlanUtilizationEmailHashKey),
            currentWeeklyResetAt: weekly?.resetsAt,
            hasAdjacentMultiAccountVeto: unreadable || cached == nil || owners.count > 1,
            hasAdjacentEmailScopeAmbiguity: unreadable || email.map { (emailOwners[$0]?.count ?? 0) > 1 } == true)
    }
}
