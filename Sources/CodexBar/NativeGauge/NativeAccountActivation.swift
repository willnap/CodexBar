import CodexBarCore
import Foundation

enum NativeAccountActivationResult: Equatable {
    case activated
    case unavailable(String)
    case failed(String)
    /// Nothing changed because switching now would need an app restart only the user may approve.
    case deferred(String)
}

/// Promotion writes the ambient auth.json. Refuse configurations where that file cannot prove CLI login ownership.
/// The Codex desktop app shares this login: its bundled app-server reads the same auth.json once at startup, so
/// the desktop follows a change only after it restarts (see `NativeCodexDesktopHandoff`).
enum NativeCodexActivationCapability {
    private static let unsupported = "Switching requires Codex CLI file-based login without auth overrides."
    private static let unreadable = "Could not verify Codex CLI login configuration."

    static func unavailabilityReason(
        environment: [String: String],
        readConfig: (URL) throws -> String? = Self.readConfig) -> String?
    {
        let url = CodexHomeScope.ambientHomeURL(env: environment).appendingPathComponent("config.toml")
        do {
            return try Self.unavailabilityReason(config: readConfig(url) ?? "", environment: environment)
        } catch {
            return Self.unreadable
        }
    }

    static func unavailabilityReason(config: String, environment: [String: String]) -> String? {
        let overrides = ["OPENAI_API_KEY", "CODEX_API_KEY", "OPENAI_BASE_URL", "CODEX_PROFILE"]
        guard !overrides.contains(where: {
            !(environment[$0]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }) else { return Self.unsupported }

        var seenStore = false
        guard let statements = NativeCodexActivationTOMLStatements.parse(config) else { return Self.unreadable }
        for line in statements {
            // Headers don't reset safety: profile-local overrides also need to fail closed.
            if line.hasPrefix("["), line.hasSuffix("]") { continue }
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, let key = Self.key(String(parts[0])) else { return Self.unreadable }
            let value = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            switch key {
            case "cli_auth_credentials_store":
                guard !seenStore, Self.string(value) == "file" else { return Self.unsupported }
                seenStore = true
            case "model_provider":
                // Provider-specific by design: These values are Codex CLI's first-party login configuration contract.
                guard let provider = Self.string(value), ["openai", "chatgpt"].contains(provider) else {
                    return Self.unsupported
                }
            case "profile", "forced_login_method", "forced_chatgpt_workspace_id", "experimental_bearer_token":
                return Self.unsupported
            default:
                continue
            }
        }
        return nil
    }

    private static func readConfig(_ url: URL) throws -> String? {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
        defer { try? handle.close() }
        let limit = 256 * 1024
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit, let contents = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return contents
    }

    private static func key(_ raw: String) -> String? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let quoted = Self.string(key) { return quoted }
        guard !key.isEmpty, key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") })
        else { return nil }
        return key
    }

    private static func string(_ raw: String) -> String? {
        if raw.hasPrefix("\"") { return try? JSONDecoder().decode(String.self, from: Data(raw.utf8)) }
        guard raw.count >= 2, raw.first == "'", raw.last == "'", !raw.dropFirst().dropLast().contains("'") else {
            return nil
        }
        return String(raw.dropFirst().dropLast())
    }
}

/// Splits TOML outside strings/collections so unrelated multiline config cannot hide a later auth override.
/// This is a lexical reader, not a permissive fallback: unterminated strings/collections fail closed.
private enum NativeCodexActivationTOMLStatements {
    static func parse(_ config: String) -> [String]? {
        let characters = Array(config)
        var index = 0
        var brackets: [Character] = []
        var current = ""
        var statements: [String] = []
        while index < characters.count {
            let character = characters[index]
            if character == "'" || character == "\"" {
                guard let end = Self.stringEnd(characters, start: index) else { return nil }
                current += String(characters[index..<end])
                index = end
                continue
            }
            if character == "#" {
                while index < characters.count, !characters[index].isNewline {
                    index += 1
                }
                continue
            }
            if character == "[" || character == "{" {
                brackets.append(character)
            } else if character == "]" || character == "}" {
                guard brackets.popLast() == (character == "]" ? "[" : "{") else { return nil }
            }
            if character.isNewline, brackets.isEmpty {
                let statement = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !statement.isEmpty { statements.append(statement) }
                current = ""
            } else {
                current.append(character)
            }
            index += 1
        }
        guard brackets.isEmpty else { return nil }
        let statement = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !statement.isEmpty { statements.append(statement) }
        return statements
    }

