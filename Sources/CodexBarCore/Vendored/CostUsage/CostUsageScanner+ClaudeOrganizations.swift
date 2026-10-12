import Foundation

/// Organization projections over the incremental Claude transcript cache. Rows carry the organization proven by
/// a preceding `credential_org` event in the same transcript; nothing here reads the current login.
extension CostUsageScanner {
    struct ClaudeLocalUsageReports {
        /// Every Claude transcript row on this Mac, independent of ownership.
        var machine: CostUsageDailyReport
        /// Reports for each requested organization, built only from rows attributed to it.
        var organizations: [String: CostUsageDailyReport]
        /// Earliest `credential_org` event across the live transcripts; earlier rows cannot be attributed.
        var attributionStart: Date?
    }

    /// Dated events are grouped so per-render history reconstruction stays proportional to minutes, not requests.
    static let claudeOrganizationSliceInterval: TimeInterval = 5 * 60

    /// Advances the shared all-history transcript cache (unchanged files are never reparsed) and projects
    /// organization reports from its rows.
    static func loadClaudeLocalUsageReports(
        organizationIDs: Set<String>,
        range: CostUsageDayRange,
        now: Date,
        options: Options,
        checkCancellation: CancellationCheck?) throws -> ClaudeLocalUsageReports
    {
        // Provider-specific by design: credential_org attribution exists only in Claude transcripts.
        let machine = try self.loadClaudeDaily(
            provider: .claude,
            range: range,
            now: now,
            options: options,
            reportContext: .spendDashboard,
            checkCancellation: checkCancellation)
        try checkCancellation?()
        let cacheURL = CostUsageClaudeCacheIO.cacheFileURL(
            provider: .claude,
            cacheRoot: options.cacheRoot,
            reportContext: .spendDashboard)
        let pricingStamp = CostUsageClaudeFileStamp.read(at: ModelsDevCache.cacheFileURL(cacheRoot: options.cacheRoot))
        let key = ClaudeOrganizationReportMemo.Key(
            cacheStamp: CostUsageClaudeFileStamp.read(at: cacheURL),
            pricingStamp: pricingStamp,
            organizations: organizationIDs.sorted(),
            sinceKey: range.sinceKey,
            untilKey: range.untilKey,
            timeZoneIdentifier: range.calendar.timeZone.identifier)
        if key.cacheStamp != nil, let memoized = ClaudeOrganizationReportMemo.shared.value(for: key) {
            return ClaudeLocalUsageReports(
                machine: machine,
                organizations: memoized.organizations,
                attributionStart: memoized.attributionStart)
        }
        // Provider-specific by design: organization reports are projected from the Claude transcript cache only.
        let cache = CostUsageClaudeCacheIO.load(
            provider: .claude,
            cacheRoot: options.cacheRoot,
            reportContext: .spendDashboard,
            calendar: range.calendar).usage
        try checkCancellation?()
        let projected = self.claudeOrganizationReports(
            cache: cache,
            organizationIDs: organizationIDs,
            range: range,
            pricingResolver: CostUsagePricing.ClaudeResolver(now: now, cacheRoot: options.cacheRoot))
        // Never memoize a projection whose source artifact changed while it was read.
        if key.cacheStamp != nil, CostUsageClaudeFileStamp.read(at: cacheURL) == key.cacheStamp {
            ClaudeOrganizationReportMemo.shared.store(projected, for: key)
        }
        return ClaudeLocalUsageReports(
            machine: machine,
            organizations: projected.organizations,
            attributionStart: projected.attributionStart)
    }

    struct ClaudeOrganizationProjection {
        var organizations: [String: CostUsageDailyReport]
        var attributionStart: Date?
    }

