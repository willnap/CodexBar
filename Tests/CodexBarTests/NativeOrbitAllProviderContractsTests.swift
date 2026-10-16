import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

/// Shared presentation contracts, not claims that every service supplies every optional capability.
/// Every case uses synthetic account-owned evidence and never opens a store, credential or live provider.
@MainActor
struct NativeOrbitAllProviderContractsTests {
    private let now = Date(timeIntervalSince1970: 1_800_014_400)

    @Test(arguments: UsageProvider.allCases)
    func `missing optional measurements stay unknown quiet and inactive`(provider: UsageProvider) {
        let gauge = NativeUsageGaugeProjection.state(provider: provider, snapshot: nil)
        let account = self.account(provider: provider, gauge: gauge)
        let projection = self.projection(account)
        #expect(gauge.provider == provider.rawValue)
        #expect(gauge.resolvedWindows.allSatisfy { $0.usedFraction == nil })
        #expect(!projection.isActive)
        #expect(projection.lanes.isEmpty)
        #expect(projection.periodSummary.tokens == nil)
        #expect(projection.periodSummary.cost == nil)
        #expect(NativeOrbitWarningSignals.account(
            provider: provider, snapshot: nil, metrics: .empty, history: [], now: self.now).isEmpty)
        for mode in [NativeOrbitMonetaryInstrument.Mode.balance, .budgetRemaining, .spend] {
            #expect(NativeOrbitMonetaryInstrument.reading(
                mode: mode, metrics: .empty, days: 1, now: self.now).amount == nil)
        }
        let optional = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 0,
                windowMinutes: 300,
                resetsAt: nil,
                resetDescription: nil,
                isSyntheticPlaceholder: true),
            secondary: nil,
            updatedAt: self.now)
        #expect(NativeUsageGaugeProjection.state(provider: provider, snapshot: optional)
            .resolvedWindows.allSatisfy { $0.usedFraction == nil })
        #expect(NativeOrbitWarningSignals.account(
            provider: provider, snapshot: optional, metrics: .empty, history: [], now: self.now).isEmpty)
    }

    @Test(arguments: UsageProvider.allCases)
    func `only a current exhausted quota claims exhaustion and a passed reset retires that evidence`(
        provider: UsageProvider) throws
    {
        let reset = self.now.addingTimeInterval(600)
        let snapshot = self.snapshot(used: 100, reset: reset)
        let gauge = NativeUsageGaugeProjection.state(provider: provider, snapshot: snapshot)
        let window = try #require(gauge.resolvedWindows.first { $0.usedFraction != nil })
        #expect(window.usedFraction == 1)
        let countdown = try #require(NativeOrbitCountdown(window: window).value(at: self.now))
        #expect(countdown > 0 && countdown <= 1)
        let current = NativeOrbitWarningSignals.account(
            provider: provider, snapshot: snapshot, metrics: .empty, history: [], now: self.now)
        #expect(current.contains { $0.kind == .limit && $0.severity == .critical })
        #expect(!current.contains { [.behindPace, .idle].contains($0.kind) })
        let afterReset = NativeOrbitWarningSignals.account(
            provider: provider, snapshot: snapshot, metrics: .empty, history: [], now: reset.addingTimeInterval(1))
        #expect(!afterReset.contains { [.limit, .resetLate].contains($0.kind) })
        let refreshed = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 0,
                windowMinutes: 300,
                resetsAt: reset.addingTimeInterval(18000),
                resetDescription: nil),
            secondary: nil,
            updatedAt: reset)
        #expect(!NativeOrbitWarningSignals.account(
            provider: provider, snapshot: refreshed, metrics: .empty, history: [], now: reset)
            .contains { [.limit, .resetLate].contains($0.kind) })
    }

    @Test(arguments: UsageProvider.allCases)
    func `history restores measured exhaustion without borrowing current login failures`(
        provider: UsageProvider) throws
    {
        let before = self.now.addingTimeInterval(-600)
        let oldReset = self.now.addingTimeInterval(-300)
        let newReset = oldReset.addingTimeInterval(18000)
        let history = self.quotaHistory([
            (before, 100, oldReset), (self.now, 0, newReset),
        ])
        let snapshot = self.snapshot(used: 0, reset: newReset)
        var account = self.account(
            provider: provider,
            gauge: NativeUsageGaugeProjection.state(provider: provider, snapshot: snapshot),
            history: [history])
        account.warnings = [.init(.signIn, .critical, "The current login expired.")]
        let projection = self.projection(account)
        let restored = NativeOrbitHistoricalInspection.windows(
            account: account, date: before, now: self.now, days: 1)
        #expect(try #require(restored.first?.usedFraction) == 1)
        let past = NativeOrbitWarningEvaluation.lights(
            account: account, peers: [account], projection: projection, date: before, now: self.now, days: 1)
        #expect(past.contains { $0.kind == .limit && $0.severity == .critical })
        #expect(!past.contains { $0.kind == .signIn })
        let live = NativeOrbitWarningEvaluation.lights(
            account: account, peers: [account], projection: projection, date: nil, now: self.now, days: 1)
        #expect(live.contains { $0.kind == .signIn })
        #expect(!live.contains { $0.kind == .limit })
    }

    @Test(arguments: UsageProvider.allCases)
    func `zero balances require continuous evidence of prior funding to warn`(provider: UsageProvider) throws {
        var metrics = NativeOrbitAccountMetrics.empty
        metrics.reportedBalance = .init(value: 0, unit: "USD", isWorkspace: false, updatedAt: self.now)
        let mode = try #require(NativeOrbitMonetaryInstrument.mode(provider: provider, windows: [], metrics: metrics))
        #expect(mode == .balance)
        #expect(NativeOrbitMonetaryInstrument.reading(
            mode: mode, metrics: metrics, days: 1, now: self.now).amount == 0)
        func credits(_ history: [PlanUtilizationSeriesHistory]) -> [NativeOrbitWarningLight] {
            NativeOrbitWarningSignals.account(
                provider: provider, snapshot: nil, metrics: metrics, history: history, now: self.now)
                .filter { $0.kind == .credits }
        }
        #expect(credits([]).isEmpty)
        let funded = PlanUtilizationHistoryEntry(
            capturedAt: self.now.addingTimeInterval(-600),
            usedPercent: 0,
            resetsAt: nil,
            nativeMetrics: .init(balance: .init(
                value: 10, unit: "USD", isWorkspace: false, updatedAt: self.now.addingTimeInterval(-600))))
        let lane = PlanUtilizationSeriesHistory(name: "nativeMetric:balance", windowMinutes: 0, entries: [funded])
        #expect(credits([lane]).contains { $0.severity == .critical })
        let interrupted = PlanUtilizationSeriesHistory(name: lane.name, windowMinutes: 0, entries: [
            funded,
            .init(capturedAt: self.now.addingTimeInterval(-300), usedPercent: 0, resetsAt: nil, nativeMetrics: .init()),
        ])
        #expect(credits([interrupted]).isEmpty)
    }

    @Test(arguments: UsageProvider.allCases)
    func `invalid quota and budget receipts stay unknown without invented exhaustion`(
        provider: UsageProvider)
    {
        for invalid in [Double.nan, .infinity, -.infinity, -1] {
            let snapshot = self.snapshot(used: invalid, reset: self.now.addingTimeInterval(3600))
            let gauge = NativeUsageGaugeProjection.state(provider: provider, snapshot: snapshot)
            #expect(gauge.resolvedWindows.allSatisfy { $0.usedFraction == nil })
            for window in gauge.resolvedWindows {
                let countdown = NativeOrbitCountdown(window: window)
                #expect((1...31).contains(countdown.segments))
                if let value = countdown.value(at: self.now) {
                    #expect(value.isFinite && (0...1).contains(value))
                }
            }
            var metrics = NativeOrbitAccountMetrics.empty
            metrics.reportedBalance = .init(value: invalid, unit: "USD", isWorkspace: false, updatedAt: self.now)
            metrics.reportedSpend = .init(
                used: invalid, limit: 100, currencyCode: "USD", updatedAt: self.now)
            #expect(NativeOrbitMonetaryInstrument.reading(
                mode: .budgetRemaining, metrics: metrics, days: 1, now: self.now).amount == nil)
            if !invalid.isFinite {
                #expect(NativeOrbitMonetaryInstrument.reading(
                    mode: .balance, metrics: metrics, days: 1, now: self.now).amount == nil)
            }
            let lights = NativeOrbitWarningSignals.account(
                provider: provider, snapshot: snapshot, metrics: metrics, history: [], now: self.now)
            #expect(!lights.contains { [.limit, .spend].contains($0.kind) })
            if !invalid.isFinite { #expect(!lights.contains { $0.kind == .credits }) }
        }
    }

    @Test(arguments: UsageProvider.allCases)
    func `every registered provider has real product artwork and its own gauge identity`(
        provider: UsageProvider)
    {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 {
            root.deleteLastPathComponent()
        }
        let catalogue = root.appendingPathComponent("Implementation/Components/UsageIndicator/ComputeGauge.xcassets")
        func exists(_ name: String) -> Bool {
            FileManager.default.fileExists(atPath: catalogue.appendingPathComponent(name + ".symbolset").path)
        }
        let gauge = NativeUsageGaugeProjection.state(provider: provider, snapshot: nil)
        #expect(gauge.provider == provider.rawValue)
        #expect(ServiceIdentity.find(gauge.productID) != nil)
        let artwork = NativeOrbitProviderArtwork.name(for: gauge.productID, assetExists: exists)
        #expect(exists(artwork), "Missing actual product artwork for \(provider.rawValue): \(artwork)")
    }

    @Test(arguments: UsageProvider.allCases)
    func `measured chart projection and dial agree through future exhaustion and reset`(
        provider: UsageProvider) throws
    {
        let reset = self.now.addingTimeInterval(7200)
        let history = self.quotaHistory([
            (self.now.addingTimeInterval(-600), 85, reset), (self.now, 90, reset),
        ])
        let account = self.account(
            provider: provider,
            gauge: NativeUsageGaugeProjection.state(
                provider: provider,
                snapshot: self.snapshot(used: 90, reset: reset)),
            history: [history])
        let projection = self.projection(account)
        #expect(projection.isActive)
        let original = try #require(account.gauge.resolvedWindows.first)
        let lane = try #require(projection.lane(NativeOrbitHistoricalInspection.historyID(
            original, provider: provider.rawValue)))
        #expect(lane.available(at: self.now) == 10)
        for date in [self.now.addingTimeInterval(1800), reset] {
            let windows = NativeOrbitHistoricalInspection.windows(
                account: account, date: date, now: self.now, days: 1, projection: projection)
            let window = try #require(windows.first)
            let fraction = try #require(window.usedFraction)
            #expect(abs(fraction - lane.used(at: date) / 100) < 0.000001)
            #expect(fraction.isFinite && (0...1).contains(fraction))
            #expect(window.countdown?.nextReset == lane.nextReset(after: date))
            let warnings = NativeOrbitWarningEvaluation.lights(
                account: account, peers: [account], projection: projection, date: date, now: self.now, days: 1)
            #expect(warnings.contains { $0.kind == .limit && $0.severity == .critical } == (date < reset))
            #expect(!warnings.contains { $0.kind == .limit && $0.severity == .critical }
                || fraction == 1)
        }
    }

    private func snapshot(used: Double, reset: Date) -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(
                usedPercent: used, windowMinutes: 300, resetsAt: reset, resetDescription: nil),
            secondary: nil,
            updatedAt: self.now)
    }

    private func quotaHistory(_ readings: [(Date, Double, Date)]) -> PlanUtilizationSeriesHistory {
        .init(name: "nativeQuota:primary", windowMinutes: 300, entries: readings.map { date, used, reset in
            .init(capturedAt: date, usedPercent: used, resetsAt: reset)
        })
    }

    private func account(
        provider: UsageProvider,
        gauge: ComputeGauge.State,
        history: [PlanUtilizationSeriesHistory] = []) -> NativeOrbitAccountPresentation
    {
        .init(
            id: "contract:\(provider.rawValue)",
            label: "Synthetic account",
            email: nil,
            symbol: "person",
            isActive: false,
            canActivate: false,
            gauge: gauge,
            updatedAt: self.now,
            history: history,
            odometer: nil,
            odometerHelp: nil,
            statusText: nil,
            selection: .none)
    }

    private func projection(_ account: NativeOrbitAccountPresentation) -> NativeOrbitAccountProjection {
        let lanes = NativeOrbitHistoryWidget(histories: account.history, now: self.now, provider: UsageProvider(
            rawValue: account.gauge.provider)).lanes
        return NativeOrbitAccountProjection.make(
            account: account,
            lanes: lanes,
            now: self.now,
            days: 1,
            start: self.now.addingTimeInterval(-43200),
            end: self.now.addingTimeInterval(43200))
    }
}
