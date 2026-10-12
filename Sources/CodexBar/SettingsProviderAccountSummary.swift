import CodexBarCore
import Foundation

extension UsageStore {
    /// Account text for settings search and rows. This accessor must stay entirely in memory.
    func settingsAccountLabel(for provider: UsageProvider) -> String? {
        guard !self.settings.hidePersonalInfo,
              self.settings.isProviderEnabled(provider: provider, metadata: self.metadata(for: provider))
        else { return nil }
        let label: String?
        // Provider-specific by design: ClaudeSwap and Codex have verified account inventories with separate owners.
        if provider == .claude, self.nativeClaudeSwapOwnsPresentation {
            label = self.nativeClaudeSwapDisplay().displayedAccount?.displayLabel
        } else if let account = self.settings.effectiveSelectedTokenAccount(for: provider) {
            label = account.label
        } else if provider == .codex,
                  self.settings.codexUsageDataSource != .pat,
                  self.lastSourceLabels[.codex] != CodexUsageDataSource.pat.sourceLabel
        {
            // Pending reconciliation has no safe identity. Never borrow the previous ambient account.
            let projection = self.nativeCodexAccountProjection
            let accounts = projection?.visibleAccounts.filter { account in
                if self.settings.usesNativeGauges {
                    return account.isLive && account.id == projection?.liveVisibleAccountID
                }
                return account.id == projection?.activeVisibleAccountID
            } ?? []
            label = accounts.count == 1 ? accounts[0].displayName : nil
        } else {
            label = self.snapshot(for: provider.instanceID)?.accountEmail(for: provider)
        }
        guard let label = label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty else { return nil }
        return label
    }
}
