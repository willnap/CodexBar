import AppKit
import CodexBarCore
import SwiftUI

@MainActor
struct NativeCombinedAccountSource {
    let provider: UsageProvider
    let state: NativeOrbitPopupState
    var activate: (String) -> Void = { _ in }
    var lightAction: (String, NativeOrbitWarningLight.Action) -> Void = { _, _ in }
    var refresh: () -> Void = {}
    var settings: () -> Void = {}
    /// Holds the service's background changes while the pages move, and lands them once they settle.
    var holdPresentation: (Bool) -> Void = { _ in }
}

/// Pages sit side by side like a service's own account columns. The scroll view owns trackpad momentum and
/// snapping to a column; gestures, keyboard, VoiceOver and the symbol control resolve the same stable account identity.
struct NativeCombinedPopupView: View {
    static let indicatorHeight: CGFloat = 36
    static let pageWidth: CGFloat = 240
    static let pageHeight = NativeOrbitPopupView.contentHeight(showsFooter: true) - NativeOrbitToolbar.height
    /// A page and the divider after it.
    static let pitch = Self.pageWidth + 1
    /// Every page runs down behind the floating toolbar, so its area and tint fill the whole popup. No page control
    /// sits above the pages: the columns themselves show where the strip is, and swipes, arrow keys and VoiceOver
    /// move through it.
    static let stripHeight = Self.pageHeight + NativeOrbitToolbar.height
    /// The narrowest a person can make the popup: one whole page.
    static let minimumWidth = Self.pageWidth

    /// Up to three pages show in full. More show two and a half, so the cut-off column says there is more to scroll.
    static func visibleColumns(pageCount: Int) -> Double {
        pageCount <= 3 ? Double(max(1, pageCount)) : 2.5
    }

    /// The pages wholly inside a viewport scrolled `leading` points from the start.
    static func wholeColumns(leading: CGFloat, width: CGFloat) -> ClosedRange<Int> {
        let start = max(0, leading)
        let first = Int(((start - 0.5) / Self.pitch).rounded(.up))
        let last = Int(((start + width + 0.5 - Self.pageWidth) / Self.pitch).rounded(.down))
        return max(0, first)...max(0, first, last)
    }

    /// Includes the partial columns at either edge, so their charts are current throughout a swipe.
    static func intersectingColumns(leading: CGFloat, width: CGFloat) -> ClosedRange<Int> {
        let start = max(0, leading)
        let first = max(0, Int((start / Self.pitch).rounded(.down)))
        let last = Int(((start + max(0, width) - 0.5) / Self.pitch).rounded(.down))
        return first...max(first, last)
    }

    private struct Viewport: Equatable {
        let whole: ClosedRange<Int>
        let intersecting: ClosedRange<Int>
    }

    /// How much of each page is in the window, in twentieths so a swipe updates the marks only as that changes.
    static func visibility(leading: CGFloat, width: CGFloat, count: Int) -> [Double] {
        (0..<max(0, count)).map { index in
            let start = CGFloat(index) * Self.pitch
            let shown = min(start + Self.pageWidth, leading + width) - max(start, leading)
            return (Double(min(1, max(0, shown / Self.pageWidth))) * 20).rounded() / 20
        }
    }

    static func providersInView(
        _ pages: [NativeCombinedAccounts.Page],
        columns: ClosedRange<Int>) -> Set<UsageProvider>
    {
        Set(pages.enumerated().compactMap { columns.contains($0.offset + 1) ? $0.element.provider : nil })
    }

    static func contentSize(pageCount: Int, maximumWidth: CGFloat = .infinity, preferredWidth: CGFloat? = nil)
        -> NSSize
    {
        let natural = CGFloat(Self.visibleColumns(pageCount: pageCount)) * Self.pitch - 1
        let width: CGFloat = if let preferredWidth {
            Self.clampedWidth(preferredWidth, pageCount: pageCount, maximumWidth: maximumWidth)
        } else {
            min(natural.rounded(), maximumWidth)
        }
        return NSSize(width: width, height: Self.stripHeight)
    }

    /// A chosen width stays between one page and every page side by side, and within the screen.
    static func clampedWidth(_ width: CGFloat, pageCount: Int, maximumWidth: CGFloat = .infinity) -> CGFloat {
        let widest = max(Self.minimumWidth, CGFloat(max(1, pageCount)) * Self.pitch - 1)
        return max(Self.minimumWidth, min(width.rounded(), widest, max(Self.minimumWidth, maximumWidth)))
    }

