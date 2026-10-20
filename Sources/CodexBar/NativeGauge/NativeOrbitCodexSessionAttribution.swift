import CodexBarCore
import Foundation
import Observation

/// Splits verified local Codex session reports between visible accounts off the main actor.
///
/// Rendering reads the latest finished attribution; a changed publication, timeline, or account evidence starts
/// one background pass and the observable revision redraws the dials when it lands.
@MainActor
@Observable
final class NativeCodexSessionAttributionStore {
    struct Key: Hashable {
        let publicationRevision: UInt64
        let publicationGeneration: UInt64
        let publicationLoadedAt: Date
        let timelineRevision: UInt64
        let evidenceDigest: Int
        let bucketTimeZoneIdentifier: String
        let sourceIDs: [String]
    }

    /// Incremental rollout scanner whose drained observations build the timeline.
    @ObservationIgnored let scanner = NativeCodexQuotaSessionHistoryScanner()
    /// The inputs of the last repair that left history as it was. The same readings repaired into the same history
    /// give the same result, so a refresh that read nothing new skips re-sorting every recovered series.
    @ObservationIgnored var unchangedRepair: (
        observations: [NativeCodexQuotaSessionObservation],
        original: PlanUtilizationHistoryBuckets,
        protected: [String: [NativeCodexQuotaHistoryLane: Set<PlanUtilizationHistoryEntry>]])?
    private(set) var timeline: NativeCodexSessionWindowTimeline?
    private(set) var timelineRevision: UInt64 = 0
    private(set) var resultRevision: UInt64 = 0
    @ObservationIgnored private(set) var result: (key: Key, value: NativeCodexSessionWindowAttribution.Result)?
    @ObservationIgnored private var pending: (key: Key, task: Task<Void, Never>)?
    @ObservationIgnored private var seedTask: Task<Void, Never>?
    /// The last pass's inputs and outcome as counts and relative times, for the opt-in history proof.
    @ObservationIgnored var diagnostics: [String: Any] = [:]
    static let recordsDiagnostics = CommandLine.arguments.contains("--native-popup-preview-provider")

    func update(timeline: NativeCodexSessionWindowTimeline) {
        guard timeline != self.timeline else { return }
        self.seedTask?.cancel()
        self.timeline = timeline
        self.timelineRevision &+= 1
    }

    /// Until this launch's scanner drains every rollout, the persisted anonymous session archive (one entry per
    /// event with its weekly reset) already describes the same windows. Build that timeline off the main actor.
    func seedTimelineIfNeeded(archive: [PlanUtilizationSeriesHistory], now: Date) {
        guard self.timeline == nil, self.seedTask == nil else { return }
        let weekly = NativeCodexSessionWindowTimeline.weeklyWindowMinutes
        let lanes = archive.filter {
            $0.windowMinutes == weekly
                && ($0.name.rawValue == "nativeQuota:secondary" || $0.name.rawValue == "nativeQuota:primary")
        }
        guard !lanes.isEmpty else { return }
        self.seedTask = Task { @MainActor [weak self] in
            let timeline = await Task.detached(priority: .utility) {
                let events = lanes.flatMap(\.entries).compactMap { entry in
                    entry.resetsAt.map { (time: entry.capturedAt, weeklyReset: $0) }
                }
                return NativeCodexSessionWindowTimeline(
                    events: events,
                    coverageStart: now.addingTimeInterval(-32 * 86400),
                    coverageEnd: events.map(\.time).max() ?? now.addingTimeInterval(-32 * 86400))
            }.value
            guard let self, !Task.isCancelled, self.timeline == nil else { return }
            self.update(timeline: timeline)
        }
    }

    func waitForTimelineSeed() async {
        await self.seedTask?.value
    }

    /// The finished attribution for `key`, or the previous one while a new pass is computing.
    func attribution(
        key: Key,
        reports: @autoclosure () -> [CostUsageTokenSnapshot],
        evidence: @autoclosure () -> [String: [Date]],
        calendar: Calendar) -> NativeCodexSessionWindowAttribution.Result?
    {
        _ = self.resultRevision
        if let result, result.key == key { return result.value }
        guard let timeline, self.pending?.key != key else { return self.result?.value }
        self.pending?.task.cancel()
        let reports = reports()
        let evidence = evidence()
        let task = Task { @MainActor [weak self] in
            let value = await Task.detached(priority: .utility) {
                NativeCodexSessionWindowAttribution.attribute(
                    reports: reports,
                    timeline: timeline,
                    evidence: evidence,
                    calendar: calendar)
            }.value
            guard let self, !Task.isCancelled, self.pending?.key == key else { return }
            self.pending = nil
            self.result = (key, value)
            self.resultRevision &+= 1
        }
        self.pending = (key, task)
        return self.result?.value
    }

