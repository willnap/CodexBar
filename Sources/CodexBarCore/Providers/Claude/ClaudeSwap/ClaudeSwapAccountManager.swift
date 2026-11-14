import Crypto
import Foundation

/// What `cswap add` did with the login it was given.
public struct ClaudeSwapAddResult: Equatable, Sendable {
    public let slot: Int
    public let email: String
    /// The account was already managed; claude-swap renewed its saved login in place.
    public let wasAlreadyAdded: Bool
}

public enum ClaudeSwapAccountManagerError: LocalizedError, Equatable, Sendable {
    /// claude-swap refused or failed; the text is its own reason.
    case commandFailed(String)
    case unrecognizedOutput

    public var errorDescription: String? {
        switch self {
        case let .commandFailed(reason): reason
        case .unrecognizedOutput: "claude-swap gave an answer CodexBar could not read."
        }
    }
}

/// Account management through the external `claude-swap` executable.
///
/// Every command is a fixed argument array: no shell, no passthrough arguments. CodexBar never reads or writes a
/// credential itself. A new account is signed in to a separate Claude Code profile (`CLAUDE_CONFIG_DIR`) and
/// `cswap add` saves that profile's login, so the login the user is working with is never replaced.
public enum ClaudeSwapAccountManager {
    public static let commandTimeout: TimeInterval = 60

    /// Saves the login held by the Claude Code profile at `configDirectory`.
    public static func addAccount(
        executablePath: String,
        configDirectory: String,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment) async throws -> ClaudeSwapAddResult
    {
        let stdout = try await self.run(
            executablePath: executablePath,
            arguments: ["add"],
            environment: self.profileEnvironment(configDirectory: configDirectory, base: baseEnvironment),
            label: "claude-swap add")
        guard let result = self.parseAddOutput(stdout) else {
            throw ClaudeSwapAccountManagerError.unrecognizedOutput
        }
        return result
    }

    /// Sets the display alias of a slot, or removes it when `alias` is nil.
    public static func setAlias(executablePath: String, slot: Int, alias: String?) async throws {
        let trimmed = alias?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let arguments = trimmed.isEmpty
            ? ["alias", String(slot), "--unset"]
            : ["alias", String(slot), trimmed]
        _ = try await self.run(
            executablePath: executablePath,
            arguments: arguments,
            environment: self.scrubbedEnvironment(ProcessInfo.processInfo.environment),
            label: "claude-swap alias")
    }

    /// Removes a slot and its saved login. claude-swap asks before it removes, so the answer is piped in.
    public static func removeAccount(executablePath: String, slot: Int) async throws {
        _ = try await self.run(
            executablePath: executablePath,
            arguments: ["remove", String(slot)],
            environment: self.scrubbedEnvironment(ProcessInfo.processInfo.environment),
            standardInput: "y\n",
            label: "claude-swap remove")
    }

    // MARK: Environment

    /// Variables that point Claude Code or claude-swap at another login or profile.
    static func isLoginOverride(_ key: String) -> Bool {
        key.hasPrefix("CLAUDE_") || key.hasPrefix("ANTHROPIC_")
    }

    public static func scrubbedEnvironment(_ base: [String: String]) -> [String: String] {
        base.filter { !self.isLoginOverride($0.key) }
    }

    /// The environment that makes Claude Code and claude-swap both use the profile at `configDirectory`.
    public static func profileEnvironment(configDirectory: String, base: [String: String]) -> [String: String] {
        var environment = self.scrubbedEnvironment(base)
        environment["CLAUDE_CONFIG_DIR"] = configDirectory
        return environment
    }

    /// The Keychain service Claude Code uses for the profile at `configDirectory`: it hashes the exact exported
    /// string (NFC), never a resolved path.
    public static func keychainServiceName(configDirectory: String) -> String {
        let normalized = configDirectory.precomposedStringWithCanonicalMapping
        let digest = SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
        return "Claude Code-credentials-\(digest.prefix(8))"
    }

    // MARK: Output

    /// Reads `Added Account 3: a@b.c [Personal]` or `Updated credentials for Account 3 (a@b.c [Personal]).`
    static func parseAddOutput(_ stdout: String) -> ClaudeSwapAddResult? {
        let text = self.strippingANSI(stdout)
        let patterns: [(String, Bool)] = [
            (#"Added Account (\d+): (\S+)"#, false),
            (#"Updated credentials for Account (\d+) \((\S+)"#, true),
        ]
        for (pattern, existed) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let slotRange = Range(match.range(at: 1), in: text),
                  let emailRange = Range(match.range(at: 2), in: text),
                  let slot = Int(text[slotRange])
            else { continue }
            return ClaudeSwapAddResult(slot: slot, email: String(text[emailRange]), wasAlreadyAdded: existed)
        }
        return nil
    }

    static func strippingANSI(_ text: String) -> String {
        text.replacingOccurrences(of: #"\u001B\[[0-9;?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
    }

    /// claude-swap's own reason: its last non-empty line, without colour codes or an `Error:` prefix.
    public static func reason(from output: String) -> String? {
        let lines = self.strippingANSI(output)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Traceback") }
        guard var line = lines.last else { return nil }
        for prefix in ["Error:", "error:"] where line.hasPrefix(prefix) {
            line = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        }
        return line.isEmpty ? nil : line
    }

    // MARK: Process

    private static func run(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        standardInput: String? = nil,
        label: String) async throws -> String
    {
        let binary = try ClaudeSwapAccountReader.resolvedExecutablePath(executablePath)
        var input: Pipe?
        if let standardInput {
            let pipe = Pipe()
            pipe.fileHandleForWriting.write(Data(standardInput.utf8))
            try? pipe.fileHandleForWriting.close()
            input = pipe
        }
        do {
            let result = try await SubprocessRunner.run(
                binary: binary,
                arguments: arguments,
                environment: environment,
                timeout: self.commandTimeout,
                maxOutputBytes: ClaudeSwapAccountReader.maxOutputBytes,
                standardInput: input,
                label: label)
            return result.stdout
        } catch let SubprocessRunnerError.nonZeroExit(code, stderr) {
            throw ClaudeSwapAccountManagerError.commandFailed(
                self.reason(from: stderr) ?? "claude-swap stopped with exit code \(code).")
        }
    }
}
