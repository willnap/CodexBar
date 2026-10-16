import CodexBarCore
import SwiftUI
import Synchronization

/// Which reading a corner shows: the live one, the live one before the account's first refresh, a hovered past
/// instant, or a hovered instant ahead of now (a prediction).
enum NativeOrbitReadingMoment: Equatable {
    case live
    case loading
    case inspecting
    case projecting
}

/// Stable watch-face corners; absent measurements stay unknown and never borrow another metric's units.
struct NativeOrbitInstruments: View {
    let account: NativeOrbitAccountPresentation
    let days: Int
    let now: Date
    let accent: Color
    var inspectionDate: Date?
    /// Predictions for instants after `liveNow`; without them a future instant has no readings.
    var projection: NativeOrbitAccountProjection?
    var liveNow: Date?

    /// The prediction the corners show while the pointer is ahead of now.
    private var future: (date: Date, now: Date, projection: NativeOrbitAccountProjection)? {
        guard let date = self.inspectionDate, let now = self.liveNow, date > now, let projection else { return nil }
        return (date, now, projection)
    }

    /// Historical reconstruction is the costly step; evaluate it once per render, never once per corner.
    private var displayedMetrics: NativeOrbitAccountMetrics {
        if let future {
            return future.projection.liveMetrics.projected(
                at: future.date, inventory: future.projection.resetInventory)
        }
        return self.account.metrics.at(
            self.inspectionDate, observedAt: self.account.updatedAt, history: self.account.history)
    }

    private var provider: UsageProvider? {
        UsageProvider(rawValue: self.account.gauge.provider)
    }

    var body: some View {
        let displayed = self.displayedMetrics
        let projected = self.future.map { $0.projection.summary(days: self.days, at: $0.date) }
        let metrics = projected?.summary ?? displayed.summary(days: self.days, now: self.now)
        NativeOrbitInstrumentSurface {
            ZStack {
                self.monetaryReading(metrics, displayed: displayed, projected: projected)
                self.activityReading(metrics, displayed: displayed, projected: projected)
                self.resetReading(displayed)
                self.extraUsageReading(displayed)
            }
        }
        .frame(width: 224, height: 224)
    }

