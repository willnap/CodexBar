import CodexBarCore
import Foundation

/// Dated costs in one source scope and currency. Billing-cycle counters never become calendar buckets.
struct NativeOrbitSpendingHistory {
    enum Granularity: String {
        case event, hourly, daily
    }

    struct Bar: Identifiable, Equatable {
        let start: Date
        let end: Date
        let observedAt: Date
        let cost: Double
        let granularity: Granularity
        let isEstimated: Bool
        let isPartial: Bool

        var id: String {
            "\(self.granularity.rawValue):\(self.start.timeIntervalSinceReferenceDate)"
        }
    }

    let bars: [Bar]
    let currencyCode: String
    let scope: NativeOrbitUsageScope
    let emphasizesQuota: Bool
    private let maximumCost: Double
    private let intervalEndPrefix: [Date]
    /// A genuine budget ratio recorded at the source's observation time, for money-only providers.
    let budgetHistory: PlanUtilizationSeriesHistory?

    /// Immutable chart inputs: reused by every pointer frame instead of filtering and stringifying all bars.
    let observationDates: [Date]
    let signature: [String]

    private init(
        bars: [Bar],
        currencyCode: String,
        scope: NativeOrbitUsageScope,
        emphasizesQuota: Bool,
        maximumCost: Double,
        budgetHistory: PlanUtilizationSeriesHistory?)
    {
        self.bars = bars
        self.currencyCode = currencyCode
        self.scope = scope
        self.emphasizesQuota = emphasizesQuota
        self.maximumCost = maximumCost
        self.budgetHistory = budgetHistory
        var lastEnd = Date.distantPast
        self.intervalEndPrefix = bars.map { bar in
            if bar.granularity != .event { lastEnd = max(lastEnd, bar.end) }
            return lastEnd
        }
        // A daily aggregate has an interval, never an invented intraday observation.
        self.observationDates = bars.filter { $0.granularity != .daily }.map(\.start)
        self.signature = ["\(currencyCode)|\(scope.rawValue)|\(emphasizesQuota)"] + bars.map {
            "\($0.id)|\($0.end.timeIntervalSinceReferenceDate)|\($0.cost)|\($0.isEstimated)|\($0.isPartial)"
        } + (budgetHistory?.entries.map {
            "budget|\($0.capturedAt.timeIntervalSinceReferenceDate)|\($0.usedPercent)|"
                + "\($0.resetsAt?.timeIntervalSinceReferenceDate ?? 0)"
        } ?? [])
    }

    var maximumAmount: Double {
        self.maximumCost
    }

    /// Bars share the existing plot, with their own unlabeled relative height. Percentage lanes retain 0...100.
    func height(_ bar: Bar) -> Double {
        guard self.maximumCost > 0 else { return 0 }
        return bar.cost / self.maximumCost * 90
    }

