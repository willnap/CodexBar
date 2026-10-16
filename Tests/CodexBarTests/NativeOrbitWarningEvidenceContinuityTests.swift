import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct NativeOrbitWarningEvidenceContinuityTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test(arguments: [false, true])
    func `an unavailable optional cloud promotion does not claim prepaid credit exhaustion`(locked: Bool) throws {
        let expiry = self.now.addingTimeInterval(locked ? 86400 : -86400).ISO8601Format()
        let reason = locked ? "\"promotion_not_available\"" : "null"
        let json = """
        {"limit_dollars":100,"remaining_dollars":75,"resets_at":"\(expiry)","locked_reason":\(reason)}
        """
        let cloud = try JSONDecoder().decode(ClaudeCloudCreditsSnapshot.self, from: Data(json.utf8))
        let snapshot = UsageSnapshot(
            primary: .init(
                usedPercent: 0,
                windowMinutes: 300,
                resetsAt: nil,
                resetDescription: nil),
            secondary: nil,
            claudeCloudCredits: cloud,
            updatedAt: self.now)
        let lights = NativeOrbitWarningSignals.account(
            provider: .claude, snapshot: snapshot, metrics: .empty, history: [], now: self.now)
        #expect(!lights.contains { $0.kind == .credits })
        #expect(!lights.contains { $0.severity == .critical })
    }

    @Test func `evaluation respects a source that deliberately has no stale reading warning`() {
        let account = self.staleAccount()
        #expect(!self.evaluated(account).contains { $0.kind == .oldReading })
    }

    @Test func `evaluation preserves a stale reading warning explicitly supplied by the source`() {
        var account = self.staleAccount()
        account.warnings = [.init(.oldReading, .caution, "Reading is out of date.", action: .refresh)]
        #expect(self.evaluated(account).filter { $0.kind == .oldReading }.count == 1)
    }

    @Test(arguments: [600.0, 3600.0])
    func `a cached missing reset warning expires with its actual quota evidence`(resetAfter: TimeInterval) {
        let account = self.quotaWarningAccount(resetAfter: resetAfter, partial: false)
        #expect(self.evaluated(account).contains { $0.kind == .notReported })
        let later = self.now.addingTimeInterval(min(resetAfter, 1800) + 1)
        #expect(!self.evaluated(account, at: later).contains { $0.kind == .notReported })
    }

    @Test(arguments: [600.0, 3600.0])
    func `a cached missing model warning expires with its actual quota evidence`(resetAfter: TimeInterval) {
        let account = self.quotaWarningAccount(resetAfter: resetAfter, partial: true)
        #expect(self.evaluated(account).contains { $0.kind == .partialReading })
        let later = self.now.addingTimeInterval(min(resetAfter, 1800) + 1)
        #expect(!self.evaluated(account, at: later).contains { $0.kind == .partialReading })
    }

    @Test(arguments: BalanceBarrier.allCases)
    func `credit depletion needs a continuous immediate prior receipt`(_ barrier: BalanceBarrier) {
        let older = self.balance(100, at: -7200)
        let previous: NativeOrbitReportedBalance? = switch barrier {
        case .missing: nil
        case .currency: self.balance(100, at: -3600, unit: "EUR")
        case .workspace: self.balance(100, at: -3600, workspace: true)
        case .flat: self.balance(1, at: -3600)
        case .increase: self.balance(0.5, at: -3600)
        case .old: self.balance(100, at: -10800)
        case .tooClose: self.balance(100, at: -300)
        }
        let priorDate = previous?.updatedAt ?? self.now.addingTimeInterval(-3600)
        let entries = barrier == .old ? [self.receipt(at: priorDate, balance: previous)] : [
            self.receipt(at: older.updatedAt, balance: older),
            self.receipt(at: priorDate, balance: previous),
        ]
        var metrics = NativeOrbitAccountMetrics.empty
        metrics.reportedBalance = self.balance(1, at: 0)
        let lights = self.money(metrics, history: [.init(
            name: "nativeMetric:balance", windowMinutes: 0, entries: entries)])
        #expect(!lights.contains { $0.kind == .credits })
    }

    @Test func `continuous current wallet depletion still warns before credits run out`() {
        var metrics = NativeOrbitAccountMetrics.empty
        metrics.reportedBalance = self.balance(5, at: 0)
        let previous = self.balance(10, at: -3600)
        let lights = self.money(metrics, history: [.init(
            name: "nativeMetric:balance",
            windowMinutes: 0,
            entries: [self.receipt(at: previous.updatedAt, balance: previous)])])
        #expect(lights.contains { $0.kind == .credits && $0.severity == .caution })
    }

    @Test(arguments: SpendBarrier.allCases)
    func `spend forecasts stop at the immediate prior receipt evidence barrier`(_ barrier: SpendBarrier) {
        let previous: ProviderCostSnapshot? = switch barrier {
        case .missing: nil
        case .disabled: self.spend(10, at: -3600, disabled: true)
        case .unavailable: self.spend(10, at: -3600, unavailable: true)
        case .cycle: self.spend(10, at: -3600, reset: 2 * 86400)
        case .currency: self.spend(10, at: -3600, currency: "EUR")
        case .period: self.spend(10, at: -3600, period: "Daily")
        case .flat: self.spend(20, at: -3600)
        case .decrease: self.spend(30, at: -3600)
        case .old: self.spend(5, at: -10800)
        case .tooClose: self.spend(10, at: -300)
        }
        let priorDate = previous?.updatedAt ?? self.now.addingTimeInterval(-3600)
        let older = self.spend(5, at: -7200)
        let entries = barrier == .old ? [self.receipt(at: priorDate, spend: previous)] : [
            self.receipt(at: older.updatedAt, spend: older),
            self.receipt(at: priorDate, spend: previous),
        ]
        var metrics = NativeOrbitAccountMetrics.empty
        metrics.reportedSpend = self.spend(20, at: 0)
        let lights = self.money(metrics, history: [.init(
            name: "nativeMetric:spend", windowMinutes: 0, entries: entries)])
        #expect(!lights.contains { $0.kind == .spend })
    }

    @Test func `continuous spending within the same current cycle still predicts a cap`() {
        var metrics = NativeOrbitAccountMetrics.empty
        metrics.reportedSpend = self.spend(20, at: 0)
        let previous = self.spend(10, at: -3600)
        let lights = self.money(metrics, history: [.init(
            name: "nativeMetric:spend",
            windowMinutes: 0,
            entries: [self.receipt(at: previous.updatedAt, spend: previous)])])
        #expect(lights.contains { $0.kind == .spend && $0.severity == .caution })
    }

    enum BalanceBarrier: CaseIterable {
        case missing, currency, workspace, flat, increase, old, tooClose
    }

    enum SpendBarrier: CaseIterable {
        case missing, disabled, unavailable, cycle, currency, period, flat, decrease, old, tooClose
    }

    private func balance(
        _ value: Double, at offset: TimeInterval, unit: String = "USD", workspace: Bool = false)
        -> NativeOrbitReportedBalance
    {
        .init(value: value, unit: unit, isWorkspace: workspace, updatedAt: self.now.addingTimeInterval(offset))
    }

    private func spend(
        _ used: Double,
        at offset: TimeInterval,
        currency: String = "USD",
        period: String = "Monthly",
        reset: TimeInterval = 86400,
        disabled: Bool = false,
        unavailable: Bool = false) -> ProviderCostSnapshot
    {
        .init(
            used: used,
            limit: 100,
            currencyCode: currency,
            period: period,
            resetsAt: self.now.addingTimeInterval(reset),
            usageIsUnavailable: unavailable,
            isDisabled: disabled,
            updatedAt: self.now.addingTimeInterval(offset))
    }

    private func receipt(
        at date: Date, spend: ProviderCostSnapshot? = nil, balance: NativeOrbitReportedBalance? = nil)
        -> PlanUtilizationHistoryEntry
    {
        .init(capturedAt: date, usedPercent: 0, resetsAt: nil, nativeMetrics: .init(spend: spend, balance: balance))
    }

    private func money(
        _ metrics: NativeOrbitAccountMetrics, history: [PlanUtilizationSeriesHistory]) -> [NativeOrbitWarningLight]
    {
        NativeOrbitWarningSignals.account(
            provider: .claude, snapshot: nil, metrics: metrics, history: history, now: self.now)
    }

    private func quotaWarningAccount(resetAfter: TimeInterval, partial: Bool) -> NativeOrbitAccountPresentation {
        let id = partial ? "tertiary" : "primary"
        let history = [PlanUtilizationSeriesHistory(
            name: .init(rawValue: "nativeQuota:" + id),
            windowMinutes: 300,
            entries: [.init(
                capturedAt: self.now.addingTimeInterval(-300),
                usedPercent: 30,
                resetsAt: self.now.addingTimeInterval(resetAfter))])]
        let window = RateWindow(usedPercent: 40, windowMinutes: 300, resetsAt: nil, resetDescription: nil)
        let snapshot = UsageSnapshot(
            primary: partial ? nil : window,
            secondary: nil,
            extraRateWindows: partial ? [.init(id: id, title: "Fable", window: window, usageKnown: false)] : nil,
            updatedAt: self.now)
        var account = self.staleAccount(updatedAt: self.now, history: history, used: partial ? nil : 0.4)
        account.warnings = NativeOrbitWarningSignals.account(
            provider: .claude, snapshot: snapshot, metrics: .empty, history: history, now: self.now)
        return account
    }

    private func staleAccount(
        updatedAt: Date? = nil, history: [PlanUtilizationSeriesHistory] = [], used: Double? = 0)
        -> NativeOrbitAccountPresentation
    {
        var gauge = ComputeGauge.State()
        gauge.provider = "claude"
        gauge.windows = [.init(id: "primary", label: "Session", period: 18000, used: used)]
        return .init(
            id: "fixture",
            label: "Fixture",
            email: nil,
            symbol: "person",
            isActive: true,
            canActivate: false,
            gauge: gauge,
            updatedAt: updatedAt ?? self.now.addingTimeInterval(-3600),
            history: history,
            odometer: nil,
            odometerHelp: nil,
            statusText: nil,
            selection: .none)
    }

    private func evaluated(
        _ account: NativeOrbitAccountPresentation, at date: Date? = nil) -> [NativeOrbitWarningLight]
    {
        let now = date ?? self.now
        let projection = NativeOrbitAccountProjection(
            now: now,
            end: now.addingTimeInterval(86400),
            lastActivity: nil,
            lanes: [],
            events: [],
            tokenRate: nil,
            costRate: nil,
            periodSummary: .init(),
            resetInventory: nil,
            liveMetrics: .empty)
        return NativeOrbitWarningEvaluation.lights(
            account: account, peers: [account], projection: projection, date: nil, now: now, days: 1)
    }
}
