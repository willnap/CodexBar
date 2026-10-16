import AppKit
import CodexBarCore
import Observation
import SwiftUI

@MainActor
@Observable
final class NativeOrbitPopupState {
    private var preparedAccounts: [NativeOrbitAccountPresentation] = []
    var accounts: [NativeOrbitAccountPresentation] {
        get { self.preparedAccounts }
        set {
            self.preparedAccounts = newValue.map { account in
                var prepared = account
                prepared.metrics = account.metrics.preparingInspection(history: account.history)
                return prepared
            }
            self.invalidatePreparedHistory()
        }
    }

    var now = Date() {
        didSet {
            self.warningLightsCache = [:]
            // Lanes only change with their histories (which replace `accounts`), the range, or the day.
            if abs(self.now.timeIntervalSince(oldValue)) >= 60
                || !Calendar.current.isDate(self.now, inSameDayAs: oldValue)
            {
                self.invalidatePreparedHistory()
            }
        }
    }

    var badges: [String: String] = [:]
    var accountSwitch: NativeAccountSwitchController?
    var days = 1 {
        didSet {
            guard self.days != oldValue else { return }
            if [1, 7, 30].contains(self.days), [1, 7, 30].contains(oldValue) {
                self.invalidateRangePreparation()
            } else {
                self.invalidatePreparedHistory()
            }
        }
    }

    var accent = Color.primary
    /// Evidence readiness informs the startup checks; prepared columns are visible immediately.
    var isReady = true
    /// The columns the popup is laid out for: the accounts shown, or while not ready the count it last showed.
    var layoutColumns = 1
    var isRefreshing = false
    /// Why the last refresh from the toolbar did not bring every column up to date; nil once one does.
    var refreshIssue: NativeOrbitRefreshIssue?
    var inspectionDate: Date? {
        didSet { if self.inspectionDate != oldValue { self.warningLightsCache = [:] } }
    }

    /// Why this provider's logins cannot be switched in this setup, for the active dial's switching light.
    var switchingUnavailable: String?
    /// Whether every warning light is lit for the bulb check, once after launch.
    var isBulbCheck = false
    var startup: NativeOrbitStartupPhase = .live
    var startupCheckpoint = 0
    var startupHistoryReady = true
    var startupStatusReady = true
    @ObservationIgnored private var startupGeneration = UUID()
    @ObservationIgnored private var startupHoverPolicy: NativeOrbitStartupHoverPolicy?
    @ObservationIgnored private var reportedStationaryStartupHover = false
    /// Offline performance fixtures only; no accounts or provider data are included.
    @ObservationIgnored private(set) var startupEvents: [[String: Any]] = []

    private func traceStartup(_ event: String) {
        guard CommandLine.arguments.contains("--preview-performance") else { return }
        if self.startupEvents.count >= 256 { self.startupEvents.removeFirst() }
        self.startupEvents.append([
            "event": event,
            "phase": String(describing: self.startup),
            "checkpoint": self.startupCheckpoint,
            "uptime": ProcessInfo.processInfo.systemUptime,
        ])
    }