    func bar(at date: Date) -> Bar? {
        // A UTC hourly bucket can overlap the next local daily bucket. Keep the original first matching source
        // even there: a prefix of interval ends finds the earliest containing bucket in logarithmic time.
        var lower = 0
        var upper = self.bars.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if self.bars[middle].start < date { lower = middle + 1 } else { upper = middle }
        }
        let exact = lower < self.bars.count && self.bars[lower].start == date ? lower : nil
        let started = exact.map { $0 + 1 } ?? lower
        lower = 0
        upper = started
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if self.intervalEndPrefix[middle] <= date { lower = middle + 1 } else { upper = middle }
        }
        let interval = lower < started ? lower : nil
        let index: Int? = if let exact, let interval {
            min(exact, interval)
        } else {
            exact ?? interval
        }
        return index.map { self.bars[$0] }
    }

    func help(at date: Date) -> String {
        self.bar(at: date).map(self.help) ?? "Spend · No observation at this time"
    }

    func help(_ bar: Bar) -> String {
        let amount = bar.cost.formatted(.currency(code: self.currencyCode).precision(.fractionLength(2...6)))
        let scope = switch self.scope {
        case .account: "Account"
        case .localProfile: "Local profile"
        case .localMachine: "Local machine"
        }
        let kind = switch bar.granularity {
        case .event: "Request spend"
        case .hourly: "Hourly spend"
        case .daily: "Daily total"
        }
        var text = "\(amount) \(self.currencyCode) spent · \(scope) · \(kind)"
        if bar.isEstimated { text += " · Estimated" }
        if bar.isPartial { text += " · Partial" }
        return text
    }

    private struct Report {
        let snapshot: CostUsageTokenSnapshot
        let scope: NativeOrbitUsageScope
        let zone: String?
        let isPartial: Bool
    }

    static func make(
        metrics: NativeOrbitAccountMetrics,
        history: [PlanUtilizationSeriesHistory],
        now: Date,
        days: Int,
        calendar: Calendar = .current,
        emphasizesQuota: Bool = false) -> Self
    {
        var accountReports = history.filter { $0.name.rawValue == "nativeMetric:usage" }.flatMap(\.entries)
            .filter { $0.capturedAt <= now }.sorted { $0.capturedAt < $1.capturedAt }.compactMap { entry in
                entry.nativeMetrics?.usage?.snapshot(at: entry.capturedAt).map {
                    Report(snapshot: $0, scope: .account, zone: $0.bucketTimeZoneIdentifier, isPartial: false)
                }
            }
        if let report = metrics.usage, metrics.usageScope == .account {
            accountReports.append(Report(
                snapshot: report,
                scope: .account,
                zone: report.bucketTimeZoneIdentifier ?? metrics.bucketTimeZoneIdentifier,
                isPartial: false))
        }
        var localReports: [Report] = []
        if let local = metrics.primaryLocalUsage {
            localReports.append(Report(
                snapshot: local.snapshot,
                scope: local.scope,
                zone: local.bucketTimeZoneIdentifier ?? local.snapshot.bucketTimeZoneIdentifier,
                isPartial: local.isStale || !local.unattributedDays.isEmpty))
        } else if let report = metrics.usage, metrics.usageScope != .account {
            localReports.append(Report(
                snapshot: report,
                scope: metrics.usageScope,
                zone: report.bucketTimeZoneIdentifier ?? metrics.bucketTimeZoneIdentifier,
                isPartial: false))
        }
        if let local = metrics.localCostUsage {
            localReports.append(Report(
                snapshot: local.snapshot,
                scope: local.scope,
                zone: local.bucketTimeZoneIdentifier ?? local.snapshot.bucketTimeZoneIdentifier,
                isPartial: local.isStale || !local.unattributedDays.isEmpty))
        }
        // Select a priced source; account and local reports are never added together or currency-converted.
        let account = Self.selectedReports(accountReports)
        let local = Self.selectedReports(localReports)
        let accountBars = Self.bars(account, now: now, days: days, calendar: calendar)
        let reports = accountBars.isEmpty ? local : account
        let bars = accountBars.isEmpty ? Self.bars(local, now: now, days: days, calendar: calendar) : accountBars
        let latest = reports.last
        return Self(
            bars: bars,
            currencyCode: latest?.snapshot.currencyCode ?? metrics.reportedSpend?.currencyCode ?? "USD",
            scope: latest?.scope ?? .account,
            emphasizesQuota: emphasizesQuota,
            maximumCost: bars.map(\.cost).max() ?? 0,
            budgetHistory: Self.budgetHistory(metrics: metrics, history: history, now: now))
    }

    private static func selectedReports(_ reports: [Report]) -> [Report] {
        let ordered = reports.enumerated().sorted {
            let first = $0.element.snapshot.updatedAt
            let second = $1.element.snapshot.updatedAt
            return first == second ? $0.offset < $1.offset : first < second
        }.map(\.element)
        guard let latest = ordered.last else { return [] }
        return ordered.filter {
            $0.scope == latest.scope && $0.snapshot.currencyCode == latest.snapshot.currencyCode
                && $0.zone == latest.zone
        }
    }

    private static func bars(_ reports: [Report], now: Date, days: Int, calendar: Calendar) -> [Bar] {
        guard let latest = reports.last else { return [] }
        var sourceCalendar = Calendar(identifier: .gregorian)
        sourceCalendar.timeZone = latest.zone.flatMap(TimeZone.init(identifier:)) ?? calendar.timeZone
        let start = CostReportingPeriod.rolling(days: max(1, days)).bounds(now: now, calendar: calendar).lowerBound
        let formatter = DateFormatter()
        formatter.calendar = sourceCalendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = sourceCalendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        var daily: [Date: (CostUsageDailyReport.Entry, Report, Date)] = [:]
        for report in reports {
            for entry in report.snapshot.daily {
                guard let day = formatter.date(from: entry.date), formatter.string(from: day) == entry.date,
                      let end = sourceCalendar.date(byAdding: .day, value: 1, to: day),
                      day <= now, end > start,
                      report.snapshot.updatedAt <= now || end <= now else { continue }
                // A later receipt corrects the day, including a correction to unknown. Polls are not new spend.
                daily[day] = (entry, report, end)
            }
        }
        let report = latest.snapshot
        let estimated = report.costProvenance == .listPriceEstimate || report.costProvenance == .mixed
        let partial = latest.isPartial || report.historyScanIsPartial
        let events = report.quotaSlices.filter { $0.timestamp >= start && $0.timestamp <= now }
        let hourly = report.hourly.filter { $0.hour >= start && $0.hour <= now }
        var timed: [Bar] = []
        if events.contains(where: { $0.costUSD.map(Self.validCost) == true }) {
            // Multiple real requests may share a timestamp. Sum within this snapshot only, never across polls.
            timed = Dictionary(grouping: events, by: \.timestamp).compactMap { date, entries in
                let costs = entries.compactMap(\.costUSD).filter(Self.validCost)
                guard !costs.isEmpty else { return nil }
                let cost = costs.reduce(0, +)
                guard cost.isFinite else { return nil }
                return Bar(
                    start: date,
                    end: date,
                    observedAt: date,
                    cost: cost,
                    granularity: .event,
                    isEstimated: estimated,
                    isPartial: partial || costs.count != entries.count
                        || entries.contains { !$0.costIsComplete })
            }
        } else {
            timed = Dictionary(grouping: hourly, by: \.hour).compactMap { date, entries in
                guard let entry = entries.last, let cost = entry.costUSD, Self.validCost(cost),
                      let end = sourceCalendar.date(byAdding: .hour, value: 1, to: date) else { return nil }
                return Bar(
                    start: date,
                    end: end,
                    observedAt: date,
                    cost: cost,
                    granularity: .hourly,
                    isEstimated: estimated,
                    isPartial: partial || !entry.costIsComplete)
            }
        }
        if days == 1, !timed.isEmpty { return timed.sorted { $0.start < $1.start } }
        let dailyBars = daily.compactMap { day, value -> Bar? in
            let (entry, source, end) = value
            guard let cost = entry.costUSD, Self.validCost(cost) else { return nil }
            let provenance = source.snapshot.costProvenance
            return Bar(
                start: day,
                end: end,
                observedAt: source.snapshot.updatedAt,
                cost: cost,
                granularity: .daily,
                isEstimated: provenance == .listPriceEstimate || provenance == .mixed,
                isPartial: source.isPartial || source.snapshot.historyScanIsPartial || entry.costIsPartial == true
                    || entry.incompleteRequestCount > 0 || (entry.unpricedRequestCount ?? 0) > 0
                    || (entry.unmeteredRequestCount ?? 0) > 0)
        }
        // Daily totals are authoritative for their day; timed data fills only days without a measured total.
        let covered = Set(dailyBars.map(\.start))
        return (dailyBars + timed.filter { !covered.contains(sourceCalendar.startOfDay(for: $0.start)) })
            .sorted { $0.start < $1.start }
    }

    private static func validCost(_ cost: Double) -> Bool { cost.isFinite && cost >= 0 }

    private static func budgetHistory(
        metrics: NativeOrbitAccountMetrics, history: [PlanUtilizationSeriesHistory], now: Date)
        -> PlanUtilizationSeriesHistory?
    {
        var readings = history.filter { $0.name.rawValue == "nativeMetric:spend" }.flatMap(\.entries)
            .filter { $0.capturedAt <= now }.map { entry in
                (date: entry.capturedAt, spend: entry.nativeMetrics?.spend(at: entry.capturedAt))
            }
        if let spend = metrics.reportedSpend, spend.updatedAt <= now {
            readings.append((date: spend.updatedAt, spend: spend))
        }
        readings = readings.enumerated().sorted {
            $0.element.date == $1.element.date ? $0.offset < $1.offset : $0.element.date < $1.element.date
        }.map(\.element)
        guard NativeOrbitMonetaryInstrument.validBudget(readings.last?.spend) != nil else { return nil }
        var entries: [Date: PlanUtilizationHistoryEntry] = [:]
        var previous: ProviderCostSnapshot?
        for reading in readings {
            guard let spend = NativeOrbitMonetaryInstrument.validBudget(reading.spend) else {
                // An unavailable receipt breaks continuity even if a later report restores the same cap.
                entries.removeAll()
                previous = nil
                continue
            }
            if let previous {
                let sameDefinition = previous.currencyCode.uppercased() == spend.currencyCode.uppercased()
                    && previous.limit == spend.limit && previous.period == spend.period
                // A new cycle can legitimately publish its next reset. A schedule correction before the
                // recorded reset, however, cannot establish a reset or a comparable consumption trend.
                let crossedReset = previous.resetsAt.map {
                    previous.updatedAt < $0 && $0 <= spend.updatedAt
                } ?? false
                if !sameDefinition || (previous.resetsAt != spend.resetsAt && !crossedReset) {
                    entries.removeAll()
                }
            }
            previous = spend
            entries[spend.updatedAt] = .init(
                capturedAt: spend.updatedAt,
                usedPercent: min(100, spend.used / spend.limit * 100),
                resetsAt: spend.resetsAt)
        }
        guard !entries.isEmpty else { return nil }
        return .init(
            name: .init(rawValue: "nativeQuota:monetary-budget"),
            windowMinutes: 0,
            entries: entries.values.sorted { $0.capturedAt < $1.capturedAt })
    }
}
