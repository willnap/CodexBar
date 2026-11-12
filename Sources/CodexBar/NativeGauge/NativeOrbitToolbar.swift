import SwiftUI

struct NativeOrbitToolbar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var refreshPresses = 0
    @State private var settingsPresses = 0
    @State private var showingSpinner = false
    let state: NativeOrbitPopupState
    let refresh: () -> Void
    let settings: () -> Void
    /// Combined account ranges join this same input transaction, before SwiftUI starts updating either chart.
    var rangeChanged: (Int) -> Void = { _ in }

    /// The columns' content inset (8 pt column padding plus the footer's 6 pt), so the leading refresh glyph and the
    /// trailing gear line up with the account rows and dial corners above them.
    static let contentInset: CGFloat = 14
    /// The settings glass reaches this far past its gear.
    static let glassPadding: CGFloat = 6
    static let glyphSpacing: CGFloat = 4
    /// The refresh arrow's ink is 11.5 × 13 pt at its 13 pt size. The capsule's glass reaches as far past the ink of
    /// the arrow and the age on each side as above and below them; the arrow's frame starts half a point before its
    /// ink, and the age's ends a point past its own.
    static let refreshGlyphWidth: CGFloat = 12
    static let refreshInset: CGFloat = (Self.rowHeight - 13) / 2
    static let refreshLeading = Self.refreshInset - 0.5
    static let refreshTrailing = Self.refreshInset - 1
    static let rowHeight: CGFloat = 30
    /// Below the controls, to the popup's edge; above them, to the footer, which already ends in 6 pt of its own, so
    /// the controls sit as far from the content above as from the edge below.
    static let verticalPadding: CGFloat = 9
    static let topPadding: CGFloat = 3
    static let height = Self.topPadding + Self.rowHeight + Self.verticalPadding
    /// The arrow makes one quick turn on the click (about half a second at double speed); the spinner takes over
    /// only if loading outlasts that turn.
    static let spinnerDelay: Duration = .milliseconds(500)

    /// No bar of its own: like a Liquid Glass toolbar, its controls float as glass over the columns, whose tints run on
    /// underneath them.
    var body: some View {
        GlassEffectContainer(spacing: 8) {
            self.controls
        }
        .padding(.horizontal, Self.contentInset - Self.glassPadding)
        .padding(.top, Self.topPadding)
        .padding(.bottom, Self.verticalPadding)
        .frame(maxWidth: .infinity)
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

    private var controls: some View {
        NativeOrbitToolbarLayout(spacing: 8) {
            self.refreshInfo
            NativeOrbitRangeControl(
                days: Binding(get: { self.state.days }, set: {
                    self.state.select(days: $0)
                    self.rangeChanged($0)
                }),
                span: self.state.visibleSpan,
                accent: self.state.accent,
                fullWords: self.state.layoutColumns > 1)
                // Words where columns leave room; even letter segments in a single 240 pt column.
                    .frame(
                        width: NativeOrbitRangeControl.width(
                            span: self.state.span, fullWords: self.state.layoutColumns > 1),
                        height: Self.rowHeight)
                    .animation(self.reduceMotion ? nil : .smooth(duration: 0.28), value: self.state.span)
                    .help(L("native_orbit_range_help"))
            self.settingsButton
        }
        .frame(height: Self.rowHeight)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(Color.secondary)
        .buttonStyle(.plain)
        .controlSize(.regular)
        .tint(self.state.accent)
    }

    // MARK: Refresh

    /// The arrow and the age share one glass capsule, all of it the refresh button.
    private var refreshInfo: some View {
        Button(action: self.pressRefresh) {
            HStack(spacing: Self.glyphSpacing) {
                self.refreshGlyph
                self.ageReadout
            }
            .padding(.leading, Self.refreshLeading)
            .padding(.trailing, Self.refreshTrailing)
            .frame(height: Self.rowHeight)
            .contentShape(Capsule())
        }
        .glassEffect(.regular.interactive(), in: Capsule())
        .overlay { NativeOrbitHoverHelp(text: self.issue?.detail ?? self.refreshHelp) }
        .accessibilityLabel(L("Refresh"))
        .accessibilityValue(self.issue.map { "\($0.label). \($0.detail)" } ?? "")
    }

    private var ageReadout: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let now = max(timeline.date, self.state.now)
            // Wide columns read "5m ago"; a single column drops "ago" (or the whole label) before it would
            // crowd the centered range control. A refresh that went wrong changes the arrow, never this text.
            ViewThatFits(in: .horizontal) {
                self.ageLabel(self.refreshText(at: now, compact: false), now: now)
                self.ageLabel(self.refreshText(at: now, compact: true), now: now)
                Color.clear.frame(width: 0, height: 0)
            }
            // The age appears with the columns it describes.
            .opacity(self.state.isReady ? 1 : 0)
            .animation(self.reduceMotion ? nil : .smooth(duration: 0.35), value: self.state.isReady)
        }
    }

    private var refreshGlyph: some View {
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
                NativeOrbitSpinner(isSpinning: self.showingSpinner, size: 13)
                    .opacity(self.showingSpinner ? 1 : 0)
                    .scaleEffect(self.showingSpinner ? 1 : 0.5)
            }
            .frame(width: Self.refreshGlyphWidth, height: Self.rowHeight)
    }

    /// The last press's issue, once its spinner has stopped.
    private var issue: NativeOrbitRefreshIssue? {
        self.state.isRefreshing ? nil : self.state.refreshIssue
    }

    private func ageLabel(_ text: String, now: Date) -> some View {
        Text(text)
            .monospacedDigit()
            .contentTransition(.numericText(value: self.refreshAge(at: now)))
            .animation(self.reduceMotion ? nil : .smooth(duration: 0.3), value: text)
            .lineLimit(1)
            .fixedSize()
    }

    private func pressRefresh() {
        // Every press counts, even during a load: the popup joins the running load and, for a later press, runs
        // one more after it (`NativePopoverManualRefresh`). The button never disables, which would dim its spinner.
        if !self.reduceMotion { self.refreshPresses += 1 }
        // Start the refresh on the next turn so the arrow's spin is on screen before any loading work begins.
        Task { @MainActor in self.refresh() }
    }

    /// The reading the age describes: the oldest among the accounts in use. Saved accounts that are not in use
    /// are measured on their own slower pace (claude-swap's, or the secondary-account interval) that a press
    /// cannot hurry, so dating the readout by them left it unchanged after every refresh. A column a load could
    /// not bring up to date still reports itself through the refresh issue.
    private var readoutDate: Date? {
        let inUse = self.state.accounts.filter(\.isActive).compactMap(\.updatedAt)
        return (inUse.isEmpty ? self.state.accounts.compactMap(\.updatedAt) : inUse).min()
    }

    private func refreshText(at now: Date, compact: Bool) -> String {
        guard let updated = self.readoutDate else { return "—" }
        return compact ? Self.compactAge(updated, now: now) : Self.age(updated, now: now)
    }

    private func refreshAge(at now: Date) -> Double {
        guard let updated = self.readoutDate else { return 0 }
        return Double(Self.displayAgeSeconds(updated, now: now))
    }

    private var refreshHelp: String {
        guard let updated = self.readoutDate else { return L("Refresh") }
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
                .padding(.horizontal, Self.glassPadding)
                .contentShape(Circle())
        }
        .glassEffect(.regular.interactive(), in: Circle())
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

