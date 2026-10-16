import CodexBarCore
import Foundation

/// Evaluates only measured, account-scoped inputs. Missing evidence never becomes a zero or an incident.
enum NativeOrbitWarningSignals {
    static let maximumQuotaAge: TimeInterval = 30 * 60
    static let maximumMoneyAge: TimeInterval = 2 * 3600

    private static func light(
        _ kind: NativeOrbitWarningLight.Kind,
        _ severity: NativeOrbitWarningLight.Severity,
        _ detail: String,
        action: NativeOrbitWarningLight.Action? = nil) -> NativeOrbitWarningLight
    {
        .init(kind, severity, detail, action: action, tooltipDetail: detail)
    }

    static func isCurrent(_ measured: Date?, at now: Date, maximumAge: TimeInterval) -> Bool {
        guard let measured else { return false }
        let age = now.timeIntervalSince(measured)
        return age >= 0 && age <= maximumAge
    }

    static func currentWindows(_ snapshot: UsageSnapshot?, at now: Date) -> [RateWindow] {
        guard self.isCurrent(snapshot?.updatedAt, at: now, maximumAge: self.maximumQuotaAge),
              let snapshot else { return [] }
        return snapshot.measuredRateWindows.filter { window in
            window.usedPercent.isFinite && window.usedPercent >= 0
                && !(window.resetsAt.map { snapshot.updatedAt < $0 && $0 <= now } ?? false)
        }
    }

    static func account(
        provider: UsageProvider,
        snapshot: UsageSnapshot?,
        metrics: NativeOrbitAccountMetrics,
        history: [PlanUtilizationSeriesHistory],
        now: Date,
        days: Int = 30,
        observedAt: Date? = nil,
        evidenceDate: Date? = nil,
        includeObservedHistory: Bool = true,
        preparedHistory: NativeOrbitPreparedWarningHistory? = nil) -> [NativeOrbitWarningLight]
    {
        var lights: [NativeOrbitWarningLight] = []
        let windows = self.currentWindows(snapshot, at: now)
        self.appendQuotaWindows(windows, snapshotUpdatedAt: snapshot?.updatedAt, now: now, to: &lights)
        if let snapshot, self.isCurrent(snapshot.updatedAt, at: now, maximumAge: self.maximumQuotaAge) {
            let status = snapshot.subscriptionStatus?.lowercased()
            if snapshot.subscriptionIsActive == false
                || ["past_due", "unpaid", "suspended", "deactivated", "inactive", "payment_failed"]
                .contains(status ?? "")
            {
                lights.append(Self.light(
                    .billing,
                    .critical,
                    "Subscription inactive or payment failed."))
            }
            if snapshot.claudeResetCreditsIneligibleReason == "cli_version" {
                lights.append(Self.light(
                    .update,
                    .caution,
                    "Update Claude Code to read saved resets.",
                    action: .settings))
            }
            lights += NativeOrbitWarningEvidence.quotaLights(
                provider: provider, snapshot: snapshot, history: history, now: now)
            if includeObservedHistory {
                let current = UsageStore.nativeOrbitQuotaWindowMap(provider: provider, snapshot: snapshot)
                let byName = Dictionary(grouping: history.filter(\.name.isNativeQuotaObservation), by: \.name)
                let changed = byName.contains { name, lanes in
                    guard let currentWindow = current[name.rawValue],
                          let minutes = currentWindow.windowMinutes else { return false }
                    let past = lanes.filter { $0.windowMinutes != minutes && $0.windowMinutes > 0 }
                        .compactMap { self.latestCapturedAt(in: $0, through: now) }.max()
                    guard let past, snapshot.updatedAt > past,
                          snapshot.updatedAt.timeIntervalSince(past) <= 86400 else { return false }
                    let currentFirst = lanes.filter { $0.windowMinutes == minutes }
                        .compactMap { self.firstCapturedAt(in: $0, after: past, through: now) }.min()
                        ?? snapshot.updatedAt
                    return now.timeIntervalSince(currentFirst) <= 86400
                }
                if changed {
                    lights.append(Self.light(
                        .limitsChanged,
                        .caution,
                        "Quota period changed."))
                }
            }
        }
        let planIsCurrent = self.planIsCurrent(
            metrics: metrics, history: history, observedAt: observedAt ?? snapshot?.updatedAt, now: evidenceDate ?? now)
        self.appendMoney(metrics, history: history, now: now, planIsCurrent: planIsCurrent, to: &lights)
        if includeObservedHistory {
            self.appendHistory(
                provider: provider,
                metrics: metrics,
                history: history,
                now: now,
                preparedHistory: preparedHistory,
                to: &lights)
        }
        self.appendUsage(
            plan: snapshot?.loginMethod(for: provider),
            metrics: metrics,
            history: history,
            now: now,
            days: days,
            includeObservedHistory: includeObservedHistory,
            preparedHistory: preparedHistory,
            to: &lights)
        if windows.contains(where: { $0.usedPercent > 0 }) { lights.removeAll { $0.kind == .idle } }
        let providerState: Set<NativeOrbitWarningLight.Kind> = [.billing, .update]
        return NativeOrbitWarningLight.reconciled(lights.map { light in
            var result = light
            result.evidence = light.evidence == .providerState || providerState.contains(light.kind)
                ? .providerState : .measurement
            return result
        })
    }

