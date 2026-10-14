import AppKit
import CodexBarCore
import Foundation
import SwiftUI

/// Opt-in (`--native-popup-refresh-probe` with `--native-popup-preview-provider`): presses the popup's refresh button
/// like a click on live data and writes `codexbar-native-refresh-probe-<provider>.json` to the temporary directory.
/// Update times, busy flags and errors only. Phases, in order, after `CODEXBAR_REFRESH_PROBE_DELAY` seconds (20):
/// - `CODEXBAR_REFRESH_PROBE_OBSERVE` seconds (0): samples every 50 ms each flag that can make a press inert or
///   slow, and how long each one holds.
/// - `CODEXBAR_REFRESH_PROBE_RUNS` presses while idle (2).
/// - `CODEXBAR_REFRESH_PROBE_BUSY_RUNS` presses while the timer's background refresh is fetching the provider (0).
/// - `CODEXBAR_REFRESH_PROBE_DOUBLE_RUNS` presses repeated while the first press is still loading, alternately
///   300 ms and 1.2 s after it (0).
@MainActor
enum NativeOrbitRefreshProbe {
    struct Context {
        let controller: NativeServicePopoverController
        let store: UsageStore
        let provider: UsageProvider
        let target: NSView
        let reopenPopup: @MainActor () -> Void

        var state: NativeOrbitPopupState {
            self.controller.orbitState
        }
    }

    private struct Hold {
        var since: ContinuousClock.Instant?
        var trueSamples = 0
        var durations: [Double] = []
    }

