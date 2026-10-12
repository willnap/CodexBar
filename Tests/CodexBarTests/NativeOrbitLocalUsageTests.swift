import CryptoKit
import Foundation
import SwiftUI
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct NativeOrbitLocalUsageTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let home = "/tmp/native-orbit-owned-profile"

    @Test func `native metrics reuse available matching Codex profile reports with explicit local provenance`() throws {
        let account = self.account()
        let publication = self.publication(account: account)
        let local = try #require(UsageStore.nativeOrbitCodexLocalUsage(
            account: account,
            homePath: self.home,
            bucketTimeZoneIdentifier: "UTC",
            publication: publication))
        #expect(local.scope == .localProfile)
        let metrics = NativeOrbitAccountMetrics.make(
            provider: .codex,
            snapshot: nil,
            usage: nil,
            now: self.now,
            localUsage: local)
        let summary = metrics.summary(
            days: 1,
            now: self.now)
        #expect(summary.tokens == 1200)
        #expect(summary.cost == 0.25)
        #expect(summary.requests == 3)
        #expect(summary.usageScope == .localProfile)
        let authoritative = NativeOrbitAccountMetrics.make(
            provider: .codex,
            snapshot: nil,
            usage: self.report(tokens: 99),
            now: self.now,
            localUsage: local)
        #expect(authoritative.summary(
            days: 1,
            now: self.now).tokens == 99)
        #expect(authoritative.usageScope == .account)
    }

    @Test func `home reports reject changed credentials path and timezone but keep retained reports`() throws {
        let account = self.account()
        let publication = self.publication(account: account)
        #expect(UsageStore.nativeOrbitCodexLocalUsage(
            account: self.account(fingerprint: "rotated"),
            homePath: self.home,
            bucketTimeZoneIdentifier: "UTC",
            publication: publication) == nil)
        #expect(UsageStore.nativeOrbitCodexLocalUsage(
            account: account,
            homePath: "/tmp/other-profile",
            bucketTimeZoneIdentifier: "UTC",
            publication: publication) == nil)
        #expect(UsageStore.nativeOrbitCodexLocalUsage(
            account: account,
            homePath: self.home,
            bucketTimeZoneIdentifier: "Europe/London",
            publication: publication) == nil)
        // A report retained after a failed refresh is still this home's measured history, as a lower bound.
        let retained = try #require(UsageStore.nativeOrbitCodexLocalUsage(
            account: account,
            homePath: self.home,
            bucketTimeZoneIdentifier: "UTC",
            publication: self.publication(
                account: account,
                state: .staleLastKnown)))
        #expect(retained.isStale)
        #expect(NativeOrbitAccountMetrics.make(
            provider: .codex, snapshot: nil, usage: nil, now: self.now, localUsage: retained)
            .summary(days: 1, now: self.now).isPartial)
        for state in [SpendSourcePublication.State.loading, .unavailable, .confirmedEmpty] {
            #expect(UsageStore.nativeOrbitCodexLocalUsage(
                account: account,
                homePath: self.home,
                bucketTimeZoneIdentifier: "UTC",
                publication: self.publication(account: account, state: state, includesInput: state != .loading)) == nil)
        }
        // A probe home that never ran a session is no spend evidence.
        #expect(UsageStore.nativeOrbitCodexLocalUsage(
            account: account,
            homePath: self.home,
            bucketTimeZoneIdentifier: "UTC",
            publication: self.publication(account: account, report: self.emptyReport())) == nil)
        let live = self.account(live: true)
        #expect(UsageStore.nativeOrbitCodexLocalUsage(
            account: live,
            homePath: self.home,
            bucketTimeZoneIdentifier: "UTC",
            publication: self.publication(account: live))?.scope == .localMachine)
    }

    @Test func `real credit and prepaid balances remain distinct from spend and unavailable balances`() {
        let credits = CreditsSnapshot(
            remaining: 42,
            events: [],
            updatedAt: self.now,
            balanceIsWorkspace: true)
        let metrics = NativeOrbitAccountMetrics.make(
            provider: .codex,
            snapshot: nil,
            usage: nil,
            now: self.now,
            credits: credits)
        #expect(metrics.reportedBalance?.value == 42)
        #expect(metrics.reportedBalance?.unit == "Credits")
        #expect(metrics.reportedBalance?.isWorkspace == true)
        #expect(metrics.reportedSpend == nil)
        let absent = CreditsSnapshot(
            remaining: 0,
            events: [],
            updatedAt: self.now,
            balanceReadSucceeded: false)
        #expect(NativeOrbitAccountMetrics.make(
            provider: .codex,
            snapshot: nil,
            usage: nil,
            now: self.now,
            credits: absent).reportedBalance == nil)
        let zero = CreditsSnapshot(
            remaining: 0,
            events: [],
            updatedAt: self.now)
        #expect(NativeOrbitAccountMetrics.make(
            provider: .codex,
            snapshot: nil,
            usage: nil,
            now: self.now,
            credits: zero).reportedBalance?.value == 0)
    }

    @Test func `quota timing metadata includes optional lanes and reported rolling recovery`() {
        let window = RateWindow(
            usedPercent: 40,
            windowMinutes: 300,
            resetsAt: self.now.addingTimeInterval(300),
            resetDescription: nil,
            nextRegenPercent: 12)
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            extraRateWindows: [NamedRateWindow(
                id: "optional-model",
                title: "Model quota",
                window: window)],
            updatedAt: self.now)
        let windows = UsageStore.nativeOrbitQuotaWindowMap(
            provider: .kimi,
            snapshot: snapshot)
        #expect(windows["nativeQuota:optional-model"]?.nextRegenPercent == 12)
        #expect(windows["nativeQuota:optional-model"]?.resetsAt == window.resetsAt)
    }

    @Test func `a completed scan shows zero for a covered period without activity`() {
        let calendar = CostUsageBucketTimeZone.calendar(identifier: "UTC")
        let past = self.now.addingTimeInterval(-2 * 86400)
        let usage = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: 1200,
            last30DaysCostUSD: 0.25,
            historyDays: 30,
            daily: [.init(
                date: CostUsageLocalDay.key(from: past, calendar: calendar),
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: 1200,
                requestCount: 3,
                costUSD: 0.25,
                modelsUsed: nil,
                modelBreakdowns: nil)], updatedAt: self.now)
        let today = NativeOrbitAccountMetrics(usage: usage).summary(days: 1, now: self.now, calendar: calendar)
        #expect(today.tokens == 0)
        #expect(today.cost == 0)
        #expect(today.requests == 0)
        let week = NativeOrbitAccountMetrics(usage: usage).summary(days: 7, now: self.now, calendar: calendar)
        #expect(week.tokens == 1200)
        #expect(week.cost == 0.25)
        let empty = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: 0,
            last30DaysCostUSD: 0,
            last30DaysRequests: 0,
            historyDays: 30,
            daily: [],
            updatedAt: self.now)
        for days in [1, 7, 30] {
            let summary = NativeOrbitAccountMetrics(usage: empty).summary(
                days: days, now: self.now, calendar: calendar)
            #expect(summary.tokens == 0)
            #expect(summary.cost == 0)
            #expect(summary.requests == 0)
        }
        let incomplete = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: 0,
            last30DaysCostUSD: 0,
            historyDays: 30,
            historyScanIsPartial: true,
            daily: [],
            updatedAt: self.now)
        #expect(NativeOrbitAccountMetrics(usage: incomplete).summary(
            days: 1, now: self.now, calendar: calendar).tokens == nil)
        let unknown = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: 0,
            last30DaysCostUSD: 0,
            historyDays: 30,
            historyCoverageIsEstablished: false,
            daily: [],
            updatedAt: self.now)
        #expect(NativeOrbitAccountMetrics(usage: unknown).summary(
            days: 1, now: self.now, calendar: calendar).tokens == nil)
        let aggregate = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: 1200,
            last30DaysCostUSD: 0.25,
            historyDays: 30,
            daily: [],
            updatedAt: self.now)
        #expect(NativeOrbitAccountMetrics(usage: aggregate).summary(
            days: 1, now: self.now, calendar: calendar).tokens == nil)
        #expect(NativeOrbitAccountMetrics(usage: usage).summary(
            days: 60, now: self.now, calendar: calendar).isPartial)
    }

    @Test func `reported account tokens preserve separately scoped local spend`() {
        let calendar = CostUsageBucketTimeZone.calendar(identifier: "UTC")
        let accountUsage = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: 99,
            last30DaysCostUSD: nil,
            historyCoverageIsEstablished: false,
            daily: [.init(
                date: CostUsageLocalDay.key(from: self.now, calendar: calendar),
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: 99,
                costUSD: nil,
                modelsUsed: nil,
                modelBreakdowns: nil)],
            updatedAt: self.now)
        let local = NativeOrbitLocalUsage(
            snapshot: self.report(), scope: .localProfile, bucketTimeZoneIdentifier: "UTC")
        let metrics = NativeOrbitAccountMetrics.make(
            provider: .codex, snapshot: nil, usage: accountUsage, now: self.now, localUsage: local)
        let today = metrics.summary(days: 1, now: self.now, calendar: calendar)
        #expect(today.tokens == 99)
        #expect(today.usageScope == .account)
        #expect(today.isPartial)
        #expect(today.cost == 0.25)
        #expect(today.costUsageScope == .localProfile)
        #expect(!today.costIsPartial)
        let historical = metrics.summary(days: 1, now: self.now.addingTimeInterval(-60), calendar: calendar)
        #expect(historical.tokens == nil)
        #expect(historical.cost == nil)
    }

    @Test func `a missing account day retains verified local activity with its own provenance`() {
        let calendar = CostUsageBucketTimeZone.calendar(identifier: "UTC")
        let accountUsage = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: nil,
            last30DaysCostUSD: nil,
            historyCoverageIsEstablished: false,
            daily: [.init(
                date: CostUsageLocalDay.key(from: self.now.addingTimeInterval(-86400), calendar: calendar),
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: 99,
                costUSD: nil,
                modelsUsed: nil,
                modelBreakdowns: nil)],
            updatedAt: self.now)
        let local = NativeOrbitLocalUsage(
            snapshot: self.report(), scope: .localProfile, bucketTimeZoneIdentifier: "UTC")
        let metrics = NativeOrbitAccountMetrics.make(
            provider: .codex, snapshot: nil, usage: accountUsage, now: self.now, localUsage: local)
        let today = metrics.summary(days: 1, now: self.now, calendar: calendar)
        #expect(today.tokens == 1200)
        #expect(today.requests == 3)
        #expect(today.usageScope == .localProfile)
        #expect(metrics.summary(days: 7, now: self.now, calendar: calendar).tokens == 99)
        let historical = metrics.summary(days: 1, now: self.now.addingTimeInterval(-60), calendar: calendar)
        #expect(historical.tokens == nil)
        #expect(historical.requests == nil)
    }

    @Test func `local activity complication cannot borrow the provider account source label`() {
        var accountUsage = self.report(
            tokens: 99, date: self.now.addingTimeInterval(-86400), historyCoverageIsEstablished: false)
        accountUsage.historyLabel = "Provider-reported daily account tokens · Statistics as of yesterday"
        let local = NativeOrbitLocalUsage(
            snapshot: self.report(), scope: .localProfile, bucketTimeZoneIdentifier: "UTC")
        let metrics = NativeOrbitAccountMetrics.make(
            provider: .codex, snapshot: nil, usage: accountUsage, now: self.now, localUsage: local)
        let account = NativeOrbitAccountPresentation(
            id: "fixture",
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
        let today = NativeOrbitInstruments(account: account, days: 1, now: self.now, accent: .blue)
        let week = NativeOrbitInstruments(account: account, days: 7, now: self.now, accent: .blue)
        #expect(Self.cornerLabels(today.body).contains { $0.contains("Local sessions in this profile") })
        #expect(!Self.cornerLabels(today.body).contains { $0.contains("Provider-reported daily account tokens") })
        #expect(Self.cornerLabels(week.body).contains { $0.contains("Provider-reported daily account tokens") })
    }

    private static func cornerLabels(_ value: Any, depth: Int = 0) -> [String] {
        if let view = value as? NativeOrbitComplication { return [view.help] }
        guard depth < 30 else { return [] }
        return Mirror(reflecting: value).children.flatMap { self.cornerLabels($0.value, depth: depth + 1) }
    }

    private func account(
        fingerprint: String = "fixture-fingerprint",
        live: Bool = false) -> CodexVisibleAccount
    {
        CodexVisibleAccount(
            id: "fixture",
            email: "fixture@example.com",
            workspaceAccountID: "fixture-workspace",
            authFingerprint: fingerprint,
            storedAccountID: nil,
            selectionSource: live ? .liveSystem : .profileHome(path: self.home),
            isActive: live,
            isLive: live,
            canReauthenticate: false,
            canRemove: false)
    }

    private func emptyReport() -> CostUsageTokenSnapshot {
        CostUsageTokenSnapshot(
            sessionTokens: 0,
            sessionCostUSD: 0,
            last30DaysTokens: 0,
            last30DaysCostUSD: 0,
            historyDays: 365,
            daily: [],
            updatedAt: self.now)
    }

    private func publication(
        account: CodexVisibleAccount,
        state: SpendSourcePublication.State = .available,
        includesInput: Bool = true,
        report: CostUsageTokenSnapshot? = nil) -> SpendDashboardPublication
    {
        let source = account.selectionSource == .liveSystem ? "live" : "profile:\(self.home)"
        let material = [account.id, source, self.home, account.authFingerprint ?? "", "UTC"].joined(separator: "\u{0}")
        let digest = SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
        return SpendDashboardPublication(
            revision: 1,
            generation: 1,
            configuration: SpendDashboardConfiguration(
                costUsageEnabled: true,
                providerIDs: ["codex"],
                codexAccountIdentities: ["\(account.id)|\(digest)"],
                bucketTimeZoneIdentifier: "UTC"),
            loadedAt: self.now,
            isRefreshing: false,
            inputs: includesInput ? [.init(
                id: "codex:fixture",
                provider: .codex,
                displayName: "Fixture",
                snapshot: report ?? self.report())] : [],
            sources: [.init(
                id: "codex:fixture",
                provider: .codex,
                displayName: "Fixture",
                role: .subscription,
                state: state)])
    }

    private func report(
        tokens: Int = 1200,
        date: Date? = nil,
        historyCoverageIsEstablished: Bool = true) -> CostUsageTokenSnapshot
    {
        let calendar = CostUsageBucketTimeZone.calendar(identifier: "UTC")
        return CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: nil,
            last30DaysCostUSD: nil,
            historyDays: 30,
            historyCoverageIsEstablished: historyCoverageIsEstablished,
            daily: [.init(
                date: CostUsageLocalDay.key(
                    from: date ?? self.now,
                    calendar: calendar),
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: tokens,
                requestCount: 3,
                costUSD: 0.25,
                modelsUsed: nil,
                modelBreakdowns: nil)],
            updatedAt: self.now)
    }
}
