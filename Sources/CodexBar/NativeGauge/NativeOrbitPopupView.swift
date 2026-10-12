import AppKit
import CodexBarCore
import Observation
import SwiftUI

@MainActor
@Observable
final class NativeOrbitPopupState {
    var accounts: [NativeOrbitAccountPresentation] = [] {
        didSet { self.historyCache = [:] }
    }

    var now = Date() {
        didSet {
            // Lanes only change with their histories (which replace `accounts`), the range, or the day.
            if abs(self.now.timeIntervalSince(oldValue)) >= 60
                || !Calendar.current.isDate(self.now, inSameDayAs: oldValue)
            {
                self.historyCache = [:]
            }
        }
    }

    var badges: [String: String] = [:]
    var accountSwitch: NativeAccountSwitchController?
    var days = 1 {
        didSet { self.historyCache = [:] }
    }

    var accent = Color.primary
    var isRefreshing = false
    /// Why the last refresh from the toolbar did not bring every column up to date; nil once one does.
    var refreshError: String?
    var inspectionDate: Date?
    var claudeLocalArchiveHistory: [PlanUtilizationSeriesHistory] = []
    var codexLocalArchiveHistory: [PlanUtilizationSeriesHistory] = []
    var kimiLocalArchiveHistory: [PlanUtilizationSeriesHistory] = []
    @ObservationIgnored private var historyCache: [String: [NativeOrbitHistoryWidget.Lane]] = [:]
    @ObservationIgnored private var observationCache: [String: [Date]] = [:]

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

    /// Hover reports every pointer move; only a changed instant should invalidate the columns.
    func inspect(_ date: Date?) {
        if self.inspectionDate != date { self.inspectionDate = date }
    }

    private func widget(for account: NativeOrbitAccountPresentation) -> NativeOrbitHistoryWidget {
        NativeOrbitHistoryWidget(
            histories: account.history,
            now: self.now,
            days: self.days,
            quotaLabels: account.quotaLabels,
            quotaWindows: account.quotaWindows,
            provider: UsageProvider(rawValue: account.gauge.provider),
            // An early reset that several of this provider's accounts saw together, with nothing redeemed, was
            // the provider's.
            peerHistories: self.accounts.filter { $0.id != account.id }.map(\.history))
    }
}

