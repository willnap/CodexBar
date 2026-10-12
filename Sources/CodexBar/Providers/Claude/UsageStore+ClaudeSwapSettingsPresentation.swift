import CodexBarCore
import Foundation

extension UsageStore {
    /// A selected adapter owns the complete settings preview, including absent measurements.
    /// This is a cached projection: rendering never reads credentials or refreshes an account.
    func claudeSwapSettingsAccount(for provider: UsageProvider) -> UsageMenuCardContext.Account? {
        guard self.settings.nativeDesignEnabled, provider == .claude,
              self.nativeClaudeSwapOwnsPresentation else { return nil }
        _ = self.claudeSwapRevision
        let active = self.claudeSwapAccountSnapshots.filter {
            $0.provider == .claude && $0.id.source == ClaudeSwapAccountProjection.sourceName && $0.isActive
        }
        guard active.count == 1, let owner = active.first,
              NativeAccountActivationVerification.claudeOwnsLogin(owner.id, accounts: self.claudeSwapAccountSnapshots)
        else {
            return .init(
                error: L("No active account"),
                info: AccountInfo(email: nil, plan: nil),
                sourceLabel: ClaudeSwapAccountProjection.sourceLabel)
        }
        return ClaudeSwapAccountMenuDisplay.cardContext(
            for: owner,
            planLabel: nil,
            adapterError: self.claudeSwapLastError,
            switchError: self.claudeSwapTransientState.lastErrorAccountID == owner.id
                ? self.claudeSwapTransientState.lastError : nil).account
    }
}
