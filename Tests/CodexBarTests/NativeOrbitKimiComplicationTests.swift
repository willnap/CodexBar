import Foundation
import SwiftUI
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct NativeOrbitKimiComplicationTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func `Kimi zero monthly spend does not invent a balance or activate an unconfirmed cap`() throws {
        let snapshot = try self.snapshot(wallet: [
            "balance": ["type": "BOOSTER", "unit": "UNIT_CURRENCY"],
            "monthlyUsed": ["currency": "USD", "priceInCents": "0"],
            "monthlyChargeLimit": ["currency": "USD", "priceInCents": "10000"],
        ])
        let cost = try #require(snapshot.providerCost)
        #expect(cost.used == 0)
        #expect(cost.currencyCode == "USD")
        #expect(cost.period == "Monthly")
        #expect(cost.limit == 0, "A configured cap without enablement cannot become an active budget")
        #expect(cost.balance == nil, "Absent balance fields cannot prove zero")
        #expect(snapshot.kimiRequestQuotas?.first?.used == 10)
    }

    @Test func `funded camel case wallet preserves fixed point dollars and enabled monthly budget`() throws {
        let snapshot = try self.snapshot(wallet: [
            "balance": ["type": "BOOSTER", "unit": "UNIT_CURRENCY", "amountLeft": "250000000"],
            "monthlyUsed": ["currency": "USD", "priceInCents": 1234],
            "monthlyChargeLimit": ["currency": "USD", "priceInCents": "2000"],
            "monthlyChargeLimitEnabled": true,
        ], walletKey: "boosterWallet")
        let metrics = NativeOrbitAccountMetrics.make(provider: .kimi, snapshot: snapshot, usage: nil, now: self.now)
        #expect(metrics.reportedSpend?.used == 12.34)
        #expect(metrics.reportedSpend?.limit == 20)
        #expect(metrics.reportedBalance?.value == 2.5)
        #expect(metrics.extraUsageFraction == 0.617)
        #expect(metrics.summary(days: 7, now: self.now).cost == nil)
    }

    @Test func `balance only wallet cannot claim zero booster spending`() throws {
        let snapshot = try self.snapshot(wallet: [
            "balance": ["type": "BOOSTER", "unit": "UNIT_CURRENCY", "amountLeft": "0"],
            "monthlyChargeLimit": ["currency": "USD", "priceInCents": "10000"],
        ])
        let metrics = NativeOrbitAccountMetrics.make(provider: .kimi, snapshot: snapshot, usage: nil, now: self.now)
        #expect(metrics.reportedBalance?.value == 0)
        #expect(metrics.reportedSpend == nil)
    }

    @Test func `Kimi request allowances and deadlines cannot masquerade as tokens or banked resets`() throws {
        let snapshot = try self.snapshot(wallet: [
            "balance": ["type": "BOOSTER", "unit": "UNIT_CURRENCY"],
            "monthlyUsed": ["currency": "USD", "priceInCents": "0"],
        ])
        let metrics = NativeOrbitAccountMetrics.make(provider: .kimi, snapshot: snapshot, usage: nil, now: self.now)
        let account = NativeOrbitAccountPresentation(
            id: "kimi-fixture",
            label: "Fixture",
            email: nil,
            symbol: "person",
            isActive: true,
            canActivate: false,
            gauge: .init(),
            updatedAt: self.now,
            history: [],
            odometer: nil,
            odometerHelp: nil,
            statusText: nil,
            selection: .none,
            metrics: metrics)
        let view = NativeOrbitInstruments(account: account, days: 7, now: self.now, accent: .blue)
        let labels = Self.cornerLabels(view.body)
        #expect(labels.count == 4)
        #expect(labels.contains { $0.contains("$0.00") && $0.contains("this month") })
        #expect(labels.contains { $0.hasPrefix("No token count for") })
        #expect(labels.contains { $0 == "Banked resets unavailable" })
        #expect(labels.contains { $0.contains("additional usage") && $0.contains("$0.00") })
        #expect(!labels.contains { $0.contains("10 of 100 requests") || $0.contains("allowance resets") })
    }

    @Test func `Kimi history restores measured requests and exact resets without future borrowing`() throws {
        // A reading stands until its lane's next poll is overdue (15 minutes for a single reading), never earlier.
        let snapshot = try self.snapshot(wallet: [:])
        let samples = UsageStore.nativeOrbitHistorySamples(provider: .kimi, snapshot: snapshot)
        let allowance = try #require(samples.first { $0.name.rawValue == "nativeMetric:allowances" })
        let data = try JSONEncoder().encode(allowance.entry)
        let entry = try JSONDecoder().decode(PlanUtilizationHistoryEntry.self, from: data)
        let histories = [PlanUtilizationSeriesHistory(name: allowance.name, windowMinutes: 0, entries: [entry])]
        var metrics = NativeOrbitAccountMetrics.make(provider: .kimi, snapshot: snapshot, usage: nil, now: self.now)
        metrics.reportedQuotaUsage = [.init(
            id: "secondary",
            title: "Rate limit",
            used: 80,
            limit: 100,
            windowMinutes: 300,
            resetsAt: self.now.addingTimeInterval(3600.875))]
        let past = metrics.at(
            self.now,
            observedAt: self.now.addingTimeInterval(300),
            history: histories)
        #expect(past.reportedQuotaUsage.first?.used == 10)
        #expect(past.reportedQuotaUsage.first?.resetsAt == self.now.addingTimeInterval(3600.875))
        #expect(metrics.at(self.now.addingTimeInterval(-1), observedAt: self.now, history: histories)
            .reportedQuotaUsage.isEmpty)
        #expect(metrics.at(self.now.addingTimeInterval(901), observedAt: self.now, history: histories)
            .reportedQuotaUsage.isEmpty)
        for seconds in [60.0, 840] {
            let between = metrics.at(self.now.addingTimeInterval(seconds), observedAt: self.now, history: histories)
            #expect(between.reportedQuotaUsage.first?.used == 10)
            #expect(between.reportedQuotaUsage.first?.resetsAt == self.now.addingTimeInterval(3600.875))
        }
    }

    @Test func `optional malformed Kimi wallet does not suppress valid quota readings`() throws {
        let snapshot = try self.snapshot(wallet: ["monthlyUsed": "invalid"])
        #expect(snapshot.secondary?.usedPercent == 10)
        #expect(snapshot.providerCost == nil)
    }

    @Test func `malformed optional wallet balance preserves valid monthly spending`() throws {
        let snapshot = try self.snapshot(wallet: [
            "balance": ["type": "BOOSTER", "unit": "UNIT_CURRENCY", "amountLeft": "invalid"],
            "monthlyUsed": ["currency": "USD", "priceInCents": "1234"],
        ])
        #expect(snapshot.providerCost?.used == 12.34)
        #expect(snapshot.providerCost?.balance == nil)
    }

    @Test func `malformed wallet unit cannot turn an unverified balance into currency`() throws {
        let snapshot = try self.snapshot(wallet: [
            "balance": ["type": "BOOSTER", "unit": 123, "amountLeft": "250000000"],
            "monthlyUsed": ["currency": "USD", "priceInCents": "1234"],
        ])
        #expect(snapshot.providerCost?.used == 12.34)
        #expect(snapshot.providerCost?.balance == nil)
    }

    @Test func `balance only detail card cannot turn an enabled budget into zero spend`() throws {
        let snapshot = try self.snapshot(wallet: [
            "balance": ["type": "BOOSTER", "unit": "UNIT_CURRENCY", "amountLeft": "250000000"],
            "monthlyChargeLimit": ["currency": "USD", "priceInCents": "10000"],
            "monthlyChargeLimitEnabled": true,
        ])
        let section = try #require(UsageMenuCardView.Model.providerCostSection(
            cost: snapshot.providerCost, style: .generic))
        #expect(section.spendLine == "Balance: $2.50")
        #expect(section.percentUsed == nil)
        #expect(StatusItemController.extraUsageSpendDisplayText(snapshot: snapshot) == nil)
    }

    @Test func `new balance only observation invalidates earlier historical monthly spend`() throws {
        let first = try self.snapshot(wallet: [
            "balance": ["type": "BOOSTER"],
            "monthlyUsed": ["currency": "USD", "priceInCents": "1234"],
        ])
        let next = try self.snapshot(wallet: [
            "balance": ["type": "BOOSTER", "amountLeft": "250000000"],
            "monthlyChargeLimit": ["currency": "USD", "priceInCents": "10000"],
        ], at: self.now.addingTimeInterval(60))
        let history = Self.histories([first, next])
        let current = NativeOrbitAccountMetrics.make(provider: .kimi, snapshot: next, usage: nil, now: next.updatedAt)
        #expect(current.at(self.now, observedAt: next.updatedAt, history: history)
            .reportedSpend?.used == 12.34)
        #expect(current.at(next.updatedAt, observedAt: next.updatedAt, history: history)
            .reportedSpend == nil)
    }

    @Test func `new ratio only response invalidates earlier historical request counters`() throws {
        let first = try self.snapshot(wallet: [:])
        let next = UsageSnapshot(primary: first.primary, secondary: nil, updatedAt: self.now.addingTimeInterval(60))
        let history = Self.histories([first, next])
        let current = NativeOrbitAccountMetrics.make(provider: .kimi, snapshot: next, usage: nil, now: next.updatedAt)
        #expect(current.at(self.now, observedAt: next.updatedAt, history: history)
            .reportedQuotaUsage.first?.used == 10)
        #expect(current.at(next.updatedAt, observedAt: next.updatedAt, history: history)
            .reportedQuotaUsage.isEmpty)
    }

    private static func histories(_ snapshots: [UsageSnapshot]) -> [PlanUtilizationSeriesHistory] {
        let samples = snapshots.flatMap { UsageStore.nativeOrbitHistorySamples(provider: .kimi, snapshot: $0) }
        return Dictionary(grouping: samples, by: \.name).map { name, samples in
            PlanUtilizationSeriesHistory(name: name, windowMinutes: 0, entries: samples.map(\.entry))
        }
    }

    private func snapshot(
        wallet: [String: Any],
        walletKey: String = "booster_wallet",
        at date: Date? = nil) throws -> UsageSnapshot
    {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let reset = formatter.string(from: self.now.addingTimeInterval(3600.875))
        let payload: [String: Any] = [
            "limits": [[
                "window": ["duration": 300, "timeUnit": "TIME_UNIT_MINUTE"],
                "detail": ["limit": "100", "used": "10", "remaining": "90", "resetTime": reset],
            ]],
            "usages": ["limit_5h": ["used_ratio": 0.099, "reset_time": reset]],
            walletKey: wallet,
        ]
        return try KimiUsageFetcher.parseCodeAPIUsage(
            from: JSONSerialization.data(withJSONObject: payload), now: date ?? self.now).toUsageSnapshot()
    }

    /// Traverse the actual constructed SwiftUI corner views; assertions inspect their consumer-visible readouts.
    private static func cornerLabels(_ value: Any, depth: Int = 0) -> [String] {
        if let view = value as? NativeOrbitComplication { return [view.help] }
        if let view = value as? NativeOrbitResetComplication { return [view.help] }
        if let view = value as? NativeOrbitExtraUsageComplication { return [view.help] }
        guard depth < 30 else { return [] }
        return Mirror(reflecting: value).children.flatMap { self.cornerLabels($0.value, depth: depth + 1) }
    }
}
