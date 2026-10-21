import CodexBarCore
import Foundation

enum NativeOrbitUsageScope: String {
    case account
    case localProfile
    case localMachine
}

struct NativeOrbitReportedBalance: Codable, Hashable, Sendable {
    let value: Double
    let unit: String
    let isWorkspace: Bool
    let updatedAt: Date
}

struct NativeOrbitLocalUsage {
    let snapshot: CostUsageTokenSnapshot
    let scope: NativeOrbitUsageScope
    let bucketTimeZoneIdentifier: String?
    /// Only requests whose reported quota window belongs to this account; comparable with account totals.
    var isAccountAttributed = false
    /// Retained after a failed or incomplete refresh, so its totals are lower bounds.
    var isStale = false
    /// Civil days in the local bucket zone holding requests whose serving account is unknown or ambiguous.
    var unattributedDays: Set<String> = []

    fileprivate func hasUnattributedActivity(days: Int, now: Date, calendar: Calendar) -> Bool {
        guard !self.unattributedDays.isEmpty else { return false }
        var calendar = calendar
        if let identifier = self.bucketTimeZoneIdentifier, let zone = TimeZone(identifier: identifier) {
            calendar.timeZone = zone
        }
        let markers = self.unattributedDays.map {
            CostUsageDailyReport.Entry(
                date: $0,
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: nil,
                costUSD: nil,
                modelsUsed: nil,
                modelBreakdowns: nil)
        }
        return !CostReportingPeriod.rolling(days: max(1, days)).entries(markers, now: now, calendar: calendar).isEmpty
    }
}

struct NativeOrbitMetricSummary {
    var tokens: Int?
    var cost: Double?
    var currencyCode = "USD"
    var requests: Int?
    var costIsEstimated = false
    /// Known priced subtotal; missing pricing must not make complete token counts partial.
    var costIsPartial = false
    var isPartial = false
    var usageScope: NativeOrbitUsageScope = .account
    var costUsageScope: NativeOrbitUsageScope?
    /// The token sources showed nothing for the period, but the account's quota readings rose in it: usage happened
    /// where those sources can't see it yet (another machine, or the provider's lagging statistics).
    var zeroContradictedByQuota = false
}

struct NativeOrbitPeriodSpendReading {
    let cost: Double
    let currency: String
    let period: String
    let estimated: Bool
    let isPartial: Bool
}

struct NativeOrbitAccountMetrics {
    static var empty: Self {
        Self()
    }

    /// Provider reports or explicitly labeled local-home reports; scope must stay visible to the user.
    var accountUsageHistory: NativeCodexAccountUsageHistory? {
        didSet { self.preparedAccountUsage = nil }
    }

    var usage: CostUsageTokenSnapshot?
    var usageCostPartialDays: Set<String> = []
    var usageScope: NativeOrbitUsageScope = .account
    var bucketTimeZoneIdentifier: String?
    /// A token-only account report must not hide a separately identified local cost observation.
    var localCostUsage: NativeOrbitLocalUsage?
    /// The local report standing in for `usage` when no account report exists; its stale or unattributed
    /// activity keeps totals marked as lower bounds.
    var primaryLocalUsage: NativeOrbitLocalUsage?
    var creditUsageEvents: [NativeOrbitCreditUsageEvent] = [] {
        didSet { self.preparedCreditEvents = nil }
    }

    var reportedBalance: NativeOrbitReportedBalance?
    /// Provider-reported billing-cycle spend; never relabeled as a selected calendar-period total.
    var reportedSpend: ProviderCostSnapshot?
    /// Absolute provider request allowances retain their quota period; they are not calendar-period usage totals.
    var reportedQuotaUsage: [KimiRequestQuota] = []
    /// The plan the provider names for this login, kept for checks that run on a rebuilt snapshot.
    var reportedPlan: String?
    var reportedPlanExpiry: Date?
    var usedResets = 0
    /// Instants where the account's own quota readings rose: measured consumption, wherever it happened.
    var quotaConsumption: [Date] = []
    var bankedResets: Int?
    var nextResetCreditExpiry: Date?
    var resetInventoryObservedAt: Date?

