import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct NativeCodexAccountUsageHistoryTests {
    private let now = Date(timeIntervalSince1970: 1_791_741_600)

    @Test func `partial server responses retain original dated observations without filling missing days`() throws {
        let first = try #require(NativeCodexAccountUsageHistory.merging(
            self.history(days: [("2026-10-09", 10), ("2026-10-10", 20)]),
            previous: nil,
            fetchedAt: self.now))
        let later = self.now.addingTimeInterval(60)
        let merged = try #require(NativeCodexAccountUsageHistory.merging(
            self.history(days: [("2026-10-10", 25), ("2026-10-11", 30)]),
            previous: first,
            fetchedAt: later))
        #expect(merged.observations.map(\.day.startDate) == ["2026-10-09", "2026-10-10", "2026-10-11"])
        #expect(merged.observations.map(\.day.tokens) == [10, 25, 30])
        #expect(merged.observations.map(\.reportedAt) == [self.now, later, later])
        let snapshot = try #require(merged.tokenSnapshot())
        #expect(!snapshot.historyIsFullyScanned)
        #expect(snapshot.daily.count == 3)
        #expect(snapshot.quotaSlices.isEmpty)
        #expect(snapshot.last30DaysCostUSD == nil)
        let calendar = CostUsageBucketTimeZone.calendar(identifier: "UTC")
        let summary = NativeOrbitAccountMetrics(usage: snapshot).summary(
            days: 7,
            now: later,
            calendar: calendar)
        #expect(summary.tokens == 65)
        #expect(summary.isPartial)
        #expect(summary.cost == nil)
        #expect(try NativeCodexAccountUsageHistory.merging(
            self.history(
                days: [],
                error: "stats unavailable"),
            previous: merged,
            fetchedAt: later) == merged)
        let omitted = try self.history(days: nil)
        #expect(NativeCodexAccountUsageHistory.merging(
            omitted,
            previous: merged,
            fetchedAt: later) == merged)
    }

    @Test func `history loader binds the isolated principal and contains optional failures`() async throws {
        let account = self.account()
        let response = try self.history(days: [("2026-10-10", 25)])
        let measured = await UsageStore.nativeCodexAccountUsageHistory(
            for: account,
            previous: nil,
            env: ["CODEX_HOME": "/tmp/fixture-profile"],
            now: self.now,
            loader: { email, workspace, env in
                #expect(email == "owner@example.com")
                #expect(workspace == "fixture-workspace")
                #expect(env["CODEX_HOME"] == "/tmp/fixture-profile")
                return response
            })
        let previous = try #require(measured)
        let retained = await UsageStore.nativeCodexAccountUsageHistory(
            for: account,
            previous: previous,
            env: [:],
            now: self.now.addingTimeInterval(60),
            loader: { _, _, _ in throw URLError(.timedOut) })
        #expect(retained == previous)
    }

    @Test func `observations reject future timestamps and retain evidence on clock rollback`() throws {
        let response = try self.history(days: [("2026-10-10", 25)])
        let previous = try #require(NativeCodexAccountUsageHistory.merging(
            response,
            previous: nil,
            fetchedAt: self.now))
        let inconsistent = NativeCodexAccountUsageHistory(
            latest: response,
            fetchedAt: self.now.addingTimeInterval(-60),
            observations: previous.observations)
        #expect(inconsistent.tokenSnapshot() == nil)
        #expect(NativeCodexAccountUsageHistory.merging(
            response,
            previous: previous,
            fetchedAt: self.now.addingTimeInterval(-60)) == previous)
    }

    @Test(arguments: ["2026-01-+1", "+026-01-01", "2026-1-011", "2026-02-30", "0000-01-01"])
    func `cached observation dates must be canonical valid civil dates`(date: String) throws {
        let response = try self.history(days: [("2026-10-10", 25)])
        let history = NativeCodexAccountUsageHistory(
            latest: response,
            fetchedAt: self.now,
            observations: [.init(
                day: .init(
                    startDate: date,
                    tokens: 25),
                reportedAt: self.now)])
        #expect(history.tokenSnapshot() == nil)
    }

    @Test func `dated account tokens survive restart and reject a different owner in the same slot`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileCodexAccountUsageSnapshotStore(fileURL: root.appendingPathComponent("snapshots.json"))
        let history = try #require(NativeCodexAccountUsageHistory.merging(
            self.history(days: [("2026-10-10", 25)]),
            previous: nil,
            fetchedAt: self.now))
        let account = self.account()
        store.store([CodexAccountUsageSnapshot(
            account: account,
            snapshot: UsageSnapshot(
                primary: nil,
                secondary: nil,
                updatedAt: self.now),
            error: nil,
            sourceLabel: "fixture",
            accountUsageHistory: history)])
        let loaded = try #require(store.load(for: [account]).first)
        #expect(loaded.accountUsageHistory == history)
        #expect(loaded.snapshot?.costUsage?.daily.first?.totalTokens == 25)
        #expect(store.load(for: [self.account(email: "foreign@example.com")]).isEmpty)
        #expect(store.load(for: [self.account(workspace: "other-workspace")]).isEmpty)
        #expect(UsageStore.codexSnapshotsRetainingCandidate(
            loaded,
            candidate: nil).first?
            .accountUsageHistory == history)
    }

    @Test func `unreadable account caches survive publication attempts`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("snapshots.json")
        for bytes in [Data("{broken".utf8), Data("{\"version\":99,\"records\":[]}".utf8)] {
            try bytes.write(to: path)
            let store = FileCodexAccountUsageSnapshotStore(fileURL: path)
            #expect(store.load(for: [self.account()]).isEmpty)
            store.store([])
            #expect(try Data(contentsOf: path) == bytes)
        }
    }

    @Test func `invalid cached counts never display or overwrite evidence`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("snapshots.json")
        let store = FileCodexAccountUsageSnapshotStore(fileURL: path)
        let history = try #require(NativeCodexAccountUsageHistory.merging(
            self.history(days: [("2026-10-10", 25)]),
            previous: nil,
            fetchedAt: self.now))
        store.store([CodexAccountUsageSnapshot(
            account: self.account(),
            snapshot: UsageSnapshot(
                primary: nil,
                secondary: nil,
                updatedAt: self.now),
            error: nil,
            sourceLabel: "fixture",
            accountUsageHistory: history)])
        var payload = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        var records = try #require(payload["records"] as? [[String: Any]])
        var cached = try #require(records[0]["accountUsageHistory"] as? [String: Any])
        var observations = try #require(cached["observations"] as? [[String: Any]])
        var day = try #require(observations[0]["day"] as? [String: Any])
        day["tokens"] = -1
        observations[0]["day"] = day
        cached["observations"] = observations
        records[0]["accountUsageHistory"] = cached
        payload["records"] = records
        let invalid = try JSONSerialization.data(withJSONObject: payload)
        try invalid.write(to: path)
        #expect(store.load(for: [self.account()]).first?.accountUsageHistory == nil)
        store.store([])
        #expect(try Data(contentsOf: path) == invalid)
    }

    @Test func `temporarily absent accounts and reused slots retain owner bound history`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileCodexAccountUsageSnapshotStore(fileURL: root.appendingPathComponent("snapshots.json"))
        let first = self.account()
        let second = self.account(
            id: "second",
            email: "second@example.com")
        let history = try #require(NativeCodexAccountUsageHistory.merging(
            self.history(days: [("2026-10-09", 25)]),
            previous: nil,
            fetchedAt: self.now))
        func row(_ account: CodexVisibleAccount, _ report: NativeCodexAccountUsageHistory?)
        -> CodexAccountUsageSnapshot {
            CodexAccountUsageSnapshot(
                account: account,
                snapshot: nil,
                error: nil,
                sourceLabel: nil,
                accountUsageHistory: report)
        }
        store.store([row(first, history), row(second, history)])
        store.store([row(first, nil)])
        #expect(store.load(for: [first, second]).count == 2)
        #expect(store.load(for: [first]).first?.accountUsageHistory == history)
        let partial = try #require(NativeCodexAccountUsageHistory.merging(
            self.history(days: [("2026-10-10", 30)]),
            previous: nil,
            fetchedAt: self.now.addingTimeInterval(60)))
        store.store([row(first, partial)])
        let joined = try #require(store.load(for: [first]).first?.accountUsageHistory)
        #expect(joined.observations.map(\.day.tokens) == [25, 30])
        #expect(joined.observations.map(\.reportedAt) == [self.now, self.now.addingTimeInterval(60)])
        let replacement = self.account(email: "replacement@example.com")
        store.store([row(replacement, nil)])
        #expect(store.load(for: [replacement]).first?.accountUsageHistory == nil)
        #expect(store.load(for: [first]).first?.accountUsageHistory == joined)
        #expect(store.load(for: [second]).first?.accountUsageHistory == history)
    }

    @Test func `historical inspection keeps the original token reading after a daily correction`() throws {
        let initial = try #require(NativeCodexAccountUsageHistory.merging(
            self.history(days: [("2026-10-10", 20)]),
            previous: nil,
            fetchedAt: self.now))
        let later = self.now.addingTimeInterval(60)
        let corrected = try #require(NativeCodexAccountUsageHistory.merging(
            self.history(days: [("2026-10-10", 25)]),
            previous: initial,
            fetchedAt: later))
        let inspected = corrected.tokenSnapshot(asOf: self.now)
        #expect(inspected?.daily.first?.totalTokens == 20)
        #expect(inspected?.updatedAt == self.now)
        #expect(corrected.tokenSnapshot()?.daily.first?.totalTokens == 25)
        #expect(corrected.tokenSnapshot(asOf: self.now.addingTimeInterval(-1)) == nil)
        let restarted = try JSONDecoder().decode(
            NativeCodexAccountUsageHistory.self,
            from: JSONEncoder().encode(corrected))
        #expect(restarted.tokenSnapshot(asOf: self.now)?.daily.first?.totalTokens == 20)
    }

    private func account(
        id: String = "fixture",
        email: String = "owner@example.com",
        workspace: String = "fixture-workspace") -> CodexVisibleAccount
    {
        CodexVisibleAccount(
            id: id,
            email: email,
            workspaceAccountID: workspace,
            authFingerprint: "fixture-fingerprint",
            storedAccountID: nil,
            selectionSource: .profileHome(path: "/tmp/fixture-profile"),
            isActive: false,
            isLive: false,
            canReauthenticate: false,
            canRemove: false)
    }

    @Test func `as of history never borrows the latest correction metadata`() throws {
        let first = try #require(NativeCodexAccountUsageHistory.merging(
            self.history(
                days: [("2026-10-10", 10)],
                statsAsOf: "2026-10-10"),
            previous: nil,
            fetchedAt: self.now))
        let corrected = try #require(NativeCodexAccountUsageHistory.merging(
            self.history(
                days: [("2026-10-10", 20)],
                statsAsOf: "2026-10-11"),
            previous: first,
            fetchedAt: self.now.addingTimeInterval(86400)))
        let projected = try #require(corrected.tokenSnapshot(asOf: self.now))
        #expect(projected.daily.first?.totalTokens == 10)
        #expect(projected.updatedAt == self.now)
        #expect(projected.historyLabel?.contains("2026-10-11") == false)
    }

    @Test func `malformed archived revisions invalidate writable account evidence`() throws {
        let response = try self.history(days: [("2026-10-10", 25)])
        for version in [
            NativeCodexAccountUsageHistory.Observation(
                day: .init(
                    startDate: "2026-02-30",
                    tokens: 25),
                reportedAt: self.now),
            .init(
                day: .init(
                    startDate: "2026-10-10",
                    tokens: -1),
                reportedAt: self.now),
            .init(
                day: .init(
                    startDate: "2026-10-10",
                    tokens: 25),
                reportedAt: self.now.addingTimeInterval(60)),
        ] {
            let history = NativeCodexAccountUsageHistory(
                latest: response,
                fetchedAt: self.now,
                observations: [.init(
                    day: .init(
                        startDate: "2026-10-10",
                        tokens: 25),
                    reportedAt: self.now)],
                archivedObservations: [version])
            #expect(history.tokenSnapshot() == nil)
        }
    }

    private func history(
        days: [(String, Int)]?,
        error: String? = nil,
        statsAsOf: String = "2026-10-11") throws -> CodexAccountUsageHistory
    {
        var stats: [String: Any] = [:]
        if let days {
            stats["daily_usage_buckets"] = days.map { ["start_date": $0.0, "tokens": $0.1] as [String: Any] }
        }
        var metadata: [String: Any] = ["stats_as_of": statsAsOf]
        if let error { metadata["stats_error"] = error }
        return try CodexAccountUsageHistory.decode(JSONSerialization.data(withJSONObject: [
            "stats": stats, "metadata": metadata,
        ]))
    }
}
