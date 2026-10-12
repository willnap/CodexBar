import CodexBarCore
import CryptoKit
import Foundation

extension UsageStore {
    func nativeOrbitClaudeHistory(
        _ account: ProviderAccountUsageSnapshot,
        ambient: UsageSnapshot?) -> [PlanUtilizationSeriesHistory]
    {
        _ = self.planUtilizationHistoryRevision
        guard self.planUtilizationHistoryLoaded, let key = Self.nativeOrbitClaudeHistoryKey(account) else { return [] }
        // Provider-specific by design: ClaudeSwap uses isolated slot owners and merges only measured Claude identity
        // buckets.
        let buckets = self.planUtilizationHistory[.claude] ?? PlanUtilizationHistoryBuckets()
        var histories = buckets.accounts[key] ?? []
        let email = CodexIdentityResolver.normalizeEmail(account.accountEmail)
        guard email != nil, self.claudeSwapAccountSnapshots.count(where: {
            $0.provider == .claude && CodexIdentityResolver.normalizeEmail($0.accountEmail) == email
        }) == 1 else { return histories }
        // Identity-derived buckets carry their own measured email/organization evidence. Opaque OAuth preferred
        // buckets require the accepted-publication bridge below, never a guess made while rendering.
        for snapshot in [account.snapshot, ambient].compactMap(\.self) {
            guard CodexIdentityResolver.normalizeEmail(snapshot.accountEmail(for: .claude)) == email,
                  let legacy = Self.planUtilizationIdentityAccountKey(provider: .claude, snapshot: snapshot),
                  legacy != key, let fragment = buckets.accounts[legacy] else { continue }
            histories = Self.nativeOrbitMergedHistories(histories, fragment)
        }
        return histories
    }

    nonisolated static func nativeOrbitMergedHistories(
        _ existing: [PlanUtilizationSeriesHistory],
        _ incoming: [PlanUtilizationSeriesHistory]) -> [PlanUtilizationSeriesHistory]
    {
        var result = existing
        for history in incoming {
            if let index = result.firstIndex(where: {
                $0.name == history.name && $0.windowMinutes == history.windowMinutes
            }) {
                result[index] = .init(
                    name: history.name,
                    windowMinutes: history.windowMinutes,
                    entries: self.nativeOrbitMergedRawEntries(history.entries, result[index].entries))
            } else {
                result.append(history)
            }
        }
        return result
    }

    /// Called only after the ambient refresh has resolved and published its exact owner history bucket.
    func bridgeNativeClaudeHistory(
        snapshot: UsageSnapshot,
        histories: [PlanUtilizationSeriesHistory],
        buckets: inout PlanUtilizationHistoryBuckets)
    {
        guard self.settings.nativeDesignEnabled,
              self.claudeSwapTransientState.switchingAccountID == nil,
              self.claudeSwapTransientState.switchPhase == nil,
              let active = self.claudeSwapAccountSnapshots.first(where: \.isActive),
              Self.nativeOrbitClaudeOwnedAmbientSnapshot(
                  account: active, accounts: self.claudeSwapAccountSnapshots, snapshot: snapshot) != nil,
              let key = Self.nativeOrbitClaudeHistoryKey(active) else { return }
        buckets.setHistories(Self.nativeOrbitMergedHistories(buckets.accounts[key] ?? [], histories), for: key)
    }

    nonisolated static func nativeKimiHistoryAccountKey(_ snapshot: UsageSnapshot) -> String? {
        // Provider-specific by design: Kimi's accepted credential owner scopes its rotating OAuth history aliases.
        snapshot.identity(for: .kimi)?.accountID.flatMap(self.nativeKimiHistoryAccountKey(ownerID:))
    }

    private nonisolated static func nativeKimiHistoryAccountKey(ownerID: String) -> String? {
        guard ownerID.hasPrefix("kimi-credential-v1:") else { return nil }
        let digest = ownerID.dropFirst("kimi-credential-v1:".count)
        guard digest.count == 64, digest.allSatisfy(\.isHexDigit) else { return nil }
        return self.nativeOrbitHistoryDigest(Data(("kimi:history-owner:" + ownerID).utf8))
    }