    /// Built once when an account presentation changes, shared by its value copies during inspection.
    var preparedHistory: NativeOrbitPreparedMetricHistory?
    var preparedAccountUsage: NativeOrbitPreparedAccountUsage?
    var preparedCreditEvents: [NativeOrbitCreditUsageEvent]?
    var preparedUsageSlices: [NativeOrbitPreparedUsageSlices] = []

    /// A value already prepared for this history is returned as it is: the combined popup hands every column's
    /// prepared rows to its toolbar on each opening, and rebuilding them delayed the popup by tens of milliseconds.
    func preparingInspection(history: [PlanUtilizationSeriesHistory]) -> Self {
        if self.preparedHistory?.matches(history) == true, self.preparedAccountUsage != nil,
           self.preparedCreditEvents != nil
        {
            return self
        }
        var result = self
        let prepared = NativeOrbitPreparedMetricHistory(history: history)
        result.preparedHistory = prepared
        result
            .preparedAccountUsage = NativeOrbitPreparedAccountUsage(snapshot: self.accountUsageHistory?.tokenSnapshot())
        result.preparedCreditEvents = NativeOrbitCreditUsageEvent.merging([
            self.creditUsageEvents,
            prepared.creditEvents,
        ])
        result.preparedUsageSlices = [self.usage, self.localCostUsage?.snapshot, self.primaryLocalUsage?.snapshot]
            .compactMap { $0.flatMap { NativeOrbitPreparedUsageSlices($0.quotaSlices) } }
        return result
    }

    func providerPeriodTokenReading(now: Date) -> (tokens: Int, period: String, isPartial: Bool)? {
        guard self.usageScope == .account, let usage, usage.updatedAt <= now,
              usage.daily.isEmpty, usage.quotaSlices.isEmpty,
              let tokens = usage.last30DaysTokens, tokens >= 0,
              let label = usage.historyLabel, !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return (tokens, label, usage.historyScanIsPartial)
    }

    func providerPeriodSpendReading(now: Date) -> NativeOrbitPeriodSpendReading? {
        guard self.usageScope == .account, let usage, usage.updatedAt <= now,
              usage.daily.isEmpty, usage.quotaSlices.isEmpty,
              let cost = usage.last30DaysCostUSD, cost.isFinite, cost >= 0,
              let label = usage.historyLabel, !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return NativeOrbitPeriodSpendReading(
            cost: cost,
            currency: usage.currencyCode,
            period: label,
            estimated: usage.costProvenance == .listPriceEstimate || usage.costProvenance == .mixed,
            isPartial: usage.historyScanIsPartial)
    }

    var extraUsageFraction: Double? {
        guard let spend = self.reportedSpend, spend.used.isFinite, spend.used >= 0,
              spend.limit.isFinite, spend.limit > 0 else { return nil }
        return min(1, spend.used / spend.limit)
    }

    func summary(days: Int, now: Date, calendar: Calendar = .current) -> NativeOrbitMetricSummary {
        var result = self.measuredSummary(days: days, now: now, calendar: calendar)
        // A zero contradicted by the account's own quota readings is not a measured zero: the account consumed quota
        // in this period where the token sources can't see it yet. It reads as unknown until a report covers it.
        guard result.tokens == 0 || result.cost == 0 else { return result }
        let period = CostReportingPeriod.rolling(days: max(1, days)).bounds(now: now, calendar: calendar)
        guard self.quotaConsumption.contains(where: { $0 >= period.lowerBound && $0 <= now }) else { return result }
        if result.tokens == 0 {
            result.tokens = nil
            result.requests = nil
        }
        if result.cost == 0 { result.cost = nil }
        result.zeroContradictedByQuota = true
        return result
    }