    /// The columns a toolbar of this width spans, for its compact or full labels.
    static func layoutColumns(width: CGFloat) -> Int {
        max(1, Int((width / self.pitch).rounded(.up)))
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    let sources: [NativeCombinedAccountSource]
    let toolbar: NativeOrbitPopupState
    let showing: NativeCombinedShowing
    /// Fixture renders only: the same pages laid side by side without the scroll view, which offscreen
    /// rendering cannot draw.
    var rendersStaticStrip = false
    @State private var navigation: NativePageControlNavigation
    @State private var scrollID: String?
    /// Pages whose content is built; the rest hold their place and tint. An opening builds and updates only the
    /// pages on screen, the others follow once the popup has appeared, and built pages stay while it is open, so
    /// scrolling never builds a page.
    @State private var livePages: Set<String>
    @State private var renderedColumns: ClosedRange<Int>
    @State private var modelMemo = NativeCombinedAccountsMemo()

    private var selection: String {
        self.navigation.selectionID
    }

    private var navigationRequest: NativePageControlNavigation.Request? {
        self.navigation.request
    }

    init(sources: [NativeCombinedAccountSource], toolbar: NativeOrbitPopupState, showing: NativeCombinedShowing) {
        self.sources = sources
        self.toolbar = toolbar
        self.showing = showing
        self._navigation = State(initialValue: NativePageControlNavigation(selectionID: showing.openingID))
        self._scrollID = State(initialValue: showing.openingID)
        let ids = [NativeCombinedAccounts.overviewID] + showing.pageOrder
        self._livePages = State(initialValue: Self.pagesInView(
            ids, leadingID: showing.openingLeadingID, width: showing.width))
        self._renderedColumns = State(initialValue: Self.openingColumns(
            ids, leadingID: showing.openingLeadingID, width: showing.width))
    }

    /// The pages on screen with `leadingID` at the leading edge; the scroll view stops at the last page. The overview
    /// always stays built, so its chart keeps what it drew instead of rebuilding from nothing at each opening.
    static func pagesInView(_ ids: [String], leadingID: String, width: CGFloat? = nil) -> Set<String> {
        Set(self.openingColumns(ids, leadingID: leadingID, width: width)
            .compactMap { ids.indices.contains($0) ? ids[$0] : nil })
            .union([NativeCombinedAccounts.overviewID])
    }

    private static func openingColumns(_ ids: [String], leadingID: String, width: CGFloat? = nil) -> ClosedRange<Int> {
        let columns = width.map { Self.layoutColumns(width: $0) }
            ?? Int(Self.visibleColumns(pageCount: ids.count).rounded(.up))
        let index = ids.firstIndex(of: leadingID) ?? 0
        let start = max(0, min(index, ids.count - columns))
        return start...max(start, min(ids.count, start + columns) - 1)
    }

    private var model: NativeCombinedAccounts {
        self.modelMemo.value(
            connections: self.sources.map {
                .init(provider: $0.provider, accounts: $0.state.accounts, hasSavedAccounts: true)
            },
            now: self.toolbar.now,
            preservingOrder: self.showing.pageOrder)
    }

    var body: some View {
        let model = self.model
        let ids = [NativeCombinedAccounts.overviewID] + model.pages.map(\.id)
        self.strip(ids: ids, model: model)
            // The toolbar's glass floats over the pages, whose tints run on underneath it.
                .overlay(alignment: .bottom) {
                    NativeOrbitToolbar(
                        state: self.toolbar,
                        refresh: { for source in self.sources {
                            source.refresh()
                        } },
                        settings: {
                            (self.sources.first { source in
                                model.pages.contains { $0.id == self.selection && $0.provider == source.provider }
                            } ?? self.sources.first)?.settings()
                        },
                        rangeChanged: { self.synchronizeRange($0) })
                }
                .frame(width: self.showing.width, height: Self.stripHeight)
                .onChange(of: self.scrollID) {
                    self.navigation.observe(
                        self.scrollID,
                        validIDs: [NativeCombinedAccounts.overviewID] + model.pages.map(\.id))
                }
                .onChange(of: self.selection, initial: true) { self.showing.leftSelectionID = self.selection }
                .onChange(of: self.toolbar.days, initial: true) {
                    self.synchronizeRange(self.toolbar.days)
                }
                .onChange(of: model.pages.map(\.id)) {
                    let ids = [NativeCombinedAccounts.overviewID] + model.pages.map(\.id)
                    self.navigation.inventoryChanged(
                        validIDs: ids,
                        fallbackID: model.pages.first?.id ?? NativeCombinedAccounts.overviewID)
                    self.synchronizeRange(self.toolbar.days)
                }
                .onChange(of: self.sources.map(\.state.now), initial: true) {
                    self.synchronizeToolbar(model)
                }
                .onChange(of: self.sources.map { $0.state.accounts.map(\.updatedAt) }) {
                    self.synchronizeToolbar(model)
                }
                .onChange(of: self.sources.map(\.state.isRefreshing), initial: true) {
                    self.toolbar.isRefreshing = self.sources.contains { $0.state.isRefreshing }
                }
                .onChange(of: self.sources.map { $0.state.refreshIssue?.detail }, initial: true) {
                    let issues = self.sources.compactMap(\.state.refreshIssue)
                    self.toolbar.refreshIssue = issues.isEmpty ? nil : .init(
                        kind: .failed,
                        detail: issues.map(\.detail).joined(separator: "\n"))
                }
    }

    private func synchronizeRange(_ days: Int) {
        let timing = NativeCombinedRangeTiming.begin()
        defer { NativeCombinedRangeTiming.end("source-range", since: timing) }
        if self.toolbar.inspectionDate != nil { self.toolbar.inspectionDate = nil }
        let providers = Self.providersInView(self.model.pages, columns: self.renderedColumns)
        for source in self.sources {
            source.state.finishStartup()
            if source.state.inspectionDate != nil { source.state.inspectionDate = nil }
            // A provider's shared state also drives its warmed gauges and predictions. Keep hidden providers
            // dormant instead of rebuilding all of those views before the visible charts get their first frame.
            if providers.contains(source.provider), source.state.days != days { source.state.days = days }
        }
    }

    @ViewBuilder
    private func strip(ids: [String], model: NativeCombinedAccounts) -> some View {
        if self.rendersStaticStrip {
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                    self.page(id, model: model)
                    if index < ids.count - 1 {
                        Divider().frame(width: 1, height: 464).padding(.top, 12)
                            .frame(height: Self.stripHeight, alignment: .top)
                            .background(self.columnTint(id, model: model))
                    }
                }
            }
            .frame(width: self.showing.width, height: Self.stripHeight, alignment: .leading)
            .clipped()
        } else {
            self.scrollingStrip(ids: ids, model: model)
        }
    }

    private func pageRows(ids: [String], model: NativeCombinedAccounts) -> some View {
        ForEach(Array(ids.enumerated()), id: \.element) { index, id in
            HStack(alignment: .top, spacing: 0) {
                if self.livePages.contains(id) {
                    self.page(id, model: model)
                        .environment(\.nativeOrbitPlotIsVisible, self.renderedColumns.contains(index))
                        .onAppear { NativeCombinedScrollProbe.shared?.pageAppeared() }
                } else {
                    self.placeholder(id, model: model)
                }
                if index < ids.count - 1 {
                    Divider().frame(width: 1, height: 464).padding(.top, 12)
                        .frame(height: Self.stripHeight, alignment: .top)
                        .background(self.columnTint(id, model: model))
                }
            }
            .id(id)
        }
    }

    /// Once the popup has appeared, the pages off screen are built one at a time, a frame apart, nearest first.
    private func buildRemainingPages(_ ids: [String]) async {
        guard self.showing.shownGeneration > 0 else { return }
        let closed = self.showing.closedGeneration
        let selected = ids.firstIndex(of: self.selection) ?? 0
        for id in ids.enumerated().sorted(by: { abs($0.offset - selected) < abs($1.offset - selected) }).map(\.element)
            where !self.livePages.contains(id)
        {
            try? await Task.sleep(for: .milliseconds(20))
            // A popup closed meanwhile keeps only its opening pages.
            guard !Task.isCancelled, self.showing.closedGeneration == closed else { return }
            self.livePages.insert(id)
        }
    }

    private func scrollingStrip(ids: [String], model: NativeCombinedAccounts) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 0) { self.pageRows(ids: ids, model: model) }
                    .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned)
            .onScrollGeometryChange(for: Viewport.self) { geometry in
                let leading = self.layoutDirection == .rightToLeft
                    ? geometry.contentSize.width - geometry.visibleRect.maxX : geometry.visibleRect.minX
                return Viewport(
                    whole: Self.wholeColumns(leading: leading, width: geometry.visibleRect.width),
                    intersecting: Self.intersectingColumns(leading: leading, width: geometry.visibleRect.width))
            } action: { _, viewport in
                if ids.indices.contains(viewport.whole.lowerBound) {
                    self.showing.leftLeadingID = ids[viewport.whole.lowerBound]
                }
                if self.renderedColumns != viewport.intersecting {
                    var transaction = Transaction(animation: nil)
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        self.renderedColumns = viewport.intersecting
                        self.synchronizeRange(self.toolbar.days)
                    }
                }
                let columns = viewport.whole
                // The selection holds while wholly in view; otherwise the nearest whole page takes over.
                let selected = ids.firstIndex(of: self.selection) ?? columns.lowerBound
                let index = min(max(selected, columns.lowerBound), columns.upperBound)
                if ids.indices.contains(index) { self.scrollID = ids[index] }
            }
            .onChange(of: self.navigationRequest) {
                guard let request = self.navigationRequest else { return }
                withAnimation(self.reduceMotion || request.interaction == .continuous
                    ? nil : .easeInOut(duration: 0.25))
                {
                    proxy.scrollTo(request.id, anchor: .leading)
                }
            }
            .onScrollPhaseChange { old, phase in
                if phase.isScrolling != old.isScrolling {
                    // Swiping before every page is built: build the rest now rather than slide in empty pages.
                    if phase.isScrolling, self.livePages.count < ids.count { self.livePages = Set(ids) }
                    for source in self.sources {
                        source.holdPresentation(phase.isScrolling)
                        source.state.isScrolling = phase.isScrolling
                    }
                    self.toolbar.isScrolling = phase.isScrolling
                    NativeCombinedScrollProbe.shared?.scrolling(phase.isScrolling)
                }
                if phase == .interacting {
                    self.navigation.interrupt(at: self.scrollID, validIDs: ids)
                } else if phase == .idle {
                    self.navigation.settle(at: self.scrollID, validIDs: ids)
                }
            }
        }
        .frame(width: self.showing.width, height: Self.stripHeight)
        .accessibilityLabel(L("Accounts"))
        .accessibilityValue(self.selectionLabel(model))
        .accessibilityAdjustableAction { direction in
            self.move(direction == .increment ? 1 : -1, model: model)
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) {
            self.move(self.layoutDirection == .rightToLeft ? 1 : -1, model: model)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            self.move(self.layoutDirection == .rightToLeft ? -1 : 1, model: model)
            return .handled
        }
        .onChange(of: self.showing.generation, initial: true) {
            let leading = self.showing.openingLeadingID
            self.renderedColumns = Self.openingColumns(ids, leadingID: leading, width: self.showing.width)
            self.synchronizeRange(self.toolbar.days)
            self.livePages.formUnion(Self.pagesInView(ids, leadingID: leading, width: self.showing.width))
            self.clearInspection()
            self.navigation.resume(selectionID: self.showing.openingID, leadingID: leading)
        }
        .task(id: self.showing.shownGeneration) { await self.buildRemainingPages(ids) }
        .onChange(of: self.showing.closedGeneration) {
            // The next opening most likely resumes here, so only these pages stay built.
            self.livePages = Self.pagesInView(
                ids,
                leadingID: self.showing.leftLeadingID ?? self.showing.openingLeadingID,
                width: self.showing.width)
        }
    }

    /// Account pages carry a hint of their service's colour, the active one of several a little more, so different
    /// services read as distinct areas side by side.
    private func page(_ id: String, model: NativeCombinedAccounts) -> AnyView {
        if id == NativeCombinedAccounts.overviewID {
            return AnyView(NativeCombinedOverviewView(model: model, sources: self.sources, state: self.toolbar)
                .frame(width: Self.pageWidth, height: Self.stripHeight, alignment: .top))
        }
        if let page = model.pages.first(where: { $0.id == id }),
           let source = self.sources.first(where: { $0.provider == page.provider })
        {
            let active = page.account.isActive && source.state.accounts.count > 1
            return AnyView(NativeOrbitPopupView(
                state: source.state,
                activate: source.activate,
                signIn: nil,
                lightAction: source.lightAction,
                displayedAccountID: page.account.id,
                showsToolbar: false,
                drawsColumnBackground: false)
                .frame(width: Self.pageWidth, height: Self.stripHeight, alignment: .top)
                .background(active ? NativeOrbitPopupView.activeColumnTint(source.state.accent)
                    : source.state.accent.opacity(0.03)))
        }
        return AnyView(Color.clear.frame(width: Self.pageWidth, height: Self.stripHeight))
    }

    private func columnTint(_ id: String, model: NativeCombinedAccounts) -> Color {
        guard let page = model.pages.first(where: { $0.id == id }),
              let source = self.sources.first(where: { $0.provider == page.provider }) else { return .clear }
        return page.account.isActive && source.state.accounts.count > 1
            ? NativeOrbitPopupView.activeColumnTint(source.state.accent) : source.state.accent.opacity(0.03)
    }

    /// A page not built yet keeps its place and its service's tint.
    private func placeholder(_ id: String, model: NativeCombinedAccounts) -> some View {
        self.columnTint(id, model: model).frame(width: Self.pageWidth, height: Self.stripHeight)
    }

    private func synchronizeToolbar(_ model: NativeCombinedAccounts) {
        self.toolbar.accounts = model.pages.map(\.account)
        self.toolbar.now = max(Date(), self.sources.map(\.state.now).max() ?? self.toolbar.now)
    }

    private func selectionLabel(_ model: NativeCombinedAccounts) -> String {
        model.pages.first { $0.id == self.selection }?.title ?? L("All accounts")
    }

    private func select(_ id: String, interaction: NativePageControlInteraction = .discrete) {
        self.clearInspection()
        self.navigation.select(id, interaction: interaction)
    }

    private func clearInspection() {
        self.toolbar.inspectionDate = nil
        for source in self.sources {
            source.state.inspectionDate = nil
        }
    }

    private func move(_ delta: Int, model: NativeCombinedAccounts) {
        let ids = [NativeCombinedAccounts.overviewID] + model.pages.map(\.id)
        guard let index = ids.firstIndex(of: self.selection) else { return }
        self.select(ids[min(ids.count - 1, max(0, index + delta))])
    }
}

