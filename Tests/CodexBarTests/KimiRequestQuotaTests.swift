import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct KimiRequestQuotaTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func `absolute Kimi request counters survive projection and cache copies without becoming money`() throws {
        let projected = KimiUsageSnapshot(
            weekly: .init(limit: "100", used: "25", remaining: "75", resetTime: nil),
            rateLimit: .init(limit: "20", used: nil, remaining: "12", resetTime: nil),
            updatedAt: self.now)
            .toUsageSnapshot()
        #expect(projected.kimiRequestQuotas?.map(\.remaining) == [75, 12])
        #expect(projected.kimiRequestQuotas?.map(\.used) == [25, 8])
        let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: JSONEncoder().encode(projected))
        #expect(decoded.kimiRequestQuotas == projected.kimiRequestQuotas)
        #expect(decoded.withDataConfidence(.unknown).kimiRequestQuotas == projected.kimiRequestQuotas)
        let metrics = NativeOrbitAccountMetrics.make(provider: .kimi, snapshot: projected, usage: nil, now: self.now)
        #expect(metrics.reportedQuotaUsage.count == 2)
        #expect(metrics.reportedBalance == nil)
        #expect(metrics.reportedSpend == nil)
        #expect(metrics.summary(days: 30, now: self.now).tokens == nil)
        #expect(metrics.summary(days: 30, now: self.now).cost == nil)
    }

    @Test func `unreliable or superseded Kimi counters cannot invent available requests`() throws {
        for used in [nil, "invalid", "-1"] as [String?] {
            let projected = KimiUsageSnapshot(
                weekly: .init(limit: "100", used: used, remaining: nil, resetTime: nil),
                rateLimit: nil,
                updatedAt: self.now).toUsageSnapshot()
            #expect(projected.kimiRequestQuotas == nil)
        }
        let data = Data(#"{"usage":{"limit":"100","used":"25"},"usages":{"limit_7d":{"used_ratio":0.5}}}"#.utf8)
        let projected = try KimiUsageFetcher.parseCodeAPIUsage(from: data, now: self.now).toUsageSnapshot()
        #expect(projected.primary?.usedPercent == 50)
        #expect(projected.kimiRequestQuotas == nil)
        let overage = KimiUsageSnapshot(
            weekly: .init(limit: "100", used: "125", remaining: nil, resetTime: nil),
            rateLimit: nil,
            updatedAt: self.now).toUsageSnapshot()
        #expect(overage.kimiRequestQuotas?.first?.used == 125)
        #expect(overage.kimiRequestQuotas?.first?.remaining == 0)
    }
}