    private func measuredSummary(days: Int, now: Date, calendar: Calendar) -> NativeOrbitMetricSummary {
        var result = self.usageSummary(days: days, now: now, calendar: calendar)
        if let primary = self.primaryLocalUsage,
           primary.isStale || primary.hasUnattributedActivity(days: days, now: now, calendar: calendar)
        {
            result.isPartial = true
            result.costIsPartial = true
        }
        guard result.cost == nil || result.tokens == nil || self.localCostUsage?.isAccountAttributed == true,
              let local = self.localCostUsage else { return result }
        var localMetrics = Self(
            usage: local.snapshot,
            usageScope: local.scope,
            bucketTimeZoneIdentifier: local.bucketTimeZoneIdentifier)
        localMetrics.preparedUsageSlices = self.preparedUsageSlices
        var localSummary = localMetrics.usageSummary(days: days, now: now, calendar: calendar)
        if local.isStale || local.hasUnattributedActivity(days: days, now: now, calendar: calendar) {
            localSummary.isPartial = true
            localSummary.costIsPartial = true
        }
        // The account endpoint covers every machine but lags hours behind; window-attributed local requests are
        // real time. Both measure the same account, so each civil day takes the larger of the two counts.
        if local.isAccountAttributed, self.usageScope == .account, let usage = self.usage {
            var mergedMetrics = Self(
                usage: Self.dailyMaximum(account: usage, local: local),
                usageScope: .account,
                bucketTimeZoneIdentifier: local.bucketTimeZoneIdentifier)
            mergedMetrics.preparedUsageSlices = self.preparedUsageSlices
            let merged = mergedMetrics.usageSummary(days: days, now: now, calendar: calendar)
            if let tokens = merged.tokens {
                result.tokens = tokens
                result.requests = nil
                result.isPartial = merged.isPartial || localSummary.isPartial
            }
        }
        if result.tokens == nil, let tokens = localSummary.tokens {
            result.tokens = tokens
            result.requests = localSummary.requests
            result.usageScope = localSummary.usageScope
            result.isPartial = localSummary.isPartial
        }
        // A local known zero describes this Mac only; it cannot be the spend of an account that reported activity.
        if result.cost == nil, let cost = localSummary.cost,
           !(cost == 0 && result.usageScope == .account && (result.tokens ?? 0) > 0)
        {
            result.cost = cost
            result.currencyCode = localSummary.currencyCode
            result.costUsageScope = localSummary.usageScope
            result.costIsPartial = localSummary.costIsPartial
            result.costIsEstimated = localSummary.costIsEstimated
        }
        return result
    }

