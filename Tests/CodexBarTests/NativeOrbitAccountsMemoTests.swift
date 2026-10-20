import CodexBarCore
import Foundation
import Observation
import Testing
@testable import CodexBar

@MainActor
struct NativeOrbitAccountsMemoTests {
    private final class Flag: @unchecked Sendable {
        var raised = false
    }

    @Test func `an observer served remembered rows still hears about the next input change`() {
        let store = self.store()
        let built = store.nativeOrbitAccounts(for: .kimi)
        #expect(store.nativeOrbitAccountsMemo.entries[.kimi] != nil)

        let flag = Flag()
        let remembered = withObservationTracking {
            store.nativeOrbitAccounts(for: .kimi)
        } onChange: {
            flag.raised = true
        }
        #expect(remembered.map(\.id) == built.map(\.id))

        store.planUtilizationHistoryRevision &+= 1
        #expect(flag.raised)
        #expect(store.nativeOrbitAccountsMemo.entries[.kimi] == nil)
        _ = store.nativeOrbitAccounts(for: .kimi)
        #expect(store.nativeOrbitAccountsMemo.entries[.kimi] != nil)
    }

    @Test func `remembered rows are reused briefly and expire so clock-derived values stay current`() {
        let store = self.store()
        _ = store.nativeOrbitAccounts(for: .kimi)
        store.nativeOrbitAccountsMemo.entries[.kimi] = .init(accounts: [], builtAt: Date())
        #expect(store.nativeOrbitAccounts(for: .kimi).isEmpty)
        let stale = Date().addingTimeInterval(-NativeOrbitAccountsMemo.lifetime)
        store.nativeOrbitAccountsMemo.entries[.kimi] = .init(accounts: [], builtAt: stale)
        #expect(!store.nativeOrbitAccounts(for: .kimi).isEmpty)
    }

    private func store() -> UsageStore {
        let settings = testSettingsStore(
            suiteName: "NativeOrbitAccountsMemo", userDefaults: InMemoryUserDefaults())
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        store._cancelPlanUtilizationHistoryLoadForTesting()
        return store
    }
}
