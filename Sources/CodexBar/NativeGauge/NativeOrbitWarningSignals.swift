import CodexBarCore
import Foundation

/// Evaluates only measured, account-scoped inputs. Missing evidence never becomes a zero or an incident.
enum NativeOrbitWarningSignals {
    /// A quota reading stays current until the next scheduled one is overdue: the slowest automatic refresh (30
    /// minutes:
    /// adaptive refresh when idle or in Low Power Mode) plus time for the fetch itself.
    static let maximumQuotaAge: TimeInterval = 45 * 60
    static let maximumMoneyAge: TimeInterval = 2 * 3600
    /// How long a provider can take to count a request in its quota reading.
    static let quotaReportingLag: TimeInterval = 10 * 60
    /// Percentage points a quota must rise with no local request before it counts as use elsewhere. Whole-number
    /// readings can step a point with no request here (a limit that changes size moves it too).
    static let minimumUnexplainedRise = 2.0

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

    /// The current windows with the name their lights use: the provider's own windows by their length, and a window of
    /// its own (one model's weekly limit) by its title as well.
    static func currentWindows(_ snapshot: UsageSnapshot?, at now: Date) -> [(title: String, window: RateWindow)] {
        guard self.isCurrent(snapshot?.updatedAt, at: now, maximumAge: self.maximumQuotaAge),
              let snapshot else { return [] }
        let own: [(scope: String?, window: RateWindow?)] = [snapshot.primary, snapshot.secondary, snapshot.tertiary]
            .map { (nil, $0) }
        let extra = (snapshot.extraRateWindows ?? []).filter(\.usageKnown).map { named -> (String?, RateWindow?) in
            let title = named.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return (self.providerWindowIDs.contains(named.id) || title.isEmpty ? nil : title, named.window)
        }
        return (own + extra).compactMap { scope, window in
            guard let window = window?.measured, window.usedPercent.isFinite, window.usedPercent >= 0,
                  !(window.resetsAt.map { snapshot.updatedAt < $0 && $0 <= now } ?? false) else { return nil }
            let title = self.quotaTitle(minutes: window.windowMinutes)
            return (scope.map { "\(title) (\($0))" } ?? title, window)
        }
    }

