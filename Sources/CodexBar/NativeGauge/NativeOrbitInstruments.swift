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
    /// While the startup sweeps, each reading shows its zero; settling rolls the real values up from there.
    var countsFromZero = false
    /// The dial's gauges, outermost first: a reset that clears only an inner one is drawn in its colour.
    var gauges: [NativeOrbitGaugeLane] = []
    /// The accent the gauges are tinted from, when it differs from the instruments' own.
    var gaugeAccent: Color?

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
        let zeroed = self.countsFromZero && numericValue != nil
        return NativeOrbitComplication(
            value: zeroed ? Self.compact(0) : value,
            corner: .topTrailing,
            help: help,
            monospaced: true,
            numericValue: zeroed ? 0 : numericValue)
    }

    private func resetReading(_ displayed: NativeOrbitAccountMetrics) -> some View {
        let state = NativeOrbitResetCornerState.resolve(provider: self.provider, metrics: displayed)
        // Counting from zero, every banked reset starts as an empty place and fills as the dial settles.
        let shown: NativeOrbitResetCornerState = if self.countsFromZero, case let .inventory(available, used) = state {
            .inventory(available: 0, used: available + used)
        } else {
            state
        }
        // The instant the corner shows: what was used in the week before it is still fading there.
        let instant = self.inspectionDate ?? self.liveNow ?? self.now
        let prepared = self.account.metrics.preparedHistory
        let week = NativeOrbitResetEvent.redemptions(
            in: self.account.history, days: 7, now: instant, prepared: prepared)
        let recent = self.countsFromZero || self.future != nil
            ? [] : week.flatMap { Array(repeating: $0.date, count: max(1, $0.quantity)) }
        let ids = self.gauges.map(\.id)
        let banked = displayed.bankedResetDetails.map { NativeOrbitResetComplication.lane($0.scope, gauges: ids) }
        let used = displayed.usedResetDetails.map { NativeOrbitResetComplication.lane($0.scope, gauges: ids) }
        return NativeOrbitResetComplication(
            state: shown,
            accent: self.accent,
            help: Self.resetHelp(
                state,
                banked: displayed.bankedResetDetails,
                used: displayed.usedResetDetails,
                recentlyUsed: recent,
                earlier: NativeOrbitResetEvent.redemptions(
                    in: self.account.history, days: max(self.days, 30), now: instant, prepared: prepared)
                    .map(\.date).max(),
                gauges: self.gauges,
                laneTitles: displayed.resetLaneTitles,
                provider: self.provider,
                moment: self.moment,
                now: self.liveNow ?? self.now),
            recentlyUsed: recent,
            now: instant,
            bankedLanes: self.countsFromZero ? [] : banked,
            usedLanes: used,
            laneStyles: self.resetLaneStyles(banked + used))
    }

    /// Each gauge's colour for the resets that clear it. A window the dial is not drawing just now (a model
    /// allowance left unused for a week) keeps the colour its gauge has when it is drawn.
    private func resetLaneStyles(_ lanes: [String?]) -> [String: NativeOrbitResetLaneStyle] {
        var styles = Dictionary(
            self.gauges.enumerated().map { index, gauge in
                (gauge.id, NativeOrbitResetLaneStyle(tint: gauge.tint, isOutermost: index == 0))
            },
            uniquingKeysWith: { first, _ in first })
        for case let lane? in lanes where styles[lane] == nil {
            styles[lane] = NativeOrbitResetLaneStyle(
                tint: NativeOrbitPalette.color(accent: self.gaugeAccent ?? self.accent, id: lane, period: 604_800),
                isOutermost: false)
        }
        return styles
    }

    private var moment: NativeOrbitReadingMoment {
        if self.future != nil { return .projecting }
        if self.inspectionDate != nil { return .inspecting }
        return self.account.updatedAt == nil ? .loading : .live
    }

    /// What is in stock, one line for each kind with what a part reset refills straight under it; then the last
    /// thing that happened: a use this week (naming the kind when that tells it apart), an earlier use, or when the
    /// last one was given. An ordinary reset needs no explaining, so kinds are named only beside a part reset.
    static func resetHelp( // swiftlint:disable:this function_parameter_count
        _ state: NativeOrbitResetCornerState,
        banked: [ProviderReset],
        used: [ProviderReset] = [],
        recentlyUsed: [Date],
        earlier: Date?,
        gauges: [NativeOrbitGaugeLane],
        laneTitles: [String: String] = [:],
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
        case let .inventory(available, _):
            let left = moment == .projecting ? " left by then" : ""
            let kinds = Self.resetKinds(banked, gauges: gauges, laneTitles: laneTitles)
            let usedKinds = Self.resetKinds(used, gauges: gauges, laneTitles: laneTitles)
            let hasParts = (kinds + usedKinds).contains { $0.name != nil }
            var lines: [String] = []
            if available == 0 {
                lines.append("No resets left" + (moment == .projecting ? " by then" : ""))
            } else if kinds.count == banked.count, kinds.contains(where: { $0.name != nil }) {
                let mixed = Set(kinds.map(\.name)).count > 1
                var seen: [String?] = []
                for kind in kinds where !seen.contains(kind.name) {
                    seen.append(kind.name)
                    let same = zip(kinds, banked).filter { $0.0.name == kind.name }.map(\.1)
                    let word = kind.name.map { "\($0) " } ?? (mixed ? "full " : "")
                    lines.append(
                        "\(same.count) \(word)" + (same.count == 1 ? "reset" : "resets") + left
                            + Self.resetExpiry(same, now: now))
                    guard let name = kind.name else { continue }
                    let back = kind.givesBack ? " and the \(gauges.first?.title ?? "wider limit") it used" : " only"
                    lines.append((same.count == 1 ? "It refills " : "Each refills ") + name + back)
                }
            } else {
                lines.append(
                    "\(available) " + (available == 1 ? "reset" : "resets") + left
                        + Self.resetExpiry(banked, now: now))
            }
            if let latest = recentlyUsed.max() {
                let when = NativeOrbitTooltip.at(latest, now: now)
                if recentlyUsed.count > 1 {
                    lines.append("Used \(recentlyUsed.count) this week, last \(when)")
                } else if hasParts, usedKinds.count == 1 {
                    lines.append("Used a \(usedKinds[0].name ?? "full") reset \(when)")
                } else {
                    lines.append("Used one \(when)")
                }
            } else if let earlier {
                lines.append("Last used " + NativeOrbitTooltip.at(earlier, now: now))
            } else if let given = banked.compactMap(\.grantedAt).max(), given <= now {
                lines.append("Last given " + NativeOrbitTooltip.at(given, now: now))
            }
            return lines.joined(separator: "\n")
        }
    }

    /// ", expires Dec 10" for resets that lapse together, ", next expires Dec 10" when they do not, and nothing for
    /// resets with no end.
    private static func resetExpiry(_ resets: [ProviderReset], now: Date) -> String {
        guard let soonest = resets.compactMap(\.expiresAt).min(), soonest > now else { return "" }
        let date = NativeOrbitTooltip.moment(soonest, now: now)
        guard Set(resets.map(\.expiresAt)).count == 1 else { return ", next expires \(date)" }
        return resets.count == 1 ? ", expires \(date)" : ", expire \(date)"
    }

    /// What each banked reset is, in order: no name for an ordinary one that clears everything, otherwise the
    /// name of the one gauge it clears ("Fable") and whether it also returns that gauge's share of the main one.
    static func resetKinds(
        _ banked: [ProviderReset],
        gauges: [NativeOrbitGaugeLane],
        laneTitles: [String: String] = [:]) -> [(name: String?, givesBack: Bool)]
    {
        let ids = gauges.map(\.id)
        return banked.map { reset in
            guard let lane = NativeOrbitResetComplication.lane(reset.scope, gauges: ids) else { return (nil, false) }
            let title = gauges.first { $0.id == lane }?.title ?? laneTitles[lane] ?? "Partial"
            // "Fable only" is the gauge's own title; the reset is a Fable reset.
            let name = title.replacing(/\s+only$/.ignoresCase(), with: "")
            return (name.isEmpty ? "Partial" : name, reset.givesBackWiderUsage)
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
        let shown = self.countsFromZero ? amount.map { _ in 0 } : amount
        return NativeOrbitComplication(
            value: shown.map { Self.money($0, currency: currency) } ?? "—",
            corner: .topLeading,
            help: help,
            numericValue: shown)
    }

    /// The bottom-trailing corner is always the additional-usage gauge. Its arc fills only from a reported
    /// used/limit pair; amounts without a limit, a disabled window, balances and recorded credits stay in its help.
    private func extraUsageReading(_ displayed: NativeOrbitAccountMetrics) -> some View {
        let fraction = displayed.reportedSpend?.isDisabled == true ? nil : displayed.extraUsageLeftFraction
        return NativeOrbitExtraUsageComplication(
            fraction: self.countsFromZero ? fraction.map { _ in 0 } : fraction,
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
            let cycle = spend.period?.localizedCaseInsensitiveContains("month") == true ? " this month" : ""
            if spend.limit > 0 {
                // The gauge draws what is left, so the words lead with it.
                let left = Self.money(max(0, spend.limit - spend.used), currency: spend.currencyCode)
                let limit = Self.money(spend.limit, currency: spend.currencyCode)
                lines.append("\(left) left of \(limit) additional usage\(cycle)")
            } else {
                lines.append("\(Self.money(spend.used, currency: spend.currencyCode)) of additional usage\(cycle)")
            }
            if spend.isOutOfFunds == true { lines.append("The provider has it paused: out of credits") }
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
