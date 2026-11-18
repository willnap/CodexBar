import AppKit
import CodexBarCore
import CryptoKit
import Foundation

/// The Claude desktop app's login, kept per account so it can follow a Claude Code switch.
///
/// Unlike Codex, the desktop app shares nothing with the CLI. It is signed in twice over: by its Electron session
/// cookie, in its profile's cookie database, and by an OAuth token cache it keeps in `config.json`
/// (`oauth:tokenCacheV2`, with `lastKnownAccountUuid` naming the account). Both are encrypted with the app's own
/// Keychain key ("Claude Safe Storage"), which is per Mac, not per account, so they can be set aside and put back
/// whole. The app trusts the token cache over the cookie, so moving the cookies alone leaves it on the old account.
/// CodexBar never decrypts or parses either; it only moves them while the app is not running.
struct NativeClaudeDesktopLoginVault {
    /// The cookie database and its rollback journal, in both places Electron has kept them.
    static let sessionFiles = ["Cookies", "Cookies-journal", "Network/Cookies", "Network/Cookies-journal"]
    /// Where an outgoing login goes when CodexBar cannot name the account it belongs to.
    static let unclaimedKey = "unclaimed"
    /// The app's settings file, which also holds its OAuth token cache.
    static let configFile = "config.json"
    /// Where a slot keeps the login entries taken out of `config.json`.
    static let configLoginFile = "config-login.json"

    /// The `config.json` entries that belong to the signed-in account rather than to the Mac.
    static func isLoginEntry(_ key: String) -> Bool {
        key.hasPrefix("oauth:") || key == "lastKnownAccountUuid"
    }

    enum Installed: Equatable {
        /// The account's saved login is in place.
        case restored
        /// No login was saved for the account yet, so the app opens signed out.
        case signedOut
    }

    /// The desktop app's profile directory (`~/Library/Application Support/Claude`).
    let profile: URL
    /// CodexBar's own directory of saved logins, one subdirectory per account.
    let vault: URL