struct NativeOrbitPopupView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let state: NativeOrbitPopupState
    let activate: (String) -> Void
    let signIn: (() -> Void)?
    var refresh: () -> Void = {}
    var settings: () -> Void = {}

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
            }
            .scrollIndicators(.hidden)
            NativeOrbitToolbar(state: self.state, refresh: self.refresh, settings: self.settings)
        }
        .tint(self.state.accent)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: self.state.days) { self.state.inspectionDate = nil }
        .onDisappear { self.state.inspectionDate = nil }
    }

    private var loginTarget: String {
        // Provider-specific by design: ClaudeSwap activates Claude Code, while a Codex switch moves the CLI login and
        // the desktop app that shares it.
        self.state.accountSwitch?.provider == .claude ? "Claude Code" : NativeCodexDesktopHandoff.loginTargetName
    }

    private func column(_ account: NativeOrbitAccountPresentation) -> some View {
        let liveAccent = self.state.accounts.count == 1 || account.isActive
            ? self.state.accent : Color.gray.mix(with: self.state.accent, by: 0.40)
        let accent = self.state.inspectionDate == nil ? liveAccent : liveAccent.mix(with: .secondary, by: 0.45)
        let lanes = self.state.lanes(for: account)
        return VStack(spacing: 0) {
            NativeOrbitGaugeWidget(
                account: account,
                now: self.state.now,
                days: self.state.days,
                accent: accent,
                badge: self.state.accounts.count > 1 ? self.state.badges[account.id] : nil,
                inspectionDate: self.state.inspectionDate,
                preparedLanes: lanes)
            Rectangle().fill(Color(nsColor: .separatorColor).opacity(0.65)).frame(width: 166, height: 0.5)
            NativeOrbitHistoryWidget(
                histories: account.history,
                now: self.state.now,
                days: self.state.days,
                accent: accent,
                quotaLabels: account.quotaLabels,
                quotaWindows: account.quotaWindows,
                provider: UsageProvider(rawValue: account.gauge.provider),
                preparedLanes: lanes,
                preparedObservationDates: self.state.observationDates(for: account),
                selectedDate: self.state.inspectionDate,
                onSelect: { [state = self.state] in state.inspect($0) })
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

    private func footer(_ account: NativeOrbitAccountPresentation) -> some View {
        HStack(spacing: 5) {
            if self.state.accounts.count > 1 {
                if account.isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(self.state.accent)
                        .help(L("Active %@ account", self.loginTarget))
                }
                Text(account.label).lineLimit(1).truncationMode(.middle)
                    .help(account.label)
                Spacer(minLength: 1)
                if account.canActivate, !account.isActive {
                    // Account surfaces and labels never activate a login. Only this explicit menu action does.
                    Menu {
                        Button(L("Use in %@", self.loginTarget)) { self.activate(account.id) }
                        if let error = self.state.accountSwitch?.error { Text(error) }
                    } label: {
                        Image(systemName: self.state.accountSwitch?.inFlightID == account.id
                            ? "hourglass" : "arrow.right.circle.fill")
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .disabled(self.state.accountSwitch?.inFlightID != nil)
                    .help(L("Use this account in %@", self.loginTarget))
                    .accessibilityLabel(L("Use %@ in %@", account.label, self.loginTarget))
                }
            } else if let signIn = self.signIn, account.updatedAt == nil {
                Button(L("Sign In…"), action: signIn).buttonStyle(.plain)
            }
        }
        .font(.callout.weight(.medium))
        .foregroundStyle(.secondary)
        .frame(height: 28)
        .padding(.horizontal, 6)
    }
}

private struct NativeOrbitGaugeWidget: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let account: NativeOrbitAccountPresentation
    let now: Date
    let days: Int
    let accent: Color
    let badge: String?
    var inspectionDate: Date?
    var preparedLanes: [NativeOrbitHistoryWidget.Lane]

    private var windows: [UsageWindow] {
        NativeOrbitHistoricalInspection.windows(
            account: self.account,
            date: self.inspectionDate,
            now: self.now,
            days: self.days,
            preparedLanes: self.preparedLanes)
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
                    accent: NativeOrbitPalette.color(accent: self.accent, id: window.id, period: window.period))
                NativeOrbitCurvedLabel(
                    title: Self.title(window), radius: NativeOrbitSymbol.radii[lane] * 216 / 256, size: 216)
                    .foregroundStyle(Color.primary)
                    .opacity(0.32)
                    .allowsHitTesting(false)
                self.helpTargets(window, lane: lane)
            }
            self.identity(windows)
            NativeOrbitInstruments(
                account: self.account,
                days: self.days,
                now: self.displayDate,
                accent: self.accent,
                inspectionDate: self.inspectionDate)
            Circle()
                .strokeBorder(
                    self.accent.opacity(self.inspectionDate == nil ? 0 : 0.35),
                    style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
                .frame(width: 207, height: 207)
                .allowsHitTesting(false)
        }
        .frame(width: 224, height: 240)
        .animation(self.reduceMotion ? nil : .smooth(duration: 0.22), value: self.inspectionDate != nil)
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
                } else if windows.allSatisfy({ $0.usedFraction == nil }) {
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
                .help("\(Self.title(window)) · \(window.recoveryDescription(at: self.displayDate))\n"
                    + (window.countdown?.nextReset?.formatted(date: .complete, time: .standard) ?? "")
                    + "\n\(NativeOrbitCountdown(window: window).description)")
                .accessibilityLabel("\(Self.title(window)) · \(window.recoveryDescription(at: self.displayDate))")
        }
        .frame(width: 216, height: 216)
    }

    private static func usageHelp(_ window: UsageWindow) -> String {
        guard let used = window.usedFraction else { return "\(self.title(window)) · Usage unavailable" }
        let available = ((1 - used) * 100).formatted(.number.precision(.fractionLength(0...2)))
        let consumed = (used * 100).formatted(.number.precision(.fractionLength(0...2)))
        return "\(Self.title(window)) · \(available)% available · \(consumed)% used"
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
