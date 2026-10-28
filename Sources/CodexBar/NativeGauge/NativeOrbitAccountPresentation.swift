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
    /// False when `label` only stands in with the service's name: nothing identifies this login.
    var isNamed = true
    /// The plan as the menu names it ("Claude Max 20x", "Pro 5x", "Plus").
    var plan: String?
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
    /// The token and spend corners show a remembered reading measured at this time until the live one publishes.
    var usageLastKnownAt: Date?
    /// How much of a window is left when its fuel light comes on.
    var fuelReserve: NativeOrbitWarningSignals.FuelReserve = .standard
    /// The dial's lit warning lights the store can see (the popup adds its own: quota and switching).
    var warnings: [NativeOrbitWarningLight] = []
}

/// Account presentations remembered between the callers of `UsageStore.nativeOrbitAccounts(for:)`.
@MainActor
final class NativeOrbitAccountsMemo {
    struct Entry {
        let accounts: [NativeOrbitAccountPresentation]
        let builtAt: Date
    }

    /// Bumped when an input of the provider's entry changes.
    @MainActor
    @Observable
    final class Generation {
        fileprivate(set) var value: UInt64 = 0
    }

    /// How long an entry stands in for a fresh build while none of its inputs changes. Its metrics and warnings also
    /// read the clock; none of them moves faster than this.
    static let lifetime: TimeInterval = 5

    var entries: [UsageProvider: Entry] = [:]
    private var generations: [UsageProvider: Generation] = [:]

    func generation(_ provider: UsageProvider) -> Generation {
        if let generation = self.generations[provider] { return generation }
        let generation = Generation()
        self.generations[provider] = generation
        return generation
    }

    func forget(_ provider: UsageProvider) {
        self.entries[provider] = nil
        self.generation(provider).value &+= 1
    }
}

extension UsageStore {
    /// The menu bar, automatic switching and each popover ask for the same rows after every change, so one build
    /// serves them all. A change to anything the build read discards it.
    func nativeOrbitAccounts(for provider: UsageProvider) -> [NativeOrbitAccountPresentation] {
        let memo = self.nativeOrbitAccountsMemo
        let now = Date()
        if let entry = memo.entries[provider],
           (0..<NativeOrbitAccountsMemo.lifetime).contains(now.timeIntervalSince(entry.builtAt))
        {
            // A reader served the remembered rows observes their generation in place of the inputs they were built
            // from. A reader that builds observes those inputs itself, exactly as without the memo.
            _ = memo.generation(provider).value
            return entry.accounts
        }
        // Observers re-read on a later turn, so a rebuild always sees the change that discarded the last one.
        let accounts = withObservationTracking {
            self.buildNativeOrbitAccounts(for: provider)
        } onChange: { [weak memo] in
            if Thread.isMainThread {
                MainActor.assumeIsolated { memo?.forget(provider) }
            } else {
                Task { @MainActor [weak memo] in memo?.forget(provider) }
            }
        }
        memo.entries[provider] = .init(accounts: accounts, builtAt: now)
        return accounts
    }

