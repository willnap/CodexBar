import CodexBarCore
import Foundation

struct ClaudeOrganizationUsagePublication {
    let owners: [ProviderAccountIdentity: String]
    let bucketTimeZoneIdentifier: String
    let reports: [String: CostUsageTokenSnapshot]

    /// An organization shared by visible rows cannot prove which account owned a transcript request.
    static func owners(for accounts: [ProviderAccountUsageSnapshot]) -> [ProviderAccountIdentity: String] {
        let candidates = accounts.compactMap { account -> (ProviderAccountIdentity, String)? in
            guard account.provider == .claude, account.id.source == ClaudeSwapAccountProjection.sourceName,
                  let organization = account.sourceOrganizationID.flatMap({ UUID(uuidString: $0) })
            else { return nil }
            return (account.id, organization.uuidString.lowercased())
        }
        let counts = Dictionary(
            grouping: candidates,
            by: { $0.1 }).mapValues(\.count)
        return Dictionary(
            candidates.compactMap { id, organization in
                guard counts[organization] == 1 else { return nil }
                return (id, organization)
            },
            uniquingKeysWith: { first, _ in first })
    }
}

enum ClaudeSwapSwitchPhase: Equatable, Sendable {
    case activating
    case reconciling
}

/// External credential transactions must run to completion; configuration changes hide their state but do not
/// cancel the subprocess halfway through a claude-swap transaction.
struct ClaudeSwapTransientState {
    var lastError: String?
    var lastErrorAccountID: ProviderAccountIdentity?
    var switchingAccountID: ProviderAccountIdentity?
    var switchPhase: ClaudeSwapSwitchPhase?
    var task: Task<Void, Never>?
    var configurationGeneration: UInt64 = 0
    var versionProbedPath: String?
    var versionProbeGeneration: UInt64 = 0
    /// A local transcript projection was requested while one was running; run once more when it finishes.
    var localUsageRerunRequested = false
    /// The scheduled list still running, when it was started outside any refresh generation (at launch, or after a
    /// settings change); its result publishes for every refresh, so a refresh moments later joins it.
    var generationFreeList: (token: UUID, startedAt: Date)?
    /// Opt-in launch evidence (`--native-popup-preview-provider`): each list's start, read and outcome, by time.
    var listTimeline: [(String, Date)] = []
}

