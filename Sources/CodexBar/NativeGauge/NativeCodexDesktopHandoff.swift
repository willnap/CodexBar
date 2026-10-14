import AppKit
import CodexBarCore
import Foundation

/// Whether a Codex login change may ask the desktop app to quit. Only the explicit "Use in …" action grants it;
/// every other caller, Auto Switch included, keeps the default and defers while the desktop app is open.
enum NativeCodexDesktopQuitPolicy: Equatable {
    case never
    case askToQuit
}

/// A running instance of the Codex desktop app (shipped as ChatGPT.app, bundle identifier `com.openai.codex`).
struct NativeCodexDesktopInstance: Equatable {
    let pid: Int32
    let bundlePath: String
}

/// Every process and app interaction of a handoff, so tests never inspect, quit or launch the real desktop app.
@MainActor
protocol NativeCodexDesktopSystem {
    var ownPID: Int32 { get }
    func runningDesktops() -> [NativeCodexDesktopInstance]
    func installedDesktopBundlePath() -> String?
    func processes() -> [CodexProcessRecord]?
    func homeEnvironment(pid: Int32) -> [String: String]?
    func isSymbolicLink(_ url: URL) -> Bool
    func stopOwnCLISession() async
    func requestQuit(pid: Int32) -> Bool
    /// Returns the launched app's process identifier.
    func launchDesktop(bundlePath: String) async -> Int32?
    func now() -> Date
    func sleep(seconds: TimeInterval) async
}

/// Codex processes, grouped by who owns the login each one holds in memory.
struct NativeCodexProcessCensus: Equatable {
    private(set) var desktopApps: [CodexProcessRecord] = []
    private(set) var desktopCodex: [CodexProcessRecord] = []
    private(set) var ownCodex: [CodexProcessRecord] = []
    private(set) var externalCodex: [CodexProcessRecord] = []

    /// `desktopStarts` pins each desktop process to its start time, so a reused process ID is not mistaken for it.
    init(
        processes: [CodexProcessRecord],
        desktopStarts: [Int32: Date],
        bundlePaths: [String],
        ownPID: Int32)
    {
        let parents = Dictionary(processes.map { ($0.pid, $0.parentPID) }, uniquingKeysWith: { first, _ in first })
        func descends(_ pid: Int32, from roots: Set<Int32>) -> Bool {
            var current = pid
            for _ in 0..<64 {
                guard let parent = parents[current], parent > 1, parent != current else { return false }
                if roots.contains(parent) { return true }
                current = parent
            }
            return false
        }
        self.desktopApps = processes.filter { process in
            desktopStarts[process.pid].map { $0 == process.startedAt } ?? false
        }
        let desktopPIDs = Set(self.desktopApps.map(\.pid))
        let bundles = bundlePaths.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path + "/" }
        for process in processes where process.isCodexBinary {
            if bundles.contains(where: process.executablePath.hasPrefix) || descends(process.pid, from: desktopPIDs) {
                self.desktopCodex.append(process)
            } else if descends(process.pid, from: [ownPID]) {
                self.ownCodex.append(process)
            } else {
                self.externalCodex.append(process)
            }
        }
    }
}

/// Moves the Codex desktop app along with a change of the shared `~/.codex/auth.json` login.
///
/// The desktop's bundled `codex app-server` reads `auth.json` once when it starts and keeps that login in memory,
/// so a file change alone only switches the CLI. Explicit switching therefore asks the app to quit (honoring its own
/// confirmation), waits until the app and every app-server it owns have exited, installs the new login, and reopens
/// the app only when the switch closed it. Automatic switching never quits the app; it defers instead.
@MainActor
struct NativeCodexDesktopHandoff {
    @TaskLocal static var quitPolicy: NativeCodexDesktopQuitPolicy = .never
    static let bundleIdentifier = "com.openai.codex"

    /// The installed desktop app's name ("ChatGPT"), or nil when it is not installed.
    static let desktopAppName: String? = NSWorkspace.shared
        .urlForApplication(withBundleIdentifier: NativeCodexDesktopHandoff.bundleIdentifier)
        .map { FileManager.default.displayName(atPath: $0.path) }
        .map { $0.hasSuffix(".app") ? String($0.dropLast(4)) : $0 }

    /// What a Codex login change applies to, as shown in the account menu.
    static var loginTargetName: String {
        desktopAppName.map { "\($0) & Codex CLI" } ?? "Codex CLI"
    }

    struct Plan: Equatable {
        let desktops: [NativeCodexDesktopInstance]
        let desktopStarts: [Int32: Date]
        let bundlePaths: [String]
    }

    enum Preparation: Equatable {
        case ready(Plan)
        /// Nothing was changed, and retrying unchanged would fail the same way.
        case refused(String)
        /// Nothing was changed; an automatic caller may retry once the desktop app or CLI session is gone.
        case deferred(String)
    }

    enum DesktopResult: Equatable {
        case notRunning
        case relaunched(appServerStarted: Bool)
        case notReopened
    }

    enum Outcome: Equatable {
        case switched(DesktopResult)
        /// No login was changed. A desktop app this handoff closed was reopened.
        case notSwitched(String)
    }

