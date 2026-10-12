import CodexBarCore
import Foundation

/// Account-bound server measurements, kept separate from quota observations and local session estimates.
struct NativeCodexAccountUsageHistory: Codable, Sendable, Equatable {
    struct Observation: Codable, Sendable, Equatable {
        let day: CodexAccountUsageHistory.DailyBucket
        let reportedAt: Date
    }

    let latest: CodexAccountUsageHistory
    let fetchedAt: Date
    let observations: [Observation]
    /// Prior readings remain dated measurements after the provider corrects a civil day.
    var archivedObservations: [Observation]?

    private var allObservations: [Observation] {
        (self.archivedObservations ?? []) + self.observations
    }

    private static func retainedVersions(
        _ values: [Observation],
        fetchedAt: Date) -> [Observation]
    {
        let cutoff = fetchedAt.addingTimeInterval(-366 * 86400)
        var unique: [String: Observation] = [:]
        for value in values where value.reportedAt >= cutoff && value.reportedAt <= fetchedAt {
            unique["\(value.day.startDate)|\(value.reportedAt.timeIntervalSince1970)"] = value
        }
        return Array(unique.values.sorted { $0.reportedAt < $1.reportedAt }.suffix(100_000))
    }

    static func retainingStoredObservations(
        _ incoming: Self?,
        previous: Self?) -> Self?
    {
        guard let incoming, incoming.tokenSnapshot() != nil else { return previous }
        guard let previous, previous.tokenSnapshot() != nil else { return incoming }
        let newest = incoming.fetchedAt >= previous.fetchedAt ? incoming : previous
        let observations = Dictionary(
            grouping: previous.observations + incoming.observations,
            by: { $0.day.startDate })
            .compactMapValues { $0.max(by: { $0.reportedAt < $1.reportedAt }) }
        return Self(
            latest: newest.latest,
            fetchedAt: newest.fetchedAt,
            observations: observations.values.sorted { $0.day.startDate < $1.day.startDate },
            archivedObservations: Self.retainedVersions(
                previous.allObservations + incoming.allObservations,
                fetchedAt: newest.fetchedAt))
    }

    static func merging(
        _ history: CodexAccountUsageHistory,
        previous: Self?,
        fetchedAt: Date) -> Self?
    {
        guard !history.hasStatsError, let days = history.dailyUsageBuckets,
              fetchedAt.timeIntervalSince1970.isFinite,
              previous.map({ fetchedAt >= $0.fetchedAt }) ?? true else { return previous }
        var byDate = Dictionary(
            grouping: previous?.observations ?? [],
            by: { $0.day.startDate })
            .compactMapValues { $0.max(by: { $0.reportedAt < $1.reportedAt }) }
        for day in days {
            byDate[day.startDate] = Observation(
                day: day,
                reportedAt: fetchedAt)
        }
        return Self(
            latest: history,
            fetchedAt: fetchedAt,
            observations: byDate.values.sorted { $0.day.startDate < $1.day.startDate },
            archivedObservations: Self.retainedVersions(
                (previous?.allObservations ?? []) + days.map { Observation(
                    day: $0,
                    reportedAt: fetchedAt) },
                fetchedAt: fetchedAt))
    }

    func tokenSnapshot(asOf date: Date) -> CostUsageTokenSnapshot? {
        guard date.timeIntervalSince1970.isFinite, self.tokenSnapshot() != nil else { return nil }
        let eligible = self.allObservations.filter { $0.reportedAt <= date }
        guard let reportedAt = eligible.map(\.reportedAt).max() else { return nil }
        let observations = Dictionary(
            grouping: eligible,
            by: { $0.day.startDate })
            .compactMapValues { $0.max(by: { $0.reportedAt < $1.reportedAt }) }
        var snapshot = Self(
            latest: self.latest,
            fetchedAt: reportedAt,
            observations: observations.values.sorted { $0.day.startDate < $1.day.startDate })
            .tokenSnapshot(usesLatestMetadata: false)
        // These counts belong to retained dated receipts; the latest correction's metadata was not observed then.
        snapshot?.historyLabel = "Provider-reported daily account tokens"
        return snapshot
    }

    func tokenSnapshot() -> CostUsageTokenSnapshot? {
        self.tokenSnapshot(usesLatestMetadata: true)
    }