    /// Tests and proofs await the pass started by the latest render.
    func waitForPendingAttribution() async {
        await self.pending?.task.value
    }
}

extension UsageStore {
    var nativeCodexSessionHistoryScanner: NativeCodexQuotaSessionHistoryScanner {
        self.nativeCodexSessionAttribution.scanner
    }

    /// Weekly windows this account reported about itself: live readings, closed server periods, and its snapshot.
    ///
    /// Unstarted windows float at capture time + 7 days for every idle account, so they never prove ownership.
    nonisolated static func nativeCodexWeeklyWindowEvidence(
        history: [PlanUtilizationSeriesHistory],
        snapshot: UsageSnapshot?) -> [Date]
    {
        let week = TimeInterval(NativeCodexSessionWindowTimeline.weeklyWindowMinutes * 60)
        func isFloating(usedPercent: Double, capturedAt: Date, resetsAt: Date) -> Bool {
            usedPercent <= 0 && abs(resetsAt.timeIntervalSince(capturedAt) - week) <= 180
        }
        var resets: [Date] = []
        for lane in history where lane.windowMinutes == NativeCodexSessionWindowTimeline.weeklyWindowMinutes {
            for entry in lane.entries {
                if let period = entry.historicalPeriod {
                    // A closed server period can end early (banked reset); its events report start + 7 days.
                    resets.append(period.startsAt.addingTimeInterval(week))
                } else if let reset = entry.resetsAt,
                          !isFloating(usedPercent: entry.usedPercent, capturedAt: entry.capturedAt, resetsAt: reset)
                {
                    resets.append(reset)
                }
            }
        }
        if let snapshot {
            for window in [snapshot.primary, snapshot.secondary].compactMap(\.self)
                where window.windowMinutes == NativeCodexSessionWindowTimeline.weeklyWindowMinutes
            {
                if let reset = window.resetsAt,
                   !isFloating(usedPercent: window.usedPercent, capturedAt: snapshot.updatedAt, resetsAt: reset)
                {
                    resets.append(reset)
                }
            }
        }
        return Array(Set(resets)).sorted()
    }

    /// Local session reports this Mac verified for Codex, one per distinct session home.
    func nativeCodexSessionPool(accounts: [CodexVisibleAccount])
        -> (reports: [CostUsageTokenSnapshot], sourceIDs: [String], isIncomplete: Bool)?
    {
        let publication = self.spendDashboardPublication
        guard let configuration = publication.configuration, configuration.costUsageEnabled,
              configuration.bucketTimeZoneIdentifier == self.settings.costUsageBucketTimeZoneIdentifier
        else { return nil }
        var homesBySourceID: [String: String?] = [:]
        for account in accounts {
            let home = CodexHomeScope.normalizedHomePath(self.nativeCodexHomePath(account))
            homesBySourceID["codex:\(account.id)"] = home
        }
        homesBySourceID["codex:local"] = CodexHomeScope.normalizedHomePath(
            CodexHomeScope.ambientHomeURL(env: self.environmentBase).path)
        var seenHomes: Set<String> = []
        var reports: [CostUsageTokenSnapshot] = []
        var sourceIDs: [String] = []
        var isIncomplete = false
        // Provider-specific by design: these are individually scanned Codex session homes on this Mac.
        for source in publication.sources where source.provider == .codex && source.role == .subscription {
            guard let home = homesBySourceID[source.id] else { continue }
            if let home, !seenHomes.insert(home).inserted { continue }
            switch source.state {
            case .available, .staleLastKnown:
                let inputs = publication.inputs.filter {
                    $0.id == source.id && $0.provider == .codex && $0.sourceKind == .native
                }
                guard inputs.count == 1, let input = inputs.first else {
                    isIncomplete = true
                    continue
                }
                reports.append(input.snapshot)
                sourceIDs.append(source.id)
                if source.state == .staleLastKnown { isIncomplete = true }
            case .confirmedEmpty:
                continue
            case .loading, .unavailable:
                isIncomplete = true
            }
        }
        guard !reports.isEmpty else { return nil }
        return (reports, sourceIDs, isIncomplete)
    }

