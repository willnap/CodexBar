import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct PlanUtilizationHistoryDurabilityTests {
    @MainActor
    @Test func `same turn quit seals the loaded latest history before a delayed older enqueue`() async throws {
        let directory = self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = PlanUtilizationHistoryStore(directoryURL: directory)
        let coordinator = PlanUtilizationHistoryPersistenceCoordinator(store: disk)
        let store = self.store()
        store.planUtilizationHistoryLoaded = true
        store.planUtilizationHistory = self.snapshot(percent: 42)
        let older = self.snapshot(percent: 10)
        let release = PlanUtilizationHistoryLoadGate()
        defer { release.open() }
        // Selection migration captures a snapshot in a fire-and-forget MainActor task.
        // Hold its admission until after quit has replied, making the ordering deterministic.
        let deferredEnqueue = Task { @MainActor in
            _ = await release.wait()
            await coordinator.enqueue(older)
            _ = await coordinator.flush()
        }
        let delegate = AppDelegate()
        delegate._test_configureHistoryPersistence(coordinator, store: store)
        var replies = 0
        delegate.replyToApplicationShouldTerminate = { _, approved in
            #expect(approved)
            #expect(disk.load() == store.planUtilizationHistory)
            replies += 1
        }
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
        for _ in 0..<100 where replies == 0 {
            self.deliverTerminationReplies()
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(replies == 1)
        release.open()
        await deferredEnqueue.value
        #expect(disk.load() == self.snapshot(percent: 42))
    }

    @MainActor
    @Test func `quit never replaces unread persisted history with an empty startup store`() async throws {
        let directory = self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = PlanUtilizationHistoryStore(directoryURL: directory)
        let retained = self.snapshot(percent: 42)
        #expect(disk.save(retained).isEmpty)
        let coordinator = PlanUtilizationHistoryPersistenceCoordinator(store: disk)
        let store = self.store()
        store.planUtilizationHistoryLoaded = false
        store.planUtilizationHistory = [:]
        let delegate = AppDelegate()
        delegate._test_configureHistoryPersistence(coordinator, store: store)
        var replies = 0
        delegate.replyToApplicationShouldTerminate = { _, approved in
            #expect(approved)
            replies += 1
        }
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
        for _ in 0..<100 where replies == 0 {
            self.deliverTerminationReplies()
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(replies == 1)
        #expect(disk.load() == retained)
    }

    @MainActor
    @Test func `normal quit waits for the accepted last quota observation to reach disk`() async throws {
        let directory = self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = PlanUtilizationHistoryStore(directoryURL: directory)
        let entered = PlanUtilizationHistoryLoadGate()
        let release = PlanUtilizationHistoryLoadGate()
        defer { release.open() }
        let coordinator = PlanUtilizationHistoryPersistenceCoordinator(store: disk, saveOperation: { snapshot in
            entered.open()
            _ = await release.wait()
            return disk.save(snapshot).isEmpty
        })
        let snapshot = self.snapshot(percent: 42)
        await coordinator.enqueue(snapshot)
        _ = await entered.wait()
        let delegate = AppDelegate()
        delegate._test_configureHistoryPersistence(coordinator)
        var replies = 0
        delegate.replyToApplicationShouldTerminate = { _, approved in
            #expect(approved)
            #expect(disk.load() == snapshot)
            replies += 1
        }
        let response = delegate.applicationShouldTerminate(NSApplication.shared)
        #expect(response == .terminateLater)
        #expect(replies == 0)
        release.open()
        for _ in 0..<100 where replies == 0 {
            self.deliverTerminationReplies()
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(replies == 1)
    }

    @Test func `a failed provider write is reported without discarding other providers`() throws {
        let directory = self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("kimi.json"), withIntermediateDirectories: true)
        let disk = PlanUtilizationHistoryStore(directoryURL: directory)
        var snapshot = self.snapshot(percent: 42)
        snapshot[.langdock] = snapshot[.kimi]
        let failed = disk.save(snapshot)
        #expect(failed == [.kimi])
        #expect(disk.load()[.langdock] == snapshot[.langdock])
    }

    @Test func `flush waits for coalesced replacement observations during a pending save`() async {
        let directory = self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = PlanUtilizationHistoryStore(directoryURL: directory)
        let entered = PlanUtilizationHistoryLoadGate()
        let release = PlanUtilizationHistoryLoadGate()
        defer { release.open() }
        let coordinator = PlanUtilizationHistoryPersistenceCoordinator(store: disk, saveOperation: { snapshot in
            entered.open()
            _ = await release.wait()
            return disk.save(snapshot).isEmpty
        })
        await coordinator.enqueue(self.snapshot(percent: 10))
        _ = await entered.wait()
        let latest = self.snapshot(percent: 42)
        await coordinator.enqueue(latest)
        let releasing = Task {
            try? await Task.sleep(for: .milliseconds(30))
            release.open()
        }
        #expect(await coordinator.flush())
        #expect(disk.load() == latest)
        await releasing.value
    }

    @Test func `a rejected final save remains retryable when the blocked provider path is repaired`() async throws {
        let directory = self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let blocked = directory.appendingPathComponent("kimi.json")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        let disk = PlanUtilizationHistoryStore(directoryURL: directory)
        let attempted = PlanUtilizationHistoryLoadGate()
        let release = PlanUtilizationHistoryLoadGate()
        defer { release.open() }
        let coordinator = PlanUtilizationHistoryPersistenceCoordinator(store: disk, saveOperation: { snapshot in
            let result = disk.save(snapshot)
            attempted.open()
            _ = await release.wait()
            return result.isEmpty
        })
        let snapshot = self.snapshot(percent: 42)
        let flushing = Task { await coordinator.flushForTermination(latestSnapshot: snapshot) }
        _ = await attempted.wait()
        try FileManager.default.removeItem(at: blocked)
        release.open()
        #expect(await flushing.value)
        #expect(disk.load() == snapshot)
    }

    @Test func `flush reports a persistent disk failure without retrying forever`() async throws {
        let directory = self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("kimi.json"), withIntermediateDirectories: true)
        let disk = PlanUtilizationHistoryStore(directoryURL: directory)
        let coordinator = PlanUtilizationHistoryPersistenceCoordinator(store: disk)
        #expect(await !(coordinator.flushForTermination(latestSnapshot: self.snapshot(percent: 42))))
        #expect(disk.load().isEmpty)
    }

    @MainActor private func deliverTerminationReplies() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.001))
    }

    @MainActor private func store() -> UsageStore {
        let settings = testSettingsStore(
            suiteName: "PlanUtilizationHistoryDurability", userDefaults: InMemoryUserDefaults())
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        store._cancelPlanUtilizationHistoryLoadForTesting()
        return store
    }

    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("quota-durability-\(UUID().uuidString)")
    }

    private func snapshot(percent: Double) -> [ProviderInstanceID: PlanUtilizationHistoryBuckets] {
        [.kimi: .init(unscoped: [.init(
            name: "nativeQuota:primary",
            windowMinutes: 300,
            entries: [.init(
                capturedAt: Date(timeIntervalSince1970: 1_786_363_200),
                usedPercent: percent,
                resetsAt: nil)])])]
    }
}
