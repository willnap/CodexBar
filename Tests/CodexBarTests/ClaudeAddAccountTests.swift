import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct ClaudeAddAccountTests {
    @Test
    func `a configured claude-swap that runs wins over install locations`() {
        let path = ClaudeSwapSetup.executablePath(
            configured: "/custom/cswap",
            home: "/Users/example",
            isExecutable: { ["/custom/cswap", "/Users/example/.local/bin/cswap"].contains($0) })
        #expect(path == "/custom/cswap")
    }

    @Test
    func `a missing configured path falls back to where claude-swap installs`() {
        let path = ClaudeSwapSetup.executablePath(
            configured: "/gone/cswap",
            home: "/Users/example",
            isExecutable: { $0 == "/Users/example/.local/bin/cswap" })
        #expect(path == "/Users/example/.local/bin/cswap")
    }

    @Test
    func `no claude-swap anywhere reads as not installed`() {
        #expect(ClaudeSwapSetup.executablePath(configured: "", home: "/Users/example", isExecutable: { _ in false })
            == nil)
    }

    @Test
    func `uv installs claude-swap before pipx`() {
        let both = ClaudeSwapSetup.installer(
            home: "/Users/example",
            isExecutable: { ["/opt/homebrew/bin/uv", "/opt/homebrew/bin/pipx"].contains($0) })
        #expect(both == .init(name: "uv", executable: "/opt/homebrew/bin/uv", arguments: [
            "tool", "install", "claude-swap",
        ]))
        let pipx = ClaudeSwapSetup.installer(home: "/Users/example", isExecutable: { $0 == "/usr/local/bin/pipx" })
        #expect(pipx?.commandLine == "pipx install claude-swap")
        #expect(ClaudeSwapSetup.installer(home: "/Users/example", isExecutable: { _ in false }) == nil)
    }

    @Test
    func `every failed sign in has a reason`() {
        func failure(_ outcome: ClaudeLoginRunner.Result.Outcome, output: String = "") -> String? {
            ClaudeAddAccountFlow.failure(for: .init(outcome: outcome, output: output, authLink: nil))
        }
        #expect(failure(.success) == nil)
        #expect(failure(.timedOut) == L("claude_add_account_timed_out"))
        #expect(failure(.missingBinary) == L("claude_add_account_missing_claude"))
        #expect(failure(.launchFailed("no pty")) == "no pty")
        #expect(failure(.failed(status: 1), output: "Opening browser…\nOAuth error: access denied\n")
            == "OAuth error: access denied")
        #expect(failure(.failed(status: 7)) == L("claude_add_account_login_failed", 7))
    }
}
