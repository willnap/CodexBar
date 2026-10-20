import CodexBarCore
import Foundation

/// Money follows its own dated receipts. Token activity and another source's spend never price a wallet.
enum NativeOrbitMonetaryInspection {
    static func reading(
        mode: NativeOrbitMonetaryInstrument.Mode,
        account: NativeOrbitAccountPresentation,
        date: Date?,
        now: Date,
        days: Int,
        projection: NativeOrbitAccountProjection? = nil,
        spending: NativeOrbitSpendingHistory? = nil) -> NativeOrbitMonetaryInstrument.Reading
    {
        guard let date else {
            return NativeOrbitMonetaryInstrument.reading(
                mode: mode,
                metrics: projection?.liveMetrics ?? account.metrics.at(
                    nil, observedAt: account.updatedAt, history: account.history),
                days: days,
                now: now)
        }
        if date <= now {
            if mode == .spend, let spending, let bar = spending.bar(at: date) {
                return .init(
                    amount: bar.cost,
                    currencyCode: spending.currencyCode,
                    kind: mode,
                    period: bar.granularity == .daily ? "Daily total" : bar.granularity == .hourly
                        ? "Hourly spend" : "Request spend",
                    estimated: bar.isEstimated,
                    partial: bar.isPartial,
                    scope: spending.scope)
            }
            return NativeOrbitMonetaryInstrument.reading(
                mode: mode,
                metrics: account.metrics.at(date, observedAt: account.updatedAt, history: account.history),
                days: days,
                now: date)
        }
        let live = projection?.liveMetrics ?? account.metrics.at(
            nil, observedAt: account.updatedAt, history: account.history)
        if mode == .spend, let projection {
            let summary = projection.summary(days: days, at: date).summary
            if let cost = summary.cost, cost.isFinite, cost >= 0 {
                return .init(
                    amount: cost,
                    currencyCode: summary.currencyCode,
                    kind: mode,
                    period: NativeOrbitTooltip.range(days: days),
                    estimated: true,
                    partial: summary.costIsPartial,
                    scope: summary.costUsageScope ?? summary.usageScope,
                    projected: true)
            }
        }
        let metrics = self.projectedMetrics(
            metrics: live, history: account.history, at: date, now: now, projection: projection)
        // A projected dated-spend summary is evaluated above. Re-reading the live usage report here would show
        // recorded activity as a future amount even when its pace is unknown.
        var monetary = metrics
        monetary.usage = nil
        monetary.localCostUsage = nil
        monetary.primaryLocalUsage = nil
        var reading = NativeOrbitMonetaryInstrument.reading(mode: mode, metrics: monetary, days: days, now: date)
        reading.estimated = true
        reading.projected = true
        return reading
    }

