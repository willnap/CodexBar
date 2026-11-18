import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

/// Every Claude switch (popup, Settings, menu) goes through the store, so the store is what moves the desktop app.
@MainActor
struct ClaudeSwapSwitchDesktopFollowTests {
    @Test
    func `a switch moves the desktop app from the outgoing account to the incoming one before reconciling`()
        async throws
    {
        try await self.withFixture { fixture in
            var calls: [[String?]] = []
            fixture.store._test_claudeDesktopFollowOverride = { outgoing, incoming in
                calls.append([outgoing, incoming])
                return .restored
            }
            let task = try fixture.startSwitch()
            try await fixture.waitUntil { fixture.listEntered(1) }
            // Already followed: nothing claude-swap's list reports afterwards can skip it.
            #expect(calls == [["synthetic-1@example.invalid", "synthetic-2@example.invalid"]])
            try fixture.releaseList(1)
            await task.value
            #expect(fixture.store.claudeSwapTransientState.lastError == nil)
            #expect(fixture.activeSlots == ["2"])
            try await fixture.waitUntil { fixture.ambientGate.entered }
            try await fixture.finishAmbientRefresh()
        }
    }

    @Test
    func `a failed claude-swap switch leaves the desktop app alone`() async throws {
        try await self.withFixture(failure: .switchFailure) { fixture in
            var calls = 0
            fixture.store._test_claudeDesktopFollowOverride = { _, _ in
                calls += 1
                return .restored
            }
            let task = try fixture.startSwitch()
            try await fixture.waitUntil { fixture.listEntered(1) }
            try fixture.releaseList(1)
            await task.value
            #expect(calls == 0)
            #expect(fixture.store.claudeSwapTransientState.lastError?.contains("credentials missing") == true)
            try await fixture.waitUntil { fixture.ambientGate.entered }
            try await fixture.finishAmbientRefresh()
        }
    }

    @Test(arguments: [
        (
            NativeClaudeDesktopHandoff.Outcome.failed("Claude didn’t quit, so it stayed on its account."),
            "Switched Claude Code. Claude didn’t quit, so it stayed on its account."),
        (.leftOpen, "Switched Claude Code. Claude was open, so it stayed on its account."),
    ])
    func `a desktop app that did not follow says why on the switched account`(
        outcome: NativeClaudeDesktopHandoff.Outcome,
        reason: String) async throws
    {
        try await self.withFixture { fixture in
            fixture.store._test_claudeDesktopFollowOverride = { _, _ in outcome }
            let task = try fixture.startSwitch()
            try await fixture.waitUntil { fixture.listEntered(1) }
            try fixture.releaseList(1)
            await task.value
            #expect(fixture.store.claudeSwapTransientState.lastError == reason)
            #expect(fixture.store.claudeSwapTransientState.lastErrorAccountID == fixture.targetID)
            // Claude Code did switch.
            #expect(fixture.activeSlots == ["2"])
            let section = ClaudeAccountsSectionState.make(store: fixture.store, settings: fixture.settings)
            #expect(section.switchError == reason)
            try await fixture.waitUntil { fixture.ambientGate.entered }
            try await fixture.finishAmbientRefresh()
        }
    }

    @Test
    func `only an app left on the old account is reported`() {
        #expect(NativeClaudeDesktopHandoff.unfollowedReason(.restored) == nil)
        #expect(NativeClaudeDesktopHandoff.unfollowedReason(.signedOut) == nil)
        #expect(NativeClaudeDesktopHandoff.unfollowedReason(.notApplicable) == nil)
        #expect(NativeClaudeDesktopHandoff.unfollowedReason(.leftOpen) != nil)
    }

    private nonisolated func withFixture(
        failure: ClaudeSwapReconciliationFailure = .none,
        _ body: @MainActor @Sendable (ClaudeSwapReconciliationFixture) async throws -> Void) async throws
    {
        let fixture = try await MainActor.run { try ClaudeSwapReconciliationFixture(failure: failure) }
        let credentialsURL = await MainActor.run {
            fixture.navigation.files.root.appendingPathComponent("missing-claude-credentials.json")
        }
        do {
            try await ClaudeOAuthCredentialsStore.withIsolatedCredentialsFileTrackingForTesting {
                try await ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(credentialsURL) {
                    try await body(fixture)
                }
            }
        } catch {
            await fixture.cleanup()
            throw error
        }
        await fixture.cleanup()
    }
}
