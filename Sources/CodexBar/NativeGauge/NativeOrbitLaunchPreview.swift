import AppKit
import CodexBarCore
import SwiftUI

extension StatusItemController {
    /// Opt-in via launch argument or a development Info.plist key; opens the same retained popup as the status item.
    func openNativeOrbitLaunchPreviewIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        let flag = "--native-popup-preview-provider"
        let requested = arguments.firstIndex(of: flag).flatMap { index in
            arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
        }
        guard self.settings.nativeDesignEnabled,
              let identifier = requested
              ?? Bundle.main.object(forInfoDictionaryKey: "CodexBarNativePopupPreview") as? String,
              let provider = UsageProvider(rawValue: identifier) else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, let item = self.statusItems[provider.instanceID], let button = item.button else { return }
            NSApp.activate()
            let popup = self.nativePopover(for: provider, button: button)
            if let controller = popup.contentViewController as? NativeServicePopoverController {
                // A standard inspection window exposes the identical live SwiftUI content to window-only tools.
                // The actual status-anchored popup stays open alongside it in this opt-in development mode.
                controller.prepare()
                let inspectionWindow = NativeOrbitPreviewWindow.show(controller)
                Task { @MainActor in
                    await NativeOrbitPopupBenchmark.runIfRequested(
                        controller: controller, window: inspectionWindow, provider: provider)
                }
                Task { @MainActor [weak self] in
                    guard let store = self?.store else { return }
                    await NativeOrbitPopupBenchmark.runRefreshProbeIfRequested(
                        controller: controller, store: store, provider: provider, popover: popup)
                }
                // Open the actual status popup after the inspection window takes focus. Otherwise AppKit can
                // dismiss the status popup while making the new window key, before a visual audit can capture it.
                // A hidden menu extra cannot anchor a visible popup.
                if item.isVisible, let window = button.window,
                   NSScreen.screens.contains(where: { $0.frame.intersects(window.frame) })
                {
                    popup.behavior = .applicationDefined
                    self.nativeServiceClicked(button)
                }
                let proof: [String: Any] = [
                    "provider": provider.rawValue,
                    "shown": popup.isShown,
                    "inspectionWindowShown": inspectionWindow.isVisible,
                    "contentSize": NSStringFromSize(popup.contentSize),
                    "windowFrame": NSStringFromRect(inspectionWindow.frame),
                    "popupWindowFrame": controller.view.window.map { NSStringFromRect($0.frame) } ?? "",
                    "accounts": controller.orbitState.accounts.count,
                    "measuredAccounts": controller.orbitState.accounts.count {
                        $0.gauge.resolvedWindows.contains { $0.usedFraction != nil }
                    },
                ]
                let path = FileManager.default.temporaryDirectory
                    .appendingPathComponent("codexbar-native-orbit-preview.json")
                try? JSONSerialization.data(withJSONObject: proof, options: [.prettyPrinted, .sortedKeys])
                    .write(to: path, options: .atomic)
            }
        }
    }
}

@MainActor
private enum NativeOrbitPreviewWindow {
    private static var window: NSWindow?

    static func show(_ controller: NativeServicePopoverController) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: controller.preferredContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "CodexBar · Live usage"
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .windowBackgroundColor
        window.contentView = NSHostingView(rootView: NativeOrbitPopupView(
            state: controller.orbitState,
            activate: { [weak controller] id in controller?.activateAccount(id: id) },
            signIn: nil,
            refresh: { [weak controller] in controller?.refreshUsage() },
            settings: { [weak controller] in controller?.openSettings() }))
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        // Accounts load after launch; keep the inspection window as wide as the popup's columns.
        Task { @MainActor [weak window, weak controller] in
            for _ in 0..<30 {
                try? await Task.sleep(for: .seconds(2))
                guard let window, let controller else { return }
                if window.contentLayoutRect.size != controller.preferredContentSize {
                    window.setContentSize(controller.preferredContentSize)
                }
            }
        }
        return window
    }
}