    static func run(
        controller: NativeServicePopoverController,
        store: UsageStore,
        provider: UsageProvider,
        popover: NSPopover?,
        reopenPopup: @escaping @MainActor () -> Void = {}) async
    {
        let environment = ProcessInfo.processInfo.environment
        func number(_ key: String, _ fallback: Double) -> Double {
            environment[key].flatMap(Double.init) ?? fallback
        }
        try? await Task.sleep(for: .seconds(number("CODEXBAR_REFRESH_PROBE_DELAY", 20)))
        // Click the status popup when it is on screen, else the inspection window showing the same toolbar.
        let target = controller.view.window?.isVisible == true ? controller.view
            : NSApp.windows.first { $0.isVisible && $0.contentView is NSHostingView<NativeOrbitPopupView> }?.contentView
            ?? controller.view
        let context = Context(
            controller: controller,
            store: store,
            provider: provider,
            target: target,
            reopenPopup: reopenPopup)
        var report: [String: Any] = [
            "provider": provider.rawValue,
            "configuration": NativeOrbitPopupBenchmark.configuration,
            "clickedPopup": target === controller.view,
            "accounts": controller.orbitState.accounts.count,
        ]
        let observe = number("CODEXBAR_REFRESH_PROBE_OBSERVE", 0)
        if observe > 0 {
            report["observation"] = await Self.observe(context, seconds: observe)
        }
        var idle: [[String: Any]] = []
        for _ in 0..<max(0, Int(number("CODEXBAR_REFRESH_PROBE_RUNS", 2))) {
            await idle.append(Self.press(context, fallbackToAction: true))
            try? await Task.sleep(for: .seconds(3))
        }
        report["runs"] = idle
        var busy: [[String: Any]] = []
        for _ in 0..<max(0, Int(number("CODEXBAR_REFRESH_PROBE_BUSY_RUNS", 0))) {
            await busy.append(Self.pressDuringBackgroundRefresh(context))
            try? await Task.sleep(for: .seconds(3))
        }
        report["busyRuns"] = busy
        var double: [[String: Any]] = []
        for run in 0..<max(0, Int(number("CODEXBAR_REFRESH_PROBE_DOUBLE_RUNS", 0))) {
            // Alternately a double click (inside the join window) and a later second press during the load.
            await double.append(Self.press(
                context,
                secondPressAfter: .milliseconds(run.isMultiple(of: 2) ? 300 : 1200)))
            try? await Task.sleep(for: .seconds(3))
        }
        report["doubleRuns"] = double
        if environment["CODEXBAR_REFRESH_PROBE_SETTINGS"] == "1" {
            // The preview pins its popup open; restore the status item's own dismissal for this step.
            popover?.behavior = .transient
            report["settingsPressedAt"] = Date().ISO8601Format()
            _ = NativeOrbitPopupBenchmark.click(target, fromLeading: -(NativeOrbitToolbar.contentInset + 7))
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

    // MARK: Flags

    static func busyFlags(_ context: Context) -> [String: Bool] {
        let store = context.store
        return [
            "toolbarRefreshing": context.state.isRefreshing,
            "providerRefreshing": store.refreshingProviders.contains(context.provider.instanceID),
            "storeRefreshing": store.isRefreshing,
            "forcedEnrichmentInFlight": store.hasForcedRefreshEnrichmentInFlight,
            "popupEnrichmentInFlight": context.controller.manualRefresh.isEnriching,
            "localScanInFlight": Self.localScanInFlight(context),
            "tokenScanInFlight": store.tokenRefreshSequenceTask != nil,
        ]
    }

    private static func localScanInFlight(_ context: Context) -> Bool {
        // Provider-specific by design: each provider's local archive scan has its own task.
        switch context.provider {
        case .kimi: context.store.nativeKimiLocalUsageTask != nil
        case .claude: context.store.nativeClaudeAmbientUsageTask != nil
        case .codex: context.store.nativeCodexSessionHistoryBackfillTask != nil
        default: false
        }
    }

    private static func updatedAt(_ context: Context) -> [String: Double] {
        Dictionary(
            context.state.accounts.map { ($0.id, $0.updatedAt?.timeIntervalSince1970 ?? 0) },
            uniquingKeysWith: { first, _ in first })
    }

    private static func label(_ context: Context) -> String {
        guard let updated = context.state.accounts.compactMap(\.updatedAt).min() else { return "—" }
        return NativeOrbitToolbar.age(updated, now: Date())
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let components = start.duration(to: .now).components
        return Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
    }

    // MARK: Observation

    /// How often each flag is set while nobody presses, and for how long it holds once set.
    private static func observe(_ context: Context, seconds: Double) async -> [String: Any] {
        let started = ContinuousClock.now
        var holds: [String: Hold] = [:]
        var samples = 0
        var labelChanges = 0
        var lastUpdated = Self.updatedAt(context)
        var accountUpdates: [String: Int] = [:]
        while Self.milliseconds(since: started) < seconds * 1000 {
            samples += 1
            let now = ContinuousClock.now
            for (name, value) in Self.busyFlags(context) {
                var hold = holds[name] ?? Hold()
                if value {
                    hold.trueSamples += 1
                    if hold.since == nil { hold.since = now }
                } else if let since = hold.since {
                    let components = since.duration(to: now).components
                    hold.durations.append(Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15)
                    hold.since = nil
                }
                holds[name] = hold
            }
            let updated = Self.updatedAt(context)
            if updated != lastUpdated {
                labelChanges += 1
                for (id, value) in updated where lastUpdated[id] != value {
                    accountUpdates[id, default: 0] += 1
                }
                lastUpdated = updated
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        var flags: [String: Any] = [:]
        for (name, hold) in holds {
            var durations = hold.durations
            if let since = hold.since { durations.append(Self.milliseconds(since: since)) }
            let sorted = durations.sorted()
            flags[name] = [
                "fractionOfTime": samples == 0 ? 0 : Double(hold.trueSamples) / Double(samples),
                "holds": sorted.count,
                "medianHoldMilliseconds": sorted.isEmpty ? 0 : sorted[sorted.count / 2],
                "maxHoldMilliseconds": sorted.last ?? 0,
                "stillHeldAtEnd": hold.since != nil,
            ] as [String: Any]
        }
        return [
            "seconds": seconds,
            "samples": samples,
            "flags": flags,
            "presentationUpdates": labelChanges,
            "accountUpdates": accountUpdates.values.sorted(),
            "labelAtEnd": Self.label(context),
        ]
    }

    // MARK: Presses

    /// Starts what the adaptive timer runs every few minutes, waits until it is fetching this provider, then presses.
    private static func pressDuringBackgroundRefresh(_ context: Context) async -> [String: Any] {
        let triggered = ContinuousClock.now
        let background = Task { @MainActor in
            await context.store.refresh(enrichmentMode: .automatic)
            return Self.milliseconds(since: triggered)
        }
        while !context.store.refreshingProviders.contains(context.provider.instanceID),
              Self.milliseconds(since: triggered) < 10000
        {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let busyAfter = Self.milliseconds(since: triggered)
        try? await Task.sleep(for: .milliseconds(150))
        var result = await Self.press(context)
        result["backgroundProviderBusyAfterMilliseconds"] = busyAfter
        result["backgroundRefreshMilliseconds"] = await background.value
        return result
    }

    /// One press (and optionally a second one while the first is loading), followed until the spinner, every load
    /// and the popup's enrichment have settled.
    private static func press(
        _ context: Context,
        fallbackToAction: Bool = false,
        secondPressAfter: Duration? = nil) async -> [String: Any]
    {
        let state = context.state
        let before = Self.updatedAt(context)
        let pressedAt = Date().timeIntervalSince1970
        var result: [String: Any] = [
            "startedAt": Date().ISO8601Format(),
            "busyBeforeClick": Self.busyFlags(context),
            "labelBefore": Self.label(context),
        ]
        let loadsBefore = context.controller.manualRefresh.loadCount
        let started = ContinuousClock.now
        // Click the toolbar's own button (mouse down and up delivered to its window), as a person would.
        result["click"] = await Self.clickRefresh(context)
        try? await Task.sleep(for: .milliseconds(60))
        result["clickRegistered"] = state.isRefreshing
        if !state.isRefreshing {
            // The status popup can be closed by clicks on other status items; press the inspection window's
            // identical toolbar instead, made key first.
            result["retryClick"] = await Self.clickRefresh(context, preferInspectionWindow: true)
            try? await Task.sleep(for: .milliseconds(60))
            result["retryRegistered"] = state.isRefreshing
        }
        if fallbackToAction, !state.isRefreshing { context.controller.refreshUsage() }
        result["accepted"] = state.isRefreshing
        if let secondPressAfter {
            try? await Task.sleep(for: secondPressAfter)
            result["secondPressWhileLoading"] = state.isRefreshing
            result["secondPressAtMilliseconds"] = Self.milliseconds(since: started)
            result["secondClick"] = await Self.clickRefresh(context)
        }
        let followed = await Self.follow(context, started: started)
        result.merge(followed) { _, new in new }
        // Let the open popup apply the published change (it coalesces store changes for 150 ms).
        try? await Task.sleep(for: .milliseconds(400))
        result["accounts"] = state.accounts.map { account in
            let after = account.updatedAt?.timeIntervalSince1970 ?? 0
            return [
                "updatedBefore": before[account.id] ?? 0,
                "updatedAfter": after,
                "refreshed": after > (before[account.id] ?? 0),
                "measuredAfterPress": after >= pressedAt,
                "ageSecondsAfter": after > 0 ? Date().timeIntervalSince1970 - after : -1,
                "status": account.statusText ?? "",
            ] as [String: Any]
        }
        result["toolbarLoads"] = context.controller.manualRefresh.loadCount - loadsBefore
        result["labelAfter"] = Self.label(context)
        result["storeError"] = context.store.userFacingError(for: context.provider) ?? ""
        result["toolbarError"] = state.refreshIssue?.detail ?? ""
        result["toolbarIssue"] = state.refreshIssue?.label ?? ""
        return result
    }

    /// Clicks the refresh arrow in whichever window shows the toolbar now, and records whether that window could
    /// take the click.
    private static func clickRefresh(_ context: Context, preferInspectionWindow: Bool = false) async -> [String: Any] {
        var reopened = false
        if !preferInspectionWindow, context.controller.view.window?.isVisible != true {
            context.reopenPopup()
            reopened = true
            try? await Task.sleep(for: .milliseconds(400))
        }
        let inspection = NSApp.windows.first {
            $0.isVisible && $0.contentView is NSHostingView<NativeOrbitPopupView>
        }?.contentView
        let popupVisible = context.controller.view.window?.isVisible == true
        let target = preferInspectionWindow ? inspection ?? context.controller.view
            : popupVisible ? context.controller.view : inspection ?? context.controller.view
        if preferInspectionWindow {
            NSApp.activate()
            target.window?.makeKeyAndOrderFront(nil)
        }
        let offset = NativeOrbitToolbar.contentInset + 6
        let location = NativeOrbitPopupBenchmark.clickLocation(target, fromLeading: offset)
        let hit = target.superview.map { target.hitTest($0.convert(location, from: nil)) }
            ?? target.hitTest(location)
        let info: [String: Any] = [
            "reopenedPopup": reopened,
            "popup": target === context.controller.view,
            "popupVisible": popupVisible,
            "windowVisible": target.window?.isVisible ?? false,
            "windowKey": target.window?.isKeyWindow ?? false,
            "appActive": NSApp.isActive,
            "hitView": hit.map { String(describing: type(of: $0)).prefix(60) }.map(String.init) ?? "none",
        ]
        _ = NativeOrbitPopupBenchmark.click(target, fromLeading: offset)
        return info
    }

    /// Follows the spinner state after a press: every load it runs, and the popup's enrichment after them.
    private static func follow(_ context: Context, started: ContinuousClock.Instant) async -> [String: Any] {
        let state = context.state
        var loads = state.isRefreshing ? 1 : 0
        var wasRefreshing = state.isRefreshing
        var firstLoadEnded: Double?
        var lastLoadEnded: Double?
        var spinnerVisibleAt: Double?
        var providerTimeline: [[String: Any]] = []
        var providerBusy = context.store.refreshingProviders.contains(context.provider.instanceID)
        providerTimeline.append(["milliseconds": Self.milliseconds(since: started), "providerRefreshing": providerBusy])
        while Self.milliseconds(since: started) < 300_000 {
            try? await Task.sleep(for: .milliseconds(20))
            let elapsed = Self.milliseconds(since: started)
            let refreshing = state.isRefreshing
            if refreshing, !wasRefreshing { loads += 1 }
            if !refreshing, wasRefreshing {
                lastLoadEnded = elapsed
                if firstLoadEnded == nil { firstLoadEnded = elapsed }
            }
            if refreshing, spinnerVisibleAt == nil, elapsed >= NativeOrbitToolbar.spinnerDelay.milliseconds {
                spinnerVisibleAt = elapsed
            }
            wasRefreshing = refreshing
            let busy = context.store.refreshingProviders.contains(context.provider.instanceID)
            if busy != providerBusy {
                providerBusy = busy
                providerTimeline.append(["milliseconds": elapsed, "providerRefreshing": busy])
            }
            // Settled: no load for a second and a half, and the popup's enrichment has finished.
            if !refreshing, !context.controller.manualRefresh.isEnriching,
               elapsed - (lastLoadEnded ?? 0) > 1500
            {
                break
            }
        }
        return [
            "loads": loads,
            "spinnerMilliseconds": firstLoadEnded ?? -1,
            "lastLoadEndedMilliseconds": lastLoadEnded ?? -1,
            "spinnerShownAtMilliseconds": spinnerVisibleAt ?? -1,
            "settledMilliseconds": Self.milliseconds(since: started),
            "providerRefreshingTimeline": providerTimeline,
        ]
    }
}

extension Duration {
    fileprivate var milliseconds: Double {
        Double(self.components.seconds) * 1000 + Double(self.components.attoseconds) / 1e15
    }
}