    nonisolated static func mergeVerifiedNativeKimiHistory(
        snapshot: UsageSnapshot,
        into key: String,
        buckets: inout PlanUtilizationHistoryBuckets)
    {
        // Aliases originate in a successful request or a refresh exchange for this login. Never infer continuity
        // from the preferred bucket or from adjacent readings; neither identifies an account.
        // Provider-specific by design: only Kimi's successful credential exchange supplies these verified aliases.
        let aliases = Set((snapshot.identity(for: .kimi)?.historyOwnerAliases ?? [])
            .compactMap(self.nativeKimiHistoryAccountKey(ownerID:))).subtracting([key])
        var histories = buckets.accounts[key] ?? []
        for alias in aliases.sorted() {
            guard let fragment = buckets.accounts.removeValue(forKey: alias) else { continue }
            histories = self.nativeOrbitMergedHistories(fragment, histories)
        }
        if !histories.isEmpty { buckets.setHistories(histories, for: key) }
    }

    /// Earlier builds keyed Kimi history by each rotating access token, before the stable credential owner existed,
    /// so a single login left one small quota-only bucket per token refresh. With exactly one configured Kimi
    /// credential those fragments, which all end before the stable owner's first reading, can only be that login's
    /// own readings: fold them into its bucket. Another credential, or another timeline that records complications
    /// (a distinct current owner), leaves every bucket untouched.
    nonisolated static func nativeKimiFoldedLegacyHistory(
        _ buckets: PlanUtilizationHistoryBuckets,
        credentialCount: Int) -> PlanUtilizationHistoryBuckets?
    {
        guard credentialCount == 1, let key = buckets.preferredAccountKey, let owner = buckets.accounts[key],
              owner.contains(where: \.name.isNativeMetricObservation),
              let ownerStart = owner.flatMap(\.entries).map(\.capturedAt).min() else { return nil }
        var legacy: [String] = []
        for (candidate, histories) in buckets.accounts where candidate != key {
            if histories.contains(where: \.name.isNativeMetricObservation) { return nil }
            let entries = histories.flatMap(\.entries)
            guard !entries.isEmpty,
                  entries.allSatisfy({ $0.capturedAt < ownerStart && $0.historicalPeriod == nil }) else { continue }
            legacy.append(candidate)
        }
        guard !legacy.isEmpty else { return nil }
        var result = buckets
        var merged = owner
        for candidate in legacy.sorted() {
            guard let fragment = result.accounts.removeValue(forKey: candidate) else { continue }
            merged = self.nativeOrbitMergedHistories(merged, fragment)
        }
        result.setHistories(merged, for: key)
        return result
    }

    /// Saved Kimi web accounts plus the ambient credential that produced the stable owner. Two ambient environment
    /// credentials can belong to two logins. Reads configuration and environment only, never the Keychain.
    func nativeKimiConfiguredCredentialCount() -> Int {
        let ambient = [
            KimiSettingsReader.authToken(environment: self.environmentBase),
            KimiSettingsReader.apiKey(environment: self.environmentBase),
        ].compactMap(\.self).count
        // Provider-specific by design: Kimi's legacy per-token history fold needs Kimi's own credential count.
        return self.settings.tokenAccounts(for: .kimi).count + max(1, ambient)
    }

    func foldLegacyNativeKimiHistoryIfNeeded() async {
        guard self.settings.nativeDesignEnabled, self.planUtilizationHistoryLoaded,
              let buckets = self.planUtilizationHistory[.kimi],
              let folded = Self.nativeKimiFoldedLegacyHistory(
                  buckets,
                  credentialCount: self.nativeKimiConfiguredCredentialCount())
        else { return }
        // Provider-specific by design: this one-time migration only rewrites Kimi's own history buckets.
        self.planUtilizationHistory[.kimi] = folded
        self.planUtilizationHistoryRevision &+= 1
        await self.planUtilizationPersistenceCoordinator.enqueue(self.planUtilizationHistory)
    }

