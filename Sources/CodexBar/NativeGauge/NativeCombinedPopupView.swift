import AppKit
import Charts
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

/// AppKit owns the horizontal page transitions. Gestures, keyboard, VoiceOver and the symbol control
/// resolve the same stable account identity.
struct NativeCombinedPopupView: View {
    static let indicatorHeight: CGFloat = 36
    static let pageHeight = NativeOrbitPopupView.contentHeight(showsFooter: true) - NativeOrbitToolbar.height
    static let contentSize = NSSize(
        width: 240,
        height: Self.pageHeight + Self.indicatorHeight + NativeOrbitToolbar.height)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    let sources: [NativeCombinedAccountSource]
    let toolbar: NativeOrbitPopupState
    let pageOrder: [String]
    private let openingID: String
    @State private var navigation: NativePageControlNavigation
    @State private var scrollID: String?

    private var selection: String {
        self.navigation.selectionID
    }

    private var navigationRequest: NativePageControlNavigation.Request? {
        self.navigation.request
    }

    init(sources: [NativeCombinedAccountSource], toolbar: NativeOrbitPopupState, initialID: String? = nil) {
        self.sources = sources
        self.toolbar = toolbar
        let model = NativeCombinedAccounts(connections: sources.map {
            .init(provider: $0.provider, accounts: $0.state.accounts, hasSavedAccounts: true)
        }, now: toolbar.now)
        self.pageOrder = model.pages.map(\.id)
        let selection = initialID ?? model.pages.first?.id ?? NativeCombinedAccounts.overviewID
        self.openingID = selection
        self._navigation = State(initialValue: NativePageControlNavigation(selectionID: selection))
        self._scrollID = State(initialValue: selection)
    }

    private var model: NativeCombinedAccounts {
        NativeCombinedAccounts(
            connections: self.sources.map {
                .init(provider: $0.provider, accounts: $0.state.accounts, hasSavedAccounts: true)
            },
            now: self.toolbar.now,
            preservingOrder: self.pageOrder)
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
            NativeAccountPager(
                ids: self.layoutDirection == .rightToLeft ? Array(ids.reversed()) : ids,
                selectedID: self.selection,
                request: self.navigationRequest,
                revision: self.sources.map(\.state.now),
                reduceMotion: self.reduceMotion,
                layoutDirection: self.layoutDirection,
                content: { id in
                    AnyView(self.page(id, model: model).environment(\.layoutDirection, self.layoutDirection))
                },
                interactionBegan: { id in self.navigation.interrupt(at: id, validIDs: ids) },
                visible: { id in
                    self.scrollID = id
                    self.navigation.observe(id, validIDs: ids)
                    self.navigation.settle(at: id, validIDs: ids)
                })
                .frame(width: 240, height: Self.pageHeight)
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
                .onAppear { self.select(self.openingID, interaction: .continuous) }
            self.indicators(model)
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
        .frame(width: 240)
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

    private func page(_ id: String, model: NativeCombinedAccounts) -> AnyView {
        if id == NativeCombinedAccounts.overviewID {
            return AnyView(NativeCombinedOverviewView(model: model, state: self.toolbar)
                .frame(width: 240, height: Self.pageHeight))
        }
        if let page = model.pages.first(where: { $0.id == id }),
           let source = self.sources.first(where: { $0.provider == page.provider })
        {
            return AnyView(NativeOrbitPopupView(
                state: source.state,
                activate: source.activate,
                signIn: nil,
                lightAction: source.lightAction,
                displayedAccountID: page.account.id,
                showsToolbar: false)
                .frame(width: 240, height: Self.pageHeight, alignment: .top))
        }
        return AnyView(Color.clear.frame(width: 240, height: Self.pageHeight))
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

private struct NativeCombinedOverviewView: View {
    let model: NativeCombinedAccounts
    let state: NativeOrbitPopupState

    private var averageRemaining: Double? {
        let values = self.model.pages.compactMap { page in
            page.account.gauge.resolvedWindows.compactMap(\.usedFraction).max().map { 1 - $0 }
        }
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    var body: some View {
        let summary = self.model.summary(days: self.state.days, now: self.state.now)
        VStack(spacing: 0) {
            ZStack {
                NativeOrbitSymbol(
                    remaining: self.averageRemaining,
                    countdown: nil,
                    segments: 1,
                    lane: 0,
                    size: 216,
                    accent: self.state.accent)
                VStack(spacing: 5) {
                    Image(systemName: "square.stack.3d.up").font(.system(size: 26, weight: .light))
                    Text(L("All accounts")).font(.system(size: 13, weight: .medium))
                    Text(self.averageRemaining.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "—")
                        .font(.system(size: 24, weight: .light, design: .rounded)).monospacedDigit()
                    Text(L("Mean quota left")).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                NativeOrbitComplication(
                    value: summary.tokens.map { $0.formatted(.number.notation(.compactName)) } ?? "—",
                    corner: .topTrailing,
                    help: L("Known tokens across accounts"),
                    monospaced: true)
                NativeOrbitComplication(
                    value: self.costText(summary),
                    corner: .topLeading,
                    help: summary.costs.keys.sorted().map { currency in
                        (summary.costs[currency] ?? 0).formatted(.currency(code: currency))
                    }.joined(separator: " · "),
                    monospaced: true)
                NativeOrbitComplication(
                    value: "\(self.model.pages.count)",
                    corner: .bottomLeading,
                    help: L("Connected accounts"),
                    monospaced: true)
                NativeOrbitComplication(
                    value: summary.requests.map { $0.formatted(.number.notation(.compactName)) } ?? "—",
                    corner: .bottomTrailing,
                    help: L("Known requests across accounts"),
                    monospaced: true)
            }
            .frame(width: 224, height: 240)
            .help(L("Average of each account’s most constrained quota. Account limits reset independently."))
            Rectangle().fill(.separator).frame(width: 166, height: 0.5)
            NativeCombinedHistoryView(model: self.model, days: self.state.days, now: self.state.now)
                .frame(width: 224, height: 224)
            Rectangle().fill(.separator).frame(width: 166, height: 0.5)
            Text(summary.isPartial ? L("Known totals · Partial data") : L("All connected accounts"))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(height: 38)
        }
        .padding(.horizontal, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("Combined usage overview"))
    }

    private func costText(_ summary: NativeCombinedAccounts.Summary) -> String {
        guard summary.costs.count == 1, let currency = summary.costs.keys.first,
              let value = summary.costs[currency] else { return summary.costs.isEmpty ? "—" : L("Multi") }
        return value.formatted(.currency(code: currency).precision(.fractionLength(0...2)))
    }
}

private struct NativeCombinedHistoryView: View {
    let model: NativeCombinedAccounts
    let days: Int
    let now: Date

    var body: some View {
        let points = self.model.dailyHistory(days: self.days, now: self.now)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("Tokens")).font(.system(size: 11, weight: .medium))
                Spacer()
                Text(L("%d days", self.days)).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Chart(points) { point in
                if let tokens = point.tokens {
                    BarMark(x: .value("Day", point.date, unit: .day), y: .value("Tokens", tokens))
                        .foregroundStyle(.primary.opacity(0.25)).cornerRadius(3)
                }
            }
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) }
            .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
            .overlay {
                if points.allSatisfy({ $0.tokens == nil }) {
                    Text(L("No token history for this range")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 20)
    }
}