extension UsageStore {
    /// True when the opt-in claude-swap adapter should run alongside the
    /// ambient Claude refresh. Listing is read-only; explicit account activation
    /// stays external-process-owned and never exposes credentials to CodexBar.
    func shouldFetchClaudeSwapAccounts() -> Bool {
        self.isEnabled(.claude) && self.settings.claudeSwapEnabled &&
            !self.settings.claudeSwapExecutablePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The active claude-swap account's usage snapshot when the adapter owns Claude
    /// account presentation (issue #2731: with two accounts the menu shows adapter
    /// cards while the bar rendered the ambient snapshot, which can have no usable
    /// windows). Returns nil — keep the ambient snapshot — when the adapter is below
    /// its presentation threshold or the active account reports no usable usage.
    ///
    /// A last-known measurement is deliberately not eligible here. Account cards
    /// state a snapshot's age, but the bar icon has no such affordance and
    /// `isStale` tracks provider errors rather than measurement age, so serving
    /// last-known numbers on the bar would present them as current.
    func claudeSwapMenuBarSnapshotOverride(for instanceID: ProviderInstanceID) -> UsageSnapshot? {
        guard instanceID == UsageProvider.claude.instanceID else { return nil }
        guard ClaudeSwapMenuPrecedence.prefersClaudeSwap(
            provider: .claude,
            accountCount: self.claudeSwapAccountSnapshots.count,
            showSingleAccount: self.settings.claudeSwapShowSingleAccount)
        else { return nil }
        guard let active = self.claudeSwapAccountSnapshots.first(where: \.isActive),
              !active.usesLastKnownUsage
        else { return nil }
        return active.snapshot
    }

    func clearClaudeSwapAccountState() {
        let hadState = !self.claudeSwapAccountSnapshots.isEmpty ||
            self.claudeOrganizationUsagePublication != nil ||
            self.claudeSwapLastRefreshAt != nil || self.claudeSwapLastError != nil ||
            self.claudeSwapTransientState.lastError != nil ||
            self.claudeSwapTransientState.lastErrorAccountID != nil ||
            self.claudeSwapTransientState.switchingAccountID != nil ||
            self.claudeSwapTransientState.switchPhase != nil ||
            self.claudeSwapTransientState.versionProbedPath != nil ||
            self.claudeSwapDetectedVersion != nil
        self.claudeSwapRefreshTask?.cancel()
        self.claudeSwapRefreshTask = nil
        self.claudeSwapAccountSnapshots = []
        self.claudeOrganizationUsagePublication = nil
        self.claudeSwapLastRefreshAt = nil
        self.claudeSwapLastError = nil
        self.nativeClaudeSwapFault = nil
        self.claudeSwapTransientState = ClaudeSwapTransientState(
            task: self.claudeSwapTransientState.task,
            configurationGeneration: self.claudeSwapTransientState.configurationGeneration &+ 1,
            versionProbeGeneration: self.claudeSwapTransientState.versionProbeGeneration &+ 1)
        self.claudeSwapDetectedVersion = nil
        if hadState {
            self.claudeSwapRevision &+= 1
            self.persistWidgetSnapshot(reason: "claude-swap-accounts")
        }
    }

    /// Runs the optional adapter independently so it cannot delay the ambient Claude card.
    func scheduleClaudeSwapAccountRefresh(generation: UInt64? = nil) {
        // At launch the provider's start and the first refresh each scheduled a list; restarting the first one made
        // the popup wait for two lists back to back before its columns appeared. A switch always gets its own list.
        if generation != nil, let running = self.claudeSwapTransientState.generationFreeList,
           Date().timeIntervalSince(running.startedAt) < Self.claudeSwapListJoinWindow,
           self.claudeSwapTransientState.switchingAccountID == nil, self.claudeSwapTransientState.switchPhase == nil,
           self.claudeSwapRefreshTask?.isCancelled == false, self.shouldFetchClaudeSwapAccounts()
        {
            return
        }
        self.claudeSwapRefreshTask?.cancel()
        self.claudeSwapTransientState.generationFreeList = nil
        guard self.shouldFetchClaudeSwapAccounts() else {
            self.clearClaudeSwapAccountState()
            return
        }

        let token = generation == nil ? UUID() : nil
        self.claudeSwapTransientState.generationFreeList = token.map { ($0, Date()) }
        self.claudeSwapRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshClaudeSwapAccounts(generation: generation)
            if let token, self.claudeSwapTransientState.generationFreeList?.token == token {
                self.claudeSwapTransientState.generationFreeList = nil
            }
        }
    }

    /// A list started this recently describes the accounts as a refresh scheduled now would.
    static let claudeSwapListJoinWindow: TimeInterval = 15

    /// Whether the ambient Claude login's reading currently measures one of the claude-swap columns (its account and
    /// organization own the active row). Only then can its fetch bring a column up to date on demand.
    var nativeClaudeAmbientMeasuresSwapColumn: Bool {
        self.claudeSwapAccountSnapshots.contains { self.nativeOrbitClaudeOwnedAmbientSnapshot(for: $0) != nil }
    }

