import Foundation
import Testing
@testable import CodexBarCore

struct NativeKimiLocalUsageTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func `turn usage preserves all token categories and exact time without aggregate double counting`() throws {
        let first = self.record(time: 1_799_999_900_125)
        let second = self.record(
            time: 1_799_999_950_625,
            input: 20)
        let aggregate = first.replacingOccurrences(
            of: "usage.record",
            with: "token_counting")
        let overall = first.replacingOccurrences(
            of: "\"turn\"",
            with: "\"session\"")
        let report = NativeKimiLocalUsageParser.snapshot(
            data: Data([
                first,
                first,
                second,
                aggregate,
                overall,
            ].joined(separator: "\n").utf8),
            now: self.now,
            bucketTimeZoneIdentifier: "UTC")
        #expect(report.last30DaysTokens == 112)
        #expect(report.last30DaysRequests == 2)
        let day = try #require(report.daily.first)
        #expect(day.inputTokens == 30)
        #expect(day.outputTokens == 14)
        #expect(day.cacheReadTokens == 62)
        #expect(day.cacheCreationTokens == 6)
        #expect(report.quotaSlices.map(\.timestamp) == [
            Date(timeIntervalSince1970: 1_799_999_900.125),
            Date(timeIntervalSince1970: 1_799_999_950.625),
        ])
        #expect(report.quotaSlices.map(\.totalTokens) == [
            51,
            61,
        ])
        #expect(report.last30DaysCostUSD == nil)
        #expect(day.costUSD == nil)
    }

    @Test func `invalid counters and timestamps cannot establish complete local history`() {
        let valid = self.record(time: 1_799_999_900_125)
        for invalid in [
            "true",
            "-1",
            "1.5",
            "9223372036854775808",
        ] {
            let bad = valid.replacingOccurrences(
                of: "\"inputOther\":10",
                with: "\"inputOther\":\(invalid)")
            let report = NativeKimiLocalUsageParser.snapshot(
                data: Data((valid + "\n" + bad).utf8),
                now: self.now,
                bucketTimeZoneIdentifier: "UTC")
            #expect(report.last30DaysTokens == 51)
            #expect(report.historyScanIsPartial)
        }
        let future = self.record(time: 1_800_000_100_000)
        let report = NativeKimiLocalUsageParser.snapshot(
            data: Data((valid + "\n" + future).utf8),
            now: self.now,
            bucketTimeZoneIdentifier: "UTC")
        #expect(report.quotaSlices.count == 1)
        // Local files cannot prove that this machine
        // retained every request for an entire month.
        #expect(!report.historyCoverageIsEstablished)
    }

    @Test func `bounded scans drain main and subagent wire files and deduplicate source copies`() async throws {
        let root = try self.fixtureRoot()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let first = self.record(time: 1_799_999_900_125) + "\n"
        let second = self.record(
            time: 1_799_999_950_625,
            input: 20) + "\n"
        try self.write(
            first + second,
            to: root.appendingPathComponent(
                "a/b/agents/main/wire.jsonl"))
        try self.write(
            first,
            to: root.appendingPathComponent(
                "a/b/agents/child/wire.jsonl"))
        try self.write(
            second,
            to: root.appendingPathComponent(
                "duplicate/b/agents/main/wire.jsonl"))
        let scanner = NativeKimiLocalUsageScanner(byteBudget: 64)
        let initial = try #require(await scanner.scan(
            sessionsRoot: root,
            now: self.now,
            bucketTimeZoneIdentifier: "UTC"))
        #expect(initial.historyScanIsPartial)
        #expect(await scanner.hasPendingWork)
        var final = initial
        for _ in 0..<100 {
            if await !(scanner.hasPendingWork) { break }
            final = try #require(await scanner.scan(
                sessionsRoot: root,
                now: self.now,
                bucketTimeZoneIdentifier: "UTC"))
        }
        #expect(await !(scanner.hasPendingWork))
        #expect(final.last30DaysTokens == 163)
        #expect(final.last30DaysRequests == 3)
        #expect(!final.historyScanIsPartial)
        try self.write(
            first + second + self.record(
                time: 1_799_999_999_250,
                input: 40) + "\n",
            to: root.appendingPathComponent(
                "a/b/agents/main/wire.jsonl"))
        for _ in 0..<100 {
            final = try #require(await scanner.scan(
                sessionsRoot: root,
                now: self.now,
                bucketTimeZoneIdentifier: "UTC"))
            if await !(scanner.hasPendingWork) { break }
        }
        #expect(final.last30DaysTokens == 244)
        #expect(final.quotaSlices.last?.timestamp == Date(timeIntervalSince1970: 1_799_999_999.250))
    }

    @Test func `an unfinished wire line remains partial and resumes after append`() async throws {
        let root = try self.fixtureRoot()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let url = root.appendingPathComponent(
            "a/b/agents/main/wire.jsonl")
        let event = self.record(time: 1_799_999_900_125)
        try self.write(
            String(event.prefix(40)),
            to: url)
        let scanner = NativeKimiLocalUsageScanner()
        let partial = try #require(await scanner.scan(
            sessionsRoot: root,
            now: self.now,
            bucketTimeZoneIdentifier: "UTC"))
        #expect(partial.historyScanIsPartial)
        #expect(partial.last30DaysTokens == nil)
        try self.write(
            event + "\n",
            to: url)
        let complete = try #require(await scanner.scan(
            sessionsRoot: root,
            now: self.now,
            bucketTimeZoneIdentifier: "UTC"))
        #expect(complete.last30DaysTokens == 51)
        #expect(!complete.historyScanIsPartial)
    }

    @Test func `matching records in separate sessions retain their distinct source identity`() async throws {
        let root = try self.fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let event = self.record(time: 1_799_999_900_125) + "\n"
        try self.write(event, to: root.appendingPathComponent("project/one/agents/main/wire.jsonl"))
        try self.write(event, to: root.appendingPathComponent("project/two/agents/main/wire.jsonl"))
        let scanner = NativeKimiLocalUsageScanner()
        let report = try #require(await scanner.scan(
            sessionsRoot: root,
            now: self.now,
            bucketTimeZoneIdentifier: "UTC"))
        #expect(report.last30DaysTokens == 102)
        #expect(report.last30DaysRequests == 2)
    }

    @Test func `a partial inventory cannot discard previously measured wire records`() async throws {
        let root = try self.fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let wire = root.appendingPathComponent("project/one/agents/main/wire.jsonl")
        try self.write(self.record(time: 1_799_999_900_125) + "\n", to: wire)
        let scanner = NativeKimiLocalUsageScanner()
        _ = await scanner.scan(sessionsRoot: root, now: self.now, bucketTimeZoneIdentifier: "UTC")
        try FileManager.default.removeItem(at: wire)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("unreadable-inventory"), withDestinationURL: root)
        let retained = try #require(await scanner.scan(
            sessionsRoot: root,
            now: self.now,
            bucketTimeZoneIdentifier: "UTC"))
        #expect(retained.last30DaysTokens == 51)
        #expect(retained.historyScanIsPartial)
    }

    @Test func `a changed sessions root never reuses another roots durable events`() async throws {
        let root = try self.fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first")
        let second = root.appendingPathComponent("second")
        let archive = root.appendingPathComponent("cache/history.json")
        try self.write(
            self.record(time: 1_799_999_900_125) + "\n",
            to: first.appendingPathComponent("project/one/agents/main/wire.jsonl"))
        try self.write(
            self.record(time: 1_799_999_950_625, input: 20) + "\n",
            to: second.appendingPathComponent("project/two/agents/main/wire.jsonl"))
        let scanner = NativeKimiLocalUsageScanner(archiveURL: archive)
        let initial = await scanner.scan(sessionsRoot: first, now: self.now, bucketTimeZoneIdentifier: "UTC")
        #expect(initial?.last30DaysTokens == 51)
        let firstArchive = try Data(contentsOf: archive)
        let changed = await scanner.scan(sessionsRoot: second, now: self.now, bucketTimeZoneIdentifier: "UTC")
        #expect(changed?.last30DaysTokens == 61)
        #expect(changed?.historyScanIsPartial == true)
        #expect(try Data(contentsOf: archive) == firstArchive)
        let restarted = NativeKimiLocalUsageScanner(archiveURL: archive)
        let reading = await restarted.scan(sessionsRoot: second, now: self.now, bucketTimeZoneIdentifier: "UTC")
        #expect(reading?.last30DaysTokens == 61)
        #expect(try Data(contentsOf: archive) == firstArchive)
        try FileManager.default.removeItem(at: first)
        let originalOwner = await restarted.scan(sessionsRoot: first, now: self.now, bucketTimeZoneIdentifier: "UTC")
        #expect(originalOwner?.last30DaysTokens == 51)
    }

    @Test func `canonical symlink root aliases restore the same owned archive`() async throws {
        let root = try self.fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions")
        let alias = root.appendingPathComponent("aliased-sessions")
        let archive = root.appendingPathComponent("cache/history.json")
        let wire = sessions.appendingPathComponent("project/one/agents/main/wire.jsonl")
        try self.write(self.record(time: 1_799_999_900_125) + "\n", to: wire)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: sessions)
        let scanner = NativeKimiLocalUsageScanner(archiveURL: archive)
        let initial = await scanner.scan(sessionsRoot: sessions, now: self.now, bucketTimeZoneIdentifier: "UTC")
        #expect(initial?.last30DaysTokens == 51)
        let document = try Data(contentsOf: archive)
        try FileManager.default.removeItem(at: wire)
        let restarted = NativeKimiLocalUsageScanner(archiveURL: archive)
        let restored = await restarted.scan(sessionsRoot: alias, now: self.now, bucketTimeZoneIdentifier: "UTC")
        #expect(restored?.last30DaysTokens == 51)
        #expect(restored?.historyScanIsPartial == false)
        #expect(try Data(contentsOf: archive) == document)
    }

    @Test func `sanitized token archive survives source rotation deletion and restart`() async throws {
        let root = try self.fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions")
        let archive = root.appendingPathComponent("cache/token-history.json")
        let wire = sessions.appendingPathComponent("project/one/agents/main/wire.jsonl")
        try self.write(self.record(time: 1_799_999_900_125) + "\n", to: wire)
        let scanner = NativeKimiLocalUsageScanner(archiveURL: archive)
        _ = await scanner.scan(sessionsRoot: sessions, now: self.now, bucketTimeZoneIdentifier: "UTC")
        // Same size and inode: only the later modification time identifies the rewritten source.
        try self.write(
            self.record(time: 1_799_999_950_625, input: 20) + "\n",
            to: wire,
            modified: self.now.addingTimeInterval(1))
        let rotated = try #require(await scanner.scan(
            sessionsRoot: sessions,
            now: self.now,
            bucketTimeZoneIdentifier: "UTC"))
        #expect(rotated.last30DaysTokens == 112)
        try FileManager.default.removeItem(at: sessions)
        let restarted = NativeKimiLocalUsageScanner(archiveURL: archive)
        let restored = try #require(await restarted.scan(
            sessionsRoot: sessions,
            now: self.now,
            bucketTimeZoneIdentifier: "UTC"))
        #expect(restored.last30DaysTokens == 112)
        #expect(restored.quotaSlices.map(\.timestamp) == [
            Date(timeIntervalSince1970: 1_799_999_900.125), Date(timeIntervalSince1970: 1_799_999_950.625),
        ])
        let document = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: archive)) as? [String: Any])
        #expect(Set(document.keys) == ["version", "sourceRootFingerprint", "events", "isPartial", "files"])
        #expect(document["version"] as? Int == 3)
        let owner = try #require(document["sourceRootFingerprint"] as? String)
        #expect(owner.count == 64)
        let hasHexadecimalOwner = owner.allSatisfy(\.isHexDigit)
        #expect(hasHexadecimalOwner)
        #expect(try String(data: Data(contentsOf: archive), encoding: .utf8)?.contains(root.path) == false)
        let events = try #require(document["events"] as? [[String: Any]])
        #expect(events.count == 2)
        #expect(events.allSatisfy { Set($0.keys) == [
            "fingerprint", "timestamp", "input", "output", "cacheRead", "cacheCreation",
        ] })
    }

    @Test func `unreadable and future archives are never overwritten by newly observed local records`() async throws {
        let root = try self.fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions")
        try self.write(
            self.record(time: 1_799_999_900_125) + "\n",
            to: sessions.appendingPathComponent("project/one/agents/main/wire.jsonl"))
        for existing in [
            Data("unreadable json".utf8),
            Data("{\"version\":1,\"events\":[],\"isPartial\":false}".utf8),
            Data("{\"version\":99,\"events\":[]}".utf8),
        ] {
            let archive = root.appendingPathComponent("cache.json")
            try existing.write(to: archive)
            let scanner = NativeKimiLocalUsageScanner(archiveURL: archive)
            let measured = try #require(await scanner.scan(
                sessionsRoot: sessions,
                now: self.now,
                bucketTimeZoneIdentifier: "UTC"))
            #expect(measured.last30DaysTokens == 51)
            #expect(measured.historyScanIsPartial)
            #expect(try Data(contentsOf: archive) == existing)
        }
    }

    private func record(
        time: Int64,
        input: Int = 10) -> String
    {
        """
        {"type":"usage.record","time":\(time),"usageScope":"turn",\
        "usage":{"inputOther":\(input),"output":7,"inputCacheRead":31,"inputCacheCreation":3}}
        """
    }

    private func fixtureRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true)
        return root
    }

    private func write(_ text: String, to url: URL, modified: Date? = nil) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        // Fixture records are dated relative to `now`; their files are last written at the same clock.
        try FileManager.default.setAttributes([.modificationDate: modified ?? self.now], ofItemAtPath: url.path)
    }
}