/// What went wrong with the toolbar's last refresh, one entry for each column it left behind.
struct NativeOrbitRefreshIssue: Equatable {
    enum Kind: Equatable {
        /// A column's own fetch failed.
        case failed
        /// A column kept a reading taken well before the press.
        case stale
        /// The load outlived its timeout; it still publishes when it completes.
        case slow
    }

    struct Entry: Equatable {
        /// The service, where several share the toolbar.
        var service: String?
        /// The account, where the service shows several.
        var account: String?
        let message: String

        var line: String {
            let owner = [self.service, self.account].compactMap(\.self).joined(separator: " ")
            return owner.isEmpty ? self.message : "\(owner): \(self.message)"
        }
    }

    let kind: Kind
    let entries: [Entry]

    init(kind: Kind, entries: [Entry]) {
        self.kind = kind
        self.entries = entries
    }

    init(kind: Kind, detail: String) {
        self.init(kind: kind, entries: [.init(message: detail)])
    }

    /// One plain line for each column: whose reading it is, then why it was left as it was.
    var detail: String {
        self.entries.map(\.line).joined(separator: "\n")
    }

    var label: String {
        switch self.kind {
        case .failed: L("Failed")
        case .stale: L("native_refresh_issue_stale")
        case .slow: L("native_refresh_issue_slow")
        }
    }

    /// Several services under one toolbar: every entry names its service, and the worst kind is the toolbar's.
    static func combined(
        _ issues: [(service: String, issue: NativeOrbitRefreshIssue?)]) -> NativeOrbitRefreshIssue?
    {
        let entries = issues.flatMap { service, issue in
            (issue?.entries ?? []).map { Entry(service: service, account: $0.account, message: $0.message) }
        }
        let kinds = issues.compactMap(\.issue?.kind)
        guard !entries.isEmpty, let kind = [Kind.failed, .slow, .stale].first(where: kinds.contains)
        else { return nil }
        return NativeOrbitRefreshIssue(kind: kind, entries: entries)
    }
}

/// The system's indeterminate spinner as a symbol, so it is drawn in the same style as the glyph it stands in for.
/// `ProgressView`'s AppKit indicator did not follow the glass it sat on: it came out white on light glass.
struct NativeOrbitSpinner: View {
    let isSpinning: Bool
    let size: CGFloat

    var body: some View {
        Image(systemName: "progress.indicator")
            .font(.system(size: self.size, weight: .medium))
            .symbolEffect(.variableColor.iterative, options: .repeat(.continuous), isActive: self.isSpinning)
            .accessibilityHidden(true)
    }
}

/// Hover help held by an AppKit view of its own. The text is set only when it changes, so a label that redraws
/// every second under the pointer cannot restart the hover delay, and the view takes no clicks from the control
/// it covers.
struct NativeOrbitHoverHelp: NSViewRepresentable {
    let text: String

    final class Anchor: NSView {
        override func hitTest(_: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context _: Context) -> Anchor {
        let view = Anchor()
        view.toolTip = self.text
        return view
    }

    func updateNSView(_ view: Anchor, context _: Context) {
        if view.toolTip != self.text { view.toolTip = self.text }
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
