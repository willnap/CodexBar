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

    /// Opt-in (`--native-popup-refresh-probe` with `--native-popup-preview-provider`); see `NativeOrbitRefreshProbe`.
    static func runRefreshProbeIfRequested(
        controller: NativeServicePopoverController,
        store: UsageStore,
        provider: UsageProvider,
        popover: NSPopover?,
        reopenPopup: @escaping @MainActor () -> Void = {}) async
    {
        guard CommandLine.arguments.contains("--native-popup-refresh-probe") else { return }
        await NativeOrbitRefreshProbe.run(
            controller: controller,
            store: store,
            provider: provider,
            popover: popover,
            reopenPopup: reopenPopup)
    }

    /// Delivers a click to the toolbar row at `fromLeading` points from the leading edge (negative: from the
    /// trailing edge), without moving the pointer.
    static func click(_ view: NSView, fromLeading offset: CGFloat) -> Bool {
        guard let window = view.window else { return false }
        let location = self.clickLocation(view, fromLeading: offset)
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

    /// The window location `click` uses, in the toolbar row 24 pt above the view's bottom edge.
    static func clickLocation(_ view: NSView, fromLeading offset: CGFloat) -> NSPoint {
        let fromBottom: CGFloat = 24
        let local = NSPoint(
            x: offset >= 0 ? offset : view.bounds.maxX + offset,
            y: view.isFlipped ? view.bounds.maxY - fromBottom : fromBottom)
        return view.convert(local, to: nil)
    }

    static var configuration: String {
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
