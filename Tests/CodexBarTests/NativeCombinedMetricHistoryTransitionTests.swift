import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct NativeCombinedMetricHistoryTransitionTests {
    private let now = Date(timeIntervalSince1970: 1_800_014_400)

    @Test func `one preparation makes both units immediately available with stable sample identities`() async throws {
        let model = self.model()
        let history = try #require(await NativeCombinedTokenHistory.prepare(
            model: model, days: 1, now: self.now, moneyCurrency: "USD"))
        let tokens = history.series(for: .tokens)
        let money = history.series(for: .money(currency: "USD"))
        #expect(tokens.map(\.id) == money.map(\.id))
        #expect(tokens.first?.points.map(\.id) == money.first?.points.map(\.id))
        #expect(tokens.first?.points.last?.value == 500)
        #expect(money.first?.points.last?.value == 6.75)
        // Repeated unit selection consumes the prepared snapshot, without another asynchronous gap.
        #expect(history.series(for: .tokens) == tokens)
        #expect(history.series(for: .money(currency: "USD")) == money)
        #expect(tokens == NativeCombinedTokenHistory.make(model: model, days: 1, now: self.now))
        #expect(money == NativeCombinedTokenHistory.make(
            model: model, days: 1, now: self.now, metric: .money(currency: "USD")))
    }

    @Test func `a prepared history never substitutes tokens or another currency for unavailable spend`() async throws {
        let model = self.model()
        let noCurrency = try #require(await NativeCombinedTokenHistory.prepare(
            model: model, days: 1, now: self.now, moneyCurrency: nil))
        #expect(!noCurrency.series(for: .tokens).isEmpty)
        #expect(noCurrency.series(for: .money(currency: "USD")).isEmpty)
        let dollars = try #require(await NativeCombinedTokenHistory.prepare(
            model: model, days: 1, now: self.now, moneyCurrency: "USD"))
        #expect(dollars.series(for: .money(currency: "EUR")).isEmpty)
        let euros = try #require(await NativeCombinedTokenHistory.prepare(
            model: model, days: 1, now: self.now, moneyCurrency: "EUR"))
        #expect(euros.series(for: .money(currency: "EUR")).isEmpty)
        #expect(!euros.series(for: .tokens).isEmpty)
    }

    @Test func `both preloaded units retain exact scrubbed observations rather than the latest total`() async throws {
        let model = self.model()
        let history = try #require(await NativeCombinedTokenHistory.prepare(
            model: model, days: 1, now: self.now, moneyCurrency: "USD"))
        let selected = self.now.addingTimeInterval(-3600)
        let readings = model.readings(days: 1, now: selected)
        for metric in [NativeCombinedMetric.tokens, .money(currency: "USD")] {
            let series = try #require(history.series(for: metric).first)
            let point = try #require(series.points.first { $0.date == selected })
            let reading = try #require(readings.first { $0.page.id == series.id })
            #expect(point.value == metric.value(reading.reading))
            #expect(point.value == (metric == .tokens ? 200 : 2.25))
            #expect(point.value != series.points.last?.value)
        }
    }

    @Test func `range changes preserve sample identities while changing their actual times`() {
        let model = self.model(completeCoverage: true)
        let day = NativeCombinedTokenHistory.make(model: model, days: 1, now: self.now).first?.points ?? []
        #expect(day.count == 49)
        for days in [7, 30] {
            let next = NativeCombinedTokenHistory.make(model: model, days: days, now: self.now).first?.points ?? []
            #expect(next.count == 49)
            #expect(day.map(\.id) == next.map(\.id))
            #expect(day.map(\.date) != next.map(\.date))
        }
    }

    @Test
    func `preparation retains its complete snapshot and rejects superseded results`() async throws {
        let model = self.model()
        let history = try #require(await NativeCombinedTokenHistory.prepare(
            model: model, days: 1, now: self.now, moneyCurrency: "USD"))
        let day = NativeCombinedChartPresentation.Request(
            now: self.now,
            days: 1,
            moneyCurrency: "USD",
            ids: model.pages.map(\.id),
            accounts: model.pages.map(\.account))
        let week = NativeCombinedChartPresentation.Request(
            now: self.now, days: 7, moneyCurrency: "USD", ids: day.ids, accounts: day.accounts)
        let refreshed = NativeCombinedChartPresentation.Request(
            now: self.now.addingTimeInterval(60), days: 1, moneyCurrency: "USD", ids: day.ids, accounts: day.accounts)
        var presentation = NativeCombinedChartPresentation()
        presentation.begin(day)
        let firstPublished = presentation.publish([.init(request: day, history: history, model: model, labels: [:])])
        #expect(firstPublished)
        for pending in [week, refreshed] {
            presentation.begin(pending)
            #expect(presentation.visible?.request == day)
            #expect(presentation.visible?.history.tokenSeries == history.tokenSeries)
        }
        let stalePublished = presentation.publish([.init(request: week, history: history, model: model, labels: [:])])
        #expect(!stalePublished)
        #expect(presentation.visible?.request == day)
        let next = try #require(await NativeCombinedTokenHistory.prepare(
            model: model, days: 1, now: refreshed.now, moneyCurrency: "USD"))
        let refreshedPublished = presentation.publish([.init(
            request: refreshed,
            history: next,
            model: model,
            labels: [:])])
        #expect(refreshedPublished)
        #expect(presentation.visible?.request == refreshed)
        #expect(presentation.visible?.history.tokenSeries == next.tokenSeries)
    }

    @Test func `range selection immediately reuses prepared histories in both units`() async throws {
        let model = self.model(completeCoverage: true)
        var presentation = NativeCombinedChartPresentation()
        for days in [1, 7, 30] {
            let request = NativeCombinedChartPresentation.Request(
                now: self.now,
                days: days,
                moneyCurrency: "USD",
                ids: model.pages.map(\.id),
                accounts: model.pages.map(\.account))
            let history = try #require(await NativeCombinedTokenHistory.prepare(
                model: model, days: days, now: self.now, moneyCurrency: "USD"))
            presentation.begin(request)
            let published = presentation.publish([.init(request: request, history: history, model: model, labels: [:])])
            #expect(published)
        }
        // No preparation or suspension follows these selections, including the first return to an earlier range.
        for days in [1, 30, 7, 1] {
            presentation.begin(.init(
                now: self.now,
                days: days,
                moneyCurrency: "USD",
                ids: model.pages.map(\.id),
                accounts: model.pages.map(\.account)))
            let visible = try #require(presentation.visible)
            #expect(visible.request.days == days)
            let tokens = try #require(visible.history.series(for: .tokens).first)
            let money = try #require(visible.history.series(for: .money(currency: "USD")).first)
            #expect(tokens.points.first?.date == self.now.addingTimeInterval(-Double(days) * 86400))
            #expect(tokens.points.count == 49)
            #expect(tokens.points.last?.value == 500)
            #expect(money.points.last?.value == 6.75)
        }
    }

    @Test func `one source preparation supplies every range during selection and refresh`() async throws {
        let model = self.model(completeCoverage: true)
        let request = NativeCombinedChartPresentation.Request(
            now: self.now,
            days: 7,
            moneyCurrency: "USD",
            ids: model.pages.map(\.id),
            accounts: model.pages.map(\.account))
        let snapshots = try #require(await NativeCombinedChartPresentation.prepare(
            request: request, model: model, labels: ["history-account": "Original"]))
        #expect(snapshots.map(\.request.days) == [1, 7, 30])
        var presentation = NativeCombinedChartPresentation()
        presentation.begin(request)
        let published = presentation.publish(snapshots)
        #expect(published)
        // A clock refresh has begun, but neither a new source nor a range click may discard cached targets.
        let refreshed = NativeCombinedChartPresentation.Request(
            now: self.now.addingTimeInterval(60),
            days: 7,
            moneyCurrency: "USD",
            ids: request.ids,
            accounts: request.accounts)
        presentation.begin(refreshed)
        let clock = ContinuousClock()
        let selectionStart = clock.now
        for days in [30, 1, 7, 30, 1] {
            let visible = try #require(presentation.snapshot(days: days))
            #expect(visible.request.days == days)
            #expect(visible.request.now == self.now)
            #expect(visible.history.series(for: .tokens).first?.points.last?.value == 500)
            #expect(visible.history.series(for: .money(currency: "USD")).first?.points.last?.value == 6.75)
        }
        print("All cached range selections, with pending refresh: \(selectionStart.duration(to: clock.now))")
        let stalePublished = presentation.publish(snapshots)
        #expect(!stalePublished)
        let replacements = try #require(await NativeCombinedChartPresentation.prepare(
            request: refreshed, model: model, labels: ["history-account": "Refreshed"]))
        let refreshedPublished = presentation.publish(replacements)
        #expect(refreshedPublished)
        for days in [1, 7, 30] {
            let visible = try #require(presentation.snapshot(days: days))
            #expect(visible.request.days == days)
            #expect(visible.request.now == refreshed.now)
            #expect(visible.labels["history-account"] == "Refreshed")
        }
    }

    private func model(completeCoverage: Bool = false) -> NativeCombinedAccounts {
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: nil,
            last30DaysCostUSD: nil,
            historyDays: completeCoverage ? 90 : 30,
            historyCoverageIsEstablished: completeCoverage,
            daily: completeCoverage ? [.init(
                date: "2026-11-01",
                inputTokens: 0,
                outputTokens: 0,
                totalTokens: 0,
                costUSD: 0,
                modelsUsed: nil,
                modelBreakdowns: nil)] : [],
            quotaSlices: [
                .init(timestamp: self.now.addingTimeInterval(-7200), totalTokens: 200, costUSD: 2.25),
                .init(timestamp: self.now.addingTimeInterval(-600), totalTokens: 300, costUSD: 4.50),
            ],
            updatedAt: self.now)
        var gauge = ComputeGauge.State()
        gauge.provider = UsageProvider.codex.rawValue
        let account = NativeOrbitAccountPresentation(
            id: "history-account",
            label: "History account",
            email: nil,
            symbol: "leaf",
            isActive: false,
            canActivate: false,
            gauge: gauge,
            updatedAt: self.now,
            history: [],
            odometer: nil,
            odometerHelp: nil,
            statusText: nil,
            selection: .none,
            metrics: NativeOrbitAccountMetrics(usage: snapshot, usageScope: .account))
        return NativeCombinedAccounts(connections: [.init(provider: .codex, accounts: [account])], now: self.now)
    }
}