    private static func appendQuotaWindows(
        _ windows: [RateWindow], snapshotUpdatedAt: Date?, now: Date, to lights: inout [NativeOrbitWarningLight])
    {
        for window in windows where window.usedPercent.isFinite && window.usedPercent >= 0 {
            let title = self.quotaTitle(minutes: window.windowMinutes)
            if window.usedPercent >= 100 {
                lights.append(Self.light(.limit, .critical, "\(title) exhausted."))
                if let reset = window.resetsAt, let measured = snapshotUpdatedAt,
                   measured.timeIntervalSince(reset) > 600
                {
                    lights.append(Self.light(
                        .resetLate,
                        .caution,
                        "\(title) still exhausted after reset."))
                }
            }
            guard window.usedPercent > 0, window.usedPercent < 100,
                  let minutes = window.windowMinutes, minutes > 0,
                  window.resetsAt.map({ $0 > now }) == true,
                  let pace = UsagePace.weekly(window: window, now: now, defaultWindowMinutes: minutes)
            else { continue }
            switch pace.stage {
            case .behind, .farBehind:
                lights.append(Self.light(
                    .behindPace,
                    .opportunity,
                    "\(title): \(Int(abs(pace.deltaPercent).rounded())) points below pace."))
            case .slightlyAhead, .ahead:
                lights.append(Self.light(
                    .aheadOfPace,
                    .caution,
                    "\(title): \(Int(pace.deltaPercent.rounded())) points above pace."))
            case .farAhead:
                lights.append(Self.light(
                    .farAheadPace,
                    .caution,
                    "\(title): \(Int(pace.deltaPercent.rounded())) points above pace."))
            case .onTrack, .slightlyBehind: break
            }
            if window.usedPercent < 100, let eta = pace.etaSeconds, let reset = window.resetsAt,
               eta >= 0, eta < reset.timeIntervalSince(now)
            {
                let delay = NativeOrbitTooltip.countdown(to: now.addingTimeInterval(eta), now: now)
                lights.append(Self.light(
                    .limit,
                    .caution,
                    "\(title) may run out in \(delay)."))
            }
            if minutes >= 10080, let reset = window.resetsAt,
               reset.timeIntervalSince(now) <= 86400, window.remainingPercent >= 40
            {
                lights.append(Self.light(
                    .behindPace,
                    .opportunity,
                    "\(Int(window.remainingPercent.rounded()))% left; resets within 24 hours."))
            }
        }
    }

