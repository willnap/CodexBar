import Foundation
import Testing
@testable import CodexBarCore

/// Fake executables only: no real claude-swap, no credentials, no Keychain access.
struct ClaudeSwapAccountManagerTests {
    private func makeFakeExecutable(_ script: String) throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-swap-manager-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("cswap")
        try "#!/bin/sh\n\(script)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    @Test
    func `reads a newly added account from colored output`() {
        let output = "\u{1B}[32mAdded\u{1B}[0m Account 3: second@example.com \u{1B}[2m[Personal]\u{1B}[0m\n"
        #expect(ClaudeSwapAccountManager.parseAddOutput(output) == ClaudeSwapAddResult(
            slot: 3, email: "second@example.com", wasAlreadyAdded: false))
    }

    @Test
    func `reads a renewed login of an account that was already added`() {
        let output = "Updated credentials for Account 2 (first@example.com [Example Org]).\n"
        #expect(ClaudeSwapAccountManager.parseAddOutput(output) == ClaudeSwapAddResult(
            slot: 2, email: "first@example.com", wasAlreadyAdded: true))
    }

    @Test
    func `unreadable add output is not mistaken for success`() {
        #expect(ClaudeSwapAccountManager.parseAddOutput("Cancelled\n") == nil)
    }

    @Test
    func `the profile keychain name matches claude-swap's own hash`() {
        // Values from claude_swap.session.keychain_service_name.
        #expect(ClaudeSwapAccountManager.keychainServiceName(
            configDirectory: "/Users/example/Library/Application Support/CodexBar/ClaudeAddAccount")
            == "Claude Code-credentials-7943b3b5")
        #expect(ClaudeSwapAccountManager.keychainServiceName(configDirectory: "/tmp/Cafe\u{301}")
            == "Claude Code-credentials-c5d313be")
    }

    @Test
    func `the sign in profile replaces every login override`() {
        let environment = ClaudeSwapAccountManager.profileEnvironment(
            configDirectory: "/profile",
            base: [
                "PATH": "/usr/bin",
                "HOME": "/Users/example",
                "CLAUDE_CONFIG_DIR": "/elsewhere",
                "CLAUDE_SECURESTORAGE_CONFIG_DIR": "/elsewhere",
                "CLAUDE_CODE_OAUTH_TOKEN": "token",
                "ANTHROPIC_API_KEY": "key",
            ])
        #expect(environment == ["PATH": "/usr/bin", "HOME": "/Users/example", "CLAUDE_CONFIG_DIR": "/profile"])
    }

    @Test
    func `add runs claude-swap add inside the sign in profile`() async throws {
        let path = try self.makeFakeExecutable("""
        [ "$#" = "1" ] && [ "$1" = "add" ] || exit 2
        [ "$CLAUDE_CONFIG_DIR" = "/profile" ] || exit 3
        [ -z "$CLAUDE_CODE_OAUTH_TOKEN" ] || exit 4
        echo "Added Account 4: new@example.com [Personal]"
        """)
        let result = try await ClaudeSwapAccountManager.addAccount(
            executablePath: path,
            configDirectory: "/profile",
            baseEnvironment: ["PATH": "/usr/bin:/bin", "CLAUDE_CODE_OAUTH_TOKEN": "token"])
        #expect(result == ClaudeSwapAddResult(slot: 4, email: "new@example.com", wasAlreadyAdded: false))
    }

    @Test
    func `a refusal carries claude-swap's own reason`() async throws {
        let path = try self.makeFakeExecutable("""
        printf '\\033[31mError: No active Claude account found. Please log in first.\\033[0m\\n' >&2
        exit 1
        """)
        await #expect(throws: ClaudeSwapAccountManagerError.commandFailed(
            "No active Claude account found. Please log in first."))
        {
            try await ClaudeSwapAccountManager.addAccount(executablePath: path, configDirectory: "/profile")
        }
    }

    @Test
    func `rename sets and clears an alias with exact arguments`() async throws {
        let path = try self.makeFakeExecutable("""
        echo "$@" >> "$0.calls"
        """)
        try await ClaudeSwapAccountManager.setAlias(executablePath: path, slot: 2, alias: " work ")
        try await ClaudeSwapAccountManager.setAlias(executablePath: path, slot: 2, alias: "")
        let calls = try String(contentsOfFile: path + ".calls", encoding: .utf8)
        #expect(calls == "alias 2 work\nalias 2 --unset\n")
    }

    @Test
    func `remove answers claude-swap's confirmation`() async throws {
        let path = try self.makeFakeExecutable("""
        [ "$1" = "remove" ] && [ "$2" = "5" ] || exit 2
        read answer
        [ "$answer" = "y" ] || exit 3
        echo "Removed Account 5"
        """)
        try await ClaudeSwapAccountManager.removeAccount(executablePath: path, slot: 5)
    }
}
