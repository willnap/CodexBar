#if canImport(Darwin)
import Foundation

/// Every running process's arguments and starting environment, read once per process. Both are fixed when a process
/// starts, while reading them for every process on the Mac took about a second per scan, with several scans in each
/// Claude and Codex refresh. A process is read again while it is young (a runtime may still rename itself) and when
/// its pid is reused; its parent is always current.
final class DarwinProcessRecordCache: @unchecked Sendable {
    static let shared = DarwinProcessRecordCache()
    /// How long after its start a process is still read afresh on every scan.
    static let settlingTime: TimeInterval = 60

    private let lock = NSLock()
    private var settled: [Int32: AgentProcessRecord] = [:]

    func records(
        pids: [Int32],
        now: Date = Date(),
        bsdInfo: (Int32) -> (ppid: Int32, startTime: Date)? = DarwinProcessEnumerator.bsdInfo,
        read: (Int32) -> AgentProcessRecord? = { LocalAgentSessionScanner.darwinProcessRecord(pid: $0) })
        -> [AgentProcessRecord]
    {
        let known = self.lock.withLock { self.settled }
        var settled: [Int32: AgentProcessRecord] = [:]
        let records = pids.compactMap { pid -> AgentProcessRecord? in
            guard let info = bsdInfo(pid) else { return nil }
            let record: AgentProcessRecord
            if let cached = known[pid], cached.startedAt == info.startTime {
                record = cached.ppid == info.ppid ? cached : cached.withParent(info.ppid)
            } else {
                guard let fresh = read(pid) else { return nil }
                record = fresh
            }
            if let started = record.startedAt, now.timeIntervalSince(started) >= Self.settlingTime {
                settled[pid] = record
            }
            return record
        }
        self.lock.withLock { self.settled = settled }
        return records
    }
}
#endif
