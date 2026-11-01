import CodexBarCore
import Foundation

/// These observations share the existing verified account buckets and persistence coordinator.
/// Spend, balance, and inventory age independently; quota percentages cannot reconstruct them.
struct NativeOrbitMetricObservation: Codable, Hashable, Sendable {
    var quotaSchema: NativeOrbitQuotaSchemaObservation?
    var usage: NativeOrbitUsageObservation?
    var spend: ProviderCostSnapshot?
    var balance: NativeOrbitReportedBalance?
    var resets: NativeOrbitResetObservation?
    var creditEvents: [NativeOrbitCreditUsageEvent]?
    var spendResetReferenceTime: Double?
    var spendBalanceReferenceTime: Double?
    var requestQuotas: [KimiRequestQuota]?
    var requestResetReferenceTimes: [Double?]?
    var planExpiryReferenceTime: Double?

    func spend(at observationDate: Date) -> ProviderCostSnapshot? {
        self.spend.map {
            ProviderCostSnapshot(
                used: $0.used,
                limit: $0.limit,
                currencyCode: $0.currencyCode,
                period: $0.period,
                resetsAt: self.spendResetReferenceTime.map(Date.init(timeIntervalSinceReferenceDate:)) ?? $0.resetsAt,
                nextRegenAmount: $0.nextRegenAmount,
                personalUsed: $0.personalUsed,
                balance: $0.balance,
                balanceUpdatedAt: self.spendBalanceReferenceTime.map(Date.init(timeIntervalSinceReferenceDate:))
                    ?? $0.balanceUpdatedAt,
                balanceIsWorkspace: $0.balanceIsWorkspace,
                usageIsUnavailable: $0.usageIsUnavailable,
                // A recorded "turned off" reading must restore as off, not as an enabled zero allowance.
                isDisabled: $0.isDisabled,
                updatedAt: observationDate)
        }
    }

    var exactRequestQuotas: [KimiRequestQuota] {
        (self.requestQuotas ?? []).enumerated().map { index, quota in
            let reset = self.requestResetReferenceTimes.flatMap { times in
                times.indices.contains(index) ? times[index] : nil
            }.map(Date.init(timeIntervalSinceReferenceDate:)) ?? quota.resetsAt
            return KimiRequestQuota(
                id: quota.id,
                title: quota.title,
                used: quota.used,
                limit: quota.limit,
                windowMinutes: quota.windowMinutes,
                resetsAt: reset)
        }
    }
}

struct NativeOrbitCreditUsageEvent: Codable, Hashable, Sendable {
    let timestampReferenceTime: Double
    let service: String
    let creditsUsed: Double

    var date: Date {
        Date(timeIntervalSinceReferenceDate: self.timestampReferenceTime)
    }

    init(_ event: CreditEvent) {
        self.timestampReferenceTime = event.date.timeIntervalSinceReferenceDate
        self.service = event.service
        self.creditsUsed = event.creditsUsed
    }

    static func merging(_ snapshots: [[Self]]) -> [Self] {
        // Dashboard parsers assign fresh UUIDs on each read. Match actual source fields, retaining the greatest
        // multiplicity of identical rows in a snapshot rather than double-counting repeated polls.
        var counts: [Self: Int] = [:]
        for snapshot in snapshots {
            for (event, rows) in Dictionary(grouping: snapshot, by: { $0 }) {
                counts[event] = max(counts[event] ?? 0, rows.count)
            }
        }
        return counts.flatMap { event, count in Array(repeating: event, count: count) }.sorted {
            if $0.date != $1.date { return $0.date < $1.date }
            if $0.service != $1.service { return $0.service < $1.service }
            return $0.creditsUsed < $1.creditsUsed
        }
    }
}

struct NativeOrbitResetObservation: Codable, Hashable, Sendable {
    private let availableExpirationTimes: [Double?]
    private let usedExpirationTimes: [Double?]?
    private let redeemedTimes: [Double]?

    init(availableExpirations: [Date?], usedExpirations: [Date?]? = nil, redeemedDates: [Date]? = nil) {
        self.availableExpirationTimes = availableExpirations.map { $0?.timeIntervalSinceReferenceDate }
        self.usedExpirationTimes = usedExpirations?.map { $0?.timeIntervalSinceReferenceDate }
        self.redeemedTimes = redeemedDates?.map(\.timeIntervalSinceReferenceDate)
    }

    var availableExpirations: [Date?] {
        self.availableExpirationTimes.map { $0.map(Date.init(timeIntervalSinceReferenceDate:)) }
    }

