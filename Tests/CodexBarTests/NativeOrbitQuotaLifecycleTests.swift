import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct NativeOrbitQuotaLifecycleTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test
    func `recorded quota periods survive cadence changes and a save load cycle`() throws {
        let snapshots = [300, 300, 600, 600].enumerated().map { index, minutes in
            self.snapshot(offset: Double(index * 300 - 1200), session: Double(index * 10), minutes: minutes)
        }
        let history = try self.record(snapshots)
        let widget = NativeOrbitHistoryWidget(histories: history, now: self.now, days: 7, provider: .claude)
        let lane = try #require(widget.lanes.first { $0.id == "nativeQuota:primary" })
        #expect(lane.samples.filter { !$0.isResetEdge }.map(\.period) == [18000, 18000, 36000, 36000])
        #expect(widget.nearest(lane, to: self.now.addingTimeInterval(-1050))?.period == 18000)
        #expect(widget.nearest(lane, to: self.now.addingTimeInterval(-450))?.period == 36000)
    }

    @Test
    func `a retired quota stays in old history without bridging its absence when it returns`() throws {
        let history = try self.record(self.transition)
        let widget = NativeOrbitHistoryWidget(histories: history, now: self.now, days: 7, provider: .claude)
        let lane = try #require(widget.lanes.first { $0.id == "nativeQuota:primary" })
        #expect(widget.nearest(lane, to: self.now.addingTimeInterval(-1050))?.available == 50)
        #expect(widget.nearest(lane, to: self.now.addingTimeInterval(-450)) == nil)
        #expect(lane.samples.last?.segment != lane.samples.first?.segment)
        #expect(lane.samples.filter { !$0.isResetEdge }.map(\.available) == [60, 40, 20])
    }

    @Test
    func `historical dials restore both old quotas and only weekly during the retired interval`() throws {
        let history = try self.record(self.transition)
        let current = self.snapshot(offset: 0, session: 80)
        let account = self.account(snapshot: current, history: history)
        let before = NativeOrbitHistoricalInspection.windows(
            account: account, date: self.now.addingTimeInterval(-1050), now: self.now, days: 7)
        #expect(Set(before.map(\.id)) == ["primary", "secondary"])
        #expect(before.first { $0.id == "primary" }?.period == 18000)
        let retired = NativeOrbitHistoricalInspection.windows(
            account: account, date: self.now.addingTimeInterval(-450), now: self.now, days: 7)
        #expect(retired.map(\.id) == ["secondary"])
    }

    @Test
    func `retired historical lanes do not produce forecasts or future reset events`() throws {
        let history = try self.record(Array(self.transition.dropLast()))
        let current = self.snapshot(offset: 0, session: nil)
        let account = self.account(snapshot: current, history: history)
        let state = NativeOrbitPopupState()
        state.now = self.now
        state.accounts = [account]
        let projection = state.projection(for: account)
        #expect(projection.lane("nativeQuota:primary") == nil)
        #expect(projection.lane("nativeQuota:secondary") != nil)
        #expect(!projection.events.contains { $0.id.contains("nativeQuota:primary") })
    }

    @Test
    func `a quota returning after retirement is not evidence of intervening consumption or resets`() throws {
        let history = try self.record(self.transition)
        let primary = history.filter {
            $0.name.rawValue == "nativeQuota:primary" || $0.name.isNativeMetricObservation
        }
        #expect(!NativeOrbitActivity.consumptionDates(primary).contains(self.now))
        let prepared = NativeOrbitPreparedWarningHistory(history: primary)
        #expect(!prepared.consumptionIntervals(at: self.now).contains { $0.interval.upperBound == self.now })
        let events = NativeOrbitResetEvent.events(
            quotaHistories: primary.filter(\.name.isNativeQuotaObservation),
            metricHistories: primary.filter(\.name.isNativeMetricObservation),
            provider: .claude,
            now: self.now)
        #expect(!events.contains { $0.date >= self.now.addingTimeInterval(-600) })
    }

    @Test
    func `a quota label change preserves the name observed at an earlier instant`() throws {
        let snapshots = ["Old allowance", "Old allowance", "Renamed allowance"].enumerated().map { index, title in
            UsageSnapshot(
                primary: nil,
                secondary: self.window(used: 30, minutes: 10080),
                extraRateWindows: [.init(
                    id: "scoped-fixture",
                    title: title,
                    window: self.window(used: Double(index * 10), minutes: 300))],
                updatedAt: self.now.addingTimeInterval(Double(index * 300 - 600)))
        }
        let history = try self.record(snapshots)
        var widget = NativeOrbitHistoryWidget(
            histories: history,
            now: self.now,
            days: 7,
            quotaLabels: ["nativeQuota:scoped-fixture": "Renamed allowance"],
            provider: .claude)
        widget.selectedDate = self.now.addingTimeInterval(-450)
        let index = try #require(widget.lanes.firstIndex { $0.id == "nativeQuota:scoped-fixture" })
        #expect(widget.legendLabels[index] == "Old allowance")
    }

    @Test
    func `a present but unmeasured window stays applicable with unknown usage`() throws {
        var missing = self.snapshot(offset: -600, session: nil)
        missing.quotaWindowPresence = ["primary": true, "secondary": true]
        let history = try self.record([
            self.snapshot(offset: -1200, session: 40), self.snapshot(offset: -900, session: 60),
            missing, self.snapshot(offset: 0, session: 80),
        ])
        let account = self.account(snapshot: self.snapshot(offset: 0, session: 80), history: history)
        let windows = NativeOrbitHistoricalInspection.windows(
            account: account, date: self.now.addingTimeInterval(-450), now: self.now, days: 7)
        let session = try #require(windows.first { $0.id == "primary" })
        #expect(session.usedFraction == nil)
        #expect(session.period == 18000)
        #expect(!NativeOrbitQuotaTimeline(history: history).isAbsent(
            "nativeQuota:primary", at: self.now.addingTimeInterval(-450)))
    }

    @Test
    func `an observed unknown cadence does not inherit a previous known period`() throws {
        let snapshots = [300, nil].enumerated().map { index, minutes in
            UsageSnapshot(
                primary: .init(usedPercent: 20, windowMinutes: minutes, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: self.now.addingTimeInterval(Double(index * 300 - 300)))
        }
        let history = try self.record(snapshots, provider: .langdock)
        let lane = try #require(NativeOrbitHistoryWidget(
            histories: history, now: self.now, days: 7, provider: .langdock).lanes.first)
        #expect(lane.samples.first?.period == 18000)
        #expect(lane.samples.last?.period == nil)
        #expect(NativeOrbitAccountProjection.project(lane, now: self.now, active: false)?.period == nil)
    }

    @Test
    func `legacy five hour history remains inspectable after weekly only recording begins`() throws {
        let legacy = PlanUtilizationSeriesHistory(name: .session, windowMinutes: 300, entries: [
            .init(capturedAt: self.now.addingTimeInterval(-1200), usedPercent: 40, resetsAt: nil),
            .init(capturedAt: self.now.addingTimeInterval(-900), usedPercent: 60, resetsAt: nil),
        ])
        let current = self.snapshot(offset: 0, session: nil)
        let history = try self.record([self.snapshot(offset: -600, session: nil), current]) + [legacy]
        let windows = NativeOrbitHistoricalInspection.windows(
            account: self.account(snapshot: current, history: history),
            date: self.now.addingTimeInterval(-1050),
            now: self.now,
            days: 7)
        #expect(windows.first { $0.id == "primary" }?.usedFraction == 0.5)
        #expect(windows.first { $0.id == "primary" }?.period == 18000)
        #expect(!windows.contains { $0.id == "secondary" })
    }

    @Test
    func `an explicitly empty covered inventory retires quotas without adding zero observations`() throws {
        var empty = UsageSnapshot(primary: nil, secondary: nil, updatedAt: self.now)
        empty.quotaWindowPresence = ["primary": false, "secondary": false]
        let history = try self.record([self.snapshot(offset: -600, session: 40), empty])
        let timeline = NativeOrbitQuotaTimeline(history: history)
        #expect(timeline.isAbsent("nativeQuota:primary", at: self.now))
        #expect(timeline.isAbsent("nativeQuota:secondary", at: self.now))
        #expect(history.first { $0.name.rawValue == "nativeQuota:primary" }?.entries.map(\.usedPercent) == [40])
    }

    @Test
    func `partial display snapshots cannot declare a quota retired`() throws {
        let row = ClaudeSwapAccountRow(
            number: 1,
            email: "fixture@example.test",
            isActive: false,
            usageStatus: .unavailable,
            fiveHour: .init(usedPercent: 100, resetsAt: self.now.addingTimeInterval(-1)),
            sevenDay: .init(usedPercent: 100, resetsAt: self.now.addingTimeInterval(86400)))
        let projected = try #require(ClaudeSwapAccountProjection.accountSnapshots(
            from: .init(activeAccountNumber: nil, accounts: [row]), now: self.now).first?.snapshot)
        #expect(projected.primary == nil)
        #expect(projected.quotaWindowPresence == nil)
        let old = try self.record([self.snapshot(offset: -600, session: 40)])
        let overlay = UsageStore.nativeOrbitHistoryIncludingCurrentSnapshot(old, provider: .claude, snapshot: projected)
        #expect(!NativeOrbitQuotaTimeline(history: overlay).isAbsent("nativeQuota:primary", at: self.now))
    }

    @Test
    func `source presence survives mapping and enrichment but not cached snapshot replay`() throws {
        let raw = try ClaudeUsageFetcher._mapOAuthUsageForTesting(Data("""
        {"five_hour":{"resets_at":"2026-11-02T12:00:00Z"},"seven_day":{"utilization":30}}
        """.utf8))
        #expect(raw.primary == nil)
        #expect(raw.quotaWindowPresence == ["primary": true, "secondary": true])
        let mapped = ClaudeOAuthFetchStrategy._snapshotForTesting(from: raw)
            .withIdentity(.init(
                providerID: .claude,
                accountEmail: "fixture@example.test",
                accountOrganization: nil,
                loginMethod: nil))
        #expect(mapped.quotaWindowPresence == raw.quotaWindowPresence)
        let cached = try JSONDecoder().decode(UsageSnapshot.self, from: JSONEncoder().encode(mapped))
        #expect(cached.quotaWindowPresence == nil)
        let web = try ClaudeWebAPIFetcher._parseUsageResponseForTesting(Data("""
        {"five_hour":{"resets_at":"2026-11-02T12:00:00Z"},"seven_day":null}
        """.utf8))
        #expect(web.quotaWindowPresence == ["primary": true, "secondary": false])
    }

    @Test(arguments: ["{\"utilization\":\"unknown\"}", "{\"resets_at\":42}"])
    func `malformed utilization does not turn a present OAuth window into a retirement`(window: String) throws {
        let raw = try ClaudeUsageFetcher._mapOAuthUsageForTesting(Data(
            "{\"five_hour\":\(window),\"seven_day\":{\"utilization\":30}}".utf8))
        #expect(raw.primary == nil)
        #expect(raw.quotaWindowPresence?["primary"] == true)
    }

    @Test
    func `the OAuth apps weekly alias is present in the same logical slot it measures`() throws {
        let raw = try ClaudeUsageFetcher._mapOAuthUsageForTesting(Data("""
        {"seven_day":null,"seven_day_oauth_apps":{"utilization":30}}
        """.utf8))
        #expect(raw.secondary?.usedPercent == 30)
        #expect(raw.quotaWindowPresence == ["primary": false, "secondary": true])
    }

    @Test
    func `Codex canonicalization respects each reading cadence in a mixed old transport slot`() {
        let history = PlanUtilizationSeriesHistory(name: "nativeQuota:primary", windowMinutes: 10080, entries: [
            .init(
                capturedAt: self.now.addingTimeInterval(-300),
                usedPercent: 20,
                resetsAt: nil,
                quotaDescriptor: .init(label: "Session", windowMinutes: 300)),
            .init(
                capturedAt: self.now,
                usedPercent: 30,
                resetsAt: nil,
                quotaDescriptor: .init(label: "Weekly", windowMinutes: 10080)),
        ])
        let canonical = UsageStore.nativeOrbitCanonicalQuotaHistories(provider: .codex, histories: [history])
        #expect(canonical.first { $0.name.rawValue == "nativeQuota:primary" }?.entries.map(\.usedPercent) == [20])
        #expect(canonical.first { $0.name.rawValue == "nativeQuota:secondary" }?.entries.map(\.usedPercent) == [30])
    }

    @Test(arguments: ["{}", "{\"spend\":{}}", "{\"five_hour\":\"unreadable\"}"])
    func `empty adjunct and malformed only replies carry no quota retirement authority`(body: String) throws {
        let oauth = try JSONDecoder().decode(OAuthUsageResponse.self, from: Data(body.utf8))
        #expect(oauth.quotaWindowPresence.isEmpty)
        let web = try ClaudeWebAPIFetcher._parseUsageResponseForTesting(Data(body.utf8))
        #expect(web.quotaWindowPresence == nil)
    }

    @Test
    func `explicit null quota keys still declare a covered empty inventory`() throws {
        let body = Data("{\"five_hour\":null,\"seven_day\":null}".utf8)
        let oauth = try JSONDecoder().decode(OAuthUsageResponse.self, from: body)
        let web = try ClaudeWebAPIFetcher._parseUsageResponseForTesting(body)
        #expect(oauth.quotaWindowPresence == ["primary": false, "secondary": false])
        #expect(web.quotaWindowPresence == ["primary": false, "secondary": false])
    }

    private var transition: [UsageSnapshot] {
        [
            self.snapshot(offset: -1200, session: 40),
            self.snapshot(offset: -900, session: 60),
            self.snapshot(offset: -600, session: nil),
            self.snapshot(offset: -300, session: nil),
            self.snapshot(offset: 0, session: 80),
        ]
    }

    private func snapshot(offset: Double, session: Double?, minutes: Int = 300) -> UsageSnapshot {
        var snapshot = UsageSnapshot(
            primary: session.map { self.window(used: $0, minutes: minutes) },
            secondary: self.window(used: 30 + (offset + 1200) / 100, minutes: 10080),
            updatedAt: self.now.addingTimeInterval(offset))
        snapshot.quotaWindowPresence = ["primary": session != nil, "secondary": true]
        return snapshot
    }

    private func window(used: Double, minutes: Int) -> RateWindow {
        RateWindow(
            usedPercent: used,
            windowMinutes: minutes,
            resetsAt: self.now.addingTimeInterval(minutes == 10080 ? 86400 : -300),
            resetDescription: nil)
    }

    private func record(
        _ snapshots: [UsageSnapshot],
        provider: UsageProvider = .claude) throws -> [PlanUtilizationSeriesHistory]
    {
        var history: [PlanUtilizationSeriesHistory] = []
        for snapshot in snapshots {
            history = UsageStore.updatedPlanUtilizationHistories(
                existingHistories: history,
                samples: UsageStore.nativeOrbitHistorySamples(provider: provider, snapshot: snapshot)) ?? history
        }
        return try JSONDecoder().decode([PlanUtilizationSeriesHistory].self, from: JSONEncoder().encode(history))
    }

    private func account(snapshot: UsageSnapshot, history: [PlanUtilizationSeriesHistory])
        -> NativeOrbitAccountPresentation
    {
        NativeOrbitAccountPresentation(
            id: "fixture",
            label: "Fixture",
            email: nil,
            symbol: "person",
            isActive: false,
            canActivate: false,
            gauge: NativeUsageGaugeProjection.state(provider: .claude, snapshot: snapshot),
            updatedAt: snapshot.updatedAt,
            history: history,
            odometer: nil,
            odometerHelp: nil,
            statusText: nil,
            selection: .none,
            quotaLabels: UsageStore.nativeOrbitQuotaLabels(provider: .claude, snapshot: snapshot),
            quotaWindows: UsageStore.nativeOrbitQuotaWindowMap(provider: .claude, snapshot: snapshot))
    }
}
