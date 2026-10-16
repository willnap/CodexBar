import CodexBarCore
import Foundation

/// Selects the money already reported for an account; never turns token activity into a budget.
enum NativeOrbitMonetaryInstrument {
    enum Mode: Equatable {
        case balance, budgetRemaining, spend
    }

    struct Reading: Equatable {
        let amount: Double?
        let currencyCode: String
        let kind: Mode
        var period: String?
        var estimated = false
        var partial = false
        var scope: NativeOrbitUsageScope = .account
        var isWorkspace = false
        var projected = false

        var value: String {
            guard let amount else { return "—" }
            return NativeOrbitInstruments.money(amount, currency: self.currencyCode)
        }

        var help: String {
            guard self.amount != nil else { return "No monetary reading for this moment" }
            let meaning = switch self.kind {
            case .balance: "Available balance"
            case .budgetRemaining: "Budget remaining"
            case .spend: self.estimated ? "Estimated spend" : "Spend"
            }
            return (self.projected ? "Projected " + meaning.lowercased() : meaning) + ": " + self
                .value + (self.partial ? " or more" : "") + (self.period.map { " (\($0))" } ?? "")
                + (self.isWorkspace ? " · Workspace" : NativeOrbitTooltip.scope(self.scope))
        }
    }

    static func validBudget(_ cost: ProviderCostSnapshot?) -> ProviderCostSnapshot? {
        guard let cost, cost.isDisabled != true, cost.usageIsUnavailable != true,
              cost.used.isFinite, cost.used >= 0, cost.limit.isFinite, cost.limit > 0,
              Locale.commonISOCurrencyCodes.contains(cost.currencyCode.uppercased())
        else { return nil }
        return cost
    }

    static func mode(
        provider: UsageProvider?,
        windows: [UsageWindow],
        metrics: NativeOrbitAccountMetrics) -> Mode?
    {
        let measured = windows.filter { $0.usedFraction != nil }
        if !measured.isEmpty {
            guard let budget = self.validBudget(metrics.reportedSpend),
                  measured.contains(where: {
                      $0.id == "monetary-budget" || provider.map(self.monetaryQuotaProviders.contains) == true
                          && abs(($0.usedFraction ?? -1) - min(1, budget.used / budget.limit)) < 0.005
                  }) else { return nil }
            return .budgetRemaining
        }
        if self.validBudget(metrics.reportedSpend) != nil { return .budgetRemaining }
        if let balance = metrics.reportedBalance, balance.value.isFinite { return .balance }
        // An account awaiting its first quota reading keeps its existing identity face. Missing data alone
        // does not establish that a percentage-based subscription is a monetary account.
        guard metrics.reportedSpend != nil || metrics.usage != nil || metrics.localCostUsage != nil
            || provider.map(self.monetaryQuotaProviders.contains) == true else { return nil }
        return .spend
    }

    @MainActor
    static func mode(
        account: NativeOrbitAccountPresentation,
        windows: [UsageWindow],
        date: Date?,
        now: Date,
        projection: NativeOrbitAccountProjection?) -> Mode?
    {
        let metrics: NativeOrbitAccountMetrics
        let classifiedWindows: [UsageWindow]
        if let date, date <= now {
            metrics = account.metrics.at(date, observedAt: account.updatedAt, history: account.history)
            classifiedWindows = windows
        } else {
            // Unknown projected quotas must not promote a subscription's optional overage into its primary face.
            metrics = projection?.liveMetrics ?? account.metrics
            classifiedWindows = account.gauge.resolvedWindows
        }
        return self.mode(
            provider: UsageProvider(rawValue: account.gauge.provider), windows: classifiedWindows, metrics: metrics)
    }

    static func reading(
        mode: Mode,
        metrics: NativeOrbitAccountMetrics,
        days: Int,
        now: Date) -> Reading
    {
        switch mode {
        case .balance:
            let balance = metrics.reportedBalance
            return Reading(
                amount: balance.flatMap { $0.value.isFinite ? $0.value : nil },
                currencyCode: balance?.unit ?? "USD",
                kind: mode,
                isWorkspace: balance?.isWorkspace == true)
        case .budgetRemaining:
            let budget = self.validBudget(metrics.reportedSpend)
            return Reading(
                amount: budget.map { max(0, $0.limit - $0.used) },
                currencyCode: budget?.currencyCode ?? "USD",
                kind: mode,
                period: budget?.period)
        case .spend:
            let summary = metrics.summary(days: days, now: now)
            if let amount = summary.cost, amount.isFinite, amount >= 0 {
                return Reading(
                    amount: amount,
                    currencyCode: summary.currencyCode,
                    kind: mode,
                    period: NativeOrbitTooltip.range(days: days),
                    estimated: summary.costIsEstimated,
                    partial: summary.costIsPartial,
                    scope: summary.costUsageScope ?? summary.usageScope)
            }
            if let reading = metrics.providerPeriodSpendReading(now: now) {
                return Reading(
                    amount: reading.cost,
                    currencyCode: reading.currency,
                    kind: mode,
                    period: reading.period,
                    estimated: reading.estimated,
                    partial: reading.isPartial)
            }
            let spend = metrics.reportedSpend.flatMap {
                $0.isDisabled != true && $0.usageIsUnavailable != true && $0.used.isFinite && $0.used >= 0 ? $0 : nil
            }
            return Reading(
                amount: spend?.used,
                currencyCode: spend?.currencyCode ?? summary.currencyCode,
                kind: mode,
                period: spend?.period)
        }
    }

    /// These providers publish spend caps as their primary quota. A subscription's optional overage budget must
    /// never replace its existing quota face, even if both happen to read zero or the same percentage.
    /// Provider-specific by design: these spend-cap providers use money as their primary quota.
    private static let monetaryQuotaProviders: Set<UsageProvider> = [
        .aixy, .bedrock, .bifrost, .clawrouter, .deepinfra, .kilo, .litellm, .llmproxy,
        .mistral, .openai, .openrouter, .sub2api, .v0,
    ]
}
