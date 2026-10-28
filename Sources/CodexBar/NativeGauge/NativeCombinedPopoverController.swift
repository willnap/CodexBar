import AppKit
import CodexBarCore
import SwiftUI

/// Kept between showings like a service's own popup, so opening never rebuilds the pages from scratch.
@MainActor
final class NativeCombinedPopoverController: NSViewController, NSPopoverDelegate {
    let controllers: [NativeServicePopoverController]
    private let toolbar = NativeOrbitPopupState()
    private let showing = NativeCombinedShowing()
    private weak var button: NSStatusBarButton?
    private let didClose: () -> Void

    init(controllers: [NativeServicePopoverController], button: NSStatusBarButton, didClose: @escaping () -> Void) {
        self.controllers = controllers
        self.button = button
        self.didClose = didClose
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    /// Each showing opens on the most recently used account, with the page order and width frozen for that showing.
    func prepareForShowing() {
        for controller in self.controllers {
            controller.beginCombinedPresentation()
        }
        let sources = self.controllers.map { $0.combinedSource() }
        let model = NativeCombinedAccounts(connections: sources.map {
            .init(provider: $0.provider, accounts: $0.state.accounts, hasSavedAccounts: true)
        }, now: Date())
        self.pageCount = model.pages.count + 1
        self.preferredContentSize = NativeCombinedPopupView.contentSize(
            pageCount: self.pageCount,
            maximumWidth: self.maximumWidth,
            preferredWidth: Self.chosenWidth)
        self.toolbar.layoutColumns = NativeCombinedPopupView.layoutColumns(width: self.preferredContentSize.width)
        self.toolbar.accounts = self.controllers.flatMap(\.orbitState.accounts)
        let ids = [NativeCombinedAccounts.overviewID] + model.pages.map(\.id)
        let resumed = self.showing.resumed(validIDs: ids, now: Date())
        self.showing.begin(
            openingID: resumed?.selection ?? model.pages.first?.id ?? NativeCombinedAccounts.overviewID,
            leadingID: resumed?.leading,
            pageOrder: model.pages.map(\.id),
            width: self.preferredContentSize.width)
    }

    // MARK: Width

    /// The width a person chose by dragging an edge, kept across launches.
    static let widthDefaultsKey = "NativeCombinedPopupWidth"
    private var pageCount = 1
    weak var popover: NSPopover?

    private static var chosenWidth: CGFloat? {
        let width = UserDefaults.standard.double(forKey: Self.widthDefaultsKey)
        return width > 0 ? width : nil
    }

    private var maximumWidth: CGFloat {
        (self.button?.window?.screen?.visibleFrame.width ?? 1200) - 40
    }

    private var widthLimits: ClosedRange<CGFloat> {
        NativeCombinedPopupView.minimumWidth...NativeCombinedPopupView.clampedWidth(
            .infinity, pageCount: self.pageCount, maximumWidth: self.maximumWidth)
    }

    /// Follows an edge drag: the popup takes the width, within one page and every page side by side.
    private func resize(to proposed: CGFloat) -> CGFloat {
        let width = NativeCombinedPopupView.clampedWidth(
            proposed, pageCount: self.pageCount, maximumWidth: self.maximumWidth)
        guard width != self.showing.width else { return width }
        self.showing.resize(width)
        self.toolbar.layoutColumns = NativeCombinedPopupView.layoutColumns(width: width)
        self.preferredContentSize = NSSize(width: width, height: NativeCombinedPopupView.stripHeight)
        self.popover?.contentSize = self.preferredContentSize
        return width
    }

    override func loadView() {
        let host = NSHostingView(rootView: NativeCombinedPopupView(
            sources: self.controllers.map { $0.combinedSource() },
            toolbar: self.toolbar,
            showing: self.showing))
        let edges = NativePopoverEdgeResizer(frame: NSRect(origin: .zero, size: self.preferredContentSize))
        edges.host(host)
        edges.width = { [weak self] in self?.showing.width ?? 0 }
        edges.limits = { [weak self] in self?.widthLimits ?? NativeCombinedPopupView.minimumWidth...10000 }
        edges.resize = { [weak self] in self?.resize(to: $0) ?? $0 }
        edges.began = { [weak self] in self?.popover?.animates = false }
        edges.ended = { [weak self] width in
            // A drag follows the pointer directly; the popover's own animation returns for opening and closing.
            self?.popover?.animates = true
            UserDefaults.standard.set(Double(width), forKey: Self.widthDefaultsKey)
        }
        self.view = edges
    }

    func popoverWillShow(_: Notification) {
        self.button?.highlight(true)
    }

    func popoverDidShow(_: Notification) {
        for controller in self.controllers {
            controller.combinedPresentationDidShow()
        }
        self.showing.shown()
    }

    func popoverDidClose(_: Notification) {
        for controller in self.controllers {
            controller.endCombinedPresentation()
        }
        self.button?.highlight(false)
        // Release the pages built off screen now, while nothing is drawn, so the next opening updates only its own.
        self.showing.closed()
        if self.isViewLoaded { self.view.layoutSubtreeIfNeeded() }
        self.didClose()
    }
}

extension StatusItemController {
    /// Native mode decides visibility from cached connection evidence every time it receives an icon update.
    func updateNativeAccountVisibility() {
        let connections = self.store.nativeCombinedConnections()
        let connected = connections.filter(\.isConnected).map(\.provider)
        let combined = NativeCombinedAccounts.shouldCombine(
            connections, always: self.settings.nativeCombinesAllServices)
        if self.nativeCombinedProviders != (combined ? connected : []) {
            self.closeNativeServicePopover()
            self.nativeCombinedProviders = combined ? connected : []
            self.nativeCombinedPopover = nil
        }
        self.attachNativeServiceButtons()
        self.setStatusItemVisiblePreservingPlacement(self.statusItem, combined)
        var visibleNames: Set<String> = combined ? [self.statusItem.autosaveName] : []
        for (id, item) in self.statusItems {
            let visible = !combined && id.firstPartyProvider
                .map { self.isEnabled($0) || self.fallbackProvider == $0 } == true
            self.setStatusItemVisiblePreservingPlacement(item, visible)
            if visible {
                visibleNames.insert(item.autosaveName)
                if let provider = id.firstPartyProvider { self.applyNativeGauge(for: provider) }
            }
        }
        self.expectedVisibleStatusItemAutosaveNames = visibleNames
        let shown = combined ? Array(NativeCombinedAccounts(connections: connections, now: Date())
            .recentAccounts.prefix(2)) : []
        self.drawNativeCombinedGauges(shown)
        guard combined, let button = self.statusItem.button else { return }
        self.statusItem.menu = nil
        button.target = self
        button.action = #selector(self.nativeCombinedClicked(_:))
        button.sendAction(on: [.leftMouseDown, .rightMouseUp])
        button.setAccessibilityIdentifier("CodexBar.CombinedAccounts")
    }