    private var usedExpirations: [Date?]? {
        self.usedExpirationTimes?.map { $0.map(Date.init(timeIntervalSinceReferenceDate:)) }
    }

    /// Exact redemption times (Codex `redeemedAt`); nil when the inventory reports none (Claude, Grok).
    var redeemedDates: [Date]? {
        self.redeemedTimes?.map(Date.init(timeIntervalSinceReferenceDate:))
    }

    func available(at date: Date) -> [Date?] {
        self.availableExpirations.filter { $0.map { $0 > date } ?? true }
    }

    /// Used resets in grants still current at `date`; nil when the inventory does not report used resets.
    func usedCount(at date: Date) -> Int? {
        self.usedExpirations?.count { $0.map { $0 > date } ?? true }
    }

    func used(at date: Date) -> Int {
        if let redeemedDates {
            return redeemedDates.filter { $0 <= date && date.timeIntervalSince($0) < 86400 }.count
        }
        // Claude reports used grants' expirations, not the time they were redeemed.
        return self.usedExpirations?.filter { $0.map { $0 > date } ?? true }.count ?? 0
    }
}

extension UsageStore {
    nonisolated static func nativeOrbitMetricSamples(
        provider: UsageProvider,
        snapshot: UsageSnapshot,
        credits: CreditsSnapshot? = nil) -> [PlanUtilizationSeriesSample]
    {
        let metrics = NativeOrbitAccountMetrics.make(
            provider: provider, snapshot: snapshot, usage: nil, now: snapshot.updatedAt, credits: credits)
        var samples: [PlanUtilizationSeriesSample] = []
        func append(_ name: String, at date: Date, observation: NativeOrbitMetricObservation) {
            samples.append(.init(
                name: .init(rawValue: "nativeMetric:" + name),
                windowMinutes: 0,
                entry: .init(capturedAt: date, usedPercent: 0, resetsAt: nil, nativeMetrics: observation)))
        }
        if let schema = Self.nativeOrbitQuotaSchema(provider: provider, snapshot: snapshot) {
            append("quotaSchema", at: snapshot.updatedAt, observation: .init(quotaSchema: schema))
        }
        // Machine-local scans are not account receipts; history inspection reads their own dated buckets.
        let report = Self.nativeOrbitSnapshotReportIsMachineLocal(provider) ? nil
            : snapshot.costUsage ?? Self.nativeOrbitProviderUsageReport(provider: provider, snapshot: snapshot)
        if let report, let receipt = NativeOrbitUsageObservation(report) {
            append("usage", at: report.updatedAt, observation: .init(usage: receipt))
        }
        if let spend = metrics.reportedSpend {
            append("spend", at: spend.updatedAt, observation: .init(
                spend: spend,
                spendResetReferenceTime: spend.resetsAt?.timeIntervalSinceReferenceDate,
                spendBalanceReferenceTime: spend.balanceUpdatedAt?.timeIntervalSinceReferenceDate))
        } else if let cost = snapshot.providerCost, cost.usageIsUnavailable == true {
            append("spend", at: cost.updatedAt, observation: .init())
        }
        // Provider-specific by design: the last branch waits for Codex's credits read. A Codex balance (or its absence)
        // comes from that read, moments after the usage refresh; an empty marker here would break its continuity.
        if let balance = metrics.reportedBalance {
            append("balance", at: balance.updatedAt, observation: .init(balance: balance))
        } else if let credits, credits.balanceReadSucceeded || credits.creditsAvailable == true {
            append("balance", at: credits.updatedAt, observation: .init())
        } else if provider != .codex || credits != nil, let date = snapshot.providerCost?.balanceUpdatedAt {
            append("balance", at: date, observation: .init())
        }
        if !metrics.creditUsageEvents.isEmpty, let credits {
            append("creditEvents", at: credits.updatedAt, observation: .init(creditEvents: metrics.creditUsageEvents))
        }
        // Provider-specific by design: an accepted Kimi response without absolute allowances invalidates old counters.
        if provider == .kimi || !metrics.reportedQuotaUsage.isEmpty || metrics.reportedPlanExpiry != nil {
            append("allowances", at: snapshot.updatedAt, observation: .init(
                requestQuotas: metrics.reportedQuotaUsage,
                requestResetReferenceTimes: metrics.reportedQuotaUsage
                    .map { $0.resetsAt?.timeIntervalSinceReferenceDate },
                planExpiryReferenceTime: metrics.reportedPlanExpiry?.timeIntervalSinceReferenceDate))
        }
        // Provider-specific by design: these reset inventories report distinct expiry and redemption payloads.
        switch provider {
        case .codex:
            if let resets = snapshot.codexResetCredits {
                append("resets", at: resets.updatedAt, observation: .init(resets: .init(
                    availableExpirations: resets.availableCredits(at: resets.updatedAt).map(\.expiresAt),
                    redeemedDates: resets.credits.filter { $0.status == .redeemed }.compactMap(\.redeemedAt))))
            }
        case .claude:
            if let resets = snapshot.claudeResetCredits {
                append("resets", at: resets.updatedAt, observation: .init(resets: .init(
                    availableExpirations: resets.expirations,
                    usedExpirations: resets.usedExpirations)))
            }
        case .grok:
            if let resets = snapshot.grokResetCredits {
                append("resets", at: resets.updatedAt, observation: .init(resets: .init(
                    availableExpirations: resets.expirations.map { Optional($0) })))
            }
        default: break
        }
        return samples
    }

