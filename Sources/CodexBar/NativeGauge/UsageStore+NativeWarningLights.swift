import CodexBarCore
import Foundation

extension UsageStore {
    // swiftlint:disable function_parameter_count
    /// The warning lights the store can see for one account column: its last failed fetch, its provider's status page,
    /// the age of its reading and how complete its local totals are, plus what its source reported (`extra`). A column
    /// error nothing else explains lights the reading-failed light, so no failure goes unlit.
    func nativeOrbitWarnings(
        provider: UsageProvider,
        faultScope: String?,
        updatedAt: Date?,
        metrics: NativeOrbitAccountMetrics,
        error: String?,
        extra: [NativeOrbitWarningLight],
        errorExplained: Bool,
        snapshot: UsageSnapshot? = nil,
        history: [PlanUtilizationSeriesHistory] = [],
        now: Date = Date()) -> [NativeOrbitWarningLight]
    {
        let name = self.metadata(for: provider).displayName
        var lights = extra + NativeOrbitWarningSignals.account(
            provider: provider,
            snapshot: snapshot,
            metrics: metrics,
            history: history,
            now: now,
            observedAt: updatedAt,
            fuelReserve: self.nativeFuelReserve(provider))
        let system = NativeOrbitSystemSignals.shared
        if system.isOffline == true {
            lights.append(.init(.macOffline, .caution, "This Mac has no network connection."))
        }
        if let change = system.timeZoneChange, now >= change.changedAt,
           now.timeIntervalSince(change.changedAt) < 86400
        {
            lights.append(.init(
                .timeZone,
                .opportunity,
                "Time zone changed from \(change.oldIdentifier) to \(change.newIdentifier)."))
        }
        if system.historyWriteFailures.contains(provider.instanceID) {
            lights.append(.init(.storage, .caution, "Usage history could not be saved."))
        }
        if let folder = NativeOrbitWarningSignals.folderAccess(
            provider: provider,
            configuredPaths: self.settings.antigravityAdditionalProfileHomes,
            unavailablePaths: NativeFolderAccessStore.shared.unavailablePaths)
        { lights.append(folder) }
        let notificationsEnabled = self.settings.quotaWarningNotificationsEnabled
            || self.settings.sessionQuotaNotificationsEnabled || self.settings.predictivePaceWarningNotificationsEnabled
        if notificationsEnabled, system.notificationsDenied == true {
            lights.append(.init(
                .notifications,
                .caution,
                "macOS has disabled CodexBar notifications.",
                action: .notificationSettings))
        }
        if self.settings.refreshFrequency == .manual {
            lights.append(.init(.autoRefreshOff, .opportunity, "Usage refresh is set to Manual.", action: .settings))
        }
        if let started = self.nativeWarningRefreshStartedAt[provider.instanceID], now.timeIntervalSince(started) > 120 {
            lights.append(.init(.refreshStuck, .caution, "Refresh has taken more than two minutes."))
        }
        if let faultScope {
            let key = CredentialNotificationKey(provider: provider, account: faultScope)
            if let fault = self.nativeFetchFaults[key] { lights.append(fault) }
            if self.nativeAuthenticationFailures.contains(key) {
                lights.append(NativeOrbitFetchFault.signInLight(name))
            }
        }
        lights += NativeOrbitStatusWarningSignals.lights(
            provider: provider,
            status: self.status(for: provider),
            components: self.statusComponents(for: provider),
            fetchFailed: self.settings.statusChecksEnabled && self.nativeStatusFetchFailures
                .contains(provider.instanceID),
            recentModels: Set((metrics.usageScope == .account ? metrics.usage?.daily ?? [] : [])
                .flatMap { $0.modelsUsed ?? [] }),
            now: now)
        if let updatedAt, let limit = self.nativeOldReadingAge, now.timeIntervalSince(updatedAt) > limit,
           !lights.contains(where: { $0.kind == .oldReading })
        {
            lights.append(.init(
                .oldReading,
                .caution,
                "Showing a reading from \(NativeOrbitTooltip.moment(updatedAt, now: now)).",
                action: .refresh,
                tooltipDetail: "Last reading: \(NativeOrbitTooltip.moment(updatedAt, now: now))."))
        }
        let explaining: Set<NativeOrbitWarningLight.Kind> = [
            .signIn, .outage, .usageFailing, .rateLimited, .unreachable, .unknownError, .helper, .switching,
            .oldReading, .apiChanged, .botCheck, .insecure, .keychain, .browserSession, .wrongAccount,
            .permission, .unavailableHere,
        ]
        if let error = error?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty, !errorExplained,
           !lights.contains(where: { explaining.contains($0.kind) })
        {
            lights.append(.init(.readFailed, .caution, "Usage refresh failed.", action: .refresh))
        }
        return NativeOrbitWarningLight.reconciled(lights)
    }

    // swiftlint:enable function_parameter_count