    private static func stringEnd(_ characters: [Character], start: Int) -> Int? {
        let quote = characters[start]
        let multiline = start + 2 < characters.count &&
            characters[start + 1] == quote && characters[start + 2] == quote
        var index = start + (multiline ? 3 : 1)
        while index < characters.count {
            let character = characters[index]
            if !multiline, character.isNewline { return nil }
            if quote == "\"", character == "\\" {
                index += 2
                continue
            }
            if character == quote {
                if !multiline { return index + 1 }
                if index + 2 < characters.count,
                   characters[index + 1] == quote, characters[index + 2] == quote
                {
                    index += 3
                    // TOML permits one or two literal quote characters immediately before its closing triple.
                    for _ in 0..<2 where index < characters.count && characters[index] == quote {
                        index += 1
                    }
                    return index
                }
            }
            index += 1
        }
        return nil
    }
}

enum NativeAccountActivationVerification {
    /// These display fields can detect a changed manual selection, but cannot establish a stable owner for rotation.
    static func claudeSelectionStillMatches(
        _ expected: ProviderAccountUsageSnapshot,
        accounts: [ProviderAccountUsageSnapshot]) -> Bool
    {
        let matches = accounts.filter { $0.id == expected.id }
        guard expected.id.source == ClaudeSwapAccountProjection.sourceName,
              // Provider-specific by design: Both selection snapshots must belong to ClaudeSwap's Claude owner.
              expected.provider == .claude, matches.count == 1, matches[0].provider == .claude,
              let email = expected.accountEmail?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty,
              let organization = expected.accountOrganizationName
        else { return false }
        let current = matches[0]
        return current.accountEmail?.trimmingCharacters(in: .whitespacesAndNewlines) == email &&
            current.accountOrganizationName == organization && current.displayLabel == expected.displayLabel
    }

