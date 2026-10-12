#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation

/// One same-user process, with only what a shared `auth.json` change needs to know about it.
package struct CodexProcessRecord: Equatable, Sendable {
    package let pid: Int32
    package let parentPID: Int32
    package let executablePath: String
    package let startedAt: Date

    package init(pid: Int32, parentPID: Int32, executablePath: String, startedAt: Date) {
        self.pid = pid
        self.parentPID = parentPID
        self.executablePath = executablePath
        self.startedAt = startedAt
    }

    /// The CLI, IDE integrations and the desktop app's bundled app-server all run a native binary named `codex`.
    package var isCodexBinary: Bool {
        // Provider-specific by design: this is the Codex CLI's executable name.
        URL(fileURLWithPath: self.executablePath).lastPathComponent == "codex"
    }
}

/// Read-only process inspection for changing the shared Codex login.
/// It never reads arguments, and it decodes only the Codex home selectors from a process environment,
/// so no credential or token can be observed through it.
package enum CodexDesktopProcessProbe {
    package static let homeSelectorNames: Set<String> = ["CODEX_HOME", "HOME"]

    /// Processes owned by this user that have a readable executable path, or nil when the table is unreadable.
    package static func sameUserProcesses() -> [CodexProcessRecord]? {
        #if canImport(Darwin)
        let pids = DarwinProcessEnumerator.allPIDs()
        guard !pids.isEmpty else { return nil }
        let user = getuid()
        return pids.compactMap { pid in
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_uid == user,
                  let path = DarwinProcessEnumerator.executablePath(pid: pid)
            else { return nil }
            let started = TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000
            return CodexProcessRecord(
                pid: pid,
                parentPID: Int32(bitPattern: info.pbi_ppid),
                executablePath: path,
                startedAt: Date(timeIntervalSince1970: started))
        }
        #else
        return nil
        #endif
    }

    /// `CODEX_HOME` and `HOME` of a same-user process; nil when its environment cannot be read.
    package static func homeEnvironment(pid: Int32) -> [String: String]? {
        #if canImport(Darwin)
        DarwinProcessEnumerator.environment(pid: pid, names: self.homeSelectorNames)
        #else
        nil
        #endif
    }

    /// The Codex home a process resolves from its environment, the same way the CLI does.
    package static func codexHomePath(environment: [String: String]) -> String? {
        if let home = CodexHomeScope.normalizedHomePath(environment["CODEX_HOME"]) { return home }
        guard let userHome = CodexHomeScope.normalizedHomePath(environment["HOME"]) else { return nil }
        // Provider-specific by design: `.codex` is the CLI's default on-disk home contract.
        return URL(fileURLWithPath: userHome, isDirectory: true).appendingPathComponent(".codex").path
    }

    /// Ends CodexBar's own long-lived Codex CLI status session so it cannot keep an outgoing login in memory.
    package static func stopCodexBarCLISession() async {
        await CodexCLISession.shared.reset()
    }
}

/// The live login is replaced by renaming a new file over `auth.json`. A symbolic link there belongs to
/// someone else's setup, and replacing it would silently detach that setup, so the switch refuses instead.
package enum CodexLiveAuthFileSafety {
    package static func isSymbolicLink(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFLNK
    }
}
