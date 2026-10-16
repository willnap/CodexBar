import AppKit
import Foundation
import QuartzCore

/// Offline fixture timing only. Callback cadence is measured separately from synchronous view update cost;
/// neither is a claim about compositor presentation times.
@MainActor
final class NativeOrbitPerformanceProbe: NSObject {
    private static var active: NativeOrbitPerformanceProbe?
    private let state: NativeOrbitPopupState
    private weak var view: NSView?
    private var link: CADisplayLink?
    private var preparationMilliseconds: Double = 0
    private var started = CACurrentMediaTime()
    private var previous: Double?
    private var phase = "startup"
    private var updateTimes: [String: [Double]] = [:]
    private var intervals: [String: [Double]] = [:]
    private var allIntervals: [String: [Double]] = [:]
    private var startupIntervals: [String: [Double]] = [:]
    private var visibility: [String: WindowVisibilityCounts] = [:]
    private var previousWasForeground = false
    private var invalidUpdateSamples: [String: Int] = [:]
    private var preflightMilliseconds: Double = 0
    private var preflightVisibility: [String: Any] = [:]
    private var preflightWasForeground = false
    private var switchAccount: (() -> Void)?
    private var phaseStart = CACurrentMediaTime()
    private var phaseIndex = -2
    private var phasePreparation: [String: Double] = [:]
    private var phaseStarts: [String: Double] = ["startup": 0]
    private var snap: ((Date) -> Date)?
    private var step = 0

