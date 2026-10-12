import CodexBarCore
import CryptoKit
import Foundation

enum NativeOrbitAccountSelection {
    case codex(CodexVisibleAccount)
    case token(UUID?)
    case claudeSwap(ProviderAccountUsageSnapshot)
    case none
}

private struct NativeOrbitCodexAccountContext {
    let account: CodexVisibleAccount
    let active: Bool
    let ownsLive: Bool
    let record: CodexAccountUsageSnapshot?
    let snapshot: UsageSnapshot?
    let error: String?
    let verifiedProfileOwner: Bool
    let history: [PlanUtilizationSeriesHistory]
}

struct NativeOrbitAccountPresentation: Identifiable {
    let id: String
    let label: String
    let email: String?
    var symbol: String
    let isActive: Bool
    let canActivate: Bool
    let gauge: ComputeGauge.State
    let updatedAt: Date?
    let history: [PlanUtilizationSeriesHistory]
    let odometer: String?
    let odometerHelp: String?
    let statusText: String?
    let selection: NativeOrbitAccountSelection
    var autoSwitchEligible: Bool = false
    var autoSwitchWindows: [RateWindow?] = []
    var metrics: NativeOrbitAccountMetrics = .empty
    var quotaLabels: [String: String] = [:]
    var quotaWindows: [String: RateWindow] = [:]
    var historySourceLabel: String?
}

extension UsageStore {
    /// Rendering reads only cached inventories and their verified snapshots; it never selects or fetches an account.
    func nativeOrbitAccounts(for provider: UsageProvider) -> [NativeOrbitAccountPresentation] {
        // Provider-specific by design: Codex reconciliation and ClaudeSwap own their distinct account inventories.
        if provider == .codex, let projection = self.nativeCodexAccountProjection {
            return self.nativeOrbitCodexAccounts(projection)
        }
        if provider == .claude, self.nativeClaudeSwapOwnsPresentation {
            return self.nativeOrbitClaudeSwapAccounts()
        }
        let accounts = self.settings.tokenAccounts(for: provider)
        if !accounts.isEmpty {
            let cached = self.validTokenAccountSnapshots(
                provider: provider,
                accounts: accounts)
            let selected = self.settings.effectiveSelectedTokenAccount(for: provider)?.id
            let uniqueIDs = Dictionary(
                grouping: accounts,
                by: \.id).filter { $0.value.count == 1 }
            var rows = accounts.enumerated().compactMap { index, account -> NativeOrbitAccountPresentation? in
                guard uniqueIDs[account.id] != nil else { return nil }
                let matches = cached.filter { $0.id == account.id }
                let record = matches.count == 1 ? matches.first : nil
                // This is the existing token-account history identity; never adopt an unscoped bucket while rendering.
                let historyKey = Self.nativeOrbitDigest(
                    "\(provider.rawValue):token-account:\(account.id.uuidString.lowercased())")
                return self.nativeOrbitAccount(
                    provider: provider,
                    id: account.id.uuidString,
                    label: self.settings.hidePersonalInfo ? L("Account %@", String(index + 1)) : account.displayName,
                    email: record?.snapshot?.accountEmail(for: provider),
                    isActive: false,
                    canActivate: false,
                    snapshot: record?.snapshot,
                    error: record?.error,
                    history: self.nativeOrbitHistory(
                        provider: provider,
                        key: historyKey),
                    selection: .none,
                    localUsage: self.nativeOrbitCachedUsageReport(for: provider, tokenAccount: account))
            }
            if self.settings.nativeTokenAccountOptions(for: provider).contains(where: { $0.id == "automatic" }) {
                rows.append(self.nativeOrbitAutomaticAccount(for: provider, usesAmbientSource: selected == nil))
            }
            return Self.nativeOrbitOrdered(rows)
        }
        return Self.nativeOrbitOrdered([self.nativeOrbitAmbientAccount(for: provider)])
    }

