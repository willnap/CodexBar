import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct NativeCodexDesktopHandoffTests {
    @Test
    func `a closed desktop app is switched without quitting or reopening it`() async {
        let system = FakeCodexDesktopSystem()
        let handoff = system.handoff()
        guard case let .ready(plan) = handoff.prepare(policy: .askToQuit) else {
            Issue.record("Expected a ready plan")
            return
        }
        let outcome = await handoff.run(plan) { system.install() }
        #expect(outcome == .switched(.notRunning))
        #expect(system.events == ["stop-own-session", "install"])
    }

    @Test
    func `an open desktop app quits before the login changes and reopens on the new login`() async {
        let system = FakeCodexDesktopSystem()
        system.startDesktop()
        let handoff = system.handoff()
        guard case let .ready(plan) = handoff.prepare(policy: .askToQuit) else {
            Issue.record("Expected a ready plan")
            return
        }
        let outcome = await handoff.run(plan) { system.install() }
        #expect(outcome == .switched(.relaunched(appServerStarted: true)))
        #expect(system.events == ["stop-own-session", "quit 100", "install", "launch"])
        // Nothing of the desktop app was alive when the login changed.
        #expect(system.desktopProcessesAtInstall == 0)
    }

    @Test
    func `a cancelled quit leaves the login and the open app untouched`() async {
        let system = FakeCodexDesktopSystem()
        system.startDesktop()
        system.quitBehavior = .cancelled
        let handoff = system.handoff()
        guard case let .ready(plan) = handoff.prepare(policy: .askToQuit) else {
            Issue.record("Expected a ready plan")
            return
        }
        let start = system.clock
        let outcome = await handoff.run(plan) { system.install() }
        guard case let .notSwitched(message) = outcome else {
            Issue.record("Expected no switch")
            return
        }
        #expect(message.contains("didn’t quit"))
        #expect(system.events == ["stop-own-session", "quit 100"])
        #expect(system.clock.timeIntervalSince(start) >= 20)
    }

    @Test
    func `an app server outliving its app times out and the closed app is reopened unchanged`() async {
        let system = FakeCodexDesktopSystem()
        system.startDesktop()
        system.quitBehavior = .appServerLingers
        let handoff = system.handoff()
        guard case let .ready(plan) = handoff.prepare(policy: .askToQuit) else {
            Issue.record("Expected a ready plan")
            return
        }
        let outcome = await handoff.run(plan) { system.install() }
        guard case let .notSwitched(message) = outcome else {
            Issue.record("Expected no switch")
            return
        }
        #expect(message.contains("didn’t stop in time"))
        #expect(system.events == ["stop-own-session", "quit 100", "launch"])
    }

    @Test
    func `a failed install reopens the app it closed`() async {
        let system = FakeCodexDesktopSystem()
        system.startDesktop()
        let handoff = system.handoff()
        guard case let .ready(plan) = handoff.prepare(policy: .askToQuit) else {
            Issue.record("Expected a ready plan")
            return
        }
        let outcome = await handoff.run(plan) {
            _ = system.install()
            return "Could not replace the login."
        }
        #expect(outcome == .notSwitched("Could not replace the login."))
        #expect(system.events == ["stop-own-session", "quit 100", "install", "launch"])
    }

    @Test
    func `a reopened app counts once launched and its app server is not required`() async {
        let system = FakeCodexDesktopSystem()
        system.startDesktop()
        system.relaunchStartsAppServer = false
        let handoff = system.handoff()
        guard case let .ready(plan) = handoff.prepare(policy: .askToQuit) else {
            Issue.record("Expected a ready plan")
            return
        }
        #expect(await handoff.run(plan) { system.install() } == .switched(.relaunched(appServerStarted: false)))
        system.reset(running: true)
        system.relaunchFails = true
        guard case let .ready(retry) = handoff.prepare(policy: .askToQuit) else {
            Issue.record("Expected a ready plan")
            return
        }
        #expect(await handoff.run(retry) { system.install() } == .switched(.notReopened))
    }

    @Test
    func `other Codex sessions block explicit switching and defer automatic switching`() {
        let system = FakeCodexDesktopSystem()
        system.addExternalCLI()
        let handoff = system.handoff()
        guard case let .refused(message) = handoff.prepare(policy: .askToQuit) else {
            Issue.record("Expected a refusal")
            return
        }
        #expect(message.contains("Codex CLI or IDE session"))
        guard case .deferred = handoff.prepare(policy: .never) else {
            Issue.record("Expected a deferral")
            return
        }
        #expect(system.events.isEmpty)
    }

    @Test
    func `a desktop app on another Codex home or with an unreadable environment is refused`() {
        for environment in [["CODEX_HOME": "/Users/fixture/other-codex", "HOME": "/Users/fixture"], nil] {
            let system = FakeCodexDesktopSystem()
            system.startDesktop()
            system.environment = environment
            guard case let .refused(message) = system.handoff().prepare(policy: .askToQuit) else {
                Issue.record("Expected a refusal")
                continue
            }
            #expect(message.contains("Codex home"))
            #expect(system.events.isEmpty)
        }
        let system = FakeCodexDesktopSystem()
        system.startDesktop()
        system.environment = ["CODEX_HOME": "/Users/fixture/.codex/"]
        guard case .ready = system.handoff().prepare(policy: .askToQuit) else {
            Issue.record("An explicit CODEX_HOME equal to the live home must be accepted")
            return
        }
    }

    @Test
    func `automatic switching never asks an open desktop app to quit`() {
        #expect(NativeCodexDesktopHandoff.quitPolicy == .never)
        let system = FakeCodexDesktopSystem()
        system.startDesktop()
        guard case let .deferred(message) = system.handoff().prepare(policy: NativeCodexDesktopHandoff.quitPolicy)
        else {
            Issue.record("Expected a deferral")
            return
        }
        #expect(message.contains("Auto Switch waits"))
        #expect(system.events.isEmpty)
    }

    @Test
    func `CodexBar's own probes drain before the desktop app is asked to quit`() async {
        let system = FakeCodexDesktopSystem()
        system.startDesktop()
        system.addOwnProbe(exitsAfter: 1)
        let handoff = system.handoff()
        guard case let .ready(plan) = handoff.prepare(policy: .askToQuit) else {
            Issue.record("Expected a ready plan")
            return
        }
        #expect(await handoff.run(plan) { system.install() } == .switched(.relaunched(appServerStarted: true)))

        let stuck = FakeCodexDesktopSystem()
        stuck.startDesktop()
        stuck.addOwnProbe(exitsAfter: nil)
        let stuckHandoff = stuck.handoff()
        guard case let .ready(stuckPlan) = stuckHandoff.prepare(policy: .askToQuit) else {
            Issue.record("Expected a ready plan")
            return
        }
        let outcome = await stuckHandoff.run(stuckPlan) { stuck.install() }
        #expect(outcome == .notSwitched("CodexBar is still checking Codex usage. Try again in a moment."))
        #expect(stuck.events == ["stop-own-session"])
    }

    @Test
    func `a symlinked live login is refused before anything changes`() {
        let system = FakeCodexDesktopSystem()
        system.symlinkedAuth = true
        guard case let .refused(message) = system.handoff().prepare(policy: .askToQuit) else {
            Issue.record("Expected a refusal")
            return
        }
        #expect(message.contains("symbolic link"))
    }

    @Test
    func `process census attributes each Codex binary to the login owner holding it`() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let processes = [
            CodexProcessRecord(
                pid: 100,
                parentPID: 1,
                executablePath: FakeCodexDesktopSystem.appBinary,
                startedAt: start),
            CodexProcessRecord(
                pid: 101,
                parentPID: 100,
                executablePath: FakeCodexDesktopSystem.serverBinary,
                startedAt: start),
            // A desktop configured with a custom CLI path still owns the server it spawned.
            CodexProcessRecord(pid: 102, parentPID: 100, executablePath: "/opt/custom/codex", startedAt: start),
            CodexProcessRecord(pid: 200, parentPID: 500, executablePath: "/usr/local/bin/node", startedAt: start),
            CodexProcessRecord(pid: 201, parentPID: 200, executablePath: "/usr/local/lib/codex", startedAt: start),
            CodexProcessRecord(pid: 300, parentPID: 1, executablePath: "/bin/zsh", startedAt: start),
            CodexProcessRecord(pid: 301, parentPID: 300, executablePath: "/opt/homebrew/bin/codex", startedAt: start),
            CodexProcessRecord(
                pid: 302,
                parentPID: 300,
                executablePath: "/opt/homebrew/bin/codex-helper",
                startedAt: start),
        ]
        let census = NativeCodexProcessCensus(
            processes: processes,
            desktopStarts: [100: start],
            bundlePaths: [FakeCodexDesktopSystem.bundle],
            ownPID: 500)
        #expect(census.desktopApps.map(\.pid) == [100])
        #expect(census.desktopCodex.map(\.pid) == [101, 102])
        #expect(census.ownCodex.map(\.pid) == [201])
        #expect(census.externalCodex.map(\.pid) == [301])
        // A reused process ID with a different start time is not the desktop app.
        let reused = NativeCodexProcessCensus(
            processes: processes,
            desktopStarts: [100: start.addingTimeInterval(-60)],
            bundlePaths: [],
            ownPID: 500)
        #expect(reused.desktopApps.isEmpty)
        #expect(reused.externalCodex.map(\.pid) == [101, 102, 301])
    }

    @Test
    func `the live auth file safety check recognizes only symbolic links`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-auth-symlink-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let regular = root.appendingPathComponent("regular.json")
        try Data("{}".utf8).write(to: regular)
        let link = root.appendingPathComponent("auth.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: regular)
        #expect(CodexLiveAuthFileSafety.isSymbolicLink(link))
        #expect(!CodexLiveAuthFileSafety.isSymbolicLink(regular))
        #expect(!CodexLiveAuthFileSafety.isSymbolicLink(root.appendingPathComponent("missing.json")))
    }
}