    /// A stable directory name for an account that reveals no email on disk.
    static func key(email: String?) -> String? {
        guard let email = email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !email.isEmpty
        else { return nil }
        return SHA256.hash(data: Data(email.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    var hasProfile: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: self.profile.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    func hasLogin(_ key: String) -> Bool {
        (Self.sessionFiles.filter { !$0.hasSuffix("-journal") } + [Self.configLoginFile]).contains { name in
            FileManager.default.fileExists(atPath: self.slot(key).appendingPathComponent(name).path)
        }
    }

    private var configURL: URL {
        self.profile.appendingPathComponent(Self.configFile)
    }

    private func readConfig() throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: self.configURL.path) else { return nil }
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: self.configURL))
        guard let config = object as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
        return config
    }

    private static func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// The profile's current login entries from `config.json`, if it has any.
    private func configLogin() throws -> [String: Any]? {
        let login = try self.readConfig()?.filter { Self.isLoginEntry($0.key) } ?? [:]
        return login.isEmpty ? nil : login
    }

    private func slot(_ key: String) -> URL {
        self.vault.appendingPathComponent(key, isDirectory: true)
    }

    /// Copies the profile's current login into `key`'s slot, replacing what the slot held only once the whole copy
    /// has succeeded. A profile without a cookie database leaves the slot as it was.
    func stash(as key: String) throws {
        let files = FileManager.default
        let present = Self.sessionFiles.filter {
            files.fileExists(atPath: self.profile.appendingPathComponent($0).path)
        }
        let configLogin = try self.configLogin()
        guard present.contains(where: { !$0.hasSuffix("-journal") }) || configLogin != nil else { return }
        try files.createDirectory(
            at: self.vault, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let staging = self.vault.appendingPathComponent(".\(key).incoming-\(UUID().uuidString)", isDirectory: true)
        do {
            for name in present {
                let destination = staging.appendingPathComponent(name)
                try files.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                try files.copyItem(at: self.profile.appendingPathComponent(name), to: destination)
                try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            }
            if let configLogin {
                try files.createDirectory(
                    at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let destination = staging.appendingPathComponent(Self.configLoginFile)
                try Self.json(configLogin).write(to: destination, options: .atomic)
                try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            }
            let slot = self.slot(key)
            if files.fileExists(atPath: slot.path) { try files.removeItem(at: slot) }
            try files.moveItem(at: staging, to: slot)
        } catch {
            try? files.removeItem(at: staging)
            throw error
        }
    }

    /// Replaces the profile's login with `key`'s saved one, or removes it when none was saved. Call only after the
    /// outgoing login has been stashed: this deletes the profile's current cookie database and token cache.
    func install(_ key: String) throws -> Installed {
        let files = FileManager.default
        let restoring = self.hasLogin(key)
        try self.installConfigLogin(key, restoring: restoring)
        for name in Self.sessionFiles {
            let live = self.profile.appendingPathComponent(name)
            if files.fileExists(atPath: live.path) { try files.removeItem(at: live) }
            let saved = self.slot(key).appendingPathComponent(name)
            guard restoring, files.fileExists(atPath: saved.path) else { continue }
            try files.createDirectory(at: live.deletingLastPathComponent(), withIntermediateDirectories: true)
            try files.copyItem(at: saved, to: live)
        }
        return restoring ? .restored : .signedOut
    }

    /// Swaps only the login entries of `config.json`, leaving every other setting as the app wrote it. A login
    /// saved before the app kept a token cache restores no entries, so the app falls back to its cookie.
    private func installConfigLogin(_ key: String, restoring: Bool) throws {
        let savedURL = self.slot(key).appendingPathComponent(Self.configLoginFile)
        var saved: [String: Any] = [:]
        if restoring, FileManager.default.fileExists(atPath: savedURL.path) {
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: savedURL))
            saved = (object as? [String: Any] ?? [:]).filter { Self.isLoginEntry($0.key) }
        }
        let current = try self.readConfig() ?? [:]
        guard !saved.isEmpty || current.keys.contains(where: Self.isLoginEntry) else { return }
        var config = current.filter { !Self.isLoginEntry($0.key) }
        config.merge(saved) { _, new in new }
        try Self.json(config).write(to: self.configURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: self.configURL.path)
    }
}

/// Moves the Claude desktop app along with a Claude Code account switch: quit the app, set its login aside under
/// the outgoing account, put the incoming account's saved login in its place, and reopen it.
///
/// The first switch to an account has nothing saved, so the app reopens signed out; signing in there once is what
/// gets saved the next time that account is switched away from. CodexBar cannot read which account the app is
/// signed in to, so it files the outgoing login under the account Claude Code was using.
@MainActor
struct NativeClaudeDesktopHandoff {
    static let bundleIdentifier = "com.anthropic.claudefordesktop"

