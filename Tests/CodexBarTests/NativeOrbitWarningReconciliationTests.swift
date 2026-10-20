import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct NativeOrbitWarningReconciliationTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func `an unused allowance does not advertise a pace opportunity`() {
        let lights = self.lights(windows: [self.window(0, reset: 9000)])
        #expect(lights.isEmpty)
    }

    @Test func `the fuel light says how much of the window is left`() {
        for (minutes, used, expected) in [
            (43200, 96.0, "Monthly limit: 4% left."),
            (10080, 90, "Weekly limit: 10% left."),
            (300, 95, "Session limit: 5% left."),
        ] {
            let snapshot = UsageSnapshot(
                primary: .init(
                    usedPercent: used,
                    windowMinutes: minutes,
                    resetsAt: self.now.addingTimeInterval(3600),
                    resetDescription: nil),
                secondary: nil,
                updatedAt: self.now)
            let lights = NativeOrbitWarningSignals.account(
                provider: .claude, snapshot: snapshot, metrics: .empty, history: [], now: self.now)
            #expect(lights.first { $0.kind == .limit && $0.severity == .caution }?.tooltip(account: "Work") == expected)
        }
    }

    @Test func `an elapsed reset invalidates a pre-reset exhausted reading`() {
        let snapshot = UsageSnapshot(
            primary: self.window(100, reset: -60), secondary: nil, updatedAt: self.now.addingTimeInterval(-120))
        let lights = NativeOrbitWarningSignals.account(
            provider: .claude, snapshot: snapshot, metrics: .empty, history: [], now: self.now)
        #expect(lights.isEmpty)
    }

    @Test func `old quota evidence does not claim current exhaustion or pace`() {
        let snapshot = UsageSnapshot(
            primary: self.window(100, reset: 9000), secondary: nil, updatedAt: self.now.addingTimeInterval(-7200))
        #expect(NativeOrbitWarningSignals.account(
            provider: .claude, snapshot: snapshot, metrics: .empty, history: [], now: self.now).isEmpty)
    }

    @Test func `the fuel light is the allowance left while the hare and flame report pace`() {
        func kinds(
            _ used: Double,
            untilReset: TimeInterval,
            reserve: NativeOrbitWarningSignals.FuelReserve = .standard) -> Set<NativeOrbitWarningLight.Kind>
        {
            let snapshot = UsageSnapshot(
                primary: nil,
                secondary: RateWindow(
                    usedPercent: used,
                    windowMinutes: 10080,
                    resetsAt: self.now.addingTimeInterval(untilReset),
                    resetDescription: nil),
                updatedAt: self.now)
            return Set(NativeOrbitWarningSignals.account(
                provider: .codex,
                snapshot: snapshot,
                metrics: .empty,
                history: [],
                now: self.now,
                fuelReserve: reserve).map(\.kind))
        }
        // Four hours into the week and a hair above even: noise.
        #expect(kinds(2.62, untilReset: 163.85 * 3600).isEmpty)
        // A third of the week used six hours in: burning fast with two thirds of the tank left.
        #expect(kinds(33, untilReset: 7 * 86400 - 6 * 3600) == [.farAheadPace])
        #expect(kinds(60, untilReset: 4 * 86400) == [.farAheadPace])
        #expect(kinds(50, untilReset: 3.5 * 86400 + 6 * 3600) == [.aheadOfPace])
        // At or below the lowest quota warning threshold (20% by default): fuel alone, whatever the pace.
        #expect(kinds(81, untilReset: 6.5 * 86400) == [.limit])
        #expect(kinds(90, untilReset: 30 * 3600) == [.limit])
        #expect(kinds(55, untilReset: 2 * 86400, reserve: .init(session: 20, weekly: 50)) == [.limit])
        #expect(NativeOrbitWarningSignals.FuelReserve(thresholds: [50, 20], weekly: [0]).weekly == 20)
        #expect(NativeOrbitWarningSignals.FuelReserve(thresholds: [60, 30], weekly: [40]) == .init(
            session: 30, weekly: 40))
    }

    @Test func `a lit fuel light replaces the pace lamps`() {
        let lights = self.lights(windows: [self.window(5, reset: 9000), self.window(80, reset: 9000)])
        #expect(lights.contains { $0.kind == .limit && $0.severity == .caution })
        #expect(Set(lights.map(\.kind)).isDisjoint(with: [.behindPace, .aheadOfPace, .farAheadPace]))
    }

    @Test func `exhaustion suppresses slower usage encouragement`() {
        let lights = self.lights(windows: [self.window(100, reset: 9000), self.window(5, reset: 9000)])
        #expect(lights.contains { $0.kind == .limit && $0.severity == .critical })
        #expect(!lights.contains { [.behindPace, .aheadOfPace, .farAheadPace, .idle].contains($0.kind) })
    }

    @Test func `invalid and future money observations cannot establish empty credits or a spend cap`() {
        for value in [Double.nan, .infinity] {
            var metrics = NativeOrbitAccountMetrics.empty
            metrics.reportedBalance = .init(value: value, unit: "USD", isWorkspace: false, updatedAt: self.now)
            #expect(self.money(metrics).isEmpty)
        }
        var future = NativeOrbitAccountMetrics.empty
        future.reportedBalance = .init(
            value: 0,
            unit: "USD",
            isWorkspace: false,
            updatedAt: self.now.addingTimeInterval(60))
        future.reportedSpend = .init(
            used: 10,
            limit: 10,
            currencyCode: "USD",
            period: "Monthly",
            updatedAt: self.now.addingTimeInterval(60))
        #expect(self.money(future).isEmpty)
    }

    @Test func `an ended spend cycle cannot keep its old cap warning`() {
        var metrics = NativeOrbitAccountMetrics.empty
        metrics.reportedSpend = .init(
            used: 10,
            limit: 10,
            currencyCode: "USD",
            period: "Monthly",
            resetsAt: self.now.addingTimeInterval(-60),
            updatedAt: self.now.addingTimeInterval(-120))
        #expect(self.money(metrics).isEmpty)
    }

    @Test func `a critical cap is not replaced by a lower severity spend forecast`() {
        let history = [PlanUtilizationSeriesHistory(name: "nativeMetric:spend", windowMinutes: 0, entries: [
            .init(
                capturedAt: self.now.addingTimeInterval(-600),
                usedPercent: 0,
                resetsAt: nil,
                nativeMetrics: .init(spend: .init(
                    used: 5,
                    limit: 10,
                    currencyCode: "USD",
                    period: "Monthly",
                    resetsAt: self.now.addingTimeInterval(3600),
                    updatedAt: self.now.addingTimeInterval(-600)))),
        ])]
        var metrics = NativeOrbitAccountMetrics.empty
        metrics.reportedSpend = .init(
            used: 10,
            limit: 10,
            currencyCode: "USD",
            period: "Monthly",
            resetsAt: self.now.addingTimeInterval(3600),
            updatedAt: self.now)
        let lights = NativeOrbitWarningSignals.account(
            provider: .claude,
            snapshot: nil,
            metrics: metrics,
            history: history,
            now: self.now)
        #expect(lights.first { $0.kind == .spend }?.severity == .critical)
        #expect(lights.first { $0.kind == .spend }?.tooltip(account: nil) == "Spending cap reached.")
    }

    private func window(_ used: Double, reset: TimeInterval) -> RateWindow {
        .init(
            usedPercent: used,
            windowMinutes: 300,
            resetsAt: self.now.addingTimeInterval(reset),
            resetDescription: nil)
    }

    private func lights(windows: [RateWindow]) -> [NativeOrbitWarningLight] {
        let snapshot = UsageSnapshot(primary: windows.first, secondary: windows.dropFirst().first, updatedAt: self.now)
        return NativeOrbitWarningSignals.account(
            provider: .claude,
            snapshot: snapshot,
            metrics: .empty,
            history: [],
            now: self.now)
    }

    private func money(_ metrics: NativeOrbitAccountMetrics) -> [NativeOrbitWarningLight] {
        NativeOrbitWarningSignals.account(
            provider: .claude,
            snapshot: nil,
            metrics: metrics,
            history: [],
            now: self.now)
    }
}
