import AppKit
import CodexBarCore
import Foundation
import SwiftUI

/// Opt-in render timing on live data (`--native-popup-benchmark` with `--native-popup-preview-provider`).
/// Writes `codexbar-native-popup-benchmark-<provider>.json` to the temporary directory; usage totals only.
@MainActor
enum NativeOrbitPopupBenchmark {
    static func runIfRequested(
        controller: NativeServicePopoverController,
        window: NSWindow,
        provider: UsageProvider) async
    {
        guard CommandLine.arguments.contains("--native-popup-benchmark") else { return }
        let delay = ProcessInfo.processInfo.environment["CODEXBAR_BENCHMARK_DELAY"].flatMap(Double.init) ?? 60
        try? await Task.sleep(for: .seconds(delay))
        let state = controller.orbitState
        func render() {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        func measure(_ body: () -> Void) -> Double {
            let started = ContinuousClock.now
            body()
            render()
            let elapsed = started.duration(to: .now).components
            return Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
        }
        var results: [String: Any] = [
            "provider": provider.rawValue,
            "accounts": state.accounts.count,
            "configuration": Self.configuration,
        ]
        // An open after background changes rebuilds the presentation; an unchanged open only advances the clock.
        results["openAfterChange"] = Self.summary((0..<5).map { _ in
            measure {
                controller.invalidatePresentation()
                controller.popoverWillShow(Notification(name: NSPopover.willShowNotification))
            }
        })
        results["openUnchanged"] = Self.summary((0..<5).map { _ in
            measure { controller.popoverWillShow(Notification(name: NSPopover.willShowNotification)) }
        })
        for days in [1, 7, 30] {
            state.inspect(nil)
            state.days = days
            render()
            let end = state.now
            let start = CostReportingPeriod.rolling(days: days).bounds(now: end, calendar: .current).lowerBound
            let steps = 80
            let samples = (0..<steps).map { step in
                measure {
                    let fraction = Double(step) / Double(steps - 1)
                    state.inspect(start.addingTimeInterval(end.timeIntervalSince(start) * fraction))
                }
            }
            results["hover\(days)d"] = Self.summary(samples)
        }
        state.inspect(nil)
        state.days = 1
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-native-popup-benchmark-\(provider.rawValue).json")
        guard let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? data.write(to: path, options: .atomic)
    }

    /// Opt-in (`--native-popup-refresh-probe` with `--native-popup-preview-provider`): presses the popup's refresh
    /// action like a click and records how long the spinner and the background enrichment take, and what the
    /// columns published, to `codexbar-native-refresh-probe-<provider>.json` in the temporary directory. Update
    /// times and errors only.
    static func runRefreshProbeIfRequested(
        controller: NativeServicePopoverController,
        store: UsageStore,
        provider: UsageProvider,
        popover: NSPopover?) async
    {
        guard CommandLine.arguments.contains("--native-popup-refresh-probe") else { return }
        let environment = ProcessInfo.processInfo.environment
        let delay = environment["CODEXBAR_REFRESH_PROBE_DELAY"].flatMap(Double.init) ?? 20
        let runs = environment["CODEXBAR_REFRESH_PROBE_RUNS"].flatMap(Int.init) ?? 2
        try? await Task.sleep(for: .seconds(delay))
        let state = controller.orbitState
        // Click the status popup when it is on screen, else the inspection window showing the same toolbar.
        let target = controller.view.window?.isVisible == true ? controller.view
            : NSApp.windows.first { $0.isVisible && $0.contentView is NSHostingView<NativeOrbitPopupView> }?.contentView
            ?? controller.view
        var results: [[String: Any]] = []
        for _ in 0..<max(0, runs) {
            let before = Dictionary(
                state.accounts.map { ($0.id, $0.updatedAt?.timeIntervalSince1970 ?? 0) },
                uniquingKeysWith: { first, _ in first })
            var result: [String: Any] = [
                "startedAt": Date().ISO8601Format(),
                "busyBeforeClick": [
                    "storeRefreshing": store.isRefreshing,
                    "providerRefreshing": store.refreshingProviders.contains(provider.instanceID),
                    "forcedEnrichmentInFlight": store.hasForcedRefreshEnrichmentInFlight,
                    "popupEnrichmentInFlight": controller.manualRefresh.isEnriching,
                ],
            ]
            let started = ContinuousClock.now
            func elapsed() -> Double {
                let components = started.duration(to: .now).components
                return Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
            }
            // Click the popup's own toolbar button (mouse down and up delivered to its window), as a person would.
            result["clickedPopup"] = target === controller.view
            _ = Self.click(target, fromLeading: NativeOrbitToolbar.contentInset + 6)
            try? await Task.sleep(for: .milliseconds(30))
            result["clickRegistered"] = state.isRefreshing
            if !state.isRefreshing { controller.refreshUsage() }
            result["accepted"] = state.isRefreshing
            var loaded: Double?
            var enriched: Double?
            var accountsAtLoad: [String: Double] = [:]
            while elapsed() < 300_000 {
                try? await Task.sleep(for: .milliseconds(20))
                if loaded == nil, !state.isRefreshing {
                    loaded = elapsed()
                    accountsAtLoad = Dictionary(
                        state.accounts.map { ($0.id, $0.updatedAt?.timeIntervalSince1970 ?? 0) },
                        uniquingKeysWith: { first, _ in first })
                }
                if loaded != nil, !controller.manualRefresh.isEnriching {
                    enriched = elapsed()
                    break
                }
            }
            // Let the open popup apply the published change (it coalesces store changes for 150 ms).
            try? await Task.sleep(for: .milliseconds(400))
            result["spinnerMilliseconds"] = loaded ?? -1
            result["enrichedMilliseconds"] = enriched ?? -1
            result["timedOut"] = enriched == nil
            result["accounts"] = state.accounts.map { account in
                [
                    "updatedBefore": before[account.id] ?? 0,
                    "updatedWhenSpinnerStopped": accountsAtLoad[account.id] ?? 0,
                    "updatedAfter": account.updatedAt?.timeIntervalSince1970 ?? 0,
                    "refreshed": (account.updatedAt?.timeIntervalSince1970 ?? 0) > (before[account.id] ?? 0),
                    "status": account.statusText ?? "",
                ] as [String: Any]
            }
            result["storeError"] = store.userFacingError(for: provider) ?? ""
            result["toolbarError"] = state.refreshError ?? ""
            results.append(result)
            try? await Task.sleep(for: .seconds(3))
        }
        var report: [String: Any] = [
            "provider": provider.rawValue,
            "configuration": Self.configuration,
            "runs": results,
        ]
        if environment["CODEXBAR_REFRESH_PROBE_SETTINGS"] == "1" {
            // The preview pins its popup open; restore the status item's own dismissal for this step.
            popover?.behavior = .transient
            report["settingsPressedAt"] = Date().ISO8601Format()
            report["clickedPopup"] = target === controller.view
            _ = Self.click(target, fromLeading: -(NativeOrbitToolbar.contentInset + 7))
            try? await Task.sleep(for: .seconds(2))
            report["settingsWindowVisible"] = NSApp.windows.contains {
                $0.isVisible && $0.identifier?.rawValue == SettingsWindowIdentity.identifier
            }
            report["popupShownAfterSettings"] = controller.view.window?.isVisible ?? false
        }
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-native-refresh-probe-\(provider.rawValue).json")
        guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? data.write(to: path, options: .atomic)
    }

    /// Delivers a click to the toolbar row at `fromLeading` points from the leading edge (negative: from the
    /// trailing edge), without moving the pointer.
    private static func click(_ view: NSView, fromLeading offset: CGFloat) -> Bool {
        guard let window = view.window else { return false }
        let fromBottom: CGFloat = 24
        let local = NSPoint(
            x: offset >= 0 ? offset : view.bounds.maxX + offset,
            y: view.isFlipped ? view.bounds.maxY - fromBottom : fromBottom)
        let location = view.convert(local, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type,
                location: location,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0)
            else { return false }
            window.sendEvent(event)
        }
        return true
    }

    private static var configuration: String {
        #if DEBUG
        "debug"
        #else
        "release"
        #endif
    }

    private static func summary(_ samples: [Double]) -> [String: Double] {
        let sorted = samples.sorted()
        guard !sorted.isEmpty else { return [:] }
        return [
            "medianMilliseconds": sorted[sorted.count / 2],
            "p95Milliseconds": sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))],
            "maxMilliseconds": sorted.last ?? 0,
            "meanMilliseconds": sorted.reduce(0, +) / Double(sorted.count),
        ]
    }
}