    /// Rendering reads only cached inventories and their verified snapshots; it never selects or fetches an account.
    private func buildNativeOrbitAccounts(for provider: UsageProvider) -> [NativeOrbitAccountPresentation] {
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
                    faultScope: Self.warningTokenAccountDiscriminator(account) ?? "default",
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
                selection: .none,
                faultScope: "default")]
        }
        let accounts = Self.nativeOrbitCodexAccountsWithoutImportedCopies(projection.visibleAccounts)
        let labels = Self.nativeOrbitCodexLabels(accounts, hidePersonalInfo: self.settings.hidePersonalInfo)
        let uniqueIDs = Dictionary(
            grouping: accounts,
            by: \.id).filter { $0.value.count == 1 }
        let contexts = accounts.compactMap { account -> NativeOrbitCodexAccountContext? in
            guard uniqueIDs[account.id] != nil else { return nil }
            let active = account.isLive && account.id == projection.liveVisibleAccountID
            let record = self.nativeCodexPresentationRecord(for: account)
            let ownsLive = active && self.lastCodexUsagePublicationGuard.map {
                Self.codexScopedRefreshGuardsMatchAccount($0, Self.codexScopedRefreshGuard(for: account))
            } == true
            // Provider-specific by design: Only a verified active Codex owner can use the current provider reading.
            let snapshot = self.nativeCodexPresentationSnapshot(
                for: account, live: ownsLive ? self.snapshots[.codex] : nil, record: record)
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
        let localUsages = self.nativeOrbitCodexResolvedLocalUsages(contexts.map {
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
                credits: context.ownsLive ? self.credits ?? context.record?.credits : context.record?.credits,
                history: context.history,
                // Provider-specific by design: only a reconciled Codex account can select its credential scope.
                selection: .codex(account),
                // Its own visible account's fetch outcomes (`handleCodexCredentialOutcome`).
                faultScope: Self.nativeCodexFaultScope(account.id),
                extraWarnings: account.authenticationHealthLabel == nil ? [] : [Self.nativeCodexMissingAuthLight],
                autoSwitchEligible: !context.active && !account
                    .isLive && (account.storedAccountID != nil || context.verifiedProfileOwner)
                    && account.authenticationHealthLabel == nil && context.record?.snapshot != nil
                    && context.record?.error == nil,
                autoSwitchWindows: context.snapshot.map { [$0.primary, $0.secondary] } ?? [],
                localUsage: localUsages[account.id]?.usage,
                usageLastKnownAt: localUsages[account.id]?.lastKnownAt,
                accountUsage: context.record?.accountUsageHistory?.tokenSnapshot(),
                accountUsageHistory: context.record?.accountUsageHistory)
        }
        return Self.nativeOrbitOrdered(rows)
    }

    /// Each column's name: its email, or "Account N" in privacy mode. Only when another shown column has the same
    /// email does it add the workspace, or failing a distinct workspace name its number. Counted over the columns
    /// shown, so a hidden imported copy never adds anything, and never a hash.
    static func nativeOrbitCodexLabels(
        _ accounts: [CodexVisibleAccount],
        hidePersonalInfo: Bool) -> [String: String]
    {
        let ordinals = CodexAccountSwitcherLabeling.ordinals(for: accounts)
        func number(_ account: CodexVisibleAccount) -> String {
            CodexAccountSwitcherLabeling.accountLabel(ordinal: ordinals[account.id])
        }
        func workspace(_ account: CodexVisibleAccount) -> String? {
            guard let name = account.workspaceLabel?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
                  name.compare("Personal", options: .caseInsensitive) != .orderedSame,
                  !name.contains("@")
            else { return nil }
            return name
        }
        let emails = Dictionary(grouping: accounts) { CodexIdentityResolver.normalizeEmail($0.email) ?? "" }
        return accounts.reduce(into: [:]) { labels, account in
            let email = account.email.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !hidePersonalInfo, !email.isEmpty else {
                labels[account.id] = number(account)
                return
            }
            let peers = emails[CodexIdentityResolver.normalizeEmail(account.email) ?? ""] ?? []
            guard peers.count > 1 else {
                labels[account.id] = email
                return
            }
            let name = workspace(account)
            let distinct = name != nil && peers.count(where: { workspace($0) == name }) == 1
            labels[account.id] = "\(email) · \(distinct ? name ?? "" : number(account))"
        }
    }

    private static let nativeCodexMissingAuthLight = NativeOrbitWarningLight(
        .signIn,
        .critical,
        "This saved Codex login has no credentials. Re-authenticate it.",
        action: .settings)

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
            // A switch keeps every column as it was until claude-swap's list names the new active row: each reading
            // here is tied to its own slot, and the ambient one also to its email and organization, so none can land
            // on the wrong column meanwhile.
            let ambient = self.nativeOrbitClaudeOwnedAmbientSnapshot(for: account)
            let snapshot = self.nativeOrbitClaudePresentationSnapshot(for: account, ambient: ambient)
            let localUsage = self.nativeOrbitClaudeResolvedLocalUsage(account)
            let warnings = self.nativeOrbitClaudeSwapWarnings(account)
            let displayError = account.usesLastKnownUsage && ambient == nil
                ? error ?? L(
                    "claude_showing_last_known_usage",
                    account.snapshot?.updatedAt.formatted(date: .abbreviated, time: .shortened) ?? "—") : error
            var row = self.nativeOrbitAccount(
                // Provider-specific by design: ClaudeSwap supplies this Claude row's usage and activation identity.
                provider: .claude,
                id: "\(account.id.source):\(account.id.opaqueID)",
                label: ClaudeSwapAccountMenuDisplay.label(
                    for: account,
                    hidePersonalInfo: self.settings.hidePersonalInfo),
                email: account.accountEmail,
                isActive: NativeAccountActivationVerification.claudeOwnsLogin(
                    account.id, accounts: self.claudeSwapAccountSnapshots),
                canActivate: account.canActivate,
                snapshot: snapshot,
                error: displayError,
                history: self.nativeOrbitClaudeHistory(
                    account,
                    ambient: ambient),
                selection: .claudeSwap(account),
                // claude-swap owns this row's fetching; its own report lights the dial. This Mac's own Claude read can
                // fail (a rotated keychain item it may not read without a prompt) while claude-swap reads the same
                // login, so its faults never light a claude-swap row.
                faultScope: nil,
                extraWarnings: warnings.lights,
                errorExplained: warnings.explained,
                autoSwitchEligible: account.autoSwitchEligible && account.canActivate && !account.usesLastKnownUsage
                    && account.snapshot != nil && !switching && error == nil,
                autoSwitchWindows: snapshot.map { [$0.primary, $0.secondary] } ?? [],
                localUsage: localUsage?.usage,
                usageLastKnownAt: localUsage?.lastKnownAt)
            // Ambient observations enter this owner bucket only through a verified accepted-publication bridge.
            // claude-swap's own reports carry its source label where a plan goes; that names no plan.
            let reportedPlan = snapshot?.loginMethod(for: .claude) == ClaudeSwapAccountProjection.sourceLabel
                ? nil : row.plan
            row.plan = reportedPlan ?? NativeClaudeSwapProfilePlan.plan(email: account.accountEmail)
            return row
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
            selection: .none,
            faultScope: nil)
    }

    private func nativeOrbitAmbientAccount(
        for provider: UsageProvider,
        automatic: Bool = false) -> NativeOrbitAccountPresentation
    {
        let presentation = self.nativeServicePresentation(for: provider)
        let snapshot = self.presentationSnapshot(for: provider)
        _ = self.planUtilizationHistoryRevision
        let history = self.planUtilizationHistorySelection(
            for: provider,
            readOnly: true)
        let isAnonymousSource = Self.nativeOrbitAllowsAnonymousQuotaHistory(for: provider)
            && self.settings.effectiveSelectedTokenAccount(for: provider) == nil
            && snapshot.flatMap { Self.planUtilizationIdentityAccountKey(provider: provider, snapshot: $0) } == nil
        let sourceHistory = isAnonymousSource && self.nativeHistoryAvailable(provider)
            ? (self.planUtilizationHistory[provider.instanceID]?.unscoped ?? [])
            .filter(\.name.isNativeQuotaObservation)
            : history.accountKey == nil ? [] : history.histories
        let reports = self.nativeOrbitAmbientUsageReports(for: provider, snapshot: snapshot)
        // The ambient local report is the remembered one until this launch's first scan publishes.
        let ambientLocal = self.nativeOrbitAmbientResolvedLocalUsage(for: provider)
        let usageLastKnownAt = reports.local.flatMap { local in
            ambientLocal?.lastKnownAt.flatMap { local.snapshot.updatedAt == $0 ? $0 : nil }
        }
        let ambientMetrics = NativeOrbitAccountMetrics.make(
            provider: provider,
            snapshot: snapshot,
            usage: reports.usage,
            now: Date(),
            localUsage: reports.local,
            quotaHistory: sourceHistory)
        // Without an email, the name the service gives the login (a Kimi phone login's nickname).
        let accountName = self.settings.hidePersonalInfo ? nil
            : snapshot?.identity(for: provider.instanceID)?.accountName
        let accountLabel = presentation.model.email.isEmpty
            ? accountName ?? self.metadata(for: provider).displayName
            : presentation.model.email
        return NativeOrbitAccountPresentation(
            id: automatic ? "\(provider.rawValue):automatic"
                : presentation.accountID ?? "\(provider.rawValue):automatic",
            label: automatic ? L("Automatic") : accountLabel,
            email: self.settings.hidePersonalInfo ? nil : presentation.model.email,
            isNamed: automatic || !presentation.model.email.isEmpty || accountName != nil,
            plan: presentation.model.planText,
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
            metrics: ambientMetrics,
            quotaLabels: Self.nativeOrbitQuotaLabels(
                provider: provider,
                snapshot: snapshot),
            quotaWindows: Self.nativeOrbitQuotaWindowMap(
                provider: provider,
                snapshot: snapshot),
            historySourceLabel: isAnonymousSource ? L("Account not recorded") : nil,
            usageLastKnownAt: usageLastKnownAt,
            warnings: self.nativeOrbitWarnings(
                provider: provider,
                faultScope: self.nativeGaugeCredentialScope(for: provider) ?? "default",
                updatedAt: snapshot?.updatedAt,
                metrics: ambientMetrics,
                error: self.userFacingError(for: provider),
                extra: presentation.gauge.health == .authentication
                    ? [NativeOrbitFetchFault.signInLight(self.metadata(for: provider).displayName)]
                    : snapshot == nil ? self.unavailableMessage(for: provider).map {
                        [.init(.unavailableHere, .caution, $0, action: .settings)]
                    } ?? [] : [],
                errorExplained: false,
                snapshot: snapshot,
                history: sourceHistory))
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
        faultScope: String?,
        extraWarnings: [NativeOrbitWarningLight] = [],
        errorExplained: Bool = false,
        autoSwitchEligible: Bool = false,
        autoSwitchWindows: [RateWindow?] = [],
        localUsage: NativeOrbitLocalUsage? = nil,
        usageLastKnownAt: Date? = nil,
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
            localUsage: localUsage,
            quotaHistory: history)
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
            isNamed: label != self.metadata(for: provider).displayName,
            plan: model.planText,
            symbol: "person.crop.circle",
            isActive: isActive,
            canActivate: canActivate,
            gauge: gauge,
            updatedAt: snapshot?.updatedAt,
            history: Self.nativeOrbitHistoryIncludingCurrentSnapshot(
                history, provider: provider, snapshot: historySnapshot, credits: credits),
            odometer: tokens.map { $0.formatted() + " tokens" },
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
                snapshot: historySnapshot),
            usageLastKnownAt: localUsage == nil ? nil : usageLastKnownAt,
            fuelReserve: self.nativeFuelReserve(provider),
            warnings: self.nativeOrbitWarnings(
                provider: provider,
                faultScope: faultScope,
                updatedAt: snapshot?.updatedAt,
                metrics: metrics,
                error: error,
                extra: extraWarnings,
                errorExplained: errorExplained,
                snapshot: snapshot,
                history: history))
    }

    private func nativeOrbitHistory(
        provider: UsageProvider,
        key: String?) -> [PlanUtilizationSeriesHistory]
    {
        _ = self.planUtilizationHistoryRevision
        guard self.nativeHistoryAvailable(provider), let key else { return [] }
        return self.planUtilizationHistory[provider.instanceID]?.accounts[key] ?? []
    }

    /// Whether `provider`'s persisted history is in memory, which can be before the whole load finishes: display
    /// reads use it as soon as its own file is decoded, while writes still wait for every file.
    func nativeHistoryAvailable(_ provider: UsageProvider) -> Bool {
        self.planUtilizationHistoryLoaded || self.planUtilizationHistoryLoadedProviders.contains(provider.instanceID)
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

extension NativeOrbitAccountSelection: Equatable {
    /// A ClaudeSwap slot compares by what identifies and routes it; the row's own fields carry what it shows.
    static func == (lhs: Self, rhs: Self) -> Bool {
        // Provider-specific by design: Selection payloads differ: Codex account values, token IDs and ClaudeSwap
        // routing fields each define equality for their own case.
        switch (lhs, rhs) {
        case let (.codex(left), .codex(right)): left == right
        case let (.token(left), .token(right)): left == right
        case let (.claudeSwap(left), .claudeSwap(right)):
            left.id == right.id && left.displayLabel == right.displayLabel && left.accountEmail == right.accountEmail
                && left.accountOrganizationName == right.accountOrganizationName
                && left.sourceOrganizationID == right.sourceOrganizationID && left.isActive == right.isActive
                && left.canActivate == right.canActivate && left.autoSwitchEligible == right.autoSwitchEligible
                && left.usesLastKnownUsage == right.usesLastKnownUsage && left.error == right.error
                && left.sourceLabel == right.sourceLabel && left.snapshot?.updatedAt == right.snapshot?.updatedAt
        case (.none, .none): true
        default: false
        }
    }
}

/// Equal rows show the same thing; a rebuilt row equal to the shown one keeps the shown one and its preparation.
extension NativeOrbitAccountPresentation: Equatable {}