    static func startIfRequested(
        state: NativeOrbitPopupState,
        view: NSView,
        preparationMilliseconds: Double,
        switchAccount: @escaping () -> Void) async
    {
        guard CommandLine.arguments.contains("--preview-performance") else { return }
        let preflightStart = CACurrentMediaTime()
        view.isHidden = false
        view.layoutSubtreeIfNeeded()
        view.window?.displayIfNeeded()
        CATransaction.flush()
        // Window-server occlusion arrives after ordering. Yield once and wait only while this owned window has
        // not become visible, with a bounded timeout that produces an invalid benchmark rather than a false pass.
        await Task.yield()
        for _ in 0..<20 {
            if WindowVisibility(view: view).isForeground { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let probe = Self(state: state, view: view)
        Self.active = probe
        probe.preparationMilliseconds = preparationMilliseconds
        probe.switchAccount = switchAccount
        let visibility = WindowVisibility(view: view)
        probe.preflightMilliseconds = (CACurrentMediaTime() - preflightStart) * 1000
        probe.preflightVisibility = visibility.json
        probe.preflightWasForeground = visibility.isForeground
        guard let screen = view.window?.screen ?? NSScreen.main else { return }
        let link = screen.displayLink(target: probe, selector: #selector(Self.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 120, maximum: 120, preferred: 120)
        probe.link = link
        link.add(to: .main, forMode: .common)
    }

    private init(state: NativeOrbitPopupState, view: NSView) {
        self.state = state
        self.view = view
        super.init()
    }

    @objc private func tick(_: CADisplayLink) {
        let timestamp = CACurrentMediaTime()
        let visibility = WindowVisibility(view: self.view)
        self.visibility[self.phase, default: WindowVisibilityCounts()].record(visibility)
        if let previous {
            let interval = (timestamp - previous) * 1000
            self.allIntervals[self.phase, default: []].append(interval)
            if self.previousWasForeground, visibility.isForeground {
                self.intervals[self.phase, default: []].append(interval)
                if self.phaseIndex < 0 {
                    self.startupIntervals["\(self.phase).\(self.state.startup)", default: []].append(interval)
                }
            }
        }
        self.previous = timestamp
        self.previousWasForeground = visibility.isForeground
        let elapsed = timestamp - self.phaseStart
        let inspectionDuration = CommandLine.arguments.contains("--preview-performance-steady") ? 4.0 : 1.2
        let phaseDuration = self.phaseIndex == -2 ? 2.2 : self.phaseIndex == -1 ? 4.0 : inspectionDuration
        if elapsed >= phaseDuration {
            self.phaseIndex += 1
            if self.phaseIndex == -1 {
                self.phase = "accountSwitchStartup"
                self.phaseStarts[self.phase] = timestamp - self.started
                self.phaseStart = timestamp
                self.switchAccount?()
                return
            }
            guard self.phaseIndex < 6 else { self.finish(); return }
            let preparationStart = CACurrentMediaTime()
            self.state.inspect(nil)
            let days = [1, 7, 30][self.phaseIndex / 2]
            if self.state.days != days { self.state.days = days }
            self.state.prepareStartupArtwork(
                screen: self.view?.window?.screen,
                appearance: self.view?.effectiveAppearance)
            self.phase = "\(self.phaseIndex.isMultiple(of: 2) ? "past" : "future")\(self.state.days)d"
            if let account = self.state.accounts.first {
                let widget = NativeOrbitHistoryWidget(
                    histories: account.history,
                    now: self.state.now,
                    days: self.state.days,
                    quotaLabels: account.quotaLabels,
                    quotaWindows: account.quotaWindows,
                    spending: self.state.spendingHistory(for: account),
                    preparedLanes: self.state.renderLanes(for: account),
                    preparedObservationDates: self.state.renderObservationDates(for: account),
                    projection: self.state.projection(for: account),
                    isProjecting: self.state.isProjecting)
                let index = widget.inspectionIndex(widget.lanes)
                self.snap = { widget.inspectionDate(at: $0, plotWidth: 196, using: index) }
            }
            self.phasePreparation[self.phase] = (CACurrentMediaTime() - preparationStart) * 1000
            self.phaseStart = CACurrentMediaTime()
            self.phaseStarts[self.phase] = self.phaseStart - self.started
            self.step = 0
        }
        let before = CACurrentMediaTime()
        if self.phaseIndex >= 0 {
            let fraction = Double(self.step % 100) / 99
            let span = Double(self.state.days) * 86400
            let offset = self.phaseIndex.isMultiple(of: 2) ? -span + span * fraction : span * fraction
            let date = self.state.now.addingTimeInterval(offset)
            self.state.inspect(self.snap?(date) ?? date)
            self.step += 1
        }
        if !CommandLine.arguments.contains("--preview-performance-natural") {
            self.view?.layoutSubtreeIfNeeded()
            self.view?.window?.displayIfNeeded()
            CATransaction.flush()
        }
        let elapsedUpdate = (CACurrentMediaTime() - before) * 1000
        if visibility.isForeground, WindowVisibility(view: self.view).isForeground {
            self.updateTimes[self.phase, default: []].append(elapsedUpdate)
        } else {
            self.invalidUpdateSamples[self.phase, default: 0] += 1
        }
    }

    private func finish() {
        self.link?.invalidate()
        let window = WindowVisibility(view: self.view)
        let invalidCallbacks = self.visibility.values.reduce(0) { $0 + $1.invalidSamples }
        let result: [String: Any] = [
            "configuration": NativeOrbitPopupBenchmark.configuration,
            "renderScheduling": CommandLine.arguments.contains("--preview-performance-natural")
                ? "native" : "forcedSynchronousDisplay",
            "inspectionPhaseSeconds": CommandLine.arguments.contains("--preview-performance-steady") ? 4.0 : 1.2,
            "physicalHoverInspection": "ignored",
            "preparationMilliseconds": self.preparationMilliseconds,
            "dense": CommandLine.arguments.contains("--preview-dense"),
            "accounts": self.state.accounts.count,
            "screenMaximumFramesPerSecond": self.view?.window?.screen?.maximumFramesPerSecond ?? 0,
            "warningRaster": NativeOrbitWarningHDRRaster.performanceStatistics,
            "elapsedSeconds": CACurrentMediaTime() - self.started,
            "probeStartedAtUnixSeconds": Date().timeIntervalSince1970 - (CACurrentMediaTime() - self.started),
            "probeStartedUptimeSeconds": self.started,
            "phaseStartSeconds": self.phaseStarts,
            "synchronousUpdateWallTime": self.updateTimes.mapValues(Self.summary),
            "phasePreparationMilliseconds": self.phasePreparation,
            "windowVisible": window.windowVisible,
            "windowOcclusionVisible": window.occlusionVisible,
            "windowIsKeyWindow": window.isKeyWindow,
            "applicationIsActive": window.applicationActive,
            "windowLevel": window.level,
            "windowNumber": window.number,
            "foregroundValidityRequires": "owned window visible, unoccluded, on screen, and view not hidden",
            "benchmarkForegroundValid": self.preflightWasForeground && invalidCallbacks == 0
                && self.visibility.count == 8 && self.invalidUpdateSamples.values.allSatisfy { $0 == 0 },
            "visibilityPreflightMilliseconds": self.preflightMilliseconds,
            "visibilityPreflight": self.preflightVisibility,
            "phaseWindowVisibility": self.visibility.mapValues(\.json),
            "invalidForegroundCallbackSamples": invalidCallbacks,
            "invalidForegroundUpdateSamples": self.invalidUpdateSamples,
            "viewSize": NSStringFromSize(self.view?.bounds.size ?? .zero),
            "mainCallbackIntervals": self.intervals.mapValues(Self.cadenceSummary),
            "allObservedMainCallbackIntervals": self.allIntervals.mapValues(Self.cadenceSummary),
            "startupStageCallbackIntervals": self.startupIntervals.mapValues(Self.cadenceSummary),
            "startupEvents": self.state.startupEvents,
        ]
        let path = ProcessInfo.processInfo.environment["CODEXBAR_PERFORMANCE_OUTPUT"]
            ?? "/tmp/codexbar-offline-performance.json"
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        NSApp.terminate(nil)
    }

    private struct WindowVisibility {
        let windowVisible: Bool
        let occlusionVisible: Bool
        let isKeyWindow: Bool
        let applicationActive: Bool
        let viewVisible: Bool
        let hasScreen: Bool
        let level: Int
        let number: Int

        @MainActor init(view: NSView?) {
            let window = view?.window
            self.windowVisible = window?.isVisible ?? false
            self.occlusionVisible = window?.occlusionState.contains(.visible) ?? false
            self.isKeyWindow = window?.isKeyWindow ?? false
            self.applicationActive = NSApp.isActive
            self.viewVisible = view.map { !$0.isHiddenOrHasHiddenAncestor } ?? false
            self.hasScreen = window?.screen != nil
            self.level = window?.level.rawValue ?? 0
            self.number = window?.windowNumber ?? -1
        }

        var isForeground: Bool {
            self.windowVisible && self.occlusionVisible && self.viewVisible && self.hasScreen
        }

        var json: [String: Any] {
            [
                "windowVisible": self.windowVisible, "windowOcclusionVisible": self.occlusionVisible,
                "isKeyWindow": self.isKeyWindow, "applicationIsActive": self.applicationActive,
                "viewVisible": self.viewVisible, "hasScreen": self.hasScreen, "windowLevel": self.level,
                "windowNumber": self.number, "validForegroundSample": self.isForeground,
            ]
        }
    }

    private struct WindowVisibilityCounts {
        var samples = 0
        var visibleSamples = 0
        var unoccludedSamples = 0
        var keyWindowSamples = 0
        var activeApplicationSamples = 0
        var invalidSamples = 0
        var levels: [String: Int] = [:]
        var last: WindowVisibility?

        mutating func record(_ visibility: WindowVisibility) {
            self.samples += 1
            if visibility.windowVisible { self.visibleSamples += 1 }
            if visibility.occlusionVisible { self.unoccludedSamples += 1 }
            if visibility.isKeyWindow { self.keyWindowSamples += 1 }
            if visibility.applicationActive { self.activeApplicationSamples += 1 }
            if !visibility.isForeground { self.invalidSamples += 1 }
            self.levels[String(visibility.level), default: 0] += 1
            self.last = visibility
        }

        var json: [String: Any] {
            [
                "callbackSamples": self.samples, "windowVisibleSamples": self.visibleSamples,
                "windowUnoccludedSamples": self.unoccludedSamples,
                "windowOccludedOrMissingSamples": self.samples - self.unoccludedSamples,
                "keyWindowSamples": self.keyWindowSamples, "activeApplicationSamples": self.activeApplicationSamples,
                "invalidForegroundSamples": self.invalidSamples, "windowLevels": self.levels,
                "last": self.last?.json ?? [:],
            ]
        }
    }

    private static func cadenceSummary(_ samples: [Double]) -> [String: Double] {
        var result = Self.summary(samples)
        result.removeValue(forKey: "over120HzBudgetPercent")
        result["missed120HzRefreshPercent"] = samples.isEmpty ? 0
            : Double(samples.filter { $0 > 12.5 }.count) / Double(samples.count) * 100
        return result
    }

    private static func summary(_ samples: [Double]) -> [String: Double] {
        let sorted = samples.sorted()
        guard !sorted.isEmpty else { return [:] }
        return [
            "count": Double(sorted.count),
            "medianMilliseconds": sorted[sorted.count / 2],
            "p95Milliseconds": sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))],
            "maxMilliseconds": sorted.last ?? 0,
            "meanMilliseconds": sorted.reduce(0, +) / Double(sorted.count),
            "over120HzBudgetPercent": Double(sorted.filter { $0 > 1000 / 120 }.count) / Double(sorted.count) * 100,
        ]
    }
}
