import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct NativeClaudeDesktopLoginVaultTests {
    private static func makeVault() throws -> NativeClaudeDesktopLoginVault {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-desktop-vault-\(UUID().uuidString)", isDirectory: true)
        let profile = root.appendingPathComponent("Claude", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        return NativeClaudeDesktopLoginVault(
            profile: profile, vault: root.appendingPathComponent("logins", isDirectory: true))
    }

    private static func write(
        _ text: String, to vault: NativeClaudeDesktopLoginVault, name: String = "Cookies") throws
    {
        try Data(text.utf8).write(to: vault.profile.appendingPathComponent(name))
    }

    private static func read(_ vault: NativeClaudeDesktopLoginVault, name: String = "Cookies") -> String? {
        (try? Data(contentsOf: vault.profile.appendingPathComponent(name))).flatMap {
            String(data: $0, encoding: .utf8)
        }
    }

    @Test
    func `keys are stable per email and hide it`() throws {
        let key = try #require(NativeClaudeDesktopLoginVault.key(email: " Person@Example.com "))
        #expect(key == NativeClaudeDesktopLoginVault.key(email: "person@example.com"))
        #expect(!key.contains("person"))
        #expect(NativeClaudeDesktopLoginVault.key(email: "  ") == nil)
    }

    @Test
    func `a first switch signs the app out and a return restores the saved login`() throws {
        let vault = try Self.makeVault()
        try Self.write("first", to: vault)
        try Self.write("journal", to: vault, name: "Cookies-journal")

        try vault.stash(as: "a")
        #expect(try vault.install("b") == .signedOut)
        #expect(Self.read(vault) == nil)
        #expect(Self.read(vault, name: "Cookies-journal") == nil)

        try Self.write("second", to: vault)
        try vault.stash(as: "b")
        #expect(try vault.install("a") == .restored)
        #expect(Self.read(vault) == "first")
        #expect(Self.read(vault, name: "Cookies-journal") == "journal")

        try vault.stash(as: "a")
        #expect(try vault.install("b") == .restored)
        #expect(Self.read(vault) == "second")
    }

    private static func writeConfig(_ object: [String: Any], to vault: NativeClaudeDesktopLoginVault) throws {
        try JSONSerialization.data(withJSONObject: object)
            .write(to: vault.profile.appendingPathComponent("config.json"))
    }

    private static func readConfig(_ vault: NativeClaudeDesktopLoginVault) throws -> [String: Any] {
        let data = try Data(contentsOf: vault.profile.appendingPathComponent("config.json"))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test
    func `the token cache in config json follows the account and other settings stay`() throws {
        let vault = try Self.makeVault()
        try Self.write("cookie-a", to: vault)
        try Self.writeConfig(
            ["locale": "en-US", "oauth:tokenCacheV2": "token-a", "lastKnownAccountUuid": "uuid-a"], to: vault)

        try vault.stash(as: "a")
        #expect(try vault.install("b") == .signedOut)
        var config = try Self.readConfig(vault)
        #expect(config["oauth:tokenCacheV2"] == nil)
        #expect(config["lastKnownAccountUuid"] == nil)
        #expect(config["locale"] as? String == "en-US")

        try Self.write("cookie-b", to: vault)
        try Self.writeConfig(
            ["locale": "en-GB", "oauth:tokenCacheV2": "token-b", "lastKnownAccountUuid": "uuid-b"], to: vault)
        try vault.stash(as: "b")
        #expect(try vault.install("a") == .restored)
        config = try Self.readConfig(vault)
        #expect(config["oauth:tokenCacheV2"] as? String == "token-a")
        #expect(config["lastKnownAccountUuid"] as? String == "uuid-a")
        #expect(config["locale"] as? String == "en-GB")
        #expect(Self.read(vault) == "cookie-a")

        try vault.stash(as: "a")
        #expect(try vault.install("b") == .restored)
        #expect(try Self.readConfig(vault)["oauth:tokenCacheV2"] as? String == "token-b")
    }

    @Test
    func `a login saved before the token cache still clears the outgoing token`() throws {
        let vault = try Self.makeVault()
        try Self.write("cookie-a", to: vault)
        try vault.stash(as: "a")
        try Self.writeConfig(["locale": "en-US", "oauth:tokenCacheV2": "token-b"], to: vault)

        #expect(try vault.install("a") == .restored)
        let config = try Self.readConfig(vault)
        #expect(config["oauth:tokenCacheV2"] == nil)
        #expect(config["locale"] as? String == "en-US")
        #expect(Self.read(vault) == "cookie-a")
    }

    @Test
    func `a profile without a cookie database keeps the saved login`() throws {
        let vault = try Self.makeVault()
        try Self.write("saved", to: vault)
        try vault.stash(as: "a")
        try FileManager.default.removeItem(at: vault.profile.appendingPathComponent("Cookies"))

        try vault.stash(as: "a")
        #expect(vault.hasLogin("a"))
        #expect(try vault.install("a") == .restored)
        #expect(Self.read(vault) == "saved")
    }

    @Test
    func `sessions hosted by the desktop app give it longer to quit`() {
        let profile = URL(fileURLWithPath: "/Users/someone/Library/Application Support/Claude", isDirectory: true)
        func process(_ path: String) -> CodexProcessRecord {
            CodexProcessRecord(pid: 1, parentPID: 0, executablePath: path, startedAt: Date())
        }
        let session = process(profile.path + "/claude-code/2.1.0/abc/claude.app/Contents/MacOS/claude")
        let unrelated = process("/Applications/Claude.app/Contents/MacOS/Claude")
        let terminal = process("/Users/someone/.local/bin/claude")

        #expect(NativeClaudeDesktopHandoff.hostsSessions(processes: [unrelated, session], profile: profile))
        #expect(!NativeClaudeDesktopHandoff.hostsSessions(processes: [unrelated, terminal], profile: profile))
        #expect(!NativeClaudeDesktopHandoff.hostsSessions(processes: [], profile: profile))
        // Without a process list nothing shows that quitting is harmless.
        #expect(NativeClaudeDesktopHandoff.hostsSessions(processes: nil, profile: profile))
    }
}
