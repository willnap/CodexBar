import CodexBarCore
import Foundation
import SwiftUI
import Testing
@testable import CodexBar

struct NativeOrbitMonetaryInstrumentTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func `wallets show their balance including zero and debt without a gauge`() throws {
        for amount in [48.30, 0, -2.50] {
            var metrics = NativeOrbitAccountMetrics()
            metrics.reportedBalance = .init(value: amount, unit: "USD", isWorkspace: false, updatedAt: self.now)
            let mode = try #require(NativeOrbitMonetaryInstrument.mode(
                provider: .openrouter, windows: [], metrics: metrics))
            #expect(mode == .balance)
            let reading = NativeOrbitMonetaryInstrument.reading(mode: mode, metrics: metrics, days: 7, now: self.now)
            #expect(reading.amount == amount)
            #expect(reading.currencyCode == "USD")
        }
    }

    @Test func `budget money counts down in the same direction as the remaining gauge`() throws {
        var metrics = NativeOrbitAccountMetrics()
        metrics.reportedSpend = self.spend(used: 42.70, limit: 100)
        let windows = [UsageWindow(id: "primary", label: "Budget", period: 1, used: 0.427, recovery: .none)]
        let mode = try #require(NativeOrbitMonetaryInstrument.mode(
            provider: .openrouter, windows: windows, metrics: metrics))
        #expect(mode == .budgetRemaining)
        let reading = NativeOrbitMonetaryInstrument.reading(mode: mode, metrics: metrics, days: 7, now: self.now)
        #expect(try abs(#require(reading.amount) - 57.30) < 0.000001)
        metrics.reportedSpend = self.spend(used: 120, limit: 100)
        #expect(NativeOrbitMonetaryInstrument.reading(
            mode: mode, metrics: metrics, days: 7, now: self.now).amount == 0)
    }

    @Test func `subscription quotas keep their normal face even with a monetary extra usage budget`() {
        var metrics = NativeOrbitAccountMetrics()
        metrics.reportedSpend = self.spend(used: 0, limit: 100)
        let windows = [UsageWindow(id: "primary", label: "Session", period: 18000, used: 0, recovery: .none)]
        for provider in [UsageProvider.claude, .codex, .kimi, .gemini, .cursor] {
            #expect(NativeOrbitMonetaryInstrument.mode(provider: provider, windows: windows, metrics: metrics) == nil)
        }
    }

    @Test func `loading subscriptions do not switch their unknown quota face into money`() {
        let unknown = UsageWindow(id: "unknown", label: "Usage", period: 1, used: nil, recovery: .none)
        #expect(NativeOrbitMonetaryInstrument.mode(provider: .claude, windows: [unknown], metrics: .empty) == nil)
        #expect(NativeOrbitMonetaryInstrument
            .mode(provider: .openrouter, windows: [unknown], metrics: .empty) == .spend)
    }

    @Test func `historical money never borrows the current wallet or budget`() {
        let empty = NativeOrbitAccountMetrics()
        for mode in [NativeOrbitMonetaryInstrument.Mode.balance, .budgetRemaining] {
            #expect(NativeOrbitMonetaryInstrument.reading(
                mode: mode, metrics: empty, days: 7, now: self.now).amount == nil)
        }
    }

    @Test func `an uncapped report retains its own billing period rather than claiming selected period spending`() {
        var metrics = NativeOrbitAccountMetrics()
        metrics.reportedSpend = self.spend(used: 80, limit: 0)
        let reading = NativeOrbitMonetaryInstrument.reading(mode: .spend, metrics: metrics, days: 1, now: self.now)
        #expect(reading.amount == 80)
        #expect(reading.period == "Monthly")
        #expect(reading.kind == .spend)
    }

    @Test func `a budget in another unit or against another quota cannot become a monetary main reading`() {
        var metrics = NativeOrbitAccountMetrics()
        metrics.reportedSpend = self.spend(used: 25, limit: 100)
        let windows = [UsageWindow(id: "primary", label: "Requests", period: 3600, used: 0.8, recovery: .none)]
        #expect(NativeOrbitMonetaryInstrument.mode(provider: .openrouter, windows: windows, metrics: metrics) == nil)
        metrics.reportedSpend = ProviderCostSnapshot(
            used: 25, limit: 100, currencyCode: "Points", updatedAt: self.now)
        #expect(NativeOrbitMonetaryInstrument.validBudget(metrics.reportedSpend) == nil)
    }

    @Test func `money help keeps local and workspace attribution`() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        var metrics = NativeOrbitAccountMetrics(usage: .init(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: nil,
            last30DaysCostUSD: nil,
            daily: [.init(
                date: formatter.string(from: self.now),
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: nil,
                costUSD: 3,
                modelsUsed: nil,
                modelBreakdowns: nil)],
            updatedAt: self.now))
        metrics.usageScope = .localMachine
        let local = NativeOrbitMonetaryInstrument.reading(mode: .spend, metrics: metrics, days: 1, now: self.now)
        #expect(local.amount == 3)
        #expect(local.help.contains("on this Mac"))
        metrics.reportedBalance = .init(value: 48, unit: "USD", isWorkspace: true, updatedAt: self.now)
        #expect(NativeOrbitMonetaryInstrument.reading(
            mode: .balance, metrics: metrics, days: 7, now: self.now).help.contains("Workspace"))
    }

    @MainActor @Test func `budget money fits inside each existing gauge opening`() {
        for lanes in 1...3 {
            let size = NativeOrbitMoneyReading.size(lanes: lanes)
            let radius = (NativeOrbitSymbol.radii[lanes - 1] - NativeOrbitSymbol.stroke / 2) * 216 / 256
            #expect(hypot(size.width / 2, size.height / 2) < radius)
        }
    }

    @MainActor @Test func `unknown money retains a normal dash instead of filling the dial`() {
        let rect = CGRect(x: 0, y: 0, width: 192, height: 52)
        let bounds = NativeOrbitMoneyShape(value: "—").path(in: rect).boundingRect
        #expect(bounds.width < rect.width / 2)
        #expect(bounds.height < 12)
        #expect(abs(bounds.midX - rect.midX) < 0.001)
        #expect(abs(bounds.midY - rect.midY) < 0.001)
    }

    @Test func `money faces use plain numbers while help preserves estimates and lower bounds`() {
        for estimated in [false, true] {
            for partial in [false, true] {
                let reading = NativeOrbitMonetaryInstrument.Reading(
                    amount: 12.50, currencyCode: "USD", kind: .spend, estimated: estimated, partial: partial)
                #expect(reading.value == NativeOrbitInstruments.money(12.50, currency: "USD"))
                #expect(!reading.value.contains { "<>≤≥≈~".contains($0) })
                #expect(reading.help.contains("Estimated spend") == estimated)
                #expect(reading.help.contains("or more") == partial)
            }
        }
    }

    @Test func `money formatting preserves the existing locale currency and unknown unit fixtures`() {
        let fixtures: [(locale: String, currency: String, expected: String)] = [
            ("en_US", "USD", "$1,234.50"),
            ("en_GB", "USD", "US$1,234.50"),
            ("en_GB", "JPY", "JP¥1,234.50"),
            ("fr_FR", "USD", "$US1\u{202F}234,50"),
            ("fr_FR", "EUR", "€1\u{202F}234,50"),
            ("de_DE", "USD", "$1.234,50"),
            ("ja_JP", "JPY", "¥1,234.50"),
            ("ar_EG", "USD", "US$١٬٢٣٤٫٥٠"),
            ("zh_TW", "USD", "US$1,234.50"),
            ("en_US", "usd", "$1,234.50"),
            ("en_US", "Credits", "1,234.50 credits"),
            ("fr_FR", "Credits", "1\u{202F}234,50 credits"),
            ("en_US", "TokenUnits", "1,234.50 TokenUnits"),
            ("de_DE", "TokenUnits", "1.234,50 TokenUnits"),
        ]
        // Switching back and forth must preserve each locale's symbols and separators, including non-ISO units.
        for fixture in fixtures + fixtures.reversed() {
            #expect(NativeOrbitInstruments.money(
                1234.5, currency: fixture.currency, locale: Locale(identifier: fixture.locale)) == fixture.expected)
        }
        #expect(NativeOrbitInstruments.money(12.5, currency: "USD")
            == NativeOrbitInstruments.money(12.5, currency: "USD", locale: .current))
    }

    private func spend(used: Double, limit: Double) -> ProviderCostSnapshot {
        .init(used: used, limit: limit, currencyCode: "USD", period: "Monthly", updatedAt: self.now)
    }
}
