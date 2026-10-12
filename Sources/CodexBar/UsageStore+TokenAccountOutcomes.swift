import CodexBarCore
import Foundation

extension UsageStore {
    struct ResolvedAccountOutcome {
        let snapshot: TokenAccountUsageSnapshot?
        let usage: UsageSnapshot?
        let freshUsage: UsageSnapshot?
    }

    func resolveAccountOutcome(
        _ outcome: ProviderFetchOutcome,
        provider: UsageProvider,
        account: ProviderTokenAccount,
        priorSnapshot: TokenAccountUsageSnapshot? = nil) -> ResolvedAccountOutcome
    {
        self.handleCredentialOutcome(
            provider: provider,
            account: Self.warningTokenAccountDiscriminator(account) ?? "default",
            result: outcome.result)
        switch outcome.result {
        case let .success(result):
            let scoped = result.usage.scoped(to: provider)
            let current = self.resolvingCurrentCopilotAllowance(in: scoped, provider: provider, account: account)
            let labeled = current.withAccountLabel(account.label, for: provider)
            let prior = self.matchingTokenAccountSnapshot(priorSnapshot, provider: provider, account: account)?.snapshot
            // Provider-specific by design: DeepSeek retains its account-owned Chrome profile catalog during API
            // refreshes.
            let profileStable = provider == .deepseek
                ? labeled.preservingDeepSeekPlatformProfiles(from: prior) : labeled
            let enriched = Self.commandCodeSnapshotResolvingDepletionOnEnrichmentFailure(
                current: profileStable, previous: prior).backfillingResetTimesForProvider(provider, from: prior)
            let snapshot = TokenAccountUsageSnapshot(
                account: account,
                snapshot: enriched,
                error: nil,
                sourceLabel: result.sourceLabel,
                cacheKey: self.tokenAccountSnapshotCacheKey(provider: provider, account: account))
            return ResolvedAccountOutcome(snapshot: snapshot, usage: enriched, freshUsage: enriched)
        case let .failure(error):
            let prior = self.matchingTokenAccountSnapshot(priorSnapshot, provider: provider, account: account)
            if Self.shouldSuppressProviderCancellation(error, priorSnapshot: prior?.snapshot) {
                return ResolvedAccountOutcome(snapshot: prior, usage: prior?.snapshot, freshUsage: nil)
            }
            let oauthLimited = Self.preservesClaudeOAuthSnapshot(error, provider: provider, snapshot: prior)
            let retained = oauthLimited || Self.shouldPreservePriorSnapshot(
                after: error,
                hadPriorData: prior != nil,
                priorSnapshot: prior?.snapshot)
                ? prior : nil
            let snapshot = TokenAccountUsageSnapshot(
                account: account,
                snapshot: retained?.snapshot,
                error: oauthLimited ? nil : self.tokenAccountSnapshotErrorMessage(error),
                sourceLabel: retained?.sourceLabel,
                cacheKey: self.tokenAccountSnapshotCacheKey(provider: provider, account: account),
                fetchError: error)
            return ResolvedAccountOutcome(snapshot: snapshot, usage: retained?.snapshot, freshUsage: nil)
        }
    }

    func matchingTokenAccountSnapshot(
        _ snapshot: TokenAccountUsageSnapshot?,
        provider: UsageProvider,
        account: ProviderTokenAccount) -> TokenAccountUsageSnapshot?
    {
        guard let snapshot, snapshot.account.id == account.id, snapshot.snapshot != nil,
              let current = self.uniqueTokenAccount(provider: provider, accountID: account.id),
              snapshot.cacheKey == self.tokenAccountSnapshotCacheKey(provider: provider, account: current)
        else { return nil }
        return self.resolvingCurrentCopilotAllowance(in: snapshot, provider: provider, account: current)
    }

    static func preservesClaudeOAuthSnapshot(
        _ error: Error,
        provider: UsageProvider,
        snapshot: TokenAccountUsageSnapshot?) -> Bool
    {
        // Provider-specific by design: a matching Claude OAuth cache survives OAuth usage throttling.
        provider == .claude && snapshot?.sourceLabel == "oauth" && ClaudeUsageError.isClaudeOAuthUsageRateLimit(error)
    }
}
