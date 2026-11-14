import CodexBarCore
import Foundation

/// Finding and installing claude-swap, and the scratch Claude Code profile a new account signs in to.
enum ClaudeSwapSetup {
    struct Installer: Equatable {
        let name: String
        let executable: String
        let arguments: [String]

        var commandLine: String {
            ([self.name] + self.arguments).joined(separator: " ")
        }
    }

    static let packageName = "claude-swap"
    static let projectURL = URL(string: "https://github.com/realiti4/claude-swap")!

    /// The configured executable when it runs, else the first install location that has one.
    static func executablePath(
        configured: String,
        home: String = NSHomeDirectory(),
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String?
    {
        let trimmed = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let expanded = (trimmed as NSString).expandingTildeInPath
            if isExecutable(expanded) { return expanded }
        }
        return self.candidatePaths(home: home).first(where: isExecutable)
    }

    static func candidatePaths(home: String) -> [String] {
        let directories = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        return directories.flatMap { ["\($0)/cswap", "\($0)/claude-swap"] }
    }

    /// uv first (claude-swap's own recommendation), then pipx.
    static func installer(
        home: String = NSHomeDirectory(),
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> Installer?
    {
        let directories = ["\(home)/.local/bin", "\(home)/.cargo/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        let tools: [(String, [String])] = [
            ("uv", ["tool", "install", Self.packageName]),
            ("pipx", ["install", Self.packageName]),
        ]
        for (name, arguments) in tools {
            if let path = directories.map({ "\($0)/\(name)" }).first(where: isExecutable) {
                return Installer(name: name, executable: path, arguments: arguments)
            }
        }
        return nil
    }

    /// Runs the installer; returns its reason on failure.
    static func install(with installer: Installer) async -> String? {
        do {
            _ = try await SubprocessRunner.run(
                binary: installer.executable,
                arguments: installer.arguments,
                environment: ClaudeSwapAccountManager.scrubbedEnvironment(ProcessInfo.processInfo.environment),
                timeout: 300,
                label: "claude-swap install")
            return nil
        } catch let SubprocessRunnerError.nonZeroExit(_, stderr) {
            return ClaudeSwapAccountManager.reason(from: stderr) ?? L("claude_add_account_install_failed")
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// One fixed location, emptied before every sign-in. Claude Code names the profile's Keychain item after this
    /// path, so reusing it keeps a single item instead of leaving one behind per added account.
    static func signInProfileURL() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true)
        return support.appendingPathComponent("CodexBar", isDirectory: true)
            .appendingPathComponent("ClaudeAddAccount", isDirectory: true)
    }

    static func preparedSignInProfile() throws -> URL {
        let url = try self.signInProfileURL()
        let manager = FileManager.default
        if manager.fileExists(atPath: url.path) { try manager.removeItem(at: url) }
        try manager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }
}
