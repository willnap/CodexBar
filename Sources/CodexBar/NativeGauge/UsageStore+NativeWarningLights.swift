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
        now: Date = Date()) -> [NativeOrbitWarningLight]
    {
        let name = self.metadata(for: provider).displayName
        var lights = extra
        if let faultScope {
            let key = CredentialNotificationKey(provider: provider, account: faultScope)
            if let fault = self.nativeFetchFaults[key] { lights.append(fault) }
            if self.nativeAuthenticationFailures.contains(key) {
                lights.append(NativeOrbitFetchFault.signInLight(name))
            }
        }
        if let status = self.status(for: provider) {
            let description = status.description?.trimmingCharacters(in: .whitespacesAndNewlines)
            let incident = description.flatMap { $0.isEmpty ? nil : $0 }
            switch status.indicator {
            case .minor:
                lights.append(.init(
                    .providerIncident,
                    .caution,
                    incident.map { "\(name): \($0)" } ?? "\(name) reports degraded service.",
                    action: .statusPage))
            case .major, .critical:
                lights.append(.init(
                    .providerIncident,
                    .critical,
                    incident.map { "\(name): \($0)" } ?? "\(name) reports an outage.",
                    action: .statusPage))
            case .maintenance:
                lights.append(.init(
                    .maintenance,
                    .caution,
                    incident.map { "\(name): \($0)" } ?? "\(name) is under maintenance.",
                    action: .statusPage))
            case .none, .unknown:
                break
            }
        }
        if let updatedAt, let limit = self.nativeOldReadingAge, now.timeIntervalSince(updatedAt) > limit,
           !lights.contains(where: { $0.kind == .oldReading })
        {
            lights.append(.init(
                .oldReading,
                .caution,
                "Showing a reading from \(NativeOrbitTooltip.moment(updatedAt, now: now)).",
                action: .refresh))
        }
        if let spend = metrics.reportedSpend, let fraction = metrics.extraUsageFraction,
           fraction >= Self.spendCapCaution
        {
            let format = FloatingPointFormatStyle<Double>.Currency(code: spend.currencyCode)
            lights.append(.init(
                .spendCap,
                fraction >= 1 ? .critical : .caution,
                "Extra usage is at \(spend.used.formatted(format)) of its \(spend.limit.formatted(format)) cap."))
        }
        if Self.nativeOrbitTotalsArePartial(metrics) {
            lights.append(.init(
                .localLogs,
                .caution,
                "Token and spend totals are partial: reading this Mac’s usage logs stopped short."))
        }
        let explaining: Set<NativeOrbitWarningLight.Kind> = [
            .signIn, .providerIncident, .rateLimited, .offline, .readFailed, .helper, .switching,
            .oldReading,
        ]
        if let error = error?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty, !errorExplained,
           !lights.contains(where: { explaining.contains($0.kind) })
        {
            let line = error.split(whereSeparator: \.isNewline).first.map(String.init) ?? error
            lights.append(.init(.readFailed, .caution, "Couldn’t read usage: \(line)", action: .refresh))
        }
        return NativeOrbitWarningLight.merged(lights)
    }

    // swiftlint:enable function_parameter_count

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
    /// claude-swap's own pacing of idle accounts. Manual refresh never calls a reading old.
    var nativeOldReadingAge: TimeInterval? {
        guard self.settings.refreshFrequency != .manual else { return nil }
        return max(15 * 60, 3 * (self.settings.refreshFrequency.seconds ?? 10 * 60))
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
        let reason = account.error?.split(whereSeparator: \.isNewline).first.map(String.init)
        switch account.condition {
        case .ok:
            break
        case .credentialProblem:
            lights.append(.init(.signIn, .critical, reason ?? "This account’s saved login needs attention."))
        case .usageUnavailable:
            if account.snapshot == nil {
                lights.append(.init(
                    .readFailed,
                    .caution,
                    "claude-swap couldn’t measure this account’s usage.",
                    action: .refresh))
            }
        case .notApplicable:
            explained = true
        case .unrecognized:
            lights.append(.init(.readFailed, .caution, reason ?? "claude-swap reported an unknown status."))
        }
        if account.usesLastKnownUsage || (account.condition == .usageUnavailable && account.snapshot != nil),
           let measured = account.snapshot?.updatedAt
        {
            lights.append(.init(
                .oldReading,
                .caution,
                "claude-swap couldn’t refresh this account; showing usage from " +
                    "\(NativeOrbitTooltip.moment(measured, now: now)).",
                action: .refresh))
        }
        if let error = self.claudeSwapLastError {
            let line = error.split(whereSeparator: \.isNewline).first.map(String.init) ?? error
            lights.append(.init(.helper, .caution, "claude-swap isn’t responding: \(line)", action: .settings))
        }
        if self.claudeSwapTransientState.lastErrorAccountID == account.id,
           let error = self.claudeSwapTransientState.lastError
        {
            lights.append(.init(.switching, .caution, "Switching to this account failed: \(error)"))
        }
        return (lights, explained)
    }
}
