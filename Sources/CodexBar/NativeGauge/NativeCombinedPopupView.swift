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
}

/// Pages sit side by side like a service's own account columns. The scroll view owns trackpad momentum and
/// snapping to a column; gestures, keyboard, VoiceOver and the symbol control resolve the same stable account identity.
struct NativeCombinedPopupView: View {
    static let indicatorHeight: CGFloat = 36
    static let pageWidth: CGFloat = 240
    static let pageHeight = NativeOrbitPopupView.contentHeight(showsFooter: true) - NativeOrbitToolbar.height
    /// A page and the divider after it.
    static let pitch = Self.pageWidth + 1
    /// How far the page control rises into the empty foot of each account's footer.
    static let controlTuck: CGFloat = 6
    /// Every page runs down behind the page control, so its area and tint reach the toolbar.
    static let stripHeight = Self.pageHeight + Self.indicatorHeight - Self.controlTuck

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

    static func contentSize(pageCount: Int, maximumWidth: CGFloat = .infinity) -> NSSize {
        let width = (Self.visibleColumns(pageCount: pageCount) * Self.pitch - 1).rounded()
        return NSSize(width: min(width, maximumWidth), height: Self.stripHeight + NativeOrbitToolbar.height)
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
    }

    private var model: NativeCombinedAccounts {
        NativeCombinedAccounts(
            connections: self.sources.map {
                .init(provider: $0.provider, accounts: $0.state.accounts, hasSavedAccounts: true)
            },
            now: self.toolbar.now,
            preservingOrder: self.showing.pageOrder)
    }

    private var badges: [String: String] {
        var result: [String: String] = [:]
        for source in self.sources {
            for (id, symbol) in source.state.badges {
                result[NativeCombinedAccounts.Page.id(provider: source.provider, accountID: id)] = symbol
            }
        }
        return result
    }

    var body: some View {
        let model = self.model
        VStack(spacing: 0) {
            let ids = [NativeCombinedAccounts.overviewID] + model.pages.map(\.id)
            ZStack(alignment: .bottom) {
                self.strip(ids: ids, model: model)
                self.indicators(model)
                    .frame(width: Self.pageWidth)
            }
            NativeOrbitToolbar(
                state: self.toolbar,
                refresh: { for source in self.sources {
                    source.refresh()
                } },
                settings: {
                    (self.sources.first { source in
                        model.pages.contains { $0.id == self.selection && $0.provider == source.provider }
                    } ?? self.sources.first)?.settings()
                })
        }
        .frame(width: self.showing.width)
        .onChange(of: self.scrollID) {
            self.navigation.observe(
                self.scrollID,
                validIDs: [NativeCombinedAccounts.overviewID] + model.pages.map(\.id))
        }
        .onChange(of: self.toolbar.days, initial: true) {
            for source in self.sources {
                source.state.finishStartup()
                source.state.days = self.toolbar.days
                source.state.inspectionDate = nil
            }
        }
        .onChange(of: model.pages.map(\.id)) {
            let ids = [NativeCombinedAccounts.overviewID] + model.pages.map(\.id)
            self.navigation.inventoryChanged(
                validIDs: ids,
                fallbackID: model.pages.first?.id ?? NativeCombinedAccounts.overviewID)
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

    @ViewBuilder
    private func strip(ids: [String], model: NativeCombinedAccounts) -> some View {
        if self.rendersStaticStrip {
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                    self.page(id, model: model)
                    if index < ids.count - 1 {
                        Divider().frame(height: 464).padding(.top, 12)
                    }
                }
            }
            .frame(width: self.showing.width, height: Self.stripHeight, alignment: .leading)
            .clipped()
        } else {
            self.scrollingStrip(ids: ids, model: model)
        }
    }