    func nativeOrbitCodexAccounts(_ projection: CodexVisibleAccountProjection) -> [NativeOrbitAccountPresentation] {
        guard !projection.visibleAccounts.isEmpty else {
            return [self.nativeOrbitAccount(
                // Provider-specific by design: An empty Codex inventory must not inherit another account's usage.
                provider: .codex,
                id: "codex:automatic",
                label: self.metadata(for: .codex).displayName,
                email: nil,
                isActive: false,
                canActivate: false,
                snapshot: nil,
                error: nil,
                history: [],
                selection: .none)]
        }
        let accounts = Self.nativeOrbitCodexAccountsWithoutImportedCopies(projection.visibleAccounts)
        let labels = CodexAccountSwitcherLabeling.labels(
            for: accounts,
            hidePersonalInfo: self.settings.hidePersonalInfo)
        let uniqueIDs = Dictionary(
            grouping: accounts,
            by: \.id).filter { $0.value.count == 1 }
        let contexts = accounts.compactMap { account -> NativeOrbitCodexAccountContext? in
            guard uniqueIDs[account.id] != nil else { return nil }
            let active = account.isLive && account.id == projection.liveVisibleAccountID
            let matches = self.codexAccountSnapshots.filter {
                $0.id == account.id && Self.codexPriorSnapshotAccountMatches(
                    $0.account,
                    account: account)
            }
            let record = matches.count == 1 ? matches.first : nil
            let ownsLive = active && self.lastCodexUsagePublicationGuard.map {
                Self.codexScopedRefreshGuardsMatchAccount($0, Self.codexScopedRefreshGuard(for: account))
            } == true
            // Provider-specific by design: Only a verified active Codex owner can use the current provider reading.
            let snapshot = ownsLive ? self.snapshots[.codex] : record?.snapshot
            let error = ownsLive ? self.userFacingError(for: .codex)
                : CodexUIErrorMapper.userFacingMessage(record?.error)
            let email = CodexIdentityResolver.normalizeEmail(account.email)
            let workspace = CodexOpenAIWorkspaceResolver.normalizeWorkspaceAccountID(account.workspaceAccountID)
            let identity: CodexIdentity = if let workspace {
                .providerAccount(id: workspace)
            } else if let email {
                .emailOnly(normalizedEmail: email)
            } else {
                .unresolved
            }
            let verifiedProfileOwner: Bool = if case .profileHome = account.selectionSource {
                workspace != nil && email != nil && CodexAuthFingerprint.normalize(account.authFingerprint) != nil
            } else {
                false
            }
            let ambiguousEmail = workspace == nil && accounts.count {
                CodexIdentityResolver.normalizeEmail($0.email) == email
            } > 1
            let historyKey = ambiguousEmail ? nil : CodexHistoryOwnership.canonicalKey(for: identity)
            return NativeOrbitCodexAccountContext(
                account: account,
                active: active,
                ownsLive: ownsLive,
                record: record,
                snapshot: snapshot,
                error: error,
                verifiedProfileOwner: verifiedProfileOwner,
                history: self.nativeOrbitCodexHistory(
                    account: account,
                    projection: projection,
                    snapshot: snapshot,
                    canonicalKey: historyKey))
        }
        // Every account's own window evidence is needed before any account can claim a shared local session.
        let localUsages = self.nativeOrbitCodexLocalUsages(contexts.map {
            (account: $0.account, history: $0.history, snapshot: $0.snapshot)
        })
        let rows = contexts.map { context in
            let account = context.account
            return self.nativeOrbitAccount(
                // Provider-specific by design: Codex rows retain their own identity, credits, and history owner.
                provider: .codex,
                id: account.id,
                label: labels[account.id] ?? account.menuDisplayName,
                email: account.email,
                isActive: context.active,
                canActivate: !context.active && !account.isLive && account.authFingerprint != nil
                    && account.authenticationHealthLabel == nil,
                snapshot: context.snapshot,
                error: context.error ?? account.authenticationHealthLabel,
                credits: context.ownsLive ? self.credits : context.record?.credits,
                history: context.history,
                // Provider-specific by design: only a reconciled Codex account can select its credential scope.
                selection: .codex(account),
                autoSwitchEligible: !context.active && !account
                    .isLive && (account.storedAccountID != nil || context.verifiedProfileOwner)
                    && account.authenticationHealthLabel == nil && context.record?.snapshot != nil
                    && context.record?.error == nil,
                autoSwitchWindows: context.snapshot.map { [$0.primary, $0.secondary] } ?? [],
                localUsage: localUsages[account.id],
                accountUsage: context.record?.accountUsageHistory?.tokenSnapshot(),
                accountUsageHistory: context.record?.accountUsageHistory)
        }
        return Self.nativeOrbitOrdered(rows)
    }