    static func claudeEnvironmentAllowsActivation(_ environment: [String: String]) -> Bool {
        let overrides = [
            "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "CLAUDE_CODE_OAUTH_TOKEN",
            "CLAUDE_CONFIG_DIR", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY",
        ]
        return !overrides.contains {
            !(environment[$0]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
    }

    static func claudeOwnsLogin(
        _ target: ProviderAccountIdentity,
        accounts: [ProviderAccountUsageSnapshot]) -> Bool
    {
        let active = accounts.filter(\.isActive)
        // Provider-specific by design: ClaudeSwap must prove one active Claude owner after changing its login.
        return target.source == ClaudeSwapAccountProjection.sourceName && active.count == 1 &&
            active[0].id == target && active[0].provider == .claude && !active[0].canActivate &&
            accounts.count(where: { $0.id == target }) == 1
    }

    static func codexOwnsLogin(_ target: CodexVisibleAccount, projection: CodexVisibleAccountProjection) -> Bool {
        let live = projection.visibleAccounts.filter(\.isLive)
        guard live.count == 1, let account = live.first,
              projection.liveVisibleAccountID == account.id,
              account.storedAccountID == target.storedAccountID,
              target.storedAccountID != nil || account.id == target.id
        else { return false }
        return Self.codexOwnerEvidenceMatches(target, account: account)
    }

    static func codexOwnerEvidenceMatches(_ expected: CodexVisibleAccount, account: CodexVisibleAccount) -> Bool {
        if UsageStore.codexPriorSnapshotAccountMatches(expected, account: account) { return true }
        return expected.authFingerprint != nil && expected.authFingerprint == account.authFingerprint &&
            CodexIdentityResolver.normalizeEmail(expected.email) == CodexIdentityResolver
            .normalizeEmail(account.email) &&
            expected.workspaceAccountID == account.workspaceAccountID
    }
}

extension StatusItemController {
    func isNativeAccountActivationBlocked(provider: UsageProvider) -> Bool {
        if self.hasPreparedForAppShutdown || self.loginTask != nil { return true }
        // Provider-specific by design: Codex promotion and ClaudeSwap expose their own credential transaction locks.
        return switch provider {
        case .codex: self.codexAccountPromotionCoordinator.isInteractionBlocked()
        case .claude: self.store.claudeSwapTransientState.task != nil
        default: false
        }
    }

    /// Performs a source-owned credential transaction and verifies its actual owner before reporting success.
    func activateNativeAccount(
        provider: UsageProvider,
        selection: NativeOrbitAccountSelection) async -> NativeAccountActivationResult
    {
        guard !self.isNativeAccountActivationBlocked(provider: provider) else {
            return .unavailable("Finish the current login change before switching accounts.")
        }
        // Provider-specific by design: Credential changes dispatch to the matching Codex or Claude account owner.
        switch selection {
        case let .codex(account) where provider == .codex:
            return await self.activateNativeCodexAccount(account)
        case let .claudeSwap(account) where provider == .claude:
            return await self.activateNativeClaudeAccount(account)
        default:
            return .unavailable("This account can be monitored. Switch its login in the provider’s app or CLI.")
        }
    }

    private func activateNativeCodexAccount(_ target: CodexVisibleAccount) async -> NativeAccountActivationResult {
        if let reason = NativeCodexActivationCapability.unavailabilityReason(environment: self.store.environmentBase) {
            return .unavailable(reason)
        }
        let projection = self.settings.codexVisibleAccountProjection
        let matches = projection.visibleAccounts.filter { $0.id == target.id }
        guard matches.count == 1, let current = matches.first,
              current.storedAccountID == target.storedAccountID,
              current.selectionSource == target.selectionSource,
              UsageStore.codexPriorSnapshotAccountMatches(target, account: current)
        else { return .unavailable("Account ownership changed. Refresh and try again.") }
        var promotionTarget = current
        var desktop = NativeCodexDesktopHandoff.DesktopResult.notRunning
        if current.isLive {
            guard NativeAccountActivationVerification.codexOwnsLogin(target, projection: projection) else {
                return .unavailable("Could not verify the current Codex CLI login.")
            }
            self.settings.codexActiveSource = .liveSystem
            await self.store.refreshCodexAccountScopedState(allowDisabled: true)
        } else {
            // Desktop checks run before any profile import, and the login changes only after the app has quit.
            let handoff = NativeCodexDesktopHandoff(
                liveHome: CodexHomeScope.ambientHomeURL(env: self.store.environmentBase))
            let plan: NativeCodexDesktopHandoff.Plan
            switch handoff.prepare(policy: NativeCodexDesktopHandoff.quitPolicy) {
            case let .ready(ready): plan = ready
            case let .refused(reason): return .unavailable(reason)
            case let .deferred(reason): return .deferred(reason)
            }
            if case .profileHome = current.selectionSource {
                do {
                    let imported = try NativeCodexProfileImporter().importProfile(current)
                    _ = self.settings.refreshCodexAccountReconciliationAfterManagedAccountsDidChange()
                    let importedRows = self.settings.codexVisibleAccountProjection.visibleAccounts.filter {
                        $0.storedAccountID == imported.id
                    }
                    guard importedRows.count == 1, let importedRow = importedRows.first,
                          NativeAccountActivationVerification.codexOwnerEvidenceMatches(current, account: importedRow)
                    else { return .failed("The saved profile login could not be verified. Refresh the accounts.") }
                    promotionTarget = importedRow
                } catch {
                    return .failed(error.localizedDescription)
                }
            }
            guard let managedID = promotionTarget.storedAccountID,
                  promotionTarget.selectionSource == .managedAccount(id: managedID)
            else {
                return .unavailable("This account has no verified saved login to activate.")
            }
            var restartNote: String?
            let outcome = await handoff.run(plan) {
                switch await self.codexAccountPromotionCoordinator.promote(managedAccountID: managedID) {
                case let .failure(error): return error.message
                case let .success(result):
                    restartNote = result.daemonRestartNote
                    return nil
                }
            }
            switch outcome {
            case let .notSwitched(reason): return .failed(reason)
            case let .switched(result): desktop = result
            }
            if let restartNote { return .failed(restartNote) }
            // A relaunched app-server may have rewritten auth.json; verify against the file as it is now.
            if desktop != .notRunning { self.settings.invalidateCodexAccountReconciliationSnapshotCache() }
        }
        guard NativeCodexActivationCapability.unavailabilityReason(environment: self.store.environmentBase) == nil,
              NativeAccountActivationVerification.codexOwnsLogin(
                  promotionTarget, projection: self.settings.codexVisibleAccountProjection)
        else { return .failed("The Codex login could not be verified after switching. Refresh the accounts.") }
        if desktop == .notReopened {
            let app = NativeCodexDesktopHandoff.desktopAppName ?? "The Codex app"
            return .failed("Switched the Codex login. \(app) didn’t reopen; open it to continue with this account.")
        }
        return .activated
    }

    private func activateNativeClaudeAccount(
        _ expected: ProviderAccountUsageSnapshot) async -> NativeAccountActivationResult
    {
        guard NativeAccountActivationVerification.claudeEnvironmentAllowsActivation(self.store.environmentBase) else {
            return .unavailable("Switching requires Claude Code login without token or profile environment overrides.")
        }
        let target = expected.id
        guard self.store.shouldFetchClaudeSwapAccounts(),
              NativeAccountActivationVerification.claudeSelectionStillMatches(
                  expected, accounts: self.store.claudeSwapAccountSnapshots)
        else { return .unavailable("Claude account ownership changed. Refresh and select the account again.") }
        let executable = self.settings.claudeSwapExecutablePath
        let generation = self.store.claudeSwapTransientState.configurationGeneration
        let beforePreflight = self.store.claudeSwapLastRefreshAt
        await self.store.refreshClaudeSwapAccounts()
        guard self.store.isCurrentClaudeSwapConfiguration(
            executablePath: executable, configurationGeneration: generation),
            // Provider-specific by design: Recheck ClaudeSwap's credential transaction lock after its owner refresh.
            !self.isNativeAccountActivationBlocked(provider: .claude),
            let preflightTime = self.store.claudeSwapLastRefreshAt,
            beforePreflight.map({ preflightTime > $0 }) ?? true,
            NativeAccountActivationVerification.claudeSelectionStillMatches(
                expected, accounts: self.store.claudeSwapAccountSnapshots)
        else { return .unavailable("Claude account ownership changed. Refresh and select the account again.") }
        let matches = self.store.claudeSwapAccountSnapshots.filter { $0.id == target }
        // Provider-specific by design: A ClaudeSwap activation must match a unique activatable Claude account.
        guard self.store.shouldFetchClaudeSwapAccounts(), matches.count == 1, matches[0].provider == .claude,
              matches[0].canActivate,
              self.store.claudeSwapLastError == nil
        else { return .unavailable("This Claude account cannot be activated. Refresh the accounts and try again.") }
        let previousRefresh = self.store.claudeSwapLastRefreshAt
        self.store.switchClaudeSwapAccount(target)
        guard let task = self.store.claudeSwapTransientState.task else {
            return .unavailable("Claude account switching is currently unavailable.")
        }
        await task.value
        guard self.store.isCurrentClaudeSwapConfiguration(
            executablePath: executable, configurationGeneration: generation),
            self.store.claudeSwapTransientState.task == nil
        else { return .failed("Claude account configuration changed during switching. Refresh the accounts.") }
        if let error = self.store.claudeSwapTransientState.lastError { return .failed(error) }
        guard self.store.claudeSwapLastError == nil,
              let refreshed = self.store.claudeSwapLastRefreshAt,
              previousRefresh.map({ refreshed > $0 }) ?? true,
              NativeAccountActivationVerification.claudeSelectionStillMatches(
                  expected, accounts: self.store.claudeSwapAccountSnapshots),
              NativeAccountActivationVerification.claudeOwnsLogin(
                  target,
                  accounts: self.store.claudeSwapAccountSnapshots)
        else { return .failed("The active Claude login could not be verified after switching. Refresh the accounts.") }
        return .activated
    }
}