    private func scrollingStrip(ids: [String], model: NativeCombinedAccounts) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 0) {
                    ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                        HStack(alignment: .top, spacing: 0) {
                            self.page(id, model: model)
                            if index < ids.count - 1 {
                                Divider().frame(height: 464).padding(.top, 12)
                            }
                        }
                        .id(id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned)
            .onScrollGeometryChange(for: ClosedRange<Int>.self) { geometry in
                let leading = self.layoutDirection == .rightToLeft
                    ? geometry.contentSize.width - geometry.visibleRect.maxX : geometry.visibleRect.minX
                return Self.wholeColumns(leading: leading, width: geometry.visibleRect.width)
            } action: { _, columns in
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
            .onScrollPhaseChange { _, phase in
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
            self.select(self.showing.openingID, interaction: .continuous)
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

    private func synchronizeToolbar(_ model: NativeCombinedAccounts) {
        self.toolbar.accounts = model.pages.map(\.account)
        self.toolbar.now = max(Date(), self.sources.map(\.state.now).max() ?? self.toolbar.now)
    }

    private func indicators(_ model: NativeCombinedAccounts) -> some View {
        NativeCombinedPageIndicators(
            indicators: model.indicators(selectedID: self.selection, badges: self.badges),
            pages: [.init(id: NativeCombinedAccounts.overviewID, label: L("All accounts"))] + model.pages.map {
                .init(
                    id: $0.id,
                    label: ProviderDescriptorRegistry.descriptor(for: $0.provider).metadata.displayName
                        + ", " + $0.account.label)
            },
            selectionID: self.selection,
            select: self.select)
    }

    private func selectionLabel(_ model: NativeCombinedAccounts) -> String {
        model.pages.first { $0.id == self.selection }.map {
            ProviderDescriptorRegistry.descriptor(for: $0.provider).metadata.displayName + ", " + $0.account.label
        } ?? L("All accounts")
    }

    private func select(_ id: String, interaction: NativePageControlInteraction = .discrete) {
        for source in self.sources {
            source.state.inspectionDate = nil
        }
        self.navigation.select(id, interaction: interaction)
    }

    private func move(_ delta: Int, model: NativeCombinedAccounts) {
        let ids = [NativeCombinedAccounts.overviewID] + model.pages.map(\.id)
        guard let index = ids.firstIndex(of: self.selection) else { return }
        self.select(ids[min(ids.count - 1, max(0, index + delta))])
    }
}

/// Laid out like an account page: the dial, then the history chart. The dial is each account's share of the range's
/// tokens; the chart draws each account's main allowance through time; the colours are the accounts' own.
private struct NativeCombinedOverviewView: View {
    let model: NativeCombinedAccounts
    let sources: [NativeCombinedAccountSource]
    let state: NativeOrbitPopupState

    private struct Account {
        let page: NativeCombinedAccounts.Page
        let accent: Color
        let name: String
    }

    /// The colour an account's page, share and lane share: its service's accent, greyed a little when another login
    /// of that service is the active one, as on the service's own columns.
    private var accounts: [Account] {
        self.model.pages.compactMap { page in
            guard let source = self.sources.first(where: { $0.provider == page.provider }) else { return nil }
            let several = source.state.accounts.count > 1
            let service = ProviderDescriptorRegistry.descriptor(for: page.provider).metadata.displayName
            return Account(
                page: page,
                accent: several && !page.account.isActive
                    ? source.state.accent.mix(with: .gray, by: 0.12) : source.state.accent,
                name: several ? "\(service) · \(page.account.label)" : service)
        }
    }

    var body: some View {
        let accounts = self.accounts
        VStack(spacing: 0) {
            ZStack {
                NativeCombinedShareRing(segments: self.segments(accounts))
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.secondary)
                self.corners
            }
            .frame(width: 224, height: 240)
            Rectangle().fill(Color(nsColor: .separatorColor).opacity(0.65)).frame(width: 166, height: 0.5)
            self.chart(accounts)
        }
        .padding(.horizontal, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("All accounts"))
    }

    private func segments(_ accounts: [Account]) -> [NativeCombinedShareRing.Segment] {
        let shares = self.model.tokenShares(days: self.state.days, now: self.state.now)
        let total = Double(shares.map(\.tokens).reduce(0, +))
        guard total > 0 else { return [] }
        return shares.compactMap { share in
            guard let account = accounts.first(where: { $0.page.id == share.page.id }) else { return nil }
            let fraction = Double(share.tokens) / total
            return .init(
                id: share.page.id,
                fraction: fraction,
                accent: account.accent,
                productID: share.page.account.gauge.productID,
                help: "\(account.name): \(fraction.formatted(.percent.precision(.fractionLength(0)))) of tokens "
                    + NativeOrbitTooltip.during(days: self.state.days))
        }
    }

    /// The account corners that add up across accounts: spend and tokens. Banked resets and extra usage belong to
    /// one account each, so the bottom corners stay empty.
    private var corners: some View {
        let summary = self.model.summary(days: self.state.days, now: self.state.now)
        return NativeOrbitInstrumentSurface {
            ZStack {
                if summary.costs.count == 1, let currency = summary.costs.keys.first,
                   let cost = summary.costs[currency]
                {
                    let money = NativeOrbitInstruments.money(cost, currency: currency)
                    NativeOrbitComplication(
                        value: money,
                        corner: .topLeading,
                        help: (summary.isPartial ? "At least " : "") + "\(money) "
                            + NativeOrbitTooltip.during(days: self.state.days),
                        numericValue: cost)
                }
                if let tokens = summary.tokens {
                    NativeOrbitComplication(
                        value: NativeOrbitInstruments.compact(tokens),
                        corner: .topTrailing,
                        help: (summary.isPartial ? "At least " : "") + "\(tokens.formatted()) tokens "
                            + NativeOrbitTooltip.during(days: self.state.days),
                        monospaced: true,
                        numericValue: Double(tokens))
                }
            }
        }
        .frame(width: 224, height: 224)
    }

    /// Each account's longest quota lane from its own prepared chart, drawn together in the account chart.
    private func chart(_ accounts: [Account]) -> some View {
        var lanes: [NativeOrbitHistoryWidget.Lane] = []
        var accents: [String: Color] = [:]
        var labels: [String: String] = [:]
        for (index, account) in accounts.enumerated() {
            guard let source = self.sources.first(where: { $0.provider == account.page.provider }),
                  let lane = source.state.renderLanes(for: account.page.account)
                      .max(by: { $0.history.windowMinutes < $1.history.windowMinutes })
            else { continue }
            let name = PlanUtilizationSeriesName(rawValue: "nativeQuota:combined-\(index)")
            lanes.append(.init(
                history: lane.history.renamed(name),
                samples: lane.samples,
                resetEvents: [],
                start: lane.start,
                now: lane.now,
                styleIndex: 0))
            accents[name.rawValue] = account.accent
            labels[name.rawValue] = account.name
        }
        return NativeOrbitHistoryWidget(
            histories: [],
            now: self.state.now,
            days: self.state.days,
            laneAccents: accents,
            quotaLabels: labels,
            preparedLanes: lanes,
            preparedObservationDates: [],
            selectedDate: self.state.inspectionDate,
            onSelect: { [state = self.state] in state.inspect($0, source: "hover") },
            showsEmptyState: true,
            dataDays: NativeOrbitPopupState.dataDays)
    }
}