    static func projectedMetrics(
        metrics: NativeOrbitAccountMetrics,
        history: [PlanUtilizationSeriesHistory],
        at date: Date,
        now: Date,
        projection: NativeOrbitAccountProjection? = nil) -> NativeOrbitAccountMetrics
    {
        var result = metrics.projected(at: date, inventory: projection?.resetInventory)
        result.reportedBalance = nil
        result.reportedSpend = nil
        if let balance = metrics.reportedBalance, self.fresh(balance.updatedAt, now: now), balance.value.isFinite {
            if let rate = self.balanceRate(balance, history: history) {
                let extrapolated = balance.value + rate * max(0, date.timeIntervalSince(balance.updatedAt))
                // A funded wallet does not establish permission to incur debt. An actually reported negative
                // balance retains its provider's debt semantics.
                let amount = balance.value >= 0 ? max(0, extrapolated) : extrapolated
                if amount.isFinite {
                    result.reportedBalance = .init(
                        value: amount, unit: balance.unit, isWorkspace: balance.isWorkspace, updatedAt: date)
                }
            }
        }
        if let spend = metrics.reportedSpend, self.fresh(spend.updatedAt, now: now),
           spend.isDisabled != true, spend.usageIsUnavailable != true, spend.used.isFinite, spend.used >= 0
        {
            var projectedUsed: Double?
            if NativeOrbitMonetaryInstrument.validBudget(spend) != nil, spend.used <= spend.limit,
               let lane = projection?.lane("nativeQuota:monetary-budget"),
               abs(lane.originUsed - min(100, spend.used / spend.limit * 100)) < 0.5,
               abs(lane.origin.timeIntervalSince(spend.updatedAt)) <= NativeOrbitAccountMetrics.sameRefreshSkew
            {
                projectedUsed = lane.used(at: date) / 100 * spend.limit
            } else if let rate = self.spendRate(spend, history: history) {
                if let reset = spend.resetsAt, reset > now, date >= reset {
                    projectedUsed = rate * date.timeIntervalSince(reset)
                } else if spend.resetsAt.map({ $0 <= now }) != true {
                    projectedUsed = spend.used + rate * max(0, date.timeIntervalSince(spend.updatedAt))
                }
            }
            if let used = projectedUsed, used.isFinite, used >= 0 {
                result.reportedSpend = .init(
                    used: used,
                    limit: spend.limit,
                    currencyCode: spend.currencyCode,
                    period: spend.period,
                    resetsAt: spend.resetsAt.flatMap { $0 > date ? $0 : nil },
                    usageIsUnavailable: false,
                    updatedAt: date)
            }
        }
        return result
    }

    /// A same-source monetary change can expose the chart's future even when this account has no quota lane.
    static func lastActivity(
        metrics: NativeOrbitAccountMetrics, history: [PlanUtilizationSeriesHistory], now: Date) -> Date?
    {
        var dates: [Date] = []
        func recent(_ date: Date) -> Bool {
            date <= now && now.timeIntervalSince(date) <= NativeOrbitActivity.window
        }
        if let balance = metrics.reportedBalance, recent(balance.updatedAt),
           let rate = self.balanceRate(balance, history: history), rate < 0
        {
            dates.append(balance.updatedAt)
        }
        if let spend = metrics.reportedSpend, recent(spend.updatedAt),
           let rate = self.spendRate(spend, history: history), rate > 0,
           spend.resetsAt.map({ $0 > now }) ?? true
        {
            dates.append(spend.updatedAt)
        }
        return dates.max()
    }

    static func balanceRate(
        _ balance: NativeOrbitReportedBalance, history: [PlanUtilizationSeriesHistory]) -> Double?
    {
        let previous = self.previousReceipt("balance", history: history, before: balance.updatedAt)
        guard let previous, let prior = previous.nativeMetrics?.balance,
              prior.unit.uppercased() == balance.unit.uppercased(), prior.isWorkspace == balance.isWorkspace,
              let rate = self.rate(
                  from: prior.value,
                  at: previous.capturedAt,
                  to: balance.value,
                  at: balance.updatedAt),
              rate <= 0 else { return nil }
        return rate
    }

    static func spendRate(_ spend: ProviderCostSnapshot, history: [PlanUtilizationSeriesHistory]) -> Double? {
        let previous = self.previousReceipt("spend", history: history, before: spend.updatedAt)
        guard spend.isDisabled != true, spend.usageIsUnavailable != true, spend.used >= 0,
              let previous, let prior = previous.nativeMetrics?.spend(at: previous.capturedAt),
              prior.currencyCode.uppercased() == spend.currencyCode.uppercased(),
              prior.limit == spend.limit, prior.period == spend.period, prior.resetsAt == spend.resetsAt,
              prior.used >= 0, prior.isDisabled != true, prior.usageIsUnavailable != true,
              let rate = self.rate(from: prior.used, at: previous.capturedAt, to: spend.used, at: spend.updatedAt),
              rate >= 0 else { return nil }
        return rate
    }

