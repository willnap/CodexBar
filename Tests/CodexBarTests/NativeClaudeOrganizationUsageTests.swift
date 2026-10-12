import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct NativeClaudeOrganizationUsageTests {
    private let first = "11111111-1111-1111-1111-111111111111"
    private let second = "22222222-2222-2222-2222-222222222222"

    @Test func `named transcript reports require unique current organization ownership`() throws {
        let account = self.account(
            slot: "1",
            organization: self.first)
        let report = CostUsageTokenSnapshot(
            sessionTokens: 110,
            sessionCostUSD: 0.01,
            last30DaysTokens: 110,
            last30DaysCostUSD: 0.01,
            historyCoverageIsEstablished: false,
            daily: [],
            updatedAt: Date())
        let publication = ClaudeOrganizationUsagePublication(
            owners: [account.id: self.first],
            bucketTimeZoneIdentifier: "UTC",
            reports: [self.first: report])
        let local = try #require(UsageStore.nativeOrbitClaudeLocalUsage(
            account: account,
            accounts: [account],
            bucketTimeZoneIdentifier: "UTC",
            publication: publication))
        #expect(local.scope == .localMachine)
        #expect(local.snapshot.sessionTokens == 110)
        #expect(UsageStore.nativeOrbitClaudeLocalUsage(
            account: account,
            accounts: [account, self.account(
                slot: "2",
                organization: self.first)],
            bucketTimeZoneIdentifier: "UTC",
            publication: publication) == nil)
        #expect(UsageStore.nativeOrbitClaudeLocalUsage(
            account: self.account(
                slot: "1",
                organization: self.second),
            accounts: [self.account(
                slot: "1",
                organization: self.second)],
            bucketTimeZoneIdentifier: "UTC",
            publication: publication) == nil)
        #expect(UsageStore.nativeOrbitClaudeLocalUsage(
            account: account,
            accounts: [account],
            bucketTimeZoneIdentifier: "Europe/London",
            publication: publication) == nil)
        #expect(UsageStore.nativeOrbitClaudeLocalUsage(
            account: account,
            accounts: [],
            bucketTimeZoneIdentifier: "UTC",
            publication: publication) == nil)
    }

    private func account(
        slot: String,
        organization: String) -> ProviderAccountUsageSnapshot
    {
        ProviderAccountUsageSnapshot(
            id: .init(
                source: "claude-swap",
                opaqueID: slot),
            provider: .claude,
            displayLabel: slot,
            sourceOrganizationID: organization,
            isActive: slot == "1",
            snapshot: nil,
            error: nil,
            sourceLabel: nil)
    }
}
