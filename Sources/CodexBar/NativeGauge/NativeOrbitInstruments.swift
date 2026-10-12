import CodexBarCore
import SwiftUI

/// Which reading a corner shows: the live one, the live one before the account's first refresh, or a hovered instant.
enum NativeOrbitReadingMoment: Equatable {
    case live
    case loading
    case inspecting
}

/// Stable watch-face corners; absent measurements stay unknown and never borrow another metric's units.
struct NativeOrbitInstruments: View {
    let account: NativeOrbitAccountPresentation
    let days: Int
    let now: Date
    let accent: Color
    var inspectionDate: Date?

    /// Historical reconstruction is the costly step; evaluate it once per render, never once per corner.
    private var displayedMetrics: NativeOrbitAccountMetrics {
        self.account.metrics.at(
            self.inspectionDate, observedAt: self.account.updatedAt, history: self.account.history)
    }

    private var period: String {
        self.days == 1 ? "today" : "last \(self.days) days"
    }

    private var provider: UsageProvider? {
        UsageProvider(rawValue: self.account.gauge.provider)
    }

    var body: some View {
        let displayed = self.displayedMetrics
        let metrics = displayed.summary(days: self.days, now: self.now)
        ZStack {
            self.monetaryReading(metrics, displayed: displayed)
            self.activityReading(metrics, displayed: displayed)
            self.resetReading(displayed)
            self.extraUsageReading(displayed)
        }
        .frame(width: 224, height: 224)
    }

    private func activityReading(
        _ metrics: NativeOrbitMetricSummary,
        displayed: NativeOrbitAccountMetrics) -> some View
    {
        let value: String
        let help: String
        let numericValue: Double?
        if let tokens = metrics.tokens {
            value = Self.compact(tokens)
            help = "\(tokens.formatted()) tokens · \(self.calendarPeriod(scope: metrics.usageScope, displayed))"
                + " · \(Self.scope(metrics.usageScope))"
                + (metrics.isPartial ? " · Recorded subtotal; coverage incomplete" : "")
                + (metrics.usageScope == .account
                    ? (displayed.usage?.historyLabel.map { " · \($0)" } ?? "") : "")
            numericValue = Double(tokens)
        } else if let reading = displayed.providerPeriodTokenReading(now: self.now) {
            value = Self.compact(reading.tokens)
            help = "\(reading.tokens.formatted()) tokens · \(reading.period) · Account total"
                + (reading.isPartial ? " · Recorded subtotal; coverage incomplete" : "")
            numericValue = Double(reading.tokens)
        } else {
            value = "—"
            help = "Token total is not reported for \(self.period)"
            numericValue = nil
        }
        return NativeOrbitComplication(
            value: value,
            corner: .topTrailing,
            help: help,
            monospaced: true,
            numericValue: numericValue)
    }

    private func resetReading(_ displayed: NativeOrbitAccountMetrics) -> some View {
        let state = NativeOrbitResetCornerState.resolve(provider: self.provider, metrics: displayed)
        return NativeOrbitResetComplication(
            state: state,
            accent: self.accent,
            help: Self.resetHelp(
                state,
                displayed: displayed,
                redeemed: NativeOrbitResetEvent.redemptions(in: self.account.history, days: self.days, now: self.now),
                provider: self.provider,
                moment: self.moment))
    }

    private var moment: NativeOrbitReadingMoment {
        if self.inspectionDate != nil { return .inspecting }
        return self.account.updatedAt == nil ? .loading : .live
    }