    nonisolated static func nativeOrbitQuotaWindows(
        provider: UsageProvider,
        snapshot: UsageSnapshot) -> [(id: String, title: String, window: RateWindow)]
    {
        // Importing each observation must not rebuild metadata for every provider on the main thread.
        let metadata: ProviderMetadata? = ProviderDescriptorRegistry.descriptor(for: provider).metadata
        var lanes: [(String, String, RateWindow?)] = [
            ("primary", metadata?.sessionLabel ?? "Primary", snapshot.primary),
            ("secondary", metadata?.weeklyLabel ?? "Secondary", snapshot.secondary),
            ("tertiary", metadata?.opusLabel ?? "Additional", snapshot.tertiary),
        ]
        // Provider-specific by design: Codex's primary slot can be weekly-only. Resolve its logical source
        // roles before recording, keeping raw observations rather than the display's binding weekly cap.
        if provider == .codex {
            lanes = [
                (
                    "primary",
                    metadata?.sessionLabel ?? "Session",
                    CodexConsumerProjection.sourceRateWindow(for: .session, snapshot: snapshot)),
                (
                    "secondary",
                    metadata?.weeklyLabel ?? "Weekly",
                    CodexConsumerProjection.sourceRateWindow(for: .weekly, snapshot: snapshot)),
                (
                    "monthly",
                    "Monthly credit limit",
                    CodexConsumerProjection.sourceRateWindow(for: .monthly, snapshot: snapshot)
                        ?? self.nativeOrbitCodexMonthlyCreditWindow(snapshot)),
                ("tertiary", metadata?.opusLabel ?? "Additional", snapshot.tertiary),
            ]
        }
        var result = lanes.compactMap { id, title, window -> (String, String, RateWindow)? in
            window.map { (id, title, $0) }
        }
        result += (snapshot.extraRateWindows ?? []).filter(\.usageKnown).map { ($0.id, $0.title, $0.window) }
        var seen = Set<String>()
        return result.filter { id, _, window in
            seen.insert(id).inserted && !window.isSyntheticPlaceholder
                && window.usedPercent.isFinite && window.usedPercent >= 0
        }
    }

    nonisolated static func nativeOrbitQuotaSamples(
        provider: UsageProvider,
        snapshot: UsageSnapshot) -> [PlanUtilizationSeriesSample]
    {
        self.nativeOrbitQuotaWindows(provider: provider, snapshot: snapshot).map { lane in
            PlanUtilizationSeriesSample(
                name: .init(rawValue: "nativeQuota:\(lane.id)"),
                windowMinutes: max(0, lane.window.windowMinutes ?? 0),
                entry: PlanUtilizationHistoryEntry(
                    capturedAt: self.nativeOrbitQuotaObservationDate(
                        provider: provider,
                        snapshot: snapshot,
                        id: lane.id),
                    usedPercent: lane.window.usedPercent,
                    resetsAt: lane.window.resetsAt))
        }
    }

    nonisolated static func nativeOrbitHistorySamples(
        provider: UsageProvider,
        snapshot: UsageSnapshot,
        credits: CreditsSnapshot? = nil) -> [PlanUtilizationSeriesSample]
    {
        self.nativeOrbitQuotaSamples(provider: provider, snapshot: snapshot)
            + self.nativeOrbitMetricSamples(provider: provider, snapshot: snapshot, credits: credits)
    }

    private nonisolated static func nativeOrbitQuotaObservationDate(
        provider: UsageProvider,
        snapshot: UsageSnapshot,
        id: String) -> Date
    {
        // Provider-specific by design: Codex's monthly credit cap has its own measured timestamp; a balance-only
        // refresh or unrelated usage refresh must not turn a preserved cap into a new observation.
        if provider == .codex, id == "monthly", self.nativeOrbitCodexMonthlyCreditWindow(snapshot) != nil,
           let cost = snapshot.providerCost
        { return cost.updatedAt }
        return snapshot.updatedAt
    }

    private nonisolated static func nativeOrbitCodexMonthlyCreditWindow(_ snapshot: UsageSnapshot) -> RateWindow? {
        guard !snapshot.hasRateLimitWindows, let cost = snapshot.providerCost,
              cost.currencyCode == CodexExtraUsageCost.currencyCode,
              cost.used.isFinite, cost.used >= 0, cost.limit.isFinite, cost.limit > 0 else { return nil }
        return RateWindow(
            usedPercent: cost.used / cost.limit * 100,
            windowMinutes: nil,
            resetsAt: cost.resetsAt,
            resetDescription: nil)
    }

