import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

/// A refresh rebuilds every account row each time any account publishes. These cover the pieces that keep a row
/// whose own inputs did not change from paying for its whole history again, and the Claude model lane that must
/// not come and go with a rounded percentage.
@MainActor
struct NativeOrbitRowBuildCacheTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func window(_ used: Double, minutes: Int = 10080) -> RateWindow {
        RateWindow(usedPercent: used, windowMinutes: minutes, resetsAt: nil, resetDescription: nil)
    }

    private func series(
        _ name: String,
        minutes: Int = 10080,
        _ readings: [(age: TimeInterval, used: Double)]) -> PlanUtilizationSeriesHistory
    {
        PlanUtilizationSeriesHistory(
            name: .init(rawValue: name),
            windowMinutes: minutes,
            entries: readings.map {
                .init(capturedAt: self.now.addingTimeInterval(-$0.age), usedPercent: $0.used, resetsAt: nil)
            })
    }

    private func claudeSnapshot(fable: Double, at date: Date? = nil) -> UsageSnapshot {
        UsageSnapshot(
            primary: nil,
            secondary: self.window(40),
            tertiary: nil,
            extraRateWindows: [NamedRateWindow(
                id: "claude-weekly-scoped-fable", title: "Fable only", window: self.window(fable))],
            updatedAt: date ?? self.now)
    }

    // MARK: Civil day validation

    @Test
    func `civil day validation agrees with a strict date formatter`() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        func strict(_ text: String) -> Bool {
            guard text.utf8.count == 10, let parsed = formatter.date(from: text) else { return false }
            return formatter.string(from: parsed) == text
        }
        var candidates = [
            "2024-02-29", "2023-02-29", "2100-02-29", "2000-02-29", "2026-11-10", "2026-13-01", "2026-00-10",
            "2026-11-00", "2026-11-31", "2026-12-31", "2026-1-010", "2026/11/10", "26-11-2010", "abcd-ef-gh",
            "2026-11-1０", "", "2026-11-10 ", " 2026-11-10", "2026-11-10T", "+026-11-10", "2026-04-31",
        ]
        for month in 1...12 {
            for day in 27...32 {
                candidates.append(String(format: "2025-%02d-%02d", month, day))
                candidates.append(String(format: "2028-%02d-%02d", month, day))
            }
        }
        for text in candidates {
            #expect(NativeOrbitUsageObservation.isCivilDay(text) == strict(text), "\(text)")
        }
    }

    // MARK: Claude model lanes

    @Test
    func `a model allowance used within the past week keeps its lane at zero`() {
        let snapshot = self.claudeSnapshot(fable: 0)
        func shows(_ history: [PlanUtilizationSeriesHistory]) -> Bool {
            NativeUsageGaugeProjection.state(
                provider: .claude, snapshot: snapshot, modelLaneHistory: history, now: self.now)
                .resolvedWindows.contains { $0.id == "claude-weekly-scoped-fable" }
        }
        // Never used: hidden, as before.
        #expect(!shows([]))
        #expect(!shows([self.series("nativeQuota:claude-weekly-scoped-fable", [(3600, 0), (60, 0)])]))
        // Used two days ago, reset to zero since: stays.
        #expect(shows([self.series("nativeQuota:claude-weekly-scoped-fable", [(2 * 86400, 17), (60, 0)])]))
        // Last used more than a week ago: gone again.
        #expect(!shows([self.series("nativeQuota:claude-weekly-scoped-fable", [(8 * 86400, 17), (60, 0)])]))
        // Another lane's use says nothing about this one.
        #expect(!shows([self.series("nativeQuota:secondary", [(3600, 60)])]))
    }

    @Test
    func `a model allowance in use always shows and an unmeasured one never does`() {
        let used = NativeUsageGaugeProjection.state(provider: .claude, snapshot: self.claudeSnapshot(fable: 3))
        #expect(used.resolvedWindows.contains { $0.id == "claude-weekly-scoped-fable" })

        let recent = [self.series("nativeQuota:claude-weekly-scoped-fable", [(3600, 9)])]
        let unknown = UsageSnapshot(
            primary: nil,
            secondary: self.window(40),
            tertiary: nil,
            extraRateWindows: [NamedRateWindow(
                id: "claude-weekly-scoped-fable", title: "Fable only", window: self.window(0), usageKnown: false)],
            updatedAt: self.now)
        let gauge = NativeUsageGaugeProjection.state(
            provider: .claude, snapshot: unknown, modelLaneHistory: recent, now: self.now)
        #expect(!gauge.resolvedWindows.contains { $0.id == "claude-weekly-scoped-fable" })
    }

    // MARK: Row caches

    @Test
    func `the remembered history equals a fresh merge and follows every input`() {
        let memo = NativeOrbitAccountsMemo()
        let history = [
            self.series("nativeQuota:secondary", [(7200, 30), (3600, 35)]),
            self.series("nativeQuota:claude-weekly-scoped-fable", [(7200, 10), (3600, 12)]),
        ]
        let snapshot = self.claudeSnapshot(fable: 17)
        func fresh(
            _ history: [PlanUtilizationSeriesHistory], _ snapshot: UsageSnapshot) -> [PlanUtilizationSeriesHistory]
        {
            UsageStore.nativeOrbitHistoryIncludingCurrentSnapshot(history, provider: .claude, snapshot: snapshot)
        }
        func remembered(
            _ history: [PlanUtilizationSeriesHistory], _ snapshot: UsageSnapshot?) -> [PlanUtilizationSeriesHistory]
        {
            memo.historyIncludingCurrentSnapshot(
                provider: .claude, accountID: "a", history: history, snapshot: snapshot)
        }

        let first = remembered(history, snapshot)
        #expect(first == fresh(history, snapshot))
        #expect(first != history)
        // Unchanged inputs are served again.
        #expect(remembered(history, snapshot) == first)

        // A new reading replaces what was remembered.
        let later = self.claudeSnapshot(fable: 21, at: self.now.addingTimeInterval(120))
        #expect(remembered(history, later) == fresh(history, later))
        #expect(remembered(history, later) != first)

        // So does a history that grew, and the earlier reading is not served for it.
        let grown = history + [self.series("nativeQuota:tertiary", [(3600, 4)])]
        #expect(remembered(grown, snapshot) == fresh(grown, snapshot))

        // Without a reading the stored history is returned untouched.
        #expect(remembered(history, nil) == history)
    }

    @Test
    func `remembered histories are kept per account and dropped with it`() {
        let memo = NativeOrbitAccountsMemo()
        let first = [self.series("nativeQuota:secondary", [(7200, 30)])]
        let second = [self.series("nativeQuota:secondary", [(7200, 80)])]
        let snapshot = self.claudeSnapshot(fable: 17)
        func remembered(_ id: String, _ history: [PlanUtilizationSeriesHistory]) -> [PlanUtilizationSeriesHistory] {
            memo.historyIncludingCurrentSnapshot(
                provider: .claude, accountID: id, history: history, snapshot: snapshot)
        }
        let a = remembered("a", first)
        let b = remembered("b", second)
        #expect(a != b)
        #expect(remembered("a", first) == a)
        memo.retainWarningHistories(provider: .claude, accountIDs: ["b"])
        #expect(remembered("a", first) == a)
        #expect(remembered("b", second) == b)
    }

    @Test
    func `remembered consumption dates equal a fresh derivation and follow the history`() {
        let memo = NativeOrbitAccountsMemo()
        // Readings a minute apart share one window; hours apart without a reset time they are not joined.
        let rising = [self.series("nativeQuota:secondary", [(180, 10), (120, 20), (60, 35)])]
        let flat = [self.series("nativeQuota:secondary", [(180, 10), (120, 10)])]
        func remembered(_ history: [PlanUtilizationSeriesHistory]) -> [Date] {
            memo.consumptionDates(provider: .claude, accountID: "a", history: history)
        }
        #expect(remembered(rising) == NativeOrbitActivity.consumptionDates(rising))
        #expect(!remembered(rising).isEmpty)
        #expect(remembered(flat) == NativeOrbitActivity.consumptionDates(flat))
        #expect(remembered(flat).isEmpty)
        #expect(remembered(rising) == NativeOrbitActivity.consumptionDates(rising))
    }

    // MARK: Reading size

    @Test
    func `a history reading stays small enough to copy and sort by the thousand`() throws {
        // Thousands of readings per account are merged, grouped and sorted on every row build, so whatever a
        // reading carries inline is moved each time. Its rarely present payloads live behind references.
        print("stride PlanUtilizationHistoryEntry", MemoryLayout<PlanUtilizationHistoryEntry>.stride)
        #expect(MemoryLayout<PlanUtilizationHistoryEntry>.stride <= 40)
        // The payload still round-trips and compares by value from behind its reference.
        let metrics = NativeOrbitMetricObservation(spendResetReferenceTime: 12)
        let entry = PlanUtilizationHistoryEntry(
            capturedAt: self.now, usedPercent: 3, resetsAt: nil, nativeMetrics: metrics)
        let twin = PlanUtilizationHistoryEntry(
            capturedAt: self.now, usedPercent: 3, resetsAt: nil, nativeMetrics: metrics)
        #expect(entry.nativeMetrics == metrics)
        #expect(entry == twin)
        #expect(entry.hashValue == twin.hashValue)
        #expect(entry != PlanUtilizationHistoryEntry(capturedAt: self.now, usedPercent: 3, resetsAt: nil))
        // A named lane's descriptor and a backfilled period come back from there too, alone or together.
        let descriptor = NativeOrbitQuotaDescriptor(label: "Fable only", windowMinutes: 10080)
        let named = PlanUtilizationHistoryEntry(
            capturedAt: self.now, usedPercent: 3, resetsAt: self.now, quotaDescriptor: descriptor)
        #expect(named.quotaDescriptor == descriptor)
        #expect(named.nativeMetrics == nil)
        #expect(named.historicalPeriod == nil)
        #expect(named == PlanUtilizationHistoryEntry(
            capturedAt: self.now, usedPercent: 3, resetsAt: self.now, quotaDescriptor: descriptor))
        #expect(named != PlanUtilizationHistoryEntry(capturedAt: self.now, usedPercent: 3, resetsAt: self.now))
        let both = PlanUtilizationHistoryEntry(
            capturedAt: self.now, usedPercent: 3, resetsAt: nil, nativeMetrics: metrics, quotaDescriptor: descriptor)
        #expect(both.quotaDescriptor == descriptor)
        #expect(both.nativeMetrics == metrics)
        #expect(both != named)
        let encoded = try JSONEncoder().encode([entry, named, both])
        #expect(try JSONDecoder().decode([PlanUtilizationHistoryEntry].self, from: encoded) == [entry, named, both])
    }
}