    /// Banked inventory as of the displayed instant, plus any banked reset redeemed in the selected period up to it.
    /// Only redemptions count here; window and provider resets never change the banked inventory.
    static func resetHelp(
        _ state: NativeOrbitResetCornerState,
        displayed: NativeOrbitAccountMetrics,
        redeemed: [NativeOrbitResetEvent.Redemption],
        provider: UsageProvider?,
        moment: NativeOrbitReadingMoment) -> String
    {
        let isInspecting = moment == .inspecting
        switch state {
        case .notApplicable:
            let name = provider.map { ProviderDescriptorRegistry.descriptor(for: $0).metadata.displayName }
            return "Banked resets do not apply" + (name.map { " to \($0)" } ?? "")
        case .unknown:
            return isInspecting ? "No banked-reset reading at this time" : "Banked resets are not reported"
        case let .inventory(available, used):
            var parts = ["\(available) banked \(available == 1 ? "reset" : "resets") · \(used) used"]
            if let expiry = displayed.nextResetCreditExpiry {
                parts.append("Next expires \(expiry.formatted(date: .abbreviated, time: .shortened))")
            }
            if isInspecting, let observed = displayed.resetInventoryObservedAt {
                parts.append("Observed \(observed.formatted(date: .abbreviated, time: .shortened))")
            }
            if let latest = redeemed.max(by: { $0.date < $1.date }) {
                let count = redeemed.reduce(0) { $0 + $1.quantity }
                let time = latest.date.formatted(date: .abbreviated, time: .shortened)
                let when = latest.earliest.map {
                    "between \($0.formatted(date: .abbreviated, time: .shortened)) and \(time)"
                } ?? time
                parts.append(count == 1 ? "You used a banked reset \(when)"
                    : "You used \(count) banked resets in this period, latest \(when)")
            }
            return parts.joined(separator: " · ")
        }
    }

    /// Spend for the selected calendar period only. A billing-cycle allowance (e.g. monthly extra usage) belongs to
    /// the bottom-trailing corner and is never relabeled as Day/7D/30D spend; without a period cost this reads "—".
    private func monetaryReading(
        _ metrics: NativeOrbitMetricSummary,
        displayed: NativeOrbitAccountMetrics) -> some View
    {
        let reading = displayed.providerPeriodSpendReading(now: self.now)
        let amount = metrics.cost ?? reading?.cost
        let currency = metrics.cost != nil ? metrics.currencyCode : (reading?.currency ?? metrics.currencyCode)
        let period = metrics.cost != nil
            ? self.calendarPeriod(scope: metrics.costUsageScope ?? metrics.usageScope, displayed)
            : (reading?.period ?? self.period)
        let usesPeriodReading = metrics.cost == nil && reading != nil
        return NativeOrbitComplication(
            value: amount.map { Self.money($0, currency: currency) } ?? "—",
            corner: .topLeading,
            help: amount.map {
                "\(Self.money($0, currency: currency)) · \(period)"
                    + (metrics.cost != nil ? " · \(Self.scope(metrics.costUsageScope ?? metrics.usageScope))" : "")
                    + (metrics.cost != nil && metrics.costIsPartial
                        ? " · Recorded subtotal; coverage incomplete" : "")
                    + (metrics.cost != nil && metrics.costIsEstimated ? " · Estimated" : "")
                    + (usesPeriodReading && reading?.estimated == true ? " · Estimated" : "")
                    + (usesPeriodReading && reading?.isPartial == true
                        ? " · Recorded subtotal; coverage incomplete" : "")
            } ?? "Spend is not reported for \(self.period)",
            numericValue: amount)
    }

    /// The bottom-trailing corner is always the additional-usage gauge. Its arc fills only from a reported
    /// used/limit pair; amounts without a limit, a disabled window, balances and recorded credits stay in its help.
    private func extraUsageReading(_ displayed: NativeOrbitAccountMetrics) -> some View {
        NativeOrbitExtraUsageComplication(
            fraction: displayed.reportedSpend?.isDisabled == true ? nil : displayed.extraUsageFraction,
            icon: Self.extraUsageIcon(
                displayed,
                creditUsage: displayed.recordedCreditUsage(days: self.days, now: self.now),
                moment: self.moment,
                history: self.account.history),
            accent: self.accent,
            help: Self.extraUsageHelp(displayed, days: self.days, now: self.now, period: self.period))
    }

