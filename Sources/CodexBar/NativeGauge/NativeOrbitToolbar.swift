import SwiftUI

struct NativeOrbitToolbar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var refreshPresses = 0
    @State private var settingsPresses = 0
    @State private var showingSpinner = false
    let state: NativeOrbitPopupState
    let refresh: () -> Void
    let settings: () -> Void

    /// The columns' content inset (8 pt column padding plus the footer's 6 pt), so the leading refresh glyph and the
    /// trailing gear line up with the account rows and dial corners above them.
    static let contentInset: CGFloat = 14
    static let glyphSpacing: CGFloat = 4
    static let rowHeight: CGFloat = 30
    static let verticalPadding: CGFloat = 9
    static let bottomInset: CGFloat = 0
    static let height = Self.rowHeight + Self.verticalPadding * 2 + Self.bottomInset
    /// The arrow makes one quick turn on the click (about half a second at double speed); the spinner takes over
    /// only if loading outlasts that turn.
    static let spinnerDelay: Duration = .milliseconds(500)

    var body: some View {
        NativeOrbitToolbarLayout(spacing: 8) {
            self.refreshInfo
            NativeOrbitRangeControl(
                days: Binding(get: { self.state.days }, set: { self.state.days = $0 }),
                accent: self.state.accent,
                fullWords: self.state.layoutColumns > 1)
                // Words where columns leave room; three even letter segments in a single 240 pt column.
                    .frame(width: self.state.layoutColumns > 1 ? 180 : 102, height: Self.rowHeight)
                    .help(L("native_orbit_range_help"))
            self.settingsButton
        }
        .frame(height: Self.rowHeight)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(Color.secondary)
        .buttonStyle(.plain)
        .controlSize(.regular)
        .tint(self.state.accent)
        .padding(.horizontal, Self.contentInset)
        .padding(.vertical, Self.verticalPadding)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: ConcentricRectangle())
        .task(id: self.state.isRefreshing) {
            guard self.state.isRefreshing else {
                withAnimation(self.reduceMotion ? nil : .smooth(duration: 0.25)) { self.showingSpinner = false }
                return
            }
            do {
                try await Task.sleep(for: self.reduceMotion ? .zero : Self.spinnerDelay)
            } catch {
                return
            }
            withAnimation(self.reduceMotion ? nil : .smooth(duration: 0.25)) { self.showingSpinner = true }
        }
    }

    // MARK: Refresh

    private var refreshInfo: some View {
        HStack(spacing: Self.glyphSpacing) {
            self.refreshButton
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                let now = max(timeline.date, self.state.now)
                // Wide columns read "5m ago"; a single column drops "ago" (or the whole label) before it would
                // crowd the centered range control. A refresh issue adds its one word ("5m ago · Stale"), which
                // outlasts the age when room runs out.
                ViewThatFits(in: .horizontal) {
                    self.ageLabel(self.refreshText(at: now, compact: false), now: now)
                    self.ageLabel(self.refreshText(at: now, compact: true), now: now)
                    if self.issue != nil { self.ageLabel(nil, now: now) }
                    Color.clear.frame(width: 0, height: 0)
                }
                .animation(self.reduceMotion ? nil : .smooth(duration: 0.3), value: self.issue)
                // The age appears with the columns it describes.
                .opacity(self.state.isReady ? 1 : 0)
                .animation(self.reduceMotion ? nil : .smooth(duration: 0.35), value: self.state.isReady)
            }
        }
    }

    private var refreshButton: some View {
        Button(action: self.pressRefresh) {
            Image(systemName: self.issue == nil
                ? "arrow.clockwise" : "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(self.issue == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.rotate.clockwise, options: .nonRepeating.speed(2), value: self.refreshPresses)
                .opacity(self.showingSpinner ? 0 : 1)
                .scaleEffect(self.showingSpinner ? 0.5 : 1)
                .blur(radius: self.showingSpinner ? 2 : 0)
                // The spinner sits on the arrow's center without widening the label, so the glyph keeps the
                // columns' inset and the age text never shifts.
                .overlay {
                    ProgressView()
                        .controlSize(.small)
                        .opacity(self.showingSpinner ? 1 : 0)
                        .scaleEffect(self.showingSpinner ? 0.8 : 0.4)
                }
                .frame(width: 18, height: Self.rowHeight)
                .contentShape(Rectangle())
        }
        .help(self.issue?.detail ?? L("Refresh"))
        .accessibilityLabel(L("Refresh"))
        .accessibilityValue(self.issue.map { "\($0.label). \($0.detail)" } ?? "")
    }

    /// The last press's issue, once its spinner has stopped.
    private var issue: NativeOrbitRefreshIssue? {
        self.state.isRefreshing ? nil : self.state.refreshIssue
    }

    /// The age, then the issue's word in the arrow's orange; a nil age shows the word alone.
    private func ageLabel(_ text: String?, now: Date) -> some View {
        HStack(spacing: 0) {
            if let text {
                Text(text)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: self.refreshAge(at: now)))
                    .animation(self.reduceMotion ? nil : .smooth(duration: 0.3), value: text)
            }
            if let issue = self.issue {
                Text(verbatim: text == nil ? issue.label : " · \(issue.label)")
                    .foregroundStyle(Color.orange)
                    .transition(.blurReplace)
            }
        }
        .lineLimit(1)
        .fixedSize()
        .help(self.issue?.detail ?? self.refreshHelp)
    }

    private func pressRefresh() {
        // Every press counts, even during a load: the popup joins the running load and, for a later press, runs
        // one more after it (`NativePopoverManualRefresh`). The button never disables, which would dim its spinner.
        if !self.reduceMotion { self.refreshPresses += 1 }
        // Start the refresh on the next turn so the arrow's spin is on screen before any loading work begins.
        Task { @MainActor in self.refresh() }
    }

    private func refreshText(at now: Date, compact: Bool) -> String {
        guard let updated = self.state.accounts.compactMap(\.updatedAt).min() else { return "—" }
        return compact ? Self.compactAge(updated, now: now) : Self.age(updated, now: now)
    }

    private func refreshAge(at now: Date) -> Double {
        guard let updated = self.state.accounts.compactMap(\.updatedAt).min() else { return 0 }
        return Double(Self.displayAgeSeconds(updated, now: now))
    }

    private var refreshHelp: String {
        guard let updated = self.state.accounts.compactMap(\.updatedAt).min() else { return L("Refresh") }
        return L("Updated %@", NativeOrbitTooltip.moment(updated, now: Date()))
    }

    // MARK: Settings

    private var settingsButton: some View {
        Button(action: self.pressSettings) {
            Image(systemName: "gear")
                .symbolEffect(.rotate.clockwise, options: .nonRepeating.speed(2), value: self.settingsPresses)
                // The gear's native bounds are larger: 12pt gear and 13pt arrow have matching visible heights.
                .font(.system(size: 12, weight: .medium))
                .frame(width: 18, height: Self.rowHeight)
                .contentShape(Rectangle())
        }
        .help(L("Settings"))
        .accessibilityLabel(L("Settings"))
    }

    private func pressSettings() {
        guard !self.reduceMotion else { return self.settings() }
        self.settingsPresses += 1
        // Settings becoming key dismisses the popup; let the gear's turn get under way before it opens.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(280))
            self.settings()
        }
    }

    // MARK: Age text

    static func age(_ updated: Date, now: Date) -> String {
        let seconds = Self.displayAgeSeconds(updated, now: now)
        let text: String = if seconds == 0 {
            L("just now")
        } else if seconds < 60 {
            L("%ds ago", seconds)
        } else if seconds < 3600 {
            L("%dm ago", seconds / 60)
        } else if seconds < 86400 {
            L("%dh ago", seconds / 3600)
        } else {
            L("%dd ago", seconds / 86400)
        }
        return Self.sentenceCased(text, locale: codexBarLocalizedResourceLocale())
    }

    /// The same age without "ago", for a single 240 pt column ("5m", "Now").
    static func compactAge(
        _ updated: Date,
        now: Date,
        locale: Locale = codexBarLocalizedResourceLocale()) -> String
    {
        let seconds = Self.displayAgeSeconds(updated, now: now)
        guard seconds > 0 else { return L("Now") }
        var style = Duration.UnitsFormatStyle(allowedUnits: [.seconds, .minutes, .hours, .days], width: .narrow)
        style.locale = locale
        return Duration.seconds(seconds).formatted(style)
    }

    /// A standalone label starts with a capital, whatever the catalog's mid-sentence casing ("just now").
    static func sentenceCased(_ text: String, locale: Locale) -> String {
        guard let first = text.first else { return text }
        return String(first).uppercased(with: locale) + text.dropFirst()
    }

    /// The label and its rolling transition share a value that changes only at visible boundaries.
    static func displayAgeSeconds(_ updated: Date, now: Date) -> Int {
        let seconds = max(0, Int(now.timeIntervalSince(updated)))
        if seconds < 30 { return 0 }
        if seconds < 60 { return 30 }
        if seconds < 3600 { return seconds / 60 * 60 }
        if seconds < 86400 { return seconds / 3600 * 3600 }
        return seconds / 86400 * 86400
    }
}

