import Foundation
import SwiftUI
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct NativeCombinedAccountsTests {
    private let now = Date(timeIntervalSince1970: 1_800_014_400)

    @Test func `only more than three meaningfully connected platforms collapse`() {
        let providers: [UsageProvider] = [.codex, .claude, .gemini, .cursor]
        let three = providers.prefix(3).map { self.connection($0) }
        #expect(!NativeCombinedAccounts.shouldCombine(three))
        #expect(NativeCombinedAccounts.shouldCombine(providers.map { self.connection($0) }))
        let empty = NativeCombinedAccounts.Connection(provider: .cursor, accounts: [], hasSavedAccounts: false)
        #expect(!NativeCombinedAccounts.shouldCombine(three + [empty]))
        let unconfigured = NativeCombinedAccounts.Connection(
            provider: .cursor, accounts: [self.account(.cursor, id: "empty", measured: false)], hasSavedAccounts: false)
        #expect(!NativeCombinedAccounts.shouldCombine(three + [unconfigured]))
    }

    @Test func `combining every service needs only one connected platform`() {
        let codex = self.connection(.codex)
        let empty = NativeCombinedAccounts.Connection(provider: .cursor, accounts: [], hasSavedAccounts: false)
        #expect(NativeCombinedAccounts.shouldCombine([codex], always: true))
        #expect(!NativeCombinedAccounts.shouldCombine([codex], always: false))
        #expect(!NativeCombinedAccounts.shouldCombine([empty], always: true))
        #expect(!NativeCombinedAccounts.shouldCombine([], always: true))
    }

    @Test func `the popup shows every page up to three and two and a half beyond`() {
        #expect(NativeCombinedPopupView.contentSize(pageCount: 2).width == 481)
        #expect(NativeCombinedPopupView.contentSize(pageCount: 3).width == 722)
        #expect(NativeCombinedPopupView.contentSize(pageCount: 9).width == 602)
        #expect(NativeCombinedPopupView.contentSize(pageCount: 9, maximumWidth: 500).width == 500)
    }

    @Test func `only pages wholly in view count as shown`() {
        #expect(NativeCombinedPopupView.wholeColumns(leading: 0, width: 602) == 0...1)
        #expect(NativeCombinedPopupView.wholeColumns(leading: 241, width: 602) == 1...2)
        #expect(NativeCombinedPopupView.wholeColumns(leading: 120, width: 602) == 1...2)
        // The end of nine pages: page 6 is cut off, pages 7 and 8 are whole.
        #expect(NativeCombinedPopupView.wholeColumns(leading: 1566, width: 602) == 7...8)
        #expect(NativeCombinedPopupView.wholeColumns(leading: 0, width: 722) == 0...2)
    }

    @Test func `an opening builds only the pages on screen at its opening page`() {
        let six = ["all", "a", "b", "c", "d", "e"]
        // Two and a half columns: the opening page, the next, and the one cut off after it.
        #expect(NativeCombinedPopupView.pagesInView(six, leadingID: "a") == ["a", "b", "c"])
        #expect(NativeCombinedPopupView.pagesInView(six, leadingID: "all") == ["all", "a", "b"])
        // The strip stops at its last page.
        #expect(NativeCombinedPopupView.pagesInView(six, leadingID: "e") == ["c", "d", "e"])
        #expect(NativeCombinedPopupView.pagesInView(["all", "a"], leadingID: "a") == ["all", "a"])
    }

    @Test func `saved accounts remain connected when their usage is unavailable`() {
        let connection = NativeCombinedAccounts.Connection(
            provider: .codex, accounts: [self.account(.codex, id: "saved", measured: false)], hasSavedAccounts: true)
        #expect(connection.isConnected)
    }

    @Test func `recent icons follow measured consumption rather than refresh timestamps`() {
        let old = self.account(.codex, id: "old", activity: -600)
        let recent = self.account(.claude, id: "recent", activity: -30)
        let refreshed = self.account(.gemini, id: "freshly-polled")
        let model = NativeCombinedAccounts(connections: [
            .init(provider: .codex, accounts: [old]),
            .init(provider: .gemini, accounts: [refreshed]),
            .init(provider: .claude, accounts: [recent]),
        ], now: self.now)
        #expect(model.recentAccounts.map(\.account.id) == ["recent", "old", "freshly-polled"])
        #expect(model.pages.first?.id == model.recentAccounts.first?.id)
    }

    @Test func `page identities are provider scoped and account groups stay contiguous`() {
        let model = NativeCombinedAccounts(connections: [
            .init(provider: .codex, accounts: [self.account(.codex, id: "same"), self.account(.codex, id: "other")]),
            .init(provider: .claude, accounts: [self.account(.claude, id: "same", activity: -10)]),
        ], now: self.now)
        #expect(Set(model.pages.map(\.id)).count == 3)
        #expect(model.pages.map(\.provider) == [.claude, .codex, .codex])
        #expect(model.indicators(selectedID: model.pages.last?.id).filter { $0.accountID != nil }.count == 2)
        #expect(model.indicators(selectedID: NativeCombinedAccounts.overviewID).allSatisfy { $0.accountID == nil })
    }

    @Test func `overview preserves unknowns partial totals and separate currencies`() {
        let summary = NativeCombinedAccounts.Summary([
            .init(tokens: 100, cost: 2, currencyCode: "USD", requests: 3),
            .init(tokens: 200, cost: 5, currencyCode: "EUR", requests: 4),
            .init(),
        ])
        #expect(summary.tokens == 300)
        #expect(summary.requests == 7)
        #expect(summary.costs == ["USD": 2, "EUR": 5])
        #expect(summary.isPartial)
        #expect(NativeCombinedAccounts.Summary([.init()]).tokens == nil)
    }

    @Test func `every page has exactly one selected indicator with a valid navigation target`() {
        let model = NativeCombinedAccounts(connections: [
            .init(provider: .codex, accounts: [self.account(.codex, id: "one"), self.account(.codex, id: "two")]),
            .init(provider: .claude, accounts: [self.account(.claude, id: "only")]),
        ], now: self.now)
        let pageIDs = [NativeCombinedAccounts.overviewID] + model.pages.map(\.id)
        for pageID in pageIDs {
            let indicators = model.indicators(selectedID: pageID)
            #expect(indicators.filter(\.selected).count == 1)
            #expect(indicators.first(where: \.selected)?.targetID == pageID)
            #expect(indicators.allSatisfy { pageIDs.contains($0.targetID) })
        }
    }

    @Test func `attributed machine reports and distinct profiles are all counted`() {
        for scope in [NativeOrbitUsageScope.localMachine, .localProfile] {
            var first = self.account(.codex, id: "one")
            var second = self.account(.codex, id: "two")
            first.metrics = self.metrics(tokens: 100, scope: scope, attributed: true)
            second.metrics = self.metrics(tokens: 200, scope: scope, attributed: true)
            let model = NativeCombinedAccounts(
                connections: [.init(provider: .codex, accounts: [first, second])],
                now: self.now)
            #expect(model.summary(days: 1, now: self.now).tokens == 300)
        }
    }

    @Test func `repeated unattributed machine reports contribute once`() {
        var first = self.account(.codex, id: "one")
        var second = self.account(.codex, id: "two")
        first.metrics = self.metrics(tokens: 100, scope: .localMachine, attributed: false)
        second.metrics = first.metrics
        let model = NativeCombinedAccounts(
            connections: [.init(provider: .codex, accounts: [first, second])],
            now: self.now)
        #expect(model.summary(days: 1, now: self.now).tokens == 100)
    }

    @Test func `token shares count each account once and a shared machine report once`() {
        var first = self.account(.codex, id: "one")
        var second = self.account(.codex, id: "two")
        var claude = self.account(.claude, id: "claude")
        first.metrics = self.metrics(tokens: 100, scope: .localMachine, attributed: false)
        second.metrics = first.metrics
        claude.metrics = self.metrics(tokens: 300, scope: .account, attributed: false)
        let model = NativeCombinedAccounts(connections: [
            .init(provider: .codex, accounts: [first, second]),
            .init(provider: .claude, accounts: [claude]),
        ], now: self.now)
        let shares = model.tokenShares(days: 1, now: self.now)
        #expect(shares.map(\.tokens) == [300, 100])
        #expect(shares.map(\.page.provider) == [.claude, .codex])
    }

    @Test func `aggregate-only totals still count toward the range total`() {
        var account = self.account(.codex, id: "aggregate")
        account.metrics.usage = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: 9000,
            last30DaysCostUSD: 20,
            historyDays: 30,
            daily: [],
            updatedAt: self.now)
        let model = NativeCombinedAccounts(connections: [.init(provider: .codex, accounts: [account])], now: self.now)
        #expect(model.summary(days: 30, now: self.now).tokens == 9000)
        #expect(model.tokenShares(days: 30, now: self.now).map(\.tokens) == [9000])
    }

    @Test func `incoming accounts preserve provider grouping and the visible page identity`() {
        let first = self.account(.codex, id: "one", activity: -60)
        let other = self.account(.claude, id: "other", activity: -30)
        let original = NativeCombinedAccounts(connections: [
            .init(provider: .codex, accounts: [first]),
            .init(provider: .claude, accounts: [other]),
        ], now: self.now)
        let updated = NativeCombinedAccounts(
            connections: [
                .init(provider: .codex, accounts: [first, self.account(.codex, id: "new", activity: -1)]),
                .init(provider: .claude, accounts: [other]),
            ],
            now: self.now,
            preservingOrder: original.pages.map(\.id))
        #expect(updated.pages.map(\.provider) == [.claude, .codex, .codex])
        #expect(updated.pages.first?.id == original.pages.first?.id)
    }

    @Test func `scrubbed token shares totals and chart use absolute requests at the same instant`() throws {
        var first = self.account(.codex, id: "one")
        var second = self.account(.codex, id: "two")
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: nil,
            last30DaysCostUSD: nil,
            historyDays: 30,
            daily: [],
            quotaSlices: [
                .init(timestamp: self.now.addingTimeInterval(-7200), totalTokens: 200, costUSD: 2),
                .init(timestamp: self.now.addingTimeInterval(-600), totalTokens: 300, costUSD: 3),
            ],
            updatedAt: self.now)
        first.metrics = NativeOrbitAccountMetrics(usage: snapshot, usageScope: .localMachine)
        first.metrics.primaryLocalUsage = .init(snapshot: snapshot, scope: .localMachine, bucketTimeZoneIdentifier: nil)
        second.metrics = first.metrics
        let model = NativeCombinedAccounts(
            connections: [.init(provider: .codex, accounts: [first, second])],
            now: self.now)
        let selected = self.now.addingTimeInterval(-3600)
        #expect(model.tokenShares(days: 1, now: selected).map(\.tokens) == [200])
        #expect(model.summary(days: 1, now: selected).tokens == 200)
        #expect(model.summary(days: 1, now: selected).costs == ["USD": 2])
        let chart = NativeCombinedTokenHistory.make(model: model, days: 1, now: self.now)
        #expect(chart.count == 1)
        #expect(chart.first?.points.last?.value == 500)
        let selectedPoint = try #require(chart.first?.points.first { $0.date == selected })
        #expect(selectedPoint.value == 200)
    }

    @Test func `money and tokens use their own absolute units and preserve unknowns`() {
        let reading = NativeOrbitMetricSummary(tokens: 120, cost: 3.25, currencyCode: "USD")
        #expect(NativeCombinedMetric.tokens.value(reading) == 120)
        #expect(NativeCombinedMetric.money(currency: "USD").value(reading) == 3.25)
        #expect(NativeCombinedMetric.money(currency: "EUR").value(reading) == nil)
        #expect(NativeCombinedMetric.money(currency: "USD").value(.init()) == nil)
        #expect(NativeCombinedMetric.tokens.value(.init(tokens: 0)) == 0)
    }

    @Test func `money shares and history follow the exact scrubbed instant`() throws {
        var account = self.account(.codex, id: "money")
        account.metrics = NativeOrbitAccountMetrics(
            usage: CostUsageTokenSnapshot(
                sessionTokens: nil,
                sessionCostUSD: nil,
                last30DaysTokens: nil,
                last30DaysCostUSD: nil,
                historyDays: 30,
                daily: [],
                quotaSlices: [
                    .init(timestamp: self.now.addingTimeInterval(-7200), totalTokens: 200, costUSD: 2.25),
                    .init(timestamp: self.now.addingTimeInterval(-600), totalTokens: 300, costUSD: 4.50),
                ],
                updatedAt: self.now),
            usageScope: .account)
        let model = NativeCombinedAccounts(connections: [.init(provider: .codex, accounts: [account])], now: self.now)
        let selected = self.now.addingTimeInterval(-3600)
        let metric = NativeCombinedMetric.money(currency: "USD")
        #expect(model.shares(metric: metric, days: 1, now: selected).map(\.value) == [2.25])
        #expect(model.shares(metric: metric, days: 1, now: self.now).map(\.value) == [6.75])
        #expect(model.shares(metric: .money(currency: "EUR"), days: 1, now: self.now).isEmpty)
        let history = NativeCombinedTokenHistory.make(model: model, days: 1, now: self.now, metric: metric)
        let point = try #require(history.first?.points.first { $0.date == selected })
        #expect(point.value == 2.25)
        #expect(history.first?.points.last?.value == 6.75)
    }

    @Test func `rounded pie corners preserve tiny nonzero accounts`() {
        for fraction in [0.001, 0.005, 0.015, 0.02, 0.025, 0.1] {
            let gap = min(4.0, 63 * sin(min(Double.pi, fraction * 2 * Double.pi) / 2))
            let shape = NativeCombinedShareShape(
                start: .zero,
                end: .radians(fraction * 2 * Double.pi),
                radius: 90,
                width: 54,
                corner: 3.5,
                gap: gap)
            let path = shape.path(in: CGRect(x: 0, y: 0, width: 256, height: 256))
            #expect(!path.isEmpty)
            let middle = fraction * Double.pi
            #expect(path.contains(CGPoint(x: 128 + 90 * cos(middle), y: 128 + 90 * sin(middle))))
        }
    }

    private func metrics(
        tokens: Int, scope: NativeOrbitUsageScope, attributed: Bool, dayOffset: Int = 0) -> NativeOrbitAccountMetrics
    {
        let date = self.now.addingTimeInterval(Double(dayOffset) * 86400)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: date)
        let usage = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: nil,
            last30DaysCostUSD: nil,
            historyDays: 30,
            daily: [.init(
                date: day,
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: tokens,
                costUSD: 1,
                modelsUsed: nil,
                modelBreakdowns: nil)],
            updatedAt: self.now)
        var metrics = NativeOrbitAccountMetrics(usage: usage, usageScope: scope)
        if scope != .account {
            metrics.primaryLocalUsage = NativeOrbitLocalUsage(
                snapshot: usage,
                scope: scope,
                bucketTimeZoneIdentifier: nil,
                isAccountAttributed: attributed)
        }
        return metrics
    }

    private func connection(_ provider: UsageProvider) -> NativeCombinedAccounts.Connection {
        .init(provider: provider, accounts: [self.account(provider, id: provider.rawValue)])
    }

    private func account(
        _ provider: UsageProvider,
        id: String,
        measured: Bool = true,
        activity: TimeInterval? = nil) -> NativeOrbitAccountPresentation
    {
        var gauge = ComputeGauge.State()
        gauge.provider = provider.rawValue
        var metrics = NativeOrbitAccountMetrics.empty
        metrics.quotaConsumption = activity.map { [self.now.addingTimeInterval($0)] } ?? []
        return .init(
            id: id,
            label: id,
            email: nil,
            symbol: "leaf",
            isActive: false,
            canActivate: false,
            gauge: gauge,
            updatedAt: measured ? self.now : nil,
            history: [],
            odometer: nil,
            odometerHelp: nil,
            statusText: nil,
            selection: .none,
            metrics: metrics)
    }
}