    static func quotaTitle(minutes: Int?) -> String {
        switch minutes ?? 0 {
        case 300: "Session limit"
        case 10080: "Weekly limit"
        case 1440: "Daily limit"
        case 40320...44640: "Monthly limit"
        default: minutes.map { "\($0)-min limit" } ?? "Limit"
        }
    }

    static func folderAccess(
        provider: UsageProvider, configuredPaths: [String], unavailablePaths: Set<String>) -> NativeOrbitWarningLight?
    {
        // Provider-specific by design: Antigravity alone reads the configured security-scoped usage-log folders.
        guard provider == .antigravity, !Set(configuredPaths).isDisjoint(with: unavailablePaths) else { return nil }
        return self.light(.folderAccess, .caution, "Cannot open usage-log folder.", action: .settings)
    }

    private static func planIsCurrent(
        metrics: NativeOrbitAccountMetrics,
        history: [PlanUtilizationSeriesHistory],
        observedAt: Date?,
        now: Date) -> Bool
    {
        guard let expiry = metrics.reportedPlanExpiry,
              expiry.timeIntervalSinceReferenceDate.isFinite else { return false }
        if let receipt = self.latestReceipt(in: history, name: "nativeMetric:allowances", through: now) {
            guard receipt.nativeMetrics?.planExpiryReferenceTime == expiry.timeIntervalSinceReferenceDate
            else { return false }
            return self.isCurrent(receipt.capturedAt, at: now, maximumAge: self.maximumMoneyAge)
        }
        return self.isCurrent(observedAt, at: now, maximumAge: self.maximumMoneyAge)
    }

    private static func appendMoney(
        _ metrics: NativeOrbitAccountMetrics,
        history: [PlanUtilizationSeriesHistory],
        now: Date,
        planIsCurrent: Bool,
        to lights: inout [NativeOrbitWarningLight])
    {
        if planIsCurrent, let expiry = metrics.reportedPlanExpiry, expiry.timeIntervalSince(now) <= 7 * 86400 {
            lights.append(self.light(
                .plan,
                expiry <= now ? .critical : .caution,
                expiry <= now ? "Plan ended."
                    : "Plan ends \(NativeOrbitTooltip.moment(expiry, now: now))."))
        }
        if let balance = metrics.reportedBalance, balance.value.isFinite,
           self.isCurrent(balance.updatedAt, at: now, maximumAge: self.maximumMoneyAge)
        {
            if balance.value < 0 {
                lights.append(Self.light(.credits, .critical, "Prepaid balance below zero."))
            } else if balance.value == 0, NativeOrbitWarningEvidence.wasFunded(balance, history: history) {
                lights.append(Self.light(.credits, .critical, "Prepaid credits exhausted."))
            } else if balance.value > 0,
                      let rate = NativeOrbitMonetaryInspection.balanceRate(balance, history: history),
                      rate < 0, balance.value / -rate <= 3 * 86400
            {
                lights.append(Self.light(.credits, .caution, "Credits may run out within 3 days."))
            }
        }
        if let spend = NativeOrbitMonetaryInstrument.validBudget(metrics.reportedSpend),
           self.isCurrent(spend.updatedAt, at: now, maximumAge: self.maximumMoneyAge),
           !(spend.resetsAt.map { spend.updatedAt < $0 && $0 <= now } ?? false)
        {
            if spend.used >= spend.limit {
                lights.append(Self.light(.spend, .critical, "Spending cap reached."))
            } else if spend.used / spend.limit >= 0.9 {
                lights.append(Self.light(.spend, .caution, "Spending cap at least 90% used."))
            }
            if spend.used < spend.limit, let reset = spend.resetsAt, reset > now,
               let rate = NativeOrbitMonetaryInspection.spendRate(spend, history: history), rate > 0,
               spend.used + rate * reset.timeIntervalSince(now) >= spend.limit
            {
                lights.append(Self.light(.spend, .caution, "Spending may hit cap before reset."))
            }
        }
    }

