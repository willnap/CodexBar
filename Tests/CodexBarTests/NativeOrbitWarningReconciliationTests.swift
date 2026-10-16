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

    @Test func `forecast delays use readable days hours and minutes rather than large minute counts`() {
        for (minutes, used, reset, expected) in [
            (10080, 60.0, 4.0 * 86400, "2d"),
            (300, 60, 9000, "1h 40m"),
            (300, 95, 9000, "8m"),
        ] {
            let snapshot = UsageSnapshot(
                primary: .init(
                    usedPercent: used,
                    windowMinutes: minutes,
                    resetsAt: self.now.addingTimeInterval(reset),
                    resetDescription: nil),
                secondary: nil,
                updatedAt: self.now)
            let lights = NativeOrbitWarningSignals.account(
                provider: .claude, snapshot: snapshot, metrics: .empty, history: [], now: self.now)
            let forecast = lights.first { $0.kind == .limit && $0.severity == .caution }
            #expect(forecast?.detail.contains("in \(expected).") == true)
            #expect(forecast?.detail.contains(" min") == false)
            let title = minutes == 10080 ? "Weekly limit" : "Session limit"
            #expect(forecast?.tooltip(account: "Work") == "\(title) may run out in \(expected).")
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

    @Test func `run-out timing replaces conflicting or redundant pace lamps`() {
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
