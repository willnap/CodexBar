import Foundation
import Testing
@testable import CodexBarCore

struct ClaudeSwapResetCreditProjectionTests {
    @Test func `reset inventory alone produces an account snapshot at its measurement time`() throws {
        let fetched = Date(timeIntervalSince1970: 1_800_000_000)
        let credits = ClaudeRateLimitResetCreditsSnapshot(
            expirations: [fetched.addingTimeInterval(86400)],
            updatedAt: fetched,
            usedExpirations: [fetched.addingTimeInterval(43200)])
        let row = ClaudeSwapAccountRow(
            number: 1,
            email: "fixture@example.test",
            isActive: true,
            usageStatus: .ok,
            fiveHour: nil,
            sevenDay: nil,
            usageFetchedAt: fetched,
            resetCredits: credits)
        let account = try #require(ClaudeSwapAccountProjection.accountSnapshots(
            from: .init(
                activeAccountNumber: 1,
                accounts: [row]),
            now: fetched.addingTimeInterval(60)).first)
        let snapshot = try #require(account.snapshot)
        #expect(snapshot.claudeResetCredits == credits)
        #expect(snapshot.updatedAt == fetched)
    }

    @Test func `unavailable exhausted rows retain reset inventory and spend while pruning expired windows`() throws {
        let fetched = Date(timeIntervalSince1970: 1_800_000_000)
        let now = fetched.addingTimeInterval(60)
        let credits = ClaudeRateLimitResetCreditsSnapshot(
            expirations: [nil],
            updatedAt: fetched)
        let row = ClaudeSwapAccountRow(
            number: 1,
            email: "fixture@example.test",
            isActive: true,
            usageStatus: .unavailable,
            fiveHour: .init(
                usedPercent: 100,
                resetsAt: now.addingTimeInterval(3600)),
            sevenDay: .init(
                usedPercent: 100,
                resetsAt: fetched),
            usageFetchedAt: fetched,
            spend: .init(
                used: 12,
                limit: 20,
                usedPercent: 60,
                currencyCode: "USD",
                resetsAt: nil),
            resetCredits: credits)
        let account = try #require(ClaudeSwapAccountProjection.accountSnapshots(
            from: .init(
                activeAccountNumber: 1,
                accounts: [row]),
            now: now).first)
        let snapshot = try #require(account.snapshot)
        #expect(snapshot.primary?.usedPercent == 100)
        #expect(snapshot.secondary == nil)
        #expect(snapshot.providerCost?.used == 12)
        #expect(snapshot.claudeResetCredits == credits)
        #expect(snapshot.updatedAt == fetched)
    }
}