/// The real promotion transaction inside a desktop handoff: the outgoing login is saved before the target is
/// installed, and only once the desktop app has exited.
@Suite(.serialized, CodexCredentialFixtures())
@MainActor
struct NativeCodexDesktopHandoffPromotionTests {
    @Test
    func `rotated outgoing tokens are saved back to their account before the target is installed`() async throws {
        let container = try CodexAccountPromotionTestContainer(suiteName: "NativeCodexDesktopHandoff-save-back")
        defer { container.tearDown() }
        let target = try container.createManagedAccount(persistedEmail: "beta@example.com", authAccountID: "acct-beta")
        let outgoing = try container.createManagedAccount(
            persistedEmail: "alpha@example.com", authAccountID: "acct-alpha")
        try container.persistAccounts([target, outgoing])
        // The desktop refreshed the outgoing login since it was saved; the live copy is the newest.
        let rotated = try container.writeLiveOAuthAuthFile(
            email: "alpha@example.com", accountID: "acct-alpha", apiKey: "sk-rotated")
        #expect(try container.managedAuthData(for: outgoing) != rotated)

        let system = FakeCodexDesktopSystem()
        system.startDesktop()
        system.environment = ["CODEX_HOME": container.liveHomeURL.path]
        let handoff = system.handoff(liveHome: container.liveHomeURL)
        guard case let .ready(plan) = handoff.prepare(policy: .askToQuit) else {
            Issue.record("Expected a ready plan")
            return
        }
        let outcome = await handoff.run(plan) {
            _ = system.install()
            do {
                _ = try await container.makeService().promoteManagedAccount(id: target.id)
                return nil
            } catch {
                return error.localizedDescription
            }
        }

        #expect(outcome == .switched(.relaunched(appServerStarted: true)))
        #expect(system.desktopProcessesAtInstall == 0)
        let accounts = try container.loadAccounts().accounts
        let saved = try #require(accounts.first { $0.id == outgoing.id })
        #expect(accounts.count == 2)
        #expect(try container.managedAuthData(for: saved) == rotated)
        #expect(try container.liveAuthData() == container.managedAuthData(for: target))
    }

