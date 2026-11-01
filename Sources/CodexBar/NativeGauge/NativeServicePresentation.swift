import AppKit
import CodexBarCore
import Foundation

struct NativeClaudeCredentialPresentationScope: Equatable {
    let scope: String
    let source: String
    let profile: String
}

struct NativeServicePresentation {
    let model: UsageMenuCardView.Model
    let gauge: ComputeGauge.State
    let accountID: String?
    var gaugeOwnershipID: String?

    var iconSignature: String {
        var hasher = Hasher()
        hasher.combine(self.accountID)
        hasher.combine(self.gaugeOwnershipID)
        hasher.combine(self.model.providerName)
        hasher.combine(self.model.email)
        hasher.combine(self.gauge.health.rawValue)
        hasher.combine(self.gauge.provider)
        hasher.combine(self.gauge.pace.rawValue)
        for window in self.gauge.resolvedWindows {
            hasher.combine(window.id)
            hasher.combine(window.label)
            hasher.combine(window.period)
            hasher.combine(window.usedFraction)
            hasher.combine(window.recovery.rawValue)
            hasher.combine(window.countdown?.units)
            hasher.combine(window.countdown?.secondsPerUnit)
            hasher.combine(window.countdown?.nextReset)
            hasher.combine(window.countdown?.isReliable)
        }
        return String(hasher.finalize())
    }
}

extension UsageStore {
    var nativeClaudeSwapOwnsPresentation: Bool {
        // Provider-specific by design: ClaudeSwap owns Claude identity and usage when its adapter is selected.
        self.settings.claudeSwapEnabled && ClaudeSwapMenuPrecedence.prefersClaudeSwap(
            provider: .claude,
            accountCount: self.claudeSwapAccountSnapshots.count,
            showSingleAccount: self.settings.nativeDesignEnabled || self.settings.claudeSwapShowSingleAccount)
    }

    /// The readiness window for remembering the launch layout; it never holds back the popup's first frame.
    static let nativePopupReadinessLimit: TimeInterval = 5

    /// Whether account inventory, history, and readings have answered during the launch readiness window.
    /// Layout memory stops waiting after the window; visible columns and diagnostic evidence do not wait.
    func nativePopupIsReady(
        for provider: UsageProvider,
        accounts: [NativeOrbitAccountPresentation],
        now: Date = Date()) -> Bool
    {
        // Provider-specific by design: claude-swap's list, once it answers, decides the Claude columns.
        let awaitingAccountList = provider == .claude && self.shouldFetchClaudeSwapAccounts()
            && self.claudeSwapLastRefreshAt == nil && self.claudeSwapLastError == nil
        return Self.nativePopupIsReady(
            waitRemaining: self.nativePopupReadinessWaitRemaining(now: now),
            historyAvailable: self.nativeHistoryAvailable(provider),
            awaitingAccountList: awaitingAccountList,
            accounts: accounts)
    }

    nonisolated static func nativePopupIsReady(
        waitRemaining: TimeInterval,
        historyAvailable: Bool,
        awaitingAccountList: Bool,
        accounts: [NativeOrbitAccountPresentation]) -> Bool
    {
        if waitRemaining <= 0 { return true }
        guard historyAvailable, !awaitingAccountList, !accounts.isEmpty else { return false }
        return accounts.allSatisfy { $0.updatedAt != nil || $0.statusText != nil }
    }

    /// Seconds left of the launch wait (zero once it is over).
    func nativePopupReadinessWaitRemaining(now: Date = Date()) -> TimeInterval {
        guard let launched = NSRunningApplication.current.launchDate else { return 0 }
        return max(0, Self.nativePopupReadinessLimit - now.timeIntervalSince(launched))
    }

    /// Builds the provider's account list from local account files when none exists yet, so a popup prepared at launch
    /// shows its columns instead of an empty placeholder until the first background reconciliation lands.
    func prepareNativeAccountInventory(for provider: UsageProvider) {
        // Provider-specific by design: only Codex reconciles its account list from local files.
        guard provider == .codex, self.settings.codexUsageDataSource != .pat,
              self.settings.codexVisibleAccountProjectionForMenuDisplay == nil else { return }
        _ = self.settings.codexAccountReconciliationSnapshot
    }

