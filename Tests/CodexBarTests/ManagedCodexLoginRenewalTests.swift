import Foundation
import Testing
@testable import CodexBarCore

@MainActor
struct ManagedCodexLoginRenewalTests {
    private struct Fixture {
        let root: URL
        let store: FileManagedCodexAccountStore
        let accountID = UUID()
        let home: URL
        let liveHome: URL

        init() throws {
            self.root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            self.home = self.root.appendingPathComponent("managed/\(UUID().uuidString)", isDirectory: true)
            self.liveHome = self.root.appendingPathComponent("live", isDirectory: true)
            try FileManager.default.createDirectory(at: self.home, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: self.liveHome, withIntermediateDirectories: true)
            self.store = FileManagedCodexAccountStore(fileURL: self.root.appendingPathComponent("accounts.json"))
        }

        func saveAccount() throws {
            try self.store.storeAccounts(ManagedCodexAccountSet(version: 3, accounts: [ManagedCodexAccount(
                id: self.accountID,
                email: "second@example.com",
                workspaceAccountID: "acct-second",
                authFingerprint: CodexAuthFingerprint.fingerprint(homePath: self.home.path),
                managedHomePath: self.home.path,
                createdAt: 1,
                updatedAt: 1,
                lastAuthenticatedAt: 1)]))
        }

        func renew(
            otherHomes: [URL]? = nil,
            now: Date,
            renewer: @escaping @Sendable (URL) async throws -> Void) async -> ManagedCodexLoginRenewal.Outcome
        {
            await CodexCredentialFileAccess.withFixtureScope(.init(roots: [self.root])) {
                await ManagedCodexLoginRenewal.renewIfDue(
                    accountID: self.accountID,
                    store: self.store,
                    otherHomes: otherHomes ?? [self.liveHome],
                    now: now,
                    renew: renewer)
            }
        }
    }

    private nonisolated static func writeAuth(
        to home: URL,
        refreshToken: String,
        accountID: String,
        expiresAt: Date,
        accessToken: String = "access") throws
    {
        let payload = try JSONSerialization.data(withJSONObject: ["exp": Int(expiresAt.timeIntervalSince1970)])
        let encoded = payload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let json: [String: Any] = [
            "tokens": [
                "access_token": "e30.\(encoded).\(accessToken)",
                "refresh_token": refreshToken,
                "account_id": accountID,
            ],
            "last_refresh": "2026-10-20T00:00:00Z",
        ]
        try JSONSerialization.data(withJSONObject: json)
            .write(to: home.appendingPathComponent("auth.json"))
    }

    private static func readStoredFingerprint(_ fixture: Fixture) throws -> String? {
        try fixture.store.loadAccounts().account(id: fixture.accountID)?.authFingerprint
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test
    func `a login more than a day from expiry is left alone`() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try Self.writeAuth(
            to: fixture.home,
            refreshToken: "rt-1",
            accountID: "acct-second",
            expiresAt: self.now.addingTimeInterval(3 * 24 * 60 * 60))
        try fixture.saveAccount()
        let outcome = await fixture.renew(now: self.now) { _ in Issue.record("renewal should not run") }
        #expect(outcome == .notDue)
    }

