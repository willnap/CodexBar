import AppKit
import Charts
import SwiftUI
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
@Suite(.serialized)
struct NativeOrbitProgressiveBlurTests {
    @Observable final class Position {
        var value = 0.0
    }

    private struct PlotPoint {
        let x: Double
        let y: Double
    }

    private struct AnimatedFixture: View {
        let position: Position
        let blurred: Bool

        private var chart: some View {
            Chart {
                LinePlot(
                    [PlotPoint(x: 0.8, y: 20), PlotPoint(x: 0.8, y: 80)],
                    x: .value("x", \.x),
                    y: .value("y", \.y))
            }
            .foregroundStyle(.red)
            .chartXScale(domain: 0...(1 + self.position.value)).chartYScale(domain: 0...100)
            .chartXAxis(.hidden).chartYAxis(.hidden).chartLegend(.hidden)
        }

        var body: some View {
            Group {
                if self.blurred {
                    NativeOrbitProgressiveBlur(start: 0.5, radii: [0, 1, 2, 3]) { self.chart }
                } else {
                    self.chart
                }
            }
            .animation(.linear(duration: 0.3), value: self.position.value)
        }
    }

    private struct ForecastFixture: View {
        let position: Position
        var nativeHost = false
        var changesRange = false
        private let now = Date(timeIntervalSince1970: 1_800_014_400)

        var body: some View {
            let history = PlanUtilizationSeriesHistory(name: "nativeQuota:primary", windowMinutes: 300, entries: [
                .init(capturedAt: self.now.addingTimeInterval(-600), usedPercent: 20, resetsAt: nil),
                .init(capturedAt: self.now, usedPercent: 20, resetsAt: nil),
            ])
            let projection = NativeOrbitAccountProjection(
                now: self.now,
                end: self.now.addingTimeInterval(30 * 86400),
                lastActivity: self.now,
                lanes: [.init(
                    id: "nativeQuota:primary",
                    origin: self.now,
                    originUsed: self.changesRange ? 60 : 20 + self.position.value * 60,
                    rate: 0,
                    rateSource: .idle,
                    period: nil,
                    reset: self.changesRange ? self.now.addingTimeInterval(18 * 3600) : nil,
                    lineStart: self.now)],
                events: [],
                tokenRate: nil,
                costRate: nil,
                periodSummary: .init(),
                resetInventory: nil,
                liveMetrics: .empty)
            let widget = NativeOrbitHistoryWidget(
                histories: [history],
                now: self.now,
                days: self.changesRange && self.position.value > 0 ? 7 : 1,
                accent: .red,
                projection: projection,
                isProjecting: true,
                dataDays: 30)
            Group {
                if self.nativeHost {
                    widget
                } else {
                    widget.renderedChart(widget.lanes).frame(width: 224, height: 224)
                }
            }
            .environment(\.colorScheme, .light)
        }
    }