    /// Why the ambient reading does or does not measure the active claude-swap column, as flags only (no identity).
    func nativeClaudeAmbientOwnershipDiagnostics() -> [String: String] {
        func organization(_ value: String?) -> String? {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
        let active = self.claudeSwapAccountSnapshots.filter(\.isActive)
        let row = active.count == 1 ? active[0] : nil
        let identity = self.snapshots[.claude]?.identity(for: .claude)
        let rowEmail = CodexIdentityResolver.normalizeEmail(row?.accountEmail)
        let ownsLogin = row.map {
            NativeAccountActivationVerification.claudeOwnsLogin($0.id, accounts: self.claudeSwapAccountSnapshots)
        } ?? false
        return [
            "ambientSnapshot": self.snapshots[.claude] == nil ? "0" : "1",
            "activeRows": String(active.count),
            "activeRowOwnsLogin": ownsLogin ? "1" : "0",
            "emailMatches": rowEmail != nil && rowEmail == CodexIdentityResolver.normalizeEmail(identity?.accountEmail)
                ? "1" : "0",
            "rowHasOrganization": organization(row?.accountOrganizationName) == nil ? "0" : "1",
            "ambientHasOrganization": organization(identity?.accountOrganization) == nil ? "0" : "1",
            "organizationMatches": rowEmail.map {
                Self.nativeOrbitClaudeOwnerOrganization(row?.accountOrganizationName, email: $0)
                    == Self.nativeOrbitClaudeOwnerOrganization(identity?.accountOrganization, email: $0)
            } == true ? "1" : "0",
        ]
    }

    /// A person's explicit refresh of the ClaudeSwap columns. The adapter's list supplies every account, but
    /// claude-swap paces Anthropic's usage API itself and serves a recent measurement instead of fetching again, so
    /// only the ambient login's own fetch can measure the active account on demand, when its reading owns that
    /// column. Both finish before this returns: the ambient pass schedules the list beside its fetch, and a list
    /// replaced by a newer one is followed to it.
    func refreshClaudeSwapColumnsForUser(includingAmbient: Bool) async {
        guard includingAmbient else {
            await self.refreshClaudeSwapAccounts()
            return
        }
        let listBefore = self.claudeSwapRefreshTask
        await self.refreshProviderForUser(.claude)
        var awaitedList = false
        for _ in 0..<3 {
            guard let list = self.claudeSwapRefreshTask, list != listBefore else { break }
            awaitedList = true
            await list.value
            if self.claudeSwapRefreshTask == list { break }
        }
        if !awaitedList, self.shouldFetchClaudeSwapAccounts() {
            await self.refreshClaudeSwapAccounts()
        }
    }

    func refreshClaudeSwapAccounts(generation: UInt64? = nil) async {
        let executablePath = self.settings.claudeSwapExecutablePath
        let configurationGeneration = self.claudeSwapTransientState.configurationGeneration
        let traced = NativeCodexSessionAttributionStore.recordsDiagnostics
        func trace(_ event: String) {
            guard traced else { return }
            self.claudeSwapTransientState.listTimeline.append((
                event + " gen=\(generation.map(String.init) ?? "-")",
                Date()))
        }
        trace("start")
        // The version only labels Settings: probe it after the list publishes, so the columns never wait on it.
        do {
            let list = try await ClaudeSwapAccountReader.readAccountList(executablePath: executablePath)
            trace("read")
            let snapshots = ClaudeSwapAccountProjection.accountSnapshots(
                from: list,
                previousAccounts: ClaudeSwapRetainedUsageStore.previousAccounts(
                    inMemory: self.claudeSwapAccountSnapshots))
            guard self.isCurrentClaudeSwapRefresh(
                executablePath: executablePath,
                generation: generation),
                self.isCurrentClaudeSwapConfiguration(
                    executablePath: executablePath,
                    configurationGeneration: configurationGeneration)
            else {
                trace("discarded")
                return
            }
            trace("published")
            ClaudeSwapRetainedUsageStore.save(snapshots)
            self.claudeSwapAccountSnapshots = snapshots
            self.claudeSwapLastRefreshAt = Date()
            self.claudeSwapLastError = nil
            self.nativeClaudeSwapFault = nil
            self.claudeSwapRevision &+= 1
            self.persistWidgetSnapshot(reason: "claude-swap-accounts")
            await self.probeClaudeSwapVersionIfNeeded(executablePath: executablePath)
            await self.recordNativeClaudeSwapHistory(snapshots)
            // Transcript attribution runs in its own coalesced projection; adapter refreshes cannot cancel it.
            let owners = self.nativeClaudeLocalUsageOwners()
            if !owners.isEmpty, owners != self.claudeOrganizationUsagePublication?.owners {
                self.scheduleNativeClaudeLocalUsageRefresh()
            }
        } catch is CancellationError {
            trace("cancelled")
            return
        } catch {
            trace("failed")
            guard self.isCurrentClaudeSwapRefresh(
                executablePath: executablePath,
                generation: generation)
            else {
                return
            }
            // Retain the last successful snapshots as stale data; the settings
            // pane surfaces the adapter error and last refresh time.
            let message = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            self.nativeClaudeSwapFault = NativeOrbitFetchFault.light(for: error, provider: .claude)
            if self.claudeSwapLastError != message {
                self.claudeSwapLastError = message
                self.claudeSwapRevision &+= 1
            }
            await self.probeClaudeSwapVersionIfNeeded(executablePath: executablePath)
        }
    }

    /// Activates one account through the configured claude-swap executable.
    /// The numeric slot comes from the already validated list payload; requests
    /// are serialized so two credential transactions can never overlap.
    func switchClaudeSwapAccount(
        _ accountID: ProviderAccountIdentity,
        progressDidChange: (@MainActor () -> Void)? = nil)
    {
        guard self.claudeSwapTransientState.task == nil,
              self.shouldFetchClaudeSwapAccounts(),
              accountID.source == ClaudeSwapAccountProjection.sourceName,
              let account = self.claudeSwapAccountSnapshots.first(where: { $0.id == accountID }),
              account.canActivate,
              let accountNumber = Int(accountID.opaqueID),
              accountNumber > 0
        else {
            return
        }

        let executablePath = self.settings.claudeSwapExecutablePath
        let configurationGeneration = self.claudeSwapTransientState.configurationGeneration
        self.claudeSwapTransientState.switchingAccountID = accountID
        self.claudeSwapTransientState.switchPhase = .activating
        self.claudeSwapTransientState.lastError = nil
        self.claudeSwapTransientState.lastErrorAccountID = nil
        self.claudeSwapRevision &+= 1

        self.claudeSwapTransientState.task = Task { @MainActor [weak self] in
            var switchError: String?
            do {
                _ = try await ClaudeSwapAccountReader.switchAccount(
                    executablePath: executablePath,
                    accountNumber: accountNumber)
            } catch {
                switchError = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }

            guard let self else { return }
            if self.isCurrentClaudeSwapConfiguration(
                executablePath: executablePath,
                configurationGeneration: configurationGeneration)
            {
                self.claudeSwapTransientState.lastError = switchError
                self.claudeSwapTransientState.lastErrorAccountID = switchError == nil ? nil : accountID
                self.claudeSwapTransientState.switchPhase = .reconciling
                self.claudeSwapRevision &+= 1
                progressDidChange?()
                // claude-swap's own list names the new active row in a fraction of a second, so it alone settles
                // the switch. The ambient Claude reading (a slower provider fetch) follows once it is over.
                self.scheduleClaudeSwapAccountRefresh()
                // A replacement read still owns reconciliation.
                while self.isCurrentClaudeSwapConfiguration(
                    executablePath: executablePath,
                    configurationGeneration: configurationGeneration),
                    let adapterTask = self.claudeSwapRefreshTask
                {
                    await adapterTask.value
                    if self.claudeSwapRefreshTask == adapterTask { break }
                }
            }
            let isCurrent = self.isCurrentClaudeSwapConfiguration(
                executablePath: executablePath,
                configurationGeneration: configurationGeneration)
            let currentError = isCurrent ? switchError : nil
            self.claudeSwapTransientState.task = nil
            self.claudeSwapTransientState.switchingAccountID = nil
            self.claudeSwapTransientState.switchPhase = nil
            self.claudeSwapTransientState.lastError = currentError
            self.claudeSwapTransientState.lastErrorAccountID = currentError == nil ? nil : accountID
            self.claudeSwapRevision &+= 1
            if isCurrent { progressDidChange?() }
            // Claude Code owns the ambient credential; bring its reading over to the new login.
            if isCurrent { Task { await self.refreshProvider(.claude) } }
        }
        progressDidChange?()
    }

    private func probeClaudeSwapVersionIfNeeded(executablePath: String) async {
        guard self.claudeSwapTransientState.versionProbedPath != executablePath else { return }
        self.claudeSwapTransientState.versionProbeGeneration &+= 1
        let generation = self.claudeSwapTransientState.versionProbeGeneration
        guard let version = await ClaudeSwapAccountReader.readVersion(executablePath: executablePath),
              self.claudeSwapTransientState.versionProbeGeneration == generation,
              self.isCurrentClaudeSwapRefresh(
                  executablePath: executablePath,
                  generation: nil)
        else { return }
        self.claudeSwapTransientState.versionProbedPath = executablePath
        self.claudeSwapDetectedVersion = version
    }

    func isCurrentClaudeSwapRefresh(
        executablePath: String,
        generation: UInt64?) -> Bool
    {
        !Task.isCancelled &&
            self.isCurrentProviderRefreshGeneration(
                .claude,
                generation: generation) &&
            self.isCurrentClaudeSwapConfiguration(executablePath: executablePath)
    }

    func isCurrentClaudeSwapConfiguration(
        executablePath: String,
        configurationGeneration: UInt64? = nil) -> Bool
    {
        self.isEnabled(.claude) && self.settings.claudeSwapEnabled &&
            self.settings.claudeSwapExecutablePath == executablePath &&
            (configurationGeneration == nil ||
                self.claudeSwapTransientState.configurationGeneration == configurationGeneration)
    }
}
