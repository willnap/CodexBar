import CodexBarCore
import Foundation

extension UsageStore {
    struct ProviderRefreshOutcomeContext {
        let generation: UInt64
        let includesCredits: Bool
        let claudeUsesConsumerAutoPipeline: Bool
        let codexExpectedGuard: CodexAccountScopedRefreshGuard?
        let tokenAccount: ProviderTokenAccount?
        let priorTokenAccountSnapshot: TokenAccountUsageSnapshot?
        let codexLimitResetOwnerKey: CodexLimitResetOwnerKey?
        let claudeOAuthHistoryPersistentRefHash: String?
        let claudeOAuthActiveAccountObservation: ClaudeOAuthActiveAccountObservation
        var claudeCredentialFingerprint: String?
        var claudeCredentialSource: String?
        var claudeCredentialProfileIdentifier: String?

        var codexSessionQuotaOwnerKey: CodexSessionQuotaOwnerKey? {
            UsageStore.codexSessionQuotaOwnerKey(for: self.codexExpectedGuard)
        }
    }

    func credentialAccount(provider: UsageProvider, context: ProviderRefreshOutcomeContext) -> String {
        // Provider-specific by design: Claude clears its profile witness before Codex or Claude owner validation.
        if provider == .claude { self.nativeClaudeCredentialPresentationScope = nil }
        if let account = Self.warningTokenAccountDiscriminator(context.tokenAccount) { return account }
        // Provider-specific by design: ambient CLI accounts use the refresh's already-validated ownership evidence.
        if provider == .codex { return context.codexSessionQuotaOwnerKey?.rawValue ?? "default" }
        if provider == .claude {
            if case .stable(identity: nil) = context.claudeOAuthActiveAccountObservation,
               let source = context.claudeCredentialSource,
               let profile = context.claudeCredentialProfileIdentifier,
               source == self.settings.claudeUsageDataSource.rawValue,
               profile == self.nativeClaudeCredentialProfileIdentifier
            {
                let scope = context.claudeCredentialFingerprint.map {
                    self.claudeCredentialNotificationScope(identity: nil, fingerprint: $0)
                } ?? "claude-profile:\(profile):source:\(source)"
                self.nativeClaudeCredentialPresentationScope = .init(scope: scope, source: source, profile: profile)
                return scope
            }
            let identity: String? = if case let .stable(identity) = context.claudeOAuthActiveAccountObservation {
                identity
            } else { nil }
            return self.claudeCredentialNotificationScope(
                identity: identity,
                fingerprint: context.claudeCredentialFingerprint)
        }
        return "default"
    }

    private func warningAccountDiscriminators(
        provider: UsageProvider,
        result: ProviderFetchResult,
        context: ProviderRefreshOutcomeContext) -> (quota: String?, source: String?, requiresKnownAccount: Bool)
    {
        // Provider-specific by design: warning scopes follow Codex owners and verified Claude account bindings.
        let requiresKnownAccount = provider == .claude && [.oauth, .cli].contains(result.strategyKind)
        if let tokenAccount = context.tokenAccount {
            let key = Self.warningTokenAccountDiscriminator(tokenAccount)
            return (key, key, requiresKnownAccount)
        }
        if provider == .codex {
            let key = context.codexSessionQuotaOwnerKey?.rawValue
            return (key, key, requiresKnownAccount)
        }
        guard provider == .claude else { return (nil, nil, requiresKnownAccount) }
        let scopes = self.warningClaudeAccountDiscriminators(
            strategyKind: result.strategyKind,
            observation: result.strategyKind == .cli || result.claudeOAuthCredentialOwner == .claudeCLI
                ? context.claudeOAuthActiveAccountObservation : .changed,
            oauthHistoryOwnerIdentifier: result.claudeOAuthHistoryOwnerIdentifier)
        return (scopes.quota, scopes.source, requiresKnownAccount)
    }

    func handleProviderRefreshNotifications(
        provider: UsageProvider,
        result: ProviderFetchResult,
        snapshot: UsageSnapshot,
        context: ProviderRefreshOutcomeContext) -> (account: String?, sessionRestored: Bool)
    {
        self.handleCredentialOutcome(
            provider: provider,
            account: self.credentialAccount(provider: provider, context: context),
            nativeFaultScope: self.nativeAmbientFaultScope(provider),
            result: .success(result))
        let warningAccounts = self.warningAccountDiscriminators(
            provider: provider,
            result: result,
            context: context)
        self.handleQuotaWarningTransitions(
            provider: provider,
            snapshot: snapshot,
            accountDiscriminator: warningAccounts.quota,
            hookAccountDiscriminator: warningAccounts.source,
            requiresKnownAccount: warningAccounts.requiresKnownAccount)
        let sessionRestored = self.handleSessionQuotaTransition(
            provider: provider,
            snapshot: snapshot,
            accountDiscriminator: warningAccounts.quota,
            // Provider-specific by design: session and credit reset notices require the validated Codex owner.
            codexOwnerKey: provider == .codex ? context.codexSessionQuotaOwnerKey : nil)
        self.handlePredictivePaceWarningTransitions(
            provider: provider,
            snapshot: snapshot,
            accountDiscriminatorOverride: warningAccounts.source,
            requiresKnownAccount: warningAccounts.requiresKnownAccount)
        if provider == .codex {
            self.handleCodexResetCreditNotifications(snapshot: snapshot)
        }
        return (warningAccounts.source, sessionRestored)
    }
}
