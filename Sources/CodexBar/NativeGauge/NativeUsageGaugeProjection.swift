import CodexBarCore
import Foundation

typealias NativeServicePresentationRoute = ServicePopoverRoute<UsageProvider>

enum NativeUsageGaugeProjection {
    /// A Claude allowance for one model ("Fable only", the Sonnet or Opus week), drawn inside the all-models week.
    static func isClaudeModelLane(_ id: String) -> Bool {
        id == "tertiary" || id.hasPrefix("claude-weekly-scoped-")
    }

    /// How long after its last measured use a model allowance keeps its lane: one of its weekly periods.
    static let modelLaneRecentUse: TimeInterval = 7 * 86400

    /// A measured model allowance shows while it is in use, or was within the past week.
    private static func showsClaudeModelLane(
        _ id: String,
        window: RateWindow,
        usageKnown: Bool,
        history: [PlanUtilizationSeriesHistory],
        now: Date) -> Bool
    {
        guard usageKnown, window.usedPercent.isFinite, window.usedPercent >= 0 else { return false }
        return window.usedPercent > 0 || self.claudeModelLaneWasUsedRecently(id, history: history, now: now)
    }

    /// Whether `history` shows the model allowance `id` in use within the past week: a measured reading above
    /// zero. Server period totals are not readings and never count.
    static func claudeModelLaneWasUsedRecently(
        _ id: String,
        history: [PlanUtilizationSeriesHistory],
        now: Date) -> Bool
    {
        let cutoff = now.addingTimeInterval(-Self.modelLaneRecentUse)
        for series in history where series.name.rawValue == "nativeQuota:" + id {
            // Entries are in time order, so only the tail can be recent.
            for entry in series.entries.reversed() {
                guard entry.capturedAt >= cutoff else { break }
                if entry.capturedAt <= now, entry.historicalPeriod == nil, entry.usedPercent.isFinite,
                   entry.usedPercent > 0
                {
                    return true
                }
            }
        }
        return false
    }

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
        isAuthenticationFailure: Bool = false,
        modelLaneHistory: [PlanUtilizationSeriesHistory] = [],
        now: Date = Date()) -> ComputeGauge.State
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
            // Claude reports whole percentages, so an allowance reads 0 after each weekly reset and until use
            // reaches 1 %; one the account drew on within the past week stays, empty, instead of coming and going.
            if provider == .claude, Self.isClaudeModelLane(id),
               !Self.showsClaudeModelLane(
                   id, window: window, usageKnown: usageKnown, history: modelLaneHistory, now: now)
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
        // Provider-specific by design: with a session, a weekly and a used Sonnet allowance, a named model
        // allowance such as Fable was always the fourth lane and never drawn. The named allowance is the one
        // its model's use runs into, so it takes the third lane ahead of the Sonnet one.
        let hasNamedModelLane = provider == .claude
            && windows.contains { $0.id.hasPrefix("claude-weekly-scoped-") }
        func yields(_ window: UsageWindow) -> Bool {
            hasNamedModelLane && window.id == "tertiary"
        }
        let selected = windows.enumerated().sorted { lhs, rhs in
            let leftExhausted = lhs.element.usedFraction == 1
            let rightExhausted = rhs.element.usedFraction == 1
            if leftExhausted != rightExhausted { return leftExhausted }
            let leftYields = yields(lhs.element)
            let rightYields = yields(rhs.element)
            return leftYields == rightYields ? lhs.offset < rhs.offset : rightYields
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
