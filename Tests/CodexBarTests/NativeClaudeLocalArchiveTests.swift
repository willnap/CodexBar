import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct NativeClaudeLocalArchiveTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test
    func `archive validates fractions and timestamps without inventing readings`() throws {
        let data = Data("""
        {"dataPoints":[
          {"timestamp":"2027-01-15T07:00:00.125Z","pct5h":0.25,"pct7d":0.9},
          {"timestamp":"not a date","pct5h":0,"pct7d":0},
          {"timestamp":"2027-01-15T07:01:00Z","pct5h":-0.01,"pct7d":0},
          {"timestamp":"2027-01-15T07:02:00Z","pct5h":true,"pct7d":0},
          {"timestamp":"2027-01-15T07:03:00Z","pct5h":0},
          {"timestamp":"2028-01-15T07:00:00Z","pct5h":0,"pct7d":0}
        ]}
        """.utf8)
        let points = try NativeClaudeLocalArchive.parse(data, now: self.now)
        #expect(points.count == 1)
        #expect(points.first?.sessionUsedFraction == 0.25)
        #expect(points.first?.weeklyUsedFraction == 0.9)
        #expect(points.first?.timestamp.timeIntervalSince1970 == 1_799_996_400.125)
    }

    @Test
    func `archive cache retains pruned observations across reader instances with exact dates`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("home/.config/claude-usage-bar/history.json")
        let cache = root.appendingPathComponent("cache/archive.json")
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data("""
        {"dataPoints":[{"timestamp":"2027-01-15T07:00:00.125Z","pct5h":0.25,"pct7d":0.9}]}
        """.utf8).write(to: source)
        let first = await NativeClaudeLocalArchive(sourceURL: source, cacheURL: cache).load(now: self.now)
        #expect(first.count == 1)
        try Data("""
        {"dataPoints":[{"timestamp":"2027-01-15T08:00:00Z","pct5h":0.5,"pct7d":1}]}
        """.utf8).write(to: source)
        let second = await NativeClaudeLocalArchive(sourceURL: source, cacheURL: cache).load(now: self.now)
        #expect(second.count == 2)
        #expect(second.first == first.first)
        try Data("invalid".utf8).write(to: source)
        let recovered = await NativeClaudeLocalArchive(sourceURL: source, cacheURL: cache).load(now: self.now)
        #expect(recovered == second)
        let expired = await NativeClaudeLocalArchive(sourceURL: source, cacheURL: cache)
            .load(now: self.now.addingTimeInterval(33 * 86400))
        #expect(expired.isEmpty)
    }

    @Test
    func `current source wins duplicate timestamps and archive stays outside owned accounts`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("history.json")
        let cache = root.appendingPathComponent("cache.json")
        let reader = NativeClaudeLocalArchive(sourceURL: source, cacheURL: cache)
        for fraction in [0.25, 0.5] {
            try Data("""
            {"dataPoints":[{"timestamp":"2027-01-15T08:00:00Z","pct5h":\(fraction),"pct7d":1}]}
            """.utf8).write(to: source)
            _ = await reader.load(now: self.now)
        }
        let points = await reader.load(now: self.now)
        #expect(points.count == 1)
        #expect(points.first?.sessionUsedFraction == 0.5)
        let history = NativeOrbitClaudeLocalArchive.histories(points)
        #expect(history.map(\.windowMinutes) == [300, 10080])
        #expect(history.map { $0.entries.first?.usedPercent } == [50, 100])
        #expect(history.allSatisfy { $0.entries.allSatisfy { $0.resetsAt == nil } })
    }

    @Test
    func `unreadable and future archive versions survive refresh while source stays usable`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("history.json")
        let cache = root.appendingPathComponent("archive.json")
        try Data("""
        {"dataPoints":[{"timestamp":"2027-01-15T08:00:00Z","pct5h":0.5,"pct7d":1}]}
        """.utf8).write(to: source)
        for bytes in [Data("{broken".utf8), Data("{\"version\":99,\"points\":[]}".utf8)] {
            try bytes.write(to: cache)
            let points = await NativeClaudeLocalArchive(sourceURL: source, cacheURL: cache).load(now: self.now)
            #expect(points.count == 1)
            #expect(try Data(contentsOf: cache) == bytes)
        }
    }

    @Test
    func `tests disable default source and cache paths`() async {
        let reader = NativeClaudeLocalArchive()
        #expect(await !reader.hasConfiguredPaths)
        #expect(await reader.load(now: self.now).isEmpty)
    }

    @Test
    func `archive retains measured quota overage`() throws {
        let data = Data("""
        {"dataPoints":[{"timestamp":"2027-01-15T08:00:00Z","pct5h":1.2,"pct7d":1.05}]}
        """.utf8)
        let points = try NativeClaudeLocalArchive.parse(data, now: self.now)
        #expect(points.count == 1)
        #expect(points.first?.sessionUsedFraction == 1.2)
        #expect(points.first?.weeklyUsedFraction == 1.05)
    }

    @Test
    func `archive rejects redirected source files and never replaces the source with its cache`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data("""
        {"dataPoints":[{"timestamp":"2027-01-15T08:00:00Z","pct5h":0.5,"pct7d":1}]}
        """.utf8)
        let target = root.appendingPathComponent("unrelated.json")
        try data.write(to: target)
        let redirected = root.appendingPathComponent("history.json")
        try FileManager.default.createSymbolicLink(at: redirected, withDestinationURL: target)
        let redirectedPoints = await NativeClaudeLocalArchive(sourceURL: redirected, cacheURL: nil)
            .load(now: self.now)
        #expect(redirectedPoints.isEmpty)
        let aliasedPoints = await NativeClaudeLocalArchive(sourceURL: target, cacheURL: target).load(now: self.now)
        #expect(aliasedPoints.isEmpty)
        #expect(try Data(contentsOf: target) == data)
    }
}