    /// The timer publishes an observation when the threshold crosses, even when no other fetch has completed.
    func beginNativeWarningRefresh(_ provider: UsageProvider) {
        self.endNativeWarningRefresh(provider)
        let started = Date()
        self.nativeWarningRefreshStartedAt[provider.instanceID] = started
        self.nativeWarningRefreshTimeoutTasks[provider.instanceID] = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(120)) } catch { return }
            guard let self, self.nativeWarningRefreshStartedAt[provider.instanceID] == started else { return }
            self.nativeWarningSlowRefreshProviders.insert(provider.instanceID)
        }
    }

    func endNativeWarningRefresh(_ provider: UsageProvider) {
        self.nativeWarningRefreshTimeoutTasks.removeValue(forKey: provider.instanceID)?.cancel()
        self.nativeWarningRefreshStartedAt.removeValue(forKey: provider.instanceID)
        self.nativeWarningSlowRefreshProviders.remove(provider.instanceID)
    }

    /// The provider's quota warning thresholds, as its notifications use them, set where the fuel light comes on.
    func nativeFuelReserve(_ provider: UsageProvider) -> NativeOrbitWarningSignals.FuelReserve {
        .init(
            thresholds: self.settings.resolvedQuotaWarningThresholds(provider: provider, window: .session),
            weekly: self.settings.resolvedQuotaWarningThresholds(provider: provider, window: .weekly))
    }

    /// Extra-usage spend this close to its cap lights the spend-cap light amber; at the cap, red.
    static let spendCapCaution = 0.9

    /// Where an ambient refresh's outcome lights its column: for Codex, the live visible account it measured; for every
    /// other provider, the credential scope it was recorded under (nil keeps that scope).
    func nativeAmbientFaultScope(_ provider: UsageProvider) -> String? {
        // Provider-specific by design: Codex columns follow visible accounts (see `nativeCodexFaultScope`).
        guard provider == .codex, let live = self.settings.codexVisibleAccountProjection.liveVisibleAccountID
        else { return nil }
        return Self.nativeCodexFaultScope(live)
    }

    /// A reading older than this is old: three refresh intervals, and never under 15 minutes, which also covers
    /// claude-swap's own pacing of idle accounts. Adaptive refresh changes its interval as activity does, so its
    /// readings are never old before its slowest refresh would be overdue. Manual refresh never calls a reading old.
    var nativeOldReadingAge: TimeInterval? {
        switch self.settings.refreshFrequency {
        case .manual:
            nil
        case .adaptive, .adaptiveAgentAware:
            max(NativeOrbitWarningSignals.maximumQuotaAge, 3 * (self.normalRefreshIntervalForHeuristics() ?? 0))
        default:
            max(15 * 60, 3 * (self.settings.refreshFrequency.seconds ?? 10 * 60))
        }
    }

    /// A read of this Mac's usage logs that stopped short (a missing sidecar, an exhausted scan budget, rows that
    /// failed
    /// to decode) leaves every token and spend total a lower bound. Provider-reported statistics also call themselves
    /// partial while their day accumulates; that is not a failed read, so only the local reports count.
    nonisolated static func nativeOrbitTotalsArePartial(_ metrics: NativeOrbitAccountMetrics) -> Bool {
        [metrics.localCostUsage?.snapshot, metrics.primaryLocalUsage?.snapshot]
            .contains { $0?.historyScanIsPartial == true }
    }

    /// What claude-swap reported about one of its accounts, as lights.
    func nativeOrbitClaudeSwapWarnings(
        _ account: ProviderAccountUsageSnapshot,
        now: Date = Date()) -> (lights: [NativeOrbitWarningLight], explained: Bool)
    {
        var lights: [NativeOrbitWarningLight] = []
        var explained = false
        switch account.condition {
        case .ok:
            break
        case .credentialProblem:
            switch account.credentialIssue {
            case .keychain:
                lights.append(.init(
                    .keychain,
                    .caution,
                    "This account’s Keychain access is blocked.",
                    action: .settings))
            case .wrongAccount:
                lights.append(.init(
                    .wrongAccount,
                    .caution,
                    "The live login belongs to another account.",
                    action: .settings))
            case .signIn, nil:
                lights.append(.init(.signIn, .critical, "This account’s saved login needs attention."))
            }
        case .usageUnavailable:
            if account.snapshot == nil {
                lights.append(.init(
                    .readFailed,
                    .caution,
                    "claude-swap could not read usage.",
                    action: .refresh))
            }
        case .notApplicable:
            explained = true
        case .unrecognized:
            lights.append(.init(.readFailed, .caution, "claude-swap reported an unknown status."))
        }
        if account.usesLastKnownUsage || (account.condition == .usageUnavailable && account.snapshot != nil),
           let measured = account.snapshot?.updatedAt
        {
            lights.append(.init(
                .oldReading,
                .caution,
                "Last successful reading: \(NativeOrbitTooltip.moment(measured, now: now)).",
                action: .refresh,
                tooltipDetail: "Last reading: \(NativeOrbitTooltip.moment(measured, now: now))."))
        }
        if let fault = self.nativeClaudeSwapFault, fault.kind == .update {
            lights.append(fault)
        } else if self.claudeSwapLastError != nil {
            lights.append(.init(.helper, .caution, "claude-swap is not responding.", action: .settings))
        }
        if self.claudeSwapTransientState.lastErrorAccountID == account.id,
           self.claudeSwapTransientState.lastError != nil
        {
            lights.append(.init(
                .switching,
                .caution,
                "Account switch failed.",
                tooltipDetail: "Account switch failed."))
        }
        return (lights, explained)
    }
}
