import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

/// The popup's first frame is complete or not shown: its content waits for everything it draws, then fades in.
@MainActor
struct NativeOrbitFirstFrameTests {
    @Test func `the popup waits for history, its account list and every reading, then shows them together`() {
        let loaded = self.account(updatedAt: Date())
        let loading = self.account(updatedAt: nil)
        func ready(
            wait: TimeInterval = 3,
            history: Bool = true,
            awaiting: Bool = false,
            _ accounts: [NativeOrbitAccountPresentation]) -> Bool
        {
            UsageStore.nativePopupIsReady(
                waitRemaining: wait, historyAvailable: history, awaitingAccountList: awaiting, accounts: accounts)
        }
        #expect(ready([loaded, loaded]))
        #expect(!ready(history: false, [loaded]), "No chart without its history")
        #expect(!ready(awaiting: true, [loaded]), "No placeholder column before claude-swap answers")
        #expect(!ready([]), "No empty popup")
        #expect(!ready([loaded, loading]), "No half-filled dials")
        #expect(ready([self.account(updatedAt: nil, status: "Sign in required")]), "A definite status is an answer")
        #expect(ready(wait: 0, history: false, awaiting: true, [loading]), "The launch wait is bounded")
    }

    @Test func `history loads every provider's file and reports each as it lands`() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-first-frame-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PlanUtilizationHistoryStore(directoryURL: directory)
        let entry = PlanUtilizationHistoryEntry(capturedAt: Date(), usedPercent: 25, resetsAt: nil)
        let series = PlanUtilizationSeriesHistory(name: "nativeQuota:primary", windowMinutes: 300, entries: [entry])
        let buckets = PlanUtilizationHistoryBuckets(unscoped: [series])
        store.save([UsageProvider.claude.instanceID: buckets, UsageProvider.codex.instanceID: buckets])
        let reported = ReportedProviders()
        let loaded = await store.loadAsync { instanceID, _ in await reported.insert(instanceID) }
        #expect(Set(loaded.keys) == [UsageProvider.claude.instanceID, UsageProvider.codex.instanceID])
        #expect(await reported.ids == Set(loaded.keys))
        #expect(loaded == store.load())
    }

    private func account(updatedAt: Date?, status: String? = nil) -> NativeOrbitAccountPresentation {
        NativeOrbitAccountPresentation(
            id: UUID().uuidString,
            label: "Fixture",
            email: nil,
            symbol: "person",
            isActive: false,
            canActivate: false,
            gauge: .init(),
            updatedAt: updatedAt,
            history: [],
            odometer: nil,
            odometerHelp: nil,
            statusText: status,
            selection: .none)
    }
}

private actor ReportedProviders {
    private(set) var ids: Set<ProviderInstanceID> = []

    func insert(_ id: ProviderInstanceID) {
        self.ids.insert(id)
    }
}
