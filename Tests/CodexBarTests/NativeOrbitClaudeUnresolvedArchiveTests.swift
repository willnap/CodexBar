import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct NativeOrbitClaudeUnresolvedArchiveTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000.875)

    @Test func `Claude archive retains file readings while persisted history is unloaded`() {
        let source = self.history("nativeQuota:primary", minutes: 300, entries: [self.entry(used: 25)])
        let archive = NativeOrbitClaudeLocalArchive.mergedHistories(
            fileHistories: [source], buckets: nil, excludingOwnerKeys: ["current"])
        #expect(archive == [source])
        #expect(NativeOrbitClaudeLocalArchive.mergedHistories(
            fileHistories: [], buckets: nil, excludingOwnerKeys: []).isEmpty)
    }

    @Test func `Claude archive excludes current native owners without guessing opaque or preferred identity`() throws {
        let nativeKeys = try Set(["one@example.com", "two@example.com"].enumerated().map { index, email in
            try #require(UsageStore.nativeOrbitClaudeHistoryKey(self.account(slot: index, email: email)))
        })
        let current = self.entry(used: 90)
        let unresolved = self.entry(used: 17)
        let unscoped = self.entry(used: 21)
        var buckets = PlanUtilizationHistoryBuckets(preferredAccountKey: "opaque-preferred")
        for key in nativeKeys {
            buckets.accounts[key] = [self.history("nativeQuota:primary", minutes: 300, entries: [current])]
        }
        buckets.accounts["opaque-preferred"] = [
            self.history("nativeQuota:claude-weekly-scoped-fable", minutes: 10080, entries: [unresolved]),
        ]
        buckets.unscoped = [self.history("weekly", minutes: 10080, entries: [unscoped])]
        let original = buckets
        let archive = NativeOrbitClaudeLocalArchive.mergedHistories(
            fileHistories: [], buckets: buckets, excludingOwnerKeys: nativeKeys)
        #expect(Set(archive.flatMap(\.entries)) == Set([unresolved, unscoped]))
        #expect(!archive.flatMap(\.entries).contains(current))
        #expect(archive.contains { $0.name.rawValue == "nativeQuota:claude-weekly-scoped-fable" })
        #expect(buckets == original)
        #expect(NativeOrbitClaudeLocalArchive.quotaLabels["nativeQuota:claude-weekly-scoped-fable"] == "Fable only")
        #expect(NativeOrbitClaudeLocalArchive.quotaLabels["opus"] == nil)
    }

    @Test func `Claude file and unresolved archive retains conflicts and cadence fragments with exact dedup`() {
        let first = self.entry(used: 10)
        let value = self.entry(used: 125)
        let reset = PlanUtilizationHistoryEntry(
            capturedAt: first.capturedAt, usedPercent: first.usedPercent, resetsAt: self.now.addingTimeInterval(0.5))
        let later = PlanUtilizationHistoryEntry(
            capturedAt: self.now.addingTimeInterval(-30.125), usedPercent: 30, resetsAt: self.now)
        var buckets = PlanUtilizationHistoryBuckets()
        buckets.unscoped = [self.history("nativeQuota:primary", minutes: 300, entries: [first, value, reset])]
        buckets.accounts["unknown"] = [self.history("nativeQuota:primary", minutes: 600, entries: [first, later])]
        let archive = NativeOrbitClaudeLocalArchive.mergedHistories(
            fileHistories: [self.history("nativeQuota:primary", minutes: 300, entries: [first, first])],
            buckets: buckets,
            excludingOwnerKeys: [])
        #expect(archive.count == 2)
        #expect(archive.first { $0.windowMinutes == 300 }?.entries.count == 3)
        #expect(Set(archive.flatMap(\.entries)) == Set([first, value, reset, later]))
        let widget = NativeOrbitHistoryWidget(
            histories: archive, now: self.now, days: 30, provider: .claude, preserveSourceConflicts: true)
        #expect(widget.lanes.count == 1)
        #expect(widget.lanes.first.map { widget.coverage($0).observationCount } == 4)
    }

    @Test func `Claude archive projection cannot leak file or stored observations into another provider`() {
        let source = self.history("nativeQuota:primary", minutes: 300, entries: [self.entry(used: 25)])
        let buckets = PlanUtilizationHistoryBuckets(unscoped: [source])
        for provider in [UsageProvider.codex, .kimi] {
            #expect(NativeOrbitClaudeLocalArchive.mergedHistories(
                fileHistories: [source], buckets: buckets, excludingOwnerKeys: [], provider: provider).isEmpty)
        }
    }

    private func account(slot: Int, email: String) -> ProviderAccountUsageSnapshot {
        .init(
            id: .init(source: "claude-swap", opaqueID: String(slot)),
            provider: .claude,
            displayLabel: email,
            accountEmail: email,
            accountOrganizationName: "Fixture",
            isActive: slot == 0,
            usesLastKnownUsage: false,
            snapshot: nil,
            error: nil,
            sourceLabel: "fixture")
    }

    private func entry(used: Double) -> PlanUtilizationHistoryEntry {
        .init(capturedAt: self.now.addingTimeInterval(-60.125), usedPercent: used, resetsAt: self.now)
    }

    private func history(_ name: String, minutes: Int, entries: [PlanUtilizationHistoryEntry])
    -> PlanUtilizationSeriesHistory {
        .init(name: .init(rawValue: name), windowMinutes: minutes, entries: entries)
    }
}