    var nativeCodexAccountProjection: CodexVisibleAccountProjection? {
        guard self.settings.codexUsageDataSource != .pat,
              self.lastSourceLabels[.codex] != CodexUsageDataSource.pat.sourceLabel else { return nil }
        return self.settings.codexVisibleAccountProjectionForMenuDisplay
            ?? self.nativeCodexAccountSwitchPresentation?.projection
            .applyingCustomNames(self.settings.codexAccountNames)
    }

    func nativeClaudeSwapDisplay(inspectedAccountID: ProviderAccountIdentity? = nil) -> ClaudeSwapAccountMenuDisplay {
        _ = self.claudeSwapRevision
        return ClaudeSwapAccountMenuDisplay(
            accounts: self.claudeSwapAccountSnapshots,
            layout: .segmented,
            switchingAccountID: self.claudeSwapTransientState.switchingAccountID,
            errorAccountID: self.claudeSwapTransientState.lastErrorAccountID,
            inspectedAccountID: inspectedAccountID)
    }

    func nativeServicePresentation(
        for provider: UsageProvider,
        inspectedAccountID: ProviderAccountIdentity? = nil) -> NativeServicePresentation
    {
        var context = UsageMenuCardContext.menu
        var accountID: String?
        var suppressGaugeUsage = false
        var unverifiedMonitoringSelection = false
        // Provider-specific by design: Dedicated Codex and ClaudeSwap account owners must never inherit ambient
        // usage when their selected account has no measurement.
        if provider == .codex,
           self.settings.codexUsageDataSource != .pat,
           self.lastSourceLabels[.codex] != CodexUsageDataSource.pat.sourceLabel
        {
            let liveAccounts = self.nativeCodexAccountProjection.map { projection in
                projection.visibleAccounts.filter { $0.isLive && $0.id == projection.liveVisibleAccountID }
            } ?? []
            if liveAccounts.count == 1, let account = liveAccounts.first {
                accountID = account.id
                let ownsLiveUsage = self.lastCodexUsagePublicationGuard.map {
                    Self.codexScopedRefreshGuardsMatchAccount($0, Self.codexScopedRefreshGuard(for: account))
                } == true
                let record = self.nativeCodexPresentationRecord(for: account)
                if !ownsLiveUsage || self.nativeCodexAccountSwitchPresentation != nil
                    || (self.snapshots[.codex] == nil && record?.snapshot != nil)
                {
                    context = .account(.init(
                        snapshot: self.nativeCodexPresentationSnapshot(
                            for: account, live: ownsLiveUsage ? self.snapshots[.codex] : nil, record: record),
                        error: ownsLiveUsage ? self.userFacingError(for: .codex)
                            : CodexUIErrorMapper.userFacingMessage(record?.error),
                        info: AccountInfo(email: account.email, plan: nil),
                        sourceLabel: ownsLiveUsage ? self.lastSourceLabels[.codex] ?? record?.sourceLabel
                            : record?.sourceLabel,
                        credits: ownsLiveUsage ? self.credits ?? record?.credits : record?.credits))
                }
            } else {
                // A monitored source is not evidence of the machine's actual login.
                context = .account(.init(info: AccountInfo(email: nil, plan: nil)))
            }
            // Provider-specific by design: ClaudeSwap owns Claude's actual login and must supply exactly one active
            // owner.
        } else if provider == .claude, self.nativeClaudeSwapOwnsPresentation {
            _ = self.claudeSwapRevision
            let activeAccounts = self.claudeSwapAccountSnapshots.filter {
                $0.provider == .claude && $0.id.source == ClaudeSwapAccountProjection.sourceName && $0.isActive
            }
            if activeAccounts.count == 1, let account = activeAccounts.first,
               NativeAccountActivationVerification.claudeOwnsLogin(
                   account.id,
                   accounts: self.claudeSwapAccountSnapshots)
            {
                accountID = account.id.opaqueID
                context = ClaudeSwapAccountMenuDisplay.cardContext(
                    for: account,
                    planLabel: nil,
                    adapterError: self.claudeSwapLastError,
                    switchError: self.claudeSwapTransientState.lastErrorAccountID == account.id
                        ? self.claudeSwapTransientState.lastError : nil)
                if var accountContext = context.account {
                    accountContext.snapshot = self.nativeOrbitClaudePresentationSnapshot(
                        for: account, ambient: self.nativeOrbitClaudeOwnedAmbientSnapshot(for: account))
                    context = .account(accountContext)
                }
                suppressGaugeUsage = account.usesLastKnownUsage
                    || self.claudeSwapTransientState.switchPhase != nil
            } else {
                context = .account(.init(error: L("No active account"), info: AccountInfo(email: nil, plan: nil)))
                suppressGaugeUsage = true
            }
        } else if self.settings.nativeDesignEnabled,
                  self.settings.tokenAccounts(for: provider).count > 1,
                  self.settings.effectiveSelectedTokenAccount(for: provider) != nil
        {
            // A saved monitoring token cannot establish which account owns the machine login.
            context = .account(.init(info: AccountInfo(email: nil, plan: nil)))
            unverifiedMonitoringSelection = true
        }
        let input = self.menuCardInput(for: provider, context: context)
        let model = UsageMenuCardView.Model.make(input)
            .applyingUsageItemVisibility(hiddenItemIDs: self.settings.hiddenUsageItemIDs(for: provider))
        // Provider-specific by design: Codex's card surface omits credit-only rate lanes. Build the bar surface
        // from the same verified account inputs, with explicit nils instead of ambient fallback.
        let gaugeProjection = provider == .codex ? CodexConsumerProjection.make(
            surface: context.account == nil ? .menuBar : .overrideCard,
            context: .init(
                snapshot: input.snapshot,
                rawUsageError: input.lastError,
                liveCredits: context.account == nil ? self.credits : context.account?.credits,
                rawCreditsError: context.account == nil ? self.lastCreditsError : nil,
                liveDashboard: nil,
                rawDashboardError: nil,
                dashboardAttachmentAuthorized: false,
                dashboardRequiresLogin: false,
                now: input.now,
                showOptionalCreditsAndExtraUsage: input.showOptionalCreditsAndExtraUsage)) : nil
        let creditOnly = gaugeProjection?.displayedRateLanes(
            showOptionalCreditsAndExtraUsage: input.showOptionalCreditsAndExtraUsage) == [.monthly]
        let gaugeError = input.lastError ?? (creditOnly ? gaugeProjection?.userFacingErrors.credits : nil)
        let credentialScope = unverifiedMonitoringSelection ? nil : self.nativeGaugeCredentialScope(for: provider)
        let gauge = NativeUsageGaugeProjection.state(
            provider: provider,
            snapshot: suppressGaugeUsage ? nil : input.snapshot,
            error: gaugeError,
            codexProjection: gaugeProjection,
            showOptionalCreditsAndExtraUsage: input.showOptionalCreditsAndExtraUsage,
            visibleMetrics: model.metrics,
            weeklyPace: suppressGaugeUsage || !input.paceVisible ? nil : input.weeklyPace,
            status: self.statusIndicator(for: provider),
            isEnabled: self.settings.isProviderEnabledCached(
                provider: provider, metadataByProvider: self.providerMetadata),
            hasAccess: unverifiedMonitoringSelection || (self.isProviderAvailable(provider)
                && (context.account != nil || input.limitsAvailability?.isUnavailable != true)),
            isAuthenticationFailure: credentialScope.map {
                self.nativeAuthenticationFailures.contains(.init(provider: provider, account: $0))
            } == true)
        return NativeServicePresentation(
            model: model,
            gauge: gauge,
            accountID: accountID,
            gaugeOwnershipID: accountID ?? credentialScope)
    }

