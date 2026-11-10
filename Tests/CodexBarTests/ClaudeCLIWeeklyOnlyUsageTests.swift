import Foundation
import Testing
@testable import CodexBarCore

/// Claude plans without a five-hour cap draw no "Current session" row. The CLI reading must then carry no session
/// window at all, never the first percentage on the panel (the weekly limit) under the session's name.
struct ClaudeCLIWeeklyOnlyUsageTests {
    private static let weeklyOnlyPanel = """
    Settings:  Status   Config   Usage  (tab to cycle)
    Current week (all models)
    ███████▌ 37% used
    Resets Nov 12 at 1:30pm (Europe/London)

    Current week (Sonnet only)
    █▌ 3% used
    Resets Nov 12 at 1:30pm (Europe/London)
    """

    @Test
    func `weekly only panel reports no session instead of mirroring the weekly limit`() throws {
        let snap = try ClaudeStatusProbe.parse(text: Self.weeklyOnlyPanel)
        #expect(snap.sessionPercentLeft == nil)
        #expect(snap.primaryResetDescription == nil)
        #expect(snap.weeklyPercentLeft == 63)
    }

    @Test
    func `weekly only panel maps to a snapshot without a five hour window`() throws {
        let snapshot = try ClaudeUsageFetcher.makeSnapshot(
            from: ClaudeStatusProbe.parse(text: Self.weeklyOnlyPanel))
        #expect(snapshot.primary == nil)
        #expect(snapshot.secondary?.usedPercent == 37)
    }

    @Test
    func `a drawn session row still wins over the weekly row`() throws {
        let snap = try ClaudeStatusProbe.parse(text: """
        Settings:  Status   Config   Usage  (tab to cycle)
        Current session
        ███████▌ 15% used
        Resets 11:30pm (Europe/London)

        Current week (all models)
        █▌ 37% used
        Resets Nov 12 at 1:30pm (Europe/London)
        """)
        #expect(snap.sessionPercentLeft == 85)
        #expect(snap.weeklyPercentLeft == 63)
    }
}
