import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct NativeClaudeDesktopHistoryTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let firstOrg = "11111111-1111-4111-8111-111111111111"
    private let secondOrg = "22222222-2222-4222-8222-222222222222"

    @Test
    func `desktop v2 keeps exact org dates overages and independently observed windows`() throws {
        let data = Data("""
        {"version":2,"samples":[
          {"t":1799996400125,"org":"\(self.firstOrg)","u":{"fh":12.5,"sd":125,"so":4}},
          {"t":1799996500125,"org":"\(self.secondOrg)","u":{"fh":0}},
          {"t":1799996600125,"org":null,"u":{"sd":30}}
        ]}
        """.utf8)
        let points = try NativeClaudeDesktopHistory.parse(data, now: self.now)
        #expect(points.count == 5)
        #expect(points.contains { $0.timestamp.timeIntervalSince1970 == 1_799_996_400.125
                && $0.organizationUUID == self.firstOrg && $0.windowKey == "sd" && $0.usedPercent == 125
        })
        #expect(points.contains { $0.organizationUUID == nil && $0.usedPercent == 30 })
        let history = NativeOrbitClaudeDesktopHistory.histories(points, organizationUUID: self.firstOrg)
        #expect(history.first { $0.name == "nativeQuota:primary" }?.entries.first?.usedPercent == 12.5)
        #expect(history.first { $0.name == "nativeQuota:secondary" }?.entries.first?.usedPercent == 125)
        #expect(history.allSatisfy { $0.entries.allSatisfy { $0.resetsAt == nil } })
        #expect(!history.contains { $0.name.rawValue.contains("fable") })
        #expect(NativeOrbitClaudeDesktopHistory.histories(points, organizationUUID: nil)
            .flatMap(\.entries).map(\.usedPercent) == [30])
    }

    @Test
    func `desktop v1 remains anonymous and malformed rows cannot acquire an org`() throws {
        let legacy = Data("""
        {"version":1,"samples":[{"t":1799996400125,"fh":25,"sd":50}]}
        """.utf8)
        let oldPoints = try NativeClaudeDesktopHistory.parse(legacy, now: self.now)
        #expect(oldPoints.count == 2)
        #expect(oldPoints.allSatisfy { $0.organizationUUID == nil })
        let invalid = Data("""
        {"version":2,"samples":[
          {"t":1799996400125,"org":"not-an-org","u":{"fh":10}},
          {"t":1799996400125,"u":{"fh":10}},
          {"t":true,"org":null,"u":{"fh":10}},
          {"t":1799996400125,"org":null,"u":{"fh":true,"sd":-1}},
          {"t":1900000000000,"org":null,"u":{"fh":10}},
          {"t":1700000000000,"org":null,"u":{"fh":10}}
        ]}
        """.utf8)
        #expect(try NativeClaudeDesktopHistory.parse(invalid, now: self.now).isEmpty)
        #expect(throws: (any Error).self) {
            try NativeClaudeDesktopHistory.parse(Data("{\"version\":3,\"samples\":[]}".utf8), now: self.now)
        }
    }

    @Test
    func `desktop durable cache retains source pruning and conflicting real observations`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("plan-usage-history.json")
        let cache = root.appendingPathComponent("cache/desktop.json")
        for value in [25, 40] {
            try Data("""
            {"version":2,"samples":[{"t":1799996400125,"org":"\(self.firstOrg)","u":{"fh":\(value)}}]}
            """.utf8).write(to: source)
            _ = await NativeClaudeDesktopHistory(sourceURLs: [source], cacheURL: cache).load(now: self.now)
        }
        try Data("corrupt".utf8).write(to: source)
        let recovered = await NativeClaudeDesktopHistory(sourceURLs: [source], cacheURL: cache).load(now: self.now)
        #expect(recovered.count == 2)
        #expect(Set(recovered.map(\.usedPercent)) == [25, 40])
        #expect(recovered.allSatisfy { $0.timestamp.timeIntervalSince1970 == 1_799_996_400.125 })
        #expect(await NativeClaudeDesktopHistory(sourceURLs: [], cacheURL: cache)
            .load(now: self.now.addingTimeInterval(33 * 86400)).isEmpty)
    }

    @Test
    func `desktop picks up a changed source on the next load`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("plan-usage-history.json")
        let reader = NativeClaudeDesktopHistory(sourceURLs: [source], cacheURL: root.appendingPathComponent("c.json"))
        try Data("""
        {"version":2,"samples":[{"t":1799996400125,"org":"\(self.firstOrg)","u":{"fh":25}}]}
        """.utf8).write(to: source)
        #expect(await reader.load(now: self.now).map(\.usedPercent) == [25])
        #expect(await reader.load(now: self.now).map(\.usedPercent) == [25])
        try Data("""
        {"version":2,"samples":[{"t":1799996400125,"org":"\(self.firstOrg)","u":{"fh":25}},
          {"t":1799996500125,"org":"\(self.firstOrg)","u":{"fh":40}}]}
        """.utf8).write(to: source)
        #expect(await reader.load(now: self.now).map(\.usedPercent) == [25, 40])
    }

    @Test
    func `desktop test process uses explicit contained fixture paths only`() async throws {
        #expect(await !NativeClaudeDesktopHistory().hasConfiguredPaths)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("real.json")
        let bytes = Data("""
        {"version":2,"samples":[{"t":1799996400125,"org":null,"u":{"fh":50}}]}
        """.utf8)
        try bytes.write(to: source)
        let redirect = root.appendingPathComponent("redirect.json")
        try FileManager.default.createSymbolicLink(at: redirect, withDestinationURL: source)
        #expect(await NativeClaudeDesktopHistory(sourceURLs: [redirect], cacheURL: nil).load(now: self.now).isEmpty)
        #expect(await NativeClaudeDesktopHistory(sourceURLs: [source], cacheURL: source).load(now: self.now).isEmpty)
        #expect(try Data(contentsOf: source) == bytes)
    }

    @Test
    func `desktop reports a failed cache write and retries retained observations`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("plan-usage-history.json")
        let obstruction = root.appendingPathComponent("blocked-cache-directory")
        let cache = obstruction.appendingPathComponent("history.json")
        try Data("not a directory".utf8).write(to: obstruction)
        try Data("""
        {"version":2,"samples":[{"t":1799996400125,"org":"\(self.firstOrg)","u":{"fh":25}}]}
        """.utf8).write(to: source)
        let reader = NativeClaudeDesktopHistory(sourceURLs: [source], cacheURL: cache)
        let first = await reader.load(now: self.now)
        #expect(first.count == 1)
        #expect(await reader.persistenceFailed)
        #expect(!FileManager.default.fileExists(atPath: cache.path))
        try FileManager.default.removeItem(at: obstruction)
        try Data("source now unavailable".utf8).write(to: source)
        #expect(await reader.load(now: self.now) == first)
        #expect(await !reader.persistenceFailed)
        #expect(await NativeClaudeDesktopHistory(sourceURLs: [], cacheURL: cache).load(now: self.now) == first)
    }
}
