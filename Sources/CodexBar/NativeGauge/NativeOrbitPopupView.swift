import AppKit
import CodexBarCore
import Observation
import SwiftUI

@MainActor
@Observable
final class NativeOrbitPopupState {
    var accounts: [NativeOrbitAccountPresentation] = [] {
        didSet { self.invalidatePreparedHistory() }
    }

    var now = Date() {
        didSet {
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
        didSet { self.invalidatePreparedHistory() }
    }

    var accent = Color.primary
    /// Whether the popup has what its first frame shows (accounts, their readings, their history). Until then the
    /// columns stay hidden in a popup already sized for them, and then fade in together: nothing half drawn, nothing
    /// moving as data lands.
    var isReady = true
    /// The columns the popup is laid out for: the accounts shown, or while not ready the count it last showed.
    var layoutColumns = 1
    var isRefreshing = false
    /// Why the last refresh from the toolbar did not bring every column up to date; nil once one does.
    var refreshIssue: NativeOrbitRefreshIssue?
    var inspectionDate: Date?
    /// Why this provider's logins cannot be switched in this setup, for the active dial's switching light.
    var switchingUnavailable: String?
    /// Whether every warning light is lit for the bulb check, once after launch.
    var isBulbCheck = false
    var claudeLocalArchiveHistory: [PlanUtilizationSeriesHistory] = []
    var codexLocalArchiveHistory: [PlanUtilizationSeriesHistory] = []
    var kimiLocalArchiveHistory: [PlanUtilizationSeriesHistory] = []
    @ObservationIgnored private var historyCache: [String: [NativeOrbitHistoryWidget.Lane]] = [:]
    @ObservationIgnored private var observationCache: [String: [Date]] = [:]
    @ObservationIgnored private var projectionCache: [String: NativeOrbitAccountProjection] = [:]
    @ObservationIgnored private var markedEventCache: [String: [NativeOrbitMarkedEvent]] = [:]

    @ObservationIgnored private var projectingHistoryCache: [String: [NativeOrbitHistoryWidget.Lane]] = [:]
    @ObservationIgnored private var projectingObservationCache: [String: [Date]] = [:]

    private func invalidatePreparedHistory() {
        self.historyCache = [:]
        self.projectionCache = [:]
        self.markedEventCache = [:]
        self.projectingHistoryCache = [:]
        self.projectingObservationCache = [:]
    }

    /// The days of data every range draws: the widest range and a day of margin.
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
            // Predicted through the widest range, like the drawn data, so a range switch zooms the same marks.
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
        self.projectingHistoryCache[account.id] = widget.lanes
        self.projectingObservationCache[account.id] = widget.metricObservationDates
        return widget.lanes
    }

    func renderObservationDates(for account: NativeOrbitAccountPresentation) -> [Date] {
        guard self.isProjecting else { return self.observationDates(for: account) }
        _ = self.renderLanes(for: account)
        return self.projectingObservationCache[account.id] ?? []
    }

    func lanes(for account: NativeOrbitAccountPresentation) -> [NativeOrbitHistoryWidget.Lane] {
        if let cached = self.historyCache[account.id] { return cached }
        let widget = self.widget(for: account)
        self.historyCache[account.id] = widget.lanes
        self.observationCache[account.id] = widget.metricObservationDates
        return widget.lanes
    }