    nonisolated static func nativeOrbitMergedRawEntries(
        _ existing: [PlanUtilizationHistoryEntry],
        _ incoming: [PlanUtilizationHistoryEntry]) -> [PlanUtilizationHistoryEntry]
    {
        var byDate: [Date: PlanUtilizationHistoryEntry] = [:]
        for entry in existing + incoming {
            if entry.historicalPeriod != nil, byDate[entry.capturedAt]?.historicalPeriod == nil,
               byDate[entry.capturedAt] != nil { continue }
            byDate[entry.capturedAt] = entry
        }
        return byDate.values.sorted(by: PlanUtilizationHistoryEntry.precedes)
    }

    nonisolated static func nativeOrbitCanonicalQuotaHistories(
        provider: UsageProvider,
        histories: [PlanUtilizationSeriesHistory]) -> [PlanUtilizationSeriesHistory]
    {
        // Provider-specific by design: older Codex raw observations followed transport slots. A known cadence
        // proves which logical quota those fragments measured; unknown cadences keep their existing slot.
        guard provider == .codex else { return histories }
        return histories.map { history in
            guard ["nativeQuota:primary", "nativeQuota:secondary"].contains(history.name.rawValue) else {
                return history
            }
            let name: PlanUtilizationSeriesName = switch history.windowMinutes {
            case 300: "nativeQuota:primary"
            case 10080: "nativeQuota:secondary"
            case 43200: "nativeQuota:monthly"
            default: history.name
            }
            return .init(name: name, windowMinutes: history.windowMinutes, entries: history.entries)
        }
    }

    /// A quota's advertised reset duration can change without changing the measured quota or its owner.
    nonisolated static func nativeOrbitCoalescedQuotaHistories(
        _ histories: [PlanUtilizationSeriesHistory]) -> [PlanUtilizationSeriesHistory]
    {
        var native: [PlanUtilizationSeriesName: PlanUtilizationSeriesHistory] = [:]
        for history in histories where history.name.isNativeQuotaObservation {
            guard let existing = native[history.name] else {
                native[history.name] = history
                continue
            }
            let latest = [existing, history].filter { $0.windowMinutes > 0 }
                .max { ($0.latestCapturedAt ?? .distantPast) < ($1.latestCapturedAt ?? .distantPast) }
                ?? history
            native[history.name] = .init(
                name: history.name,
                windowMinutes: latest.windowMinutes,
                entries: self.nativeOrbitMergedRawEntries(existing.entries, history.entries))
        }
        return (histories.filter { !$0.name.isNativeQuotaObservation } + native.values)
            .sorted(by: PlanUtilizationSeriesHistory.precedes)
    }

    nonisolated static func nativeOrbitHistoryIncludingCurrentSnapshot(
        _ histories: [PlanUtilizationSeriesHistory],
        provider: UsageProvider,
        snapshot: UsageSnapshot?,
        credits: CreditsSnapshot? = nil) -> [PlanUtilizationSeriesHistory]
    {
        guard let snapshot else { return histories }
        // A verified current reading is already a real observation, even before asynchronous persistence finishes.
        // Unidentified ambient sources receive this one reading only, never another owner's unscoped timeline.
        return self.updatedPlanUtilizationHistories(
            existingHistories: self.nativeOrbitCanonicalQuotaHistories(provider: provider, histories: histories),
            samples: self.nativeOrbitHistorySamples(provider: provider, snapshot: snapshot, credits: credits)) ??
            histories
    }

    nonisolated static func nativeOrbitQuotaWindowMap(
        provider: UsageProvider,
        snapshot: UsageSnapshot?) -> [String: RateWindow]
    {
        guard let snapshot else { return [:] }
        return Dictionary(uniqueKeysWithValues: self.nativeOrbitQuotaWindows(provider: provider, snapshot: snapshot)
            .map { ("nativeQuota:\($0.id)", $0.window) })
    }

    nonisolated static func nativeOrbitQuotaLabels(
        provider: UsageProvider,
        snapshot: UsageSnapshot?) -> [String: String]
    {
        guard let snapshot else { return [:] }
        return Dictionary(uniqueKeysWithValues: self.nativeOrbitQuotaWindows(provider: provider, snapshot: snapshot)
            .map { ("nativeQuota:\($0.id)", $0.title) })
    }