    private static func nativeOrbitCodexAccountsWithoutImportedCopies(
        _ accounts: [CodexVisibleAccount]) -> [CodexVisibleAccount]
    {
        accounts.filter { profile in
            guard case .profileHome = profile.selectionSource,
                  profile.storedAccountID == nil, !profile.isLive,
                  let email = CodexIdentityResolver.normalizeEmail(profile.email) else { return true }
            let workspace = CodexOpenAIWorkspaceResolver.normalizeWorkspaceAccountID(profile.workspaceAccountID)
            let fingerprint = CodexAuthFingerprint.normalize(profile.authFingerprint)
            // Workspace and email survive credential rotation after importing a profile. Without a workspace,
            // require an exact fingerprint as well as email; email alone cannot prove a copied account owner.
            let owners = accounts.filter { candidate in
                guard candidate.storedAccountID != nil,
                      CodexIdentityResolver.normalizeEmail(candidate.email) == email,
                      CodexOpenAIWorkspaceResolver
                          .normalizeWorkspaceAccountID(candidate.workspaceAccountID) == workspace
                else { return false }
                if workspace != nil { return true }
                return fingerprint != nil && CodexAuthFingerprint.normalize(candidate.authFingerprint) == fingerprint
            }
            return owners.count != 1
        }
    }

    private func nativeOrbitClaudeSwapAccounts() -> [NativeOrbitAccountPresentation] {
        _ = self.claudeSwapRevision
        let accounts = self.claudeSwapAccountSnapshots.filter {
            // Provider-specific by design: This inventory belongs to ClaudeSwap's Claude account adapter.
            $0.provider == .claude && $0.id.source == ClaudeSwapAccountProjection.sourceName
        }
        let uniqueIDs = Dictionary(
            grouping: accounts,
            by: \.id).filter { $0.value.count == 1 }
        let rows = accounts.compactMap { account -> NativeOrbitAccountPresentation? in
            guard uniqueIDs[account.id] != nil else { return nil }
            let switching = self.claudeSwapTransientState.switchingAccountID != nil
                || self.claudeSwapTransientState.switchPhase != nil
            let error = ClaudeSwapAccountProjection.displayError(
                accountError: account.error,
                adapterError: self.claudeSwapLastError,
                switchError: self.claudeSwapTransientState.lastErrorAccountID == account.id
                    ? self.claudeSwapTransientState.lastError : nil)
            let ambient = switching ? nil : self.nativeOrbitClaudeOwnedAmbientSnapshot(for: account)
            let snapshot = switching ? nil : Self.nativeOrbitClaudeMergedSnapshot(
                adapter: account.snapshot,
                ambient: ambient)
            let displayError = account.usesLastKnownUsage && ambient == nil
                ? error ?? L(
                    "claude_showing_last_known_usage",
                    account.snapshot?.updatedAt.formatted(date: .abbreviated, time: .shortened) ?? "—") : error
            return self.nativeOrbitAccount(
                // Provider-specific by design: ClaudeSwap supplies this Claude row's usage and activation identity.
                provider: .claude,
                id: "\(account.id.source):\(account.id.opaqueID)",
                label: ClaudeSwapAccountMenuDisplay.label(
                    for: account,
                    hidePersonalInfo: self.settings.hidePersonalInfo),
                email: account.accountEmail,
                isActive: !switching && NativeAccountActivationVerification.claudeOwnsLogin(
                    account.id, accounts: self.claudeSwapAccountSnapshots),
                canActivate: account.canActivate && !switching,
                snapshot: snapshot,
                error: displayError,
                history: self.nativeOrbitClaudeHistory(
                    account,
                    ambient: ambient),
                selection: .claudeSwap(account),
                autoSwitchEligible: account.autoSwitchEligible && account.canActivate && !account.usesLastKnownUsage
                    && account.snapshot != nil && !switching && error == nil,
                autoSwitchWindows: snapshot.map { [$0.primary, $0.secondary] } ?? [],
                localUsage: switching ? nil : self.nativeOrbitClaudeLocalUsage(account))
            // Ambient observations enter this owner bucket only through a verified accepted-publication bridge.
        }
        return Self.nativeOrbitOrdered(rows)
    }

    private func nativeOrbitAutomaticAccount(
        for provider: UsageProvider,
        usesAmbientSource: Bool) -> NativeOrbitAccountPresentation
    {
        if usesAmbientSource { return self.nativeOrbitAmbientAccount(for: provider, automatic: true) }
        // A saved account owns ambient usage while selected. The dormant automatic source has no verified cache.
        return self.nativeOrbitAccount(
            provider: provider,
            id: "\(provider.rawValue):automatic",
            label: L("Automatic"),
            email: nil,
            isActive: false,
            canActivate: false,
            snapshot: nil,
            error: nil,
            history: [],
            selection: .none)
    }