    func nativeGaugeCredentialScope(for provider: UsageProvider) -> String? {
        // Provider-specific by design: ClaudeSwap owns its errors; ambient Codex uses validated session ownership.
        if provider == .claude, self.nativeClaudeSwapOwnsPresentation { return nil }
        if let scope = Self
            .warningTokenAccountDiscriminator(self.settings.effectiveSelectedTokenAccount(for: provider))
        {
            return scope
        }
        // Provider-specific by design: auth state follows the same validated Codex owner as fetch publication.
        if provider == .codex, self.settings.codexUsageDataSource != .pat,
           self.lastSourceLabels[.codex] != CodexUsageDataSource.pat.sourceLabel
        {
            guard let projection = self.nativeCodexAccountProjection else { return nil }
            let liveAccounts = projection.visibleAccounts.filter {
                $0.isLive && $0.id == projection.liveVisibleAccountID
            }
            guard liveAccounts.count == 1, let account = liveAccounts.first else { return nil }
            let guardValue = Self.codexScopedRefreshGuard(for: account)
            return Self.codexSessionQuotaOwnerKey(for: guardValue)?.rawValue
        }
        // Provider-specific by design: ClaudeSwap owns opaque account errors; never classify its strings or
        // borrow ambient credentials. Ambient Claude uses its prompt-free owner-selected account config.
        if provider == .claude { return self.nativeClaudeAmbientCredentialScope() }
        return "default"
    }