/// The same dial and chart instruments as account pages, comparing recorded money or tokens.
private struct NativeCombinedOverviewView: View {
    let model: NativeCombinedAccounts
    let sources: [NativeCombinedAccountSource]
    let state: NativeOrbitPopupState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var metric = NativeCombinedMetric.tokens

    private struct Account {
        let page: NativeCombinedAccounts.Page
        let accent: Color
        let name: String
        let badge: String?
    }

    private var accounts: [Account] {
        self.model.pages.compactMap { page in
            guard let source = self.sources.first(where: { $0.provider == page.provider }) else { return nil }
            let several = source.state.accounts.count > 1
            let service = ProviderDescriptorRegistry.descriptor(for: page.provider).metadata.displayName
            return Account(
                page: page,
                accent: several && !page.account.isActive
                    ? source.state.accent.mix(with: .gray, by: 0.12) : source.state.accent,
                name: several ? "\(service) · \(page.account.label)" : service,
                badge: several ? source.state.badges[page.account.id] : nil)
        }
    }

    /// Currency is fixed to the current range while scrubbing, so a missing past receipt never changes units.
    private var moneyCurrency: String? {
        let costs = self.model.summary(days: self.state.days, now: self.state.now).costs
        return costs.count == 1 ? costs.keys.first : nil
    }

