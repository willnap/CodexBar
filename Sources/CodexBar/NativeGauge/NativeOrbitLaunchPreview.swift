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
                // Visual audits of range switches: switch to `CODEXBAR_PREVIEW_SWITCH_DAYS` once data lands, as the
                // range
                // control does (pair with `CODEXBAR_PREVIEW_ANIMATION_SCALE` to slow it down).
                if let days = ProcessInfo.processInfo.environment["CODEXBAR_PREVIEW_SWITCH_DAYS"].flatMap(Int.init) {
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(15))
                        withAnimation(.smooth(duration: 0.25 * NativeOrbitProjectionStyle.previewAnimationScale)) {
                            controller.orbitState.days = days
                        }
                        let marker = FileManager.default.temporaryDirectory
                            .appendingPathComponent("codexbar-preview-switch.txt")
                        try? "switched \(days) now \(controller.orbitState.days)\n".write(
                            to: marker, atomically: true, encoding: .utf8)
                        try? await Task.sleep(for: .seconds(2))
                        try? "switched \(days) after2s \(controller.orbitState.days)\n".write(
                            to: marker, atomically: true, encoding: .utf8)
                    }
                }
                // Visual audits of hover states: hold an inspected instant (seconds since 1970) once data lands.
                if let value = ProcessInfo.processInfo.environment["CODEXBAR_PREVIEW_INSPECT_AT"].flatMap(Double.init) {
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(12))
                        controller.orbitState.inspect(Date(timeIntervalSince1970: value))
                    }
                }
                // Visual audits of hover scrubbing: `CODEXBAR_PREVIEW_SCRUB` is "from,to" in hours from now. Once
                // launch
                // settles it sweeps the inspected instant from one to the other at pointer-move rate, back a third of
                // the
                // way, then holds, all slowed with `CODEXBAR_PREVIEW_ANIMATION_SCALE` as the rolls are.
                if let hours = ProcessInfo.processInfo.environment["CODEXBAR_PREVIEW_SCRUB"]?
                    .split(separator: ",").compactMap({ Double($0) }), hours.count == 2
                {
                    Task { @MainActor in
                        // After launch work settles, so the sweep runs at the pace a pointer would.
                        try? await Task.sleep(for: .seconds(45))
                        let scale = NativeOrbitProjectionStyle.previewAnimationScale
                        let now = Date()
                        let from = hours[0] * 3600
                        let to = hours[1] * 3600
                        let back = to - (to - from) / 3
                        let sweeps = [(from, to, 180), (to, back, 60)]
                        // Each step's wall time, so a stalled main thread shows in the marker. A pointer on the popup
                        // keeps the app active; without this, App Nap coalesces the steps' timers to ~125ms.
                        let activity = ProcessInfo.processInfo.beginActivity(
                            options: .userInitiated, reason: "Preview hover scrub")
                        defer { ProcessInfo.processInfo.endActivity(activity) }
                        var steps: [Int] = []
                        for (start, end, count) in sweeps {
                            for step in 0...count {
                                let started = ContinuousClock.now
                                let offset = start + (end - start) * Double(step) / Double(count)
                                controller.orbitState.inspect(now.addingTimeInterval(offset))
                                try? await Task.sleep(for: .seconds(scale / 120))
                                let elapsed = started.duration(to: .now).components
                                steps
                                    .append(Int(elapsed.seconds) * 1000 +
                                        Int(elapsed.attoseconds / 1_000_000_000_000_000))
                            }
                        }
                        let marker = FileManager.default.temporaryDirectory
                            .appendingPathComponent("codexbar-preview-scrub.txt")
                        try? "scrubbed \(hours) steps(ms) \(steps)\n".write(
                            to: marker,
                            atomically: true,
                            encoding: .utf8)
                    }
                }
                Task { @MainActor [weak self] in
                    guard let store = self?.store else { return }
                    await NativeOrbitPopupBenchmark.runRefreshProbeIfRequested(
                        controller: controller,
                        store: store,
                        provider: provider,
                        popover: popup,
                        reopenPopup: { [weak self] in
                            // Clicks on other status items close this popup; open it again like its own item does.
                            guard let self, !popup.isShown, let button = self.statusItems[provider.instanceID]?.button
                            else { return }
                            self.nativeServiceClicked(button)
                        })
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
        // Native glass draws its flat inactive appearance unless its window is key. A launch from a shell is not
        // allowed to activate the app, so a non-activating panel takes key itself and shows the glass the popup shows.
        let window = NativeOrbitPreviewPanel(
            contentRect: NSRect(origin: .zero, size: controller.preferredContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        window.hidesOnDeactivate = false
        window.title = "CodexBar · Live usage"
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        let hosting = NSHostingView(rootView: NativeOrbitPopupView(
            state: controller.orbitState,
            activate: { [weak controller] id in controller?.activateAccount(id: id) },
            signIn: nil,
            refresh: { [weak controller] in controller?.refreshUsage() },
            settings: { [weak controller] in controller?.openSettings() },
            lightAction: { [weak controller] accountID, action in
                controller?.handleLight(action, accountID: accountID)
            }))
        // The popover's own material, so vibrant styles (`.secondary`, `.tertiary`) render here as they do there.
        let material = NSVisualEffectView()
        material.material = .popover
        material.blendingMode = .behindWindow
        material.state = .active
        hosting.frame = material.bounds
        hosting.autoresizingMask = [.width, .height]
        material.addSubview(hosting)
        window.contentView = material
        // `CODEXBAR_PREVIEW_APPEARANCE=light` or `dark` audits one appearance whatever the system's.
        switch ProcessInfo.processInfo.environment["CODEXBAR_PREVIEW_APPEARANCE"] {
        case "light": window.appearance = NSAppearance(named: .aqua)
        case "dark": window.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
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

/// Takes key without activating the app, so native glass shows its active appearance in preview captures.
final class NativeOrbitPreviewPanel: NSPanel {
    override var canBecomeKey: Bool {
        true
    }
}