    @Test(arguments: [false, true])
    func `forecast updates animate when recorded sample counts stay unchanged`(nativeHost: Bool) async throws {
        let position = Position()
        let host = NSHostingView(rootView: ForecastFixture(position: position, nativeHost: nativeHost))
        let window = NSWindow(
            contentRect: CGRect(x: -10000, y: -10000, width: 224, height: 224),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(300))
        func innermostPlot(_ view: NSView) -> NSHostingView<AnyView>? {
            view.subviews.compactMap { innermostPlot($0) }.last ?? (view as? NSHostingView<AnyView>)
        }
        let target: NSView = nativeHost ? try #require(innermostPlot(host)) : host
        #expect(target.bounds.width > 100 && target.bounds.height > 100)
        var captureIndex = 0
        func centroid() throws -> Double {
            let bitmap = try #require(target.bitmapImageRepForCachingDisplay(in: target.bounds))
            target.cacheDisplay(in: target.bounds, to: bitmap)
            if let directory = ProcessInfo.processInfo.environment["CODEXBAR_FORECAST_PROOF_DIR"] {
                let root = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try bitmap.representation(using: .png, properties: [:])?
                    .write(to: root.appendingPathComponent("forecast-native-\(nativeHost)-\(captureIndex).png"))
                captureIndex += 1
            }
            var total = 0.0
            var count = 0.0
            let scale = Double(bitmap.pixelsWide) / target.bounds.width
            for y in Int(0.08 * Double(bitmap.pixelsHigh))..<Int(0.9 * Double(bitmap.pixelsHigh)) {
                for x in Int(0.65 * Double(bitmap.pixelsWide))..<Int(0.9 * Double(bitmap.pixelsWide)) {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                          abs(color.redComponent - color.greenComponent) < 0.05,
                          color.alphaComponent > 0.2 else { continue }
                    total += Double(y) / scale
                    count += 1
                }
            }
            #expect(count > 10)
            return total / max(1, count)
        }
        let before = try centroid()
        position.value = 1
        try await Task.sleep(for: .milliseconds(120))
        let during = try centroid()
        try await Task.sleep(for: .milliseconds(400))
        let after = try centroid()
        #expect(
            abs(after - before) > 0.18 * target.bounds.height,
            "native \(nativeHost), before \(before), during \(during), after \(after)")
        if nativeHost { #expect(innermostPlot(host) === target) }
        #expect(
            abs(during - before) > 5 && abs(during - after) > 5,
            "before \(before), during \(during), after \(after)")
    }

    @Test(arguments: [false, true])
    func `forecast range changes animate through the native chart hosts`(nativeHost: Bool) async throws {
        let position = Position()
        let host = NSHostingView(rootView: ForecastFixture(
            position: position, nativeHost: nativeHost, changesRange: true))
        let window = NSWindow(
            contentRect: CGRect(x: -10000, y: -10000, width: 224, height: 224),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(300))
        func innermostPlot(_ view: NSView) -> NSHostingView<AnyView>? {
            view.subviews.compactMap { innermostPlot($0) }.last ?? (view as? NSHostingView<AnyView>)
        }
        let target: NSView = nativeHost ? try #require(innermostPlot(host)) : host
        func centroid() throws -> Double {
            let bitmap = try #require(target.bitmapImageRepForCachingDisplay(in: target.bounds))
            target.cacheDisplay(in: target.bounds, to: bitmap)
            var total = 0.0
            var count = 0.0
            let scale = Double(bitmap.pixelsWide) / target.bounds.width
            for y in Int(0.2 * Double(bitmap.pixelsHigh))..<Int(0.4 * Double(bitmap.pixelsHigh)) {
                for x in Int(0.505 * Double(bitmap.pixelsWide))..<Int(0.98 * Double(bitmap.pixelsWide)) {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                          abs(color.redComponent - color.greenComponent) < 0.05,
                          color.alphaComponent > 0.1 else { continue }
                    total += Double(x) / scale
                    count += 1
                }
            }
            #expect(count > 5)
            return total / max(1, count)
        }
        let before = try centroid()
        position.value = 1
        try await Task.sleep(for: .milliseconds(120))
        let during = try centroid()
        try await Task.sleep(for: .milliseconds(400))
        let after = try centroid()
        #expect(
            abs(after - before) > 20,
            "native \(nativeHost), before \(before), during \(during), after \(after)")
        #expect(
            abs(during - before) > 3 && abs(during - after) > 3,
            "native \(nativeHost), before \(before), during \(during), after \(after)")
        if nativeHost { #expect(innermostPlot(host) === target) }
    }

    @Test(arguments: [false, true])
    func `blurred charts paint intermediate line positions`(blurred: Bool) async throws {
        let position = Position()
        let host = NSHostingView(rootView: AnimatedFixture(position: position, blurred: blurred))
        let window = NSWindow(
            contentRect: CGRect(x: -10000, y: -10000, width: 200, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(100))
        func centroid() throws -> Double {
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            var total = 0.0
            var count = 0.0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                          color.redComponent > 0.6, color.greenComponent < 0.5,
                          color.alphaComponent > 0.1 else { continue }
                    total += Double(x)
                    count += 1
                }
            }
            #expect(count > 20)
            return total / max(1, count)
        }
        let before = try centroid()
        position.value = 1
        try await Task.sleep(for: .milliseconds(120))
        let during = try centroid()
        try await Task.sleep(for: .milliseconds(400))
        let after = try centroid()
        #expect(abs(after - before) > 20, "before \(before), during \(during), after \(after)")
        #expect(
            abs(during - before) > 3 && abs(during - after) > 3,
            "before \(before), during \(during), after \(after)")
    }
}