    /// The scope this Mac's own Claude reads record their outcomes under: the live login's account, from its
    /// prompt-free config. A switch changes the account, so an earlier login's fault never follows it.
    func nativeClaudeAmbientCredentialScope() -> String? {
        let environment = ProviderRegistry.makeEnvironment(
            base: self.environmentBase, provider: .claude, settings: self.settings, tokenOverride: nil)
        if let identity = Self.activeClaudeAccountIdentity(environment: environment) {
            let account = "claude-account:\(identity)"
            return self.claudeCredentialNotificationScopes[account] ?? account
        }
        guard let witness = self.nativeClaudeCredentialPresentationScope,
              witness.source == self.settings.claudeUsageDataSource.rawValue,
              witness.profile == self.nativeClaudeCredentialProfileIdentifier else { return nil }
        return witness.scope
    }

    var nativeClaudeCredentialProfileIdentifier: String {
        // Provider-specific by design: Claude OAuth profiles bind anonymous credential failures to the fetched account.
        let environment = ProviderRegistry.makeEnvironment(
            base: self.environmentBase, provider: .claude, settings: self.settings, tokenOverride: nil)
        return ClaudeOAuthCredentialsStore.credentialsProfileIdentifier(environment: environment)
    }

    func nativeServiceCardModel(for provider: UsageProvider) -> UsageMenuCardView.Model {
        self.nativeServicePresentation(for: provider).model
    }

    func nativeServiceGauge(for provider: UsageProvider) -> ComputeGauge.State {
        self.nativeServicePresentation(for: provider).gauge
    }
}

extension SettingsStore {
    func nativeTokenAccountOptions(for provider: UsageProvider) -> [NativeAccountOption] {
        let accounts = self.tokenAccounts(for: provider)
        guard !accounts.isEmpty else { return [] }
        let support = TokenAccountSupportCatalog.support(for: provider)
        var options: [NativeAccountOption] = []
        if support?.selectedAccountRequiresManualCookieSource == true || support?.passiveSourceModes.isEmpty == false {
            options.append(NativeAccountOption(id: "automatic", title: L("Automatic")))
        }
        options += accounts.enumerated().map { index, account in
            NativeAccountOption(
                id: account.id.uuidString,
                title: self.hidePersonalInfo
                    ? L("Account %@", String(index + 1)) : account.label)
        }
        return options
    }
}

extension UsageStore {
    func selectNativeTokenAccount(_ accountID: UUID?, for provider: UsageProvider) {
        let accounts = self.settings.tokenAccounts(for: provider)
        let support = TokenAccountSupportCatalog.support(for: provider)
        if let accountID {
            guard let index = accounts.firstIndex(where: { $0.id == accountID }) else { return }
            if let passive = support?.passiveSourceModes,
               passive.contains(self.settings.providerConfig(for: provider)?.source ?? .auto),
               let source = ProviderDescriptorRegistry.descriptor(for: provider).fetchPlan.sourceModes
                   .first(where: { !passive.contains($0) })
            {
                self.settings.updateProviderConfig(provider: provider) { $0.source = source }
            }
            self.settings.setActiveTokenAccountIndex(index, for: provider)
            self.activateCachedTokenAccountSnapshot(provider: provider, accountID: accountID)
        } else {
            guard support?.selectedAccountRequiresManualCookieSource == true
                || support?.passiveSourceModes.isEmpty == false else { return }
            self.settings.updateProviderConfig(provider: provider) { entry in
                entry.cookieSource = .auto
                entry.source = support?.passiveSourceModes.first ?? .auto
            }
            self.reconcileSelectedTokenAccountSnapshotBeforeRefresh(provider: provider, accounts: accounts)
        }
    }
}