    var body: some View {
        let accounts = self.accounts
        VStack(spacing: 0) {
            ZStack {
                NativeCombinedShareRing(segments: self.segments(accounts))
                self.corners
            }
            .frame(width: 224, height: 240)
            Rectangle().fill(Color(nsColor: .separatorColor).opacity(0.65)).frame(width: 166, height: 0.5)
                .overlay {
                    if let date = self.state.inspectionDate {
                        NativeOrbitInspectionPill(time: NativeOrbitPopupView.inspectedInstant(
                            date,
                            now: self.state.now))
                    }
                }
                .zIndex(1)
            NativeCombinedTokenChart(
                model: self.model,
                state: self.state,
                metric: self.metric,
                accents: Dictionary(uniqueKeysWithValues: accounts.map { ($0.page.id, $0.accent) }),
                labels: Dictionary(uniqueKeysWithValues: accounts.map { ($0.page.id, $0.name) }))
        }
        .padding(.horizontal, 8)
        .animation(self.reduceMotion ? nil : NativeCombinedMetricTransition.animation, value: self.metric)
        .animation(self.reduceMotion ? nil : NativeCombinedMetricTransition.animation, value: self.state.days)
        .onChange(of: self.moneyCurrency) { _, currency in
            if case .money = self.metric {
                self.metric = currency.map { .money(currency: $0) } ?? .tokens
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("All accounts"))
    }

    private func segments(_ accounts: [Account]) -> [NativeCombinedShareRing.Segment] {
        let shares = self.model.shares(
            metric: self.metric, days: self.state.days, now: self.state.inspectionDate ?? self.state.now)
        let total = shares.map(\.value).reduce(0, +)
        let values = Dictionary(uniqueKeysWithValues: shares.map { ($0.id, $0.value) })
        // Provider/account order stays fixed across units. Interpolated adjacent boundaries then remain a
        // partition of the ring, and a missing account can collapse smoothly to zero without losing its identity.
        return accounts.map { account in
            let amount = values[account.page.id] ?? 0
            let fraction = total > 0 ? amount / total : 0
            return .init(
                id: account.page.id,
                fraction: fraction,
                accent: account.accent,
                productID: account.page.account.gauge.productID,
                companyID: UsageProduct.companyID(account.page.account.gauge.provider),
                accountSymbol: account.badge,
                help: "\(account.name)\n\(self.metric.formatted(amount)) · "
                    + fraction.formatted(.percent.precision(.fractionLength(0))))
        }
    }

    private var corners: some View {
        let summary = self.model.summary(days: self.state.days, now: self.state.inspectionDate ?? self.state.now)
        let currency = self.moneyCurrency
        let moneyMetric = NativeCombinedMetric.money(currency: currency ?? "USD")
        let cost = currency.flatMap { summary.costs[$0] }
        let money = cost.map { moneyMetric.formatted($0) } ?? "—"
        let tokens = summary.tokens.map(NativeOrbitInstruments.compact) ?? "—"
        let usesTokens = self.metric == .tokens
        return ZStack {
            NativeCombinedMetricSelectionInk(
                degrees: usesTokens ? -45 : -135,
                length: NativeCombinedMetricButton.textWidth(usesTokens ? tokens : money, monospaced: usesTokens) + 20,
                money: money,
                tokens: tokens,
                moneyValue: cost,
                tokenValue: summary.tokens.map(Double.init))
            NativeCombinedMetricButton(
                value: money,
                corner: .topLeading,
                selected: self.metric == moneyMetric,
                help: currency == nil ? "Spend unavailable in a single currency" : "Show spend · "
                    + NativeOrbitTooltip.range(days: self.state.days))
            { self.metric = moneyMetric }
                .disabled(currency == nil)
            NativeCombinedMetricButton(
                value: tokens,
                corner: .topTrailing,
                selected: self.metric == .tokens,
                help: "Show tokens · " + NativeOrbitTooltip.range(days: self.state.days))
            { self.metric = .tokens }
        }
        .frame(width: 224, height: 224)
    }
}

/// A true round-ended pill following the same outer arc as the selected readout.
private struct NativeCombinedMetricButton: View {
    let value: String
    let corner: NativeOrbitComplication.Corner
    let selected: Bool
    let help: String
    let select: () -> Void

    var body: some View {
        Button(action: self.select) {
            Color.clear
                .frame(width: 224, height: 224)
                .contentShape(NativeOrbitCornerRegion(corner: self.corner))
        }
        .buttonStyle(.plain)
        .help(self.help)
        .accessibilityIdentifier(self.corner == .topLeading ? "combined-metric:money" : "combined-metric:tokens")
        .accessibilityLabel(self.help)
        .accessibilityValue(self.value)
        .accessibilityAddTraits(self.selected ? .isSelected : [])
    }

    static func textWidth(_ value: String, monospaced: Bool) -> CGFloat {
        let font = NativeOrbitArcText.font(monospaced: monospaced, size: 16)
        return min(88, (value as NSString).size(withAttributes: [.font: font]).width)
    }
}