    let liveHome: URL
    var system: any NativeCodexDesktopSystem = LiveNativeCodexDesktopSystem()
    var quitTimeout: TimeInterval = 20
    var probeDrainTimeout: TimeInterval = 10
    var relaunchTimeout: TimeInterval = 30
    /// How long to watch for the reopened app's Codex server. Nothing waits on it: every earlier server had exited
    /// before the install, so whichever starts reads the new login. The switch is done once the app is back.
    var appServerGrace: TimeInterval = 0
    var pollInterval: TimeInterval = 0.25

    private var appName: String {
        Self.desktopAppName ?? "The Codex app"
    }

    /// Non-mutating checks that run before any login or profile is touched.
    func prepare(policy: NativeCodexDesktopQuitPolicy) -> Preparation {
        guard let processes = self.system.processes() else {
            return .refused("Could not check which Codex processes are running.")
        }
        guard !self.system.isSymbolicLink(CodexAuthFingerprint.authFileURL(homePath: self.liveHome.path)) else {
            return .refused("Codex’s auth.json is a symbolic link, so CodexBar won’t replace it.")
        }
        let running = self.system.runningDesktops()
        var bundlePaths = running.map(\.bundlePath)
        if let installed = self.system.installedDesktopBundlePath(), !bundlePaths.contains(installed) {
            bundlePaths.append(installed)
        }
        let starts = Dictionary(
            processes.filter { process in running.contains { $0.pid == process.pid } }.map { ($0.pid, $0.startedAt) },
            uniquingKeysWith: { first, _ in first })
        // Waiting for the app to exit relies on its process record; an unlisted instance cannot be tracked.
        guard running.allSatisfy({ starts[$0.pid] != nil }) else {
            return .refused("Could not check which Codex processes are running.")
        }
        let census = NativeCodexProcessCensus(
            processes: processes, desktopStarts: starts, bundlePaths: bundlePaths, ownPID: self.system.ownPID)
        guard census.externalCodex.isEmpty else {
            let message = "Close the running Codex CLI or IDE session first. It keeps the current login in memory."
            return policy == .askToQuit ? .refused(message) : .deferred(message)
        }
        guard !running.isEmpty || !census.desktopCodex.isEmpty else {
            return .ready(Plan(desktops: [], desktopStarts: [:], bundlePaths: bundlePaths))
        }
        for pid in Set(running.map(\.pid) + census.desktopCodex.map(\.pid)).sorted() {
            guard let environment = self.system.homeEnvironment(pid: pid),
                  let home = CodexDesktopProcessProbe.codexHomePath(environment: environment)
            else { return .refused("Could not verify which Codex home \(self.appName) uses.") }
            guard Self.samePath(home, self.liveHome.path) else {
                return .refused(
                    "\(self.appName) uses a different Codex home (CODEX_HOME), so switching here wouldn’t change it.")
            }
        }
        guard !running.isEmpty else {
            let message = "\(self.appName)’s Codex server is still running. Try again in a moment."
            return policy == .askToQuit ? .refused(message) : .deferred(message)
        }
        guard policy == .askToQuit else {
            return .deferred(
                "\(self.appName) is open. Auto Switch waits until it quits, because switching restarts it.")
        }
        return .ready(Plan(desktops: running, desktopStarts: starts, bundlePaths: bundlePaths))
    }

    /// Quits the desktop app if the plan includes it, runs `install` (returning an error message, or nil once the
    /// new login is in place), then reopens the app the handoff closed.
    func run(_ plan: Plan, install: () async -> String?) async -> Outcome {
        await self.system.stopOwnCLISession()
        guard await self.waitUntil(plan, timeout: self.probeDrainTimeout, { $0.ownCodex.isEmpty }) else {
            return .notSwitched("CodexBar is still checking Codex usage. Try again in a moment.")
        }
        if !plan.desktops.isEmpty {
            let requested = plan.desktops.map { self.system.requestQuit(pid: $0.pid) }
            let exited = requested.contains(true) ? await self.waitUntil(plan, timeout: self.quitTimeout) {
                $0.desktopApps.isEmpty && $0.desktopCodex.isEmpty
            } : false
            guard exited else {
                let appOpen = self.census(plan).map { !$0.desktopApps.isEmpty } ?? true
                if !appOpen { await self.reopen(plan) }
                return .notSwitched(appOpen
                    ? "\(self.appName) didn’t quit. If it asked to confirm, answer it, then try again. " +
                    "No account was changed."
                    : "\(self.appName)’s Codex server didn’t stop in time. No account was changed.")
            }
            // A probe that started while the app was quitting must not hold the outgoing login either.
            let quiet = await self.waitUntil(plan, timeout: self.probeDrainTimeout) {
                $0.ownCodex.isEmpty && $0.externalCodex.isEmpty
            }
            guard quiet else {
                await self.reopen(plan)
                return .notSwitched("A Codex session started while switching. No account was changed.")
            }
        }
        let installedAt = self.system.now()
        if let error = await install() {
            if !plan.desktops.isEmpty { await self.reopen(plan) }
            return .notSwitched(error)
        }
        guard !plan.desktops.isEmpty else { return .switched(.notRunning) }
        guard let bundle = plan.bundlePaths.first, let pid = await self.system.launchDesktop(bundlePath: bundle)
        else { return .switched(.notReopened) }
        return await .switched(self.verifyRelaunch(pid: pid, plan: plan, after: installedAt))
    }