    private nonisolated static func nativeOrbitProviderUsageReport(
        provider: UsageProvider, snapshot: UsageSnapshot) -> CostUsageTokenSnapshot?
    {
        // Provider-specific by design: these providers retain typed daily billing data outside costUsage.
        switch provider {
        case .openai: snapshot.openAIAPIUsage?.toCostUsageTokenSnapshot()
        case .mistral: snapshot.mistralUsage?.toCostUsageTokenSnapshot(historyDays: 30)
        case .opencodego: snapshot.opencodegoUsage.flatMap {
                $0.daily.isEmpty ? nil : $0.toCostUsageTokenSnapshot(historyDays: 30)
            }
        case .xai: XAICostUsageMapping.tokenSnapshot(from: snapshot, historyDays: 30)
        default: nil
        }
    }
}

extension NativeOrbitAccountMetrics {
    mutating func includeRecordedUsage(
        from history: [PlanUtilizationSeriesHistory], at date: Date? = nil, cutoff: Date? = nil)
    {
        guard date != nil || self.usage == nil else { return }
        if let prepared = self.preparedHistory, prepared.matches(history) {
            if let report = prepared.usageSnapshot(at: date, cutoff: cutoff) {
                self.usage = report
                self.usageScope = .account
                self.usageCostPartialDays = Set(report.daily.filter { $0.costIsPartial == true }.map(\.date))
            } else if date != nil, prepared.hasUsageReceipts,
                      cutoff.map({ prepared.usageReceiptCount(through: $0) > 0 }) ?? true
            {
                self.usage = nil
                self.usageCostPartialDays = []
            }
            return
        }
        let receipts = history.filter { $0.name.rawValue == "nativeMetric:usage" }.flatMap(\.entries)
            .filter { entry in cutoff.map { entry.capturedAt <= $0 } ?? true }
        let entries = receipts
            .filter { entry in date.map { $0 >= entry.capturedAt } ?? true }
        // Each receipt belongs to the already verified account history bucket. Select an actual reading,
        // preserving its timestamp so daily aggregates cannot become fabricated intraday events.
        if let entry = entries.max(by: { $0.capturedAt < $1.capturedAt }),
           let report = entry.nativeMetrics?.usage?.snapshot(at: entry.capturedAt)
        {
            self.usage = report
            self.usageScope = .account
            self.usageCostPartialDays = Set(entry.nativeMetrics?.usage?.daily
                .filter { $0.costPartial == true }.map(\.date) ?? [])
        } else if date != nil, !receipts.isEmpty {
            self.usage = nil
            self.usageCostPartialDays = []
        }
    }

    mutating func includeRecordedCreditEvents(from history: [PlanUtilizationSeriesHistory], cutoff: Date? = nil) {
        if let prepared = self.preparedHistory, prepared.matches(history) {
            if let cutoff {
                self.creditUsageEvents = NativeOrbitCreditUsageEvent.merging([
                    self.creditUsageEvents, prepared.creditEvents(through: cutoff),
                ])
            } else {
                self.creditUsageEvents = self.preparedCreditEvents
                    ?? NativeOrbitCreditUsageEvent.merging([self.creditUsageEvents, prepared.creditEvents])
            }
            return
        }
        let observations = history.filter { $0.name.rawValue == "nativeMetric:creditEvents" }
            .flatMap(\.entries).filter { entry in cutoff.map { entry.capturedAt <= $0 } ?? true }
            .compactMap { $0.nativeMetrics?.creditEvents }
        self.creditUsageEvents = NativeOrbitCreditUsageEvent.merging([self.creditUsageEvents] + observations)
    }

