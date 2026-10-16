import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct NativeOrbitHiddenHistoryTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var past: Date {
        self.now.addingTimeInterval(-300)
    }

    @Test func `a closed Claude session remains inspectable while the live gauge shows only weekly usage`() {
        let account = self.account(history: [self.quota("primary", used: 100, minutes: 300)])
        let windows = self.windows(account, date: self.past)
        #expect(windows.first { $0.id == "primary" }?.usedFraction == 1)
        #expect(windows.first { $0.id == "primary" }?.period == 18000)
        #expect(self.lights(account, date: self.past).contains { $0.kind == .limit && $0.severity == .critical })
    }

    @Test func `a removed model allowance retains its own recorded amount identity and duration`() {
        let id = "claude-weekly-scoped-fable"
        var account = self.account(history: [self.quota(id, used: 100, minutes: 10080)])
        account.quotaLabels["nativeQuota:" + id] = "Fable"
        let windows = self.windows(account, date: self.past)
        #expect(windows.first { $0.id == id }?.usedFraction == 1)
        #expect(windows.first { $0.id == id }?.period == 604_800)
        #expect(windows.first { $0.id == id }?.label == "Fable")
        #expect(self.lights(account, date: self.past).contains { $0.kind == .limit && $0.severity == .critical })
    }

    @Test func `a current money only account can inspect an earlier exhausted quota`() {
        let account = self.account(
            history: [self.quota("primary", used: 100, minutes: 300)], moneyOnly: true)
        #expect(self.windows(account, date: self.past).contains { $0.id == "primary" && $0.usedFraction == 1 })
        #expect(self.lights(account, date: self.past).contains { $0.kind == .limit && $0.severity == .critical })
    }

    @Test func `historical hidden lanes never reappear in the live or unprojected future state`() {
        let account = self.account(history: [self.quota("primary", used: 100, minutes: 300)])
        #expect(self.windows(account, date: nil) == account.gauge.resolvedWindows)
        let future = self.now.addingTimeInterval(300)
        #expect(!self.windows(account, date: future).contains { $0.id == "primary" })
        #expect(!self.lights(account, date: nil).contains { $0.kind == .limit })
        #expect(!self.lights(account, date: future).contains { $0.kind == .limit })
    }

    @Test func `a hidden lane is never invented before its first actual observation`() {
        let account = self.account(history: [self.quota("primary", used: 100, minutes: 300)])
        let before = self.past.addingTimeInterval(-1)
        #expect(!self.windows(account, date: before).contains { $0.id == "primary" && $0.usedFraction != nil })
        #expect(!self.lights(account, date: before).contains { $0.kind == .limit })
    }

    @Test func `hidden histories preserve the chart gap rather than holding a stale quota`() {
        let first = self.now.addingTimeInterval(-7200)
        let history = self.quota("primary", used: 100, minutes: 300, at: first)
        let account = self.account(history: [history])
        let gap = first.addingTimeInterval(3600)
        #expect(!self.windows(account, date: gap).contains { $0.id == "primary" && $0.usedFraction != nil })
        #expect(!self.lights(account, date: gap).contains { $0.kind == .limit })
    }

    @Test func `more than three historical quotas keep an exhausted hidden lane in the compact gauge`() {
        let history = [
            self.quota("primary", used: 10, minutes: 300),
            self.quota("secondary", used: 20, minutes: 10080),
            self.quota("tertiary", used: 30, minutes: 10080),
            self.quota("claude-weekly-scoped-fable", used: 100, minutes: 10080),
        ]
        let account = self.account(history: history)
        let windows = self.windows(account, date: self.past)
        #expect(windows.count <= 3)
        #expect(windows.contains { $0.id == "claude-weekly-scoped-fable" && $0.usedFraction == 1 })
        #expect(Set(windows.map(\.id)).count == windows.count)
        #expect(self.lights(account, date: self.past).contains { $0.kind == .limit && $0.severity == .critical })
    }

    @Test func `an exhausted historical session stays inside the longer weekly quota`() {
        let account = self.account(history: [
            self.quota("primary", used: 100, minutes: 300),
            self.quota("secondary", used: 20, minutes: 10080),
        ])
        let windows = self.windows(account, date: self.past)
        #expect(windows.map(\.id) == ["secondary", "primary"])
        #expect(windows.last?.usedFraction == 1)
    }

    private func quota(
        _ id: String, used: Double, minutes: Int, at date: Date? = nil) -> PlanUtilizationSeriesHistory
    {
        .init(name: .init(rawValue: "nativeQuota:" + id), windowMinutes: minutes, entries: [.init(
            capturedAt: date ?? self.past,
            usedPercent: used,
            resetsAt: self.now.addingTimeInterval(3600))])
    }

    private func account(
        history: [PlanUtilizationSeriesHistory], moneyOnly: Bool = false) -> NativeOrbitAccountPresentation
    {
        var gauge = ComputeGauge.State()
        gauge.provider = "claude"
        gauge.windows = moneyOnly ? [.init(id: "unknown", label: "Usage", period: 1, used: nil, recovery: .none)]
            : [.init(id: "secondary", label: "Weekly", period: 604_800, used: 0)]
        var account = NativeOrbitAccountPresentation(
            id: "fixture",
            label: "Fixture",
            email: nil,
            symbol: "person",
            isActive: true,
            canActivate: false,
            gauge: gauge,
            updatedAt: self.now,
            history: history,
            odometer: nil,
            odometerHelp: nil,
            statusText: nil,
            selection: .none)
        if moneyOnly {
            account.metrics.reportedBalance = .init(value: 10, unit: "USD", isWorkspace: false, updatedAt: self.now)
        }
        return account
    }

    private func projection() -> NativeOrbitAccountProjection {
        .init(
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
    }

    private func windows(_ account: NativeOrbitAccountPresentation, date: Date?) -> [UsageWindow] {
        NativeOrbitHistoricalInspection.windows(
            account: account, date: date, now: self.now, days: 1, projection: self.projection())
    }

    private func lights(_ account: NativeOrbitAccountPresentation, date: Date?) -> [NativeOrbitWarningLight] {
        NativeOrbitWarningEvaluation.lights(
            account: account, peers: [account], projection: self.projection(), date: date, now: self.now, days: 1)
    }
}