    func armStartup(reduceMotion: Bool, pointerLocation: CGPoint? = nil) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            self.inspectionDate = nil
            self.startupHoverPolicy = NativeOrbitStartupHoverPolicy(
                armedPosition: pointerLocation ?? NSEvent.mouseLocation)
            self.reportedStationaryStartupHover = false
            self.startupGeneration = UUID()
            self.startupCheckpoint = 0
            self.startup = reduceMotion ? .reduced : .armed
        }
        self.traceStartup("arm")
    }

    /// One shared transaction per stage, across every column; SwiftUI interpolates the prepared geometry.
    func runStartup() async {
        self.traceStartup("runStart")
        guard !Task.isCancelled, self.startup.isActive else {
            self.traceStartup(Task.isCancelled ? "runSkipped.cancelled" : "runSkipped.live")
            return
        }
        let generation = self.startupGeneration
        if self.startup == .reduced {
            withAnimation(.easeOut(duration: 0.15)) { self.startup = .live }
            self.traceStartup("complete.reduced")
            return
        }
        withAnimation(.timingCurve(0.32, 0, 0.16, 1, duration: 0.64)) { self.startup = .sweeping }
        self.traceStartup("sweeping")
        do {
            for checkpoint in 1...4 {
                try await Task.sleep(for: .milliseconds(170))
                guard self.startupGeneration == generation else {
                    self.traceStartup("runStopped.replacedGeneration")
                    return
                }
                withAnimation(.easeOut(duration: 0.12)) { self.startupCheckpoint = checkpoint }
                self.traceStartup("checkpoint")
            }
            withAnimation(.timingCurve(0.22, 0.75, 0.2, 1, duration: 0.72)) { self.startup = .settling }
            self.traceStartup("settling")
            try await Task.sleep(for: .milliseconds(760))
            guard self.startupGeneration == generation else {
                self.traceStartup("runStopped.replacedGeneration")
                return
            }
            withAnimation(.easeOut(duration: 0.12)) { self.startup = .live }
            self.traceStartup("complete")
        } catch {
            if self.startupGeneration == generation {
                self.finishStartup(reason: "taskCancelled")
            } else {
                self.traceStartup("cancel.staleGeneration")
            }
        }
    }

    func finishStartup(reason: String = "explicit") {
        self.traceStartup("finish." + reason)
        self.startupGeneration = UUID()
        self.startupHoverPolicy = nil
        self.startup = .live
        self.startupCheckpoint = 0
    }

    func startupReadiness(for account: NativeOrbitAccountPresentation) -> NativeOrbitStartupReadiness {
        .init(
            readingReady: account.updatedAt != nil || account.statusText != nil,
            historyReady: self.startupHistoryReady,
            statusReady: self.startupStatusReady)
    }

    /// Populate expensive chart caches before interaction, never once per animation frame.
    func prepareStartupArtwork(screen: NSScreen?, appearance: NSAppearance? = nil) {
        for account in self.accounts {
            var startupAccount = account
            startupAccount.metrics = self.projection(for: account).liveMetrics
            _ = self.renderLanes(for: account)
            _ = self.renderObservationDates(for: account)
            _ = self.spendingHistory(for: account)
            NativeOrbitStartupArtwork.prepare(
                account: startupAccount,
                badge: self.accounts.count > 1 ? self.badges[account.id] : nil,
                now: self.now,
                screen: screen,
                realLights: self.displayLights(for: account),
                readiness: self.startupReadiness(for: account),
                appearance: appearance)
        }
    }

    var claudeLocalArchiveHistory: [PlanUtilizationSeriesHistory] = []
    var codexLocalArchiveHistory: [PlanUtilizationSeriesHistory] = []
    var kimiLocalArchiveHistory: [PlanUtilizationSeriesHistory] = []
    @ObservationIgnored private var historyCache: [String: [NativeOrbitHistoryWidget.Lane]] = [:]
    @ObservationIgnored private var observationCache: [String: [Date]] = [:]
    @ObservationIgnored private var projectionCache: [String: NativeOrbitAccountProjection] = [:]
    @ObservationIgnored private var markedEventCache: [String: [NativeOrbitMarkedEvent]] = [:]
    @ObservationIgnored private var spendingHistoryCache: [String: NativeOrbitSpendingHistory] = [:]
    @ObservationIgnored private var preparedSpendingAccounts: Set<String> = []
    @ObservationIgnored private var warningLightsCache: [String: [NativeOrbitWarningLight]] = [:]

    @ObservationIgnored private var projectingHistoryCache: [String: [NativeOrbitHistoryWidget.Lane]] = [:]
    @ObservationIgnored private var projectingObservationCache: [String: [Date]] = [:]

    private func invalidatePreparedHistory() {
        self.historyCache = [:]
        self.projectionCache = [:]
        self.markedEventCache = [:]
        self.spendingHistoryCache = [:]
        self.preparedSpendingAccounts = []
        self.warningLightsCache = [:]
        self.projectingHistoryCache = [:]
        self.projectingObservationCache = [:]
    }

    /// Every range uses the same 31-day quota marks. Only observations and predictions depend on the visible range.
    private func invalidateRangePreparation() {
        self.observationCache = [:]
        self.projectingObservationCache = [:]
        self.projectionCache = [:]
        self.markedEventCache = [:]
        self.spendingHistoryCache = [:]
        self.preparedSpendingAccounts = []
        self.warningLightsCache = [:]
    }

    /// Prepared source history shared by every range: the widest range and a day of margin.
    static let dataDays = 31

    /// Predictions for one account, made once per presentation refresh like its lanes; hovering only reads them.
    func projection(for account: NativeOrbitAccountPresentation) -> NativeOrbitAccountProjection {
        if let cached = self.projectionCache[account.id], self.historyCache[account.id] != nil { return cached }
        let projection = NativeOrbitAccountProjection.make(
            account: account,
            lanes: self.lanes(for: account),
            now: self.now,
            days: self.days,
            start: NativeOrbitChartAxis.start(now: self.now, days: self.days),
            // Prepare the widest prediction once; each range draws only its visible geometry.
            end: NativeOrbitChartAxis.projectingBounds(now: self.now, days: Self.dataDays).end,
            markingEnd: NativeOrbitChartAxis.projectingBounds(now: self.now, days: self.days).end)
        self.projectionCache[account.id] = projection
        return projection
    }

    /// While any account is in use, every chart centers now and plots the predicted future to its right.
    var isProjecting: Bool {
        self.accounts.contains { self.projection(for: $0).isActive }
    }

    var chartStart: Date {
        self.isProjecting ? NativeOrbitChartAxis.projectingBounds(now: self.now, days: self.days).start
            : NativeOrbitChartAxis.start(now: self.now, days: self.days)
    }

    var chartEnd: Date {
        self.isProjecting ? NativeOrbitChartAxis.projectingBounds(now: self.now, days: self.days).end : self.now
    }

    /// The lanes a column draws: the range's own lanes, or, while projecting, lanes reaching back the mirrored span.
    func renderLanes(for account: NativeOrbitAccountPresentation) -> [NativeOrbitHistoryWidget.Lane] {
        guard self.isProjecting else { return self.lanes(for: account) }
        if let cached = self.projectingHistoryCache[account.id] { return cached }
        let widget = self.widget(for: account, projecting: true)
        let lanes = widget.lanes
        self.projectingHistoryCache[account.id] = lanes
        self.projectingObservationCache[account.id] = widget.metricObservationDates
        return lanes
    }

    func renderObservationDates(for account: NativeOrbitAccountPresentation) -> [Date] {
        guard self.isProjecting else { return self.observationDates(for: account) }
        if let cached = self.projectingObservationCache[account.id] { return cached }
        let dates = self.widget(for: account, projecting: true).metricObservationDates
        self.projectingObservationCache[account.id] = dates
        return dates
    }

    func lanes(for account: NativeOrbitAccountPresentation) -> [NativeOrbitHistoryWidget.Lane] {
        if let cached = self.historyCache[account.id] { return cached }
        let widget = self.widget(for: account)
        let lanes = widget.lanes
        self.historyCache[account.id] = lanes
        self.observationCache[account.id] = widget.metricObservationDates
        return lanes
    }

    func observationDates(for account: NativeOrbitAccountPresentation) -> [Date] {
        if let cached = self.observationCache[account.id], self.historyCache[account.id] != nil { return cached }
        let dates = self.widget(for: account).metricObservationDates
        self.observationCache[account.id] = dates
        return dates
    }

    func spendingHistory(for account: NativeOrbitAccountPresentation) -> NativeOrbitSpendingHistory? {
        if self.preparedSpendingAccounts.contains(account.id) { return self.spendingHistoryCache[account.id] }
        self.preparedSpendingAccounts.insert(account.id)
        let metrics = account.metrics.at(nil, observedAt: account.updatedAt, history: account.history)
        guard let mode = NativeOrbitMonetaryInstrument.mode(
            provider: UsageProvider(rawValue: account.gauge.provider),
            windows: account.gauge.resolvedWindows,
            metrics: metrics) else { return nil }
        let history = NativeOrbitSpendingHistory.make(
            metrics: metrics,
            history: account.history,
            now: self.now,
            days: self.days,
            emphasizesQuota: mode == .budgetRemaining)
        self.spendingHistoryCache[account.id] = history
        return history
    }

    /// The reset or scheduled event the inspected moment sits on (hovering snaps onto marks), for the pill to name.
    func markedEvent(at date: Date, for account: NativeOrbitAccountPresentation) -> NativeOrbitMarkedEvent? {
        let events: [NativeOrbitMarkedEvent]
        if let cached = self.markedEventCache[account.id] {
            events = cached
        } else {
            var widget = self.widget(for: account, projecting: self.isProjecting)
            if self.isProjecting { widget.projection = self.projection(for: account) }
            events = widget.markedEvents(self.renderLanes(for: account))
            self.markedEventCache[account.id] = events
        }
        // Within one point of the mark: the pointer snapped onto it.
        let tolerance = self.chartEnd.timeIntervalSince(self.chartStart) / Double(NativeOrbitPopupView.plotWidth)
        return events.filter { abs($0.date.timeIntervalSince(date)) <= tolerance }
            .min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
    }

    /// Startup checkpoints change appearance, not evidence. Reuse the same evaluation until time or data changes.
    func warningLights(for account: NativeOrbitAccountPresentation) -> [NativeOrbitWarningLight] {
        if let cached = self.warningLightsCache[account.id] { return cached }
        let lights = NativeOrbitWarningEvaluation.lights(
            account: account,
            peers: self.accounts,
            projection: self.projection(for: account),
            date: self.inspectionDate,
            now: self.now,
            days: self.days,
            preparedLanes: self.renderLanes(for: account),
            isProjecting: self.isProjecting)
        self.warningLightsCache[account.id] = lights
        return lights
    }

    func displayLights(for account: NativeOrbitAccountPresentation) -> [NativeOrbitWarningLight] {
        var lights = self.warningLights(for: account)
        if self.inspectionDate == nil {
            if let switching = self.accountSwitch, switching.errorAccountID == account.id,
               let error = switching.error
            {
                lights.append(.init(.switching, .caution, error))
            }
            if account.isActive, self.accounts.count > 1, let reason = self.switchingUnavailable {
                lights.append(.init(.switching, .caution, reason))
            }
        }
        return NativeOrbitWarningLight.reconciled(lights)
    }

    /// Hover reports every pointer move; only a changed instant should invalidate the columns.
    func inspect(_ date: Date?, source: String = "programmatic", pointerLocation: CGPoint? = nil) {
        if self.startup.isActive, source == "hover", let policy = self.startupHoverPolicy,
           !policy.acceptsHover(at: pointerLocation ?? NSEvent.mouseLocation)
        {
            if !self.reportedStationaryStartupHover {
                self.traceStartup("hoverIgnored.stationary")
                self.reportedStationaryStartupHover = true
            }
            return
        }
        if date != nil, self.startup.isActive { self.finishStartup(reason: "inspect." + source) }
        if self.inspectionDate != date { self.inspectionDate = date }
    }

    private func widget(
        for account: NativeOrbitAccountPresentation,
        projecting: Bool = false) -> NativeOrbitHistoryWidget
    {
        var widget = NativeOrbitHistoryWidget(
            histories: account.history,
            now: self.now,
            days: self.days,
            quotaLabels: account.quotaLabels,
            quotaWindows: account.quotaWindows,
            provider: UsageProvider(rawValue: account.gauge.provider),
            // An early reset that several of this provider's accounts saw together, with nothing redeemed, was
            // the provider's.
            peerHistories: self.accounts.filter { $0.id != account.id }.map(\.history))
        widget.isProjecting = projecting
        widget.spending = self.spendingHistory(for: account)
        // Every range draws the widest range's data, so switching ranges only moves the window.
        widget.dataDays = Self.dataDays
        return widget
    }
}

