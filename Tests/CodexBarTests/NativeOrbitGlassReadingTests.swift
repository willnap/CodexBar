import Foundation
import SwiftUI
import Testing
@testable import CodexBar
@testable import CodexBarCore

/// Checks the value-dependent shape actually supplied to native glass, rather than a separate clipping mask.
@MainActor
struct NativeOrbitGlassReadingTests {
    private let rect = CGRect(x: 0, y: 0, width: 256, height: 256)

    @Test func `native usage glass receives actual live and settled account fractions`() {
        for remaining in [0.0, 0.25, 0.65, 1] {
            for phase in [NativeOrbitStartupPhase.live, .settling, .reduced] {
                let window = UsageWindow(id: "session", label: "Session", period: 18000, used: 1 - remaining)
                for lane in 0...2 {
                    let glass = self.symbol(window, phase: phase, lane: lane).usageGlass
                    #expect(abs(glass.usageSilhouette.remaining - remaining) < 0.000001)
                    let expected = NativeOrbitArtworkShape(lane: lane, remaining: remaining).path(in: self.rect)
                    #expect(glass.usageSilhouette.path(in: self.rect) == expected)
                    if remaining < 1 {
                        #expect(glass.usageSilhouette.path(in: self.rect)
                            != NativeOrbitArtworkShape(lane: lane).path(in: self.rect))
                    }
                }
            }
        }
    }

    @Test func `native glass presentation interpolation updates its actual silhouette`() {
        let window = UsageWindow(id: "session", label: "Session", period: 18000, used: 0.75)
        var glass = self.symbol(window, phase: .live).usageGlass
        for presentation in [0.0, 0.25, 0.65, 1] {
            glass.animatableData = presentation
            #expect(glass.usageSilhouette.remaining == presentation)
            #expect(glass.usageSilhouette.path(in: self.rect)
                == NativeOrbitArtworkShape(lane: 0, remaining: presentation).path(in: self.rect))
        }
    }

    @Test func `switched providers keep nonfull native glass through startup and inspection`() async throws {
        let state = NativeOrbitPopupState()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        state.now = now
        // Rendered lanes follow resolvedWindows: longest period first, regardless of provider input order.
        let fixtures: [(UsageProvider, [Double], [Double], [Double])] = [
            (.codex, [0.4, 0.7], [0.6, 0.8], [0.37, 0.67]),
            (.claude, [0.25, 0.55], [0.5, 0.85], [0.2125, 0.505]),
        ]
        for (provider, live, historical, future) in fixtures {
            let id = provider.rawValue + "-glass-fixture"
            let account = self.account(provider: provider, id: id, now: now)
            // Replacing the account exercises the same preparation/cache invalidation used by a provider switch.
            state.accounts = [account]
            #expect(state.accounts.first?.id == id)
            #expect(state.accounts.first?.gauge.provider == provider.rawValue)
            state.armStartup(reduceMotion: false, pointerLocation: .zero)
            self.expectNativeReadings(state, expected: [0, 0])
            let running = Task { @MainActor in await state.runStartup() }
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(1))
            while state.startup == .armed, clock.now < deadline {
                await Task.yield()
            }
            #expect(state.startup == .sweeping)
            self.expectNativeReadings(state, expected: [1, 1])
            await running.value
            #expect(state.startup == .live)
            self.expectNativeReadings(state, expected: live)
            state.startup = .settling
            self.expectNativeReadings(state, expected: live)
            state.finishStartup()
            #expect(state.isProjecting)
            state.inspectionDate = now.addingTimeInterval(-600)
            self.expectNativeReadings(state, expected: historical)
            state.inspectionDate = now.addingTimeInterval(1080)
            self.expectNativeReadings(state, expected: future)
            state.inspectionDate = nil
            self.expectNativeReadings(state, expected: live)
            #expect(try #require(state.accounts.first).gauge.windows == account.gauge.windows)
        }
    }

    @Test func `missing and nonfinite readings never become full native glass in live phase`() {
        for reading: Double? in [nil, .nan, .infinity, -.infinity] {
            let symbol = NativeOrbitSymbol(remaining: reading, countdown: nil, segments: 12, lane: 0)
            #expect(symbol.usageGlass.usageSilhouette.remaining == 0)
            #expect(symbol.usageGlass.usageSilhouette.path(in: self.rect).isEmpty)
        }
    }

    private func account(provider: UsageProvider, id: String, now: Date) -> NativeOrbitAccountPresentation {
        let codex = provider == .codex
        let ids = codex ? ["session", "weekly"] : ["primary", "secondary"]
        let past = codex ? [20.0, 40] : [15.0, 50]
        let live = codex ? [30.0, 60] : [45.0, 75]
        let periods: [TimeInterval] = [18000, 604_800]
        // Session is three hours into its window; weekly is six hours in. Eighteen minutes ahead adds
        // 10% and 5% of their respective current usage, without crossing either reset.
        let elapsed: [TimeInterval] = [10800, 21600]
        let histories = periods.enumerated().map { index, period in
            PlanUtilizationSeriesHistory(
                name: PlanUtilizationSeriesName(rawValue: "nativeQuota:" + (index == 0 ? "primary" : "secondary")),
                windowMinutes: Int(period / 60),
                entries: [
                    .init(
                        capturedAt: now.addingTimeInterval(-600),
                        usedPercent: past[index],
                        resetsAt: now.addingTimeInterval(period - elapsed[index])),
                    .init(
                        capturedAt: now,
                        usedPercent: live[index],
                        resetsAt: now.addingTimeInterval(period - elapsed[index])),
                ])
        }
        var gauge = ComputeGauge.State()
        gauge.provider = provider.rawValue
        gauge.windows = periods.enumerated().map { index, period in
            UsageWindow(id: ids[index], label: ids[index], period: period, used: live[index] / 100)
        }
        return .init(
            id: id,
            label: id,
            email: nil,
            symbol: "person",
            isActive: true,
            canActivate: false,
            gauge: gauge,
            updatedAt: now,
            history: histories,
            odometer: nil,
            odometerHelp: nil,
            statusText: nil,
            selection: .none)
    }

    private func expectNativeReadings(_ state: NativeOrbitPopupState, expected: [Double]) {
        guard let account = state.accounts.first else { Issue.record("Missing fixture account"); return }
        let windows = NativeOrbitHistoricalInspection.windows(
            account: account,
            date: state.inspectionDate,
            now: state.now,
            days: state.days,
            preparedLanes: state.renderLanes(for: account),
            projection: state.projection(for: account),
            isProjecting: state.isProjecting)
        #expect(windows.count == expected.count)
        for (lane, pair) in zip(windows, expected).enumerated() {
            let glass = self.symbol(pair.0, phase: state.startup, lane: lane).usageGlass
            let actual = glass.usageSilhouette.remaining
            #expect(abs(actual - pair.1) < 0.000001)
            #expect(glass.usageSilhouette.path(in: self.rect)
                == NativeOrbitArtworkShape(lane: lane, remaining: actual).path(in: self.rect))
            if pair.1 > 0, pair.1 < 1 {
                #expect(glass.usageSilhouette.path(in: self.rect)
                    != NativeOrbitArtworkShape(lane: lane).path(in: self.rect))
                #expect(!glass.usageSilhouette.path(in: self.rect).isEmpty)
            }
        }
    }

    private func symbol(
        _ window: UsageWindow,
        phase: NativeOrbitStartupPhase,
        lane: Int = 0) -> NativeOrbitSymbol
    {
        NativeOrbitSymbol(
            remaining: window.usedFraction.map { 1 - $0 },
            countdown: nil,
            segments: 12,
            lane: lane,
            startup: phase)
    }
}
