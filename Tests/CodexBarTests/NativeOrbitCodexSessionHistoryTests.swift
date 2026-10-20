import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct NativeOrbitCodexSessionHistoryTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func `Spark backfill keeps named source quotas anonymous and persists conflicting readings`() async throws {
        let home = try self.home()
        defer { try? FileManager.default.removeItem(at: home) }
        let captured = self.now.addingTimeInterval(-119.625)
        let event = self.event(at: captured)
            .replacingOccurrences(
                of: "\"limit_id\":\"codex\"",
                with:
                "\"limit_id\":\"codex_bengalfox\",\"limit_name\":\"GPT-5.3-Codex-Spark\"")
            .replacingOccurrences(
                of: "\"secondary\":null",
                with:
                "\"secondary\":{\"used_percent\":125.625,\"window_minutes\":10080,\"resets_at\":1800604800.5}")
        let conflict = event.replacingOccurrences(of: "125.625", with: "126.875")
        try self.write(
            self.data(owner: "one", events: [event, event, conflict]),
            to:
            home.appendingPathComponent("sessions/spark.jsonl"))
        let store = self.store(home: home)
        let key = try #require(CodexHistoryOwnership.canonicalKey(for: .providerAccount(id: "one")))
        let owned = PlanUtilizationSeriesHistory(name: "nativeQuota:secondary", windowMinutes: 10080, entries: [
            .init(capturedAt: captured, usedPercent: 61, resetsAt: nil),
        ])
        store.planUtilizationHistory[.codex] = .init(preferredAccountKey: key, accounts: [key: [owned]])
        await CodexCredentialFileAccess.withFixtureScope(.init(roots: [home])) {
            await store.backfillNativeCodexSessionHistory(
                projection: self.projection(self.account("one")),
                now: self.now)
        }
        let buckets = try #require(store.planUtilizationHistory[.codex])
        #expect(buckets.accounts == [key: [owned]])
        #expect(buckets.preferredAccountKey == key)
        #expect(buckets.unscoped.map(\.name.rawValue).sorted() == [
            "nativeQuota:codex-spark", "nativeQuota:codex-spark-weekly",
        ])
        let weekly = try #require(buckets.unscoped.first { $0.name == "nativeQuota:codex-spark-weekly" })
        #expect(weekly.entries.map(\.usedPercent) == [125.625, 126.875])
        #expect(weekly.entries.allSatisfy {
            $0.capturedAt == captured && $0.resetsAt == Date(timeIntervalSince1970: 1_800_604_800.5)
        })
        let session = try #require(buckets.unscoped.first { $0.name == "nativeQuota:codex-spark" })
        #expect(session.entries.count == 1)
        for _ in 0..<100 where store.planUtilizationHistoryStore.load()[.codex] != buckets {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.planUtilizationHistoryStore.load()[.codex] == buckets)
    }

    @Test func `session quota observations preserve original dates and normalize a weekly primary`() throws {
        let captured = self.now.addingTimeInterval(-3599.625)
        let observations = NativeCodexQuotaSessionHistoryParser.parse(
            self.data(owner: "workspace-one", events: [self.event(at: captured, minutes: 10080)]), now: self.now)
        let observation = try #require(observations.first)
        #expect(observations.count == 1)
        #expect(observation.workspaceAccountID == nil)
        #expect(observation.snapshot.updatedAt == captured)
        #expect(observation.snapshot.primary == nil)
        #expect(observation.snapshot.secondary?.windowMinutes == 10080)
        #expect(observation.snapshot.secondary?.usedPercent == 37)
        #expect(observation.snapshot.secondary?.resetsAt == Date(
            timeIntervalSince1970: floor(captured.timeIntervalSince1970) + 7200))
    }

    @Test func `missing conflicting or malformed creator metadata cannot own quota observations`() {
        let event = self.event(at: self.now)
        for text in [event, self.metadata(nil) + event, self.metadata("one") + self.metadata("two") + event] {
            #expect(NativeCodexQuotaSessionHistoryParser.parse(Data(text.utf8), now: self.now).count == 1)
        }
        #expect(NativeCodexQuotaSessionHistoryParser.parse(
            Data((self.metadata("one") + self.metadata(nil) + event).utf8), now: self.now).count == 1)
    }

    @Test func `independent session and weekly measurements both survive source parsing`() throws {
        let event = self.event(at: self.now).replacingOccurrences(
            of: "\"secondary\":null",
            with: "\"secondary\":{\"used_percent\":12,\"window_minutes\":10080,\"resets_at\":1800008400}")
        let observation = try #require(NativeCodexQuotaSessionHistoryParser.parse(
            self.data(owner: "one", events: [event]), now: self.now).first)
        #expect(observation.snapshot.primary?.usedPercent == 37)
        #expect(observation.snapshot.primary?.windowMinutes == 300)
        #expect(observation.snapshot.secondary?.usedPercent == 12)
        #expect(observation.snapshot.secondary?.windowMinutes == 10080)
    }

    @Test func `invalid old future and unrelated events cannot manufacture quota history`() {
        let events = [
            self.event(at: self.now.addingTimeInterval(-33 * 86400)),
            self.event(at: self.now.addingTimeInterval(60)),
            self.event(at: self.now).replacingOccurrences(of: "37", with: "-2"),
            self.event(at: self.now).replacingOccurrences(of: "token_count", with: "agent_message"),
            self.event(at: self.now).replacingOccurrences(of: "\"codex\"", with: "\"other-model-limit\""),
            self.event(at: self.now).replacingOccurrences(of: self.timestamp(self.now), with: "invalid-date"),
        ]
        #expect(NativeCodexQuotaSessionHistoryParser.parse(
            self.data(owner: "one", events: events), now: self.now).isEmpty)
    }

    @Test func `incremental scans require complete owner evidence and read appended observations`() async throws {
        let home = try self.home()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent("sessions/fixture.jsonl")
        let scanner = NativeCodexQuotaSessionHistoryScanner()
        try self.write(self.data(owner: "one", events: [self.event(at: self.now.addingTimeInterval(-120))]), to: file)
        try await CodexCredentialFileAccess.withFixtureScope(.init(roots: [home])) {
            let first = await scanner.scan(homeRoots: [home], now: self.now, byteBudget: 32)
            #expect(first.isEmpty)
            let complete = await scanner.scan(homeRoots: [home], now: self.now)
            #expect(complete.count == 1)
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(self.event(at: self.now).utf8))
            try handle.close()
            try FileManager.default.setAttributes(
                [.modificationDate: self.now.addingTimeInterval(1)],
                ofItemAtPath: file.path)
            let appended = await scanner.scan(homeRoots: [home], now: self.now)
            #expect(appended.map(\.snapshot.updatedAt) == [self.now.addingTimeInterval(-120), self.now])
            #expect(await scanner.scan(homeRoots: [home], now: self.now) == appended)
            // Nothing new to read, but a later moment drops what has aged out of the 32 days.
            let later = await scanner.scan(homeRoots: [home], now: self.now.addingTimeInterval(32 * 86400 - 60))
            #expect(later.map(\.snapshot.updatedAt) == [self.now])
        }
        #expect(await scanner.scan(homeRoots: [home], now: self.now).isEmpty)
    }

    @Test func `file isolation and symlinks prevent reading outside the selected session roots`() async throws {
        let home = try self.home()
        let outside = try self.home()
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: outside)
        }
        let outsideFile = outside.appendingPathComponent("sessions/other.jsonl")
        try self.write(self.data(owner: "one", events: [self.event(at: self.now)]), to: outsideFile)
        try FileManager.default.createSymbolicLink(
            at: home.appendingPathComponent("sessions/linked.jsonl"), withDestinationURL: outsideFile)
        let scanner = NativeCodexQuotaSessionHistoryScanner()
        await CodexCredentialFileAccess.withFixtureScope(.init(roots: [home])) {
            #expect(await scanner.scan(homeRoots: [home, outside], now: self.now).isEmpty)
        }
    }

    @Test func `oversized creator metadata cannot erase anonymous quota observations`() async throws {
        let home = try self.home()
        defer { try? FileManager.default.removeItem(at: home) }
        let footer = "{\"padding\":\"" + String(repeating: "x", count: 2 * 1024 * 1024)
            + "\",\"type\":\"session_meta\",\"payload\":{\"creator_account_id\":\"two\"}}\n"
        let file = home.appendingPathComponent("sessions/oversized.jsonl")
        try self.write(self.data(owner: "one", events: [self.event(at: self.now), footer]), to: file)
        let scanner = NativeCodexQuotaSessionHistoryScanner()
        await CodexCredentialFileAccess.withFixtureScope(.init(roots: [home])) {
            #expect(await scanner.scan(homeRoots: [home], now: self.now).count == 1)
        }
    }

    @Test func `history backfill repairs exact creator imports and preserves live account readings`() async throws {
        let home = try self.home()
        defer { try? FileManager.default.removeItem(at: home) }
        let first = home.appendingPathComponent("sessions/first.jsonl")
        let second = home.appendingPathComponent("sessions/second.jsonl")
        let unknown = home.appendingPathComponent("sessions/unknown.jsonl")
        let captured = self.now.addingTimeInterval(-3599.625)
        try self.write(self.data(owner: "one", events: [self.event(at: captured), self.event(at: self.now)]), to: first)
        try self.write(self.data(owner: "two", events: [self.event(at: captured)
                .replacingOccurrences(of: "\"used_percent\":37", with: "\"used_percent\":48")]), to: second)
        try self.write(Data(self.event(at: captured.addingTimeInterval(60)).utf8), to: unknown)
        let store = self.store(home: home)
        let projection = CodexVisibleAccountProjection(
            visibleAccounts: [self.account("one"), self.account("two")],
            activeVisibleAccountID: "one",
            liveVisibleAccountID: nil,
            hasUnreadableAddedAccountStore: false)
        let key = try #require(CodexHistoryOwnership.canonicalKey(for: .providerAccount(id: "one")))
        let siblingKey = try #require(CodexHistoryOwnership.canonicalKey(for: .providerAccount(id: "two")))
        let current = PlanUtilizationSeriesHistory(name: "nativeQuota:primary", windowMinutes: 300, entries: [
            .init(capturedAt: captured, usedPercent: 37, resetsAt: Date(
                timeIntervalSince1970: floor(captured.timeIntervalSince1970) + 7200)),
            .init(capturedAt: self.now, usedPercent: 61, resetsAt: nil),
        ])
        let legacy = PlanUtilizationSeriesHistory(name: .session, windowMinutes: 300, entries: [
            .init(capturedAt: captured, usedPercent: 37, resetsAt: Date(
                timeIntervalSince1970: floor(captured.timeIntervalSince1970) + 7200)),
        ])
        let sibling = PlanUtilizationSeriesHistory(name: "nativeQuota:primary", windowMinutes: 300, entries: [
            .init(capturedAt: captured, usedPercent: 37, resetsAt: nil),
        ])
        let original = PlanUtilizationHistoryBuckets(
            preferredAccountKey: key, accounts: [key: [current, legacy], siblingKey: [sibling]])
        store.planUtilizationHistory[.codex] = original
        await CodexCredentialFileAccess.withFixtureScope(.init(roots: [home])) {
            await store.backfillNativeCodexSessionHistory(projection: projection, now: self.now)
        }
        let buckets = try #require(store.planUtilizationHistory[.codex])
        let history = try #require(buckets.accounts[key]?.first { $0.name == "nativeQuota:primary" })
        #expect(history.entries.map(\.capturedAt) == [self.now])
        #expect(history.entries.last?.usedPercent == 61)
        #expect(buckets.accounts[siblingKey] == [sibling])
        #expect(buckets.accounts[key]?.contains(legacy) == true)
        #expect(buckets.accounts.count == 2)
        #expect(buckets.preferredAccountKey == key)
        let archive = try #require(buckets.unscoped.first { $0.name == "nativeQuota:primary" })
        #expect(archive.entries.map(\.usedPercent) == [37, 48, 37, 37])
        #expect(archive.entries.map(\.capturedAt) == [captured, captured, captured.addingTimeInterval(60), self.now])
        let backupRoot = home.appendingPathComponent("history/recovery-backups")
        let backups = try FileManager.default.contentsOfDirectory(at: backupRoot, includingPropertiesForKeys: nil)
        #expect(backups.count == 1)
        #expect(PlanUtilizationHistoryStore(directoryURL: backups.first).load()[.codex] == original)
        await CodexCredentialFileAccess.withFixtureScope(.init(roots: [home])) {
            await store.backfillNativeCodexSessionHistory(projection: projection, now: self.now)
        }
        #expect(store.planUtilizationHistory[.codex] == buckets)
        #expect(try FileManager.default.contentsOfDirectory(
            at: backupRoot, includingPropertiesForKeys: nil).count == 1)
        for _ in 0..<100 where store.planUtilizationHistoryStore.load()[.codex] != buckets {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.planUtilizationHistoryStore.load()[.codex] == buckets)
        #expect(store.planUtilizationHistoryStore.load()[.codex]?.unscoped.first?.entries.first?
            .capturedAt == captured)
    }

    @Test func `live history recording schedules source recovery without waiting for it`() async throws {
        let home = try self.home()
        defer { try? FileManager.default.removeItem(at: home) }
        let captured = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) - 120)
        try self.write(
            self.data(owner: "one", events: [self.event(at: captured)]),
            to: home.appendingPathComponent("sessions/live.jsonl"))
        let store = self.store(home: home)
        let projection = CodexVisibleAccountProjection(
            visibleAccounts: [self.account("one")],
            activeVisibleAccountID: "one",
            liveVisibleAccountID: nil,
            hasUnreadableAddedAccountStore: false)
        let key = try #require(CodexHistoryOwnership.canonicalKey(for: .providerAccount(id: "one")))
        try await CodexCredentialFileAccess.withFixtureScope(.init(roots: [home])) {
            await store.recordNativeCodexAccountHistory([], projection: projection)
            #expect(store.planUtilizationHistory[.codex]?.accounts[key] == nil)
            for _ in 0..<100 where store.planUtilizationHistory[.codex]?.unscoped.isEmpty != false {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(store.planUtilizationHistory[.codex]?.accounts[key] == nil)
            #expect(store.planUtilizationHistory[.codex]?.unscoped.first?.entries.first?.capturedAt == captured)
            await store.nativeCodexSessionHistoryBackfillTask?.value
        }
    }

    @Test func `anonymous old session readings do not require a current visible account`() async throws {
        let home = try self.home()
        defer { try? FileManager.default.removeItem(at: home) }
        try self.write(Data(self.event(at: self.now).utf8), to: home.appendingPathComponent("sessions/old.jsonl"))
        let store = self.store(home: home)
        let projection = CodexVisibleAccountProjection(
            visibleAccounts: [],
            activeVisibleAccountID: nil,
            liveVisibleAccountID: nil,
            hasUnreadableAddedAccountStore: false)
        await CodexCredentialFileAccess.withFixtureScope(.init(roots: [home])) {
            await store.backfillNativeCodexSessionHistory(projection: projection, now: self.now)
        }
        #expect(store.planUtilizationHistory[.codex]?.accounts.isEmpty == true)
        #expect(store.planUtilizationHistory[.codex]?.unscoped.first?.entries.first?.usedPercent == 37)
    }

    @Test func `failed durable backup leaves account histories untouched`() async throws {
        let home = try self.home()
        defer { try? FileManager.default.removeItem(at: home) }
        let captured = self.now.addingTimeInterval(-120)
        try self.write(
            self.data(owner: "one", events: [self.event(at: captured), self.event(at: self.now)]),
            to: home.appendingPathComponent("sessions/fixture.jsonl"))
        let store = self.store(home: home)
        let key = try #require(CodexHistoryOwnership.canonicalKey(for: .providerAccount(id: "one")))
        let history = PlanUtilizationSeriesHistory(name: "nativeQuota:primary", windowMinutes: 300, entries: [
            .init(capturedAt: captured, usedPercent: 37, resetsAt: Date(
                timeIntervalSince1970: captured.timeIntervalSince1970 + 7200)),
        ])
        let original = PlanUtilizationHistoryBuckets(accounts: [key: [history]])
        store.planUtilizationHistory[.codex] = original
        let directory = home.appendingPathComponent("history")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("blocked".utf8).write(to: directory.appendingPathComponent("recovery-backups"))
        let projection = CodexVisibleAccountProjection(
            visibleAccounts: [self.account("one")],
            activeVisibleAccountID: "one",
            liveVisibleAccountID: nil,
            hasUnreadableAddedAccountStore: false)
        await CodexCredentialFileAccess.withFixtureScope(.init(roots: [home])) {
            await store.backfillNativeCodexSessionHistory(projection: projection, now: self.now)
        }
        #expect(store.planUtilizationHistory[.codex] == original)
    }

    @Test func `an independently published account reading survives an exact source collision`() async throws {
        let home = try self.home()
        defer { try? FileManager.default.removeItem(at: home) }
        try self.write(
            self.data(owner: "one", events: [self.event(at: self.now)]),
            to: home.appendingPathComponent("sessions/fixture.jsonl"))
        let store = self.store(home: home)
        let account = self.account("one")
        let key = try #require(CodexHistoryOwnership.canonicalKey(for: .providerAccount(id: "one")))
        let reset = self.now.addingTimeInterval(7200)
        let history = PlanUtilizationSeriesHistory(name: "nativeQuota:primary", windowMinutes: 300, entries: [
            .init(capturedAt: self.now, usedPercent: 37, resetsAt: reset),
        ])
        store.planUtilizationHistory[.codex] = .init(accounts: [key: [history]])
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 37, windowMinutes: 300, resetsAt: reset, resetDescription: nil),
            secondary: nil,
            updatedAt: self.now)
        store.codexAccountSnapshots = [.init(account: account, snapshot: snapshot, error: nil, sourceLabel: "OAuth")]
        let projection = CodexVisibleAccountProjection(
            visibleAccounts: [account],
            activeVisibleAccountID: "one",
            liveVisibleAccountID: nil,
            hasUnreadableAddedAccountStore: false)
        await CodexCredentialFileAccess.withFixtureScope(.init(roots: [home])) {
            await store.backfillNativeCodexSessionHistory(projection: projection, now: self.now)
        }
        #expect(store.planUtilizationHistory[.codex]?.accounts[key] == [history])
        #expect(store.planUtilizationHistory[.codex]?.unscoped == [history])
    }

    @Test func `source overage stays raw while malformed and negative measurements remain invalid`() throws {
        let event = self.event(at: self.now).replacingOccurrences(
            of: "\"used_percent\":37", with: "\"used_percent\":125")
        let point = try #require(NativeCodexQuotaSessionHistoryParser.parse(Data(event.utf8), now: self.now).first)
        #expect(point.snapshot.primary?.usedPercent == 125)
        for invalid in ["-1", "true", "1e999"] {
            let malformed = event.replacingOccurrences(of: "\"used_percent\":125", with: "\"used_percent\":\(invalid)")
            #expect(NativeCodexQuotaSessionHistoryParser.parse(Data(malformed.utf8), now: self.now).isEmpty)
        }
    }

    @Test func `overage repair removes clipped imports and protects accepted readings`() async throws {
        for independentlyPublished in [false, true] {
            let home = try self.home()
            defer { try? FileManager.default.removeItem(at: home) }
            let event = self.event(at: self.now).replacingOccurrences(
                of: "\"used_percent\":37", with: "\"used_percent\":125")
            try self.write(
                self.data(owner: "one", events: [event]),
                to: home.appendingPathComponent("sessions/overage.jsonl"))
            let store = self.store(home: home)
            let account = self.account("one")
            let key = try #require(CodexHistoryOwnership.canonicalKey(for: .providerAccount(id: "one")))
            let reset = self.now.addingTimeInterval(7200)
            let clipped = PlanUtilizationSeriesHistory(name: "nativeQuota:primary", windowMinutes: 300, entries: [
                .init(capturedAt: self.now, usedPercent: 100, resetsAt: reset),
            ])
            store.planUtilizationHistory[.codex] = .init(accounts: [key: [clipped]])
            if independentlyPublished {
                let snapshot = UsageSnapshot(
                    primary: RateWindow(usedPercent: 100, windowMinutes: 300, resetsAt: reset, resetDescription: nil),
                    secondary: nil,
                    updatedAt: self.now)
                store.codexAccountSnapshots = [.init(
                    account: account,
                    snapshot: snapshot,
                    error: nil,
                    sourceLabel: "OAuth")]
            }
            await CodexCredentialFileAccess.withFixtureScope(.init(roots: [home])) {
                await store.backfillNativeCodexSessionHistory(projection: self.projection(account), now: self.now)
            }
            #expect(store.planUtilizationHistory[.codex]?.accounts[key] == (independentlyPublished ? [clipped] : nil))
            #expect(store.planUtilizationHistory[.codex]?.unscoped.first?.entries.first?.usedPercent == 125)
        }
    }

    private func projection(_ account: CodexVisibleAccount) -> CodexVisibleAccountProjection {
        .init(
            visibleAccounts: [account],
            activeVisibleAccountID: account.id,
            liveVisibleAccountID: nil,
            hasUnreadableAddedAccountStore: false)
    }

    private func metadata(_ owner: String?) -> String {
        let payload = owner.map { "\"creator_account_id\":\"\($0)\"" } ?? ""
        return "{\"type\":\"session_meta\",\"payload\":{\(payload)}}\n"
    }

    private func event(at date: Date, minutes: Int = 300) -> String {
        """
        {"type":"event_msg","timestamp":"\(self.timestamp(date))","payload":{"type":"token_count",\
        "rate_limits":{"limit_id":"codex","primary":{"used_percent":37,"window_minutes":\(minutes),\
        "resets_at":\(Int(date.timeIntervalSince1970) + 7200)},"secondary":null}}}

        """
    }

    private func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func data(owner: String, events: [String]) -> Data {
        Data((self.metadata(owner) + events.joined()).utf8)
    }

    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: self.now], ofItemAtPath: url.path)
    }

    private func home() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        return home
    }

    private func account(_ workspace: String) -> CodexVisibleAccount {
        .init(
            id: workspace,
            email: "fixture@example.com",
            workspaceAccountID: workspace,
            storedAccountID: nil,
            selectionSource: .profileHome(path: "/tmp/unreadable-fixture"),
            isActive: workspace == "one",
            isLive: false,
            canReauthenticate: false,
            canRemove: false)
    }

    private func store(home: URL) -> UsageStore {
        let settings = testSettingsStore(
            suiteName: "NativeCodexSessionHistory", userDefaults: InMemoryUserDefaults(), nativeDesignEnabled: true)
        enableTestProviders([.codex], settings: settings)
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            planUtilizationHistoryStore: .init(directoryURL: home.appendingPathComponent("history")),
            startupBehavior: .testing,
            environmentBase: ["CODEX_HOME": home.path])
        store._cancelPlanUtilizationHistoryLoadForTesting()
        return store
    }
}
