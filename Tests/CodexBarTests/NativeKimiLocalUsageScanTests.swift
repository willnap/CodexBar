import Foundation
import Testing
@testable import CodexBarCore

/// Throughput, persistence and coverage of the Kimi wire scanner (recency order, stale-file skipping,
/// persisted cursors and established coverage after a complete scan).
struct NativeKimiLocalUsageScanTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func `the first pass publishes the newest session before older large files`() async throws {
        let root = try self.fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // Forty older sessions sort before the active one by path and each exceeds the per-pass budget share.
        let filler = String(repeating: "{\"type\":\"message\",\"text\":\"filler\"}\n", count: 8000)
        for index in 0..<40 {
            let old = self.record(time: 1_799_000_000_000 + Int64(index)) + "\n"
            try self.write(
                old + filler,
                to: root.appendingPathComponent(String(format: "a%02d/s/agents/main/wire.jsonl", index)),
                modified: self.now.addingTimeInterval(-Double(86400 + index)))
        }
        try self.write(
            self.record(time: 1_799_999_900_125) + "\n",
            to: root.appendingPathComponent("z-active/s/agents/main/wire.jsonl"),
            modified: self.now.addingTimeInterval(-60))
        let scanner = NativeKimiLocalUsageScanner(byteBudget: 2 * 1024 * 1024)
        let first = try #require(await scanner.scan(sessionsRoot: root, now: self.now, bucketTimeZoneIdentifier: "UTC"))
        #expect(first.daily.last?.date == "2027-01-15")
        #expect(first.daily.last?.totalTokens == 51)
        var final = first
        var passes = 1
        while await scanner.hasPendingWork, passes < 100 {
            final = try #require(await scanner.scan(sessionsRoot: root, now: self.now, bucketTimeZoneIdentifier: "UTC"))
            passes += 1
        }
        #expect(final.last30DaysRequests == 41)
        #expect(final.last30DaysTokens == 41 * 51)
        // About 11.5 MB at 2 MiB per pass: whole files are read, so passes are bounded by bytes alone.
        #expect(passes <= 7)
    }

    @Test func `files last written before the retention window are not read`() async throws {
        let root = try self.fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let stale = root.appendingPathComponent("old/s/agents/main/wire.jsonl")
        // The record claims a recent time, which a file last written 40 days ago cannot actually contain.
        try self.write(
            self.record(time: 1_799_999_900_125) + "\n",
            to: stale,
            modified: self.now.addingTimeInterval(-40 * 86400))
        let scanner = NativeKimiLocalUsageScanner(byteBudget: 16)
        let report = try #require(await scanner.scan(
            sessionsRoot: root,
            now: self.now,
            bucketTimeZoneIdentifier: "UTC"))
        #expect(await !(scanner.hasPendingWork))
        #expect(report.last30DaysTokens == nil)
        #expect(report.historyIsFullyScanned)
        // Appending makes the file current again; only the appended bytes are read.
        let appended = self.record(time: 1_799_999_950_625, input: 20) + "\n"
        let handle = try FileHandle(forWritingTo: stale)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(appended.utf8))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: self.now], ofItemAtPath: stale.path)
        var current = report
        for _ in 0..<20 {
            current = try #require(await scanner.scan(
                sessionsRoot: root,
                now: self.now,
                bucketTimeZoneIdentifier: "UTC"))
            if await !(scanner.hasPendingWork) { break }
        }
        #expect(current.last30DaysTokens == 61)
        #expect(current.last30DaysRequests == 1)
    }

    @Test func `a completed scan establishes coverage and a pass with pending work does not`() async throws {
        let root = try self.fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try self.write(
            self.record(time: 1_799_999_900_125) + "\n" + self.record(time: 1_799_999_950_625, input: 20) + "\n",
            to: root.appendingPathComponent("p/s/agents/main/wire.jsonl"))
        let scanner = NativeKimiLocalUsageScanner(byteBudget: 64)
        let partial = try #require(await scanner.scan(
            sessionsRoot: root,
            now: self.now,
            bucketTimeZoneIdentifier: "UTC"))
        #expect(await scanner.hasPendingWork)
        #expect(!partial.historyIsFullyScanned)
        var final = partial
        for _ in 0..<100 {
            if await !(scanner.hasPendingWork) { break }
            final = try #require(await scanner.scan(
                sessionsRoot: root,
                now: self.now,
                bucketTimeZoneIdentifier: "UTC"))
        }
        #expect(final.historyCoverageIsEstablished)
        #expect(final.historyIsFullyScanned)
        #expect(final.last30DaysTokens == 112)
    }

    @Test func `a restarted scanner resumes from persisted cursors and reads only appended bytes`() async throws {
        let root = try self.fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions")
        let archive = root.appendingPathComponent("cache/history.json")
        let growing = sessions.appendingPathComponent("p/one/agents/main/wire.jsonl")
        let stable = sessions.appendingPathComponent("p/two/agents/main/wire.jsonl")
        try self.write(self.record(time: 1_799_999_900_125) + "\n", to: growing)
        try self.write(self.record(time: 1_799_999_910_125, input: 30) + "\n", to: stable)
        let first = NativeKimiLocalUsageScanner(archiveURL: archive)
        let initial = try #require(await first.scan(
            sessionsRoot: sessions,
            now: self.now,
            bucketTimeZoneIdentifier: "UTC"))
        #expect(initial.last30DaysTokens == 51 + 71)
        let document = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: archive)) as? [String: Any])
        #expect(document["version"] as? Int == 3)
        let cursors = try #require(document["files"] as? [String: [String: Any]])
        #expect(cursors.count == 2)
        #expect(try String(data: Data(contentsOf: archive), encoding: .utf8)?.contains("wire.jsonl") == false)
        // Rewrite the consumed first line in place with a different valid record of the same length, then
        // append. Re-reading consumed bytes would surface the substituted record (131 tokens).
        let appended = self.record(time: 1_799_999_950_625, input: 20) + "\n"
        try self.write(self.record(time: 1_799_999_900_125, input: 90) + "\n" + appended, to: growing)
        let restarted = NativeKimiLocalUsageScanner(byteBudget: 1024, archiveURL: archive)
        let resumed = try #require(await restarted.scan(
            sessionsRoot: sessions,
            now: self.now,
            bucketTimeZoneIdentifier: "UTC"))
        #expect(await !(restarted.hasPendingWork))
        #expect(resumed.last30DaysTokens == 51 + 71 + 61)
        #expect(resumed.last30DaysRequests == 3)
        #expect(resumed.historyIsFullyScanned)
        // A replaced file (new inode) resets its cursor and is read from the start; retained events stay.
        let replacement = sessions.appendingPathComponent("p/two/agents/main/replacement")
        try self.write(self.record(time: 1_799_999_960_125, input: 40) + "\n", to: replacement)
        _ = try FileManager.default.replaceItemAt(stable, withItemAt: replacement)
        try FileManager.default.setAttributes([.modificationDate: self.now], ofItemAtPath: stable.path)
        let rotated = try #require(await restarted.scan(
            sessionsRoot: sessions,
            now: self.now,
            bucketTimeZoneIdentifier: "UTC"))
        #expect(rotated.last30DaysTokens == 51 + 71 + 61 + 81)
    }

    @Test func `version two archives migrate their events instead of being rejected`() async throws {
        let root = try self.fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions")
        let archive = root.appendingPathComponent("cache/history.json")
        let wire = sessions.appendingPathComponent("p/one/agents/main/wire.jsonl")
        try self.write(self.record(time: 1_799_999_900_125) + "\n", to: wire)
        let writer = NativeKimiLocalUsageScanner(archiveURL: archive)
        _ = await writer.scan(sessionsRoot: sessions, now: self.now, bucketTimeZoneIdentifier: "UTC")
        var document = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: archive)) as? [String: Any])
        document["version"] = 2
        document.removeValue(forKey: "files")
        try JSONSerialization.data(withJSONObject: document).write(to: archive)
        try FileManager.default.removeItem(at: wire)
        let migrated = NativeKimiLocalUsageScanner(archiveURL: archive)
        let report = try #require(await migrated.scan(
            sessionsRoot: sessions,
            now: self.now,
            bucketTimeZoneIdentifier: "UTC"))
        #expect(report.last30DaysTokens == 51)
        let rewritten = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: archive)) as? [String: Any])
        #expect(rewritten["version"] as? Int == 3)
        #expect((rewritten["events"] as? [Any])?.count == 1)
    }

    /// Read-only measurement of this Mac's real Kimi corpus, run only on request:
    /// `KIMI_REAL_CORPUS_HARNESS=1 swift test --skip-build --filter NativeKimiLocalUsageScanTests`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["KIMI_REAL_CORPUS_HARNESS"] == "1"))
    func `real corpus convergence harness`() async throws {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kimi-code/sessions")
        let scratch = try self.fixtureRoot()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let archive = scratch.appendingPathComponent("archive.json")
        let zone = "Europe/London"
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: zone))
        func report(_ label: String, _ snapshot: CostUsageTokenSnapshot, seconds: Double) {
            let periods = [1, 7, 30].map { days in
                let summary = snapshot.summary(forLastDays: days, calendar: calendar)
                let cost = summary.totalCostUSD.map { String(format: "$%.2f", $0) } ?? "nil"
                return "\(days)d=\(summary.totalTokens ?? -1)/\(summary.totalRequests ?? -1) \(cost)"
            }
            print("KIMI-HARNESS \(label) \(String(format: "%.2fs", seconds)) " + periods.joined(separator: " ")
                + " partial=\(snapshot.historyScanIsPartial) coverage=\(snapshot.historyCoverageIsEstablished)")
        }
        func timed(_ scanner: NativeKimiLocalUsageScanner) async throws -> (CostUsageTokenSnapshot, Double) {
            let start = Date()
            let snapshot = try #require(await scanner.scan(
                sessionsRoot: root,
                now: Date(),
                bucketTimeZoneIdentifier: zone))
            return (snapshot, Date().timeIntervalSince(start))
        }
        let cold = NativeKimiLocalUsageScanner(
            byteBudget: 64 * 1024 * 1024,
            archiveURL: archive,
            pricingCatalog: { CostUsagePricing.modelsDevCatalog() })
        var passes = 0
        repeat {
            let (snapshot, seconds) = try await timed(cold)
            passes += 1
            report("cold pass \(passes)", snapshot, seconds: seconds)
        } while await cold.hasPendingWork && passes < 200
        let warm = NativeKimiLocalUsageScanner(
            byteBudget: 64 * 1024 * 1024,
            archiveURL: archive,
            pricingCatalog: { CostUsagePricing.modelsDevCatalog() })
        let (relaunch, seconds) = try await timed(warm)
        await report("relaunch pass 1 (pending=\(warm.hasPendingWork))", relaunch, seconds: seconds)
        let size = try FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? NSNumber
        print("KIMI-HARNESS archive bytes=\(size?.intValue ?? -1)")
    }

    private func record(time: Int64, input: Int = 10) -> String {
        """
        {"type":"usage.record","time":\(time),"usageScope":"turn",\
        "usage":{"inputOther":\(input),"output":7,"inputCacheRead":31,"inputCacheCreation":3}}
        """
    }

    private func fixtureRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ text: String, to url: URL, modified: Date? = nil) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        // Fixture records are dated relative to `now`; their files are last written at the same clock.
        try FileManager.default.setAttributes([.modificationDate: modified ?? self.now], ofItemAtPath: url.path)
    }
}
