import Foundation

/// Keeps a saved (managed) Codex login signed in while another account is the live login.
///
/// A managed home that is not the live login is read by nothing but CodexBar, so its refresh token would otherwise
/// sit unredeemed until the access token lapses and the account reads as signed out. Renewal goes through the Codex
/// CLI (`account/read` with `refreshToken`), which owns the auth.json format and writes the rotated login itself.
/// OpenAI refresh tokens rotate, and redeeming a stale copy can revoke the whole login, so a home is renewed only
/// when no other known home holds the same token or an equally new copy of the same account.
public enum ManagedCodexLoginRenewal {
    public enum Outcome: Equatable, Sendable {
        case renewed
        case notDue
        /// The live login or another home holds this login; its own owner keeps it current.
        case sharedLogin
        /// A plain API key or a token-less file has nothing to renew.
        case notRenewable
        /// Another account writer holds the lock; try again on a later refresh.
        case busy
        case failed(String)
    }

    /// Renew this long before the access token lapses, so sleep or a quit app doesn't let it expire first.
    public static let renewalLeadTime: TimeInterval = 24 * 60 * 60
    /// Without a readable expiry, follow the Codex CLI's own renewal age.
    public static let renewalAge: TimeInterval = 8 * 24 * 60 * 60

    public static func isDue(_ credentials: CodexOAuthCredentials, now: Date) -> Bool {
        guard !credentials.isAPIKey, !credentials.refreshToken.isEmpty else { return false }
        if let expiresAt = credentials.expiresAt {
            return expiresAt.timeIntervalSince(now) <= self.renewalLeadTime
        }
        guard let lastRefresh = credentials.lastRefresh else { return true }
        return now.timeIntervalSince(lastRefresh) >= self.renewalAge
    }

    /// - Parameters:
    ///   - accountID: The managed account whose saved home to renew.
    ///   - otherHomes: Every other home whose login could share this one's refresh chain: the live home, profile
    ///     homes, and the other managed homes.
    ///   - renew: Runs the owner CLI against the given home.
    @MainActor
    public static func renewIfDue(
        accountID: UUID,
        store: any ManagedCodexAccountStoring,
        otherHomes: [URL],
        now: Date = Date(),
        renew: @escaping @Sendable (URL) async throws -> Void) async -> Outcome
    {
        do {
            return try await ManagedCodexAccountLock.withLock(at: store.lockURL) {
                try await self.renewLocked(
                    accountID: accountID, store: store, otherHomes: otherHomes, now: now, renew: renew)
            }
        } catch ManagedCodexAccountLockError.busy {
            return .busy
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    @MainActor
    private static func renewLocked(
        accountID: UUID,
        store: any ManagedCodexAccountStoring,
        otherHomes: [URL],
        now: Date,
        renew: @escaping @Sendable (URL) async throws -> Void) async throws -> Outcome
    {
        guard let account = try store.loadAccounts().account(id: accountID) else { return .notRenewable }
        let home = URL(fileURLWithPath: account.managedHomePath, isDirectory: true)
        guard let before = self.credentials(home: home) else { return .notRenewable }
        guard !before.isAPIKey, !before.refreshToken.isEmpty else { return .notRenewable }
        guard self.isDue(before, now: now) else { return .notDue }
        let ownPath = home.standardizedFileURL.path
        for other in otherHomes where other.standardizedFileURL.path != ownPath {
            guard let shared = self.credentials(home: other), !shared.isAPIKey else { continue }
            if shared.refreshToken == before.refreshToken { return .sharedLogin }
            // An equally new or newer copy of the account elsewhere may have rotated this token already.
            if let accountID = before.accountId, shared.accountId == accountID,
               self.issuedAt(shared) >= self.issuedAt(before)
            {
                return .sharedLogin
            }
        }

        do {
            try await renew(home)
        } catch {
            return .failed(error.localizedDescription)
        }

        guard let after = self.credentials(home: home), !after.isAPIKey else {
            return .failed("The renewed Codex login could not be read back.")
        }
        guard after.refreshToken != before.refreshToken || after.accessToken != before.accessToken else {
            return .failed("The Codex CLI did not renew the login.")
        }
        guard after.accountId == before.accountId else {
            return .failed("The renewed Codex login belongs to a different account.")
        }
        // Keep the registry's fingerprint on the file it describes, as promotion and reauthentication do.
        let latest = try store.loadAccounts()
        guard let current = latest.account(id: accountID), current.managedHomePath == account.managedHomePath
        else { return .renewed }
        let renewed = ManagedCodexAccount(
            id: current.id,
            email: current.email,
            providerAccountID: current.providerAccountID,
            workspaceLabel: current.workspaceLabel,
            workspaceAccountID: current.workspaceAccountID,
            authFingerprint: CodexAuthFingerprint.fingerprint(homePath: current.managedHomePath),
            managedHomePath: current.managedHomePath,
            createdAt: current.createdAt,
            updatedAt: now.timeIntervalSince1970,
            lastAuthenticatedAt: current.lastAuthenticatedAt)
        try FileManagedCodexAccountStore.$mutation.withValue(.loginRenewal) {
            try store.storeAccounts(ManagedCodexAccountSet(
                version: latest.version,
                accounts: latest.accounts.map { $0.id == accountID ? renewed : $0 }))
        }
        return .renewed
    }

    private static func issuedAt(_ credentials: CodexOAuthCredentials) -> Date {
        credentials.expiresAt ?? credentials.lastRefresh ?? .distantPast
    }

    private static func credentials(home: URL) -> CodexOAuthCredentials? {
        let url = CodexAuthFingerprint.authFileURL(homePath: home.path)
        guard CodexCredentialFileAccess.fileExists(at: url),
              let data = try? CodexCredentialFileAccess.read(at: url)
        else { return nil }
        return try? CodexOAuthCredentialsStore.parse(data: data)
    }
}