    func observationDates(for account: NativeOrbitAccountPresentation) -> [Date] {
        if let cached = self.observationCache[account.id], self.historyCache[account.id] != nil { return cached }
        _ = self.lanes(for: account)
        return self.observationCache[account.id] ?? []
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

    /// Hover reports every pointer move; only a changed instant should invalidate the columns.
    func inspect(_ date: Date?) {
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
        // Every range draws the widest range's data, so switching ranges only moves the window.
        widget.dataDays = Self.dataDays
        return widget
    }
}

struct NativeOrbitPopupView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let state: NativeOrbitPopupState
    let activate: (String) -> Void
    let signIn: (() -> Void)?
    var refresh: () -> Void = {}
    var settings: () -> Void = {}
    var lightAction: (NativeOrbitWarningLight.Action) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(self.state.accounts.enumerated()), id: \.element.id) { index, account in
                        if index > 0 {
                            Divider().frame(height: 464).padding(.top, 12)
                        }
                        self.column(account)
                    }
                }
                // Switching the active account moves its column to the front and its highlight with it.
                .animation(
                    self.reduceMotion ? nil : .smooth(duration: 0.45),
                    value: self.state.accounts.map { $0.id + ($0.isActive ? "|active" : "") })
                .opacity(self.state.isReady ? 1 : 0)
                .animation(self.reduceMotion ? nil : .smooth(duration: 0.35), value: self.state.isReady)
            }
            .scrollIndicators(.hidden)
            NativeOrbitToolbar(state: self.state, refresh: self.refresh, settings: self.settings)
        }
        .tint(self.state.accent)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: self.state.days) { self.state.inspectionDate = nil }
        .onDisappear { self.state.inspectionDate = nil }
    }

    /// History desaturates a column's gauges and the projected future intensifies them: a clear step on crossing,
    /// the rest by how far the pointer reads from now.
    static func accent(_ live: Color, inspecting date: Date?, now: Date, start: Date, end: Date) -> Color {
        NativeOrbitProjectionStyle.temporalAccent(
            live,
            offset: NativeOrbitProjectionStyle.temporalOffset(date, now: now, start: start, end: end))
    }

    /// The dial's blur while the pointer reads ahead of now, growing toward the end of the projected span.
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
        let liveAccent = self.state.accounts.count == 1 || account.isActive
            ? self.state.accent : Color.gray.mix(with: self.state.accent, by: 0.40)
        // Only the gauges read the hovered moment's colour: the chart and the corners keep the column's own.
        let gaugeAccent = Self.accent(
            liveAccent,
            inspecting: self.state.inspectionDate,
            now: self.state.now,
            start: self.state.chartStart,
            end: self.state.chartEnd)
        let lanes = self.state.renderLanes(for: account)
        let projection = self.state.projection(for: account)
        let isProjecting = self.state.isProjecting
        return VStack(spacing: 0) {
            NativeOrbitGaugeWidget(
                account: account,
                now: self.state.now,
                days: self.state.days,
                accent: liveAccent,
                gaugeAccent: gaugeAccent,
                badge: self.state.accounts.count > 1 ? self.state.badges[account.id] : nil,
                inspectionDate: self.state.inspectionDate,
                preparedLanes: lanes,
                projection: projection,
                isProjecting: isProjecting,
                futureBlur: Self.dialBlur(
                    inspecting: self.state.inspectionDate,
                    now: self.state.now,
                    end: self.state.chartEnd,
                    days: self.state.days),
                lights: self.lights(account, projection: projection),
                isBulbCheck: self.state.isBulbCheck,
                lightAction: self.lightAction)
            Rectangle().fill(Color(nsColor: .separatorColor).opacity(0.65)).frame(width: 166, height: 0.5)
                .overlay { self.hoverPill(account) }
                // The pill floats over the dial's foot and the chart's top, in front of both.
                .zIndex(1)
            NativeOrbitHistoryWidget(
                histories: account.history,
                now: self.state.now,
                days: self.state.days,
                accent: liveAccent,
                quotaLabels: account.quotaLabels,
                quotaWindows: account.quotaWindows,
                provider: UsageProvider(rawValue: account.gauge.provider),
                preparedLanes: lanes,
                preparedObservationDates: self.state.renderObservationDates(for: account),
                selectedDate: self.state.inspectionDate,
                onSelect: { [state = self.state] in state.inspect($0) },
                projection: isProjecting ? projection : nil,
                isProjecting: isProjecting,
                showsEmptyState: account.updatedAt != nil,
                dataDays: NativeOrbitPopupState.dataDays)
            if self.state.accounts.count > 1 || (account.updatedAt == nil && self.signIn != nil) {
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
    static func inspectedInstant(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let locale = codexBarLocalizedResourceLocale()
        let nearby = [-1, 0, 1].contains { offset in
            calendar.date(byAdding: .day, value: offset, to: now).map { calendar.isDate(date, inSameDayAs: $0) }
                ?? false
        }
        if nearby {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.doesRelativeDateFormatting = true
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return formatter.string(from: date)
        }
        var style = Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale, calendar: calendar)
            .weekday(.abbreviated)
        style.timeZone = calendar.timeZone
        return date.formatted(style.year(.omitted))
    }

    /// Everything the dial shows lit: the store's lights, the quota's fuel light and the switch controller's switching
    /// light. They describe now, whatever moment the pointer reads.
    private func lights(
        _ account: NativeOrbitAccountPresentation,
        projection: NativeOrbitAccountProjection) -> [NativeOrbitWarningLight]
    {
        var lights = account.warnings
        let now = self.state.now
        for window in account.gauge.resolvedWindows where window.usedFraction.map({ $0 >= 1 }) == true {
            let name = NativeOrbitGaugeWidget.limitName(window)
            let reset = window.countdown.flatMap { $0.isReliable ? $0.nextReset : nil }.flatMap { $0 > now ? $0 : nil }
            lights.append(.init(
                .quota,
                .critical,
                reset.map { "\(name) reached. It resets \(NativeOrbitTooltip.at($0, now: now))." }
                    ?? "\(name) reached."))
        }
        for lane in projection.lanes where lane.originUsed < 100 {
            guard let runsOut = lane.exhaustion, runsOut > now,
                  let window = account.gauge.resolvedWindows.first(where: { lane.id == "nativeQuota:\($0.id)" })
            else { continue }
            let name = NativeOrbitGaugeWidget.limitName(window)
            let reset = lane.nextReset(after: now)
            lights.append(.init(
                .quota,
                .caution,
                "\(name) runs out \(NativeOrbitTooltip.at(runsOut, now: now)) at this pace"
                    + (reset.map { ", before it resets \(NativeOrbitTooltip.at($0, now: now))." } ?? ".")))
        }
        if let switching = self.state.accountSwitch, switching.errorAccountID == account.id,
           let error = switching.error
        {
            lights.append(.init(.switching, .caution, error))
        }
        if account.isActive, self.state.accounts.count > 1, let reason = self.state.switchingUnavailable {
            lights.append(.init(.switching, .caution, reason))
        }
        return NativeOrbitWarningLight.merged(lights)
    }

    /// The account's bar: its name at the column's inset, and at the trailing end a checkmark on the active account or
    /// a Switch button on the others. Every column lays it out the same way, so the names line up.
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
        .font(.callout.weight(.medium))
        .foregroundStyle(.secondary)
        .frame(height: 28)
        .padding(.horizontal, 6)
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
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(self.state.accent)
                .help(L("Active %@ account", self.loginTarget))
                .accessibilityLabel(L("Active %@ account", self.loginTarget))
        } else if account.canActivate {
            let inFlight = self.state.accountSwitch?.inFlightID
            let switching = inFlight == account.id
            Button {
                self.activate(account.id)
            } label: {
                // The title keeps the button's size while the spinner stands in for it.
                Text(L("Switch"))
                    .foregroundStyle(.primary)
                    .opacity(switching ? 0 : 1)
                    .overlay {
                        if switching {
                            ProgressView().controlSize(.mini).transition(.opacity)
                        }
                    }
                    .animation(self.reduceMotion ? nil : .smooth(duration: 0.2), value: switching)
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            // Plain glass: the accent marks only what is current (the checkmark, the active column, the range).
            .tint(nil)
            // Another account's switch holds the others; the running one stays undimmed so its spinner reads.
            .disabled(inFlight != nil && !switching)
            .allowsHitTesting(!switching)
            .help(L("Use in %@", self.loginTarget))
            .accessibilityLabel(L("Switch to %@", account.label))
            .accessibilityValue(switching ? L("Switching account…") : "")
        }
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
    /// Predicted readings soften with distance ahead, like the projection they come from.
    var futureBlur: CGFloat = 0
    var lights: [NativeOrbitWarningLight] = []
    var isBulbCheck = false
    var lightAction: (NativeOrbitWarningLight.Action) -> Void = { _ in }

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

    var body: some View {
        let windows = self.windows
        ZStack {
            ForEach(Array(windows.prefix(3).enumerated()), id: \.element.id) { lane, window in
                let countdown = NativeOrbitCountdown(window: window)
                NativeOrbitSymbol(
                    remaining: window.usedFraction.map { 1 - $0 },
                    countdown: countdown.value(at: self.displayDate),
                    segments: countdown.segments,
                    lane: lane,
                    size: 216,
                    accent: NativeOrbitPalette.color(accent: self.gaugeAccent, id: window.id, period: window.period))
                    .blur(radius: self.futureBlur)
                NativeOrbitCurvedLabel(
                    title: Self.title(window), radius: NativeOrbitSymbol.radii[lane] * 216 / 256, size: 216)
                    .foregroundStyle(Color.primary)
                    .opacity(0.32)
                    .blur(radius: self.futureBlur)
                    .allowsHitTesting(false)
                self.helpTargets(window, lane: lane)
            }
            // The face softens ahead of now, labels included; the marks in the middle show no data, so barely.
            self.identity(windows)
                .blur(radius: self.futureBlur * 0.35)
            // The warning lights describe now, so they step aside while the pointer reads another moment.
            NativeOrbitWarningLightsView(
                lights: self.lights,
                lanes: min(3, max(1, windows.count)),
                isBulbCheck: self.isBulbCheck,
                action: self.lightAction)
                .opacity(self.inspectionDate == nil ? 1 : 0)
            NativeOrbitInstruments(
                account: self.account,
                days: self.days,
                now: self.displayDate,
                accent: self.accent,
                inspectionDate: self.inspectionDate,
                projection: self.projection,
                liveNow: self.now)
                .blur(radius: self.futureBlur)
        }
        .frame(width: 224, height: 240)
        .animation(self.reduceMotion ? nil : .smooth(duration: 0.22), value: self.inspectionDate != nil)
        .animation(self.reduceMotion ? nil : .smooth(duration: 0.22), value: self.isFuture)
        .animation(self.reduceMotion ? nil : .smooth(duration: 0.22), value: windows)
        .accessibilityElement(children: .contain)
    }

    private func identity(_ windows: [UsageWindow]) -> some View {
        ZStack {
            Group {
                // Provider-specific by design: Codex and Claude Code show their parent provider marks above the app.
                if self.account.gauge.productID == "codex" {
                    Image("provider.openai").resizable().scaledToFit()
                } else if self.account.gauge.productID == "claudecode" {
                    Image("provider.claude").resizable().scaledToFit()
                } else {
                    Color.clear
                }
            }
            .frame(width: 15, height: 15)
            .opacity(0.6)
            .offset(y: windows.count == 3 ? -24 : -34)
            // Provider-specific by design: The small parent-brand mark for Codex represents OpenAI.
            .help(self.account.gauge.productID == "codex" ? "OpenAI" : self.account.gauge.productName)
            Image("provider.\(self.account.gauge.productID)")
                .resizable().scaledToFit()
                .frame(width: windows.count == 3 ? 28 : 42, height: windows.count == 3 ? 22 : 34)
                .help(self.account.gauge.productName)
            Group {
                if let badge = self.badge {
                    Image(systemName: badge).symbolVariant(.fill)
                } else if windows.allSatisfy({ $0.usedFraction == nil }), self.account.updatedAt != nil {
                    // Only a reading that came back without windows is unknown; before the first one, stay quiet.
                    Image(systemName: "questionmark")
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
        let amount = left > 0 && left < 1 ? "<1" : left.formatted(.number.precision(.fractionLength(0)))
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
            return window.label.uppercased().replacingOccurrences(of: " WEEKLY", with: "")
        }
        return switch window.period {
        case 604_800: "WEEKLY"
        case 18000: "SESSION"
        case 86400: "DAILY"
        case 2_419_200...2_678_400: "MONTHLY"
        default: window.label.uppercased()
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

/// Use measured SF Mono advances and tangent rotation, with the baseline centered inside the dial.
private struct NativeOrbitCurvedLabel: View {
    let title: String
    let radius: CGFloat
    let size: CGFloat

    var body: some View {
        Canvas { context, _ in
            let font = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .bold)
            let letters = Array(self.title.prefix(20)).map(String.init)
            let widths = letters.map { ($0 as NSString).size(withAttributes: [.font: font]).width }
            let total = widths.reduce(0, +)
            var offset = -total / 2
            for (index, letter) in letters.enumerated() {
                let position = offset + widths[index] / 2
                let angle = Double.pi / 2 - Double(position / self.radius)
                var glyph = context
                glyph.translateBy(
                    x: self.size / 2 + self.radius * cos(angle),
                    y: self.size / 2 + self.radius * sin(angle))
                glyph.rotate(by: .radians(angle - .pi / 2))
                glyph.draw(Text(letter).font(Font(font)), at: .zero, anchor: .center)
                offset += widths[index]
            }
        }
        .frame(width: self.size, height: self.size)
        .accessibilityHidden(true)
    }
}