    nonisolated static func nativeOrbitClaudeHistoryKey(_ account: ProviderAccountUsageSnapshot) -> String? {
        // Provider-specific by design: ClaudeSwap history requires Claude owner evidence, never a reusable slot alone.
        guard account.provider == .claude, account.id.source == ClaudeSwapAccountProjection.sourceName,
              let email = CodexIdentityResolver.normalizeEmail(account.accountEmail) else { return nil }
        if let measuredEmail = account.snapshot?.accountEmail(for: .claude),
           CodexIdentityResolver.normalizeEmail(measuredEmail) != email { return nil }
        let organization = account.accountOrganizationName?.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        let evidence = [email, organization]
        guard let encoded = try? JSONEncoder().encode(evidence) else { return nil }
        return self.nativeOrbitClaudeHistoryPrefix(account.id) + self.nativeOrbitHistoryDigest(encoded)
    }

    private nonisolated static func nativeOrbitClaudeHistoryPrefix(_ id: ProviderAccountIdentity) -> String {
        "native-claude-swap:" + self.nativeOrbitHistoryDigest(Data(id.opaqueID.utf8)) + ":"
    }

    private nonisolated static func nativeOrbitHistoryDigest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func recordNativeCodexCreditHistory(
        _ credits: CreditsSnapshot?,
        expectedGuard: CodexAccountScopedRefreshGuard) async
    {
        guard self.settings.nativeDesignEnabled, let credits else { return }
        if !self.planUtilizationHistoryLoaded { _ = await self.planUtilizationHistoryLoadTask?.result }
        // A credits-only publication can precede the first quota reading. Its admitted owner still identifies
        // its history; never fall through to a selected or unscoped quota bucket.
        guard !Task.isCancelled,
              let owner = self.codexScopedNonUsageSuccessApplyGuard(expectedGuard: expectedGuard),
              let key = CodexHistoryOwnership.canonicalKey(for: owner.identity) else { return }
        let source = UsageSnapshot(primary: nil, secondary: nil, updatedAt: credits.updatedAt)
        // Provider-specific by design: admitted Codex credits persist only in their verified Codex owner bucket.
        let samples = Self.nativeOrbitMetricSamples(provider: .codex, snapshot: source, credits: credits)
        var buckets = self.planUtilizationHistory[.codex] ?? PlanUtilizationHistoryBuckets()
        guard let histories = Self.updatedPlanUtilizationHistories(
            existingHistories: buckets.accounts[key] ?? [], samples: samples) else { return }
        buckets.setHistories(histories, for: key)
        self.planUtilizationHistory[.codex] = buckets
        self.planUtilizationHistoryRevision &+= 1
        await self.planUtilizationPersistenceCoordinator.enqueue(self.planUtilizationHistory)
    }

    func recordNativeCodexAccountHistory(
        _ records: [CodexAccountUsageSnapshot],
        projection: CodexVisibleAccountProjection,
        generation: UInt64? = nil) async
    {
        guard self.settings.nativeDesignEnabled else { return }
        if !self.planUtilizationHistoryLoaded { _ = await self.planUtilizationHistoryLoadTask?.result }
        // Provider-specific by design: Codex row history follows its verified refresh generation and owner buckets.
        guard !Task.isCancelled,
              self.isCurrentProviderRefreshGeneration(.codex, generation: generation) else { return }
        var buckets = self.planUtilizationHistory[.codex] ?? PlanUtilizationHistoryBuckets()
        let original = buckets
        for record in records {
            let published = self.codexAccountSnapshots.filter { $0.id == record.id }
            guard record.error == nil, let snapshot = record.snapshot,
                  published.count == 1, let current = published.first, current.error == nil,
                  current.snapshot?.updatedAt == snapshot.updatedAt,
                  Self.codexPriorSnapshotAccountMatches(current.account, account: record.account),
                  let account = Self.currentCodexVisibleAccount(
                      matching: record.account,
                      projection: projection,
                      allowProviderAccountAuthFingerprintMismatch: false) else { continue }
            let email = CodexIdentityResolver.normalizeEmail(account.email)
            // Provider-specific by design: Codex samples require matching measured identity before owner-bound storage.
            if let measuredEmail = snapshot.accountEmail(for: .codex),
               CodexIdentityResolver.normalizeEmail(measuredEmail) != email { continue }
            let identity = Self.codexScopedRefreshGuard(for: account).identity
            if case .emailOnly = identity,
               projection.visibleAccounts.count(where: { CodexIdentityResolver.normalizeEmail($0.email) == email }) > 1
            { continue }
            guard let key = CodexHistoryOwnership.canonicalKey(for: identity) else { continue }
            // A sibling refresh owns this verified row only. It must not resolve through the selected login,
            // adopt ambient history, change the preferred owner, or send active-account quota notifications.
            if let histories = Self.updatedPlanUtilizationHistories(
                existingHistories: Self.nativeOrbitCanonicalQuotaHistories(
                    provider: .codex, histories: buckets.accounts[key] ?? []),
                samples: Self.nativeOrbitHistorySamples(provider: .codex, snapshot: snapshot, credits: record.credits))
            {
                buckets.setHistories(histories, for: key)
            }
        }
        if buckets != original {
            self.planUtilizationHistory[.codex] = buckets
            self.planUtilizationHistoryRevision &+= 1
            await self.planUtilizationPersistenceCoordinator.enqueue(self.planUtilizationHistory)
        }
        self.scheduleNativeCodexSessionHistoryBackfill(projection: projection, generation: generation)
        self.scheduleNativeCodexServerHistoryBackfill(records, projection: projection, generation: generation)
    }