    private func nativeOrbitAmbientAccount(
        for provider: UsageProvider,
        automatic: Bool = false) -> NativeOrbitAccountPresentation
    {
        let presentation = self.nativeServicePresentation(for: provider, includeModelScopedWeeklyUsage: true)
        let snapshot = self.presentationSnapshot(for: provider)
        _ = self.planUtilizationHistoryRevision
        let history = self.planUtilizationHistorySelection(
            for: provider,
            readOnly: true)
        let isAnonymousSource = Self.nativeOrbitAllowsAnonymousQuotaHistory(for: provider)
            && self.settings.effectiveSelectedTokenAccount(for: provider) == nil
            && snapshot.flatMap { Self.planUtilizationIdentityAccountKey(provider: provider, snapshot: $0) } == nil
        let sourceHistory = isAnonymousSource && self.planUtilizationHistoryLoaded
            ? (self.planUtilizationHistory[provider.instanceID]?.unscoped ?? [])
            .filter(\.name.isNativeQuotaObservation)
            : history.accountKey == nil ? [] : history.histories
        let reports = self.nativeOrbitAmbientUsageReports(for: provider, snapshot: snapshot)
        let accountLabel = presentation.model.email.isEmpty
            ? self.metadata(for: provider).displayName
            : presentation.model.email
        return NativeOrbitAccountPresentation(
            id: automatic ? "\(provider.rawValue):automatic"
                : presentation.accountID ?? "\(provider.rawValue):automatic",
            label: automatic ? L("Automatic") : accountLabel,
            email: self.settings.hidePersonalInfo ? nil : presentation.model.email,
            symbol: "person.crop.circle",
            isActive: false,
            canActivate: false,
            gauge: presentation.gauge,
            updatedAt: snapshot?.updatedAt,
            history: Self.nativeOrbitHistoryIncludingCurrentSnapshot(
                Self.nativeOrbitHistoryDroppingMachineLocalReceipts(sourceHistory, provider: provider),
                provider: provider,
                snapshot: snapshot),
            odometer: nil,
            odometerHelp: nil,
            statusText: PersonalInfoRedactor.redactEmails(
                in: self.userFacingError(for: provider),
                isEnabled: self.settings.hidePersonalInfo),
            selection: .none,
            metrics: .make(
                provider: provider,
                snapshot: snapshot,
                usage: reports.usage,
                now: Date(),
                localUsage: reports.local),
            quotaLabels: Self.nativeOrbitQuotaLabels(
                provider: provider,
                snapshot: snapshot),
            quotaWindows: Self.nativeOrbitQuotaWindowMap(
                provider: provider,
                snapshot: snapshot),
            historySourceLabel: isAnonymousSource ? L("Account not recorded") : nil)
    }

