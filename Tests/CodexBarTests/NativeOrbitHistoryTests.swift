import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct NativeOrbitHistoryTests {
    @Test
    func `hourly samples tolerate polling drift`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let history = PlanUtilizationSeriesHistory(name: .weekly, windowMinutes: 10080, entries: [
            .init(capturedAt: now.addingTimeInterval(-3607), usedPercent: 20, resetsAt: nil),
            .init(capturedAt: now, usedPercent: 30, resetsAt: nil),
        ])
        let samples = NativeOrbitHistoryWidget(histories: [history], now: now, days: 7).points(history)
        #expect(samples.map(\.segment) == [0, 0])
        #expect(samples.map(\.available) == [80, 70])
    }

    @Test
    func `reset deadline rounding stays in the same period`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(86400)
        let history = PlanUtilizationSeriesHistory(name: .weekly, windowMinutes: 10080, entries: [
            .init(capturedAt: now.addingTimeInterval(-3600), usedPercent: 20, resetsAt: reset),
            .init(capturedAt: now, usedPercent: 30, resetsAt: reset.addingTimeInterval(30)),
        ])
        let samples = NativeOrbitHistoryWidget(histories: [history], now: now, days: 7).points(history)
        #expect(samples.map(\.segment) == [0, 0])
    }

    @Test
    func `long polling gaps and unmeasured resets break the line`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let history = PlanUtilizationSeriesHistory(name: .weekly, windowMinutes: 10080, entries: [
            .init(capturedAt: now.addingTimeInterval(-10800), usedPercent: 20, resetsAt: nil),
            .init(capturedAt: now.addingTimeInterval(-3600), usedPercent: 30, resetsAt: nil),
            .init(capturedAt: now, usedPercent: 0, resetsAt: nil),
        ])
        let samples = NativeOrbitHistoryWidget(histories: [history], now: now, days: 7).points(history)
        #expect(samples.map(\.segment) == [0, 1, 2])
        #expect(samples.map(\.id) == history.entries)
    }

    @Test
    func `native history retains earlier mapped observations and unmatched model lanes`() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = self.history("session", minutes: 300, dates: [-7200, -3600, 0], now: now)
        let raw = self.history("nativeQuota:primary", minutes: 300, dates: [-1800, 0], now: now)
        let model = self.history("opus", minutes: 10080, dates: [-7200, 0], now: now)
        let widget = NativeOrbitHistoryWidget(histories: [old, raw, model], now: now, days: 7)
        let series = widget.series
        #expect(series.count == 2)
        let primary = try #require(series.first { $0.name.rawValue == "nativeQuota:primary" })
        #expect(primary.entries.map(\.capturedAt) == [-7200, -3600, -1800, 0].map { now.addingTimeInterval($0) })
        #expect(series.first { $0.name == .opus } == model)
        #expect(!series.contains { $0.name == .session })
    }

    @Test
    func `Codex weekly observations unify their canonical lane including older primary slot records`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let legacy = self.history("weekly", minutes: 10080, dates: [-7200], now: now)
        let primary = self.history("nativeQuota:primary", minutes: 10080, dates: [0], now: now)
        let unknown = NativeOrbitHistoryWidget(histories: [legacy, primary], now: now, days: 7)
        #expect(unknown.series.count == 2)
        let codex = NativeOrbitHistoryWidget(histories: [legacy, primary], now: now, days: 7, provider: .codex)
        #expect(codex.series.count == 1)
        #expect(codex.series.first?.name.rawValue == "nativeQuota:secondary")
        #expect(codex.series.first?.entries.count == 2)
        let secondary = self.history("nativeQuota:secondary", minutes: 10080, dates: [-3600], now: now)
        let ambiguous = NativeOrbitHistoryWidget(
            histories: [legacy, primary, secondary], now: now, days: 7, provider: .codex)
        #expect(ambiguous.series.count == 1)
        #expect(ambiguous.series.first?.name.rawValue == "nativeQuota:secondary")
        #expect(ambiguous.series.first?.entries.count == 3)
    }

    @Test
    func `cadence changes preserve one quota lane and incompatible legacy history`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let session = self.history("nativeQuota:primary", minutes: 300, dates: [-3600], now: now)
        let weekly = self.history("nativeQuota:primary", minutes: 10080, dates: [0], now: now)
        let legacy = self.history("session", minutes: 1440, dates: [-7200], now: now)
        let widget = NativeOrbitHistoryWidget(histories: [session, weekly, legacy], now: now, days: 7)
        #expect(widget.series.count == 2)
        #expect(Set(widget.lanes.map(\.id)).count == 2)
        #expect(widget.series.first { $0.name.rawValue == "nativeQuota:primary" }?.entries.count == 2)
        #expect(widget.series.contains(legacy))
    }

    @Test
    func `chart ranges retain their elapsed duration across daylight savings`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/London"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 12)))
        for days in [1, 7, 30] {
            let widget = NativeOrbitHistoryWidget(histories: [], now: now, days: days, calendar: calendar)
            #expect(now.timeIntervalSince(widget.start) == Double(days) * 86400)
        }
        let midnight = calendar.startOfDay(for: now)
        let history = self.history("weekly", minutes: 10080, dates: [-1, 0, 60], now: midnight)
        let today = NativeOrbitHistoryWidget(histories: [history], now: now, calendar: calendar)
        #expect(today.points(history).map(\.date) == [
            midnight.addingTimeInterval(-1), midnight, midnight.addingTimeInterval(60),
        ])
        #expect(today.start == now.addingTimeInterval(-86400))
    }

    @Test
    func `sparse observations retain their readings without connecting missing periods`() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let history = PlanUtilizationSeriesHistory(name: .weekly, windowMinutes: 10080, entries: [
            .init(capturedAt: now.addingTimeInterval(-14400), usedPercent: 20, resetsAt: nil),
            .init(capturedAt: now.addingTimeInterval(-3600), usedPercent: 30, resetsAt: nil),
            .init(capturedAt: now.addingTimeInterval(-1800), usedPercent: 35, resetsAt: nil),
            .init(capturedAt: now, usedPercent: 0, resetsAt: nil),
        ])
        let widget = NativeOrbitHistoryWidget(histories: [history], now: now, days: 7)
        let lane = try #require(widget.lanes.first)
        #expect(lane.samples.map(\.segment) == [0, 1, 1, 2])
        #expect(lane.renderSamples.map(\.id) == history.entries)
        #expect(lane.samples.count == 4)
    }

    @Test
    func `scheduled markers preserve reported recovery without inventing future observations`() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let history = self.history("nativeQuota:primary", minutes: 300, dates: [-3600, 0], now: now)
        let deadline = now.addingTimeInterval(60)
        let widget = NativeOrbitHistoryWidget(
            histories: [history],
            now: now,
            days: 1,
            quotaLabels: ["nativeQuota:primary": "Session"],
            quotaWindows: ["nativeQuota:primary": RateWindow(
                usedPercent: 25,
                windowMinutes: 300,
                resetsAt: deadline,
                resetDescription: nil,
                nextRegenPercent: 12.5)])
        let event = try #require(widget.events.first)
        #expect(event.date == deadline)
        #expect(event.recoveryPercent == 12.5)
        #expect(widget.chartEnd == now)
        #expect(widget.visibleEvents.isEmpty)
        #expect(widget.lanes.first?.samples.count == 2)
        #expect(widget.lanes.flatMap(\.samples).allSatisfy { $0.date <= now })
    }

    @Test
    func `all accounts share a calendar axis and distant deadlines remain in schedule help`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let windows = Dictionary(uniqueKeysWithValues: [2, 5, 10, 20].enumerated().map { index, days in
            ("nativeQuota:lane\(index)", RateWindow(
                usedPercent: 25,
                windowMinutes: 10080,
                resetsAt: now.addingTimeInterval(Double(days) * 86400),
                resetDescription: nil))
        })
        let day = NativeOrbitHistoryWidget(histories: [], now: now, days: 1, quotaWindows: windows)
        let week = NativeOrbitHistoryWidget(histories: [], now: now, days: 7, quotaWindows: windows)
        let month = NativeOrbitHistoryWidget(histories: [], now: now, days: 30, quotaWindows: windows)
        #expect(day.events.count == 4)
        #expect(day.visibleEvents.isEmpty)
        #expect(day.chartEnd == now)
        #expect(day.chartEnd == week.chartEnd)
        #expect(week.chartEnd == month.chartEnd)
        #expect(week.visibleEvents.isEmpty)
        #expect(month.visibleEvents.isEmpty)
        #expect(week.events.count == 4)
        #expect(month.events.count == 4)
    }

    @Test
    func `past deadlines and invalid recovery amounts never become future refills`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let widget = NativeOrbitHistoryWidget(histories: [], now: now, quotaWindows: [
            "nativeQuota:old": RateWindow(
                usedPercent: 25, windowMinutes: 300, resetsAt: now.addingTimeInterval(-60), resetDescription: nil),
            "nativeQuota:primary": RateWindow(
                usedPercent: 25,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(60),
                resetDescription: nil,
                nextRegenPercent: .nan),
        ])
        #expect(widget.events.count == 1)
        #expect(widget.events.first?.recoveryPercent == nil)
    }

    @Test
    func `sample identities survive an earlier observation entering the selected period`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let recent = self.history("nativeQuota:primary", minutes: 300, dates: [-3600, 0], now: now)
        let expanded = self.history("nativeQuota:primary", minutes: 300, dates: [-7200, -3600, 0], now: now)
        let widget = NativeOrbitHistoryWidget(histories: [], now: now, days: 7)
        #expect(widget.points(recent).map(\.id) == widget.points(expanded).dropFirst().map(\.id))
    }

    @Test
    func `hover in a recording gap never carries an earlier value forward`() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let history = PlanUtilizationSeriesHistory(name: "nativeQuota:primary", windowMinutes: 300, entries: [
            .init(capturedAt: now.addingTimeInterval(-18000), usedPercent: 19.875, resetsAt: nil),
            .init(capturedAt: now.addingTimeInterval(-3600), usedPercent: 23.625, resetsAt: nil),
        ])
        let widget = NativeOrbitHistoryWidget(histories: [history], now: now, days: 7)
        let lane = try #require(widget.lanes.first)
        #expect(widget.nearest(lane, to: now.addingTimeInterval(-3600))?.available == 76.375)
        #expect(widget.seriesHelp(lane, selectedDate: now.addingTimeInterval(-3600)).contains("76.375%"))
        #expect(widget.nearest(lane, to: now.addingTimeInterval(-10800)) == nil)
        #expect(widget.legendSample(lane, selectedDate: now.addingTimeInterval(-10800)) == nil)
        #expect(widget.seriesHelp(lane, selectedDate: now.addingTimeInterval(-10800))
            .contains("No observation at this time"))
        #expect(widget.nearest(lane, to: now) == nil)
        #expect(widget.nearest(lane, to: now.addingTimeInterval(60)) == nil)
        #expect(widget.nearest(lane, to: now.addingTimeInterval(7200)) == nil)
    }

    @Test
    func `chart renders only observed timestamps inside the chosen period`() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let start = NativeOrbitHistoryWidget(histories: [], now: now).start
        let history = PlanUtilizationSeriesHistory(name: "nativeQuota:primary", windowMinutes: 300, entries: [
            .init(capturedAt: start.addingTimeInterval(-600), usedPercent: 19.875, resetsAt: nil),
            .init(capturedAt: now.addingTimeInterval(-3600), usedPercent: 23.625, resetsAt: nil),
        ])
        let widget = NativeOrbitHistoryWidget(histories: [history], now: now)
        let lane = try #require(widget.lanes.first)
        #expect(lane.samples.map(\.id) == history.entries)
        #expect(lane.renderSamples.map(\.date) == [now.addingTimeInterval(-3600)])
        #expect(lane.renderSamples.first?.available == 76.375)
        #expect(widget.nearest(lane, to: start) == nil)
        #expect(widget.nearest(lane, to: now) == nil)
    }

    @Test
    func `a reading outside the chosen period never paints that period`() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let start = NativeOrbitHistoryWidget(histories: [], now: now).start
        let history = PlanUtilizationSeriesHistory(name: "nativeQuota:tertiary", windowMinutes: 10080, entries: [
            .init(capturedAt: start.addingTimeInterval(-600), usedPercent: 12.375, resetsAt: nil),
        ])
        let widget = NativeOrbitHistoryWidget(histories: [history], now: now)
        let lane = try #require(widget.lanes.first)
        #expect(lane.samples.map(\.id) == history.entries)
        #expect(lane.renderSamples.isEmpty)
        #expect(widget.nearest(lane, to: now) == nil)
    }

    @Test
    func `every quota gauge keeps its own stable line and matching hover label`() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ids = ["nativeQuota:primary", "nativeQuota:secondary", "nativeQuota:tertiary", "nativeQuota:bonus"]
        let labels = Dictionary(uniqueKeysWithValues: zip(ids, ["Messages", "Requests", "Model quota", "Bonus quota"]))
        let histories = ids.map { self.history($0, minutes: 300, dates: [-600, 0], now: now) }
        let windows = Dictionary(uniqueKeysWithValues: ids.map {
            ($0, RateWindow(usedPercent: 25, windowMinutes: 300, resetsAt: nil, resetDescription: nil))
        })
        let widget = NativeOrbitHistoryWidget(
            histories: histories, now: now, quotaLabels: labels, quotaWindows: windows)
        #expect(Set(widget.lanes.map(\.id)) == Set(ids))
        for lane in widget.lanes {
            let label = try #require(labels[lane.history.name.rawValue])
            #expect(widget.seriesHelp(lane, selectedDate: now).hasPrefix(label + " · "))
        }
    }

    @Test
    func `unknown and changed cadence fragments retain every reading under the same quota identity`() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let histories = [
            self.history("nativeQuota:primary", minutes: 0, dates: [-7200], now: now),
            self.history("nativeQuota:primary", minutes: 300, dates: [-3600], now: now),
            self.history("nativeQuota:primary", minutes: 10080, dates: [0], now: now),
        ]
        let widget = NativeOrbitHistoryWidget(histories: histories, now: now, days: 7)
        #expect(widget.lanes.count == 1)
        let lane = try #require(widget.lanes.first)
        #expect(lane.id == "nativeQuota:primary")
        #expect(lane.history.windowMinutes == 10080)
        #expect(lane.samples.map(\.date) == [-7200.0, -3600, 0].map { now.addingTimeInterval($0) })
    }

    @Test
    func `recorded quota lanes are solid lines told apart by color`() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let histories = [
            self.history("nativeQuota:primary", minutes: 300, dates: [-600, 0], now: now),
            self.history("nativeQuota:secondary", minutes: 10080, dates: [-600, 0], now: now),
            self.history("nativeQuota:tertiary", minutes: 10080, dates: [-600, 0], now: now),
        ]
        let widget = NativeOrbitHistoryWidget(histories: histories, now: now)
        let first = try #require(widget.lanes.first)
        #expect(first.history.name.rawValue == "nativeQuota:primary")
        // Dashes are reserved for the projection; recorded lanes never use them.
        #expect(widget.lanes.allSatisfy { widget.stroke($0).dash.isEmpty })
        #expect(widget.lanes.allSatisfy { $0.samples.map(\.available) == [75, 75] })
    }

    @Test
    func `the final graph marker ends at the real observation`() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let history = self.history("nativeQuota:primary", minutes: 300, dates: [-600, -300], now: now)
        let lane = try #require(NativeOrbitHistoryWidget(histories: [history], now: now).lanes.first)
        let last = try #require(history.entries.last)
        #expect(lane.renderSamples.contains { $0.id == last && $0.date == last.capturedAt })
        #expect(lane.renderSamples.last?.date == history.entries.last?.capturedAt)
        #expect(lane.renderSamples.last?.id == last)
    }

    @Test
    func `a proven legacy quota role merges after its native cadence changes`() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let legacy = self.history("session", minutes: 300, dates: [-7200, 0], now: now)
        let native = PlanUtilizationSeriesHistory(name: "nativeQuota:primary", windowMinutes: 600, entries: [
            .init(capturedAt: now.addingTimeInterval(-3600), usedPercent: 30.125, resetsAt: nil),
            .init(capturedAt: now, usedPercent: 40.375, resetsAt: nil),
        ])
        let widget = NativeOrbitHistoryWidget(histories: [legacy, native], now: now, days: 7, provider: .claude)
        #expect(widget.lanes.count == 1)
        let lane = try #require(widget.lanes.first)
        #expect(lane.history.name.rawValue == "nativeQuota:primary")
        #expect(lane.history.windowMinutes == 600)
        #expect(lane.samples.map(\.date) == [-7200.0, -3600, 0].map { now.addingTimeInterval($0) })
        #expect(lane.samples.last?.available == 59.625)
    }

    @Test
    func `first ever observation is never projected backward into unknown history`() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let history = self.history("nativeQuota:primary", minutes: 300, dates: [-600], now: now)
        let lane = try #require(NativeOrbitHistoryWidget(histories: [history], now: now).lanes.first)
        #expect(lane.renderSamples.first?.date == history.entries[0].capturedAt)
        #expect(lane.renderSamples.last?.date == history.entries.last?.capturedAt)
        #expect(lane.samples.map(\.id) == history.entries)
    }

    @Test
    func `Kimi monthly legacy peaks merge only before its native monthly observations`() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let legacy = self.history("monthly", minutes: 43200, dates: [-7200, 0], now: now)
        let monthly = self.history("nativeQuota:kimi-monthly", minutes: 43200, dates: [-3600, 0], now: now)
        let widget = NativeOrbitHistoryWidget(histories: [legacy, monthly], now: now, days: 7, provider: .kimi)
        #expect(widget.series.count == 1)
        let merged = try #require(widget.series.first)
        #expect(merged.name.rawValue == "nativeQuota:kimi-monthly")
        #expect(merged.entries.map(\.capturedAt) == [-7200, -3600, 0].map { now.addingTimeInterval($0) })
    }

    @Test
    func `Kimi legacy session and weekly follow its reversed authoritative quota slots`() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let legacySession = self.history("session", minutes: 300, dates: [-7200, 0], now: now)
        let legacyWeekly = self.history("weekly", minutes: 10080, dates: [-7200, 0], now: now)
        let weekly = self.history("nativeQuota:primary", minutes: 10080, dates: [-3600, 0], now: now)
        let session = self.history("nativeQuota:secondary", minutes: 300, dates: [-3600, 0], now: now)
        let widget = NativeOrbitHistoryWidget(
            histories: [legacySession, legacyWeekly, weekly, session], now: now, days: 7, provider: .kimi)
        #expect(widget.series.count == 2)
        let primary = try #require(widget.series.first { $0.name.rawValue == "nativeQuota:primary" })
        let secondary = try #require(widget.series.first { $0.name.rawValue == "nativeQuota:secondary" })
        let dates = [-7200.0, -3600, 0].map { now.addingTimeInterval($0) }
        #expect(primary.windowMinutes == 10080)
        #expect(primary.entries.map(\.capturedAt) == dates)
        #expect(secondary.windowMinutes == 300)
        #expect(secondary.entries.map(\.capturedAt) == dates)
    }

    @Test
    func `legacy observations inside a native recording gap remain in the graph`() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let legacy = self.history("weekly", minutes: 10080, dates: [-7200, -3600, -1800, 0], now: now)
        let native = self.history("nativeQuota:secondary", minutes: 10080, dates: [-7200, 0], now: now)
        let widget = NativeOrbitHistoryWidget(
            histories: [legacy, native], now: now, days: 7, provider: .codex)
        let lane = try #require(widget.lanes.first)
        #expect(widget.lanes.count == 1)
        #expect(lane.samples.map(\.date) == [-7200.0, -3600, -1800, 0].map { now.addingTimeInterval($0) })
    }

    @Test
    func `moving rolling deadlines do not fragment a continuous usage history`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let history = PlanUtilizationSeriesHistory(name: "nativeQuota:secondary", windowMinutes: 300, entries: [
            .init(
                capturedAt: now.addingTimeInterval(-600),
                usedPercent: 30,
                resetsAt: now.addingTimeInterval(12000)),
            .init(
                capturedAt: now.addingTimeInterval(-300),
                usedPercent: 35,
                resetsAt: now.addingTimeInterval(12300)),
            .init(capturedAt: now, usedPercent: 40, resetsAt: now.addingTimeInterval(12600)),
        ])
        let widget = NativeOrbitHistoryWidget(histories: [history], now: now)
        #expect(widget.points(history).map(\.segment) == [0, 0, 0])
    }

    @Test
    func `partial quota recovery remains measured data within the current reset period`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let deadline = now.addingTimeInterval(12000)
        let history = PlanUtilizationSeriesHistory(name: "nativeQuota:secondary", windowMinutes: 300, entries: [
            .init(capturedAt: now.addingTimeInterval(-600), usedPercent: 90, resetsAt: deadline),
            .init(capturedAt: now.addingTimeInterval(-300), usedPercent: 65, resetsAt: deadline),
            .init(capturedAt: now, usedPercent: 70, resetsAt: deadline),
        ])
        let widget = NativeOrbitHistoryWidget(histories: [history], now: now)
        #expect(widget.points(history).map(\.segment) == [0, 0, 0])
        #expect(widget.points(history).map(\.available) == [10, 35, 30])
    }

    @Test
    func `quota overage appears as exhausted instead of dropping the observation`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let history = PlanUtilizationSeriesHistory(name: .weekly, windowMinutes: 10080, entries: [
            .init(capturedAt: now, usedPercent: 105, resetsAt: nil),
        ])
        let widget = NativeOrbitHistoryWidget(histories: [history], now: now)
        #expect(widget.points(history).map(\.available) == [0])
    }

    @Test
    func `persisted observations retain exact source timestamps across app starts`() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let date = Date(timeIntervalSinceReferenceDate: 800_000_000.123456)
        let reset = date.addingTimeInterval(12000.654321)
        let history = PlanUtilizationSeriesHistory(name: "nativeQuota:primary", windowMinutes: 300, entries: [
            .init(capturedAt: date, usedPercent: 23.625, resetsAt: reset),
        ])
        let disk = PlanUtilizationHistoryStore(directoryURL: directory)
        disk.save([.codex: PlanUtilizationHistoryBuckets(accounts: ["fixture-owner": [history]])])
        let entry = try #require(disk.load()[.codex]?.accounts["fixture-owner"]?.first?.entries.first)
        #expect(entry.capturedAt == date)
        #expect(entry.resetsAt == reset)
    }

    @Test
    func `a live reading preserves all recorded observations within the retention period`() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let entries = (1...20001).reversed().map {
            PlanUtilizationHistoryEntry(capturedAt: now.addingTimeInterval(-Double($0)), usedPercent: 20, resetsAt: nil)
        }
        let history = PlanUtilizationSeriesHistory(name: "nativeQuota:primary", windowMinutes: 300, entries: entries)
        let updated = try #require(UsageStore.updatedPlanUtilizationHistories(
            existingHistories: [history],
            samples: [.init(
                name: history.name,
                windowMinutes: 300,
                entry: .init(capturedAt: now, usedPercent: 21, resetsAt: nil))]))
        #expect(updated.first?.entries.count == 20002)
        #expect(updated.first?.entries.first?.capturedAt == entries.first?.capturedAt)
    }

    @Test
    func `dense flat runs render their endpoints while hover retains every measurement`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let history = PlanUtilizationSeriesHistory(
            name: "nativeQuota:primary",
            windowMinutes: 300,
            entries:
            (0..<10000).map { .init(
                capturedAt: now.addingTimeInterval(Double($0) - 9999),
                usedPercent: 20,
                resetsAt: nil) })
        let widget = NativeOrbitHistoryWidget(histories: [history], now: now)
        let lane = widget.lanes[0]
        #expect(lane.samples.count == 10000)
        #expect(lane.renderSamples.map(\.id) == [history.entries[0], history.entries[9999]])
        #expect(widget.nearest(lane, to: history.entries[4321].capturedAt)?.id == history.entries[4321])
    }

    @Test
    func `rendered history retains quota changes and segment boundaries`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let history = PlanUtilizationSeriesHistory(
            name: "nativeQuota:primary",
            windowMinutes: 300,
            entries:
            [20.0, 20, 20, 40, 40, 25, 25, 0, 0].enumerated().map {
                .init(
                    capturedAt: now.addingTimeInterval(Double($0.offset) - 8),
                    usedPercent: $0.element,
                    resetsAt: nil)
            })
        let lane = NativeOrbitHistoryWidget(histories: [history], now: now).lanes[0]
        #expect(lane.renderSamples.map(\.id) == [0, 2, 3, 4, 5, 6, 7, 8].map { history.entries[$0] })
    }

    @Test
    func `coverage excludes prior observations and leaves the selected period empty`() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000.875)
        let start = NativeOrbitHistoryWidget(histories: [], now: now, days: 30).start
        let prior = start.addingTimeInterval(-0.125)
        let history = self.history("nativeQuota:primary", minutes: 300, dates: [0], now: prior)
        let widget = NativeOrbitHistoryWidget(histories: [history], now: now, days: 30)
        let lane = try #require(widget.lanes.first)
        #expect(lane.renderSamples.isEmpty)
        let coverage = widget.coverage(lane)
        #expect(coverage.observationCount == 0)
        #expect(coverage.observedDayCount == 0)
        #expect(coverage.firstObservedAt == nil)
        #expect(coverage.lastObservedAt == nil)
        #expect(coverage.priorObservedAt == prior)
    }

    @Test
    func `coverage counts every actual flat reading and keeps exact first and last capture dates`() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000.875)
        let dates: [TimeInterval] = [-86400.5, -86400.25, -3600.5, -3600.25, -3600.125]
        let history = self.history("nativeQuota:claude-weekly-scoped-fable", minutes: 10080, dates: dates, now: now)
        let widget = NativeOrbitHistoryWidget(histories: [history], now: now, days: 30)
        let lane = try #require(widget.lanes.first)
        #expect(lane.renderSamples.count < history.entries.count)
        let coverage = widget.coverage(lane)
        #expect(coverage.observationCount == 5)
        #expect(coverage.observedDayCount == 2)
        #expect(coverage.firstObservedAt == history.entries.first?.capturedAt)
        #expect(coverage.lastObservedAt == history.entries.last?.capturedAt)
        #expect(coverage.lastObservedAt != now)
        #expect(coverage.priorObservedAt == nil)
    }

    @Test
    func `coverage uses the selected rolling boundary and excludes future readings`() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000.875)
        let start = NativeOrbitHistoryWidget(histories: [], now: now).start
        let dates = [
            start.addingTimeInterval(-0.25),
            start,
            start.addingTimeInterval(0.125),
            now,
            now
                .addingTimeInterval(0.125),
        ]
        let history = PlanUtilizationSeriesHistory(
            name: "nativeQuota:primary",
            windowMinutes: 300,
            entries: dates
                .map { .init(capturedAt: $0, usedPercent: 25, resetsAt: nil) })
        let widget = NativeOrbitHistoryWidget(histories: [history], now: now)
        let coverage = try widget.coverage(#require(widget.lanes.first))
        #expect(coverage.observationCount == 3)
        #expect(coverage.observedDayCount == 2)
        #expect(coverage.firstObservedAt == start)
        #expect(coverage.lastObservedAt == now)
        #expect(coverage.priorObservedAt == dates.first)
    }

    @Test
    func `compact quota legends retain every model and quota label`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let labels = [
            "nativeQuota:primary": "5-hour limit",
            "nativeQuota:secondary": "Total usage",
            "nativeQuota:claude-weekly-scoped-fable": "Fable only",
        ]
        let windows = Dictionary(uniqueKeysWithValues: labels.keys.map {
            ($0, RateWindow(
                usedPercent: 25,
                windowMinutes: $0 == "nativeQuota:primary" ? 300 : 10080,
                resetsAt: nil,
                resetDescription: nil))
        })
        let histories = labels.keys.map {
            self.history($0, minutes: windows[$0]?.windowMinutes ?? 0, dates: [-3600], now: now)
        }
        let widget = NativeOrbitHistoryWidget(
            histories: histories, now: now, days: 30, quotaLabels: labels, quotaWindows: windows)
        #expect(Set(widget.legendLabels) == Set(labels.values))
    }

    @Test
    func `source archive retains distinct same timestamp measurements across cadence changes`() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000.875)
        let captured = now.addingTimeInterval(-3600.125)
        let first = PlanUtilizationHistoryEntry(
            capturedAt: captured, usedPercent: 20, resetsAt: now.addingTimeInterval(3600.125))
        let changedReset = PlanUtilizationHistoryEntry(
            capturedAt: captured, usedPercent: 20, resetsAt: now.addingTimeInterval(3600.625))
        let changedValue = PlanUtilizationHistoryEntry(
            capturedAt: captured, usedPercent: 35, resetsAt: first.resetsAt)
        let later = PlanUtilizationHistoryEntry(
            capturedAt: now.addingTimeInterval(-1800.125), usedPercent: 40, resetsAt: first.resetsAt)
        let histories: [PlanUtilizationSeriesHistory] = [
            .init(name: "nativeQuota:primary", windowMinutes: 300, entries: [first, first, changedReset]),
            .init(name: "nativeQuota:primary", windowMinutes: 600, entries: [first, changedValue, later]),
        ]
        let archive = NativeOrbitHistoryWidget(
            histories: histories, now: now, days: 30, provider: .codex, preserveSourceConflicts: true)
        let lane = try #require(archive.lanes.first)
        #expect(archive.lanes.count == 1)
        #expect(Set(lane.samples.map(\.id)) == Set([first, changedReset, changedValue, later]))
        #expect(lane.samples.count == 4)
        #expect(lane.history.windowMinutes == 600)
        #expect(archive.coverage(lane).observationCount == 4)
        #expect(archive.coverage(lane).firstObservedAt == captured)
        #expect(archive.coverage(lane).lastObservedAt == later.capturedAt)
        let live = NativeOrbitHistoryWidget(histories: histories, now: now, days: 30, provider: .codex)
        #expect(live.lanes.first?.samples.map(\.id) == [changedValue, later])
    }

    @Test
    func `Claude organization display rename and missing owner preserve isolated recorded histories`() async throws {
        let settings = testSettingsStore(
            suiteName: "NativeOrbitOwnerRetention", userDefaults: InMemoryUserDefaults(), nativeDesignEnabled: true)
        enableTestProviders([.claude], settings: settings)
        settings.claudeSwapEnabled = true
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        store._cancelPlanUtilizationHistoryLoadForTesting()
        let now = Date(timeIntervalSince1970: 1_800_000_000.875)
        let old = self.claudeOwner(email: "owner@example.com", organization: "Original display", at: now, used: 10)
        store.claudeSwapAccountSnapshots = [old]
        await store.recordNativeClaudeSwapHistory([old])
        let oldKey = try #require(UsageStore.nativeOrbitClaudeHistoryKey(old))
        let oldHistory = try #require(store.planUtilizationHistory[.claude]?.accounts[oldKey])
        let renamed = self.claudeOwner(
            email: "owner@example.com", organization: "Renamed display", at: now.addingTimeInterval(60), used: 20)
        store.claudeSwapAccountSnapshots = [renamed]
        await store.recordNativeClaudeSwapHistory([renamed])
        let renamedKey = try #require(UsageStore.nativeOrbitClaudeHistoryKey(renamed))
        let renamedHistory = try #require(store.planUtilizationHistory[.claude]?.accounts[renamedKey])
        #expect(oldKey != renamedKey)
        #expect(store.planUtilizationHistory[.claude]?.accounts[oldKey] == oldHistory)
        #expect(renamedHistory.first?.entries.map(\.capturedAt) == [now.addingTimeInterval(60)])
        #expect(renamedHistory.first?.entries.map(\.usedPercent) == [20])
        let missing = self.claudeOwner(
            email: nil, organization: "Renamed display", at: now.addingTimeInterval(120), used: 90)
        store.claudeSwapAccountSnapshots = [missing]
        await store.recordNativeClaudeSwapHistory([missing])
        #expect(UsageStore.nativeOrbitClaudeHistoryKey(missing) == nil)
        #expect(store.planUtilizationHistory[.claude]?.accounts[oldKey] == oldHistory)
        #expect(store.planUtilizationHistory[.claude]?.accounts[renamedKey] == renamedHistory)
        #expect(store.planUtilizationHistory[.claude]?.unscoped.isEmpty == true)
    }

    @Test
    func `dense polling does not hide an hour of missing measurements`() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let history = self.history(
            "nativeQuota:claude-weekly-scoped-fable",
            minutes: 10080,
            dates: [-4200, -3900, -3600, 0],
            now: now)
        for days in [1, 7, 30] {
            let widget = NativeOrbitHistoryWidget(histories: [history], now: now, days: days)
            let lane = try #require(widget.lanes.first)
            #expect(lane.samples.map(\.segment) == [0, 0, 0, 1])
            #expect(lane.renderSamples.map(\.id) == [history.entries[0], history.entries[2], history.entries[3]])
            #expect(widget.nearest(lane, to: now.addingTimeInterval(-1800)) == nil)
            #expect(lane.renderSamples.allSatisfy { $0.date == $0.id.capturedAt })
        }
    }

    @Test
    func `a reported reset between readings rises only at the reported reset`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let history = PlanUtilizationSeriesHistory(name: "nativeQuota:primary", windowMinutes: 300, entries: [
            .init(
                capturedAt: now.addingTimeInterval(-600),
                usedPercent: 90,
                resetsAt: now.addingTimeInterval(-300)),
            .init(capturedAt: now, usedPercent: 5, resetsAt: now.addingTimeInterval(18000)),
        ])
        let widget = NativeOrbitHistoryWidget(histories: [history], now: now)
        let points = widget.points(history)
        // No slope across the reset: the last reading holds until the reported instant, then the window is full.
        #expect(points.map(\.segment) == [0, 0, 0, 0])
        #expect(points.map(\.date) == [-600, -300, -300, 0].map { now.addingTimeInterval($0) })
        #expect(points.map(\.available) == [10, 10, 100, 95])
    }

    @Test
    func `retained model quota labels survive absent live metadata`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let histories = [
            self.history("nativeQuota:claude-weekly-scoped-fable", minutes: 10080, dates: [-600], now: now),
            self.history("nativeQuota:codex-spark-weekly", minutes: 10080, dates: [-600], now: now),
        ]
        let widget = NativeOrbitHistoryWidget(histories: histories, now: now, days: 30)
        #expect(Set(widget.legendLabels) == Set(["Fable only", "Spark weekly"]))
    }

    @Test
    func `exact measured readings win same time aggregate conflicts in source archives`() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let measured = PlanUtilizationHistoryEntry(capturedAt: now, usedPercent: 20, resetsAt: nil)
        let aggregate = PlanUtilizationHistoryEntry(
            capturedAt: now,
            usedPercent: 10,
            resetsAt: nil,
            historicalPeriod: .init(
                startsAt: now.addingTimeInterval(-86400),
                approximate: true,
                accountingComplete: false))
        let history = PlanUtilizationSeriesHistory(
            name: "nativeQuota:secondary",
            windowMinutes: 10080,
            entries: [aggregate, measured])
        let widget = NativeOrbitHistoryWidget(histories: [history], now: now, preserveSourceConflicts: true)
        let lane = try #require(widget.lanes.first)
        #expect(lane.samples.count == 2)
        #expect(widget.nearest(lane, to: now)?.id == measured)
    }

    private func claudeOwner(email: String?, organization: String, at date: Date, used: Double)
    -> ProviderAccountUsageSnapshot {
        ProviderAccountUsageSnapshot(
            id: .init(source: "claude-swap", opaqueID: "1"),
            provider: .claude,
            displayLabel: email ?? "Unknown",
            accountEmail: email,
            accountOrganizationName: organization,
            isActive: true,
            usesLastKnownUsage: false,
            snapshot: UsageSnapshot(
                primary: RateWindow(usedPercent: used, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                tertiary: nil,
                updatedAt: date),
            error: nil,
            sourceLabel: "fixture")
    }

    @Test
    func `hover follows the drawn curve at the pointer time and does not interpolate a reset`() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let history = PlanUtilizationSeriesHistory(name: "nativeQuota:primary", windowMinutes: 300, entries: [
            .init(capturedAt: now.addingTimeInterval(-600), usedPercent: 20, resetsAt: now.addingTimeInterval(3600)),
            .init(capturedAt: now, usedPercent: 40, resetsAt: now.addingTimeInterval(3600)),
        ])
        let widget = NativeOrbitHistoryWidget(histories: [history], now: now)
        let lane = try #require(widget.lanes.first)
        let selected = now.addingTimeInterval(-300)
        let point = try #require(widget.nearest(lane, to: selected))
        #expect(point.date == selected)
        #expect(point.available == 70)
        #expect(widget.seriesHelp(lane, selectedDate: selected).contains("Interpolated"))
        #expect(!widget.seriesHelp(lane, selectedDate: selected).contains("Observed"))
        #expect(point.id.resetsAt == now.addingTimeInterval(3600))
        #expect(widget.nearest(lane, to: now.addingTimeInterval(-601)) == nil)
        let resetHistory = PlanUtilizationSeriesHistory(name: "nativeQuota:primary", windowMinutes: 300, entries: [
            .init(capturedAt: now.addingTimeInterval(-600), usedPercent: 80, resetsAt: nil),
            .init(capturedAt: now, usedPercent: 10, resetsAt: nil),
        ])
        let resetWidget = NativeOrbitHistoryWidget(histories: [resetHistory], now: now)
        #expect(try resetWidget.nearest(#require(resetWidget.lanes.first), to: selected) == nil)
    }

    @Test
    func `isolated hover snaps only inside the measured point hit target`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let recorded = now.addingTimeInterval(-600)
        let history = self.history("nativeQuota:primary", minutes: 300, dates: [-600], now: now)
        let widget = NativeOrbitHistoryWidget(histories: [history], now: now)
        #expect(widget.inspectionDate(at: recorded.addingTimeInterval(1), plotWidth: 180) == recorded)
        let gap = now.addingTimeInterval(-3600)
        #expect(widget.inspectionDate(at: gap, plotWidth: 180) == gap)
    }

    @Test(arguments: [1, 7, 30])
    func `isolated and period point hit targets retain their pixel width across ranges`(days: Int) throws {
        let now = Date(timeIntervalSince1970: 1_800_043_200)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        let start = now.addingTimeInterval(-Double(days) * 86400)
        let span = now.timeIntervalSince(start)
        let dates = [start.addingTimeInterval(span * 0.4), start.addingTimeInterval(span * 0.7)]
        let names = ["nativeQuota:primary", "nativeQuota:secondary"]
        let histories = dates.enumerated().map { index, date in
            PlanUtilizationSeriesHistory(
                name: .init(rawValue: names[index]),
                windowMinutes: index == 0 ? 300 : 10080,
                entries: [.init(
                    capturedAt: date,
                    usedPercent: 20,
                    resetsAt: nil,
                    historicalPeriod: index == 1 ? .init(
                        startsAt: date.addingTimeInterval(-86400),
                        approximate: true,
                        accountingComplete: false) : nil)])
        }
        let widget = NativeOrbitHistoryWidget(histories: histories, now: now, days: days, calendar: calendar)
        let secondsPerPoint = span / 200
        for (index, date) in dates.enumerated() {
            let lane = try #require(widget.lanes.first { $0.history.name.rawValue == names[index] })
            let inside = date.addingTimeInterval(secondsPerPoint * 2.5)
            #expect(widget.nearest(lane, to: inside) == nil)
            #expect(widget.inspectionDate(at: inside, plotWidth: 200) == date)
            let outside = date.addingTimeInterval(secondsPerPoint * 3.01)
            #expect(widget.inspectionDate(at: outside, plotWidth: 200) == outside)
        }
    }

    private func history(_ name: String, minutes: Int, dates: [TimeInterval], now: Date)
    -> PlanUtilizationSeriesHistory {
        PlanUtilizationSeriesHistory(name: .init(rawValue: name), windowMinutes: minutes, entries: dates.map {
            .init(capturedAt: now.addingTimeInterval($0), usedPercent: 25, resetsAt: nil)
        })
    }
}