    // swiftlint:disable:next function_parameter_count
    private static func appendHistory(
        provider: UsageProvider,
        metrics: NativeOrbitAccountMetrics,
        history: [PlanUtilizationSeriesHistory],
        now: Date,
        preparedHistory: NativeOrbitPreparedWarningHistory?,
        to lights: inout [NativeOrbitWarningLight])
    {
        let event = if let preparedHistory {
            preparedHistory.earlyReset(provider: provider, at: now)
        } else {
            NativeOrbitResetEvent.events(
                quotaHistories: history.filter(\.name.isNativeQuotaObservation),
                metricHistories: history.filter { $0.name.rawValue == "nativeMetric:resets" }
                    .map { $0.prefix(through: now) },
                provider: provider,
                now: now).last(where: {
                ($0.kind == .provider || $0.kind == .early) && $0.date <= now
                    && now.timeIntervalSince($0.date) <= 86400
            })
        }
        if let event {
            lights.append(Self.light(
                .earlyReset,
                .opportunity,
                "Limits reset early \(NativeOrbitTooltip.moment(event.date, now: now))."))
        }
        if let observed = metrics.resetInventoryObservedAt, let count = metrics.bankedResets,
           observed <= now, now.timeIntervalSince(observed) <= 86400,
           let previous = history.filter({ $0.name.rawValue == "nativeMetric:resets" }).flatMap(\.entries)
               .filter({ $0.capturedAt < observed }).max(by: { $0.capturedAt < $1.capturedAt }),
               let inventory = previous.nativeMetrics?.resets,
               count > inventory.available(at: observed).count
        {
            lights.append(Self.light(
                .newSavedReset,
                .opportunity,
                "Saved reset added; \(count) available."))
        }
    }