    /// Local usage per visible Codex account: requests attributed by the weekly window each one reported.
    ///
    /// With a single visible account the whole local home keeps its explicit machine provenance; with several,
    /// only window-proven requests are shown, so one account's sessions never appear under another account.
    func nativeOrbitCodexLocalUsages(
        _ contexts: [(account: CodexVisibleAccount, history: [PlanUtilizationSeriesHistory], snapshot: UsageSnapshot?)])
        -> [String: NativeOrbitLocalUsage]
    {
        self.nativeOrbitCodexResolvedLocalUsages(contexts).mapValues(\.usage)
    }

    /// Live local usage per account once the spend scan and window attribution have published; until then each
    /// account's last known reading for the same account set, homes, credentials and bucket zone.
    func nativeOrbitCodexResolvedLocalUsages(
        _ contexts: [(account: CodexVisibleAccount, history: [PlanUtilizationSeriesHistory], snapshot: UsageSnapshot?)])
        -> [String: NativeOrbitResolvedLocalUsage]
    {
        let live = self.nativeOrbitCodexLiveLocalUsages(contexts)
        let zone = self.settings.costUsageBucketTimeZoneIdentifier
        var owners: [String: String] = [:]
        var legacyOwners: [String: String] = [:]
        for context in contexts {
            owners[context.account.id] = Self.nativeCodexLastKnownUsageOwner(
                account: context.account, bucketTimeZoneIdentifier: zone)
            legacyOwners[context.account.id] = Self.nativeCodexLocalUsageOwner(
                account: context.account,
                homePath: self.nativeCodexHomePath(context.account),
                bucketTimeZoneIdentifier: zone)
        }
        /// Attribution splits shared homes between exactly these accounts; another account set is another owner.
        func cohort(_ owners: [String: String]) -> String {
            NativeOrbitLastKnownUsageStore.ownerDigest(contexts.map {
                owners[$0.account.id] ?? "unowned:\($0.account.id)"
            }.sorted())
        }
        let cohortKey = cohort(owners)
        let legacyCohort = cohort(legacyOwners)
        func key(_ id: String) -> String? {
            owners[id].map { NativeOrbitLastKnownUsageStore.ownerDigest(["codex-dial", cohortKey, $0]) }
        }
        func legacyKey(_ id: String) -> String? {
            legacyOwners[id].map { NativeOrbitLastKnownUsageStore.ownerDigest(["codex-dial", legacyCohort, $0]) }
        }
        var resolved: [String: NativeOrbitResolvedLocalUsage] = [:]
        for (id, usage) in live.usages {
            // Provider-specific by design: Codex readings are remembered only under their own account owner.
            self.nativeLastKnownUsage.record(.codex, owner: key(id), usage: usage)
            resolved[id] = NativeOrbitResolvedLocalUsage(usage: usage)
        }
        let publishedSourceIDs = Set(self.spendDashboardPublication.sources.filter {
            $0.provider == .codex && $0.role == .subscription
        }.map(\.id))
        let awaitingSwitchSources = self.nativeCodexAccountSwitchPresentation != nil
            && !Set(contexts.map { "codex:\($0.account.id)" }).isSubset(of: publishedSourceIDs)
        guard !live.isSettled || awaitingSwitchSources,
              self.settings.isCostUsageEffectivelyEnabled(for: .codex) else { return resolved }
        for context in contexts where resolved[context.account.id] == nil {
            let id = context.account.id
            let remembered = self.nativeLastKnownUsage.usage(.codex, owner: key(id))
                ?? self.nativeLastKnownUsage.usage(.codex, owner: legacyKey(id))
                ?? self.nativeCodexSwitchRetainedLocalUsage(for: context.account)
            resolved[id] = remembered
            if let remembered {
                // Existing files remain readable for the same exact scan scope; adopt their durable owner once.
                self.nativeLastKnownUsage.record(.codex, owner: key(id), usage: remembered.usage)
            }
        }
        return resolved
    }

    /// The spend scan has no Codex home left loading: its absence of a report is itself the live reading.
    private func nativeCodexSpendSourcesSettled(_ sourceIDs: Set<String>? = nil) -> Bool {
        let publication = self.spendDashboardPublication
        guard publication.configuration != nil else { return false }
        // Provider-specific by design: these are individually scanned Codex session homes on this Mac.
        let sources = publication.sources.filter {
            $0.provider == .codex && $0.role == .subscription && (sourceIDs?.contains($0.id) ?? true)
        }
        return !sources.isEmpty && !sources.contains { $0.state == .loading }
    }