    /// The balance's rate for warnings: the immediately prior receipt must continue a depletion (as `balanceRate`), and
    /// the
    /// rate runs back through the unbroken depletion before it, up to a day. One refresh's change, carried days
    /// ahead, would warn about almost any spending.
    static func sustainedBalanceRate(
        _ balance: NativeOrbitReportedBalance, history: [PlanUtilizationSeriesHistory]) -> Double?
    {
        guard let immediate = self.balanceRate(balance, history: history), immediate < 0,
              let rate = self.consumptionRate("balance", history: history, at: balance.updatedAt, now: -balance.value, {
                  guard let prior = $0.nativeMetrics?.balance, prior.value.isFinite,
                        prior.unit.uppercased() == balance.unit.uppercased(), prior.isWorkspace == balance.isWorkspace
                  else { return nil }
                  return -prior.value
              }) else { return nil }
        return -rate
    }

    /// Spending's rate for warnings: the immediately prior receipt must continue spending (as `spendRate`), and the
    /// rate runs
    /// back through the unbroken spending in the same cycle before it, up to a day.
    static func sustainedSpendRate(
        _ spend: ProviderCostSnapshot, history: [PlanUtilizationSeriesHistory]) -> Double?
    {
        guard let immediate = self.spendRate(spend, history: history), immediate > 0 else { return nil }
        return self.consumptionRate("spend", history: history, at: spend.updatedAt, now: spend.used) {
            guard let prior = $0.nativeMetrics?.spend(at: $0.capturedAt),
                  prior.currencyCode.uppercased() == spend.currencyCode.uppercased(), prior.limit == spend.limit,
                  prior.period == spend.period, prior.resetsAt == spend.resetsAt, prior.used.isFinite,
                  prior.used >= 0, prior.isDisabled != true, prior.usageIsUnavailable != true else { return nil }
            return prior.used
        }
    }

    /// Consumption per second since the start of the unbroken run that ends at a reading: walking back through the
    /// last day's receipts while each is comparable (`consumed` is non-nil) and had consumed no more than the next.
    private static func consumptionRate(
        _ name: String,
        history: [PlanUtilizationSeriesHistory],
        at date: Date,
        now: Double,
        _ consumed: (PlanUtilizationHistoryEntry) -> Double?) -> Double?
    {
        let receipts = history.filter { $0.name.rawValue == "nativeMetric:" + name }.flatMap(\.entries)
            .filter { $0.capturedAt < date && date.timeIntervalSince($0.capturedAt) <= 86400 }
            .sorted { $0.capturedAt > $1.capturedAt }
        var start = (date: date, amount: now)
        for receipt in receipts {
            guard let amount = consumed(receipt), amount <= start.amount else { break }
            start = (receipt.capturedAt, amount)
        }
        let span = date.timeIntervalSince(start.date)
        let rate = (now - start.amount) / span
        return span > 0 && rate.isFinite && rate >= 0 ? rate : nil
    }

    private static func previousReceipt(
        _ name: String, history: [PlanUtilizationSeriesHistory], before date: Date) -> PlanUtilizationHistoryEntry?
    {
        var previous: PlanUtilizationHistoryEntry?
        for lane in history where lane.name.rawValue == "nativeMetric:" + name {
            for entry in lane.entries where entry.capturedAt < date {
                // sorted().last selected the last source entry when timestamps tied; retain that rule.
                if previous.map({ entry.capturedAt >= $0.capturedAt }) ?? true { previous = entry }
            }
        }
        return previous
    }

    private static func fresh(_ date: Date, now: Date) -> Bool {
        date <= now && now.timeIntervalSince(date) <= NativeOrbitAccountProjection.maximumReadingAge
    }

    private static func rate(from start: Double, at first: Date, to end: Double, at last: Date) -> Double? {
        let span = last.timeIntervalSince(first)
        guard start.isFinite, end.isFinite, span >= NativeOrbitAccountProjection.minimumPaceSpan,
              span <= NativeOrbitAccountProjection.maximumReadingAge else { return nil }
        let rate = (end - start) / span
        return rate.isFinite ? rate : nil
    }
}
