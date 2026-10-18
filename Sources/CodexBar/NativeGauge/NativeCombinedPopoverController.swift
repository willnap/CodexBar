import AppKit
import CodexBarCore
import SwiftUI

@MainActor
final class NativeCombinedPopoverController: NSViewController, NSPopoverDelegate {
    private let controllers: [NativeServicePopoverController]
    private let toolbar = NativeOrbitPopupState()
    private weak var button: NSStatusBarButton?
    private let didClose: () -> Void

    init(controllers: [NativeServicePopoverController], button: NSStatusBarButton, didClose: @escaping () -> Void) {
        self.controllers = controllers
        self.button = button
        self.didClose = didClose
        super.init(nibName: nil, bundle: nil)
        self.preferredContentSize = NativeCombinedPopupView.contentSize
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func loadView() {
        for controller in self.controllers {
            controller.beginCombinedPresentation()
        }
        self.toolbar.accounts = self.controllers.flatMap(\.orbitState.accounts)
        self.toolbar.layoutColumns = 1
        self.view = NSHostingView(rootView: NativeCombinedPopupView(
            sources: self.controllers.map { $0.combinedSource() }, toolbar: self.toolbar))
        self.view.frame = NSRect(origin: .zero, size: self.preferredContentSize)
    }

    func popoverWillShow(_: Notification) {
        self.button?.highlight(true)
    }

    func popoverDidClose(_: Notification) {
        for controller in self.controllers {
            controller.endCombinedPresentation()
        }
        self.button?.highlight(false)
        self.didClose()
    }
}

@MainActor
enum NativeCombinedStatusImage {
    static func make(_ pages: [NativeCombinedAccounts.Page]) -> NSImage {
        let shown = Array(pages.prefix(3))
        let image = NSImage(size: NSSize(width: 18 + max(0, shown.count - 1) * 13, height: 22))
        image.lockFocus()
        for (index, page) in shown.enumerated() {
            let repeated = shown.prefix(index).contains { $0.provider == page.provider }
            let glyph = repeated
                ? NSImage(systemSymbolName: page.account.symbol, accessibilityDescription: nil)
                : NativeProviderSymbol.image(for: page.provider, pointSize: 15)
            glyph?.draw(in: NSRect(x: index * 13, y: index.isMultiple(of: 2) ? 4 : 1, width: 17, height: 17))
        }
        image.unlockFocus()
        image.isTemplate = true
        return image
    }
}

extension StatusItemController {
    /// Native mode decides visibility from cached connection evidence every time it receives an icon update.
    func updateNativeAccountVisibility() {
        let connections = self.store.nativeCombinedConnections()
        let connected = connections.filter(\.isConnected).map(\.provider)
        let combined = NativeCombinedAccounts.shouldCombine(connections)
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
        guard combined, let button = self.statusItem.button else { return }
        let model = NativeCombinedAccounts(connections: connections, now: Date())
        self.statusItem.menu = nil
        self.statusItem.length = NSStatusItem.variableLength
        button.target = self
        button.action = #selector(self.nativeCombinedClicked(_:))
        button.sendAction(on: [.leftMouseDown, .rightMouseUp])
        button.title = ""
        button.image = NativeCombinedStatusImage.make(model.recentAccounts)
        let recent = model.recentAccounts.map {
            self.store.metadata(for: $0.provider).displayName + ": " + $0.account.label
        }.joined(separator: ", ")
        let label = L("All accounts") + ". " + recent
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.setAccessibilityIdentifier("CodexBar.CombinedAccounts")
    }

    @objc func nativeCombinedClicked(_ sender: NSStatusBarButton) {
        if self.nativeCombinedPopover?.isShown == true {
            self.closeNativeServicePopover()
            return
        }
        self.closeNativeServicePopover()
        let controllers = self.nativeCombinedProviders.compactMap { provider -> NativeServicePopoverController? in
            guard let button = self.statusItems[provider.instanceID]?.button else { return nil }
            return self.nativePopover(for: provider, button: button)
                .contentViewController as? NativeServicePopoverController
        }
        guard let provider = self.nativeCombinedProviders.first, !controllers.isEmpty else { return }
        let controller = NativeCombinedPopoverController(controllers: controllers, button: sender) { [weak self] in
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
        popover.contentSize = NativeCombinedPopupView.contentSize
        self.nativeCombinedPopover = popover
        self.nativeUsagePopover = popover
        self.nativeServiceRoute.toggle(provider)
        self.lastMenuProvider = provider.instanceID
        NSApp.activate()
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        controller.view.window?.makeKey()
        self.nativePopoverOpened(provider: provider, popover: popover)
    }
}
