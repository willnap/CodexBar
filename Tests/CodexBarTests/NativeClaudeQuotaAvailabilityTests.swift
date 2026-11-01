import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct NativeClaudeQuotaAvailabilityTests {
    @Test(
        arguments: ["", #""five_hour":null,"#, #""five_hour":{"resets_at":"2026-11-01T15:00:00Z"},"#],
        ["seven_day", "seven_day_oauth_apps"])
    func `weekly only OAuth usage renders one quota across card and gauges`(
        session: String, weeklyKey: String) throws
    {
        let usage = try ClaudeUsageFetcher._mapOAuthUsageForTesting(Data("""
        {\(session)"\(weeklyKey)":{"utilization":42,"resets_at":"2026-11-05T12:00:00Z"}}
        """.utf8))
        let snapshot = ClaudeOAuthFetchStrategy._snapshotForTesting(from: usage)
        let model = try self.model(snapshot)
        #expect(model.metrics.map(\.id) == ["secondary"])
        #expect(model.metrics.map(\.percent) == [42])
        for metrics in [nil, model.metrics] {
            let gauge = NativeUsageGaugeProjection.state(
                provider: .claude, snapshot: snapshot, visibleMetrics: metrics)
            #expect(gauge.resolvedWindows.map(\.id) == ["secondary"])
            #expect(gauge.resolvedWindows.first?.usedFraction == 0.42)
        }
        let selected = MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic, provider: .claude, snapshot: snapshot, supportsAverage: false)
        #expect(selected == snapshot.secondary)
    }

    @Test
    func `session bars disappear and return with reported limits even when percentages match`() throws {
        for used in ["42", "null", "0"] {
            let fiveHour = used == "null" ? "null" : "{\"utilization\":\(used)}"
            let usage = try ClaudeUsageFetcher._mapOAuthUsageForTesting(Data("""
            {"five_hour":\(fiveHour),"seven_day":{"utilization":42}}
            """.utf8))
            let snapshot = ClaudeOAuthFetchStrategy._snapshotForTesting(from: usage)
            let expected = used == "null" ? ["secondary"] : ["primary", "secondary"]
            #expect(try self.model(snapshot).metrics.map(\.id) == expected)
            let gauge = NativeUsageGaugeProjection.state(provider: .claude, snapshot: snapshot)
            #expect(Set(gauge.resolvedWindows.map(\.id)) == Set(expected))
        }
    }

    private func model(_ snapshot: UsageSnapshot) throws -> UsageMenuCardView.Model {
        try UsageMenuCardView.Model.make(.init(
            provider: .claude,
            metadata: #require(ProviderDefaults.metadata[.claude]),
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: true,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: true,
            now: snapshot.updatedAt))
    }
}
