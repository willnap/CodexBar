import Foundation
import Testing
@testable import CodexBarCore

struct ClaudeOAuthUsageMappingTests {
    @Test
    func `oauth usage keeps weekly and model windows in their own slots when five hour is absent`() throws {
        let json = """
        {
          "seven_day": { "utilization": 42, "resets_at": "2025-12-29T23:00:00.000Z" },
          "seven_day_sonnet": { "utilization": 17, "resets_at": "2025-12-29T23:00:00.000Z" }
        }
        """
        let snapshot = try ClaudeUsageFetcher._mapOAuthUsageForTesting(Data(json.utf8))

        #expect(snapshot.primary == nil)
        #expect(snapshot.secondary?.usedPercent == 42)
        #expect(snapshot.secondary?.windowMinutes == 7 * 24 * 60)
        #expect(snapshot.opus?.usedPercent == 17)
    }

    @Test
    func `oauth usage leaves session absent when five hour has no utilization`() throws {
        let json = """
        {
          "five_hour": { "resets_at": "2025-12-23T16:00:00.000Z" },
          "seven_day": { "utilization": 9, "resets_at": "2025-12-29T23:00:00.000Z" }
        }
        """
        let snapshot = try ClaudeUsageFetcher._mapOAuthUsageForTesting(Data(json.utf8))

        #expect(snapshot.primary == nil)
        #expect(snapshot.secondary?.usedPercent == 9)
    }

    @Test(arguments: ["seven_day_sonnet", "seven_day_opus", "seven_day_oauth_apps", "seven_day_routines"])
    func `oauth usage accepts a remaining allowance without inventing a session`(key: String) throws {
        let data = Data("""
        {"five_hour":null,"\(key)":{"utilization":17,"resets_at":"2026-11-05T12:00:00Z"}}
        """.utf8)
        let snapshot = try ClaudeUsageFetcher._mapOAuthUsageForTesting(data)
        #expect(snapshot.primary == nil)
        #expect((snapshot.secondary != nil) == (key == "seven_day_oauth_apps"))
        let remaining = [snapshot.secondary, snapshot.opus].compactMap(\.self)
            + snapshot.extraRateWindows.map(\.window)
        #expect(remaining.count == 1)
        #expect(remaining.first?.usedPercent == 17)
    }

    @Test(arguments: ["{}", #"{"utilization":null}"#])
    func `unmeasured sonnet does not mask the remaining opus allowance`(sonnet: String) throws {
        let data = Data("""
        {"five_hour":null,"seven_day_sonnet":\(sonnet),"seven_day_opus":{"utilization":17}}
        """.utf8)
        let snapshot = try ClaudeUsageFetcher._mapOAuthUsageForTesting(data)
        #expect(snapshot.primary == nil)
        #expect(snapshot.opus?.usedPercent == 17)
    }

    @Test
    func `weekly quota keeps extra usage as an overage allowance without a session`() throws {
        let data = Data(#"""
        {"five_hour":null,"seven_day":{"utilization":42},
         "extra_usage":{"is_enabled":true,"monthly_limit":10000,"used_credits":2500}}
        """#.utf8)
        let snapshot = try ClaudeUsageFetcher._mapOAuthUsageForTesting(data)
        #expect(snapshot.primary == nil)
        #expect(snapshot.providerCost?.period == "Monthly cap")
    }

    @Test
    func `oauth usage accepts only a scoped weekly allowance`() throws {
        let data = Data(#"""
        {"five_hour":null,"seven_day":null,"limits":[
          {"kind":"weekly_scoped","group":"weekly","percent":17,
           "scope":{"model":{"display_name":"Fixture"}}}
        ]}
        """#.utf8)
        let snapshot = try ClaudeUsageFetcher._mapOAuthUsageForTesting(data)
        #expect(snapshot.primary == nil)
        #expect(snapshot.secondary == nil)
        #expect(snapshot.extraRateWindows.count == 1)
        #expect(snapshot.extraRateWindows.first?.window.usedPercent == 17)
    }

    @Test
    func `oauth usage throws when no usable windows are present`() {
        let json = "{}"

        #expect(throws: ClaudeUsageError.self) {
            try ClaudeUsageFetcher._mapOAuthUsageForTesting(Data(json.utf8))
        }
    }
}
