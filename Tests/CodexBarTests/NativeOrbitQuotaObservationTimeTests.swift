import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct NativeOrbitQuotaObservationTimeTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func `waiting after a pre-grace receipt cannot prove a late reset`() {
        let reset = self.now.addingTimeInterval(-720)
        let measured = reset.addingTimeInterval(60)
        let account = self.account(measured: measured, reset: reset)
        let snapshot = UsageSnapshot(primary: self.window(reset: reset), secondary: nil, updatedAt: measured)
        let direct = NativeOrbitWarningSignals.account(
            provider: .claude, snapshot: snapshot, metrics: .empty, history: [], now: self.now)
        #expect(!direct.contains { $0.kind == .resetLate })
        #expect(!self.lights(account).contains { $0.kind == .resetLate })
        #expect(self.lights(account).contains { $0.kind == .limit && $0.severity == .critical })
    }

    @Test func `a real exhausted receipt after the reset grace period still proves lateness`() {
        let reset = self.now.addingTimeInterval(-720)
        let account = self.account(measured: self.now, reset: reset)
        #expect(self.lights(account).contains { $0.kind == .resetLate })
    }

    @Test func `historical interpolation never advances the observation used to prove a late reset`() {
        let measured = self.now.addingTimeInterval(-1800)
        let reset = measured.addingTimeInterval(-60)
        let history = [PlanUtilizationSeriesHistory(name: "nativeQuota:primary", windowMinutes: 300, entries: [
            .init(capturedAt: measured, usedPercent: 100, resetsAt: reset),
            .init(capturedAt: self.now.addingTimeInterval(-900), usedPercent: 100, resetsAt: reset),
        ])]
        let account = self.account(measured: self.now, reset: reset, history: history)
        let date = measured.addingTimeInterval(660)
        #expect(!self.lights(account, date: date).contains { $0.kind == .resetLate })
        #expect(self.lights(account, date: date).contains { $0.kind == .limit && $0.severity == .critical })
    }

    private func window(reset: Date) -> RateWindow {
        .init(usedPercent: 100, windowMinutes: 300, resetsAt: reset, resetDescription: nil)
    }

    private func account(
        measured: Date, reset: Date, history: [PlanUtilizationSeriesHistory] = []) -> NativeOrbitAccountPresentation
    {
        var gauge = ComputeGauge.State()
        gauge.provider = "claude"
        gauge.windows = [.init(
            id: "primary",
            label: "Session",
            period: 18000,
            used: 1,
            countdown: .init(units: 5, secondsPerUnit: 3600, nextReset: reset))]
        return .init(
            id: "fixture",
            label: "Fixture",
            email: nil,
            symbol: "person",
            isActive: true,
            canActivate: false,
            gauge: gauge,
            updatedAt: measured,
            history: history,
            odometer: nil,
            odometerHelp: nil,
            statusText: nil,
            selection: .none)
    }

    private func lights(
        _ account: NativeOrbitAccountPresentation, date: Date? = nil) -> [NativeOrbitWarningLight]
    {
        let projection = NativeOrbitAccountProjection(
            now: self.now,
            end: self.now.addingTimeInterval(86400),
            lastActivity: nil,
            lanes: [],
            events: [],
            tokenRate: nil,
            costRate: nil,
            periodSummary: .init(),
            resetInventory: nil,
            liveMetrics: .empty)
        return NativeOrbitWarningEvaluation.lights(
            account: account, peers: [account], projection: projection, date: date, now: self.now, days: 1)
    }
}