    /// Dated receipts must not borrow the latest response's coverage or statistics day.
    private func tokenSnapshot(usesLatestMetadata: Bool) -> CostUsageTokenSnapshot? {
        guard !self.latest.hasStatsError, self.fetchedAt.timeIntervalSince1970.isFinite else { return nil }
        let calendar = CostUsageBucketTimeZone.calendar(identifier: "UTC")
        guard self.observations.count <= 100_000, (self.archivedObservations?.count ?? 0) <= 100_000,
              (self.archivedObservations ?? []).allSatisfy({
                  Self.validatedTokens(
                      $0,
                      fetchedAt: self.fetchedAt,
                      calendar: calendar) != nil
              }) else { return nil }
        var daily: [CostUsageDailyReport.Entry] = []
        var dates: Set<String> = []
        for observation in self.observations {
            let day = observation.day
            guard dates.insert(day.startDate).inserted,
                  let tokens = Self.validatedTokens(
                      observation,
                      fetchedAt: self.fetchedAt,
                      calendar: calendar)
            else { return nil }
            daily.append(.init(
                date: day.startDate,
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: tokens,
                costUSD: nil,
                modelsUsed: nil,
                modelBreakdowns: nil))
        }
        // The service omits zero days. When its buckets add up to the lifetime total (or it reports complete
        // coverage), a missing day inside the covered range is a measured zero; otherwise it stays unknown.
        // Never invent event timestamps, dollar prices, or a quota curve from these token counts.
        let label = "Provider-reported daily account tokens"
            + (self.latest.statsAsOf.map { " · Statistics as of \($0)" } ?? "")
        let statsDayEnd = usesLatestMetadata ? self.latest.statsAsOf
            .flatMap { Self.civilDayStart($0, calendar: calendar) }
            .map { $0.addingTimeInterval(86399) } : nil
        return CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: nil,
            last30DaysCostUSD: nil,
            historyDays: 365,
            historyCoverageIsEstablished: usesLatestMetadata && self.coversLifetime,
            // The statistics day keeps accumulating (and lags hours behind), so totals stay lower bounds.
            historyScanIsPartial: true,
            historyLabel: label,
            bucketTimeZoneIdentifier: "UTC",
            coverageThrough: statsDayEnd.map { min($0, self.fetchedAt) } ?? self.fetchedAt,
            daily: daily,
            updatedAt: self.fetchedAt)
    }

    /// Buckets add up to the lifetime total, so every day without a bucket was a zero day.
    private var coversLifetime: Bool {
        if self.latest.coverageComplete == true { return true }
        guard let lifetime = self.latest.summary.lifetimeTokens, lifetime >= 0,
              let buckets = self.latest.dailyUsageBuckets, buckets.allSatisfy({ $0.tokens >= 0 }) else { return false }
        var total: Int64 = 0
        for bucket in buckets {
            let sum = total.addingReportingOverflow(bucket.tokens)
            guard !sum.overflow else { return false }
            total = sum.partialValue
        }
        return total == lifetime
    }

    private static func civilDayStart(_ value: String, calendar: Calendar) -> Date? {
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, value.utf8.count == 10 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private static func validatedTokens(
        _ observation: Observation,
        fetchedAt: Date,
        calendar: Calendar) -> Int?
    {
        let day = observation.day
        let parts = day.startDate.split(separator: "-")
        guard parts.count == 3, day.startDate.utf8.count == 10,
              parts[0].utf8.count == 4, parts[1].utf8.count == 2, parts[2].utf8.count == 2,
              parts.allSatisfy({ $0.utf8.allSatisfy { (48...57).contains($0) } }),
              let year = Int(parts[0]), year > 0, let month = Int(parts[1]), let date = Int(parts[2]),
              let parsed = calendar.date(from: DateComponents(
                  year: year,
                  month: month,
                  day: date)),
              calendar.component(
                  .year,
                  from: parsed) == year,
              calendar.component(
                  .month,
                  from: parsed) == month,
              calendar.component(
                  .day,
                  from: parsed) == date,
              let tokens = Int(exactly: day.tokens), tokens >= 0,
              observation.reportedAt.timeIntervalSince1970.isFinite,
              observation.reportedAt <= fetchedAt else { return nil }
        return tokens
    }
}

extension UsageStore {
    nonisolated static func nativeCodexAccountUsageHistory(
        for account: CodexVisibleAccount,
        previous: NativeCodexAccountUsageHistory?,
        env: [String: String],
        now: Date? = nil,
        loader: @Sendable (String, String, [String: String]) async throws -> CodexAccountUsageHistory = {
            try await CodexAccountUsageHistoryFetcher.fetchForNativeAccount(
                email: $0,
                accountID: $1,
                env: $2)
        }) async -> NativeCodexAccountUsageHistory?
    {
        // Provider-specific by design: the authenticated Codex endpoint has no response owner field. Its fetcher
        // verifies the exact email/workspace principal before and after using this isolated account environment.
        guard let email = CodexIdentityResolver.normalizeEmail(account.email),
              let workspace = CodexOpenAIWorkspaceResolver.normalizeWorkspaceAccountID(account.workspaceAccountID)
        else { return previous }
        do {
            try Task.checkCancellation()
            let history = try await loader(email, workspace, env)
            try Task.checkCancellation()
            return NativeCodexAccountUsageHistory.merging(
                history,
                previous: previous,
                fetchedAt: now ?? Date())
        } catch {
            return previous
        }
    }
}