    private func nativeOrbitCodexLiveLocalUsages(
        _ contexts: [(account: CodexVisibleAccount, history: [PlanUtilizationSeriesHistory], snapshot: UsageSnapshot?)])
        -> (usages: [String: NativeOrbitLocalUsage], isSettled: Bool)
    {
        var fallback: [String: NativeOrbitLocalUsage] = [:]
        for context in contexts {
            fallback[context.account.id] = self.nativeOrbitCodexLocalUsage(context.account)
        }
        guard contexts.count > 1 else {
            let settled = !fallback.isEmpty || self.nativeCodexSpendSourcesSettled(
                Set(contexts.map { "codex:\($0.account.id)" }))
            return (fallback, settled)
        }
        // Several accounts share local session homes: only per-home reports of profile homes stay usable as-is.
        fallback = fallback.filter { id, local in
            local.scope == .localProfile && contexts.contains { $0.account.id == id && !$0.account.isLive }
                && !Self.nativeCodexReportIsEmpty(local.snapshot)
        }
        let accounts = contexts.map(\.account)
        // Provider-specific by design: Codex weekly reset windows are recorded only in Codex's own quota archive.
        if self.nativeCodexSessionAttribution.timeline == nil, self.planUtilizationHistoryLoaded {
            self.nativeCodexSessionAttribution.seedTimelineIfNeeded(
                archive: self.planUtilizationHistory[.codex]?.unscoped ?? [],
                now: Date())
        }
        let recording = NativeCodexSessionAttributionStore.recordsDiagnostics
        if recording {
            // Provider-specific by design: the proof describes this provider's own spend-scan sources.
            let states = self.spendDashboardPublication.sources
                .filter { $0.provider == .codex && $0.role == .subscription }.map { "\($0.state)" }
            self.nativeCodexSessionAttribution.diagnostics = ["accounts": contexts.count, "sourceStates": states]
        }
        guard let pool = self.nativeCodexSessionPool(accounts: accounts) else {
            if recording { self.nativeCodexSessionAttribution.diagnostics["pool"] = "none" }
            return (fallback, self.nativeCodexSpendSourcesSettled())
        }
        guard let timeline = self.nativeCodexSessionAttribution.timeline else {
            if recording { self.nativeCodexSessionAttribution.diagnostics["timeline"] = "none" }
            return (fallback, false)
        }
        var evidence: [String: [Date]] = [:]
        for context in contexts {
            let resets = Self.nativeCodexWeeklyWindowEvidence(history: context.history, snapshot: context.snapshot)
            if !resets.isEmpty { evidence[context.account.id] = resets }
        }
        var hasher = Hasher()
        for id in evidence.keys.sorted() {
            hasher.combine(id)
            for reset in evidence[id] ?? [] {
                hasher.combine(Int64(reset.timeIntervalSince1970.rounded()))
            }
        }
        let publication = self.spendDashboardPublication
        let calendar = self.settings.costUsageBucketCalendar
        let key = NativeCodexSessionAttributionStore.Key(
            publicationRevision: publication.revision,
            publicationGeneration: publication.generation,
            publicationLoadedAt: publication.loadedAt,
            timelineRevision: self.nativeCodexSessionAttribution.timelineRevision,
            evidenceDigest: hasher.finalize(),
            bucketTimeZoneIdentifier: calendar.timeZone.identifier,
            sourceIDs: pool.sourceIDs)
        guard let result = self.nativeCodexSessionAttribution.attribution(
            key: key,
            reports: pool.reports,
            evidence: evidence,
            calendar: calendar)
        else {
            if recording { self.nativeCodexSessionAttribution.diagnostics["result"] = "pending" }
            return (fallback, false)
        }
        // Requests newer than the last drained timeline cannot be attributed yet; their totals are lower bounds.
        let newestReport = pool.reports.map(\.updatedAt).max() ?? .distantPast
        let timelineLags = timeline.coverageEnd
            < newestReport.addingTimeInterval(-NativeCodexSessionWindowAttribution.maximumEventGap)
        if recording {
            self.recordNativeCodexAttributionDiagnostics(
                contexts.map(\.account.id),
                pool: pool,
                timeline: timeline,
                evidence: evidence,
                result: result,
                timelineLags: timelineLags,
                calendar: calendar)
        }
        var usages = fallback
        for (id, report) in result.reports where evidence[id] != nil {
            usages[id] = NativeOrbitLocalUsage(
                snapshot: report,
                scope: .localMachine,
                bucketTimeZoneIdentifier: calendar.timeZone.identifier,
                isAccountAttributed: true,
                isStale: pool.isIncomplete || timelineLags,
                unattributedDays: result.unattributedDays)
        }
        return (usages, true)
    }