    /// Histories are source-ordered. Bound queries instead of allocating a historical copy of every lane.
    private static func receiptCount(in lane: PlanUtilizationSeriesHistory, through date: Date) -> Int {
        var lower = 0
        var upper = lane.entries.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if lane.entries[middle].capturedAt <= date { lower = middle + 1 } else { upper = middle }
        }
        return lower
    }

    private static func latestCapturedAt(in lane: PlanUtilizationSeriesHistory, through date: Date) -> Date? {
        let count = self.receiptCount(in: lane, through: date)
        return count > 0 ? lane.entries[count - 1].capturedAt : nil
    }

    private static func firstCapturedAt(
        in lane: PlanUtilizationSeriesHistory, after date: Date, through cutoff: Date) -> Date?
    {
        let index = self.receiptCount(in: lane, through: date)
        guard index < lane.entries.count, lane.entries[index].capturedAt <= cutoff else { return nil }
        return lane.entries[index].capturedAt
    }

    private static func latestReceipt(
        in history: [PlanUtilizationSeriesHistory], name: String, through date: Date) -> PlanUtilizationHistoryEntry?
    {
        var latest: PlanUtilizationHistoryEntry?
        for lane in history where lane.name.rawValue == name {
            let count = self.receiptCount(in: lane, through: date)
            guard count > 0 else { continue }
            let timestamp = lane.entries[count - 1].capturedAt
            var lower = 0
            var upper = count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if lane.entries[middle].capturedAt < timestamp { lower = middle + 1 } else { upper = middle }
            }
            let receipt = lane.entries[lower]
            if latest.map({ $0.capturedAt < receipt.capturedAt }) ?? true { latest = receipt }
        }
        return latest
    }

    private static func dayKey(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    // swiftlint:disable:next function_parameter_count
    private static func appendUsage(
        plan: String?,
        metrics: NativeOrbitAccountMetrics,
        history: [PlanUtilizationSeriesHistory],
        now: Date,
        days: Int,
        includeObservedHistory: Bool,
        preparedHistory: NativeOrbitPreparedWarningHistory?,
        to lights: inout [NativeOrbitWarningLight])
    {
        let reports = [metrics.usage, metrics.primaryLocalUsage?.snapshot, metrics.localCostUsage?.snapshot]
            .compactMap(\.self).filter { self.isCurrent($0.updatedAt, at: now, maximumAge: self.maximumMoneyAge) }
        let localReports = [metrics.primaryLocalUsage?.snapshot, metrics.localCostUsage?.snapshot]
            .compactMap(\.self).filter { self.isCurrent($0.updatedAt, at: now, maximumAge: self.maximumMoneyAge) }
        if localReports.contains(where: \.historyScanIsPartial) {
            lights.append(Self.light(
                .localLogs,
                .caution,
                "Unreadable logs make totals incomplete."))
        }
        // A projection cannot establish any of the observations below. The real local-log failure above remains
        // meaningful, and the caller retains it; avoid reconstructing reset/activity history only to discard it.
        guard includeObservedHistory else { return }
        let lower = Calendar.current.date(byAdding: .day, value: -(max(1, days) - 1), to: now).map(self.dayKey) ?? self
            .dayKey(now)
        if reports
            .contains(where: {
                $0.daily
                    .contains { $0.date >= lower && $0.date <= self.dayKey(now) && ($0.unpricedRequestCount ?? 0) > 0 }
            })
        {
            lights.append(Self.light(
                .unpriced,
                .caution,
                "Missing prices make spend incomplete."))
        }
        if [metrics.primaryLocalUsage, metrics.localCostUsage].compactMap(\.self)
            .contains(where: { self.isCurrent($0.snapshot.updatedAt, at: now, maximumAge: self.maximumMoneyAge)
                    && $0.unattributedDays.contains { $0 >= lower && $0 <= self.dayKey(now) }
            })
        {
            lights.append(Self.light(
                .unattributed,
                .caution,
                "Some requests have no account identity."))
        }
        if self.wasUsedElsewhere(metrics: metrics, history: history, now: now, preparedHistory: preparedHistory) {
            lights.append(Self.light(
                .usedElsewhere,
                .caution,
                "Usage rose without matching requests on this Mac."))
        }
        guard let usage = metrics.usage, metrics.usageScope == .account,
              now.timeIntervalSince(usage.updatedAt) >= 0,
              now.timeIntervalSince(usage.updatedAt) <= 3600 else { return }
        var calendar = Calendar.current
        if let identifier = usage.bucketTimeZoneIdentifier, let zone = TimeZone(identifier: identifier) {
            calendar.timeZone = zone
        }
        let today = calendar.startOfDay(for: now)
        let completedAccountDays = metrics.accountUsageHistory != nil && usage.historyCoverageIsEstablished
            && (usage.coverageThrough ?? usage.updatedAt) >= today
        guard usage.historyIsFullyScanned || completedAccountDays, usage.historyDays >= 8 else { return }
        func key(_ date: Date) -> String {
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        }
        let byDate = Dictionary(grouping: usage.daily, by: \.date)
        var previous: [Int] = []
        for offset in 1...7 {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return }
            let rows = byDate[key(date)] ?? []
            if rows.isEmpty, usage.historyCoverageIsEstablished {
                previous.append(0)
            } else if rows.count == 1, let tokens = rows[0].totalTokens, tokens >= 0,
                      rows[0].incompleteRequestCount == 0
            {
                previous.append(tokens)
            } else { return }
        }
        let currentRows = byDate[key(today)] ?? []
        guard currentRows.count <= 1 else { return }
        let currentTokens = currentRows.first?.totalTokens ?? 0
        let currentComplete = currentRows.isEmpty ? usage.historyIsFullyScanned || usage.historyCoverageIsEstablished
            : currentRows[0].totalTokens != nil && currentRows[0].incompleteRequestCount == 0
        let baseline = previous.reduce(0.0) { $0 + Double($1) } / 7
        // Current-day lower bounds can prove a spike; they cannot prove inactivity.
        if baseline > 0, Double(currentTokens) >= 3 * baseline {
            lights.append(Self.light(
                .spike,
                .caution,
                "Today’s tokens are at least 3× the daily average."))
        }
        let rawPlan = plan?.lowercased() ?? ""
        let plan = rawPlan.hasPrefix("claude ") ? String(rawPlan.dropFirst(7)) : rawPlan
        let paid = ["pro", "max", "plus", "team", "business", "enterprise", "ultra"].contains {
            plan == $0 || plan.hasPrefix($0 + " ")
        }
        if paid, currentComplete, previous.allSatisfy({ $0 == 0 }), currentTokens == 0,
           !metrics.quotaConsumption.contains(where: { $0 <= now && now.timeIntervalSince($0) <= 7 * 86400 })
        {
            lights.append(Self.light(
                .idle,
                .opportunity,
                "No usage for 7 days."))
        }
    }

    private static func wasUsedElsewhere(
        metrics: NativeOrbitAccountMetrics,
        history: [PlanUtilizationSeriesHistory],
        now: Date,
        preparedHistory: NativeOrbitPreparedWarningHistory?) -> Bool
    {
        var intervals: [ClosedRange<Date>] = []
        if preparedHistory == nil {
            for lane in history where lane.name.isNativeQuotaObservation {
                for (before, after) in zip(lane.entries, lane.entries.dropFirst())
                    where after.capturedAt <= now && now.timeIntervalSince(after.capturedAt) <= 86400
                    && after.usedPercent > before.usedPercent + NativeOrbitActivity.minimumIncrease
                    && NativeOrbitActivity.sameWindow(before, after)
                {
                    intervals.append(before.capturedAt...after.capturedAt)
                }
            }
        }
        let recentIntervals = preparedHistory?.consumptionIntervals(at: now) ?? intervals[...]
        let lastConsumption = metrics.quotaConsumption.filter { $0 <= now && now.timeIntervalSince($0) <= 86400 }.max()
        guard !recentIntervals.isEmpty || lastConsumption != nil else { return false }
        return [metrics.primaryLocalUsage, metrics.localCostUsage].compactMap(\.self).contains { local in
            let report = local.snapshot
            guard local.isAccountAttributed, !local.isStale, report.historyIsFullyScanned,
                  report.updatedAt <= now, now.timeIntervalSince(report.updatedAt) <= 3600 else { return false }
            var calendar = Calendar.current
            if let identifier = local.bucketTimeZoneIdentifier ?? report.bucketTimeZoneIdentifier,
               let zone = TimeZone(identifier: identifier) { calendar.timeZone = zone }
            let through = report.coverageThrough ?? report.updatedAt
            let covered = CostReportingPeriod.rolling(days: report.historyDays).bounds(now: through, calendar: calendar)
            func dayKey(_ date: Date) -> String {
                let parts = calendar.dateComponents([.year, .month, .day], from: date)
                return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
            }
            // An exact complete request stream can rule out local use during the actual quota-rise interval,
            // even if this account was used locally earlier on the same day.
            for interval in recentIntervals where covered.lowerBound <= interval.lowerBound
                && through >= interval.upperBound && report.updatedAt >= interval.upperBound
            {
                let ambiguous = local.unattributedDays.contains {
                    $0 >= dayKey(interval.lowerBound) && $0 <= dayKey(interval.upperBound)
                }
                let localRequests = report.quotaSlices.contains {
                    $0.timestamp > interval.lowerBound && $0.timestamp <= interval.upperBound
                }
                if !ambiguous, !localRequests { return true }
            }
            guard recentIntervals.isEmpty, let consumed = lastConsumption,
                  report.updatedAt >= consumed, through >= consumed else { return false }
            let period = CostReportingPeriod.rolling(days: 1)
            let bounds = period.bounds(now: now, calendar: calendar)
            guard consumed >= bounds.lowerBound, covered.lowerBound <= bounds.lowerBound,
                  !local.unattributedDays.contains(dayKey(now)) else { return false }
            let rows = period.entries(report.daily, now: now, calendar: calendar)
            return rows.allSatisfy { $0.totalTokens == 0 && $0.incompleteRequestCount == 0 }
                && !report.quotaSlices.contains { $0.timestamp >= bounds.lowerBound && $0.timestamp <= consumed }
        }
    }
}