    func recordedCreditUsage(days: Int, now: Date, calendar: Calendar = .current) -> Double? {
        let start = NativeOrbitChartAxis.start(now: now, days: days, calendar: calendar)
        let events = self.creditUsageEvents.filter {
            $0.date >= start && $0.date <= now && $0.creditsUsed.isFinite && $0.creditsUsed >= 0
        }
        guard !events.isEmpty else { return nil }
        let total = events.reduce(0) { $0 + $1.creditsUsed }
        return total.isFinite ? total : nil
    }

    /// One refresh stamps its lanes with separate clock reads, microseconds apart; such a reading belongs to the
    /// same instant. Anything later is a future poll and is never borrowed.
    static let sameRefreshSkew: TimeInterval = 0.5

    /// The latest reading at or before `date`, while that lane's next poll was not yet overdue. Dated transaction
    /// subtotals are evaluated separately; they do not imply continuous snapshot readings.
    static func latestObservation(
        in entries: [PlanUtilizationHistoryEntry],
        at date: Date) -> PlanUtilizationHistoryEntry?
    {
        guard let latest = entries.filter({ $0.capturedAt <= date.addingTimeInterval(self.sameRefreshSkew) })
            .max(by: { $0.capturedAt < $1.capturedAt })
        else { return nil }
        return date.timeIntervalSince(latest.capturedAt) <= self.restoreTolerance(entries) ? latest : nil
    }

    /// Three polling intervals of the lane's own median cadence, bounded like the chart's gap threshold: at least
    /// 15 minutes, never more than 90, so an outage never carries a stale reading forward.
    static func restoreTolerance(_ entries: [PlanUtilizationHistoryEntry]) -> TimeInterval {
        let dates = entries.map(\.capturedAt).sorted()
        let intervals = zip(dates, dates.dropFirst()).map { $1.timeIntervalSince($0) }
            .filter { $0 > 1 && $0 <= 5400 }.sorted()
        let cadence = intervals.isEmpty ? 300 : intervals[(intervals.count - 1) / 2]
        return min(5400, max(900, cadence * 3))
    }

    mutating func restoreHistoricalMetrics(
        from history: [PlanUtilizationSeriesHistory], at date: Date, cutoff: Date? = nil)
    {
        /// Each lane restores its own reading with that observation's timestamp; a newer empty reading (for
        /// example an unavailable spend) is the latest observation and therefore clears the older value.
        func observation(_ name: String) -> PlanUtilizationHistoryEntry? {
            if let prepared = self.preparedHistory, prepared.matches(history) {
                return prepared.observation(name, at: date, cutoff: cutoff)
            }
            return Self.latestObservation(
                in: history.filter { $0.name.rawValue == "nativeMetric:" + name }.flatMap(\.entries)
                    .filter { entry in cutoff.map { entry.capturedAt <= $0 } ?? true },
                at: date)
        }
        if let entry = observation("spend"), let spend = entry.nativeMetrics?.spend(at: entry.capturedAt) {
            self.reportedSpend = spend
        }
        if let balance = observation("balance")?.nativeMetrics?.balance { self.reportedBalance = balance }
        if let allowances = observation("allowances")?.nativeMetrics {
            self.reportedQuotaUsage = allowances.exactRequestQuotas.filter { $0.resetsAt.map { $0 > date } ?? true }
            self.reportedPlanExpiry = allowances.planExpiryReferenceTime.map(Date.init(timeIntervalSinceReferenceDate:))
        }
        if let entry = observation("resets"), let resets = entry.nativeMetrics?.resets {
            let available = resets.available(at: date)
            self.bankedResets = available.count
            self.usedResets = resets.used(at: date)
            self.nextResetCreditExpiry = available.compactMap(\.self).min()
            self.resetInventoryObservedAt = entry.capturedAt
        }
    }
}

extension NativeOrbitReportedBalance {
    private enum CodingKeys: String, CodingKey {
        case value, unit, isWorkspace, updatedAt, updatedAtReferenceTime
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let exact = try values.decodeIfPresent(Double.self, forKey: .updatedAtReferenceTime)
        try self.init(
            value: values.decode(Double.self, forKey: .value),
            unit: values.decode(String.self, forKey: .unit),
            isWorkspace: values.decode(Bool.self, forKey: .isWorkspace),
            updatedAt: exact.map(Date.init(timeIntervalSinceReferenceDate:))
                ?? values.decode(Date.self, forKey: .updatedAt))
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.value, forKey: .value)
        try values.encode(self.unit, forKey: .unit)
        try values.encode(self.isWorkspace, forKey: .isWorkspace)
        try values.encode(self.updatedAt.timeIntervalSinceReferenceDate, forKey: .updatedAtReferenceTime)
    }
}