    /// Per civil day maximum of account-reported and window-attributed local tokens, keyed in the local zone.
    private static func dailyMaximum(
        account: CostUsageTokenSnapshot,
        local: NativeOrbitLocalUsage) -> CostUsageTokenSnapshot
    {
        var tokens: [String: Int] = [:]
        for entry in account.daily + local.snapshot.daily {
            guard let value = entry.totalTokens, value >= 0 else { continue }
            tokens[entry.date] = max(tokens[entry.date] ?? 0, value)
        }
        let daily = tokens.keys.sorted().map { date in
            CostUsageDailyReport.Entry(
                date: date,
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: tokens[date],
                costUSD: nil,
                modelsUsed: nil,
                modelBreakdowns: nil)
        }
        let accountThrough = account.coverageThrough ?? account.updatedAt
        let localThrough = local.snapshot.coverageThrough ?? local.snapshot.updatedAt
        return CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: nil,
            last30DaysCostUSD: nil,
            historyDays: account.historyDays,
            historyCoverageIsEstablished: account.historyCoverageIsEstablished,
            // The account's statistics day is still accumulating; every merged total is a lower bound.
            historyScanIsPartial: true,
            historyLabel: account.historyLabel,
            bucketTimeZoneIdentifier: local.bucketTimeZoneIdentifier ?? account.bucketTimeZoneIdentifier,
            coverageThrough: max(accountThrough, localThrough),
            daily: daily,
            quotaSlices: local.snapshot.quotaSlices,
            updatedAt: max(account.updatedAt, local.snapshot.updatedAt))
    }

    private func usageSummary(days: Int, now: Date, calendar: Calendar) -> NativeOrbitMetricSummary {
        guard let usage else { return NativeOrbitMetricSummary() }
        var calendar = calendar
        if let identifier = usage.bucketTimeZoneIdentifier ?? self.bucketTimeZoneIdentifier,
           let zone = TimeZone(identifier: identifier)
        {
            calendar.timeZone = zone
        }
        let period = CostReportingPeriod.rolling(days: max(1, days))
        let requested = period.bounds(now: now, calendar: calendar)
        let covered = CostReportingPeriod.rolling(days: usage.historyDays).bounds(
            now: usage.coverageThrough ?? usage.updatedAt, calendar: calendar)
        var result = NativeOrbitMetricSummary(
            currencyCode: usage.currencyCode,
            costIsEstimated: usage.costProvenance == .listPriceEstimate || usage.costProvenance == .mixed,
            isPartial: !usage.historyIsFullyScanned || covered.lowerBound > requested.lowerBound
                || covered.upperBound < requested.upperBound,
            usageScope: self.usageScope)
        if now < usage.updatedAt {
            // Completed civil days remain measured history. The inspection day's aggregate can contain
            // activity after the pointer, so use only timestamped events for that day.
            let currentDays = Set(CostReportingPeriod.rolling(days: 1)
                .entries(usage.daily, now: now, calendar: calendar).map(\.date))
            let completed = period.entries(usage.daily, now: now, calendar: calendar)
                .filter { !currentDays.contains($0.date) }
            let bounds = requested.lowerBound...now
            let slices = self.preparedUsageSlices.lazy.compactMap {
                $0.entries(matching: usage.quotaSlices, in: bounds)
            }.first ?? usage.quotaSlices.filter { $0.timestamp >= requested.lowerBound && $0.timestamp <= now }
            if !completed.isEmpty {
                // Slices arrive in time order: evaluate each civil day once, not once per request.
                var day: (interval: DateInterval, isCompleted: Bool)?
                let remainingSlices = slices.filter { slice in
                    if let day, slice.timestamp >= day.interval.start, slice.timestamp < day.interval.end {
                        return !day.isCompleted
                    }
                    let isCompleted = !CostReportingPeriod.rolling(days: 1)
                        .entries(completed, now: slice.timestamp, calendar: calendar).isEmpty
                    if let interval = calendar.dateInterval(of: .day, for: slice.timestamp) {
                        day = (interval, isCompleted)
                    }
                    return !isCompleted
                }
                result.tokens = Self.completeCount(completed.map(\.totalTokens) + remainingSlices.map(\.totalTokens))
                result.requests = Self.completeCount(completed.map(\.requestCount))
                // Missing current-day events cannot establish a complete intraday total.
                result.isPartial = true
                let costs = completed.compactMap(\.costUSD) + remainingSlices.compactMap(\.costUSD)
                let validCosts = costs.filter { $0.isFinite && $0 >= 0 }
                result.costIsPartial = true
                if !validCosts.isEmpty {
                    let cost = validCosts.reduce(0, +)
                    result.cost = cost.isFinite ? cost : nil
                }
                return result
            }
            guard !slices.isEmpty else {
                var zero = Self.coveredZeroSummary(result, usage: usage)
                // Covered data with no activity is a measured zero: a fully scanned stream, or established account
                // buckets (which omit only zero days). Day bounds are start-of-day, so the scan itself must also
                // reach the inspected instant. Without that coverage the reading stays unknown.
                let accountBucketsProveZero = self.usageScope == .account
                    && usage.daily.contains(where: { $0.totalTokens != nil })
                guard usage.historyCoverageIsEstablished, usage.historyIsFullyScanned || accountBucketsProveZero,
                      covered.lowerBound <= requested.lowerBound, covered.upperBound >= requested.upperBound,
                      (usage.coverageThrough ?? usage.updatedAt) >= now,
                      self.provesNoActivityBeforeInstant(usage, now: now, calendar: calendar)
                else { return zero }
                zero.tokens = 0
                if usage.quotaSlices.contains(where: { $0.costUSD != nil })
                    || usage.daily.contains(where: { $0.costUSD != nil })
                {
                    zero.cost = 0
                }
                return zero
            }
            result.tokens = Self.completeCount(slices.map(\.totalTokens))
            result.isPartial = result.isPartial || slices.contains { !$0.tokensAreComplete }
            let costs = slices.compactMap(\.costUSD).filter { $0.isFinite && $0 >= 0 }
            result.costIsPartial = result.isPartial || costs.count != slices.count
                || slices.contains { !$0.costIsComplete }
            if !costs.isEmpty {
                let cost = costs.reduce(0, +)
                result.cost = cost.isFinite ? cost : nil
            }
            return result
        }
        let entries = period.entries(usage.daily, now: now, calendar: calendar)
        if usage.daily.isEmpty, requested == covered, !result.isPartial {
            // Aggregate-only reports are usable for their exact coverage window, never relabeled as another range.
            result.tokens = Self.completeCount([usage.last30DaysTokens])
            result.requests = Self.completeCount([usage.last30DaysRequests])
            if let cost = usage.last30DaysCostUSD, cost.isFinite, cost >= 0 { result.cost = cost }
            return result
        }
        guard !entries.isEmpty else {
            return self.emptyPeriodSummary(result, usage: usage, requested: requested, covered: covered)
        }
        result.tokens = Self.completeCount(entries.map(\.totalTokens))
        result.requests = Self.completeCount(entries.map(\.requestCount))
        let costs = entries.compactMap(\.costUSD).filter { $0.isFinite && $0 >= 0 }
        result.costIsPartial = result.isPartial || costs.count != entries.count || entries.contains {
            self.usageCostPartialDays.contains($0.date)
                || $0.costIsPartial == true
                || $0.incompleteRequestCount > 0 || ($0.unpricedRequestCount ?? 0) > 0
                || ($0.unmeteredRequestCount ?? 0) > 0
                || ($0.modelBreakdowns ?? []).contains { breakdown in
                    breakdown.costUSD.map { !$0.isFinite || $0 < 0 } ?? true
                }
        }
        if !costs.isEmpty {
            let cost = costs.reduce(0, +)
            result.cost = cost.isFinite ? cost : nil
        }
        return result
    }

    func at(
        _ date: Date?,
        observedAt: Date?,
        history: [PlanUtilizationSeriesHistory] = [],
        historyCutoff: Date? = nil) -> Self
    {
        var result = self
        result.includeRecordedCreditEvents(from: history, cutoff: historyCutoff)
        result.includeRecordedUsage(from: history, at: date, cutoff: historyCutoff)
        guard let date else { return result }
        let accountUsageSnapshot: CostUsageTokenSnapshot? = if let prepared = self.preparedAccountUsage {
            prepared.snapshot
        } else {
            self.accountUsageHistory?.tokenSnapshot()
        }
        if let accountUsage = accountUsageSnapshot {
            // Completed civil days keep their latest corrected account total; usageSummary excludes the inspected
            // day's aggregate (it may include later activity) and uses timestamped local requests for it instead.
            if let primary = result.primaryLocalUsage {
                result.localCostUsage = primary
                result.primaryLocalUsage = nil
            }
            result.usage = accountUsage
            result.usageScope = .account
            result.bucketTimeZoneIdentifier = nil
            result.usageCostPartialDays = []
        }
        result.reportedSpend = nil
        result.reportedBalance = nil
        result.bankedResets = nil
        result.usedResets = 0
        result.nextResetCreditExpiry = nil
        result.resetInventoryObservedAt = nil
        result.reportedQuotaUsage = []
        result.reportedPlanExpiry = nil
        result.restoreHistoricalMetrics(from: history, at: date, cutoff: historyCutoff)
        return result
    }

    /// The live readings (`at(nil, …)`) carried forward to a future instant. Banked resets that expire before the
    /// instant are gone (and used ones whose grants ended no longer count); an additional-usage cycle that restarts
    /// before it starts from zero; balances and allowances hold.
    func projected(at date: Date, inventory: NativeOrbitResetObservation?) -> Self {
        var result = self
        if let inventory, result.bankedResets != nil {
            let available = inventory.available(at: date)
            result.bankedResets = available.count
            result.usedResets = inventory.used(at: date)
            result.nextResetCreditExpiry = available.compactMap(\.self).min()
        }
        if let spend = result.reportedSpend, spend.isDisabled != true, let reset = spend.resetsAt, reset <= date {
            result.reportedSpend = ProviderCostSnapshot(
                used: 0,
                limit: spend.limit,
                currencyCode: spend.currencyCode,
                period: spend.period,
                resetsAt: nil,
                nextRegenAmount: spend.nextRegenAmount,
                personalUsed: spend.personalUsed.map { _ in 0 },
                balance: spend.balance,
                balanceUpdatedAt: spend.balanceUpdatedAt,
                balanceIsWorkspace: spend.balanceIsWorkspace,
                usageIsUnavailable: spend.usageIsUnavailable,
                isDisabled: spend.isDisabled,
                updatedAt: spend.updatedAt)
        }
        return result
    }

    /// A covered calendar period with no events is a measured zero: the data for it exists and shows no activity.
    /// An aggregate-only nonzero report cannot describe a shorter period, and incomplete scans cannot prove absence.
    private func emptyPeriodSummary(
        _ summary: NativeOrbitMetricSummary,
        usage: CostUsageTokenSnapshot,
        requested: ClosedRange<Date>,
        covered: ClosedRange<Date>) -> NativeOrbitMetricSummary
    {
        var result = summary
        if !result.isPartial, !usage.daily.isEmpty {
            if usage.last30DaysTokens != nil || usage.daily.contains(where: { $0.totalTokens != nil }) {
                result.tokens = 0
            }
            if usage.last30DaysCostUSD != nil || usage.daily.contains(where: { $0.costUSD != nil }) {
                result.cost = 0
            }
            if usage.last30DaysRequests != nil || usage.daily.contains(where: { $0.requestCount != nil }) {
                result.requests = 0
            }
        } else if !result.isPartial {
            // Nonnegative aggregate zero proves zero in subranges, independently for each supported metric.
            if usage.last30DaysTokens == 0 { result.tokens = 0 }
            if usage.last30DaysCostUSD == 0 { result.cost = 0 }
            if usage.last30DaysRequests == 0 { result.requests = 0 }
        } else if self.usageScope == .account, usage.historyCoverageIsEstablished,
                  covered.lowerBound <= requested.lowerBound, covered.upperBound >= requested.upperBound,
                  usage.daily.contains(where: { $0.totalTokens != nil })
        {
            // Account buckets whose coverage is established omit only zero days. The latest statistics day may
            // still grow, so the zero stays a partial lower bound.
            result.tokens = 0
        }
        return result
    }

    /// A scanned local event stream (or a covered day with no activity at all) proves nothing ran before the
    /// inspected instant; an account day total alone could include activity after it.
    private func provesNoActivityBeforeInstant(
        _ usage: CostUsageTokenSnapshot,
        now: Date,
        calendar: Calendar) -> Bool
    {
        let day = CostReportingPeriod.rolling(days: 1)
        if self.usageScope != .account, !usage.quotaSlices.isEmpty {
            // A day total whose dated events are gone (archived after its transcripts were pruned) cannot place its
            // activity relative to the instant.
            let dayTotal = day.entries(usage.daily, now: now, calendar: calendar).compactMap(\.totalTokens).reduce(0, +)
            guard dayTotal > 0, let interval = calendar.dateInterval(of: .day, for: now) else { return true }
            return usage.quotaSlices.contains { interval.contains($0.timestamp) }
        }
        return !usage.daily.contains {
            ($0.totalTokens ?? 0) > 0 && !day.entries([$0], now: now, calendar: calendar).isEmpty
        }
    }

    private static func coveredZeroSummary(
        _ summary: NativeOrbitMetricSummary,
        usage: CostUsageTokenSnapshot) -> NativeOrbitMetricSummary
    {
        var result = summary
        // A complete nonnegative aggregate zero proves absence in a covered subrange.
        if !result.isPartial {
            if usage.last30DaysTokens == 0 { result.tokens = 0 }
            if usage.last30DaysCostUSD == 0 { result.cost = 0 }
            if usage.last30DaysRequests == 0 { result.requests = 0 }
        }
        return result
    }

    private static func completeCount(_ values: [Int?]) -> Int? {
        var total = 0
        for value in values {
            guard let value, value >= 0 else { return nil }
            let sum = total.addingReportingOverflow(value)
            guard !sum.overflow else { return nil }
            total = sum.partialValue
        }
        return total
    }

    static func make(
        provider: UsageProvider,
        snapshot: UsageSnapshot?,
        usage: CostUsageTokenSnapshot?,
        now: Date,
        credits: CreditsSnapshot? = nil,
        localUsage: NativeOrbitLocalUsage? = nil,
        quotaHistory: [PlanUtilizationSeriesHistory] = []) -> Self
    {
        var result = Self(usage: usage)
        result.quotaConsumption = NativeOrbitActivity.consumptionDates(quotaHistory)
        result.resetInventoryObservedAt = snapshot?.updatedAt
        result.reportedPlan = snapshot?.loginMethod(for: provider)
        // Provider-specific by design: Kimi's subscription expiry is its monthly pool's renewal, which recurs and is
        // already shown as that pool's reset; it never means the plan ends.
        result.reportedPlanExpiry = provider == .kimi ? nil : snapshot?.subscriptionExpiresAt
        // Provider-specific by design: Kimi alone publishes typed request allowances; retain their request units.
        if provider == .kimi, snapshot?.identity(for: .kimi) != nil {
            result.reportedQuotaUsage = (snapshot?.kimiRequestQuotas ?? []).filter { $0.used >= 0 && $0.limit > 0 }
        }
        if usage == nil, let localUsage {
            result.usage = localUsage.snapshot
            result.usageScope = localUsage.scope
            result.bucketTimeZoneIdentifier = localUsage.bucketTimeZoneIdentifier
            result.primaryLocalUsage = localUsage
        } else if let localUsage {
            result.localCostUsage = localUsage
        }
        if let cost = snapshot?.providerCost, let balance = cost.balance, balance.isFinite {
            result.reportedBalance = NativeOrbitReportedBalance(
                value: balance,
                unit: cost.currencyCode,
                isWorkspace: cost.balanceIsWorkspace == true,
                updatedAt: cost.balanceUpdatedAt ?? cost.updatedAt)
        }
        // Provider-specific by design: Codex additional usage is denominated in credits and joins its owned balance.
        let reportedCost = provider == .codex
            ? CodexExtraUsageCost.resolving(liveCredits: credits, attached: snapshot?.providerCost)
            : snapshot?.providerCost
        if let spend = reportedCost, spend.usageIsUnavailable != true,
           Locale.commonISOCurrencyCodes.contains(spend.currencyCode.uppercased())
           || (provider == .codex && spend.currencyCode == CodexExtraUsageCost.currencyCode && spend.limit > 0),
           spend.used.isFinite, spend.used >= 0,
           spend.personalUsed.map({ $0.isFinite && $0 >= 0 }) ?? true
        {
            result.reportedSpend = spend
        }
        // Provider-specific by design: only these payloads report real redeemable reset inventories.
        switch provider {
        case .codex:
            result.creditUsageEvents = (credits?.events ?? []).filter {
                $0.creditsUsed.isFinite && $0.creditsUsed >= 0 && $0.date <= (credits?.updatedAt ?? now)
            }.map(NativeOrbitCreditUsageEvent.init)
            if let credits, let balance = Self.codexBalance(credits),
               balance.isFinite, balance >= 0
            {
                result.reportedBalance = NativeOrbitReportedBalance(
                    value: balance,
                    unit: CodexExtraUsageCost.currencyCode,
                    isWorkspace: credits.hasWorkspaceBalance,
                    updatedAt: credits.updatedAt)
            }
            if let inventory = snapshot?.codexResetCredits?.availableInventory(at: now) {
                result.resetInventoryObservedAt = snapshot?.codexResetCredits?.updatedAt
                result.bankedResets = inventory.count
                result.usedResets = snapshot?.codexResetCredits?.credits.filter {
                    guard $0.status == .redeemed, let redeemed = $0.redeemedAt else { return false }
                    return redeemed <= now && now.timeIntervalSince(redeemed) < 86400
                }.count ?? 0
                result.nextResetCreditExpiry = inventory.credits.compactMap(\.expiresAt).min()
            }
        // Provider-specific by design: Claude and Grok publish dated reset inventories in distinct payload fields.
        case .claude:
            if let expirations = snapshot?.claudeResetCredits?.availableExpirations(at: now) {
                result.resetInventoryObservedAt = snapshot?.claudeResetCredits?.updatedAt
                result.bankedResets = expirations.count
                result.usedResets = snapshot?.claudeResetCredits?.usedExpirations.filter {
                    $0.map { $0 > now } ?? true
                }.count ?? 0
                result.nextResetCreditExpiry = expirations.compactMap(\.self).min()
            }
        case .grok:
            if let expirations = snapshot?.grokResetCredits?.availableExpirations(at: now) {
                result.resetInventoryObservedAt = snapshot?.grokResetCredits?.updatedAt
                result.bankedResets = expirations.count
                result.nextResetCreditExpiry = expirations.min()
            }
        default: break
        }
        return result
    }

    private static func codexBalance(_ credits: CreditsSnapshot) -> Double? {
        guard credits.balanceReadSucceeded else { return nil }
        if credits.codexCreditLimit == nil || credits.hasWorkspaceBalance { return credits.remaining }
        return CodexExtraUsageCost.purchasedExtraCreditsBalance(from: credits)
    }
}