    @Test
    func `an outgoing login matching no saved account is archived instead of dropped`() async throws {
        let container = try CodexAccountPromotionTestContainer(suiteName: "NativeCodexDesktopHandoff-archive")
        defer { container.tearDown() }
        let target = try container.createManagedAccount(persistedEmail: "beta@example.com", authAccountID: "acct-beta")
        try container.persistAccounts([target])
        let orphan = try container.writeLiveOAuthAuthFile(email: "gamma@example.com", accountID: "acct-gamma")

        let system = FakeCodexDesktopSystem()
        let handoff = system.handoff(liveHome: container.liveHomeURL)
        guard case let .ready(plan) = handoff.prepare(policy: .askToQuit) else {
            Issue.record("Expected a ready plan")
            return
        }
        let outcome = await handoff.run(plan) {
            do {
                _ = try await container.makeService().promoteManagedAccount(id: target.id)
                return nil
            } catch {
                return error.localizedDescription
            }
        }

        #expect(outcome == .switched(.notRunning))
        let archived = try #require(container.loadAccounts().accounts.first { $0.email == "gamma@example.com" })
        #expect(try container.managedAuthData(for: archived) == orphan)
        #expect(try container.liveAuthData() == container.managedAuthData(for: target))
    }

    @Test
    func `the live login is never replaced through a symbolic link`() throws {
        let home = CodexCredentialFixtures.root.appendingPathComponent("symlinked-home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let elsewhere = home.appendingPathComponent("dotfiles-auth.json")
        let original = Data(#"{"fixture":"original"}"#.utf8)
        try original.write(to: elsewhere)
        try FileManager.default.createSymbolicLink(
            at: home.appendingPathComponent("auth.json"), withDestinationURL: elsewhere)

        #expect(throws: (any Error).self) {
            try DefaultCodexLiveAuthSwapper().swapLiveAuthData(Data(#"{"fixture":"new"}"#.utf8), liveHomeURL: home)
        }
        #expect(try Data(contentsOf: elsewhere) == original)
        #expect(CodexLiveAuthFileSafety.isSymbolicLink(home.appendingPathComponent("auth.json")))
    }
}

/// Scripted processes and a manual clock; it never inspects, quits or launches a real app.
@MainActor
final class FakeCodexDesktopSystem: NativeCodexDesktopSystem {
    enum QuitBehavior {
        case exits
        case cancelled
        case appServerLingers
    }

    static let bundle = "/Applications/ChatGPT.app"
    static let appBinary = "\(bundle)/Contents/MacOS/ChatGPT"
    static let serverBinary = "\(bundle)/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"

    let ownPID: Int32 = 500
    var clock = Date(timeIntervalSince1970: 1_800_000_000)
    var quitBehavior = QuitBehavior.exits
    var relaunchStartsAppServer = true
    var relaunchFails = false
    var symlinkedAuth = false
    var environment: [String: String]? = ["HOME": "/Users/fixture"]
    private(set) var events: [String] = []
    private(set) var desktopProcessesAtInstall: Int?
    private var processList: [CodexProcessRecord] = []
    private var desktops: [NativeCodexDesktopInstance] = []
    private var appExitAt: Date?
    private var serverExitAt: Date?
    private var ownProbeExitAt: Date?
    private var nextPID: Int32 = 110

    func handoff(liveHome: URL = URL(fileURLWithPath: "/Users/fixture/.codex", isDirectory: true))
        -> NativeCodexDesktopHandoff
    {
        NativeCodexDesktopHandoff(liveHome: liveHome, system: self)
    }

    func startDesktop() {
        self.addDesktop(appPID: 100, serverPID: 101, startedAt: self.clock.addingTimeInterval(-3600), server: true)
    }

    func reset(running: Bool) {
        self.events = []
        self.processList = []
        self.desktops = []
        if running { self.startDesktop() }
    }

    func addExternalCLI() {
        self.processList.append(.init(pid: 300, parentPID: 1, executablePath: "/bin/zsh", startedAt: self.clock))
        self.processList.append(.init(
            pid: 301, parentPID: 300, executablePath: "/opt/homebrew/bin/codex", startedAt: self.clock))
    }

    func addOwnProbe(exitsAfter seconds: TimeInterval?) {
        self.processList.append(.init(
            pid: 201, parentPID: self.ownPID, executablePath: "/opt/homebrew/bin/codex", startedAt: self.clock))
        self.ownProbeExitAt = seconds.map { self.clock.addingTimeInterval($0) }
    }

    func install() -> String? {
        self.events.append("install")
        self.desktopProcessesAtInstall = self.processList.count(where: {
            $0.executablePath.hasPrefix(Self.bundle + "/")
        })
        return nil
    }

    func runningDesktops() -> [NativeCodexDesktopInstance] {
        self.desktops
    }

    func installedDesktopBundlePath() -> String? {
        Self.bundle
    }

    func processes() -> [CodexProcessRecord]? {
        self.processList
    }

    func homeEnvironment(pid _: Int32) -> [String: String]? {
        self.environment
    }

    func isSymbolicLink(_: URL) -> Bool {
        self.symlinkedAuth
    }

    func stopOwnCLISession() async {
        self.events.append("stop-own-session")
    }

    func requestQuit(pid: Int32) -> Bool {
        self.events.append("quit \(pid)")
        switch self.quitBehavior {
        case .exits:
            self.appExitAt = self.clock.addingTimeInterval(2)
            self.serverExitAt = self.clock.addingTimeInterval(3)
        case .cancelled:
            break
        case .appServerLingers:
            self.appExitAt = self.clock.addingTimeInterval(1)
        }
        return true
    }

    func launchDesktop(bundlePath _: String) async -> Int32? {
        self.events.append("launch")
        guard !self.relaunchFails else { return nil }
        let pid = self.nextPID
        self.nextPID += 2
        self.addDesktop(appPID: pid, serverPID: pid + 1, startedAt: self.clock, server: self.relaunchStartsAppServer)
        return pid
    }

    func now() -> Date {
        self.clock
    }

    func sleep(seconds: TimeInterval) async {
        self.clock = self.clock.addingTimeInterval(seconds)
        if let appExitAt, appExitAt <= self.clock {
            self.processList.removeAll { $0.executablePath == Self.appBinary }
            self.desktops = []
            self.appExitAt = nil
        }
        if let serverExitAt, serverExitAt <= self.clock {
            self.processList.removeAll { $0.executablePath == Self.serverBinary }
            self.serverExitAt = nil
        }
        if let ownProbeExitAt, ownProbeExitAt <= self.clock {
            self.processList.removeAll { $0.parentPID == self.ownPID }
            self.ownProbeExitAt = nil
        }
    }

    private func addDesktop(appPID: Int32, serverPID: Int32, startedAt: Date, server: Bool) {
        self.desktops.append(.init(pid: appPID, bundlePath: Self.bundle))
        self.processList.append(.init(
            pid: appPID, parentPID: 1, executablePath: Self.appBinary, startedAt: startedAt))
        if server {
            self.processList.append(.init(
                pid: serverPID, parentPID: appPID, executablePath: Self.serverBinary, startedAt: startedAt))
        }
    }
}
