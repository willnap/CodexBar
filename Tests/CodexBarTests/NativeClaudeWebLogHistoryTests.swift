import CodexBarCore
import Foundation
import Testing

struct NativeClaudeWebLogHistoryTests {
    private let org = "11111111-1111-4111-8111-111111111111"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func line(
        windows: [String: Any],
        scoped: Bool = true,
        local: String = "2026-07-23 15:19:23") throws -> String
    {
        var message: [String: Any] = ["type": "exceeded_limit", "windows": windows]
        if scoped {
            message["representativeClaim"] = "seven_day_overage_included"
            message["perModelLimit"] = true
            message["resolved"] = ["limit": [
                "kind": "weekly_scoped", "percent": 100,
                "resets_at": "2026-07-24T13:00:00+00:00",
                "scope": ["model": ["display_name": "Fable"]],
            ]]
        }
        let encodedMessage = try #require(String(
            data: JSONSerialization.data(withJSONObject: message),
            encoding: .utf8))
        let outer: [String: Any] = [
            "type": "rate_limit_error", "statusCode": 429, "method": "POST",
            "endpoint": "/api/organizations/\(self.org)/chat_conversations/"
                + "22222222-2222-4222-8222-222222222222/completion",
            "message": encodedMessage,
        ]
        return try "\(local) [error] [COMPLETION] Request failed "
            + #require(String(data: JSONSerialization.data(withJSONObject: outer), encoding: .utf8))
    }

    @Test
    func `web response preserves exact org raw quota reset and explicit Fable scope`() throws {
        let line = try self.line(windows: [
            "5h": ["utilization": 0.0, "resets_at": 1_784_816_400],
            "7d": ["utilization": 0.59, "resets_at": 1_784_898_000],
            "7d_oi": ["utilization": 1.01, "resets_at": 1_784_898_000],
        ])
        let points = try NativeClaudeWebLogHistory.parse(Data(line.utf8), now: self.now)
        #expect(points.count == 4)
        #expect(points.allSatisfy { $0.organizationUUID == self.org && $0.timestamp == nil
                && $0.localTimestamp == "2026-07-23 15:19:23" && $0.timeZoneIdentifier == nil
        })
        #expect(points.first { $0.windowKey == "five_hour" }?.usedPercent == 0)
        #expect(points.first { $0.windowKey == "seven_day" }?.usedPercent == 59)
        #expect(points.first { $0.windowKey == "fable" }?.usedPercent == 100)
        #expect(points.first { $0.windowKey == "seven_day_overage_included" }?.usedPercent == 101)
        #expect(points.first { $0.windowKey == "fable" }?.resetsAt?.timeIntervalSince1970 == 1_784_898_000)
    }

    @Test
    func `unscoped overage window cannot become a Fable measurement`() throws {
        let line = try self.line(windows: ["7d_oi": ["utilization": 0.5]], scoped: false)
        let points = try NativeClaudeWebLogHistory.parse(Data(line.utf8), now: self.now)
        #expect(points.count == 1)
        #expect(points.first?.windowKey == "seven_day_overage_included")
        #expect(points.first?.usedPercent == 50)
    }

    @Test
    func `resolved Fable percentage remains an explicit separate measurement`() throws {
        let line = try self.line(windows: [:])
        let points = try NativeClaudeWebLogHistory.parse(Data(line.utf8), now: self.now)
        #expect(points.count == 1)
        #expect(points.first?.usedPercent == 100)
        #expect(points.first?.sourceField == "resolved.limit.percent")
    }

    @Test
    func `verified source timezone resolves local timestamp with historical DST`() throws {
        let line = try self.line(windows: ["7d": ["utilization": 0.59]])
        let points = try NativeClaudeWebLogHistory.parse(
            Data(line.utf8), now: self.now, timeZone: #require(TimeZone(identifier: "Europe/London")))
        #expect(points.first?.timestamp == Date(timeIntervalSince1970: 1_784_816_363))
        #expect(points.first?.timeZoneIdentifier == "Europe/London")
    }

    @Test
    func `nonresponse malformed ownership and invalid numeric fields are rejected`() throws {
        let line = try self.line(windows: [
            "5h": ["utilization": true], "7d": ["utilization": -0.5],
        ], scoped: false)
        #expect(try NativeClaudeWebLogHistory.parse(Data(line.utf8), now: self.now).isEmpty)
        let valid = try self.line(windows: ["7d": ["utilization": 0.59]], scoped: false)
        for invalid in [
            valid.replacingOccurrences(of: self.org, with: "no-owner"),
            valid.replacingOccurrences(of: "[COMPLETION] Request failed", with: "user wrote"),
            valid.replacingOccurrences(of: "2026-07-23", with: "2026-02-30"),
        ] {
            #expect(try NativeClaudeWebLogHistory.parse(Data(invalid.utf8), now: self.now).isEmpty)
        }
    }

    @Test
    func `unreadable and unsupported cache bytes survive newly discovered observations`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("claude.ai-web.log")
        let cache = root.appendingPathComponent("history.json")
        let line = try self.line(windows: ["7d": ["utilization": 0.59]], scoped: false)
        try Data(line.utf8).write(to: source)
        let existingFiles = [
            Data("incomplete preserved history".utf8),
            Data("{\"version\":99,\"points\":[]}".utf8),
            Data(repeating: 0, count: 64 * 1024 * 1024 + 1),
        ]
        for existing in existingFiles {
            try existing.write(to: cache)
            let history = NativeClaudeWebLogHistory(sourceURLs: [source], cacheURL: cache)
            let discovered = await history.load(now: self.now)
            #expect(discovered.count == 1)
            #expect(await history.persistenceFailed)
            #expect(try Data(contentsOf: cache) == existing)
        }
    }

    @Test
    func `durable cache preserves old authentic rows across source rotation without raw logs`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("claude.ai-web.log")
        let cache = root.appendingPathComponent("cache/history.json")
        let line = try self.line(windows: ["7d": ["utilization": 0.59]], scoped: false)
        try Data(line.utf8).write(to: source)
        let first = await NativeClaudeWebLogHistory(sourceURLs: [source], cacheURL: cache).load(now: self.now)
        #expect(first.count == 1)
        try Data("rotated".utf8).write(to: source)
        let restored = await NativeClaudeWebLogHistory(sourceURLs: [source], cacheURL: cache)
            .load(now: self.now.addingTimeInterval(100 * 86400))
        #expect(restored == first)
        let cached = try String(contentsOf: cache, encoding: .utf8)
        #expect(!cached.contains("chat_conversations") && !cached.contains("message"))
        #expect(await !NativeClaudeWebLogHistory().hasConfiguredPaths)
    }
}
