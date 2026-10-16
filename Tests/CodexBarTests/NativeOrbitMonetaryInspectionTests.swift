import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct NativeOrbitMonetaryInspectionTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func `wallet inspection projects only its own recorded balance trend`() {
        var metrics = NativeOrbitAccountMetrics.empty
        metrics.reportedBalance = self.balance(48, at: self.now)
        let history = self.balances([self.balance(52, at: self.now.addingTimeInterval(-3600))])
        let first = NativeOrbitMonetaryInspection.projectedMetrics(
            metrics: metrics, history: history, at: self.now.addingTimeInterval(900), now: self.now)
        let later = NativeOrbitMonetaryInspection.projectedMetrics(
            metrics: metrics, history: history, at: self.now.addingTimeInterval(1800), now: self.now)
        #expect(first.reportedBalance?.value == 47)
        #expect(later.reportedBalance?.value == 46)
        #expect(NativeOrbitMonetaryInspection.projectedMetrics(
            metrics: metrics, history: [], at: self.now.addingTimeInterval(900), now: self.now)
            .reportedBalance == nil)
    }

    @Test func `wallet projection cannot borrow another currency workspace or top up as consumption`() {
        var metrics = NativeOrbitAccountMetrics.empty
        metrics.reportedBalance = self.balance(48, at: self.now)
        for prior in [
            self.balance(52, unit: "EUR", at: self.now.addingTimeInterval(-3600)),
            self.balance(52, workspace: true, at: self.now.addingTimeInterval(-3600)),
            self.balance(42, at: self.now.addingTimeInterval(-3600)),
        ] {
            #expect(NativeOrbitMonetaryInspection.projectedMetrics(
                metrics: metrics,
                history: self.balances([prior]),
                at: self.now.addingTimeInterval(1800),
                now: self.now).reportedBalance == nil)
        }
    }

    @Test func `unavailable balance receipts break a projected trend`() {
        var metrics = NativeOrbitAccountMetrics.empty
        metrics.reportedBalance = self.balance(48, at: self.now)
        let prior = self.balance(52, at: self.now.addingTimeInterval(-3600))
        let history = [PlanUtilizationSeriesHistory(
            name: .init(rawValue: "nativeMetric:balance"), windowMinutes: 0, entries: [
                .init(capturedAt: prior.updatedAt, usedPercent: 0, resetsAt: nil, nativeMetrics: .init(balance: prior)),
                .init(
                    capturedAt: self.now.addingTimeInterval(-900),
                    usedPercent: 0,
                    resetsAt: nil,
                    nativeMetrics: .init()),
            ])]
        #expect(NativeOrbitMonetaryInspection.projectedMetrics(
            metrics: metrics, history: history, at: self.now.addingTimeInterval(1800), now: self.now)
            .reportedBalance == nil)
    }

    @Test func `budget projection consumes money and respects its known cycle reset`() {
        let reset = self.now.addingTimeInterval(1800)
        var metrics = NativeOrbitAccountMetrics.empty
        metrics.reportedSpend = self.spend(40, at: self.now, reset: reset)
        let prior = self.spend(30, at: self.now.addingTimeInterval(-3600), reset: reset)
        let history = self.spends([prior])
        let before = NativeOrbitMonetaryInspection.projectedMetrics(
            metrics: metrics, history: history, at: self.now.addingTimeInterval(900), now: self.now)
        #expect(before.reportedSpend?.used == 42.5)
        let after = NativeOrbitMonetaryInspection.projectedMetrics(
            metrics: metrics, history: history, at: reset.addingTimeInterval(900), now: self.now)
        #expect(after.reportedSpend?.used == 2.5)
        let reading = NativeOrbitMonetaryInstrument.reading(
            mode: .budgetRemaining, metrics: before, days: 7, now: self.now)
        #expect(reading.amount == 57.5)
    }

    @Test func `changed budget limits and stale money cannot establish a future amount`() {
        var metrics = NativeOrbitAccountMetrics.empty
        metrics.reportedSpend = self.spend(40, at: self.now)
        let changed = self.spend(30, limit: 50, at: self.now.addingTimeInterval(-3600))
        #expect(NativeOrbitMonetaryInspection.projectedMetrics(
            metrics: metrics,
            history: self.spends([changed]),
            at: self.now.addingTimeInterval(900),
            now: self.now).reportedSpend == nil)
        metrics.reportedBalance = self.balance(48, at: self.now.addingTimeInterval(-10800))
        #expect(NativeOrbitMonetaryInspection.projectedMetrics(
            metrics: metrics,
            history: self.balances([self.balance(52, at: self.now.addingTimeInterval(-14400))]),
            at: self.now.addingTimeInterval(900),
            now: self.now).reportedBalance == nil)
    }

    @Test func `hovering backward restores recorded money and forward labels a changing projection`() {
        var account = self.account(history: self.balances([
            self.balance(52, at: self.now.addingTimeInterval(-3600)),
        ]))
        account.metrics.reportedBalance = self.balance(48, at: self.now)
        let past = NativeOrbitMonetaryInspection.reading(
            mode: .balance, account: account, date: self.now.addingTimeInterval(-3600), now: self.now, days: 7)
        #expect(past.amount == 52)
        let future = NativeOrbitMonetaryInspection.reading(
            mode: .balance, account: account, date: self.now.addingTimeInterval(1800), now: self.now, days: 7)
        #expect(future.amount == 46)
        #expect(future.estimated)
        #expect(future.help.contains("Projected"))
        let gap = NativeOrbitMonetaryInspection.reading(
            mode: .balance, account: account, date: self.now.addingTimeInterval(-7200), now: self.now, days: 7)
        #expect(gap.amount == nil)
    }

    @Test func `a past spend bar reads its measured day amount with its actual currency`() {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        let yesterday = self.now.addingTimeInterval(-86400)
        var account = self.account(history: [])
        account.metrics.usage = .init(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: nil,
            last30DaysCostUSD: nil,
            currencyCode: "EUR",
            bucketTimeZoneIdentifier: "UTC",
            daily: [.init(
                date: formatter.string(from: yesterday),
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: nil,
                costUSD: 3,
                modelsUsed: nil,
                modelBreakdowns: nil)],
            updatedAt: self.now)
        let spending = NativeOrbitSpendingHistory.make(
            metrics: account.metrics, history: [], now: self.now, days: 7)
        let reading = NativeOrbitMonetaryInspection.reading(
            mode: .spend, account: account, date: yesterday, now: self.now, days: 7, spending: spending)
        #expect(reading.amount == 3)
        #expect(reading.currencyCode == "EUR")
        #expect(reading.period == "Daily total")
    }

    @Test func `recent wallet consumption exposes the graphs future but zero usage and topups do not`() {
        for prior in [52.0, 48, 42] {
            var account = self.account(history: self.balances([
                self.balance(prior, at: self.now.addingTimeInterval(-3600)),
            ]))
            account.metrics.reportedBalance = self.balance(48, at: self.now)
            let activity = NativeOrbitMonetaryInspection.lastActivity(
                metrics: account.metrics, history: account.history, now: self.now)
            #expect((activity == self.now) == (prior > 48))
            let state = NativeOrbitPopupState()
            state.now = self.now
            state.accounts = [account]
            #expect(state.isProjecting == (prior > 48))
        }
    }

    @Test func `monetary activity rejects stale receipts and changed balance scope`() {
        var metrics = NativeOrbitAccountMetrics.empty
        metrics.reportedBalance = self.balance(48, at: self.now.addingTimeInterval(-1860))
        #expect(NativeOrbitMonetaryInspection.lastActivity(
            metrics: metrics,
            history: self.balances([self.balance(52, at: self.now.addingTimeInterval(-5460))]),
            now: self.now) == nil)
        metrics.reportedBalance = self.balance(48, at: self.now)
        #expect(NativeOrbitMonetaryInspection.lastActivity(
            metrics: metrics,
            history: self.balances([self.balance(52, workspace: true, at: self.now.addingTimeInterval(-3600))]),
            now: self.now) == nil)
    }

    @Test func `monetary activity requires comparable strictly increasing billing receipts`() {
        var metrics = NativeOrbitAccountMetrics.empty
        metrics.reportedSpend = self.spend(40, at: self.now)
        #expect(NativeOrbitMonetaryInspection.lastActivity(
            metrics: metrics,
            history: self.spends([self.spend(30, at: self.now.addingTimeInterval(-3600))]),
            now: self.now) == self.now)
        for prior in [
            self.spend(40, at: self.now.addingTimeInterval(-3600)),
            self.spend(30, limit: 50, at: self.now.addingTimeInterval(-3600)),
        ] {
            #expect(NativeOrbitMonetaryInspection.lastActivity(
                metrics: metrics, history: self.spends([prior]), now: self.now) == nil)
        }
    }

    @Test func `wallet projections stop at zero unless an actual negative balance establishes debt`() {
        for current in [2.0, -2] {
            var metrics = NativeOrbitAccountMetrics.empty
            metrics.reportedBalance = self.balance(current, at: self.now)
            let history = self.balances([self.balance(current + 4, at: self.now.addingTimeInterval(-3600))])
            let projected = NativeOrbitMonetaryInspection.projectedMetrics(
                metrics: metrics, history: history, at: self.now.addingTimeInterval(3600), now: self.now)
            #expect(projected.reportedBalance?.value == (current >= 0 ? 0 : -6))
        }
    }

    private func account(history: [PlanUtilizationSeriesHistory]) -> NativeOrbitAccountPresentation {
        var gauge = ComputeGauge.State()
        gauge.provider = "openrouter"
        return .init(
            id: "wallet-fixture",
            label: "Wallet fixture",
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

    private func balance(
        _ amount: Double, unit: String = "USD", workspace: Bool = false, at date: Date)
        -> NativeOrbitReportedBalance
    {
        .init(value: amount, unit: unit, isWorkspace: workspace, updatedAt: date)
    }

    private func spend(_ used: Double, limit: Double = 100, at date: Date, reset: Date? = nil) -> ProviderCostSnapshot {
        .init(used: used, limit: limit, currencyCode: "USD", period: "Monthly", resetsAt: reset, updatedAt: date)
    }

    private func balances(_ values: [NativeOrbitReportedBalance]) -> [PlanUtilizationSeriesHistory] {
        [.init(name: .init(rawValue: "nativeMetric:balance"), windowMinutes: 0, entries: values.map {
            .init(capturedAt: $0.updatedAt, usedPercent: 0, resetsAt: nil, nativeMetrics: .init(balance: $0))
        })]
    }

    private func spends(_ values: [ProviderCostSnapshot]) -> [PlanUtilizationSeriesHistory] {
        [.init(name: .init(rawValue: "nativeMetric:spend"), windowMinutes: 0, entries: values.map {
            .init(capturedAt: $0.updatedAt, usedPercent: 0, resetsAt: nil, nativeMetrics: .init(spend: $0))
        })]
    }
}
