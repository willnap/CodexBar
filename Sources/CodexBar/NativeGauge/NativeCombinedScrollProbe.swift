import AppKit
import CodexBarCore
import QuartzCore

/// Opt-in (`CODEXBAR_SCROLL_PROBE=1`) frame pacing of the combined popup's page scroll: display-link callback
/// intervals while the pages move, and how many pages appeared during that scroll. One log line per scroll.
@MainActor
final class NativeCombinedScrollProbe: NSObject {
    static let shared: NativeCombinedScrollProbe? =
        ProcessInfo.processInfo.environment["CODEXBAR_SCROLL_PROBE"] == "1" ? NativeCombinedScrollProbe() : nil

    private var link: CADisplayLink?
    private var previous: CFTimeInterval?
    private var nominal: CFTimeInterval = 1.0 / 60
    private var intervals: [CFTimeInterval] = []
    private var appearances = 0

    func scrolling(_ moving: Bool) {
        if moving {
            guard self.link == nil, let screen = NSScreen.main else { return }
            self.intervals = []
            self.appearances = 0
            self.previous = nil
            let link = screen.displayLink(target: self, selector: #selector(self.tick(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        } else {
            self.link?.invalidate()
            self.link = nil
            self.report()
        }
    }

    func pageAppeared() {
        if self.link != nil { self.appearances += 1 }
    }

    @objc private func tick(_ link: CADisplayLink) {
        self.nominal = max(1.0 / 240, link.targetTimestamp - link.timestamp)
        if let previous { self.intervals.append(link.timestamp - previous) }
        self.previous = link.timestamp
    }

    private func report() {
        guard !self.intervals.isEmpty else { return }
        let sorted = self.intervals.sorted()
        let milliseconds = { (value: CFTimeInterval) in String(format: "%.1f", value * 1000) }
        let late = self.intervals.filter { $0 > self.nominal * 1.5 }
        let missed = late.reduce(0) { $0 + Int(($1 / self.nominal).rounded()) - 1 }
        CodexBarLog.logger("native-gauges").info(
            "Combined scroll frames",
            metadata: [
                "frames": String(self.intervals.count),
                "nominalMilliseconds": milliseconds(self.nominal),
                "medianMilliseconds": milliseconds(sorted[sorted.count / 2]),
                "maxMilliseconds": milliseconds(sorted.last ?? 0),
                "lateFrames": String(late.count),
                "missedFrames": String(missed),
                "pagesAppeared": String(self.appearances),
            ])
    }
}
