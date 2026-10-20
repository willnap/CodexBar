import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct NativeOrbitHistoryCompactionTests {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test func `merging ordered series keeps one entry per instant like the keyed rule`() {
        var generator = SeededGenerator(seed: 7)
        for _ in 0..<200 {
            let existing = self.series(count: Int.random(in: 0...40, using: &generator), using: &generator)
            let incoming = self.series(count: Int.random(in: 0...6, using: &generator), using: &generator)
            #expect(UsageStore.nativeOrbitMergedRawEntries(existing, incoming)
                == Self.keyedMerge(existing, incoming))
            // Unordered input takes the keyed path and still yields the same series.
            let shuffled = existing.shuffled(using: &generator)
            #expect(UsageStore.nativeOrbitMergedRawEntries(shuffled, incoming)
                == Self.keyedMerge(shuffled, incoming))
        }
    }

    @Test func `thinning keeps every change, run end and recording gap`() {
        // A reading every 10 s: 30 min at 40 %, 10 min at 41 %, a 50 min gap, then 10 more min at 41 %.
        var raw: [PlanUtilizationHistoryEntry] = []
        for second in stride(from: 0, to: 1800, by: 10) {
            raw.append(self.reading(second, 40))
        }
        for second in stride(from: 1800, to: 2400, by: 10) {
            raw.append(self.reading(second, 41))
        }
        for second in stride(from: 5400, to: 6000, by: 10) {
            raw.append(self.reading(second, 41))
        }
        let thinned = UsageStore.nativeOrbitThinnedObservations(Set(raw))

        #expect(thinned.count < raw.count / 5)
        #expect(zip(thinned, thinned.dropFirst()).allSatisfy { $0.capturedAt < $1.capturedAt })
        for kept in [0, 1790, 1800, 2390, 5400, 5990] {
            #expect(thinned.contains(self.reading(kept, 40)) || thinned.contains(self.reading(kept, 41)))
        }
        let gaps = zip(thinned, thinned.dropFirst()).map { $1.capturedAt.timeIntervalSince($0.capturedAt) }
        #expect(gaps.filter { $0 > UsageStore.nativeOrbitObservationBucket } == [3010])
    }

    @Test func `readings added back by a rescan leave the thinned series unchanged`() {
        var generator = SeededGenerator(seed: 11)
        var raw: [PlanUtilizationHistoryEntry] = []
        var percent = 10.0
        for second in stride(from: 0, to: 6 * 3600, by: 7) {
            if Int.random(in: 0..<60, using: &generator) == 0 { percent += 1 }
            // Two sources taking turns, as anonymous session logs from two accounts do.
            raw.append(self.reading(second, (second / 600) % 3 == 2 ? percent + 30 : percent))
        }
        let thinned = UsageStore.nativeOrbitThinnedObservations(Set(raw))
        #expect(thinned.count < raw.count / 5)
        for _ in 0..<5 {
            let rescanned = raw.filter { _ in Bool.random(using: &generator) }
            #expect(UsageStore.nativeOrbitThinnedObservations(Set(thinned).union(rescanned)) == thinned)
        }
    }

    @Test func `saving one provider's change leaves the other providers' documents alone`() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("quota-changed-only-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = PlanUtilizationHistoryStore(directoryURL: directory)
        let coordinator = PlanUtilizationHistoryPersistenceCoordinator(store: disk)
        let kimi = self.buckets(percent: 10)
        await coordinator.enqueue([.kimi: kimi, .codex: self.buckets(percent: 20)])
        #expect(await coordinator.flush())

        let codexFile = directory.appendingPathComponent("codex.json")
        let sentinel = Data("{}".utf8)
        try sentinel.write(to: codexFile)
        await coordinator.enqueue([.kimi: kimi, .codex: self.buckets(percent: 30)])
        #expect(await coordinator.flush())
        #expect(disk.load()[.codex] == self.buckets(percent: 30))

        let kimiFile = directory.appendingPathComponent("kimi.json")
        try sentinel.write(to: kimiFile)
        await coordinator.enqueue([.kimi: kimi, .codex: self.buckets(percent: 40)])
        #expect(await coordinator.flush())
        #expect(try Data(contentsOf: kimiFile) == sentinel)
    }

    @Test func `a refresh's history changes are written once, and a flush never waits for that`() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("quota-debounce-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = PlanUtilizationHistoryStore(directoryURL: directory)
        let coordinator = PlanUtilizationHistoryPersistenceCoordinator(store: disk, debounce: .seconds(60))
        await coordinator.enqueue([.kimi: self.buckets(percent: 10)])
        await coordinator.enqueue([.kimi: self.buckets(percent: 20)])
        #expect(disk.load().isEmpty)
        let started = ContinuousClock.now
        #expect(await coordinator.flush())
        #expect(started.duration(to: .now) < .seconds(30))
        #expect(disk.load()[.kimi] == self.buckets(percent: 20))
    }

    private func reading(_ second: Int, _ percent: Double) -> PlanUtilizationHistoryEntry {
        PlanUtilizationHistoryEntry(
            capturedAt: self.start.addingTimeInterval(TimeInterval(second)),
            usedPercent: percent,
            resetsAt: self.start.addingTimeInterval(7 * 86400))
    }

    private func buckets(percent: Double) -> PlanUtilizationHistoryBuckets {
        .init(unscoped: [.init(
            name: "nativeQuota:primary",
            windowMinutes: 300,
            entries: [self.reading(0, percent)])])
    }

    private func series(
        count: Int,
        using generator: inout SeededGenerator) -> [PlanUtilizationHistoryEntry]
    {
        var second = 0
        return (0..<count).map { _ in
            // Small steps make equal instants across the two series likely.
            second += Int.random(in: 1...3, using: &generator)
            let period: PlanUtilizationHistoricalPeriod? = Bool.random(using: &generator) && Bool
                .random(using: &generator)
                ? .init(startsAt: self.start, approximate: true, accountingComplete: true) : nil
            return PlanUtilizationHistoryEntry(
                capturedAt: self.start.addingTimeInterval(TimeInterval(second)),
                usedPercent: Double(Int.random(in: 0...100, using: &generator)),
                resetsAt: nil,
                historicalPeriod: period)
        }
    }

    /// The rule as originally written: later entries replace earlier ones at an instant, except that a period total
    /// never replaces a measured reading.
    private static func keyedMerge(
        _ existing: [PlanUtilizationHistoryEntry],
        _ incoming: [PlanUtilizationHistoryEntry]) -> [PlanUtilizationHistoryEntry]
    {
        var byDate: [Date: PlanUtilizationHistoryEntry] = [:]
        for entry in existing + incoming {
            if entry.historicalPeriod != nil, byDate[entry.capturedAt]?.historicalPeriod == nil,
               byDate[entry.capturedAt] != nil { continue }
            byDate[entry.capturedAt] = entry
        }
        return byDate.values.sorted(by: PlanUtilizationHistoryEntry.precedes)
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        self.state &+= 0x9E37_79B9_7F4A_7C15
        var value = self.state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