    /// Lane ids of a provider's own windows, as the popup names them when it rebuilds a snapshot.
    private static let providerWindowIDs: Set<String> = [
        "primary", "secondary", "tertiary", "session", "weekly", "daily", "monthly",
    ]

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
        preparedHistory: NativeOrbitPreparedWarningHistory? = nil,
        fuelReserve: FuelReserve = .standard) -> [NativeOrbitWarningLight]
    {
        var lights: [NativeOrbitWarningLight] = []
        let named = self.currentWindows(snapshot, at: now)
        let windows = named.map(\.window)
        self.appendQuotaWindows(
            named, snapshotUpdatedAt: snapshot?.updatedAt, now: now, fuelReserve: fuelReserve, to: &lights)
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
            plan: snapshot?.loginMethod(for: provider) ?? metrics.reportedPlan,
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

    /// How much of a window is left when its fuel light comes on, as a car's low-fuel light: the lowest of the
    /// quota-warning thresholds, where the user asked to hear that an allowance is running low. Windows of a day or
    /// less take the session thresholds.
    struct FuelReserve: Equatable {
        var session: Double
        var weekly: Double

        static let standard = Self(thresholds: QuotaWarningThresholds.defaults, weekly: QuotaWarningThresholds.defaults)

        init(session: Double, weekly: Double) {
            self.session = session
            self.weekly = weekly
        }

        init(thresholds session: [Int], weekly: [Int]) {
            func lowest(_ thresholds: [Int]) -> Double {
                Double(QuotaWarningThresholds.active(thresholds).min() ?? QuotaWarningThresholds.defaults.min() ?? 0)
            }
            self.init(session: lowest(session), weekly: lowest(weekly))
        }

        func percent(minutes: Int) -> Double {
            minutes <= 1440 ? self.session : self.weekly
        }
    }

    private static func appendQuotaWindows(
        _ windows: [(title: String, window: RateWindow)],
        snapshotUpdatedAt: Date?,
        now: Date,
        fuelReserve: FuelReserve,
        to lights: inout [NativeOrbitWarningLight])
    {
        // A light names one window. When several windows raise the same kind, it shows the one that matters most:
        // the largest gap from pace, the least left.
        var strongest: [NativeOrbitWarningLight.Kind: (light: NativeOrbitWarningLight, weight: Double)] = [:]
        func raise(_ light: NativeOrbitWarningLight, weight: Double) {
            if let current = strongest[light.kind], current.weight >= weight { return }
            strongest[light.kind] = (light, weight)
        }
        defer { lights += strongest.values.map(\.light) }
        for (title, window) in windows where window.usedPercent.isFinite && window.usedPercent >= 0 {
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
            if window.usedPercent < 100, let minutes = window.windowMinutes, minutes > 0,
               window.remainingPercent <= fuelReserve.percent(minutes: minutes)
            {
                let left = Int(window.remainingPercent.rounded(.down))
                raise(Self.light(.limit, .caution, "\(title): \(left)% left."), weight: -window.remainingPercent)
            }
            guard window.usedPercent > 0, window.usedPercent < 100,
                  let minutes = window.windowMinutes, minutes > 0,
                  window.resetsAt.map({ $0 > now }) == true,
                  let pace = UsagePace.weekly(window: window, now: now, defaultWindowMinutes: minutes),
                  // As the menu's pace: a few minutes into a window, one request extrapolates to a run-out.
                  pace.expectedUsedPercent >= 3
            else { continue }
            let gap = abs(pace.deltaPercent)
            func detail(_ kind: NativeOrbitWarningLight.Kind) -> String {
                Self.paceDetail(
                    kind, title: title, used: window.usedPercent, elapsed: pace.expectedUsedPercent, minutes: minutes)
            }
            switch pace.stage {
            case .behind, .farBehind:
                raise(Self.light(.behindPace, .opportunity, detail(.behindPace)), weight: gap)
            case .slightlyAhead, .ahead:
                raise(Self.light(.aheadOfPace, .caution, detail(.aheadOfPace)), weight: gap)
            case .farAhead:
                raise(Self.light(.farAheadPace, .caution, detail(.farAheadPace)), weight: gap)
            case .onTrack, .slightlyBehind: break
            }
            if minutes >= 10080, let reset = window.resetsAt,
               reset.timeIntervalSince(now) <= 86400, window.remainingPercent >= 40
            {
                // Says the same as the gap from pace near a reset, in terms that are easier to act on.
                raise(
                    Self.light(
                        .behindPace,
                        .opportunity,
                        "\(title) resets within 24 hours with \(Int(window.remainingPercent.rounded()))% unused."),
                    weight: .infinity)
            }
        }
    }

    /// What the pace means for the limit, then the two numbers it compares: how much of the limit is used,
    /// and how much of its window has gone. At a steady rate, ahead of pace runs out before the reset.
    static func paceDetail(
        _ kind: NativeOrbitWarningLight.Kind,
        title: String,
        used: Double,
        elapsed: Double,
        minutes: Int) -> String
    {
        let outlook = switch kind {
        case .farAheadPace: "on pace to run out very early"
        case .aheadOfPace: "on pace to run out early"
        default: "on pace to have some left over"
        }
        let period = switch minutes {
        case 300: "the session"
        case 1440: "the day"
        case 10080: "the week"
        case 40320...44640: "the month"
        default: "the window"
        }
        let usedText = used > 0 && used < 1 ? "under 1%" : "\(Int(used.rounded()))%"
        return "\(title) \(outlook): \(usedText) used, \(Int(elapsed.rounded()))% of \(period) gone."
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
                      let rate = NativeOrbitMonetaryInspection.sustainedBalanceRate(balance, history: history),
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
            // As credits: a cap only worth warning about is one that spending would reach within three days.
            if spend.used < spend.limit, let reset = spend.resetsAt, reset > now,
               let rate = NativeOrbitMonetaryInspection.sustainedSpendRate(spend, history: history), rate > 0,
               spend.used + rate * min(reset.timeIntervalSince(now), 3 * 86400) >= spend.limit
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
           self.savedResetWasAdded(history: history, current: count, observedAt: observed, now: now)
        {
            lights.append(Self.light(
                .newSavedReset,
                .opportunity,
                "Saved reset added; \(count) available."))
        }
    }

    /// Whether a saved reset joined the inventory in the last day: a reading counted more available resets than the
    /// one before it. The news lasts the day, not only until the next refresh reads the same count again.
    private static func savedResetWasAdded(
        history: [PlanUtilizationSeriesHistory], current: Int, observedAt observed: Date, now: Date) -> Bool
    {
        let since = now.addingTimeInterval(-86400)
        var baseline: (date: Date, inventory: NativeOrbitResetObservation)?
        var recent: [(date: Date, inventory: NativeOrbitResetObservation)] = []
        for lane in history where lane.name.rawValue == "nativeMetric:resets" {
            for entry in lane.entries where entry.capturedAt < observed {
                guard let inventory = entry.nativeMetrics?.resets else { continue }
                if entry.capturedAt >= since {
                    recent.append((entry.capturedAt, inventory))
                } else if baseline.map({ entry.capturedAt > $0.date }) ?? true {
                    baseline = (entry.capturedAt, inventory)
                }
            }
        }
        let readings = (baseline.map { [$0] } ?? []) + recent.sorted { $0.date < $1.date }
        func rose(_ before: NativeOrbitResetObservation, to count: Int, at date: Date) -> Bool {
            count > before.available(at: date).count
        }
        if let last = readings.last, rose(last.inventory, to: current, at: observed) { return true }
        return zip(readings, readings.dropFirst()).contains { before, after in
            after.date >= since && rose(
                before.inventory,
                to: after.inventory.available(at: after.date).count,
                at: after.date)
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
        // Any named plan but a free one is paid for (Codex reports Pro Lite as "prolite").
        let paid = !plan.isEmpty && !["free", "guest", "trial"].contains { plan.contains($0) }
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
        var intervals: [NativeOrbitActivity.Rise] = []
        if preparedHistory == nil {
            for lane in history where lane.name.isNativeQuotaObservation {
                // Server period totals are not readings; a rise is between two measured ones.
                let measured = lane.entries.filter { $0.historicalPeriod == nil }
                for (before, after) in zip(measured, measured.dropFirst())
                    where after.capturedAt <= now && now.timeIntervalSince(after.capturedAt) <= 86400
                    && after.usedPercent > before.usedPercent + NativeOrbitActivity.minimumIncrease
                    && NativeOrbitActivity.sameWindow(before, after)
                {
                    intervals.append(.init(
                        lane: lane.name.rawValue,
                        interval: before.capturedAt...after.capturedAt,
                        points: after.usedPercent - before.usedPercent))
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
            var unexplained: [String: Double] = [:]
            for rise in recentIntervals where covered.lowerBound <= rise.interval.lowerBound
                && through >= rise.interval.upperBound && report.updatedAt >= rise.interval.upperBound
            {
                let interval = rise.interval
                let ambiguous = local.unattributedDays.contains {
                    $0 >= dayKey(interval.lowerBound) && $0 <= dayKey(interval.upperBound)
                }
                // The provider's figure catches up with a request minutes after it was made, so a rise can follow
                // the local request that caused it.
                let localRequests = report.quotaSlices.contains {
                    $0.timestamp > interval.lowerBound.addingTimeInterval(-self.quotaReportingLag)
                        && $0.timestamp <= interval.upperBound
                }
                if !ambiguous, !localRequests { unexplained[rise.lane, default: 0] += rise.points }
            }
            if unexplained.values.contains(where: { $0 >= self.minimumUnexplainedRise }) { return true }
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