    // swiftlint:disable:next function_parameter_count
    private func nativeOrbitAccount(
        provider: UsageProvider,
        id: String,
        label: String,
        email: String?,
        isActive: Bool,
        canActivate: Bool,
        snapshot: UsageSnapshot?,
        error: String?,
        credits: CreditsSnapshot? = nil,
        history: [PlanUtilizationSeriesHistory],
        selection: NativeOrbitAccountSelection,
        autoSwitchEligible: Bool = false,
        autoSwitchWindows: [RateWindow?] = [],
        localUsage: NativeOrbitLocalUsage? = nil,
        accountUsage: CostUsageTokenSnapshot? = nil,
        accountUsageHistory: NativeCodexAccountUsageHistory? = nil) -> NativeOrbitAccountPresentation
    {
        // Explicit account context prevents local provider-wide token totals and dashboard adjuncts leaking in.
        let input = self.menuCardInput(
            for: provider,
            context: .account(.init(
                snapshot: snapshot,
                error: error,
                info: AccountInfo(
                    email: email,
                    plan: nil),
                historySelection: .unavailable,
                credits: credits)))
        let model = UsageMenuCardView.Model.make(input)
            .applyingUsageItemVisibility(hiddenItemIDs: self.settings.hiddenUsageItemIDs(for: provider))
        // Provider-specific by design: Codex credit-only lanes use its verified consumer projection.
        let projection = provider == .codex ? CodexConsumerProjection.make(
            surface: .overrideCard,
            context: .init(
                snapshot: snapshot,
                rawUsageError: error,
                liveCredits: credits,
                rawCreditsError: nil,
                liveDashboard: nil,
                rawDashboardError: nil,
                dashboardAttachmentAuthorized: false,
                dashboardRequiresLogin: false,
                now: input.now,
                showOptionalCreditsAndExtraUsage: input.showOptionalCreditsAndExtraUsage)) : nil
        let gauge = NativeUsageGaugeProjection.state(
            provider: provider,
            snapshot: snapshot,
            error: error,
            codexProjection: projection,
            showOptionalCreditsAndExtraUsage: input.showOptionalCreditsAndExtraUsage,
            includeModelScopedWeeklyUsage: true,
            visibleMetrics: model.metrics,
            weeklyPace: input.paceVisible ? input.weeklyPace : nil,
            status: self.statusIndicator(for: provider),
            isEnabled: self.settings.isProviderEnabledCached(
                provider: provider,
                metadataByProvider: self.providerMetadata))
        var metrics = NativeOrbitAccountMetrics.make(
            provider: provider,
            snapshot: snapshot,
            usage: accountUsage ?? snapshot?.costUsage ?? (snapshot == nil ? nil : self.tokenSnapshot(
                fromProviderSnapshot: snapshot,
                provider: provider,
                historyDays: self.settings.costUsageHistoryDays)),
            now: input.now,
            credits: credits,
            localUsage: localUsage)
        metrics.accountUsageHistory = accountUsageHistory
        let total = metrics.summary(days: 30, now: input.now)
        // Provider-specific by design: Codex's verified account-paired credit cap may be the account's only
        // quota gauge. Give history the same source without altering the stored usage identity or timestamp.
        let historySnapshot: UsageSnapshot? = if provider == .codex {
            snapshot.map { CodexExtraUsageCost.attaching(to: $0, credits: credits) }
                ?? CodexExtraUsageCost.providerCost(from: credits).map {
                    UsageSnapshot(primary: nil, secondary: nil, providerCost: $0, updatedAt: $0.updatedAt)
                }
        } else {
            snapshot
        }
        let tokens = total.tokens
        let tokenScope = switch total.usageScope {
        case .account: "Account tokens"
        case .localProfile: "Local profile tokens"
        case .localMachine: "Local machine tokens"
        }
        return NativeOrbitAccountPresentation(
            id: id,
            label: label,
            email: self.settings.hidePersonalInfo ? nil : email,
            symbol: "person.crop.circle",
            isActive: isActive,
            canActivate: canActivate,
            gauge: gauge,
            updatedAt: snapshot?.updatedAt,
            history: Self.nativeOrbitHistoryIncludingCurrentSnapshot(
                history, provider: provider, snapshot: historySnapshot, credits: credits),
            odometer: tokens.map { (total.isPartial ? "≥" : "") + $0.formatted() + " tokens" },
            odometerHelp: tokens == nil ? nil : tokenScope + " · last 30 days"
                + (total.isPartial ? " · Partial data" : ""),
            statusText: PersonalInfoRedactor.redactEmails(
                in: error,
                isEnabled: self.settings.hidePersonalInfo),
            selection: selection,
            autoSwitchEligible: autoSwitchEligible,
            autoSwitchWindows: autoSwitchWindows,
            metrics: metrics,
            quotaLabels: Self.nativeOrbitQuotaLabels(
                provider: provider,
                snapshot: historySnapshot),
            quotaWindows: Self.nativeOrbitQuotaWindowMap(
                provider: provider,
                snapshot: historySnapshot))
    }

    private func nativeOrbitHistory(
        provider: UsageProvider,
        key: String?) -> [PlanUtilizationSeriesHistory]
    {
        _ = self.planUtilizationHistoryRevision
        guard self.planUtilizationHistoryLoaded, let key else { return [] }
        return self.planUtilizationHistory[provider.instanceID]?.accounts[key] ?? []
    }

    private static func nativeOrbitDigest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func nativeOrbitOrdered(
        _ accounts: [NativeOrbitAccountPresentation]) -> [NativeOrbitAccountPresentation]
    {
        let symbols = [
            "person.crop.circle",
            "briefcase",
            "house",
            "leaf",
            "bolt",
            "sparkles",
            "moon",
            "sun.max",
            "star",
            "cloud",
            "flame",
            "paperplane",
            "globe",
            "book",
            "lightbulb",
            "diamond",
            "heart",
            "flag",
            "mountain.2",
            "tree",
        ]
        var used = Set<String>()
        // Allocate in stable identity order so activation changes the column order, never its symbol.
        let decorated = accounts.sorted { $0.id < $1.id }.map { account in
            var row = account
            let offset = Int(Array(SHA256.hash(data: Data(account.id.utf8))).first ?? 0) % symbols.count
            let candidates = (0..<symbols.count).map { symbols[($0 + offset) % symbols.count] }
            row.symbol = candidates.first { !used.contains($0) } ?? "person.crop.circle"
            used.insert(row.symbol)
            return row
        }
        return decorated.sorted {
            if $0.isActive != $1.isActive { return $0.isActive }
            return $0.id < $1.id
        }
    }
}