    func recordNativeClaudeSwapHistory(_ accounts: [ProviderAccountUsageSnapshot]) async {
        guard self.settings.nativeDesignEnabled else { return }
        self.scheduleNativeClaudeDesktopHistoryRecovery()
        if !self.planUtilizationHistoryLoaded { _ = await self.planUtilizationHistoryLoadTask?.result }
        let unique = Dictionary(grouping: accounts, by: \.id).filter { $0.value.count == 1 }
        // Provider-specific by design: ClaudeSwap has a separate owner-bound timeline in Claude's history store.
        var buckets = self.planUtilizationHistory[.claude] ?? PlanUtilizationHistoryBuckets()
        let original = buckets
        for account in accounts {
            let key = Self.nativeOrbitClaudeHistoryKey(account)
            guard unique[account.id] != nil, account.provider == .claude,
                  account.id.source == ClaudeSwapAccountProjection.sourceName,
                  self.claudeSwapAccountSnapshots.contains(where: {
                      $0.id == account.id && Self.nativeOrbitClaudeHistoryKey($0) == key
                          && $0.snapshot?.updatedAt == account.snapshot?.updatedAt
                  }) else { continue }
            // Slots are reusable. Changed or missing owner evidence must retain prior isolated timelines;
            // selection follows only the current owner key and never borrows those prior readings.
            guard let key, !account.usesLastKnownUsage, account.error == nil,
                  let snapshot = account.snapshot else { continue }
            // Provider-specific by design: Verified ClaudeSwap samples are written only to this Claude owner bucket.
            if let histories = Self.updatedPlanUtilizationHistories(
                existingHistories: buckets.accounts[key] ?? [],
                samples: Self.nativeOrbitHistorySamples(provider: .claude, snapshot: snapshot))
            {
                buckets.setHistories(histories, for: key)
            }
        }
        guard buckets != original else { return }
        // Provider-specific by design: Commit the reconciled Claude owner timelines without touching other providers.
        self.planUtilizationHistory[.claude] = buckets
        self.planUtilizationHistoryRevision &+= 1
        await self.planUtilizationPersistenceCoordinator.enqueue(self.planUtilizationHistory)
    }

    func scheduleNativeClaudeDesktopHistoryRecovery() {
        // Desktop records an organization without the principal needed for an account-owned timeline.
        // Automatically retain those genuine readings with their original scope in a dedicated cache.
        guard self.settings.nativeDesignEnabled, self.isEnabled(.claude), !TestProcessSafety.isRunning,
              !Task.isCancelled, self.nativeClaudeDesktopHistoryLoadTask == nil else { return }
        self.nativeClaudeDesktopHistoryLoadTask = Task(priority: .utility) { @MainActor [weak self] in
            _ = await NativeClaudeDesktopHistory.shared.load()
            if await NativeClaudeDesktopHistory.shared.persistenceFailed {
                CodexBarLog.logger("plan-history")
                    .error("Claude Desktop history cache save failed; recovery will retry")
            }
            _ = await NativeClaudeWebLogHistory.shared.load()
            if await NativeClaudeWebLogHistory.shared.persistenceFailed {
                CodexBarLog.logger("plan-history")
                    .error("Claude diagnostic history cache save failed; recovery will retry")
            }
            self?.nativeClaudeDesktopHistoryLoadTask = nil
        }
    }
}