    /// One button holds the full gauges of the one or two most recently used accounts, side by side.
    private func drawNativeCombinedGauges(_ pages: [NativeCombinedAccounts.Page]) {
        for id in Array(self.nativeCombinedGaugeHosts.keys) where !pages.contains(where: { $0.id == id }) {
            self.nativeCombinedGaugeHosts.removeValue(forKey: id)?.removeFromSuperview()
        }
        guard !pages.isEmpty, let button = self.statusItem.button else { return }
        button.image = nil
        button.title = ""
        var x: CGFloat = 1
        var labels = [L("All accounts")]
        for page in pages {
            let host = self.nativeCombinedGaugeHosts[page.id].flatMap { $0.superview === button ? $0 : nil }
                ?? NativeGaugeHostingView(rootView: AnyView(EmptyView()))
            if host.superview !== button { button.addSubview(host) }
            self.nativeCombinedGaugeHosts[page.id] = host
            // Keyed by account, so a gauge keeps its animation state when the two swap places.
            x += host.update(state: page.account.gauge, accountID: page.id, button: button, x: x) + 6
            labels.append([
                self.store.metadata(for: page.provider).displayName,
                page.account.isNamed ? page.account.label : "",
                page.account.gauge.usageSummary(at: .now),
            ].filter { !$0.isEmpty }.joined(separator: ", "))
        }
        self.statusItem.length = x - 6 + 1
        let label = labels.joined(separator: ". ")
        button.toolTip = label
        button.setAccessibilityLabel(label)
    }