    /// Additional usage applies while the provider reports a spend allowance, a balance or dated credit usage, even
    /// at zero. Turned off, or never reported by this account, it does not apply. While loading, or inspecting an
    /// instant no observation covers although the account records these readings, it is unknown.
    static func extraUsageIcon(
        _ displayed: NativeOrbitAccountMetrics,
        creditUsage credits: Double?,
        moment: NativeOrbitReadingMoment,
        history: [PlanUtilizationSeriesHistory]) -> NativeOrbitExtraUsageIconState
    {
        if displayed.reportedSpend?.isDisabled == true { return .notApplicable }
        if displayed.reportedSpend != nil || displayed.reportedBalance != nil || credits != nil {
            let spent = displayed.reportedSpend.map { $0.used > 0 || ($0.personalUsed ?? 0) > 0 } ?? false
            return spent || (credits ?? 0) > 0 ? .active : .zero
        }
        if moment == .loading { return .unknown }
        let recordsReadings = history.contains {
            ["nativeMetric:spend", "nativeMetric:balance", "nativeMetric:creditEvents"].contains($0.name.rawValue)
                && !$0.entries.isEmpty
        }
        return moment == .inspecting && recordsReadings ? .unknown : .notApplicable
    }

    static func extraUsageHelp(_ displayed: NativeOrbitAccountMetrics, days: Int, now: Date, period: String) -> String {
        var parts: [String] = []
        if let spend = displayed.reportedSpend {
            if spend.isDisabled == true {
                parts.append("Additional usage is turned off")
                if spend.used > 0 { parts.append("\(Self.money(spend.used, currency: spend.currencyCode)) used") }
            } else {
                parts.append("Additional usage · \(Self.money(spend.used, currency: spend.currencyCode)) used"
                    + (spend.limit > 0 ? " of \(Self.money(spend.limit, currency: spend.currencyCode))" : ""))
                if let share = spend.personalUsed {
                    parts.append("Your share \(Self.money(share, currency: spend.currencyCode))")
                }
            }
            if let cycle = spend.period { parts.append(cycle) }
        }
        if displayed.reportedSpend == nil, let credits = displayed.recordedCreditUsage(days: days, now: now) {
            parts.append("Recorded credit usage · \(Self.money(credits, currency: "Credits")) · \(period)"
                + " · Recorded subtotal; coverage incomplete")
        }
        if let balance = displayed.reportedBalance {
            parts.append("\(balance.isWorkspace ? "Workspace" : "Account") balance "
                + Self.money(balance.value, currency: balance.unit))
        }
        return parts.isEmpty ? "Additional usage is not reported" : parts.joined(separator: " · ")
    }

    private static func scope(_ scope: NativeOrbitUsageScope) -> String {
        switch scope {
        case .account: "Account total"
        case .localProfile: "Local sessions in this profile"
        case .localMachine: "Local sessions on this Mac"
        }
    }

    private func calendarPeriod(scope: NativeOrbitUsageScope, _ displayed: NativeOrbitAccountMetrics) -> String {
        let zone = scope == .account ? displayed.usage?.bucketTimeZoneIdentifier : nil
        return self.period + (zone.map { " (\($0))" } ?? "")
    }

    static func money(_ value: Double, currency: String) -> String {
        if currency == "Credits" {
            return value.formatted(.number.precision(.fractionLength(2))) + " credits"
        }
        guard Locale.commonISOCurrencyCodes.contains(currency.uppercased()) else {
            return value.formatted(.number.precision(.fractionLength(2))) + " " + currency
        }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency.uppercased()
        let symbol = formatter.currencySymbol ?? currency.uppercased()
        return symbol + value.formatted(.number.precision(.fractionLength(2)))
    }

    static func compact(_ value: Int) -> String {
        let scale: (Double, String)? = if value >= 1_000_000_000 {
            (1_000_000_000, "B")
        } else if value >= 1_000_000 {
            (1_000_000, "M")
        } else if value >= 1000 {
            (1000, "K")
        } else {
            nil
        }
        guard let (divisor, suffix) = scale else { return String(value) }
        return (Double(value) / divisor).formatted(.number.precision(.fractionLength(0...1))) + suffix
    }
}
