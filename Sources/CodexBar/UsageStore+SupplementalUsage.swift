import CodexBarCore
import Foundation

extension UsageStore {
    func scheduleSupplementalUsageUpdate(
        provider: UsageProvider,
        outcome: ProviderFetchOutcome,
        generation: UInt64?,
        accountID: UUID?)
    {
        guard case let .success(result) = outcome.result else { return }
        self.scheduleSupplementalUsageUpdate(
            provider: provider,
            result: result,
            generation: generation,
            accountID: accountID)
    }

    func scheduleSupplementalUsageUpdates(
        provider: UsageProvider,
        results: [TokenAccountFetchResult],
        selectedAccountID: UUID?,
        generation: UInt64?)
    {
        for result in results where result.account.id != selectedAccountID {
            guard case let .success(fetchResult) = result.outcome.result else { continue }
            self.scheduleSupplementalUsageUpdate(
                provider: provider,
                result: fetchResult,
                generation: generation,
                accountID: result.account.id)
        }
    }

    func scheduleSupplementalUsageUpdate(
        provider: UsageProvider,
        result: ProviderFetchResult,
        generation: UInt64?,
        accountID: UUID?)
    {
        guard let sourceTask = result.supplementalUsageTask else { return }

        let expectedUpdatedAt = result.usage.updatedAt
        Task { @MainActor [weak self] in
            let update = await sourceTask.value
            guard let self else { return }
            guard self.isCurrentProviderRefreshGeneration(provider, generation: generation)
            else { return }
            await self.applySupplementalUsageUpdate(
                update,
                provider: provider,
                expectedUpdatedAt: expectedUpdatedAt,
                accountID: accountID)
        }
    }

    private func applySupplementalUsageUpdate(
        _ update: ProviderSupplementalUsageUpdate,
        provider: UsageProvider,
        expectedUpdatedAt: Date,
        accountID: UUID?) async
    {
        // Provider-specific by design: only Grok publishes remaining reset credits as a supplemental update.
        guard provider == .grok else { return }

        let resetCredits: GrokRateLimitResetCreditsSnapshot? = switch update {
        case let .grokResetCredits(snapshot): snapshot
        }
        var historySnapshot: UsageSnapshot?
        var historyAccount: ProviderTokenAccount?
        if let accountID,
           let account = self.uniqueTokenAccount(provider: provider, accountID: accountID),
           let accountSnapshot = self.accountSnapshots[provider.instanceID]?.first(where: {
               $0.account.id == accountID && $0.snapshot?.updatedAt == expectedUpdatedAt
           }),
           let currentAccountUsage = accountSnapshot.snapshot
        {
            let updated = currentAccountUsage.withGrokResetCredits(resetCredits)
            historySnapshot = updated
            historyAccount = account
            self.cacheTokenAccountSnapshot(
                provider: provider,
                account: account,
                snapshot: updated,
                sourceLabel: accountSnapshot.sourceLabel)
        }

        let updatesLiveSnapshot = accountID.map {
            self.settings.effectiveSelectedTokenAccount(for: provider)?.id == $0
        } ?? true
        if updatesLiveSnapshot,
           let current = self.snapshots[provider.instanceID],
           current.updatedAt == expectedUpdatedAt
        {
            let updated = current.withGrokResetCredits(resetCredits)
            self.snapshots[provider.instanceID] = updated
            if accountID == nil { historySnapshot = updated }
            if self.lastKnownResetSnapshots[provider.instanceID]?.updatedAt == expectedUpdatedAt {
                self.lastKnownResetSnapshots[provider.instanceID] = updated
            }
        }
        if self.settings.nativeDesignEnabled, let historySnapshot {
            await self.recordPlanUtilizationHistorySample(
                provider: provider,
                snapshot: historySnapshot,
                account: historyAccount,
                now: historySnapshot.updatedAt)
        }
    }
}