/// Why the toolbar's last refresh left a column behind: a word beside the age, and the full account for its help.
struct NativeOrbitRefreshIssue: Equatable {
    enum Kind: Equatable {
        /// A column's own fetch failed.
        case failed
        /// A column kept a reading taken well before the press.
        case stale
        /// The load outlived its timeout; it still publishes when it completes.
        case slow
    }

    let kind: Kind
    let detail: String

    var label: String {
        switch self.kind {
        case .failed: L("Failed")
        case .stale: L("native_refresh_issue_stale")
        case .slow: L("native_refresh_issue_slow")
        }
    }
}

/// Keep the range exactly centered while anchoring the other controls to the bar edges. Each side is offered only
/// the room beside the range, so its own fallbacks decide what to drop instead of overlapping it.
private struct NativeOrbitToolbarLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        return CGSize(
            width: proposal.width ?? sizes.reduce(0) { $0 + $1.width } + self.spacing * 2,
            height: sizes.map(\.height).max() ?? NativeOrbitToolbar.rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let middle = subviews[1].sizeThatFits(.unspecified)
        let sideWidth = max(0, (bounds.width - middle.width) / 2 - self.spacing)
        let sideProposal = ProposedViewSize(width: sideWidth, height: bounds.height)
        subviews[0].place(
            at: CGPoint(x: bounds.minX, y: bounds.midY),
            anchor: .leading,
            proposal: sideProposal)
        subviews[1].place(
            at: CGPoint(x: bounds.midX, y: bounds.midY),
            anchor: .center,
            proposal: ProposedViewSize(middle))
        subviews[2].place(
            at: CGPoint(x: bounds.maxX, y: bounds.midY),
            anchor: .trailing,
            proposal: sideProposal)
    }
}