struct NativeOrbitPopupView: View {
    /// Account controls, their padding and the separator above them.
    static let footerHeight: CGFloat = 38.5

    /// Keep the retained AppKit host and fixture windows aligned with the complete popup content.
    static func contentHeight(showsFooter: Bool) -> CGFloat {
        ceil(240 + 0.5 + 224 + (showsFooter ? self.footerHeight : 0) + NativeOrbitToolbar.height)
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let state: NativeOrbitPopupState
    let activate: (String) -> Void
    let signIn: (() -> Void)?
    var refresh: () -> Void = {}
    var settings: () -> Void = {}
    var lightAction: (String, NativeOrbitWarningLight.Action) -> Void = { _, _ in }
    /// Offline performance fixtures drive inspection themselves, independently of the user's pointer.
    var acceptsHoverInspection = true

    /// Each column owns its observation reads, so inspecting one moment does not invalidate the account list.
    private struct AccountColumn: View {
        let popup: NativeOrbitPopupView
        let account: NativeOrbitAccountPresentation

        var body: some View {
            self.popup.column(self.account)
        }
    }

    /// Execute hover-dependent construction in a child body instead of registering its reads on the whole column.
    private struct BodyScope<Content: View>: View {
        let content: () -> Content

        init(@ViewBuilder _ content: @escaping () -> Content) { self.content = content }

        var body: some View {
            self.content()
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(self.state.accounts.enumerated()), id: \.element.id) { index, account in
                        if index > 0 {
                            Divider().frame(height: 464).padding(.top, 12)
                        }
                        AccountColumn(popup: self, account: account)
                    }
                }
                // Startup places complete columns before revealing them. Ordinary account updates move the active
                // column and its highlight together, after the native chart hosts have finished their reveal.
                .animation(
                    self.reduceMotion || self.state.startup.isActive ? nil : .smooth(duration: 0.45),
                    value: self.state.accounts.map { $0.id + ($0.isActive ? "|active" : "") })
            }
            .scrollIndicators(.hidden)
            NativeOrbitToolbar(state: self.state, refresh: self.refresh, settings: self.settings)
        }
        .tint(self.state.accent)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: self.state.days) {
            self.state.finishStartup(reason: "rangeChanged")
            self.state.inspectionDate = nil
        }
        .onDisappear {
            self.state.finishStartup(reason: "disappeared")
            self.state.inspectionDate = nil
        }
    }

    /// History mutes the gauges and the future intensifies them. Each side retains one stable native glass tint.
    static func accent(_ live: Color, inspecting date: Date?, now: Date, start: Date, end: Date) -> Color {
        NativeOrbitProjectionStyle.temporalAccent(
            live,
            offset: NativeOrbitProjectionStyle.temporalOffset(date, now: now, start: start, end: end))
    }

    /// The face softens while the pointer reads ahead, growing toward the projected span's end.
    static func dialBlur(inspecting date: Date?, now: Date, end: Date, days: Int) -> CGFloat {
        guard let date, date > now else { return 0 }
        return NativeOrbitProjectionStyle.dialBlur(
            fraction: date.timeIntervalSince(now) / max(1, end.timeIntervalSince(now)),
            days: days)
    }

    /// The chart's plot width inside a 240 pt column (224 pt content less the history widget's 14 pt insets).
    static let plotWidth: CGFloat = 196

    private var loginTarget: String {
        // Provider-specific by design: ClaudeSwap activates Claude Code, while a Codex switch moves the CLI login and
        // the desktop app that shares it.
        self.state.accountSwitch?.provider == .claude ? "Claude Code" : NativeCodexDesktopHandoff.loginTargetName
    }

    private func column(_ account: NativeOrbitAccountPresentation) -> some View {
        // Prepared caches are observation-ignored. Subscribe explicitly to their clock/range inputs even when a
        // warm lookup returns before reading those properties, so captured lanes and predictions cannot go stale.
        let now = self.state.now
        let days = self.state.days
        let liveAccent = self.state.accounts.count == 1 || account.isActive
            ? self.state.accent : self.state.accent.mix(with: .gray, by: 0.12)
        let lanes = self.state.renderLanes(for: account)
        let projection = self.state.projection(for: account)
        let isProjecting = self.state.isProjecting
        return VStack(spacing: 0) {
            BodyScope {
                // Only the gauges read the hovered moment's colour: the chart and the corners keep the column's own.
                let gaugeAccent = Self.accent(
                    liveAccent,
                    inspecting: self.state.inspectionDate,
                    now: now,
                    start: self.state.chartStart,
                    end: self.state.chartEnd)
                NativeOrbitGaugeWidget(
                    account: account,
                    now: now,
                    days: days,
                    accent: liveAccent,
                    gaugeAccent: gaugeAccent,
                    badge: self.state.accounts.count > 1 ? self.state.badges[account.id] : nil,
                    inspectionDate: self.state.inspectionDate,
                    preparedLanes: lanes,
                    projection: projection,
                    isProjecting: isProjecting,
                    spending: self.state.spendingHistory(for: account),
                    futureBlur: Self.dialBlur(
                        inspecting: self.state.inspectionDate,
                        now: now,
                        end: self.state.chartEnd,
                        days: days),
                    lights: self.lights(account),
                    isBulbCheck: self.state.isBulbCheck,
                    lightAction: { self.lightAction(account.id, $0) },
                    startup: self.state.startup,
                    startupCheckpoint: self.state.startupCheckpoint,
                    startupReadiness: self.state.startupReadiness(for: account))
            }
            self.columnSeparator
                .overlay { BodyScope { self.hoverPill(account) } }
                // The pill floats over the dial's foot and the chart's top, in front of both.
                .zIndex(1)
            BodyScope {
                NativeOrbitHistoryWidget(
                    histories: account.history,
                    now: now,
                    days: days,
                    accent: liveAccent,
                    quotaLabels: account.quotaLabels,
                    quotaWindows: account.quotaWindows,
                    provider: UsageProvider(rawValue: account.gauge.provider),
                    spending: self.state.spendingHistory(for: account),
                    preparedLanes: lanes,
                    preparedObservationDates: self.state.renderObservationDates(for: account),
                    selectedDate: self.state.inspectionDate,
                    onSelect: { [state = self.state, acceptsHover = self.acceptsHoverInspection] in
                        if acceptsHover { state.inspect($0, source: "hover") }
                    },
                    projection: isProjecting ? projection : nil,
                    isProjecting: isProjecting,
                    showsEmptyState: account.updatedAt != nil,
                    dataDays: NativeOrbitPopupState.dataDays,
                    startup: self.state.startup)
            }
            if self.state.accounts.count > 1 || (account.updatedAt == nil && self.signIn != nil) {
                self.columnSeparator
                self.footer(account)
            }
        }
        .padding(.horizontal, 8)
        .background {
            if account.isActive, self.state.accounts.count > 1 {
                self.state.accent.opacity(0.055)
            }
        }
        .frame(width: 240)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(account.label)
    }

    /// The inspected instant, prominent and simple, in a glass pill centered in the gap between the dial and the
    /// chart (it covers the separator while shown).
    @ViewBuilder
    private func hoverPill(_ account: NativeOrbitAccountPresentation) -> some View {
        if let date = self.state.inspectionDate {
            let event = self.state.markedEvent(at: date, for: account)
            // On a mark the pill names it, with the mark's glyph, and keeps the time short so it fits one column.
            let time = event == nil ? Self.inspectedInstant(date, now: self.state.now)
                : NativeOrbitTooltip.moment(date, now: self.state.now)
            HStack(spacing: 5) {
                if let event {
                    if let symbol = event.symbol {
                        Image(systemName: symbol)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(event.isScheduled ? Color.secondary : self.state.accent)
                    }
                    Text(event.title)
                        .foregroundStyle(.primary)
                    Text(time)
                        .foregroundStyle(.secondary)
                } else {
                    Text(time)
                        .foregroundStyle(.primary)
                }
            }
            .font(.system(size: 12, weight: .semibold))
            .monospacedDigit()
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: 22)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .fixedSize()
            .offset(y: -4)
            .animation(self.reduceMotion ? nil : .smooth(duration: 0.2), value: event)
            .transition(.opacity.combined(with: .scale(scale: 0.92)))
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(event.map { "\($0.title), \(time)" } ?? time)
        }
    }

    /// "Today at 3:42 PM", "Tomorrow at 9:15 AM", or "Mon, Oct 6, 3:42 PM" further away, as the system writes them.
    @MainActor
    static func inspectedInstant(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        NativeOrbitInspectedInstantFormatter.shared.string(
            from: date, now: now, calendar: calendar, locale: codexBarLocalizedResourceLocale())
    }

    /// Evidence-dependent lights follow the same inspected moment as the dial.
    private func lights(_ account: NativeOrbitAccountPresentation) -> [NativeOrbitWarningLight] {
        self.state.displayLights(for: account)
    }

    private var columnSeparator: some View {
        Rectangle().fill(Color(nsColor: .separatorColor).opacity(0.65)).frame(width: 166, height: 0.5)
    }

    /// Names and equal-sized Active/Use capsules share the column inset, with breathing room above the toolbar.
    private func footer(_ account: NativeOrbitAccountPresentation) -> some View {
        HStack(spacing: 8) {
            if self.state.accounts.count > 1 {
                self.accountName(account)
                Spacer(minLength: 0)
                self.accountStatus(account)
            } else if let signIn = self.signIn, account.updatedAt == nil {
                Button(L("Sign In…"), action: signIn).buttonStyle(.plain)
            }
        }
        .font(.system(size: 11, weight: .regular))
        .foregroundStyle(Color.secondary.opacity(0.85))
        .frame(height: 26)
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
    }

    /// The name, or in its place why the last switch to this account failed (in full on hover).
    @ViewBuilder
    private func accountName(_ account: NativeOrbitAccountPresentation) -> some View {
        let switching = self.state.accountSwitch
        Group {
            if !account.isActive, switching?.errorAccountID == account.id, let error = switching?.error {
                Text(error)
                    .foregroundStyle(Color.orange)
                    .truncationMode(.tail)
                    .help(error)
            } else {
                Text(account.label)
                    .truncationMode(.middle)
                    .help(account.label)
            }
        }
        .lineLimit(1)
        .transition(.blurReplace)
        .animation(self.reduceMotion ? nil : .smooth(duration: 0.25), value: switching?.errorAccountID)
    }

    @ViewBuilder
    private func accountStatus(_ account: NativeOrbitAccountPresentation) -> some View {
        if account.isActive {
            self.accountCapsuleLabel(L("Active"))
                .glassEffect(.regular.tint(self.state.accent.opacity(0.18)), in: Capsule())
                .help(L("Active %@ account", self.loginTarget))
                .accessibilityLabel(L("Active %@ account", self.loginTarget))
                .accessibilityAddTraits(.isSelected)
        } else if account.canActivate {
            let inFlight = self.state.accountSwitch?.inFlightID
            let switching = inFlight == account.id
            Button {
                self.activate(account.id)
            } label: {
                // The title keeps the button's size while the spinner stands in for it.
                self.accountCapsuleLabel(L("Use"))
                    .opacity(switching ? 0 : 1)
                    .overlay {
                        if switching {
                            ProgressView().controlSize(.mini).transition(.opacity)
                        }
                    }
                    .animation(self.reduceMotion ? nil : .smooth(duration: 0.2), value: switching)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: Capsule())
            .controlSize(.small)
            .tint(nil)
            // Another account's switch holds the others; the running one stays undimmed so its spinner reads.
            .disabled(inFlight != nil && !switching)
            .opacity(inFlight != nil && !switching ? 0.5 : 1)
            .allowsHitTesting(!switching)
            .help(L("Use in %@", self.loginTarget))
            .accessibilityLabel(L("Switch to %@", account.label))
            .accessibilityValue(switching ? L("Switching account…") : "")
        }
    }

    private func accountCapsuleLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(width: 48, height: 22)
    }
}

