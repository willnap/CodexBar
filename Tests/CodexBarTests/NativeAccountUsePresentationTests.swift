import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct NativeAccountUsePresentationTests {
    @Test
    func `a single inactive account retains its footer in the normal service popup`() {
        #expect(NativeAccountUsePresentation.showsFooter(accounts: [self.account(canActivate: false)]))
        #expect(!NativeAccountUsePresentation.showsFooter(accounts: [self.account(active: true)]))
        #expect(NativeAccountUsePresentation.showsFooter(accounts: [self.account(active: true)], canSignIn: true))
        #expect(NativeAccountUsePresentation.showsAccountFooter(
            account: self.account(canActivate: false),
            isIndividualColumn: false,
            accountCount: 1))
        #expect(!NativeAccountUsePresentation.showsAccountFooter(
            account: self.account(active: true),
            isIndividualColumn: false,
            accountCount: 1))
        #expect(NativeAccountUsePresentation.showsAccountFooter(
            account: self.account(active: true),
            isIndividualColumn: false,
            accountCount: 2))
        #expect(NativeAccountUsePresentation.showsAccountFooter(
            account: self.account(active: true),
            isIndividualColumn: true,
            accountCount: 1))
    }

    @Test(arguments: [ClaudeSwapUsageStatus.noCredentials, .unknown("fixture")])
    func `unavailable saved logins keep a disabled Use with a specific reason`(status: ClaudeSwapUsageStatus) throws {
        let source = try self.claudeAccount(status: status)
        let shown = NativeAccountUsePresentation.resolve(account: self.account(
            canActivate: source.canActivate, selection: .claudeSwap(source)))
        #expect(shown.showsUse)
        #expect(!shown.isEnabled)
        #expect(!shown.isSwitching)
        #expect(shown.unavailableReason == (status == .noCredentials ? .noSavedLogin : .unrecognizedStatus))
        #expect(!shown.help(loginTarget: "Claude Code").isEmpty)
    }

    @Test(arguments: [ClaudeSwapUsageStatus.ok, .noCredentials, .unknown("fixture")])
    func `read only capability explains the blocked action before account authentication`(
        status: ClaudeSwapUsageStatus) throws
    {
        let source = try self.claudeAccount(status: status, supportsSwitching: false)
        #expect(source.activationUnavailableReason == .readOnlySource)
        let shown = NativeAccountUsePresentation.resolve(account: self.account(
            canActivate: source.canActivate, selection: .claudeSwap(source)))
        #expect(shown.showsUse)
        #expect(!shown.isEnabled)
        #expect(shown.unavailableReason == .readOnlySource)
        #expect(shown.help(loginTarget: "Claude Code") == L("native_account_use_read_only"))
    }

    @Test
    func `monitoring sources have no login switch control`() {
        for selection in [NativeOrbitAccountSelection.none, .token(nil)] {
            let shown = NativeAccountUsePresentation.resolve(account: self.account(
                canActivate: false, selection: selection))
            #expect(!shown.showsUse)
            #expect(!shown.isEnabled)
            #expect(shown.unavailableReason == nil)
        }
    }

    @Test
    func `another switch disables Use and the current switch keeps its spinner`() {
        let account = self.account()
        let waiting = NativeAccountUsePresentation.resolve(account: account, inFlightID: "other")
        #expect(waiting.showsUse && !waiting.isEnabled && !waiting.isSwitching)
        #expect(waiting.unavailableReason == .busy)
        #expect(waiting.help(loginTarget: "Claude Code") == L("native_account_use_busy"))
        let running = NativeAccountUsePresentation.resolve(account: account, inFlightID: account.id)
        #expect(running.showsUse && !running.isEnabled && running.isSwitching)
        #expect(running.help(loginTarget: "Claude Code") == L("Switching account…"))
    }

    @Test
    func `setup restrictions disable an otherwise usable account with the exact explanation`() {
        let reason = "Switching needs a Claude Code login without token or profile environment overrides."
        let shown = NativeAccountUsePresentation.resolve(account: self.account(), switchingUnavailable: reason)
        #expect(shown.showsUse && !shown.isEnabled)
        #expect(shown.help(loginTarget: "Claude Code") == reason)
    }

    @Test
    func `waiting for a switch controller is visible and cannot trigger activation`() {
        let shown = NativeAccountUsePresentation.resolve(account: self.account(), controllerAvailable: false)
        #expect(shown.showsUse && !shown.isEnabled)
        #expect(shown.unavailableReason == .notReady)
    }

    @Test
    func `available accounts stay usable and the active account keeps its Active badge`() {
        let available = NativeAccountUsePresentation.resolve(account: self.account())
        #expect(available.showsUse && available.isEnabled)
        #expect(available.unavailableReason == nil)
        #expect(available.help(loginTarget: "Claude Code") == L("Use in %@", "Claude Code"))
        let active = NativeAccountUsePresentation.resolve(account: self.account(active: true, canActivate: false))
        #expect(!active.showsUse && !active.isEnabled)
        #expect(active.help(loginTarget: "Claude Code") == L("Active %@ account", "Claude Code"))
    }

    @Test
    func `a changed unavailability reason invalidates an otherwise identical popup row`() throws {
        let missing = try self.claudeAccount(status: .noCredentials)
        let readOnly = try self.claudeAccount(status: .noCredentials, supportsSwitching: false)
        let before = self.account(canActivate: false, selection: .claudeSwap(missing))
        let after = self.account(canActivate: false, selection: .claudeSwap(readOnly))
        #expect(before != after)
        let state = NativeOrbitPopupState()
        state.accounts = [before]
        state.accounts = [after]
        let retained = try #require(state.accounts.first)
        #expect(NativeAccountUsePresentation.resolve(account: retained).unavailableReason == .readOnlySource)
    }

    private func claudeAccount(
        status: ClaudeSwapUsageStatus,
        supportsSwitching: Bool = true) throws -> ProviderAccountUsageSnapshot
    {
        try #require(ClaudeSwapAccountProjection.accountSnapshots(from: .init(
            activeAccountNumber: nil,
            accounts: [.init(
                number: 2,
                email: "fixture@example.test",
                isActive: false,
                usageStatus: status,
                fiveHour: nil,
                sevenDay: nil)],
            supportsAccountSwitching: supportsSwitching)).first)
    }

    private func account(
        active: Bool = false,
        canActivate: Bool = true,
        selection: NativeOrbitAccountSelection? = nil) -> NativeOrbitAccountPresentation
    {
        NativeOrbitAccountPresentation(
            id: "fixture",
            label: "Account 2",
            email: nil,
            symbol: "person",
            isActive: active,
            canActivate: canActivate,
            gauge: .init(),
            updatedAt: nil,
            history: [],
            odometer: nil,
            odometerHelp: nil,
            statusText: nil,
            selection: selection ?? .codex(CodexVisibleAccount(
                id: "fixture",
                email: "fixture@example.test",
                storedAccountID: nil,
                selectionSource: .liveSystem,
                isActive: false,
                isLive: false,
                canReauthenticate: false,
                canRemove: false)))
    }
}
