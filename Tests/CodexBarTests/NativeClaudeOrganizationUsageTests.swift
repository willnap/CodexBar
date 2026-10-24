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
        #expect(local.isAccountAttributed)
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

    @Test @MainActor
    func `all retains every separately owned Claude organization in both metrics and histories`() throws {
        let now = Date(timeIntervalSince1970: 1_800_014_400)
        let accounts = [
            self.account(slot: "1", organization: self.first),
            self.account(slot: "2", organization: self.second),
        ]
        let reports = [self.first: 100, self.second: 200].mapValues { tokens in
            CostUsageTokenSnapshot(
                sessionTokens: nil,
                sessionCostUSD: nil,
                last30DaysTokens: nil,
                last30DaysCostUSD: nil,
                daily: [],
                quotaSlices: [.init(
                    timestamp: now.addingTimeInterval(-3600),
                    totalTokens: tokens,
                    costUSD: Double(tokens) / 100)],
                updatedAt: now)
        }
        let publication = ClaudeOrganizationUsagePublication(
            owners: [accounts[0].id: self.first, accounts[1].id: self.second],
            bucketTimeZoneIdentifier: "UTC",
            reports: reports)
        let rows = try accounts.map { account in
            let local = try #require(UsageStore.nativeOrbitClaudeLocalUsage(
                account: account, accounts: accounts, bucketTimeZoneIdentifier: "UTC", publication: publication))
            var gauge = ComputeGauge.State()
            gauge.provider = "claude"
            return NativeOrbitAccountPresentation(
                id: account.id.opaqueID,
                label: account.displayLabel,
                email: nil,
                symbol: "leaf",
                isActive: account.isActive,
                canActivate: false,
                gauge: gauge,
                updatedAt: now,
                history: [],
                odometer: nil,
                odometerHelp: nil,
                statusText: nil,
                selection: .none,
                metrics: .make(provider: .claude, snapshot: nil, usage: nil, now: now, localUsage: local))
        }
        let model = NativeCombinedAccounts(connections: [.init(provider: .claude, accounts: rows)], now: now)
        #expect(model.summary(days: 1, now: now).tokens == 300)
        #expect(model.summary(days: 1, now: now).costs == ["USD": 3])
        for metric in [NativeCombinedMetric.tokens, .money(currency: "USD")] {
            #expect(Set(model.shares(metric: metric, days: 1, now: now).map(\.id)) == Set(model.pages.map(\.id)))
            let series = NativeCombinedTokenHistory.make(model: model, days: 1, now: now, metric: metric)
            #expect(Set(series.map(\.id)) == Set(model.pages.map(\.id)))
            #expect(series.compactMap { $0.points.last?.value }.reduce(0, +) == (metric == .tokens ? 300 : 3))
        }
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
