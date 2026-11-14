import CodexBarCore
import Foundation
import Observation
import Synchronization

/// Adds a Claude account through claude-swap.
///
/// The new login is made in a separate Claude Code profile (`CLAUDE_CONFIG_DIR`), so the account the user is working
/// with stays signed in. `cswap add` then saves that profile's login as a slot. Signing in again with an account that
/// is already saved renews its login in place, which is also how an expired saved login is repaired.
@MainActor
@Observable
final class ClaudeAddAccountFlow {
    enum Phase: Equatable {
        case ready
        case installing
        case signingIn
        case saving
        case added(ClaudeSwapAddResult)
        case failed(String)
    }

    private(set) var phase: Phase = .ready
    /// The sign-in link, once Claude Code prints it, for opening it in another browser or a private window.
    private(set) var link: String?
    private(set) var claudeSwapPath: String?

    @ObservationIgnored private let store: UsageStore
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let cancelled = CancelFlag()
    @ObservationIgnored private var task: Task<Void, Never>?

    /// One sign-in at a time, surviving the Settings page being rebuilt while the browser is open.
    private static var current: ClaudeAddAccountFlow?

    static func shared(store: UsageStore, settings: SettingsStore) -> ClaudeAddAccountFlow {
        if let current, current.store === store { return current }
        let flow = ClaudeAddAccountFlow(store: store, settings: settings)
        self.current = flow
        return flow
    }

    init(store: UsageStore, settings: SettingsStore) {
        self.store = store
        self.settings = settings
        self.claudeSwapPath = ClaudeSwapSetup.executablePath(configured: settings.claudeSwapExecutablePath)
    }

    var isBusy: Bool {
        switch self.phase {
        case .installing, .signingIn, .saving: true
        case .ready, .added, .failed: false
        }
    }

    var installer: ClaudeSwapSetup.Installer? {
        ClaudeSwapSetup.installer()
    }

    func checkForClaudeSwap() {
        self.claudeSwapPath = ClaudeSwapSetup.executablePath(configured: self.settings.claudeSwapExecutablePath)
    }

    func install() {
        guard !self.isBusy, let installer = self.installer else { return }
        self.phase = .installing
        self.task = Task { [weak self] in
            let failure = await ClaudeSwapSetup.install(with: installer)
            guard let self else { return }
            self.checkForClaudeSwap()
            if let failure {
                self.phase = .failed(failure)
            } else if self.claudeSwapPath == nil {
                self.phase = .failed(L("claude_add_account_install_missing"))
            } else {
                self.phase = .ready
            }
        }
    }

    /// Opens the browser to sign in; `email` prefills it when a saved account signs in again.
    func signIn(email: String = "") {
        self.checkForClaudeSwap()
        guard !self.isBusy, let executablePath = self.claudeSwapPath else { return }
        self.cancelled.set(false)
        self.link = nil
        self.phase = .signingIn
        self.useClaudeSwap(at: executablePath)
        self.task = Task { [weak self] in
            await self?.run(executablePath: executablePath, email: email)
        }
    }

    func cancel() {
        self.cancelled.set(true)
        if self.phase == .signingIn { self.phase = .ready }
    }

    // MARK: Steps

    private func run(executablePath: String, email: String) async {
        let profile: URL
        do {
            profile = try ClaudeSwapSetup.preparedSignInProfile()
        } catch {
            self.phase = .failed(error.localizedDescription)
            return
        }
        defer { try? FileManager.default.removeItem(at: profile) }

        let cancelled = self.cancelled
        let showLink: @Sendable (String) -> Void = { [weak self] link in
            Task { @MainActor in self?.link = link }
        }
        let result = await ClaudeLoginRunner.run(
            timeout: 600,
            environment: ClaudeSwapAccountManager.profileEnvironment(
                configDirectory: profile.path,
                base: ProcessInfo.processInfo.environment),
            extraArguments: email.isEmpty ? [] : ["--email", email],
            onLink: showLink,
            isCancelled: { cancelled.isSet },
            onPhaseChange: { _ in })
        guard !self.cancelled.isSet else { return }
        if let failure = Self.failure(for: result) {
            self.phase = .failed(failure)
            return
        }

        self.phase = .saving
        do {
            let added = try await ClaudeSwapAccountManager.addAccount(
                executablePath: executablePath,
                configDirectory: profile.path)
            await self.store.refreshClaudeSwapAccounts()
            self.phase = .added(added)
        } catch {
            self.phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// Adding an account is choosing claude-swap for Claude's accounts.
    private func useClaudeSwap(at executablePath: String) {
        if self.settings.claudeSwapExecutablePath != executablePath {
            self.settings.claudeSwapExecutablePath = executablePath
        }
        if self.settings.claudeSwapSource != .claudeSwap { self.settings.claudeSwapSource = .claudeSwap }
        if !self.settings.claudeSwapEnabled { self.settings.claudeSwapEnabled = true }
    }

    nonisolated static func failure(for result: ClaudeLoginRunner.Result) -> String? {
        switch result.outcome {
        case .success:
            nil
        case .timedOut:
            L("claude_add_account_timed_out")
        case .missingBinary:
            L("claude_add_account_missing_claude")
        case let .launchFailed(reason):
            reason
        case let .failed(status):
            ClaudeSwapAccountManager.reason(from: result.output)
                ?? L("claude_add_account_login_failed", Int(status))
        }
    }
}

/// Read from the login's PTY thread while Settings sets it.
private final class CancelFlag: Sendable {
    private let value = Mutex(false)

    var isSet: Bool {
        self.value.withLock { $0 }
    }

    func set(_ flag: Bool) {
        self.value.withLock { $0 = flag }
    }
}