    /// The app counts as reopened once a process started after the install; its app-server, once one exists,
    /// necessarily read the new file because every earlier app-server had exited before the install.
    private func verifyRelaunch(pid: Int32, plan: Plan, after installedAt: Date) async -> DesktopResult {
        let deadline = self.system.now().addingTimeInterval(self.relaunchTimeout)
        var serverDeadline: Date?
        while true {
            if let processes = self.system.processes() {
                let starts = Dictionary(
                    processes.filter { $0.pid == pid && $0.startedAt >= installedAt }.map { ($0.pid, $0.startedAt) },
                    uniquingKeysWith: { first, _ in first })
                let census = NativeCodexProcessCensus(
                    processes: processes,
                    desktopStarts: starts,
                    bundlePaths: plan.bundlePaths,
                    ownPID: self.system.ownPID)
                if !census.desktopApps.isEmpty {
                    if census.desktopCodex.contains(where: { $0.startedAt >= installedAt }) {
                        return .relaunched(appServerStarted: true)
                    }
                    serverDeadline = serverDeadline ?? self.system.now().addingTimeInterval(self.appServerGrace)
                }
            }
            let now = self.system.now()
            if let serverDeadline, now >= serverDeadline { return .relaunched(appServerStarted: false) }
            if serverDeadline == nil, now >= deadline { return .notReopened }
            await self.system.sleep(seconds: self.pollInterval)
        }
    }

    private func reopen(_ plan: Plan) async {
        guard self.system.runningDesktops().isEmpty, let bundle = plan.bundlePaths.first else { return }
        _ = await self.system.launchDesktop(bundlePath: bundle)
    }

    private func census(_ plan: Plan) -> NativeCodexProcessCensus? {
        self.system.processes().map {
            NativeCodexProcessCensus(
                processes: $0,
                desktopStarts: plan.desktopStarts,
                bundlePaths: plan.bundlePaths,
                ownPID: self.system.ownPID)
        }
    }

    private func waitUntil(
        _ plan: Plan,
        timeout: TimeInterval,
        _ condition: (NativeCodexProcessCensus) -> Bool) async -> Bool
    {
        let deadline = self.system.now().addingTimeInterval(timeout)
        while true {
            if let census = self.census(plan), condition(census) { return true }
            guard self.system.now() < deadline else { return false }
            await self.system.sleep(seconds: self.pollInterval)
        }
    }

    private static func samePath(_ lhs: String, _ rhs: String) -> Bool {
        URL(fileURLWithPath: lhs).resolvingSymlinksInPath().standardizedFileURL.path ==
            URL(fileURLWithPath: rhs).resolvingSymlinksInPath().standardizedFileURL.path
    }
}

@MainActor
struct LiveNativeCodexDesktopSystem: NativeCodexDesktopSystem {
    var ownPID: Int32 {
        getpid()
    }

    func runningDesktops() -> [NativeCodexDesktopInstance] {
        NSRunningApplication.runningApplications(withBundleIdentifier: NativeCodexDesktopHandoff.bundleIdentifier)
            .filter { !$0.isTerminated }
            .compactMap { app in
                app.bundleURL.map { NativeCodexDesktopInstance(pid: app.processIdentifier, bundlePath: $0.path) }
            }
    }

    func installedDesktopBundlePath() -> String? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: NativeCodexDesktopHandoff.bundleIdentifier)?.path
    }

    func processes() -> [CodexProcessRecord]? {
        CodexDesktopProcessProbe.sameUserProcesses()
    }

    func homeEnvironment(pid: Int32) -> [String: String]? {
        CodexDesktopProcessProbe.homeEnvironment(pid: pid)
    }

    func isSymbolicLink(_ url: URL) -> Bool {
        CodexLiveAuthFileSafety.isSymbolicLink(url)
    }

    func stopOwnCLISession() async {
        await CodexDesktopProcessProbe.stopCodexBarCLISession()
    }

    func requestQuit(pid: Int32) -> Bool {
        // An ordinary quit: the app may ask to confirm running chats, and the user can cancel it there.
        NSRunningApplication(processIdentifier: pid)?.terminate() ?? false
    }

    func launchDesktop(bundlePath: String) async -> Int32? {
        // The default configuration gives the app its normal launch environment, like `open -b`.
        let configuration = NSWorkspace.OpenConfiguration()
        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.openApplication(
                at: URL(fileURLWithPath: bundlePath, isDirectory: true),
                configuration: configuration)
            { app, _ in
                continuation.resume(returning: app?.processIdentifier)
            }
        }
    }

    func now() -> Date {
        Date()
    }

    func sleep(seconds: TimeInterval) async {
        try? await Task.sleep(for: .seconds(seconds))
    }
}
