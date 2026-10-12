import Foundation
import Testing
@testable import CodexBarCore

struct NativePluginMeasurementTests {
    private let now = Date(timeIntervalSince1970: 1_791_806_400)

    @Test func `old source windows cannot establish current daily coverage`() throws {
        let snapshot = try ProviderPluginSnapshotMapper.map(
            JSONProviderPluginValue([
                "costUsage": [
                    "currency": "USD", "historyDays": 30, "windowEnd": "2026-01-31",
                    "entries": [["date": "2026-01-31", "totalTokens": 140, "cost": 2.5]],
                ],
            ]),
            provider: .lithosai,
            now: self.now)
        #expect(snapshot.costUsage?.historyCoverageIsEstablished == false)
        #expect(snapshot.costUsage?.updatedAt == self.now)
    }

    @Test func `independent aggregate token totals retain daily request money and pricing evidence`() throws {
        let snapshot = try ProviderPluginSnapshotMapper.map(
            JSONProviderPluginValue([
                "costUsage": [
                    "currency": "USD", "historyDays": 12, "windowEnd": "2026-10-12",
                    "totals": ["totalTokens": 140],
                    "entries": [["date": "2026-10-12", "requests": 2, "cost": 3.0, "estimatedCost": 3.0]],
                ],
            ]),
            provider: .bifrost,
            now: self.now)
        #expect(snapshot.costUsage?.last30DaysTokens == 140)
        #expect(snapshot.costUsage?.last30DaysRequests == 2)
        #expect(snapshot.costUsage?.last30DaysCostUSD == 3)
        #expect(snapshot.costUsage?.costProvenance == .listPriceEstimate)
    }

    @Test func `wallet projection retains explicit absence of spending and its observation time`() throws {
        let snapshot = try ProviderPluginSnapshotMapper.map(
            JSONProviderPluginValue([
                "cost": ["used": 12.5, "balance": 12.5, "currency": "USD", "usageIsUnavailable": true],
            ]),
            provider: .helmcode,
            now: self.now)
        #expect(snapshot.providerCost?.balance == 12.5)
        #expect(snapshot.providerCost?.usageIsUnavailable == true)
        #expect(snapshot.providerCost?.balanceUpdatedAt == self.now)
    }

    @Test func `daily money without token or request counters preserves unknown counts`() throws {
        let snapshot = try ProviderPluginSnapshotMapper.map(
            JSONProviderPluginValue([
                "costUsage": [
                    "currency": "USD",
                    "historyDays": 12,
                    "windowEnd": "2026-10-12",
                    "entries": [["date": "2026-10-12", "cost": 2.5]],
                ],
            ]),
            provider: .lithosai,
            now: self.now)
        let report = try #require(snapshot.costUsage)
        #expect(report.daily.first?.costUSD == 2.5)
        #expect(report.daily.first?.totalTokens == nil)
        #expect(report.daily.first?.requestCount == nil)
        #expect(report.last30DaysTokens == nil)
        #expect(report.last30DaysRequests == nil)
        #expect(report.last30DaysCostUSD == 2.5)
    }

    @Test func `daily independently measured token total does not invent its breakdown or money`() throws {
        let snapshot = try ProviderPluginSnapshotMapper.map(
            JSONProviderPluginValue([
                "costUsage": [
                    "currency": "XXX",
                    "historyDays": 12,
                    "windowEnd": "2026-10-12",
                    "entries": [["date": "2026-10-12", "totalTokens": 140, "requests": 2]],
                ],
            ]),
            provider: .bifrost,
            now: self.now)
        let report = try #require(snapshot.costUsage)
        #expect(report.daily.first?.totalTokens == 140)
        #expect(report.daily.first?.inputTokens == nil)
        #expect(report.daily.first?.outputTokens == nil)
        #expect(report.daily.first?.requestCount == 2)
        #expect(report.last30DaysCostUSD == nil)
    }

    @Test func `empty money only history cannot invent token and request zeroes`() throws {
        let snapshot = try ProviderPluginSnapshotMapper.map(
            JSONProviderPluginValue([
                "costUsage": [
                    "currency": "USD",
                    "historyDays": 12,
                    "windowEnd": "2026-10-12",
                    "metrics": ["cost": true],
                    "entries": [],
                ],
            ]),
            provider: .lithosai,
            now: self.now)
        #expect(snapshot.costUsage?.last30DaysCostUSD == 0)
        #expect(snapshot.costUsage?.last30DaysTokens == nil)
        #expect(snapshot.costUsage?.last30DaysRequests == nil)
    }

    @Test func `missing prices cannot erase mixed known pricing provenance`() throws {
        let snapshot = try ProviderPluginSnapshotMapper.map(
            JSONProviderPluginValue([
                "costUsage": [
                    "currency": "USD",
                    "historyDays": 12,
                    "windowEnd": "2026-10-12",
                    "entries": [
                        ["date": "2026-10-12", "cost": 2.0],
                        ["date": "2026-10-11", "cost": 3.0, "estimatedCost": 3.0],
                        ["date": "2026-10-10", "totalTokens": 20],
                    ],
                ],
            ]),
            provider: .bifrost,
            now: self.now)
        #expect(snapshot.costUsage?.last30DaysCostUSD == nil)
        #expect(snapshot.costUsage?.costProvenance == .mixed)
    }

    @Test func `aggregate provider counters retain their source period without invented daily buckets`() throws {
        let snapshot = try ProviderPluginSnapshotMapper.map(
            JSONProviderPluginValue([
                "costUsage": [
                    "currency": "XXX",
                    "historyDays": 1,
                    "windowEnd": "2026-10-12",
                    "historyLabel": "Provider cumulative usage",
                    "historyCoverageIsEstablished": false,
                    "totals": ["totalTokens": 140, "requests": 2],
                    "entries": [],
                ],
            ]),
            provider: .llmproxy,
            now: self.now)
        #expect(snapshot.costUsage?.last30DaysTokens == 140)
        #expect(snapshot.costUsage?.last30DaysRequests == 2)
        #expect(snapshot.costUsage?.last30DaysCostUSD == nil)
        #expect(snapshot.costUsage?.daily.isEmpty == true)
        #expect(snapshot.costUsage?.historyCoverageIsEstablished == false)
    }
}
