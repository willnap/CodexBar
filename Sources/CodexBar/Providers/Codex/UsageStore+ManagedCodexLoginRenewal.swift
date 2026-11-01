import CodexBarCore
import Foundation

extension UsageStore {
    /// A failed renewal waits this long before the next try, so a broken CLI or network isn't relaunched every refresh.
    static let managedCodexLoginRenewalRetryInterval: TimeInterval = 30 * 60

    /// The account projection for a refresh, re-read when a saved login was renewed so rows carry the new file.
    func codexVisibleAccountProjectionRenewingDueLogins() async -> CodexVisibleAccountProjection {
        let projection = self.freshCodexVisibleAccountProjectionForAccountRefresh()
        guard await self.renewDueManagedCodexLogins(in: projection) else { return projection }
        return self.freshCodexVisibleAccountProjectionForAccountRefresh()
    }

    /// Renews saved Codex logins that aren't the live login before they expire, so their usage keeps updating.
    /// Returns whether any login file changed.
    func renewDueManagedCodexLogins(in projection: CodexVisibleAccountProjection, now: Date = Date()) async -> Bool {
        guard !SettingsStore.isRunningTests else { return false }
        let accountIDs = projection.visibleAccounts.compactMap { account -> UUID? in
            guard !account.isLive, case let .managedAccount(id) = account.selectionSource else { return nil }
            return id
        }
        guard !accountIDs.isEmpty else { return false }
        let store = FileManagedCodexAccountStore()
        let managedHomes = (try? store.loadAccounts().accounts.map {
            URL(fileURLWithPath: $0.managedHomePath, isDirectory: true)
        }) ?? []
        let otherHomes = [CodexHomeScope.ambientHomeURL(env: self.environmentBase)]
            + self.settings.codexProfileHomePaths.map { URL(fileURLWithPath: $0, isDirectory: true) }
            + managedHomes
        let environment = self.environmentBase
        var renewedAny = false
        for id in accountIDs {
            if let last = self.managedCodexLoginRenewalAttempts[id],
               now.timeIntervalSince(last) < Self.managedCodexLoginRenewalRetryInterval
            {
                continue
            }
            let outcome = await ManagedCodexLoginRenewal.renewIfDue(
                accountID: id, store: store, otherHomes: otherHomes, now: now)
            { home in
                try await UsageFetcher(environment: CodexHomeScope.scopedEnvironment(
                    base: environment, codexHome: home.path)).renewCodexLogin()
            }
            switch outcome {
            case .renewed:
                self.managedCodexLoginRenewalAttempts[id] = nil
                renewedAny = true
                self.managedCodexLoginRenewalLog.info("Renewed a saved Codex login")
            case let .failed(message):
                self.managedCodexLoginRenewalAttempts[id] = now
                self.managedCodexLoginRenewalLog.warning(
                    "Saved Codex login renewal failed", metadata: ["error": message])
            case .notDue, .sharedLogin, .notRenewable, .busy:
                continue
            }
        }
        if renewedAny { self.settings.refreshCodexAccountReconciliationAfterManagedAccountsDidChange() }
        return renewedAny
    }

    private var managedCodexLoginRenewalLog: CodexBarLogger {
        CodexBarLog.logger(LogCategories.codexAccounts)
    }
}