    @Test
    func `an expiring saved login is renewed through its owner and the registry follows the new file`() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try Self.writeAuth(
            to: fixture.home,
            refreshToken: "rt-1",
            accountID: "acct-second",
            expiresAt: self.now.addingTimeInterval(-60))
        try Self.writeAuth(
            to: fixture.liveHome,
            refreshToken: "rt-live",
            accountID: "acct-live",
            expiresAt: self.now.addingTimeInterval(9 * 24 * 60 * 60))
        try fixture.saveAccount()
        let before = try Self.readStoredFingerprint(fixture)
        let expires = self.now.addingTimeInterval(10 * 24 * 60 * 60)
        let renewedHome = LockedBox<URL?>(nil)
        let outcome = await fixture.renew(now: self.now) { home in
            renewedHome.set(home)
            try Self.writeAuth(to: home, refreshToken: "rt-2", accountID: "acct-second", expiresAt: expires)
        }
        #expect(outcome == .renewed)
        #expect(renewedHome.get()?.standardizedFileURL.path == fixture.home.standardizedFileURL.path)
        let after = try Self.readStoredFingerprint(fixture)
        #expect(after != before)
        #expect(after == CodexCredentialFileAccess.withFixtureScope(.init(roots: [fixture.root])) {
            CodexAuthFingerprint.fingerprint(homePath: fixture.home.path)
        })
    }

    @Test
    func `a login whose refresh token another home also holds is never redeemed`() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try Self.writeAuth(
            to: fixture.home,
            refreshToken: "rt-shared",
            accountID: "acct-second",
            expiresAt: self.now.addingTimeInterval(-60))
        try Self.writeAuth(
            to: fixture.liveHome,
            refreshToken: "rt-shared",
            accountID: "acct-second",
            expiresAt: self.now.addingTimeInterval(-60))
        try fixture.saveAccount()
        let outcome = await fixture.renew(now: self.now) { _ in Issue.record("renewal should not run") }
        #expect(outcome == .sharedLogin)
    }

    @Test
    func `a newer copy of the same account elsewhere blocks renewal of the older one`() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try Self.writeAuth(
            to: fixture.home,
            refreshToken: "rt-old",
            accountID: "acct-second",
            expiresAt: self.now.addingTimeInterval(-60))
        try Self.writeAuth(
            to: fixture.liveHome,
            refreshToken: "rt-new",
            accountID: "acct-second",
            expiresAt: self.now.addingTimeInterval(9 * 24 * 60 * 60))
        try fixture.saveAccount()
        let outcome = await fixture.renew(now: self.now) { _ in Issue.record("renewal should not run") }
        #expect(outcome == .sharedLogin)
    }

    @Test
    func `an older dead copy of the same account does not block the newest one`() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let profile = fixture.root.appendingPathComponent("profile", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try Self.writeAuth(
            to: fixture.home,
            refreshToken: "rt-head",
            accountID: "acct-second",
            expiresAt: self.now.addingTimeInterval(-60))
        try Self.writeAuth(
            to: profile,
            refreshToken: "rt-dead",
            accountID: "acct-second",
            expiresAt: self.now.addingTimeInterval(-12 * 24 * 60 * 60))
        try fixture.saveAccount()
        let outcome = await fixture.renew(otherHomes: [fixture.liveHome, profile], now: self.now) { home in
            try Self.writeAuth(
                to: home,
                refreshToken: "rt-next",
                accountID: "acct-second",
                expiresAt: Date(timeIntervalSince1970: 1_800_900_000))
        }
        #expect(outcome == .renewed)
    }

    @Test
    func `a renewal that comes back as another account is reported and leaves the registry alone`() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try Self.writeAuth(
            to: fixture.home,
            refreshToken: "rt-1",
            accountID: "acct-second",
            expiresAt: self.now.addingTimeInterval(-60))
        try fixture.saveAccount()
        let before = try Self.readStoredFingerprint(fixture)
        let outcome = await fixture.renew(now: self.now) { home in
            try Self.writeAuth(
                to: home,
                refreshToken: "rt-2",
                accountID: "acct-other",
                expiresAt: Date(timeIntervalSince1970: 1_800_900_000))
        }
        guard case .failed = outcome else {
            Issue.record("expected failure, got \(outcome)")
            return
        }
        #expect(try Self.readStoredFingerprint(fixture) == before)
    }

    @Test
    func `a CLI that leaves the login unchanged is a failure`() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try Self.writeAuth(
            to: fixture.home,
            refreshToken: "rt-1",
            accountID: "acct-second",
            expiresAt: self.now.addingTimeInterval(-60))
        try fixture.saveAccount()
        let outcome = await fixture.renew(now: self.now) { _ in }
        guard case .failed = outcome else {
            Issue.record("expected failure, got \(outcome)")
            return
        }
    }

    @Test
    func `renewal waits for another account writer instead of racing it`() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try Self.writeAuth(
            to: fixture.home,
            refreshToken: "rt-1",
            accountID: "acct-second",
            expiresAt: self.now.addingTimeInterval(-60))
        try fixture.saveAccount()
        let ready = Pipe()
        let release = Pipe()
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        holder.arguments = try [
            "-c",
            "import fcntl,sys; f=open(sys.argv[1],'w'); fcntl.flock(f,fcntl.LOCK_EX); "
                + "print('ready',flush=True); sys.stdin.read(1)",
            #require(fixture.store.lockURL).path,
        ]
        holder.environment = ["PATH": "/usr/bin:/bin"]
        holder.standardOutput = ready
        holder.standardInput = release
        try holder.run()
        defer { if holder.isRunning { holder.terminate() }; holder.waitUntilExit() }
        #expect(String(bytes: ready.fileHandleForReading.availableData, encoding: .utf8)?.contains("ready") == true)
        let outcome = await fixture.renew(now: self.now) { _ in Issue.record("renewal should not run") }
        #expect(outcome == .busy)
    }

    @Test
    func `due policy follows expiry, then the CLI's renewal age`() {
        func credentials(expiresAt: Date?, lastRefresh: Date?, apiKey: Bool = false) -> CodexOAuthCredentials {
            CodexOAuthCredentials(
                accessToken: "a",
                refreshToken: apiKey ? "" : "r",
                idToken: nil,
                accountId: nil,
                lastRefresh: lastRefresh,
                expiresAt: expiresAt,
                isAPIKey: apiKey)
        }
        let day: TimeInterval = 24 * 60 * 60
        #expect(ManagedCodexLoginRenewal.isDue(
            credentials(expiresAt: self.now.addingTimeInterval(day - 1), lastRefresh: nil), now: self.now))
        #expect(!ManagedCodexLoginRenewal.isDue(
            credentials(expiresAt: self.now.addingTimeInterval(day + 60), lastRefresh: nil), now: self.now))
        #expect(ManagedCodexLoginRenewal.isDue(
            credentials(expiresAt: nil, lastRefresh: self.now.addingTimeInterval(-8 * day)), now: self.now))
        #expect(!ManagedCodexLoginRenewal.isDue(
            credentials(expiresAt: nil, lastRefresh: self.now.addingTimeInterval(-day)), now: self.now))
        #expect(!ManagedCodexLoginRenewal.isDue(
            credentials(expiresAt: nil, lastRefresh: nil, apiKey: true), now: self.now))
    }
}

private final class LockedBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func set(_ value: Value) {
        self.lock.withLock { self.value = value }
    }

    func get() -> Value {
        self.lock.withLock { self.value }
    }
}
