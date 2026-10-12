import Foundation
import Testing
@testable import CodexBarCore

struct NativeClaudeComplicationSourceTests {
    @Test func `OAuth and web preserve typed monthly money even when extra usage is disabled`() throws {
        for (minor, exponent, currency) in [(0, 2, "USD"), (325, 2, "USD"), (123, 0, "JPY")] {
            let data = try JSONSerialization.data(withJSONObject: [
                "five_hour": ["utilization": 12],
                "spend": [
                    "enabled": false,
                    "used": ["amount_minor": minor, "exponent": exponent, "currency": currency],
                    "limit": ["amount_minor": 20000, "exponent": exponent, "currency": currency],
                ],
            ])
            let oauth = try ClaudeUsageFetcher._mapOAuthUsageForTesting(data)
            let web = try ClaudeWebAPIFetcher._parseUsageResponseForTesting(data)
            for cost in [oauth.providerCost, web.extraUsageCost] {
                let cost = try #require(cost)
                #expect(cost.used == Double(minor) / pow(10, Double(exponent)))
                #expect(cost.limit == 0)
                #expect(cost.currencyCode == currency)
                #expect(cost.period == "Monthly")
            }
        }
    }

    @Test func `typed enabled spend preserves its cap and malformed optional money keeps quotas`() throws {
        for minor in [325, -1] {
            let data = try JSONSerialization.data(withJSONObject: [
                "five_hour": ["utilization": 12],
                "spend": [
                    "enabled": true,
                    "used": ["amount_minor": minor, "exponent": 2, "currency": "USD"],
                    "limit": ["amount_minor": 20000, "exponent": 2, "currency": "USD"],
                ],
            ])
            let oauth = try ClaudeUsageFetcher._mapOAuthUsageForTesting(data)
            #expect(oauth.primary.usedPercent == 12)
            #expect(oauth.providerCost?.limit == (minor >= 0 ? 200 : nil))
        }
    }

    @Test func `disabled extra usage keeps measured spend when unused cap is malformed`() throws {
        let data = Data("""
        {"five_hour":{"utilization":12},"spend":{"enabled":false,
        "used":{"amount_minor":325,"exponent":2,"currency":"USD"},"limit":"unavailable"}}
        """.utf8)
        #expect(try ClaudeUsageFetcher._mapOAuthUsageForTesting(data).providerCost?.used == 3.25)
        #expect(try ClaudeWebAPIFetcher._parseUsageResponseForTesting(data).extraUsageCost?.used == 3.25)
    }

    @Test func `adapter keeps per account reset inventories at the original fetch time`() throws {
        let timestamp = "2026-10-12T10:00:00.125Z"
        let data = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "activeAccountNumber": 2,
            "accounts": [1, 2].map { slot in
                [
                    "number": slot, "email": "fixture\(slot)@example.com", "active": slot == 2,
                    "usageStatus": "ok", "usageFetchedAt": timestamp,
                    "usage": [
                        "fiveHour": ["pct": 12],
                        "resetCredits": [
                            "availableExpirations": Array(repeating: NSNull(), count: slot),
                            "usedExpirations": ["2026-10-13T00:00:00Z"],
                        ],
                    ],
                ] as [String: Any]
            },
        ])
        let list = try ClaudeSwapListParser.parse(data)
        let accounts = ClaudeSwapAccountProjection.accountSnapshots(from: list)
        for account in accounts {
            let resets = try #require(account.snapshot?.claudeResetCredits)
            #expect(resets.expirations.count == Int(account.id.opaqueID))
            #expect(resets.usedExpirations.count == 1)
            #expect(resets.updatedAt == ISO8601DateParser.parse(timestamp))
        }
    }
}
