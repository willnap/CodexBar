import Foundation
import Testing
@testable import CodexBarCore

/// Every provider's resets are read through one form; these cover what each payload becomes in it.
struct ProviderResetInventoryTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func date(_ days: Double) -> Date {
        self.now.addingTimeInterval(days * 86400)
    }

    @Test
    func `Claude grants say what each reset clears`() {
        let credits = ClaudeRateLimitResetCreditsSnapshot(
            expirations: [self.date(30)],
            updatedAt: self.now,
            usedExpirations: [self.date(120)],
            grants: [
                .init(
                    startsAt: self.date(-1),
                    expiresAt: self.date(30),
                    left: 1,
                    used: 0,
                    clears: ["seven_day", "seven_day_overage_included"],
                    label: "One full limit reset"),
                .init(
                    expiresAt: self.date(120),
                    left: 0,
                    used: 1,
                    clears: ["seven_day_overage_included"],
                    givesBackWeekly: true),
            ])
        let inventory = ProviderResetInventory(
            credits,
            extraWindowIDs: ["claude-weekly-scoped-fable", "claude-routines"])
        let banked = inventory.available(at: self.now)
        #expect(banked.count == 1)
        #expect(banked[0].scope == .windows(["secondary", "claude-weekly-scoped-fable"]))
        #expect(banked[0].label == "One full limit reset")
        #expect(banked[0].grantedAt == self.date(-1))
        #expect(!banked[0].givesBackWiderUsage)
        // The used one has no time of use: it counts for as long as its grant runs.
        let used = inventory.used(at: self.now)
        #expect(used.count == 1)
        #expect(used[0].scope == .windows(["claude-weekly-scoped-fable"]))
        #expect(used[0].givesBackWiderUsage)
        #expect(inventory.used(at: self.date(121)).isEmpty)
        // No model lane on the snapshot: the scoped key still names a part, not everything.
        #expect(ProviderResetInventory.claudeScope(["seven_day_overage_included"], scopedWindowIDs: [])
            == .windows(["claude-weekly-scoped"]))
        #expect(ProviderResetInventory.claudeScope(["five_hour", "seven_day"], scopedWindowIDs: [])
            == .windows(["primary", "secondary"]))
        #expect(ProviderResetInventory.claudeScope(nil, scopedWindowIDs: []) == .everything)
    }

    @Test
    func `a Claude inventory without grant detail keeps its counts and ends`() {
        let credits = ClaudeRateLimitResetCreditsSnapshot(
            expirations: [self.date(30), nil], updatedAt: self.now, usedExpirations: [self.date(10)])
        let inventory = ProviderResetInventory(credits, extraWindowIDs: [])
        #expect(inventory.available(at: self.now).map(\.expiresAt) == [self.date(30), nil])
        #expect(inventory.available(at: self.now).allSatisfy { $0.scope == .everything })
        #expect(inventory.used(at: self.now).count == 1)
        #expect(inventory.available(at: self.date(31)).count == 1)
    }

    @Test
    func `a used reset with a time counts for a day and Grok resets are plain`() {
        let inventory = ProviderResetInventory(
            resets: [
                ProviderReset(isAvailable: false, expiresAt: nil, usedAt: self.date(-0.5)),
                ProviderReset(isAvailable: false, expiresAt: nil, usedAt: self.date(-2)),
                ProviderReset(isAvailable: true, expiresAt: self.date(3), label: "  "),
            ],
            updatedAt: self.now)
        #expect(inventory.used(at: self.now).count == 1)
        #expect(inventory.available(at: self.now).first?.label == nil)
        let grok = ProviderResetInventory(GrokRateLimitResetCreditsSnapshot(
            expirations: [self.date(5), self.date(2)], updatedAt: self.now))
        #expect(grok.available(at: self.now).map(\.expiresAt) == [self.date(2), self.date(5)])
        #expect(grok.used(at: self.now).isEmpty)
    }

    @Test
    func `the snapshot gives one inventory whichever field carried it`() {
        let shared = ProviderResetInventory(
            resets: [ProviderReset(isAvailable: true, expiresAt: nil, scope: .windows(["primary"]))],
            updatedAt: self.now)
        let plugin = UsageSnapshot(primary: nil, secondary: nil, providerResets: shared, updatedAt: self.now)
        #expect(plugin.resetInventory(for: .kimi) == shared)
        let claude = UsageSnapshot(
            primary: nil,
            secondary: nil,
            claudeResetCredits: .init(expirations: [nil], updatedAt: self.now),
            updatedAt: self.now)
        #expect(claude.resetInventory(for: .claude)?.available(at: self.now).count == 1)
        // Another provider's payload is never read as this provider's resets.
        #expect(claude.resetInventory(for: .kimi) == nil)
        #expect(UsageSnapshot(primary: nil, secondary: nil, updatedAt: self.now).resetInventory(for: .claude) == nil)
    }
}
