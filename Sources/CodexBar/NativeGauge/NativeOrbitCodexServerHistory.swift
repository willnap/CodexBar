import CodexBarCore
import Foundation

private struct NativeCodexServerHistoryRequest: Sendable {
    let account: CodexVisibleAccount
    let accountID: String
    let ownerKey: String
    @ProcessEnvironment var environment: [String: String]
}

extension UsageStore {
    nonisolated static func nativeCodexServerHistorySamples(
        _ history: CodexPlanLimitHistory,
        now: Date) -> [PlanUtilizationSeriesSample]
    {
        let cutoff = now.addingTimeInterval(-32 * 86400)
        return history.closedPeriods(now: now).compactMap { period in
            guard period.endsAt >= cutoff, let percent = period.usedPercent else { return nil }
            return PlanUtilizationSeriesSample(
                name: period.windowMinutes == 300 ? "nativeQuota:primary" : "nativeQuota:secondary",
                windowMinutes: period.windowMinutes,
                entry: .init(
                    capturedAt: period.endsAt,
                    usedPercent: percent,
                    resetsAt: period.endsAt,
                    historicalPeriod: .init(
                        startsAt: period.startsAt,
                        approximate: history.approximate,
                        accountingComplete: period.accountingComplete,
                        boundaryToleranceSeconds: history.boundaryToleranceSeconds,
                        coverageComplete: history.coverageComplete,
                        coverageStart: history.coverageStart,
                        dataAsOf: history.dataAsOf,
                        sourcePeriodID: period.id)))
        }
    }

    func scheduleNativeCodexServerHistoryBackfill(
        _ records: [CodexAccountUsageSnapshot],
        projection: CodexVisibleAccountProjection,
        generation: UInt64?)
    {
        // Provider-specific by design: Codex account analytics must reuse the exact accepted native login.
        guard self.settings.nativeDesignEnabled, self.isEnabled(.codex), self.planUtilizationHistoryLoaded,
              !TestProcessSafety.isRunning,
              !Task.isCancelled, self.nativeCodexServerHistoryBackfillTask == nil,
              self.isCurrentProviderRefreshGeneration(.codex, generation: generation) else { return }
        let now = Date()
        var requests: [NativeCodexServerHistoryRequest] = []
        for record in records {
            guard record.error == nil, record.snapshot != nil,
                  let account = Self.currentCodexVisibleAccount(
                      matching: record.account,
                      projection: projection,
                      allowProviderAccountAuthFingerprintMismatch: false),
                  case let .providerAccount(accountID) = Self.codexScopedRefreshGuard(for: account).identity,
                  let ownerKey = CodexHistoryOwnership.canonicalKey(for: .providerAccount(id: accountID)),
                  (self.nativeCodexServerHistoryNextFetchAt[ownerKey] ?? .distantPast) <= now
            else { continue }
            // Provider-specific by design: the history request must use this Codex account's selected login home.
            let context = self.makeFetchContext(
                provider: .codex, override: nil, codexActiveSourceOverride: account.selectionSource)
            requests.append(.init(
                account: account,
                accountID: accountID,
                ownerKey: ownerKey,
                environment: context.env))
        }
        guard !requests.isEmpty else { return }
        let token = UUID()
        self.nativeCodexServerHistoryBackfillToken = token
        self.nativeCodexServerHistoryBackfillTask = Task(priority: .utility) { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.nativeCodexServerHistoryBackfillToken == token {
                    self.nativeCodexServerHistoryBackfillTask = nil
                    self.nativeCodexServerHistoryBackfillToken = nil
                }
            }
            for request in requests {
                guard self.nativeCodexServerHistoryCanPublish(generation: generation) else { return }
                self.nativeCodexServerHistoryNextFetchAt[request.ownerKey] = Date().addingTimeInterval(60)
                do {
                    let history = try await CodexPlanLimitHistoryFetcher.fetchForNativeAccount(
                        email: request.account.email,
                        accountID: request.accountID,
                        env: request.environment)
                    guard self.nativeCodexServerHistoryCanPublish(generation: generation) else { return }
                    let currentProjection = self.freshCodexVisibleAccountProjectionForAccountRefresh()
                    guard let account = Self.currentCodexVisibleAccount(
                        matching: request.account,
                        projection: currentProjection,
                        allowProviderAccountAuthFingerprintMismatch: false),
                        CodexHistoryOwnership.canonicalKey(for: Self.codexScopedRefreshGuard(for: account).identity)
                        == request.ownerKey else { continue }
                    // Provider-specific by design: recheck the current Codex login home before publishing its history.
                    let currentContext = self.makeFetchContext(
                        provider: .codex, override: nil, codexActiveSourceOverride: account.selectionSource)
                    guard CodexHomeScope.ambientHomeURL(env: currentContext.env).standardizedFileURL
                        == CodexHomeScope.ambientHomeURL(env: request.environment).standardizedFileURL else { continue }
                    await self.publishNativeCodexServerHistory(history, ownerKey: request.ownerKey, now: Date())
                    // Successful history is refreshed hourly; failed optional reads retry after one minute.
                    self.nativeCodexServerHistoryNextFetchAt[request.ownerKey] = Date().addingTimeInterval(3600)
                } catch {
                    if Task.isCancelled { return }
                    // Optional history failure never changes the working account's authentication or live quota.
                }
            }
        }
    }

    private func nativeCodexServerHistoryCanPublish(generation: UInt64?) -> Bool {
        // Provider-specific by design: only the current Codex refresh generation may commit Codex server history.
        self.settings.nativeDesignEnabled && self.isEnabled(.codex) && !Task.isCancelled
            && self.isCurrentProviderRefreshGeneration(.codex, generation: generation)
    }

    private func publishNativeCodexServerHistory(
        _ history: CodexPlanLimitHistory,
        ownerKey: String,
        now: Date) async
    {
        guard self.planUtilizationHistoryLoaded else { return }
        // Provider-specific by design: Codex server totals merge only with this verified Codex owner's histories.
        var buckets = self.planUtilizationHistory[.codex] ?? PlanUtilizationHistoryBuckets()
        let existing = Self.nativeOrbitCanonicalQuotaHistories(
            provider: .codex,
            histories: buckets.accounts[ownerKey] ?? [])
        let samples = Self.nativeCodexServerHistorySamples(history, now: now).filter { sample in
            // A directly measured quota reading at the same instant outranks a server period aggregate.
            !existing.contains { lane in
                lane.name == sample.name && lane.entries.contains {
                    $0.capturedAt == sample.entry.capturedAt && $0.historicalPeriod == nil
                }
            }
        }
        guard let updated = Self.updatedPlanUtilizationHistories(existingHistories: existing, samples: samples) else {
            return
        }
        buckets.setHistories(updated, for: ownerKey)
        // Provider-specific by design: commit recovered Codex totals without changing another provider's buckets.
        self.planUtilizationHistory[.codex] = buckets
        self.planUtilizationHistoryRevision &+= 1
        await self.planUtilizationPersistenceCoordinator.enqueue(self.planUtilizationHistory)
    }
}
