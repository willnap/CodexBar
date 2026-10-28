import Foundation
import SwiftUI
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct NativeCombinedAccountsTests {
    private let now = Date(timeIntervalSince1970: 1_800_014_400)

    @Test func `range returns reuse live overview readings while historical inspection remains independent`() {
        var account = self.account(.codex, id: "first")
        account.metrics = self.metrics(tokens: 100, scope: .account, attributed: true)
        let model = NativeCombinedAccounts(connections: [
            .init(provider: .codex, accounts: [account]),
        ], now: self.now)
        let day = model.readings(days: 1, now: self.now)
        let month = model.readings(days: 30, now: self.now)
        #expect(Self.sameStorage(day, model.readings(days: 1, now: self.now)))
        #expect(Self.sameStorage(month, model.readings(days: 30, now: self.now)))
        let past = model.readings(days: 1, now: self.now.addingTimeInterval(-86400))
        #expect(past.first?.reading.tokens != day.first?.reading.tokens)
        #expect(Self.sameStorage(day, model.readings(days: 1, now: self.now)))
    }

    @Test func `combined model reuse follows account data clock and frozen page order`() {
        let memo = NativeCombinedAccountsMemo()
        var account = self.account(.codex, id: "first")
        account.metrics = self.metrics(tokens: 100, scope: .account, attributed: true)
        func model(at now: Date) -> NativeCombinedAccounts {
            memo.value(connections: [.init(provider: .codex, accounts: [account])], now: now, preservingOrder: [])
        }
        let first = model(at: self.now).readings(days: 1, now: self.now)
        #expect(Self.sameStorage(first, model(at: self.now).readings(days: 1, now: self.now)))
        account.metrics = self.metrics(tokens: 200, scope: .account, attributed: true)
        let corrected = model(at: self.now).readings(days: 1, now: self.now)
        #expect(corrected.first?.reading.tokens == 200)
        #expect(!Self.sameStorage(first, corrected))
        let later = self.now.addingTimeInterval(60)
        #expect(!Self.sameStorage(corrected, model(at: later).readings(days: 1, now: later)))
        let connections = [self.connection(.codex), self.connection(.claude)]
        let initial = memo.value(connections: connections, now: self.now, preservingOrder: [])
        let order = initial.pages.map(\.id).reversed().map(\.self)
        #expect(memo.value(connections: connections, now: self.now, preservingOrder: order).pages.map(\.id) == order)
    }

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

    @Test func `an opening builds only the pages on screen at its opening page and keeps the overview`() {
        let six = [NativeCombinedAccounts.overviewID, "a", "b", "c", "d", "e"]
        let all = NativeCombinedAccounts.overviewID
        // Two and a half columns: the opening page, the next, and the one cut off after it. The overview stays
        // built, so its chart never rebuilds from nothing at an opening.
        #expect(NativeCombinedPopupView.pagesInView(six, leadingID: "a") == [all, "a", "b", "c"])
        #expect(NativeCombinedPopupView.pagesInView(six, leadingID: all) == [all, "a", "b"])
        // The strip stops at its last page.
        #expect(NativeCombinedPopupView.pagesInView(six, leadingID: "e") == [all, "c", "d", "e"])
        #expect(NativeCombinedPopupView.pagesInView([all, "a"], leadingID: "a") == [all, "a"])
        // A popup widened to four columns builds four.
        #expect(NativeCombinedPopupView.pagesInView(six, leadingID: "a", width: 4 * 241 - 1)
            == [all, "a", "b", "c", "d"])
    }

    @Test func `marks light by how much of their page is in the window`() {
        // Two and a half columns from the start: two pages whole, the third half in, the rest out.
        #expect(NativeCombinedPopupView.visibility(leading: 0, width: 602, count: 4) == [1, 1, 0.5, 0])
        #expect(NativeCombinedPopupView.visibility(leading: 120.5, width: 241, count: 3) == [0.5, 0.5, 0])
        let model = NativeCombinedAccounts(connections: [
            .init(provider: .codex, accounts: [self.account(.codex, id: "a"), self.account(.codex, id: "b")]),
        ], now: self.now)
        let marks = model.indicators(selectedID: nil, visibility: ["codex:a": 0.25, "codex:b": 0.75])
        // A collapsed provider logo takes its most visible page.
        #expect(marks.first { $0.id == "provider:codex" }?.visibility == 0.75)
    }

    @Test func `a chosen width stays between one page and every page within the screen`() {
        #expect(NativeCombinedPopupView.clampedWidth(100, pageCount: 6) == NativeCombinedPopupView.minimumWidth)
        #expect(NativeCombinedPopupView.clampedWidth(900, pageCount: 6) == 900)
        #expect(NativeCombinedPopupView.clampedWidth(5000, pageCount: 6) == CGFloat(6 * 241 - 1))
        #expect(NativeCombinedPopupView.clampedWidth(5000, pageCount: 6, maximumWidth: 1000) == 1000)
        #expect(NativeCombinedPopupView.contentSize(pageCount: 6, preferredWidth: 700).width == 700)
        #expect(NativeCombinedPopupView.contentSize(pageCount: 6).width == (2.5 * 241 - 1).rounded())
        #expect(NativeCombinedPopupView.layoutColumns(width: 240) == 1)
        #expect(NativeCombinedPopupView.layoutColumns(width: 602) == 3)
    }

    @Test func `pages resume where they were left until the popup has been closed for hours`() {
        let showing = NativeCombinedShowing()
        let ids = [NativeCombinedAccounts.overviewID, "a", "b", "c"]
        showing.leftLeadingID = "b"
        showing.leftSelectionID = "c"
        #expect(showing.resumed(validIDs: ids, now: self.now) == nil)
        showing.closed(at: self.now)
        #expect(showing.resumed(validIDs: ids, now: self.now.addingTimeInterval(600))?.leading == "b")
        #expect(showing.resumed(validIDs: ids, now: self.now.addingTimeInterval(600))?.selection == "c")
        // A page that has gone leaves the selection at the leading page; a leading page that has gone resumes
        // nothing.
        #expect(showing.resumed(validIDs: ["b"], now: self.now.addingTimeInterval(600))?.selection == "b")
        #expect(showing.resumed(validIDs: ["a", "c"], now: self.now.addingTimeInterval(600)) == nil)
        #expect(showing.resumed(
            validIDs: ids, now: self.now.addingTimeInterval(NativeCombinedShowing.resumeInterval + 1)) == nil)
        showing.begin(openingID: "c", leadingID: "b", pageOrder: ["a", "b", "c"], width: 602)
        #expect(showing.openingID == "c")
        #expect(showing.openingLeadingID == "b")
        showing.begin(openingID: "a", pageOrder: ["a", "b", "c"], width: 602)
        #expect(showing.openingLeadingID == "a")
    }

    @Test func `drained accounts sort to the back while accounts with usage left stay together`() {
        let full = self.account(.claude, id: "full", activity: -600, left: 90)
        let drained = self.account(.claude, id: "drained", activity: -10, left: 2)
        let codex = self.account(.codex, id: "codex", activity: -60, left: 50)
        let kimi = self.account(.kimi, id: "kimi", activity: -900)
        let model = NativeCombinedAccounts(connections: [
            .init(provider: .claude, accounts: [full, drained]),
            .init(provider: .codex, accounts: [codex]),
            .init(provider: .kimi, accounts: [kimi]),
        ], now: self.now)
        // Recency orders those with usage left; the drained account, though used last, goes to the back alone.
        #expect(model.pages.map(\.account.id) == ["codex", "full", "kimi", "drained"])
        // The drained account's provider shows a mark of its own there, in page order.
        let indicators = model.indicators(selectedID: model.pages.last?.id)
        #expect(indicators.map(\.id) == [
            NativeCombinedAccounts.overviewID, "provider:codex", "provider:claude", "provider:kimi",
            "provider:claude:claude:drained",
        ])
        #expect(indicators.last?.selected == true)
        #expect(indicators.allSatisfy { !$0.expanded })
    }

    @Test func `accounts of one provider that both have usage left stay side by side`() {
        let first = self.account(.codex, id: "first", activity: -10, left: 60)
        let second = self.account(.codex, id: "second", activity: -900, left: 40)
        let claude = self.account(.claude, id: "claude", activity: -60, left: 80)
        let model = NativeCombinedAccounts(connections: [
            .init(provider: .codex, accounts: [first, second]),
            .init(provider: .claude, accounts: [claude]),
        ], now: self.now)
        #expect(model.pages.map(\.account.id) == ["first", "second", "claude"])
        let indicators = model.indicators(selectedID: model.pages.first?.id)
        #expect(indicators.filter(\.expanded).map(\.id) == ["provider:codex", "codex:first", "codex:second"])
        #expect(indicators.filter(\.expanded).allSatisfy { $0.group == "provider:codex" })
    }

    @Test func `usage left follows the fuel reserve and a passed reset refills the window`() {
        let low = self.account(.codex, id: "low", left: 4)
        // The standard reserve is the lowest default quota warning, 20% left.
        let reserve = self.account(.codex, id: "reserve", left: 20)
        let plenty = self.account(.codex, id: "plenty", left: 21)
        let unknown = self.account(.codex, id: "unknown")
        var refilled = self.account(.codex, id: "refilled", left: 0)
        refilled.quotaWindows = refilled.quotaWindows.mapValues {
            RateWindow(
                usedPercent: $0.usedPercent,
                windowMinutes: 10080,
                resetsAt: self.now.addingTimeInterval(-60),
                resetDescription: nil)
        }
        #expect(!NativeCombinedAccounts.hasUsageLeft(low, now: self.now))
        #expect(!NativeCombinedAccounts.hasUsageLeft(reserve, now: self.now))
        #expect(NativeCombinedAccounts.hasUsageLeft(plenty, now: self.now))
        #expect(NativeCombinedAccounts.hasUsageLeft(unknown, now: self.now))
        #expect(NativeCombinedAccounts.hasUsageLeft(refilled, now: self.now))
        #expect(NativeCombinedAccounts.usageLeft(low, now: self.now) == 4)
        #expect(NativeCombinedAccounts.usageLeft(refilled, now: self.now) == nil)
    }

    @Test func `rendering includes partial columns as the viewport crosses page boundaries`() {
        #expect(NativeCombinedPopupView.intersectingColumns(leading: 0, width: 602) == 0...2)
        #expect(NativeCombinedPopupView.intersectingColumns(leading: 120, width: 602) == 0...2)
        #expect(NativeCombinedPopupView.intersectingColumns(leading: 121, width: 602) == 0...2)
        #expect(NativeCombinedPopupView.intersectingColumns(leading: 122, width: 602) == 0...3)
        #expect(NativeCombinedPopupView.intersectingColumns(leading: 241, width: 602) == 1...3)
        #expect(NativeCombinedPopupView.intersectingColumns(leading: 1566, width: 602) == 6...8)
        #expect(NativeCombinedPopupView.intersectingColumns(leading: 0, width: 722) == 0...2)
    }

    @Test func `range propagation includes partial accounts and leaves hidden providers dormant`() {
        let pages: [NativeCombinedAccounts.Page] = [
            .init(provider: .codex, account: self.account(.codex, id: "first")),
            .init(provider: .codex, account: self.account(.codex, id: "second")),
            .init(provider: .claude, account: self.account(.claude, id: "third")),
            .init(provider: .kimi, account: self.account(.kimi, id: "fourth")),
        ]
        #expect(NativeCombinedPopupView.providersInView(pages, columns: 0...0).isEmpty)
        #expect(NativeCombinedPopupView.providersInView(pages, columns: 0...2) == [.codex])
        #expect(NativeCombinedPopupView.providersInView(pages, columns: 2...3) == [.codex, .claude])
        #expect(NativeCombinedPopupView.providersInView(pages, columns: 3...4) == [.claude, .kimi])
        #expect(NativeCombinedPopupView.providersInView(pages, columns: 4...8) == [.kimi])
        // Removing preceding accounts changes the provider at the same visible index immediately.
        #expect(NativeCombinedPopupView.providersInView(Array(pages.dropFirst(2)), columns: 1...1) == [.claude])
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

    @Test func `page identities are provider scoped and accounts with usage left stay contiguous`() {
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

    @Test func `incoming accounts join a frozen order at its end and keep the visible page identity`() {
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
        #expect(updated.pages.map(\.account.id) == ["other", "one", "new"])
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

    private static func sameStorage<Element>(_ lhs: [Element], _ rhs: [Element]) -> Bool {
        lhs.withUnsafeBufferPointer { left in rhs.withUnsafeBufferPointer { left.baseAddress == $0.baseAddress } }
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
        activity: TimeInterval? = nil,
        left: Double? = nil) -> NativeOrbitAccountPresentation
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
            metrics: metrics,
            quotaWindows: left.map { left in
                ["nativeQuota:weekly": RateWindow(
                    usedPercent: 100 - left,
                    windowMinutes: 10080,
                    resetsAt: self.now.addingTimeInterval(86400),
                    resetDescription: nil)]
            } ?? [:])
    }
}
