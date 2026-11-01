import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct ClaudeSwapLoginContinuityTests {
    @Test(arguments: [ClaudeSwapUsageStatus.tokenExpired, .reloginRequired, .keychainUnavailable])
    func `saved inactive accounts retain their explicit switch action while usage authentication recovers`(
        status: ClaudeSwapUsageStatus) throws
    {
        let row = ClaudeSwapAccountRow(
            number: 2,
            email: "saved@example.test",
            isActive: false,
            usageStatus: status,
            fiveHour: nil,
            sevenDay: nil)
        let account = try #require(ClaudeSwapAccountProjection.accountSnapshots(from: .init(
            activeAccountNumber: 1, accounts: [row])).first)
        #expect(account.canActivate)
        #expect(ClaudeSwapAccountMenuDisplay.activatesAccount(account))
        #expect(ClaudeSwapAccountMenuDisplay.actionLabel(
            for: account, switchingAccountID: nil, switchInFlight: false, switchPhase: nil) != nil)
        #expect(account.error != nil)
        #expect(!account.autoSwitchEligible)
        if status == .tokenExpired {
            #expect(account.condition == .usageUnavailable)
            #expect(account.credentialIssue == nil)
        } else {
            #expect(account.condition == .credentialProblem)
            #expect(account.credentialIssue != nil)
        }
        let readOnly = ClaudeSwapAccountProjection.accountSnapshots(from: .init(
            activeAccountNumber: 1, accounts: [row], supportsAccountSwitching: false))
        #expect(readOnly.first?.canActivate == false)
    }
}
