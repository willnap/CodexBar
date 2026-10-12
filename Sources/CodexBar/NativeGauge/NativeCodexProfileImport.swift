import CodexBarCore
import Foundation

enum NativeCodexProfileImportError: Error, LocalizedError {
    case changedOwner
    case unsupportedLogin
    case conflictingManagedAccount
    case storageFailed

    var errorDescription: String? {
        switch self {
        case .changedOwner: "The profile login changed. Refresh and select the account again."
        case .unsupportedLogin: "This profile does not contain a verified Codex OAuth login."
        case .conflictingManagedAccount: "A different saved login already owns this account. Re-authenticate it first."
        case .storageFailed: "Could not safely save the profile login before switching."
        }
    }
}

/// Copies an explicitly selected profile into owned storage before the existing live-promotion transaction.
/// The source profile is never modified, and a failed promotion leaves the imported login available for retry.
@MainActor
struct NativeCodexProfileImporter {
    let store: any ManagedCodexAccountStoring
    let homeFactory: any ManagedCodexHomeProducing
    let authReader: any CodexAuthMaterialReading
    let fileManager: FileManager

    init(
        store: any ManagedCodexAccountStoring = FileManagedCodexAccountStore(),
        homeFactory: any ManagedCodexHomeProducing = ManagedCodexHomeFactory(),
        authReader: any CodexAuthMaterialReading = DefaultCodexAuthMaterialReader(),
        fileManager: FileManager = .default)
    {
        self.store = store
        self.homeFactory = homeFactory
        self.authReader = authReader
        self.fileManager = fileManager
    }

    func importProfile(_ profile: CodexVisibleAccount) throws -> ManagedCodexAccount {
        guard case let .profileHome(path) = profile.selectionSource,
              profile.storedAccountID == nil, !profile.isLive,
              let normalizedPath = CodexHomeScope.normalizedHomePath(path),
              let fingerprint = CodexAuthFingerprint.normalize(profile.authFingerprint)
        else { throw NativeCodexProfileImportError.unsupportedLogin }
        let source = URL(fileURLWithPath: normalizedPath, isDirectory: true)
        return try ManagedCodexAccountLock.withLock(at: self.store.lockURL) {
            guard let data = try self.authReader.readAuthData(homeURL: source),
                  CodexAuthFingerprint.fingerprint(data: data) == fingerprint
            else { throw NativeCodexProfileImportError.changedOwner }
            let identity = try Self.verifiedIdentity(data: data, profile: profile)
            let accounts = try self.store.loadAccounts()
            let matches = accounts.accounts.filter {
                if let workspace = identity.workspace { return $0.effectiveWorkspaceAccountID == workspace }
                return $0.authFingerprint == fingerprint
            }
            if !matches.isEmpty {
                guard matches.count == 1, let existing = matches.first,
                      let saved = try self.authReader.readAuthData(homeURL: URL(
                          fileURLWithPath: existing.managedHomePath, isDirectory: true)), saved == data
                else { throw NativeCodexProfileImportError.conflictingManagedAccount }
                return existing
            }
            // A legacy same-email entry without an owner ID must not be silently replaced by store sanitization.
            guard !accounts.accounts.contains(where: {
                $0.effectiveWorkspaceAccountID == nil && $0.email == identity.email
            }) else { throw NativeCodexProfileImportError.conflictingManagedAccount }
            return try self.persistCopy(
                data, source: source, profile: profile, identity: identity, accounts: accounts)
        }
    }

    private static func verifiedIdentity(
        data: Data,
        profile: CodexVisibleAccount) throws -> (email: String, workspace: String?)
    {
        let credentials = try CodexOAuthCredentialsStore.parse(data: data)
        let identity = try PreparedPromotionContextBuilder.runtimeAccount(from: data)
        guard !credentials.isAPIKey, !credentials.accessToken.isEmpty, !credentials.refreshToken.isEmpty,
              let email = CodexIdentityResolver.normalizeEmail(identity.email),
              email == CodexIdentityResolver.normalizeEmail(profile.email)
        else { throw NativeCodexProfileImportError.unsupportedLogin }
        let workspace: String? = if case let .providerAccount(id) = identity.identity {
            ManagedCodexAccount.normalizeWorkspaceAccountID(id)
        } else { nil }
        guard workspace == ManagedCodexAccount.normalizeWorkspaceAccountID(profile.workspaceAccountID) else {
            throw NativeCodexProfileImportError.changedOwner
        }
        return (email, workspace)
    }

    private func persistCopy(
        _ data: Data,
        source: URL,
        profile: CodexVisibleAccount,
        identity: (email: String, workspace: String?),
        accounts: ManagedCodexAccountSet) throws -> ManagedCodexAccount
    {
        let home = self.homeFactory.makeHomeURL()
        try self.homeFactory.validateManagedHomeForDeletion(home)
        let destination = CodexAuthFingerprint.authFileURL(homePath: home.path)
        guard CodexCredentialFileAccess.permits(destination),
              !self.fileManager.fileExists(atPath: home.path)
        else { throw NativeCodexProfileImportError.storageFailed }
        let now = Date().timeIntervalSince1970
        let account = ManagedCodexAccount(
            id: UUID(),
            email: identity.email,
            providerAccountID: identity.workspace,
            workspaceLabel: profile.workspaceLabel,
            workspaceAccountID: identity.workspace,
            authFingerprint: CodexAuthFingerprint.fingerprint(data: data),
            managedHomePath: home.path,
            createdAt: now,
            updatedAt: now,
            lastAuthenticatedAt: now)
        do {
            try CredentialFileWriter.writePrivate(data, to: destination)
            guard try self.authReader.readAuthData(homeURL: source) == data else {
                throw NativeCodexProfileImportError.changedOwner
            }
            try self.store.storeAccounts(.init(version: accounts.version, accounts: accounts.accounts + [account]))
            guard try self.store.loadAccounts().account(id: account.id) != nil else {
                throw NativeCodexProfileImportError.storageFailed
            }
            return account
        } catch {
            // If a writer committed before reporting failure, retain its referenced home rather than lose auth.
            if let latest = try? self.store.loadAccounts(),
               !latest.accounts.contains(where: { $0.managedHomePath == home.path })
            {
                try? self.fileManager.removeItem(at: home)
            }
            throw error
        }
    }
}
