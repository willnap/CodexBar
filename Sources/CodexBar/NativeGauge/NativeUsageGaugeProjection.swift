import CodexBarCore
import Foundation

typealias NativeServicePresentationRoute = ServicePopoverRoute<UsageProvider>

enum NativeUsageGaugeProjection {
    static func state(
        provider: UsageProvider,
        snapshot: UsageSnapshot?,
        error: String? = nil,
        codexProjection: CodexConsumerProjection? = nil,
        showOptionalCreditsAndExtraUsage: Bool = true,
        visibleMetrics: [UsageMenuCardView.Model.Metric]? = nil,
        weeklyPace: UsagePace? = nil,
        status: ProviderStatusIndicator = .none,
        isEnabled: Bool = true,
        hasAccess: Bool = true,
        isAuthenticationFailure: Bool = false) -> ComputeGauge.State
    {
        var state = ComputeGauge.State()
        state.provider = provider.rawValue
        state.weeklyUsed = nil
        state.fiveHourUsed = nil
        state.health = snapshot == nil ? .unknown : error == nil ? .live : .stale
        let metadata = ProviderDefaults.metadata[provider]
        let rawLanes: [(String, String, RateWindow?, Bool)] = [
            ("primary", metadata?.sessionLabel ?? "Primary", snapshot?.primary, true),
            ("secondary", metadata?.weeklyLabel ?? "Secondary", snapshot?.secondary, true),
            ("tertiary", metadata?.opusLabel ?? "Additional", snapshot?.tertiary, true),
        ]
        // Provider-specific by design: Codex consumer reconciliation binds short, weekly and credit lanes to
        // authoritative windows.
        var lanes = provider == .codex ? codexProjection.map { projection in
            projection.displayedRateLanes(
                showOptionalCreditsAndExtraUsage: showOptionalCreditsAndExtraUsage).map { lane in
                let window = projection.rateWindow(for: lane)
                return (lane.rawValue, CodexConsumerProjection.rateTitle(
                    lane: lane,
                    windowMinutes: window?.windowMinutes,
                    sessionLabel: metadata?.sessionLabel ?? "Session",
                    weeklyLabel: metadata?.weeklyLabel ?? "Weekly"), window, true)
            }
        } ?? rawLanes : rawLanes
        lanes += (snapshot?.extraRateWindows ?? []).map { ($0.id, $0.title, $0.window, $0.usageKnown) }
        var seenIDs = Set<String>()
        var windows = lanes.compactMap { id, label, candidate, usageKnown -> UsageWindow? in
            guard let window = candidate?.measured else { return nil }
            // Provider-specific by design: both Claude gauges hide unused model allowances and restore them on use.
            if provider == .claude, id == "tertiary" || id.hasPrefix("claude-weekly-scoped-"),
               !usageKnown || !window.usedPercent.isFinite || window.usedPercent <= 0
            {
                return nil
            }
            let metricID = id == "session" ? "primary" : id == "weekly" ? "secondary" : id
            let metric = visibleMetrics?.first { $0.id == metricID }
            if visibleMetrics != nil, metric == nil, id != "monthly" { return nil }
            guard seenIDs.insert(id).inserted else { return nil }
            let minutes = window.windowMinutes.flatMap { $0 > 0 ? $0 : nil }
            // The named monthly lane sorts outside short windows. Its reset scale still stays unknown unless
            // the provider supplies a duration; this nominal period is only used for layout ordering.
            let period = minutes.map { Double($0) * 60 } ?? (id == "monthly" ? 30 * 86400 : 1)
            var used = usageKnown && window.usedPercent.isFinite && window.usedPercent >= 0
                ? min(1, window.usedPercent / 100) : nil
            var isBindingCapped = false
            if let metric, let measured = used {
                let displayed = metric.percentStyle == .used ? metric.percent / 100 : 1 - metric.percent / 100
                if displayed.isFinite, abs(displayed - measured) > 0.000001 {
                    used = min(1, max(0, displayed))
                    isBindingCapped = true
                }
            }
            let countdown = isBindingCapped ? nil : minutes.map { _ in
                let units = Self.countdownUnits(period: period)
                return ResetCountdown(
                    units: units,
                    secondsPerUnit: period / Double(units),
                    nextReset: window.resetsAt,
                    isReliable: window.resetsAt != nil)
            } ?? window.resetsAt.map { date in
                // Preserve the provider deadline without inventing a countdown scale.
                ResetCountdown(
                    units: 1,
                    secondsPerUnit: 1,
                    nextReset: date,
                    isReliable: false)
            }
            return UsageWindow(
                id: id,
                label: metric?.title ?? label,
                period: period,
                used: used,
                countdown: countdown,
                recovery: window.nextRegenPercent.map { $0.isFinite && $0 > 0 } == true ? .nextRecovery : .reset)
        }
        // A genuine money budget already supplies both sides of a percentage. Use it only when the provider did
        // not report a quota; an optional overage allowance must not replace subscription capacity.
        if windows.isEmpty, snapshot?.measuredRateWindows.isEmpty == true,
           let budget = NativeOrbitMonetaryInstrument.validBudget(snapshot?.providerCost)
        {
            windows.append(UsageWindow(
                id: "monetary-budget",
                label: "Budget",
                period: 1,
                used: budget.used,
                limit: budget.limit,
                unit: budget.currencyCode,
                countdown: budget.resetsAt.map {
                    ResetCountdown(units: 1, secondsPerUnit: 1, nextReset: $0, isReliable: false)
                },
                recovery: budget.resetsAt == nil ? .none : .reset))
        }
        // The symbol supports three lanes. Keep binding/exhausted quotas first when there are more;
        // the usage card continues to show every quota, including lanes beyond the compact symbol.
        let selected = windows.enumerated().sorted { lhs, rhs in
            let leftExhausted = lhs.element.usedFraction == 1
            let rightExhausted = rhs.element.usedFraction == 1
            return leftExhausted == rightExhausted ? lhs.offset < rhs.offset : leftExhausted
        }.prefix(3).map(\.element)
        state.windows = selected.isEmpty
            ? [UsageWindow(id: "unknown", label: "Usage", period: 1, used: nil, recovery: .none)]
            : selected
        if !windows.isEmpty {
            state.health = windows.contains { $0.usedFraction != nil } ? (error == nil ? .live : .stale) : .unknown
        }
        if !isEnabled {
            state.health = .disabled
        } else if isAuthenticationFailure {
            state.health = .authentication
        } else if status == .major || status == .critical {
            state.health = .outage
        } else if status == .maintenance {
            state.health = .paused
        } else if !hasAccess || (error != nil && state.health == .unknown) {
            state.health = .offline
        }
        // A minor provider incident does not make an account's successful usage reading stale.
        // Keep incident reporting on the provider status surfaces; reserve the clock for failed refreshes.
        // This measures quota consumption against the provider's expected weekly usage, never request throughput.
        if state.health == .live, let weeklyPace {
            state.pace = switch weeklyPace.stage {
            case .onTrack: .normal
            case .slightlyBehind, .behind, .farBehind: .slow
            case .slightlyAhead, .ahead: .fast
            case .farAhead: .extreme
            }
        }
        return state
    }

    private static func countdownUnits(period: TimeInterval) -> Int {
        if period >= 28 * 86400 { return 6 }
        if period >= 86400 { return min(24, max(1, Int((period / 86400).rounded()))) }
        return min(24, max(1, Int((period / 3600).rounded(.up))))
    }
}