    @objc func nativeCombinedClicked(_ sender: NSStatusBarButton) {
        if self.nativeCombinedPopover?.isShown == true {
            self.closeNativeServicePopover()
            return
        }
        self.closeNativeServicePopover()
        let opening = ContinuousClock.now
        let waited = Self.clickWaitMilliseconds()
        guard let provider = self.nativeCombinedProviders.first,
              let (popover, controller) = self.nativeCombinedPopover(button: sender) else { return }
        controller.prepareForShowing()
        popover.contentSize = controller.preferredContentSize
        self.nativeUsagePopover = popover
        self.nativeServiceRoute.toggle(provider)
        self.lastMenuProvider = provider.instanceID
        NSApp.activate()
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        controller.view.window?.makeKey()
        self.nativePopoverOpened(provider: provider, popover: popover)
        let shown = opening.duration(to: .now)
        // The first frame is committed by the time the main actor next runs.
        Task { @MainActor in
            await Task.yield()
            CodexBarLog.logger("native-gauges").info(
                "Combined popup shown",
                metadata: [
                    "width": String(Int(controller.preferredContentSize.width)),
                    "waitedMilliseconds": String(format: "%.1f", waited),
                    "showMilliseconds": String(format: "%.1f", Self.milliseconds(shown)),
                    "drawnMilliseconds": String(format: "%.1f", Self.milliseconds(opening.duration(to: .now))),
                ])
        }
    }

    /// The kept popup, or a new one when its services' popups were replaced.
    private func nativeCombinedPopover(
        button: NSStatusBarButton) -> (NSPopover, NativeCombinedPopoverController)?
    {
        let controllers = self.nativeCombinedProviders.compactMap { provider -> NativeServicePopoverController? in
            guard let button = self.statusItems[provider.instanceID]?.button else { return nil }
            return self.nativePopover(for: provider, button: button)
                .contentViewController as? NativeServicePopoverController
        }
        guard !controllers.isEmpty else { return nil }
        if let existing = self.nativeCombinedPopover,
           let kept = existing.contentViewController as? NativeCombinedPopoverController,
           kept.controllers.elementsEqual(controllers, by: ===)
        {
            return (existing, kept)
        }
        let controller = NativeCombinedPopoverController(controllers: controllers, button: button) { [weak self] in
            self?.nativePopoverRefreshScheduler.cancel()
            self?.nativeServiceRoute.dismiss()
            if NSApp.isActive, !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeKey }) {
                NSApp.deactivate()
            }
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = controller
        popover.delegate = controller
        controller.popover = popover
        self.nativeCombinedPopover = popover
        return (popover, controller)
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    /// How long the click waited for the main thread before its handler ran (event timestamps are system uptime).
    static func clickWaitMilliseconds() -> Double {
        guard let event = NSApp.currentEvent else { return 0 }
        return max(0, ProcessInfo.processInfo.systemUptime - event.timestamp) * 1000
    }
}

/// What one showing of the kept combined popup opens on.
@MainActor
@Observable
final class NativeCombinedShowing {
    /// Closed for less than this, the pages reopen where they were left; after it, on the most recently used account.
    static let resumeInterval: TimeInterval = 6 * 60 * 60

    private(set) var generation = 0
    private(set) var openingID = NativeCombinedAccounts.overviewID
    /// The page at the leading edge as the showing opens; the opening page unless the pages resume where they were.
    private(set) var openingLeadingID = NativeCombinedAccounts.overviewID
    private(set) var pageOrder: [String] = []
    private(set) var width = NativeCombinedPopupView.pageWidth

    /// Bumped once the popup has finished appearing, and once it has closed.
    private(set) var shownGeneration = 0
    private(set) var closedGeneration = 0

    /// Where the pages were left: the selected page and the page at the leading edge.
    @ObservationIgnored var leftSelectionID: String?
    @ObservationIgnored var leftLeadingID: String?
    @ObservationIgnored private(set) var closedAt: Date?

    func begin(openingID: String, leadingID: String? = nil, pageOrder: [String], width: CGFloat) {
        self.openingID = openingID
        self.openingLeadingID = leadingID ?? openingID
        self.pageOrder = pageOrder
        self.width = width
        self.generation += 1
    }

    /// The pages where they were left, while they all still exist and the popup was closed only a while.
    func resumed(validIDs: [String], now: Date) -> (selection: String, leading: String)? {
        guard let closedAt, now.timeIntervalSince(closedAt) < Self.resumeInterval, now >= closedAt,
              let leading = self.leftLeadingID, validIDs.contains(leading) else { return nil }
        let selection = self.leftSelectionID.flatMap { validIDs.contains($0) ? $0 : nil } ?? leading
        return (selection, leading)
    }

    func resize(_ width: CGFloat) {
        if self.width != width { self.width = width }
    }

    func shown() {
        self.shownGeneration += 1
    }

    func closed(at date: Date = Date()) {
        self.closedAt = date
        self.closedGeneration += 1
    }
}