    private func activityReading(
        _ metrics: NativeOrbitMetricSummary,
        displayed: NativeOrbitAccountMetrics,
        projected: NativeOrbitProjectedSummary?) -> some View
    {
        let value: String
        let help: String
        let numericValue: Double?
        if let projected, let future {
            value = metrics.tokens.map(Self.compact) ?? "—"
            help = Self.projectedHelp(
                projected.summary.tokens.map { "\($0.formatted()) tokens" },
                rate: future.projection.tokenRate,
                days: self.days,
                date: future.date,
                now: future.now)
            numericValue = metrics.tokens.map(Double.init)
        } else if let tokens = metrics.tokens {
            value = Self.compact(tokens)
            help = (metrics.isPartial ? "At least " : "") + "\(tokens.formatted()) tokens "
                + NativeOrbitTooltip.during(days: self.days) + NativeOrbitTooltip.scope(metrics.usageScope)
            numericValue = Double(tokens)
        } else if let reading = displayed.providerPeriodTokenReading(now: self.now) {
            value = Self.compact(reading.tokens)
            help = (reading.isPartial ? "At least " : "") + "\(reading.tokens.formatted()) tokens (\(reading.period))"
            numericValue = Double(reading.tokens)
        } else {
            value = "—"
            help = metrics.zeroContradictedByQuota
                ? "Used \(NativeOrbitTooltip.during(days: self.days)), but no token count has arrived yet"
                : "No token count for \(NativeOrbitTooltip.range(days: self.days))"
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
                moment: self.moment,
                now: self.liveNow ?? self.now))
    }

    private var moment: NativeOrbitReadingMoment {
        if self.future != nil { return .projecting }
        if self.inspectionDate != nil { return .inspecting }
        return self.account.updatedAt == nil ? .loading : .live
    }

    /// The banked inventory as of the displayed instant, then one line on what changes it next: the latest
    /// redemption in the range, else the next expiry. Window and provider resets never change the inventory.
    static func resetHelp( // swiftlint:disable:this function_parameter_count
        _ state: NativeOrbitResetCornerState,
        displayed: NativeOrbitAccountMetrics,
        redeemed: [NativeOrbitResetEvent.Redemption],
        provider: UsageProvider?,
        moment: NativeOrbitReadingMoment,
        now: Date) -> String
    {
        switch state {
        case .notApplicable:
            let name = provider.map { ProviderDescriptorRegistry.descriptor(for: $0).metadata.displayName }
            return name.map { "\($0) has no banked resets" } ?? "No banked resets for this account"
        case .unknown:
            return moment == .inspecting ? "No banked-reset reading for this moment" : "Banked resets unavailable"
        case let .inventory(available, used):
            let noun = available == 1 ? "banked reset" : "banked resets"
            var count = switch (available, moment) {
            case (0, .projecting): "No banked resets left by then"
            case (0, _): "No banked resets left"
            case (_, .projecting): "\(available) \(noun) left by then"
            default: "\(available) \(noun) available"
            }
            if used > 0 { count += ", \(used) used" }
            if let latest = redeemed.max(by: { $0.date < $1.date }) {
                return count + "\nLast used " + NativeOrbitTooltip.at(latest.date, now: now)
            }
            if let expiry = displayed.nextResetCreditExpiry, expiry > now {
                return count + "\nNext expires " + NativeOrbitTooltip.at(expiry, now: now)
            }
            return count
        }
    }

    /// Spend for the selected calendar period only. A billing-cycle allowance (e.g. monthly extra usage) belongs to
    /// the bottom-trailing corner and is never relabeled as Day/7D/30D spend; without a period cost this reads "—".
    private func monetaryReading(
        _ metrics: NativeOrbitMetricSummary,
        displayed: NativeOrbitAccountMetrics,
        projected: NativeOrbitProjectedSummary?) -> some View
    {
        if let projected, let future {
            let currency = metrics.currencyCode
            return NativeOrbitComplication(
                value: metrics.cost.map { Self.money($0, currency: currency) } ?? "—",
                corner: .topLeading,
                help: Self.projectedHelp(
                    projected.summary.cost.map { Self.money($0, currency: currency) },
                    rate: future.projection.costRate,
                    days: self.days,
                    date: future.date,
                    now: future.now),
                numericValue: metrics.cost)
        }
        let reading = displayed.providerPeriodSpendReading(now: self.now)
        let amount = metrics.cost ?? reading?.cost
        let currency = metrics.cost != nil ? metrics.currencyCode : (reading?.currency ?? metrics.currencyCode)
        let help: String = if let amount {
            Self.spendHelp(
                Self.money(amount, currency: currency),
                during: metrics.cost != nil
                    ? NativeOrbitTooltip.during(days: self.days)
                    + NativeOrbitTooltip.scope(metrics.costUsageScope ?? metrics.usageScope)
                    : "(\(reading?.period ?? ""))",
                estimated: metrics.cost != nil ? metrics.costIsEstimated : reading?.estimated == true,
                partial: metrics.cost != nil ? metrics.costIsPartial : reading?.isPartial == true)
        } else if metrics.zeroContradictedByQuota {
            "Used \(NativeOrbitTooltip.during(days: self.days)), but no spend report has arrived yet"
        } else {
            "No spend data for \(NativeOrbitTooltip.range(days: self.days))"
        }
        return NativeOrbitComplication(
            value: amount.map { Self.money($0, currency: currency) } ?? "—",
            corner: .topLeading,
            help: help,
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
            help: Self.extraUsageHelp(displayed, days: self.days, now: self.now))
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

    /// What the additional-usage allowance stands at: used of limit in its cycle, then your share or a balance.
    static func extraUsageHelp(_ displayed: NativeOrbitAccountMetrics, days: Int, now: Date) -> String {
        var lines: [String] = []
        if let spend = displayed.reportedSpend {
            if spend.isDisabled == true { return "Additional usage is off" }
            let used = Self.money(spend.used, currency: spend.currencyCode)
            let cycle = spend.period?.localizedCaseInsensitiveContains("month") == true ? " this month" : ""
            lines.append(spend.limit > 0
                ? "\(used) of \(Self.money(spend.limit, currency: spend.currencyCode)) additional usage\(cycle)"
                : "\(used) of additional usage\(cycle)")
            if let share = spend.personalUsed {
                lines.append("Your share: \(Self.money(share, currency: spend.currencyCode))")
            }
        } else if let credits = displayed.recordedCreditUsage(days: days, now: now) {
            let used = Self.money(credits, currency: "Credits")
            lines.append("At least \(used) used \(NativeOrbitTooltip.during(days: days))")
        }
        if let balance = displayed.reportedBalance {
            lines.append(Self.money(balance.value, currency: balance.unit)
                + (balance.isWorkspace ? " workspace balance" : " balance"))
        }
        return lines.isEmpty ? "No additional usage on this account" : lines.joined(separator: "\n")
    }

    /// A prediction for the hovered moment ahead: "About 1,234,567 tokens today by 6:00 PM, at the current pace".
    static func projectedHelp(_ total: String?, rate: Double?, days: Int, date: Date, now: Date) -> String {
        guard let total else { return "Not enough history to project" }
        let when = NativeOrbitTooltip.moment(date, now: now)
        let span = days == 1
            ? (Calendar.current.isDate(date, inSameDayAs: now) ? "today by \(when)" : "that day by \(when)")
            : "in the \(days) days to \(when)"
        switch rate {
        case let rate? where rate > 0: return "About \(total) \(span), at the current pace"
        case 0?: return "\(total) \(span), with the account idle"
        default: return "About \(total) \(span)"
        }
    }

    /// "About $255.54 spent today on this Mac, at list prices"; a recorded subtotal reads "At least".
    static func spendHelp(_ amount: String, during: String, estimated: Bool, partial: Bool) -> String {
        (partial ? "At least " : estimated ? "About " : "") + "\(amount) spent \(during)"
            + (estimated ? ", at list prices" : "")
    }

    nonisolated static func money(_ value: Double, currency: String, locale: Locale = .current) -> String {
        let number = value.formatted(.number.precision(.fractionLength(2)).locale(locale))
        if currency == "Credits" { return number + " credits" }
        guard let symbol = NativeOrbitCurrencySymbols.shared.symbol(currency, locale: locale) else {
            return number + " " + currency
        }
        return symbol + number
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

/// NumberFormatter's currency symbol lookup builds an ICU formatter. Retain the resulting string for each actual
/// locale snapshot instead of rebuilding it for every readout and help string during inspection.
private final class NativeOrbitCurrencySymbols: Sendable {
    private struct Key: Hashable, Sendable {
        let currency: String
        let locale: Locale
    }

    static let shared = NativeOrbitCurrencySymbols()
    private static let currencyCodes = Set(Locale.commonISOCurrencyCodes)
    private let symbols = Mutex<[Key: String]>([:])

    private init() {
        // This singleton and its observer live for the process. Locale preference changes invalidate cached symbols,
        // including changes whose locale identifier stays the same.
        _ = NotificationCenter.default.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification, object: nil, queue: nil)
        { [weak self] _ in self?.symbols.withLock { $0.removeAll(keepingCapacity: true) } }
    }

    func symbol(_ currency: String, locale: Locale) -> String? {
        let code = currency.uppercased()
        guard Self.currencyCodes.contains(code) else { return nil }
        let key = Key(currency: code, locale: locale)
        return self.symbols.withLock { symbols in
            if let symbol = symbols[key] { return symbol }
            let formatter = NumberFormatter()
            formatter.locale = locale
            formatter.numberStyle = .currency
            formatter.currencyCode = code
            let symbol = formatter.currencySymbol ?? code
            if symbols.count >= 256 { symbols.removeAll(keepingCapacity: true) }
            symbols[key] = symbol
            return symbol
        }
    }
}