    /// Each organization reconciles duplicate requests among its own rows, exactly as a per-organization
    /// filtered parse would; rows without transcript evidence never join any organization.
    static func claudeOrganizationReports(
        cache: CostUsageCache,
        organizationIDs: Set<String>,
        range: CostUsageDayRange,
        pricingResolver: CostUsagePricing.ClaudeResolver) -> ClaudeOrganizationProjection
    {
        var partitions: [String: CostUsageCache] = [:]
        for organization in organizationIDs {
            partitions[organization] = CostUsageCache()
        }
        var firstAttachment: Int64?
        for (path, file) in cache.files {
            if let attachedAt = file.claudeFirstOrganizationAttachmentUnixMs {
                firstAttachment = min(firstAttachment ?? attachedAt, attachedAt)
            }
            guard let rows = file.claudeRows else { continue }
            var owned: [String: [ClaudeUsageRow]] = [:]
            for row in rows {
                guard let organization = row.organizationID, partitions[organization] != nil else { continue }
                owned[organization, default: []].append(row)
            }
            for (organization, rows) in owned {
                partitions[organization]?.files[path] = CostUsageFileUsage(
                    mtimeUnixMs: file.mtimeUnixMs,
                    size: file.size,
                    days: [:],
                    claudeRows: rows)
            }
        }
        var reports: [String: CostUsageDailyReport] = [:]
        for (organization, partition) in partitions {
            let report = self.buildClaudeReportFromCache(
                cache: partition,
                rows: self.reconciledClaudeRows(cache: partition),
                range: range,
                pricingResolver: pricingResolver,
                includeRequestCounts: true)
            reports[organization] = CostUsageDailyReport(
                data: report.data,
                summary: report.summary,
                hourly: report.hourly,
                quotaSlices: self.coarsenedQuotaSlices(
                    report.quotaSlices,
                    interval: self.claudeOrganizationSliceInterval))
        }
        return ClaudeOrganizationProjection(
            organizations: reports,
            attributionStart: firstAttachment.map { Date(timeIntervalSince1970: Double($0) / 1000) })
    }

    /// Groups dated events into fixed intervals. Each group is stamped with its latest event, so a reading at any
    /// instant includes only usage that had happened by then; totals, costs and completeness are preserved.
    static func coarsenedQuotaSlices(_ slices: [CostUsageTimedEntry], interval: TimeInterval) -> [CostUsageTimedEntry] {
        guard interval > 0, !slices.isEmpty else { return slices }
        var groups: [(start: Double, latest: Date, totals: CostUsageTemporalTotals)] = []
        for slice in slices.sorted(by: { $0.timestamp < $1.timestamp }) {
            let start = (slice.timestamp.timeIntervalSince1970 / interval).rounded(.down) * interval
            if groups.last?.start != start {
                groups.append((start, slice.timestamp, CostUsageTemporalTotals()))
            }
            let last = groups.count - 1
            groups[last].latest = slice.timestamp
            groups[last].totals.addTokens(slice.totalTokens, isComplete: slice.tokensAreComplete)
            groups[last].totals.addCost(slice.costUSD, isComplete: slice.costIsComplete)
        }
        return groups.map { $0.totals.timedEntry(timestamp: $0.latest) }
    }
}

/// In-process projections keyed by the exact transcript artifact and pricing snapshot they were built from.
final class ClaudeOrganizationReportMemo: @unchecked Sendable {
    struct Key: Equatable {
        let cacheStamp: CostUsageClaudeFileStamp?
        let pricingStamp: CostUsageClaudeFileStamp?
        let organizations: [String]
        let sinceKey: String
        let untilKey: String
        let timeZoneIdentifier: String
    }

    #if DEBUG
    @TaskLocal static var shared = ClaudeOrganizationReportMemo()
    #else
    static let shared = ClaudeOrganizationReportMemo()
    #endif

    private let lock = NSLock()
    private var entry: (key: Key, value: CostUsageScanner.ClaudeOrganizationProjection)?

    func value(for key: Key) -> CostUsageScanner.ClaudeOrganizationProjection? {
        self.lock.withLock { self.entry?.key == key ? self.entry?.value : nil }
    }

    func store(_ value: CostUsageScanner.ClaudeOrganizationProjection, for key: Key) {
        self.lock.withLock { self.entry = (key, value) }
    }
}
