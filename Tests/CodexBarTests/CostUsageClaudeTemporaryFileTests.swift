import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageClaudeTemporaryFileTests {
    @Test func `abandoned temporary cache copies are removed once they are an hour old`() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-cache-sweep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        func file(_ name: String, age: TimeInterval) throws -> URL {
            let url = directory.appendingPathComponent(name)
            try Data("x".utf8).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: now.addingTimeInterval(-age)],
                ofItemAtPath: url.path)
            return url
        }
        let abandoned = try file(".claude-cache-\(UUID().uuidString).tmp", age: 2 * 3600)
        let inProgress = try file(".claude-cache-\(UUID().uuidString).tmp", age: 60)
        let unrelated = try file("notes.tmp", age: 2 * 3600)
        let cache = try file("claude-v6.json", age: 2 * 3600)

        CostUsageClaudeCacheIO.removeAbandonedTemporaryFiles(in: directory, now: now)

        #expect(!FileManager.default.fileExists(atPath: abandoned.path))
        for kept in [inProgress, unrelated, cache] {
            #expect(FileManager.default.fileExists(atPath: kept.path))
        }
    }
}
