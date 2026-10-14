import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct NativeOrbitHistoricalInspectionTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func `all account dials project the same pointer and return their original live state on exit`() {
        let date = self.now.addingTimeInterval(-300)
        let first = self.account(id: "first", used: [20, 40])
        let second = self.account(id: "second", used: [40, 80])
        let state = NativeOrbitPopupState()
        state.now = self.now
        state.accounts = [first, second]
        state.inspectionDate = date
        let windows = state.accounts.map {
            NativeOrbitHistoricalInspection.windows(
                account: $0,
                date: state.inspectionDate,
                now: state.now,
                days: state.days,
                preparedLanes: state.lanes(for: $0))
        }
        #expect(windows[0].first?.usedFraction == 0.3)
        #expect(windows[1].first?.usedFraction == 0.6)
        #expect(windows[0].first?.countdown?.nextReset == self.now.addingTimeInterval(3600))
        state.inspectionDate = nil
        for account in state.accounts {
            #expect(NativeOrbitHistoricalInspection.windows(
                account: account,
                date: state.inspectionDate,
                now: self.now,
                days: 1) == account.gauge.resolvedWindows)
        }
    }

    @Test func `a projecting day reads the dials back to this time yesterday, not only to midnight`() throws {
        // Projecting, the day chart spans now ± 24 h; a pointer 23 h back is before any midnight in between.
        let earlier = self.now.addingTimeInterval(-23 * 3600)
        let history = PlanUtilizationSeriesHistory(name: "nativeQuota:primary", windowMinutes: 300, entries: [
            .init(
                capturedAt: earlier.addingTimeInterval(-300),
                usedPercent: 30,
                resetsAt: earlier.addingTimeInterval(3600)),
            .init(
                capturedAt: earlier.addingTimeInterval(300),
                usedPercent: 50,
                resetsAt: earlier.addingTimeInterval(3600)),
            .init(capturedAt: self.now, usedPercent: 10, resetsAt: self.now.addingTimeInterval(3600)),
        ])
        let account = self.account(histories: [history])
        var widget = NativeOrbitHistoryWidget(histories: [history], now: self.now, days: 1)
        widget.isProjecting = true
        let window = try #require(NativeOrbitHistoricalInspection.windows(
            account: account,
            date: earlier,
            now: self.now,
            days: 1,
            preparedLanes: widget.lanes,
            isProjecting: true).first)
        #expect(window.usedFraction == 0.4)
    }

    @Test func `source cadence stays historical after a quota duration changes`() throws {
        let first = self.now.addingTimeInterval(-1200)
        let second = self.now.addingTimeInterval(-600)
        let old = PlanUtilizationSeriesHistory(name: "nativeQuota:primary", windowMinutes: 300, entries: [
            .init(capturedAt: first, usedPercent: 20, resetsAt: self.now.addingTimeInterval(3600)),
            .init(capturedAt: second, usedPercent: 40, resetsAt: self.now.addingTimeInterval(3600)),
        ])
        let recent = PlanUtilizationSeriesHistory(name: "nativeQuota:primary", windowMinutes: 600, entries: [
            .init(capturedAt: self.now, usedPercent: 50, resetsAt: self.now.addingTimeInterval(7200)),
        ])
        let account = self.account(histories: [old, recent])
        let window = try #require(NativeOrbitHistoricalInspection.windows(
            account: account, date: first.addingTimeInterval(300), now: self.now, days: 1).first)
        #expect(window.period == 18000)
        #expect(window.usedFraction == 0.3)
        #expect(NativeOrbitCountdown(window: window).segments == 5)
        let gap = try #require(NativeOrbitHistoricalInspection.windows(
            account: account, date: second.addingTimeInterval(300), now: self.now, days: 1).first)
        #expect(gap.usedFraction == nil)
    }

    @Test func `current reports and reset inventory disappear when they postdate the pointer`() {
        let spend = ProviderCostSnapshot(used: 20, limit: 100, currencyCode: "USD", updatedAt: self.now)
        var metrics = NativeOrbitAccountMetrics(reportedSpend: spend)
        metrics.bankedResets = 2
        metrics.usedResets = 1
        let historical = metrics.at(self.now.addingTimeInterval(-1), observedAt: self.now)
        #expect(historical.reportedSpend == nil)
        #expect(historical.extraUsageFraction == nil)
        #expect(historical.bankedResets == nil)
        #expect(historical.usedResets == 0)
        #expect(metrics.at(nil, observedAt: self.now).bankedResets == 2)
        #expect(metrics.at(nil, observedAt: self.now).extraUsageFraction == 0.2)
        metrics.resetInventoryObservedAt = self.now
        #expect(metrics.at(self.now.addingTimeInterval(-1), observedAt: self.now.addingTimeInterval(-120))
            .bankedResets == nil)
    }

    @Test func `prepared history updates after account data and range changes`() throws {
        let state = NativeOrbitPopupState()
        state.now = self.now
        let first = self.account(used: [20, 40])
        state.accounts = [first]
        #expect(state.lanes(for: first).first?.samples.last?.available == 60)
        let changed = self.account(used: [20, 80])
        state.accounts = [changed]
        #expect(state.lanes(for: changed).first?.samples.last?.available == 20)
        state.days = 7
        let start = try #require(state.lanes(for: changed).first?.start)
        #expect(start < Calendar.current.startOfDay(for: self.now))
    }

    @Test func `identical observations in different quota lanes keep their independent durations`() throws {
        let first = self.now.addingTimeInterval(-600)
        let deadline = self.now.addingTimeInterval(3600)
        let shared = PlanUtilizationHistoryEntry(capturedAt: first, usedPercent: 0, resetsAt: deadline)
        let session = PlanUtilizationSeriesHistory(name: "nativeQuota:primary", windowMinutes: 300, entries: [
            shared, .init(capturedAt: self.now, usedPercent: 10, resetsAt: deadline),
        ])
        let weekly = PlanUtilizationSeriesHistory(name: "nativeQuota:secondary", windowMinutes: 10080, entries: [
            shared, .init(capturedAt: self.now, usedPercent: 0, resetsAt: deadline),
        ])
        let widget = NativeOrbitHistoryWidget(histories: [session, weekly], now: self.now)
        let sessionLane = try #require(widget.lanes.first { $0.id == "nativeQuota:primary" })
        let weeklyLane = try #require(widget.lanes.first { $0.id == "nativeQuota:secondary" })
        let middle = first.addingTimeInterval(300)
        #expect(sessionLane.samples.map(\.segment) == [0, 0])
        #expect(weeklyLane.samples.map(\.segment) == [0, 0])
        #expect(widget.nearest(sessionLane, to: middle)?.period == 18000)
        #expect(widget.nearest(weeklyLane, to: middle)?.period == 604_800)
        #expect(widget.nearest(sessionLane, to: middle)?.available == 95)
        #expect(widget.nearest(weeklyLane, to: middle)?.available == 100)
    }

    private func account(
        id: String = "fixture",
        used: [Double] = [20, 40],
        histories: [PlanUtilizationSeriesHistory]? = nil) -> NativeOrbitAccountPresentation
    {
        var gauge = ComputeGauge.State()
        gauge.provider = "claude"
        gauge.windows = [UsageWindow(
            id: "primary",
            label: "Session",
            period: 18000,
            used: 0.9,
            countdown: ResetCountdown(
                units: 5,
                secondsPerUnit: 3600,
                nextReset: self.now.addingTimeInterval(7200)))]
        let history = PlanUtilizationSeriesHistory(name: "nativeQuota:primary", windowMinutes: 300, entries: [
            .init(
                capturedAt: self.now.addingTimeInterval(-600),
                usedPercent: used[0],
                resetsAt: self.now.addingTimeInterval(3600)),
            .init(capturedAt: self.now, usedPercent: used[1], resetsAt: self.now.addingTimeInterval(3600)),
        ])
        return NativeOrbitAccountPresentation(
            id: id,
            label: "Fixture",
            email: nil,
            symbol: "person",
            isActive: false,
            canActivate: false,
            gauge: gauge,
            updatedAt: self.now,
            history: histories ?? [history],
            odometer: nil,
            odometerHelp: nil,
            statusText: nil,
            selection: .none)
    }
}