struct NativeOrbitGaugeWidget: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let account: NativeOrbitAccountPresentation
    let now: Date
    let days: Int
    let accent: Color
    /// The rings' accent: desaturated while reading the past, intensified while reading ahead.
    let gaugeAccent: Color
    let badge: String?
    var inspectionDate: Date?
    var preparedLanes: [NativeOrbitHistoryWidget.Lane]
    var projection: NativeOrbitAccountProjection?
    var isProjecting = false
    var spending: NativeOrbitSpendingHistory?
    /// Predicted readings soften with distance ahead, like the projection they come from.
    var futureBlur: CGFloat = 0
    var lights: [NativeOrbitWarningLight] = []
    var isBulbCheck = false
    var lightAction: (NativeOrbitWarningLight.Action) -> Void = { _ in }
    var startup: NativeOrbitStartupPhase = .live
    var startupCheckpoint = 0
    var startupReadiness: NativeOrbitStartupReadiness = .pending

    private var windows: [UsageWindow] {
        NativeOrbitHistoricalInspection.windows(
            account: self.account,
            date: self.inspectionDate,
            now: self.now,
            days: self.days,
            preparedLanes: self.preparedLanes,
            projection: self.projection,
            isProjecting: self.isProjecting)
    }

    private var isFuture: Bool {
        self.inspectionDate.map { $0 > self.now } ?? false
    }

    private var displayDate: Date {
        self.inspectionDate ?? self.now
    }

    private var monetaryMode: NativeOrbitMonetaryInstrument.Mode? {
        NativeOrbitMonetaryInstrument.mode(
            account: self.account,
            windows: self.windows,
            date: self.inspectionDate,
            now: self.now,
            projection: self.projection)
    }

    private func monetaryReading(_ mode: NativeOrbitMonetaryInstrument.Mode) -> NativeOrbitMonetaryInstrument.Reading {
        NativeOrbitMonetaryInspection.reading(
            mode: mode,
            account: self.account,
            date: self.inspectionDate,
            now: self.now,
            days: self.days,
            projection: self.projection,
            spending: self.spending)
    }

    var body: some View {
        let startupActive = self.startup.isActive
        let motionReduced = self.reduceMotion
        let windows = self.windows
        let monetaryMode = self.monetaryMode
        let moneyLanes = monetaryMode == .budgetRemaining ? min(3, windows.count) : 0
        let moneySize = NativeOrbitMoneyReading.size(lanes: moneyLanes)
        let moneyBounds = CGRect(
            x: -moneySize.width / 2,
            y: -moneySize.height / 2,
            width: moneySize.width,
            height: moneySize.height)
        ZStack {
            ForEach(Array((monetaryMode == .balance || monetaryMode == .spend ? [] : windows)
                    .prefix(3).enumerated()), id: \.element.id)
            { lane, window in
                let countdown = NativeOrbitCountdown(window: window)
                NativeOrbitSymbol(
                    remaining: window.usedFraction.map { 1 - $0 },
                    countdown: countdown.value(at: self.displayDate),
                    segments: countdown.segments,
                    lane: lane,
                    size: 216,
                    accent: NativeOrbitPalette.color(accent: self.gaugeAccent, id: window.id, period: window.period),
                    startup: self.startup)
                    .blur(radius: self.futureBlur)
                NativeOrbitGaugeLabel(
                    title: Self.title(window),
                    radius: NativeOrbitSymbol.radii[lane] * 216 / 256,
                    size: 216,
                    remaining: self.startup.fraction(window.usedFraction.map { 1 - $0 }))
                    .blur(radius: self.futureBlur)
                    .allowsHitTesting(false)
                self.helpTargets(window, lane: lane)
            }
            // The face softens ahead of now, labels included; the marks in the middle show no data, so barely.
            if let monetaryMode {
                if !self.isBulbCheck || self.inspectionDate != nil {
                    NativeOrbitMoneyReading(
                        reading: self.monetaryReading(monetaryMode),
                        accent: self.gaugeAccent,
                        lanes: moneyLanes)
                        .blur(radius: min(0.6, self.futureBlur))
                        .modifier(NativeOrbitStartupReveal(progress: self.startup.readingsReveal))
                        .transaction { [isInspecting = self.inspectionDate != nil] transaction in
                            if isInspecting {
                                transaction.animation = nil
                                transaction.disablesAnimations = true
                            }
                        }
                }
                self.monetaryIdentity
                    .blur(radius: self.futureBlur * 0.35)
            } else {
                self.identity(windows)
                    .blur(radius: self.futureBlur * 0.35)
            }
            // The warning lights describe now, so they step aside while the pointer reads another moment.
            NativeOrbitWarningLightsView(
                lights: self.lights,
                lanes: monetaryMode == .balance || monetaryMode == .spend ? 1 : min(3, max(1, windows.count)),
                isBulbCheck: self.isBulbCheck,
                action: self.lightAction,
                reservedBounds: monetaryMode != nil && !self.isBulbCheck ? moneyBounds : nil,
                reservedRegions: monetaryMode == nil ? NativeOrbitWarningLayout.identityReservations(
                    lanes: min(3, max(1, windows.count)),
                    hasCompany: UsageProduct.companyID(self.account.gauge.provider) != nil,
                    hasBadge: self.badge != nil) :
                    self.monetaryIdentityRegions(lanes: moneyLanes),
                accountLabel: self.account.label,
                isInteractive: self.inspectionDate == nil,
                startup: self.startup,
                startupCheckpoint: self.startupCheckpoint,
                startupReadiness: self.startupReadiness)
                .transaction { [isInspecting = self.inspectionDate != nil] transaction in
                    if isInspecting {
                        transaction.animation = nil
                        transaction.disablesAnimations = true
                    }
                }
            NativeOrbitInstruments(
                account: self.account,
                days: self.days,
                now: self.displayDate,
                accent: self.accent,
                inspectionDate: self.inspectionDate,
                projection: self.projection,
                liveNow: self.now)
                .blur(radius: self.futureBlur)
                .modifier(NativeOrbitStartupReveal(progress: self.startup.readingsReveal))
        }
        .frame(width: 224, height: 240)
        .animation(self.reduceMotion ? nil : .smooth(duration: 0.22), value: self.inspectionDate != nil)
        .animation(self.reduceMotion ? nil : .smooth(duration: 0.22), value: self.isFuture)
        .transaction(value: windows) { [startupActive, motionReduced] transaction in
            if !startupActive, !transaction.disablesAnimations {
                transaction.animation = motionReduced ? nil : .smooth(duration: 0.22)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func monetaryIdentityRegions(lanes: Int) -> [CGRect] {
        let halfHeight = NativeOrbitMoneyReading.size(lanes: lanes).height / 2
        var regions = [CGRect(x: -15, y: -halfHeight - 28, width: 30, height: 22)]
        if UsageProduct.companyID(self.account.gauge.provider) != nil {
            regions.append(CGRect(x: -10, y: -halfHeight - 47, width: 20, height: 18))
        }
        if self.badge != nil {
            regions.append(CGRect(x: -10, y: halfHeight + 8, width: 20, height: 18))
        }
        return regions
    }

    private var monetaryIdentity: some View {
        let lanes = self.monetaryMode == .budgetRemaining ? min(3, self.windows.count) : 0
        let halfHeight = NativeOrbitMoneyReading.size(lanes: lanes).height / 2
        return ZStack {
            if let company = UsageProduct.companyID(self.account.gauge.provider) {
                Image(NativeOrbitProviderArtwork.name(for: company))
                    .resizable().scaledToFit().frame(width: 15, height: 15)
                    .opacity(0.6)
                    .offset(y: -halfHeight - 38)
                    .help(UsageProduct.companyName(company))
            }
            Image(NativeOrbitProviderArtwork.name(for: self.account.gauge.productID))
                .resizable().scaledToFit().frame(width: 25, height: 18)
                .offset(y: -halfHeight - 17)
            if let badge = self.badge {
                NativeOrbitAccountBadgeImage(symbol: badge)
                    .font(.system(size: 13))
                    .frame(width: 17, height: 17)
                    .offset(y: halfHeight + 17)
            }
        }
        .foregroundStyle(Color.primary.opacity(0.7))
        .help(self.account.gauge.productName)
    }

    private func identity(_ windows: [UsageWindow]) -> some View {
        ZStack {
            Group {
                // Provider-specific by design: Codex and Claude Code show their parent provider marks above the app.
                if let company = UsageProduct.companyID(self.account.gauge.provider) {
                    Image(NativeOrbitProviderArtwork.name(for: company)).resizable().scaledToFit()
                } else {
                    Color.clear
                }
            }
            .frame(width: 15, height: 15)
            .opacity(0.6)
            .offset(y: windows.count == 3 ? -24 : -34)
            // Provider-specific by design: The small parent-brand mark for Codex represents OpenAI.
            .help(UsageProduct.companyID(self.account.gauge.provider).map(UsageProduct.companyName) ?? self.account
                .gauge
                .productName)
            Image(NativeOrbitProviderArtwork.name(for: self.account.gauge.productID))
                .resizable().scaledToFit()
                .frame(width: windows.count == 3 ? 28 : 42, height: windows.count == 3 ? 22 : 34)
                .help(self.account.gauge.productName)
            Group {
                if let badge = self.badge {
                    NativeOrbitAccountBadgeImage(symbol: badge)
                }
            }
            .font(.system(size: 13))
            .frame(width: 17, height: 17)
            .opacity(0.65)
            .offset(y: windows.count == 3 ? 24 : 44)
            .help(self.account.label)
        }
        .foregroundStyle(.primary)
    }

    private func helpTargets(_ window: UsageWindow, lane: Int) -> some View {
        ZStack {
            NativeOrbitHitRegion(lane: lane, countdown: false)
                .fill(.clear)
                .contentShape(NativeOrbitHitRegion(lane: lane, countdown: false))
                .help(Self.usageHelp(window))
                .accessibilityLabel(Self.usageHelp(window))
            NativeOrbitHitRegion(lane: lane, countdown: true)
                .fill(.clear)
                .contentShape(NativeOrbitHitRegion(lane: lane, countdown: true))
                .help(Self.resetHelp(window, now: self.displayDate))
                .accessibilityLabel(Self.resetHelp(window, now: self.displayDate))
        }
        .frame(width: 216, height: 216)
    }

    /// "Weekly limit: 24% left".
    static func usageHelp(_ window: UsageWindow) -> String {
        guard let used = window.usedFraction else { return "\(self.limitName(window)): no reading yet" }
        let left = max(0, 1 - used) * 100
        let amount = left.formatted(.number.precision(.fractionLength(left > 0 && left < 1 ? 2 : 0)))
        return "\(Self.limitName(window)): \(amount)% left"
    }

    /// "Weekly limit resets Mon 3:00 PM, in 4d 3h"; a rolling window "partly recovers" instead.
    static func resetHelp(_ window: UsageWindow, now: Date) -> String {
        let name = Self.limitName(window)
        guard window.recovery != .none else { return "\(name) has no scheduled reset" }
        guard let countdown = window.countdown, countdown.isReliable, let date = countdown.nextReset else {
            return "\(name): reset time unknown"
        }
        guard date > now else { return "\(name) is due to reset" }
        let verb = window.recovery == .nextRecovery ? "partly recovers" : "resets"
        return "\(name) \(verb) \(NativeOrbitTooltip.at(date, now: now)), "
            + "in \(NativeOrbitTooltip.countdown(to: date, now: now))"
    }

    /// "Session limit", "Weekly limit", "Fable weekly limit".
    static func limitName(_ window: UsageWindow) -> String {
        if window.id == "tertiary" || window.id.hasPrefix("claude-weekly-scoped-") {
            let model = window.label.replacingOccurrences(of: " Weekly", with: "", options: .caseInsensitive)
            return "\(model) weekly limit"
        }
        return switch window.period {
        case 604_800: "Weekly limit"
        case 18000: "Session limit"
        case 86400: "Daily limit"
        case 2_419_200...2_678_400: "Monthly limit"
        default: "\(window.label) limit"
        }
    }

    static func title(_ window: UsageWindow) -> String {
        if window.id == "tertiary" || window.id.hasPrefix("claude-weekly-scoped-") {
            return window.label.replacingOccurrences(of: " weekly", with: "", options: .caseInsensitive)
        }
        return switch window.period {
        case 604_800: "Weekly"
        case 18000: "Session"
        case 86400: "Daily"
        case 2_419_200...2_678_400: "Monthly"
        default: window.label
        }
    }
}

/// Native help regions follow the artwork instead of covering other concentric lanes.
private struct NativeOrbitHitRegion: Shape {
    let lane: Int
    let countdown: Bool

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / NativeOrbitSymbol.canvas
        var path = Path()
        path.addArc(
            center: CGPoint(x: rect.midX, y: rect.midY),
            radius: NativeOrbitSymbol.radii[self.lane] * scale,
            startAngle: .degrees(self.countdown ? NativeOrbitSymbol.resetStart(lane: self.lane) : -130),
            endAngle: .degrees(self.countdown ? 360 - NativeOrbitSymbol.resetStart(lane: self.lane) : 130),
            clockwise: false)
        let stroke = path.strokedPath(StrokeStyle(lineWidth: 23 * scale, lineCap: .round))
        guard self.countdown else { return stroke }
        var sector = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        sector.move(to: center)
        sector.addArc(
            center: center,
            radius: max(rect.width, rect.height),
            startAngle: .degrees(NativeOrbitSymbol.resetStart(lane: self.lane)),
            endAngle: .degrees(360 - NativeOrbitSymbol.resetStart(lane: self.lane)),
            clockwise: false)
        sector.closeSubpath()
        return stroke.intersection(sector)
    }
}

/// The pill shares one clock configuration across columns. Pointer updates only format a date; formatter setup and
/// the nearby civil-day bounds are reused until the origin, locale, calendar, or time zone changes.
@MainActor
final class NativeOrbitInspectedInstantFormatter {
    static let shared = NativeOrbitInspectedInstantFormatter()

    private struct Configuration: Hashable {
        let calendar: Calendar
        let locale: Locale
    }

    private struct Formats {
        let relative: DateFormatter
        let distant: Date.FormatStyle
    }

    private var formats: [Configuration: Formats] = [:]
    private var configuration: Configuration?
    private var origin: Date?
    private var nearby: Range<Date>?

    func string(from date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        let configuration = Configuration(calendar: calendar, locale: locale)
        if self.configuration != configuration || self.origin != now {
            let day = calendar.startOfDay(for: now)
            if let lower = calendar.date(byAdding: .day, value: -1, to: day),
               let upper = calendar.date(byAdding: .day, value: 2, to: day)
            {
                self.nearby = lower..<upper
            } else {
                self.nearby = nil
            }
            self.configuration = configuration
            self.origin = now
        }
        let formats = self.preparedFormats(for: configuration)
        return self.nearby?.contains(date) == true
            ? formats.relative.string(from: date) : date.formatted(formats.distant)
    }

    private func preparedFormats(for configuration: Configuration) -> Formats {
        if let cached = self.formats[configuration] { return cached }
        let relative = DateFormatter()
        relative.locale = configuration.locale
        relative.calendar = configuration.calendar
        relative.timeZone = configuration.calendar.timeZone
        relative.doesRelativeDateFormatting = true
        relative.dateStyle = .medium
        relative.timeStyle = .short
        var distant = Date.FormatStyle(
            date: .abbreviated,
            time: .shortened,
            locale: configuration.locale,
            calendar: configuration.calendar)
            .weekday(.abbreviated).year(.omitted)
        distant.timeZone = configuration.calendar.timeZone
        let formats = Formats(relative: relative, distant: distant)
        if self.formats.count >= 8 { self.formats.removeAll(keepingCapacity: true) }
        self.formats[configuration] = formats
        return formats
    }
}
