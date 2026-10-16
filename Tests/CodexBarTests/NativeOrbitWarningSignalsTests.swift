import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct NativeOrbitWarningSignalsTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func `quota windows produce measured limit pace and overdue signals`() {
        let exhausted = RateWindow(
            usedPercent: 100,
            windowMinutes: 300,
            resetsAt: self.now.addingTimeInterval(-900),
            resetDescription: nil)
        let snapshot = UsageSnapshot(primary: exhausted, secondary: nil, updatedAt: self.now)
        let lights = NativeOrbitWarningSignals.account(
            provider: .claude, snapshot: snapshot, metrics: .empty, history: [], now: self.now)
        #expect(lights.contains { $0.kind == .limit && $0.severity == .critical })
        #expect(lights.contains { $0.kind == .resetLate })
        let fresh = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 0,
                windowMinutes: 300,
                resetsAt: self.now.addingTimeInterval(18000),
                resetDescription: nil),
            secondary: nil,
            updatedAt: self.now)
        let clear = NativeOrbitWarningSignals.account(
            provider: .claude, snapshot: fresh, metrics: .empty, history: [], now: self.now)
        #expect(!clear.contains { [.limit, .resetLate, .partialReading, .notReported].contains($0.kind) })
    }

    @Test func `an absent reset and a placeholder alone do not establish a failed reading`() {
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 45, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 0,
                windowMinutes: 10080,
                resetsAt: nil,
                resetDescription: nil,
                isSyntheticPlaceholder: true),
            updatedAt: self.now)
        let lights = NativeOrbitWarningSignals.account(
            provider: .claude, snapshot: snapshot, metrics: .empty, history: [], now: self.now)
        #expect(!lights.contains { $0.kind == .notReported })
        #expect(!lights.contains { $0.kind == .partialReading })
        #expect(!lights.contains { $0.kind == .limit })
    }

    @Test func `adapter credential reasons survive projection without parsing display text`() {
        for (status, issue) in [
            (ClaudeSwapUsageStatus.foreignCredential, ProviderAccountCredentialIssue.wrongAccount),
            (.keychainUnavailable, .keychain),
        ] {
            let list = ClaudeSwapAccountList(activeAccountNumber: 1, accounts: [
                ClaudeSwapAccountRow(
                    number: 1,
                    email: "fixture@example.invalid",
                    isActive: true,
                    usageStatus: status,
                    fiveHour: nil,
                    sevenDay: nil),
            ])
            let account = ClaudeSwapAccountProjection.accountSnapshots(from: list, now: self.now).first
            #expect(account?.credentialIssue == issue)
        }
    }

    @Test func `plan expiry does not make an unfunded zero balance exhausted`() {
        var metrics = NativeOrbitAccountMetrics.empty
        metrics.reportedPlanExpiry = self.now.addingTimeInterval(86400)
        metrics.reportedBalance = .init(value: 0, unit: "USD", isWorkspace: false, updatedAt: self.now)
        let lights = NativeOrbitWarningSignals.account(
            provider: .kimi, snapshot: nil, metrics: metrics, history: [], now: self.now, observedAt: self.now)
        #expect(lights.contains { $0.kind == .plan && $0.severity == .caution })
        #expect(!lights.contains { $0.kind == .credits })
        #expect(NativeOrbitWarningSignals.account(
            provider: .claude, snapshot: nil, metrics: .empty, history: [], now: self.now).isEmpty)
    }

    @Test func `recognized billing problems and old CLI reports clear with fresh healthy metadata`() {
        let bad = UsageSnapshot(primary: nil, secondary: nil, subscriptionStatus: "past_due", updatedAt: self.now)
        let good = UsageSnapshot(primary: nil, secondary: nil, subscriptionStatus: "active", updatedAt: self.now)
        #expect(self.kinds(snapshot: bad).contains(.billing))
        #expect(!self.kinds(snapshot: good).contains(.billing))
        let outdated = UsageSnapshot(
            primary: nil,
            secondary: nil,
            claudeResetCreditsIneligibleReason: "cli_version",
            updatedAt: self.now)
        #expect(self.kinds(snapshot: outdated).contains(.update))
        #expect(!self.kinds(snapshot: good).contains(.update))
    }

    @Test func `pace pressure uses one actionable light and clears on even pace`() {
        for (used, kind) in [(5.0, NativeOrbitWarningLight.Kind.behindPace), (54, .limit), (80, .limit)] {
            let window = RateWindow(
                usedPercent: used,
                windowMinutes: 300,
                resetsAt: self.now.addingTimeInterval(9000),
                resetDescription: nil)
            let snapshot = UsageSnapshot(primary: window, secondary: nil, updatedAt: self.now)
            #expect(self.kinds(snapshot: snapshot).contains(kind))
        }
        let even = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 50,
                windowMinutes: 300,
                resetsAt: self.now.addingTimeInterval(9000),
                resetDescription: nil),
            secondary: nil,
            updatedAt: self.now)
        #expect(self.kinds(snapshot: even).isDisjoint(with: [.behindPace, .aheadOfPace, .farAheadPace, .limit]))
    }

    @Test func `unpriced unattributed and external usage markers clear only with complete measured data`() {
        let report = self.report(tokens: Array(repeating: 0, count: 8), unpriced: true)
        var metrics = NativeOrbitAccountMetrics(usage: report)
        metrics.primaryLocalUsage = .init(
            snapshot: report,
            scope: .localMachine,
            bucketTimeZoneIdentifier: nil,
            unattributedDays: ["2027-01-15"])
        metrics.quotaConsumption = [self.now]
        let kinds = self.kinds(metrics: metrics)
        #expect(kinds.isSuperset(of: [.unpriced, .unattributed]))
        #expect(!kinds.contains(.usedElsewhere))
        #expect(self.kinds(metrics: .empty).isDisjoint(with: [.unpriced, .unattributed, .usedElsewhere]))
    }

    @Test func `usage spike and idle account require complete account reports`() {
        let paid = UsageSnapshot(
            primary: nil,
            secondary: nil,
            updatedAt: self.now,
            identity: .init(
                providerID: .claude,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: "Pro"))
        let spike = NativeOrbitAccountMetrics(usage: self.report(tokens: [100, 10, 10, 10, 10, 10, 10, 10]))
        #expect(self.kinds(snapshot: paid, metrics: spike).contains(.spike))
        let idle = NativeOrbitAccountMetrics(usage: self.report(tokens: Array(repeating: 0, count: 8)))
        #expect(self.kinds(snapshot: paid, metrics: idle).contains(.idle))
        let even = NativeOrbitAccountMetrics(usage: self.report(tokens: Array(repeating: 10, count: 8)))
        #expect(self.kinds(snapshot: paid, metrics: even).isDisjoint(with: [.spike, .idle]))
        var unknownScope = spike
        unknownScope.usageScope = .localMachine
        #expect(!self.kinds(snapshot: paid, metrics: unknownScope).contains(.spike))
    }

    @Test func `external use requires complete contemporaneous account-attributed local logs`() {
        let report = self.report(tokens: Array(repeating: 0, count: 8))
        var metrics = NativeOrbitAccountMetrics(usage: report)
        metrics.quotaConsumption = [self.now]
        // A lagging provider total, without logs from this Mac, proves no external-device claim.
        #expect(!self.kinds(metrics: metrics).contains(.usedElsewhere))
        metrics.localCostUsage = .init(
            snapshot: report,
            scope: .localMachine,
            bucketTimeZoneIdentifier: nil,
            isAccountAttributed: true)
        #expect(self.kinds(metrics: metrics).contains(.usedElsewhere))
        metrics.localCostUsage?.isStale = true
        #expect(!self.kinds(metrics: metrics).contains(.usedElsewhere))
        metrics.localCostUsage?.isStale = false
        metrics.localCostUsage?.isAccountAttributed = false
        #expect(!self.kinds(metrics: metrics).contains(.usedElsewhere))
    }

    @Test func `real local attribution emits a complete zero report for an account used off this Mac`() throws {
        let windowA = self.now.addingTimeInterval(4 * 86400)
        let windowB = self.now.addingTimeInterval(5 * 86400)
        let request = self.now.addingTimeInterval(-60)
        let source = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: 50,
            last30DaysCostUSD: 1,
            daily: [],
            quotaSlices: [.init(timestamp: request, totalTokens: 50, costUSD: 1)],
            updatedAt: self.now)
        let timeline = NativeCodexSessionWindowTimeline(
            events: [(time: request, weeklyReset: windowA)],
            coverageStart: self.now.addingTimeInterval(-32 * 86400),
            coverageEnd: self.now)
        let attributed = NativeCodexSessionWindowAttribution.attribute(
            reports: [source], timeline: timeline, evidence: ["a": [windowA], "b": [windowB]], calendar: .current)
        let localB = try #require(attributed.reports["b"])
        #expect(localB.historyIsFullyScanned)
        #expect(localB.daily.isEmpty)
        var metrics = NativeOrbitAccountMetrics.empty
        metrics.quotaConsumption = [self.now]
        metrics.localCostUsage = .init(
            snapshot: localB,
            scope: .localMachine,
            bucketTimeZoneIdentifier: nil,
            isAccountAttributed: true,
            unattributedDays: attributed.unattributedDays)
        #expect(self.kinds(metrics: metrics).contains(.usedElsewhere))
        metrics.localCostUsage = try .init(
            snapshot: #require(attributed.reports["a"]),
            scope: .localMachine,
            bucketTimeZoneIdentifier: nil,
            isAccountAttributed: true)
        #expect(!self.kinds(metrics: metrics).contains(.usedElsewhere))
        // This account had local activity earlier today, but none during this later measured quota increase.
        let rise = PlanUtilizationSeriesHistory(name: "nativeQuota:secondary", windowMinutes: 10080, entries: [
            .init(capturedAt: self.now.addingTimeInterval(-30), usedPercent: 10, resetsAt: windowA),
            .init(capturedAt: self.now, usedPercent: 15, resetsAt: windowA),
        ])
        let live = NativeOrbitWarningSignals.account(
            provider: .codex,
            snapshot: nil,
            metrics: metrics,
            history: [rise],
            now: self.now)
        #expect(live.contains { $0.kind == .usedElsewhere })
        let noRise = PlanUtilizationSeriesHistory(name: "nativeQuota:secondary", windowMinutes: 10080, entries: [
            .init(capturedAt: self.now.addingTimeInterval(-30), usedPercent: 10, resetsAt: windowA),
            .init(capturedAt: self.now, usedPercent: 10, resetsAt: windowA),
        ])
        let clear = NativeOrbitWarningSignals.account(
            provider: .codex,
            snapshot: nil,
            metrics: metrics,
            history: [noRise],
            now: self.now)
        #expect(!clear.contains { $0.kind == .usedElsewhere })
    }

    @Test func `real Codex accumulating account receipts can prove a spike and a completed idle week`() throws {
        for (tokens, expected) in [
            (Array(repeating: 10, count: 7) + [100], NativeOrbitWarningLight.Kind.spike),
            (Array(repeating: 0, count: 8), .idle),
        ] {
            let daily = self.report(tokens: Array(tokens.reversed())).daily
            let payload: [String: Any] = [
                "stats": [
                    "lifetime_tokens": tokens.reduce(0, +),
                    "daily_usage_buckets": daily.map { ["start_date": $0.date, "tokens": $0.totalTokens!] },
                ],
                "metadata": ["stats_as_of": daily[0].date],
                "coverage_complete": true,
            ]
            let decoded = try CodexAccountUsageHistory.decode(JSONSerialization.data(withJSONObject: payload))
            let history = try #require(NativeCodexAccountUsageHistory.merging(
                decoded,
                previous: nil,
                fetchedAt: self.now))
            let report = try #require(history.tokenSnapshot())
            #expect(report.historyScanIsPartial)
            var metrics = NativeOrbitAccountMetrics(usage: report)
            metrics.accountUsageHistory = history
            let snapshot = UsageSnapshot(
                primary: nil,
                secondary: nil,
                updatedAt: self.now,
                identity: .init(
                    providerID: .codex,
                    accountEmail: nil,
                    accountOrganization: nil,
                    loginMethod: "Pro"))
            let kinds = Set(NativeOrbitWarningSignals.account(
                provider: .codex,
                snapshot: snapshot,
                metrics: metrics,
                history: [],
                now: self.now).map(\.kind))
            #expect(kinds.contains(expected))
        }
        let claude = UsageSnapshot(
            primary: nil,
            secondary: nil,
            updatedAt: self.now,
            identity: .init(
                providerID: .claude,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: "Claude Pro"))
        #expect(self.kinds(snapshot: claude, metrics: .init(usage: self.report(tokens: Array(repeating: 0, count: 8))))
            .contains(.idle))
    }

    @Test func `grant access warnings follow only configured folders for their own provider`() {
        #expect(NativeOrbitWarningSignals.folderAccess(
            provider: .antigravity,
            configuredPaths: ["/fixture/logs"],
            unavailablePaths: ["/fixture/logs"])?.kind == .folderAccess)
        #expect(NativeOrbitWarningSignals.folderAccess(
            provider: .antigravity,
            configuredPaths: ["/fixture/logs"],
            unavailablePaths: []) == nil)
        #expect(NativeOrbitWarningSignals.folderAccess(
            provider: .claude,
            configuredPaths: ["/fixture/logs"],
            unavailablePaths: ["/fixture/logs"]) == nil)
    }

    @Test func `early reset and newly granted reset use existing observed history then expire`() {
        let history = [PlanUtilizationSeriesHistory(name: "nativeQuota:primary", windowMinutes: 300, entries: [
            .init(
                capturedAt: self.now.addingTimeInterval(-1800),
                usedPercent: 60,
                resetsAt: self.now.addingTimeInterval(3600)),
            .init(
                capturedAt: self.now.addingTimeInterval(-600),
                usedPercent: 5,
                resetsAt: self.now.addingTimeInterval(17400)),
        ]), PlanUtilizationSeriesHistory(name: "nativeMetric:resets", windowMinutes: 0, entries: [
            .init(
                capturedAt: self.now.addingTimeInterval(-1800),
                usedPercent: 0,
                resetsAt: nil,
                nativeMetrics: .init(resets: .init(availableExpirations: []))),
            .init(
                capturedAt: self.now.addingTimeInterval(-600),
                usedPercent: 0,
                resetsAt: nil,
                nativeMetrics: .init(resets: .init(availableExpirations: [self.now.addingTimeInterval(86400)]))),
        ])]
        var metrics = NativeOrbitAccountMetrics.empty
        metrics.bankedResets = 1
        metrics.resetInventoryObservedAt = self.now.addingTimeInterval(-600)
        let lit = NativeOrbitWarningSignals.account(
            provider: .claude,
            snapshot: nil,
            metrics: metrics,
            history: history,
            now: self.now)
        #expect(Set(lit.map(\.kind)).isSuperset(of: [.earlyReset, .newSavedReset]))
        let expired = NativeOrbitWarningSignals.account(
            provider: .claude,
            snapshot: nil,
            metrics: metrics,
            history: history,
            now: self.now.addingTimeInterval(2 * 86400))
        #expect(Set(expired.map(\.kind)).isDisjoint(with: [.earlyReset, .newSavedReset]))
    }

    @Test func `quota cadence change is measured against this account history`() {
        let history = [PlanUtilizationSeriesHistory(name: "nativeQuota:primary", windowMinutes: 300, entries: [
            .init(
                capturedAt: self.now.addingTimeInterval(-300),
                usedPercent: 50,
                resetsAt: self.now.addingTimeInterval(9000)),
        ])]
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 50,
                windowMinutes: 360,
                resetsAt: self.now.addingTimeInterval(9000),
                resetDescription: nil),
            secondary: nil,
            updatedAt: self.now)
        let lights = NativeOrbitWarningSignals.account(
            provider: .claude,
            snapshot: snapshot,
            metrics: .empty,
            history: history,
            now: self.now)
        #expect(lights.contains { $0.kind == .limitsChanged })
        #expect(!self.kinds(snapshot: snapshot).contains(.limitsChanged))
    }

    private func kinds(snapshot: UsageSnapshot? = nil, metrics: NativeOrbitAccountMetrics = .empty)
        -> Set<NativeOrbitWarningLight.Kind>
    {
        Set(NativeOrbitWarningSignals.account(
            provider: .claude,
            snapshot: snapshot,
            metrics: metrics,
            history: [],
            now: self.now).map(\.kind))
    }

    private func report(tokens: [Int], unpriced: Bool = false) -> CostUsageTokenSnapshot {
        let daily = tokens.enumerated().map { index, tokens in
            let day = Calendar.current.date(byAdding: .day, value: -index, to: self.now)!
            let parts = Calendar.current.dateComponents([.year, .month, .day], from: day)
            let key = String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
            return CostUsageDailyReport.Entry(
                date: key,
                inputTokens: tokens,
                outputTokens: 0,
                totalTokens: tokens,
                costUSD: 0,
                modelsUsed: nil,
                modelBreakdowns: nil,
                unpricedRequestCount: unpriced ? 1 : nil)
        }
        return CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: tokens.reduce(0, +),
            last30DaysCostUSD: 0,
            daily: daily,
            updatedAt: self.now)
    }
}