    // Counts and times relative to now only: no identities, paths or amounts beyond token totals.
    // swiftlint:disable:next function_parameter_count
    private func recordNativeCodexAttributionDiagnostics(
        _ accountIDs: [String],
        pool: (reports: [CostUsageTokenSnapshot], sourceIDs: [String], isIncomplete: Bool),
        timeline: NativeCodexSessionWindowTimeline,
        evidence: [String: [Date]],
        result: NativeCodexSessionWindowAttribution.Result,
        timelineLags: Bool,
        calendar: Calendar)
    {
        let now = Date()
        let today = calendar.startOfDay(for: now)
        let parts = calendar.dateComponents([.year, .month, .day], from: now)
        let todayKey = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        func hours(_ date: Date) -> Double { (date.timeIntervalSince(now) / 360).rounded() / 10 }
        let events = timeline.events(since: today)
        var diagnostics = self.nativeCodexSessionAttribution.diagnostics
        diagnostics["timeline"] = [
            "events": timeline.eventCount,
            "coverageEndHours": hours(timeline.coverageEnd),
            "eventsToday": events.count,
            "lastEventHours": events.last.map { hours($0.time) } as Any? ?? NSNull(),
            "todayResetsHours": Array(Set(events.map { hours($0.weeklyReset) })).sorted(),
        ]
        diagnostics["reports"] = pool.reports.map { report in
            let slices = report.quotaSlices
            return [
                "updatedHours": hours(report.updatedAt),
                "slices": slices.count,
                "slicesToday": slices.count { $0.timestamp >= today },
                "newestSliceHours": slices.map(\.timestamp).max().map(hours) as Any? ?? NSNull(),
                "partial": report.historyScanIsPartial,
            ] as [String: Any]
        }
        diagnostics["poolIncomplete"] = pool.isIncomplete
        diagnostics["timelineLags"] = timelineLags
        diagnostics["attributed"] = result.attributedSliceCount
        diagnostics["unattributed"] = result.unattributedSliceCount
        diagnostics["unattributedToday"] = result.unattributedDays.contains(todayKey)
        diagnostics["perAccount"] = accountIDs.map { id in
            [
                "evidence": evidence[id]?.count ?? 0,
                "lastEvidenceHours": (evidence[id] ?? []).suffix(3).map(hours),
                "tokensToday": result.reports[id]?.daily.first { $0.date == todayKey }?.totalTokens as Any? ?? NSNull(),
            ] as [String: Any]
        }
        self.nativeCodexSessionAttribution.diagnostics = diagnostics
    }

    /// Publishes the event-window timeline after the session-history scanner drained every rollout.
    func publishNativeCodexSessionWindowTimeline(
        _ observations: [NativeCodexQuotaSessionObservation],
        now: Date) async
    {
        let timeline = await Task.detached(priority: .utility) {
            NativeCodexSessionWindowTimeline(
                observations: observations,
                coverageStart: now.addingTimeInterval(-32 * 86400),
                coverageEnd: now)
        }.value
        guard !Task.isCancelled else { return }
        self.nativeCodexSessionAttribution.update(timeline: timeline)
    }

    nonisolated static func nativeCodexReportIsEmpty(_ report: CostUsageTokenSnapshot) -> Bool {
        report.daily.allSatisfy { ($0.totalTokens ?? 0) == 0 && ($0.costUSD ?? 0) == 0 }
            && report.quotaSlices.isEmpty && (report.last30DaysTokens ?? 0) == 0
    }

    func nativeCodexHomePath(_ account: CodexVisibleAccount) -> String? {
        let cached = self.settings.cachedCodexAccountReconciliationSnapshot?.snapshot
        return switch account.selectionSource {
        case .liveSystem:
            cached?.liveSystemAccount?.codexHomePath
                ?? CodexHomeScope.ambientHomeURL(env: self.environmentBase).path
        case let .profileHome(path): path
        case let .managedAccount(id): cached?.storedAccounts.first { $0.id == id }?.managedHomePath
        }
    }
}