    static var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
    }

    /// What a Claude login change applies to, as shown in the account menu.
    static let loginTargetName: String = NativeClaudeDesktopHandoff.isInstalled ? "Claude & Claude Code" : "Claude Code"

    enum Outcome: Equatable {
        /// Nothing to move: the app or its profile is absent, or the account did not change.
        case notApplicable
        /// The app is open and this switch may not quit it.
        case leftOpen
        case restored
        case signedOut
        case failed(String)
    }

    /// Why the app is not on the incoming account after Claude Code switched, or nil when it is (or has nothing to
    /// follow). The app reopening signed out the first time an account is used is not a failure.
    nonisolated static func unfollowedReason(_ outcome: Outcome) -> String? {
        switch outcome {
        case .notApplicable, .restored, .signedOut: nil
        case .leftOpen: "Switched Claude Code. Claude was open, so it stayed on its account."
        case let .failed(reason): "Switched Claude Code. \(reason)"
        }
    }

    var quitTimeout: TimeInterval = 20
    /// Longer while the app hosts sessions: it may be waiting on its own confirmation to quit them.
    var sessionsQuitTimeout: TimeInterval = 120
    var pollInterval: TimeInterval = 0.25

    static func liveVault() -> NativeClaudeDesktopLoginVault? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        return NativeClaudeDesktopLoginVault(
            profile: base.appendingPathComponent("Claude", isDirectory: true),
            vault: base.appendingPathComponent("CodexBar", isDirectory: true)
                .appendingPathComponent("claude-desktop-logins", isDirectory: true))
    }

    /// The app and its helper processes; the cookie database is only safe to move once all of them are gone.
    private static func runningProcesses() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated && ($0.bundleIdentifier ?? "").hasPrefix(Self.bundleIdentifier)
        }
    }

    /// Whether the desktop app is hosting Claude Code sessions: processes started from the runtime it keeps in
    /// its own profile. Quitting the app stops them (it saves and restores them on relaunch) and it may ask to
    /// confirm first, so the switch waits longer for it. An unreadable process list counts as hosting.
    nonisolated static func hostsSessions(processes: [CodexProcessRecord]?, profile: URL) -> Bool {
        guard let processes else { return true }
        let runtimes = ["claude-code", "claude-code-vm"].map {
            profile.appendingPathComponent($0, isDirectory: true).standardizedFileURL.path + "/"
        }
        return processes.contains { process in
            let path = URL(fileURLWithPath: process.executablePath).standardizedFileURL.path
            return runtimes.contains { path.hasPrefix($0) }
        }
    }

    func follow(outgoingEmail: String?, incomingEmail: String?, mayQuit: Bool) async -> Outcome {
        guard !SettingsStore.isRunningTests, Self.isInstalled,
              let incoming = NativeClaudeDesktopLoginVault.key(email: incomingEmail),
              let vault = Self.liveVault(), vault.hasProfile
        else { return .notApplicable }
        let outgoing = NativeClaudeDesktopLoginVault.key(email: outgoingEmail)
            ?? NativeClaudeDesktopLoginVault.unclaimedKey
        guard outgoing != incoming else { return .notApplicable }

        let running = Self.runningProcesses()
        let bundlePath = running.first { $0.bundleIdentifier == Self.bundleIdentifier }?.bundleURL?.path
        if !running.isEmpty {
            guard mayQuit else { return .leftOpen }
            let hostsSessions = Self.hostsSessions(
                processes: CodexDesktopProcessProbe.sameUserProcesses(), profile: vault.profile)
            // An ordinary quit: the app may ask to confirm, and the user can cancel it there.
            for app in running where app.bundleIdentifier == Self.bundleIdentifier {
                _ = app.terminate()
            }
            let deadline = Date().addingTimeInterval(hostsSessions ? self.sessionsQuitTimeout : self.quitTimeout)
            while !Self.runningProcesses().isEmpty, Date() < deadline {
                try? await Task.sleep(for: .seconds(self.pollInterval))
            }
            guard Self.runningProcesses().isEmpty else {
                return .failed("Claude didn’t quit, so it stayed on its account.")
            }
            // Give the exiting network process a moment to finish writing the cookie database.
            try? await Task.sleep(for: .milliseconds(500))
        }

        let outcome: Outcome
        do {
            try vault.stash(as: outgoing)
            outcome = try vault.install(incoming) == .restored ? .restored : .signedOut
        } catch {
            if let bundlePath { await Self.launch(bundlePath: bundlePath) }
            return .failed("Claude’s login couldn’t be swapped (\(error.localizedDescription)).")
        }
        if let bundlePath { await Self.launch(bundlePath: bundlePath) }
        CodexBarLog.logger("native-gauges").info(
            "Claude desktop login followed the account switch",
            metadata: [
                "restored": outcome == .restored ? "1" : "0",
                "reopened": bundlePath == nil ? "0" : "1",
            ])
        return outcome
    }

    private static func launch(bundlePath: String) async {
        let configuration = NSWorkspace.OpenConfiguration()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            NSWorkspace.shared.openApplication(
                at: URL(fileURLWithPath: bundlePath, isDirectory: true),
                configuration: configuration)
            { _, _ in
                continuation.resume()
            }
        }
    }
}
