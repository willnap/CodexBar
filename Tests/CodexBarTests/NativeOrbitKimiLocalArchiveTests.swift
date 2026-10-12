import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct NativeOrbitKimiLocalArchiveTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000.875)

    @Test
    func `Kimi archive retains unresolved owners and unscoped readings excluding only accepted principal`() throws {
        let snapshot = try self.acceptedSnapshot()
        let key = try #require(UsageStore.nativeKimiHistoryAccountKey(snapshot))
        let first = self.entry(seconds: -86400.125, used: 10)
        let second = self.entry(seconds: -3600.25, used: 20)
        let unscoped = self.entry(seconds: -1800.375, used: 30)
        let current = self.entry(seconds: -60.5, used: 40)
        var buckets = PlanUtilizationHistoryBuckets(preferredAccountKey: "unresolved-first")
        buckets.accounts[key] = [self.history("nativeQuota:primary", minutes: 10080, entries: [current])]
        buckets.accounts["unresolved-first"] = [self.history("nativeQuota:primary", minutes: 10080, entries: [first])]
        buckets.accounts["unresolved-second"] = [self.history("nativeQuota:primary", minutes: 10080, entries: [second])]
        buckets.unscoped = [self.history("session", minutes: 300, entries: [unscoped])]
        let original = buckets
        let archive = NativeOrbitKimiLocalArchive.histories(buckets, excludingAcceptedOwnerKey: key)
        #expect(Set(archive.flatMap(\.entries)) == Set([first, second, unscoped]))
        #expect(archive.first { $0.name == "nativeQuota:primary" }?.entries == [first, second])
        #expect(archive.first { $0.name == .session }?.entries == [unscoped])
        #expect(buckets == original)
        #expect(!archive.flatMap(\.entries).contains(current))
    }

    @Test func `Kimi archive never treats preferred history as verified identity`() {
        let first = self.entry(seconds: -3600.125, used: 17)
        let second = self.entry(seconds: -1800.25, used: 23)
        var buckets = PlanUtilizationHistoryBuckets(preferredAccountKey: "old-preferred")
        buckets.accounts["old-preferred"] = [self.history("weekly", minutes: 10080, entries: [first])]
        buckets.unscoped = [self.history("nativeQuota:kimi-monthly", minutes: 43200, entries: [second])]
        let archive = NativeOrbitKimiLocalArchive.histories(buckets, excludingAcceptedOwnerKey: nil)
        #expect(Set(archive.flatMap(\.entries)) == Set([first, second]))
        #expect(NativeOrbitKimiLocalArchive.histories(.init(), excludingAcceptedOwnerKey: nil).isEmpty)
    }

    @Test
    func `Kimi archive preserves exact timestamp conflicts and cadence fragments without duplicate source copies`() {
        let first = self.entry(seconds: -3600.125, used: 10)
        let valueConflict = self.entry(seconds: -3600.125, used: 125)
        let resetConflict = PlanUtilizationHistoryEntry(
            capturedAt: first.capturedAt, usedPercent: 10, resetsAt: first.resetsAt?.addingTimeInterval(0.5))
        let later = self.entry(seconds: -1800.25, used: 30)
        var buckets = PlanUtilizationHistoryBuckets()
        buckets.accounts["unresolved-first"] = [
            self.history("nativeQuota:secondary", minutes: 300, entries: [first, valueConflict, first]),
        ]
        buckets.accounts["unresolved-second"] = [
            self.history("nativeQuota:secondary", minutes: 300, entries: [first, resetConflict]),
        ]
        buckets.unscoped = [self.history("nativeQuota:secondary", minutes: 600, entries: [first, later])]
        let archive = NativeOrbitKimiLocalArchive.histories(buckets, excludingAcceptedOwnerKey: nil)
        #expect(archive.count == 2)
        #expect(Set(archive.first { $0.windowMinutes == 300 }?.entries ?? []) ==
            Set([first, valueConflict, resetConflict]))
        #expect(archive.first { $0.windowMinutes == 300 }?.entries.count == 3)
        #expect(archive.first { $0.windowMinutes == 600 }?.entries == [first, later])
        let widget = NativeOrbitHistoryWidget(
            histories: archive, now: self.now, days: 30, provider: .kimi, preserveSourceConflicts: true)
        #expect(widget.lanes.count == 1)
        #expect(Set(widget.lanes.first?.samples.map(\.id) ?? []) == Set([first, valueConflict, resetConflict, later]))
        #expect(widget.lanes.first.map { widget.coverage($0).observationCount } == 4)
    }

    @Test func `Kimi archive quota names identify every known gauge`() {
        #expect(NativeOrbitKimiLocalArchive.quotaLabels == [
            "nativeQuota:primary": "7-day usage",
            "nativeQuota:secondary": "5-hour usage",
            "nativeQuota:kimi-monthly": "Total usage",
            "nativeQuota:kimi-code-7d": "Code 7-day",
        ])
        let history = self.history("nativeQuota:primary", minutes: 10080, entries: [self.entry(seconds: -60, used: 10)])
        let archive = NativeOrbitHistoryWidget(
            histories: [history],
            now: self.now,
            quotaLabels: NativeOrbitKimiLocalArchive.quotaLabels,
            provider: .kimi,
            preserveSourceConflicts: true)
        #expect(archive.legendLabels == ["7-day usage"])
    }

    private func acceptedSnapshot() throws -> UsageSnapshot {
        let owner = try #require(KimiUsageFetcher.historyOwnerID(
            endpoint: KimiRegion.china.apiBaseURL, credential: "synthetic-accepted-credential"))
        return UsageSnapshot(
            primary: RateWindow(usedPercent: 25, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: self.now,
            identity: ProviderIdentitySnapshot(
                providerID: .kimi, accountEmail: nil, accountOrganization: nil, loginMethod: nil, accountID: owner))
    }

    private func entry(seconds: TimeInterval, used: Double) -> PlanUtilizationHistoryEntry {
        .init(capturedAt: self.now.addingTimeInterval(seconds), usedPercent: used, resetsAt: self.now)
    }

    private func history(_ name: String, minutes: Int, entries: [PlanUtilizationHistoryEntry])
    -> PlanUtilizationSeriesHistory {
        .init(name: .init(rawValue: name), windowMinutes: minutes, entries: entries)
    }
}
