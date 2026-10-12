import CodexBarCore
import Foundation

struct NativeTokenAccountRefreshAttempt {
    let cacheKey: String
    let includesOptionalUsage: Bool
    let attemptedAt: Date
}

struct NativeCodexAccountRefreshAttempt {
    let owner: CodexAccountScopedRefreshGuard
    let configRevision: UInt64
    let attemptedAt: Date
}

extension UsageStore {
    func isNativeSavedAccountAvailable(_ provider: UsageProvider) -> Bool {
        guard self.settings.nativeDesignEnabled else { return false }
        if !self.tokenAccounts(for: provider).isEmpty { return true }
        // Provider-specific by design: ClaudeSwap can monitor accounts without an ambient CLI login.
        return provider == .claude && self.settings.claudeSwapEnabled
            && !self.settings.claudeSwapExecutablePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func recordNativeCodexAccountRefreshAttempt(
        account: CodexVisibleAccount, outcome: ProviderFetchOutcome, projection: CodexVisibleAccountProjection)
    {
        guard self.settings.nativeDesignEnabled, !Task.isCancelled,
              let current = Self.currentCodexVisibleAccount(
                  matching: account, projection: projection, allowProviderAccountAuthFingerprintMismatch: true)
        else { return }
        if case let .failure(error) = outcome.result, error is CancellationError { return }
        self.nativeCodexAccountRefreshAttempts[account.id] = .init(
            owner: Self.codexScopedRefreshGuard(for: current),
            // Provider-specific by design: Codex polling must restart when its auth configuration changes.
            configRevision: self.settings.providerConfigRevision(for: .codex),
            attemptedAt: Date())
    }

    func recordNativeTokenAccountRefreshAttempt(
        provider: UsageProvider, account: ProviderTokenAccount, outcome: ProviderFetchOutcome)
    {
        guard self.settings.nativeDesignEnabled, !Task.isCancelled else { return }
        if case let .failure(error) = outcome.result, error is CancellationError { return }
        self.nativeTokenAccountRefreshAttempts[provider.instanceID, default: [:]][account.id] = .init(
            cacheKey: self.tokenAccountSnapshotCacheKey(provider: provider, account: account),
            includesOptionalUsage: ProviderTokenAccountSelection.shouldIncludeOptionalUsage(
                provider: provider,
                settings: self.settings,
                override: .init(provider: provider, account: account)),
            attemptedAt: Date())
    }

    static let tokenAccountMenuSnapshotLimit = 6

    nonisolated static let nativeSecondaryAccountRefreshInterval: TimeInterval = 5 * 60

    /// Attempts and measurements have separate clocks: cached upstream measurements must keep their real dates.
    nonisolated static func nativeSecondaryAccountRefreshIsDue(
        snapshot: UsageSnapshot?, lastAttempt: Date?, now: Date) -> Bool
    {
        let latest = [snapshot?.updatedAt, lastAttempt].compactMap(\.self).max()
        guard let latest else { return true }
        if latest > now || now.timeIntervalSince(latest) >= self.nativeSecondaryAccountRefreshInterval { return true }
        let lastChecked = lastAttempt ?? snapshot?.updatedAt ?? .distantPast
        let windows = [snapshot?.primary, snapshot?.secondary, snapshot?.tertiary].compactMap(\.self)
            + (snapshot?.extraRateWindows ?? []).filter(\.usageKnown).map(\.window)
        let resets = windows.map(\.resetsAt).compactMap(\.self) + [snapshot?.providerCost?.resetsAt].compactMap(\.self)
        return resets.contains { $0 > lastChecked && $0 <= now }
    }

    func tokenAccountsDueForNativeRefresh(
        provider: UsageProvider, accounts: [ProviderTokenAccount], selected: ProviderTokenAccount?, now: Date)
        -> [ProviderTokenAccount]
    {
        guard self.settings.nativeDesignEnabled, ProviderInteractionContext.current == .background else {
            return accounts
        }
        let ids = Set(accounts.map(\.id))
        self.nativeTokenAccountRefreshAttempts[provider.instanceID] =
            self.nativeTokenAccountRefreshAttempts[provider.instanceID]?.filter { ids.contains($0.key) }
        let cached = Dictionary(
            grouping: self.validTokenAccountSnapshots(provider: provider, accounts: accounts),
            by: \.id)
        return accounts.filter { account in
            if account.id == selected?.id { return true }
            guard let records = cached[account.id], records.count == 1, let record = records.first else { return true }
            let attempt = self.nativeTokenAccountRefreshAttempts[provider.instanceID]?[account.id]
            let optional = ProviderTokenAccountSelection.shouldIncludeOptionalUsage(
                provider: provider, settings: self.settings, override: .init(provider: provider, account: account))
            if let attempt, attempt.cacheKey != record.cacheKey || attempt.includesOptionalUsage != optional {
                return true
            }
            return Self.nativeSecondaryAccountRefreshIsDue(
                snapshot: record.snapshot, lastAttempt: attempt?.attemptedAt, now: now)
        }
    }

    func codexAccountIsDueForNativeRefresh(
        _ account: CodexVisibleAccount, priorSnapshots: [CodexAccountUsageSnapshot], now: Date) -> Bool
    {
        // Provider-specific by design: Codex live login and selected monitoring source each keep their normal cadence.
        guard self.settings.nativeDesignEnabled, ProviderInteractionContext.current == .background,
              !account.isLive, !account.isActive else { return true }
        guard let prior = Self.codexPriorAccountSnapshot(matching: account, in: priorSnapshots),
              prior.weeklyResetCandidate == nil else { return true }
        let attempt = self.nativeCodexAccountRefreshAttempts[account.id]
        if let attempt, attempt.owner != Self.codexScopedRefreshGuard(for: account)
            || attempt.configRevision != self.settings.providerConfigRevision(for: .codex) { return true }
        return Self.nativeSecondaryAccountRefreshIsDue(
            snapshot: prior.snapshot, lastAttempt: attempt?.attemptedAt, now: now)
    }

    func freshCodexVisibleAccountsForSnapshotHydration() -> [CodexVisibleAccount] {
        self.freshCodexVisibleAccountProjectionForAccountRefresh().visibleAccounts
    }

    func tokenAccounts(for provider: UsageProvider) -> [ProviderTokenAccount] {
        guard TokenAccountSupportCatalog.support(for: provider) != nil else { return [] }
        return self.settings.tokenAccounts(for: provider)
    }

    func shouldFetchAllTokenAccounts(provider: UsageProvider, accounts: [ProviderTokenAccount]) -> Bool {
        guard TokenAccountSupportCatalog.support(for: provider) != nil else { return false }
        if self.settings.nativeDesignEnabled { return !accounts.isEmpty }
        guard self.settings.effectiveSelectedTokenAccount(for: provider) != nil else { return false }
        return self.settings.accountWidgetsEnabled && !accounts.isEmpty
            || self.settings.multiAccountMenuLayout == .stacked && accounts.count > 1
    }

    func shouldFetchAllCodexVisibleAccounts() -> Bool {
        // PAT is not a per-visible-account credential. Fan-out would fetch the same token for
        // every row and then reject its whoami identity against other accounts.
        guard !self.shouldUseAmbientCodexPATForUsage() else { return false }
        let projection = self.freshCodexVisibleAccountProjectionForAccountRefresh()
        if self.settings.nativeDesignEnabled { return !projection.visibleAccounts.isEmpty }
        return (self.settings.multiAccountMenuLayout == .stacked || self.settings.accountWidgetsEnabled)
            && projection.visibleAccounts.count > 1
    }
}
