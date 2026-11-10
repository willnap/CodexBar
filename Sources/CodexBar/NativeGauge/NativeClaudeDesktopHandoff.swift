import AppKit
import CodexBarCore
import CryptoKit
import Foundation

/// The Claude desktop app's login, kept per account so it can follow a Claude Code switch.
///
/// Unlike Codex, the desktop app shares nothing with the CLI: it is signed in by its own Electron session cookie,
/// stored in its profile's cookie database and encrypted with the app's own Keychain key ("Claude Safe Storage").
/// That key is per Mac, not per account, so the database files can be set aside and put back whole. CodexBar
/// never opens, decrypts or parses them; it only moves the files while the app is not running.
struct NativeClaudeDesktopLoginVault {
    /// The cookie database and its rollback journal, in both places Electron has kept them.
    static let sessionFiles = ["Cookies", "Cookies-journal", "Network/Cookies", "Network/Cookies-journal"]
    /// Where an outgoing login goes when CodexBar cannot name the account it belongs to.
    static let unclaimedKey = "unclaimed"

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
        Self.sessionFiles.contains { name in
            !name.hasSuffix("-journal")
                && FileManager.default.fileExists(atPath: self.slot(key).appendingPathComponent(name).path)
        }
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
        guard present.contains(where: { !$0.hasSuffix("-journal") }) else { return }
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
            let slot = self.slot(key)
            if files.fileExists(atPath: slot.path) { try files.removeItem(at: slot) }
            try files.moveItem(at: staging, to: slot)
        } catch {
            try? files.removeItem(at: staging)
            throw error
        }
    }

    /// Replaces the profile's login with `key`'s saved one, or removes it when none was saved. Call only after the
    /// outgoing login has been stashed: this deletes the profile's current cookie database.
    func install(_ key: String) throws -> Installed {
        let files = FileManager.default
        let restoring = self.hasLogin(key)
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
        /// The app is running agent sessions that quitting it would end, so it was left open.
        case sessionsRunning
        case restored
        case signedOut
        case failed(String)
    }

    var quitTimeout: TimeInterval = 20
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
    /// its own profile. Quitting the app ends every one of them, so a login change never does that by itself.
    /// An unreadable process list counts as hosting, because nothing then shows the quit is harmless.
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
            guard !Self.hostsSessions(
                processes: CodexDesktopProcessProbe.sameUserProcesses(), profile: vault.profile)
            else { return .sessionsRunning }
            // An ordinary quit: the app may ask to confirm, and the user can cancel it there.
            for app in running where app.bundleIdentifier == Self.bundleIdentifier {
                _ = app.terminate()
            }
            let deadline = Date().addingTimeInterval(self.quitTimeout)
            while !Self.runningProcesses().isEmpty, Date() < deadline {
                try? await Task.sleep(for: .seconds(self.pollInterval))
            }
            guard Self.runningProcesses().isEmpty else {
                return .failed("Claude didn’t quit, so its login was left as it was. Quit it and switch again.")
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
