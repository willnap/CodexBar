import Foundation
import Testing
@testable import CodexBarCore

struct ProviderWarningMetadataTests {
    @Test(arguments: ["past_due", "unpaid", "suspended"])
    func `Claude retains payment failures without inventing subscription dates`(_ status: String) throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "status": status, "next_charge_at": NSNull(), "next_charge_date": NSNull(),
            "plan_ending_at": NSNull(), "plan_ending_before": NSNull(),
        ])
        let metadata = try ClaudeSubscriptionMetadata.parse(data)
        #expect(metadata.status == status)
        #expect(metadata.expires == nil && metadata.renews == nil)
        let snapshot = metadata.applying(to: UsageSnapshot(primary: nil, secondary: nil, updatedAt: Date()))
        #expect(snapshot.subscriptionStatus == status)
        #expect(snapshot.with(primary: nil, secondary: nil).subscriptionStatus == status)
        let restored = try JSONDecoder().decode(UsageSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(restored.subscriptionStatus == status)
    }

    @Test func `Kimi preserves an inactive subscription even without a usable plan title`() throws {
        let decoded = try JSONDecoder().decode(KimiSubscriptionResponse.self, from: Data(
            #"""
            {"subscription":{"active":false,"status":"SUBSCRIPTION_STATUS_EXPIRED","goods":{"title":"Old plan"}}}
            """#.utf8))
        #expect(decoded.planName == nil)
        let snapshot = KimiUsageSnapshot(
            weekly: nil,
            rateLimit: nil,
            subscriptionBalance: nil,
            subscriptionStatus: decoded.subscription?.status,
            subscriptionIsActive: decoded.subscription?.active,
            updatedAt: Date()).toUsageSnapshot()
        #expect(snapshot.subscriptionStatus == "SUBSCRIPTION_STATUS_EXPIRED")
        #expect(snapshot.subscriptionIsActive == false)
        #expect(snapshot.with(primary: nil, secondary: nil).subscriptionIsActive == false)
        let missing = KimiUsageSnapshot(weekly: nil, rateLimit: nil, updatedAt: Date()).toUsageSnapshot()
        #expect(missing.subscriptionStatus == nil && missing.subscriptionIsActive == nil)
    }

    @Test func `cloud credits retain the provider reason for a locked balance`() throws {
        let credits = try JSONDecoder().decode(ClaudeCloudCreditsSnapshot.self, from: Data(
            #"{"limit_dollars":25,"remaining_dollars":10,"locked_reason":"Organization access suspended"}"#.utf8))
        #expect(credits.isLocked)
        #expect(credits.lockedReason == "Organization access suspended")
        let snapshot = UsageSnapshot(
            primary: nil, secondary: nil, claudeCloudCredits: credits, updatedAt: Date())
        #expect(snapshot.with(primary: nil, secondary: nil).claudeCloudCredits?.lockedReason == credits.lockedReason)
    }

    @Test func `reset eligibility explains an outdated CLI without inventing an empty inventory`() throws {
        let status = try JSONDecoder().decode(ClaudeLimitResetStatusResponse.self, from: Data(
            #"{"eligible":false,"ineligible_reason":"cli_version"}"#.utf8))
        #expect(status.ineligibleReason == "cli_version")
        #expect(status.snapshot(updatedAt: Date()) == nil)
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            claudeResetCreditsIneligibleReason: status.ineligibleReason,
            updatedAt: Date())
        #expect(snapshot.claudeResetCredits == nil)
        #expect(snapshot.with(primary: nil, secondary: nil).claudeResetCreditsIneligibleReason == "cli_version")
    }

    @Test(arguments: [403, 429, 500, 529])
    func `Kimi HTTP failures preserve the status for permission rate limit and overload signals`(_ code: Int) {
        #expect(KimiUsageFetcher.codeAPIError(statusCode: code) == .httpError(code))
    }

    @Test func `Claude OAuth and web publish reset eligibility beside ordinary usage`() throws {
        let data = Data(#"""
        {"five_hour":{"utilization":12},"cedar_ember":{"eligible":false,"ineligible_reason":"cli_version"},
         "iguana_necktie":{"limit_dollars":25,"remaining_dollars":10,"locked_reason":"Credit access suspended"}}
        """#.utf8)
        let usage = try ClaudeUsageFetcher._mapOAuthUsageForTesting(data)
        let snapshot = ClaudeOAuthFetchStrategy._snapshotForTesting(from: usage)
        #expect(snapshot.primary?.usedPercent == 12)
        #expect(snapshot.claudeResetCredits == nil)
        #expect(snapshot.claudeResetCreditsIneligibleReason == "cli_version")
        #expect(snapshot.claudeCloudCredits?.lockedReason == "Credit access suspended")
        let web = try ClaudeWebAPIFetcher._parseUsageResponseForTesting(data)
        #expect(web.resetCredits == nil)
        #expect(web.resetCreditsIneligibleReason == "cli_version")
    }

    @Test func `Kimi live subscription enrichment retains inactive status without a plan name`() async throws {
        let transport = ProviderHTTPTransportHandler { request in
            let url = try #require(request.url)
            let json = if url.path.hasSuffix("/GetSubscription") {
                #"{"subscription":{"active":false,"status":"SUBSCRIPTION_STATUS_EXPIRED"}}"#
            } else if url.path.hasSuffix("/GetSubscriptionStats") {
                "{}"
            } else {
                #"""
                {"usages":[{"scope":"FEATURE_CODING",
                "detail":{"limit":"100","used":"25","remaining":"75"},"limits":[]}]}
                """#
            }
            return try (Data(json.utf8), #require(HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
        let snapshot = try await KimiUsageFetcher.fetchUsage(
            authToken: "synthetic-subscription-token", transport: transport).toUsageSnapshot()
        #expect(snapshot.subscriptionIsActive == false)
        #expect(snapshot.subscriptionStatus == "SUBSCRIPTION_STATUS_EXPIRED")
        #expect(snapshot.primary?.usedPercent == 25)
    }
}
