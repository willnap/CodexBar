import AppKit
import QuartzCore
import SwiftUI

/// Offline diagnostics for the production combined popup. No provider stores, screen capture or desktop events.
enum NativeCombinedRangeTiming {
    static let enabled = CommandLine.arguments.contains("--preview-range-check")

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var started: CFTimeInterval = 0
        var counts: [String: Int] = [:]
        var durations: [String: Double] = [:]
        var first: [String: Double] = [:]
    }

    private static let state = State()

    static func begin() -> CFTimeInterval { self.enabled ? CACurrentMediaTime() : 0 }

    static func end(_ name: String, since start: CFTimeInterval) {
        guard self.enabled, start > 0 else { return }
        let now = CACurrentMediaTime()
        self.state.lock.withLock {
            self.state.counts[name, default: 0] += 1
            self.state.durations[name, default: 0] += (now - start) * 1000
            if self.state.started > 0, self.state.first[name] == nil {
                self.state.first[name] = (now - self.state.started) * 1000
            }
        }
    }

    static func reset() {
        self.state.lock.withLock {
            self.state.started = CACurrentMediaTime()
            self.state.counts = [:]
            self.state.durations = [:]
            self.state.first = [:]
        }
    }

    static func snapshot() -> [String: Any] {
        self.state.lock.withLock {
            ["counts": self.state.counts, "durationMS": self.state.durations, "firstMS": self.state.first]
        }
    }
}

@MainActor
enum NativeCombinedRangeProbe {
    static func run(view: NSView, toolbar: NativeOrbitPopupState, directory: URL) async {
        // Match popoverDidShow: the production pager warms every account page after appearing.
        try? await Task.sleep(for: .seconds(4))
        var results: [[String: Any]] = []
        for days in [7, 30, 1, 30, 7, 1] {
            guard let target = self.accountPlots(view).first,
                  let before = self.pixels(target) else { break }
            NativeCombinedRangeTiming.reset()
            let start = CACurrentMediaTime()
            let index = NativeOrbitRangeControl.ranges.firstIndex(of: days) ?? 0
            let width: CGFloat = toolbar.layoutColumns > 1 ? 180 : 102
            let x = view.bounds.midX + CGFloat(index - 1) * (width - 4) / 3
            let delivered = NativeOrbitPopupBenchmark.click(view, fromLeading: x)
            let handlerMS = (CACurrentMediaTime() - start) * 1000
            var firstChange: Double?
            for _ in 0..<100 {
                try? await Task.sleep(for: .milliseconds(8))
                if let after = self.pixels(target), self.changed(before, after) {
                    firstChange = (CACurrentMediaTime() - start) * 1000
                    break
                }
            }
            results.append([
                "days": days, "selectedDays": toolbar.days, "delivered": delivered,
                "handlerMS": handlerMS, "firstGeometryChangeMS": firstChange ?? -1,
                "foreground": view.window?.occlusionState.contains(.visible) == true,
                "visibleAccountPlots": self.accountPlots(view).count,
                "timing": NativeCombinedRangeTiming.snapshot(),
            ])
            try? await Task.sleep(for: .milliseconds(600))
        }
        self.write(results, to: directory)
        NSApp.terminate(nil)
    }

    private static func accountPlots(_ root: NSView) -> [NSView] {
        func leaves(_ view: NSView) -> [NSView] {
            let children = view.subviews.flatMap(leaves)
            if !children.isEmpty { return children }
            guard view is NSHostingView<AnyView>, view.bounds.width > 150,
                  view.bounds.width < 225, view.bounds.height > 150, view.bounds.height < 225 else { return [] }
            return [view]
        }
        return leaves(root).filter {
            let rect = $0.convert($0.bounds, to: root)
            return rect.minX > NativeCombinedPopupView.pageWidth
                && rect.intersection(root.bounds).width > 150
        }.sorted { $0.convert($0.bounds, to: root).minX < $1.convert($1.bounds, to: root).minX }
    }

    private static func pixels(_ view: NSView) -> [UInt8]? {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard !bitmap.isPlanar, let bytes = bitmap.bitmapData else { return nil }
        return Array(UnsafeBufferPointer(start: bytes, count: bitmap.bytesPerRow * bitmap.pixelsHigh))
    }

    private static func changed(_ before: [UInt8], _ after: [UInt8]) -> Bool {
        guard before.count == after.count else { return true }
        var changed = 0
        for index in stride(from: 0, to: before.count, by: 4) {
            if abs(Int(before[index]) - Int(after[index])) > 16 { changed += 1 }
            if changed > 50 { return true }
        }
        return false
    }

    private static func write(_ results: [[String: Any]], to directory: URL) {
        let result: [String: Any] = [
            "configuration": NativeOrbitPopupBenchmark.configuration,
            "checks": results,
            "passed": results.count == 6 && results.allSatisfy {
                ($0["firstGeometryChangeMS"] as? Double ?? -1) > 0
                    && $0["selectedDays"] as? Int == $0["days"] as? Int
                    && $0["foreground"] as? Bool == true
            },
        ]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("range-check.json"))
        }
    }
}
