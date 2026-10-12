import Foundation

/// Local Claude transcript usage for the whole Mac and for each organization proven by transcript events.
public struct ClaudeLocalUsageResult: Sendable {
    /// Every local Claude transcript, independent of which login produced it.
    public let machine: CostUsageTokenSnapshot?
    /// Requested organizations with established attribution coverage, keyed by lowercase organization UUID.
    public let organizations: [String: CostUsageTokenSnapshot]

    public init(machine: CostUsageTokenSnapshot?, organizations: [String: CostUsageTokenSnapshot]) {
        self.machine = machine
        self.organizations = organizations
    }
}

/// Reads organization evidence from transcript events, never from the current credential.
///
/// Rows are attributed inside the incremental Claude transcript scan (the spend-history cache), so a refresh
/// only parses appended bytes and changed files; organization reports are projections of those cached rows.
public actor ClaudeOrganizationUsageReader {
    public init() {}

    public func read(
        organizationIDs: [String],
        fetcher: CostUsageFetcher,
        now: Date = Date(),
        historyDays: Int,
        calendar: Calendar,
        archiveRoot: URL? = nil) async throws -> ClaudeLocalUsageResult
    {
        let options = fetcher.claudeTranscriptScanOptions(calendar: calendar)
        // Tests must inject fixture roots; never discover real session files from a test process.
        guard options.claudeProjectsRoots != nil || !TestProcessSafety.isRunning else {
            return ClaudeLocalUsageResult(machine: nil, organizations: [:])
        }
        let organizations = Set(organizationIDs.compactMap { UUID(uuidString: $0)?.uuidString.lowercased() })
        let days = max(1, historyDays)
        let since = options.calendar.date(byAdding: .day, value: -(days - 1), to: now) ?? now
        let range = CostUsageScanner.CostUsageDayRange(since: since, until: now, calendar: options.calendar)
        // Nil uses Application Support; test processes never resolve a default location.
        let archiveRoot = archiveRoot ?? ClaudeOrganizationUsageArchive.defaultRoot()
        return try await CostUsageScanExecutor.run { checkCancellation in
            let reports = try CostUsageScanner.loadClaudeLocalUsageReports(
                organizationIDs: organizations,
                range: range,
                now: now,
                options: options,
                checkCancellation: checkCancellation)
            try checkCancellation()
            return Self.result(
                from: reports,
                now: now,
                historyDays: days,
                calendar: range.calendar,
                archiveRoot: archiveRoot)
        }
    }

    static func result(
        from reports: CostUsageScanner.ClaudeLocalUsageReports,
        now: Date,
        historyDays: Int,
        calendar: Calendar,
        archiveRoot: URL?) -> ClaudeLocalUsageResult
    {
        let timeZone = calendar.timeZone.identifier
        let stored = ClaudeOrganizationUsageArchive.read(root: archiveRoot, timeZoneIdentifier: timeZone)
        let archive = stored.document
        let starts = [
            reports.attributionStart.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) },
            archive?.attributionStartUnixMs,
        ].compactMap(\.self)
        let attributionStart = starts.min().map { Date(timeIntervalSince1970: Double($0) / 1000) }
        var updated = archive ?? ClaudeOrganizationUsageArchive.Document(
            version: 2,
            timeZoneIdentifier: timeZone,
            attributionStartUnixMs: nil,
            owners: [:])
        updated.attributionStartUnixMs = starts.min()
        var organizations: [String: CostUsageTokenSnapshot] = [:]
        for (organization, live) in reports.organizations {
            let owner = ClaudeOrganizationUsageArchive.fingerprint(organizationID: organization, timeZone: timeZone)
            let merged = ClaudeOrganizationUsageArchive.merge(
                live: live.data,
                archived: archive?.owners[owner] ?? [])
            updated.owners[owner] = ClaudeOrganizationUsageArchive.retained(
                merged.entries,
                now: now,
                calendar: calendar)
            // Without any credential_org event no row can be attributed; absence then proves nothing.
            guard let attributionStart else { continue }
            let report = merged.usedArchive ? Self.report(entries: merged.entries, live: live) : live
            let coveredDays = Self.coveredDays(from: attributionStart, now: now, calendar: calendar)
            organizations[organization] = CostUsageFetcher.tokenSnapshot(
                from: report,
                now: now,
                historyDays: min(historyDays, coveredDays),
                calendar: calendar,
                historyCoverageIsEstablished: true,
                costProvenance: .listPriceEstimate,
                historyLabel: "Organization-attributed local transcripts since "
                    + CostUsageLocalDay.key(from: attributionStart, calendar: calendar))
        }
        if stored.canWrite, updated != archive, !reports.organizations.isEmpty {
            ClaudeOrganizationUsageArchive.save(updated, root: archiveRoot)
        }
        let machine = CostUsageFetcher.tokenSnapshot(
            from: reports.machine,
            now: now,
            historyDays: historyDays,
            calendar: calendar,
            historyCoverageIsEstablished: true,
            costProvenance: .listPriceEstimate,
            historyLabel: "Local machine transcripts")
        return ClaudeLocalUsageResult(machine: machine, organizations: organizations)
    }

    /// Inclusive civil days from the first attributable day through today.
    static func coveredDays(from start: Date, now: Date, calendar: Calendar) -> Int {
        let first = calendar.startOfDay(for: min(start, now))
        let today = calendar.startOfDay(for: now)
        return max(1, (calendar.dateComponents([.day], from: first, to: today).day ?? 0) + 1)
    }

    /// Archived days carry totals but no dated events; live intraday events stay with their days.
    private static func report(
        entries: [CostUsageDailyReport.Entry],
        live: CostUsageDailyReport) -> CostUsageDailyReport
    {
        let tokens = entries.compactMap(\.totalTokens)
        let costs = entries.compactMap(\.costUSD).filter { $0.isFinite && $0 >= 0 }
        let summary = entries.isEmpty ? nil : CostUsageDailyReport.Summary(
            totalInputTokens: CheckedSum.integers(entries.compactMap(\.inputTokens)),
            totalOutputTokens: CheckedSum.integers(entries.compactMap(\.outputTokens)),
            cacheReadTokens: CheckedSum.integers(entries.compactMap(\.cacheReadTokens)),
            cacheCreationTokens: CheckedSum.integers(entries.compactMap(\.cacheCreationTokens)),
            totalTokens: tokens.isEmpty ? nil : CheckedSum.integers(tokens),
            totalCostUSD: costs.isEmpty ? nil : costs.reduce(0, +))
        return CostUsageDailyReport(
            data: entries,
            summary: summary,
            hourly: live.hourly,
            quotaSlices: live.quotaSlices)
    }
}
