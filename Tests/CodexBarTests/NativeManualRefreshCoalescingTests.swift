import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

/// The popup's refresh against background work for the same provider: a press always fetches anew, background
/// refreshes join a press instead of fetching again, and a press replaced by a newer request ends on that request.
@MainActor
@Suite(.serialized)
struct NativeManualRefreshCoalescingTests {
    @Test
    func `a press during a background refresh replaces it with a fresh fetch`() async {
        let store = Self.makeStore()
        let fetches = ProviderFetchGate()
        store._test_providerRefreshOverride = { _ in await fetches.run() }
        defer { store._test_providerRefreshOverride = nil }

        let background = Task { @MainActor in
            await store.refreshProvider(.kimi, coalesceIfRefreshing: true)
        }
        await waitUntil { fetches.started == 1 }
        let pressDone = DoneFlag()
        let press = Task { @MainActor in
            await store.refreshProviderForUser(.kimi)
            pressDone.value = true
        }
        await waitUntil { fetches.started == 2 }
        #expect(fetches.started == 2, "The press never settles for a request that began before it")
        #expect(fetches.cancelled == [1], "The older background fetch is cancelled, not awaited to completion")
        #expect(!pressDone.value)
        fetches.release(2)
        await press.value
        await background.value
        #expect(pressDone.value)
        #expect(fetches.started == 2, "The replaced background refresh does not fetch a third time")
    }

    @Test
    func `a background refresh during a press joins it without fetching again`() async {
        let store = Self.makeStore()
        let fetches = ProviderFetchGate()
        store._test_providerRefreshOverride = { _ in await fetches.run() }
        defer { store._test_providerRefreshOverride = nil }

        let press = Task { @MainActor in await store.refreshProviderForUser(.kimi) }
        await waitUntil { fetches.started == 1 }
        let backgroundDone = DoneFlag()
        let background = Task { @MainActor in
            await store.refreshProvider(.kimi, coalesceIfRefreshing: true)
            backgroundDone.value = true
        }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(fetches.started == 1, "Timer and menu-open refreshes coalesce into the press")
        #expect(fetches.cancelled.isEmpty, "Background work never cancels a press")
        #expect(!backgroundDone.value, "The joined background refresh waits for the press's reading")
        fetches.release(1)
        await press.value
        await background.value
        #expect(backgroundDone.value)
        #expect(fetches.started == 1)
    }

    @Test
    func `a press replaced by a newer request ends on that request`() async {
        let store = Self.makeStore()
        let fetches = ProviderFetchGate()
        store._test_providerRefreshOverride = { _ in await fetches.run() }
        defer { store._test_providerRefreshOverride = nil }

        let pressDone = DoneFlag()
        let press = Task { @MainActor in
            await store.refreshProviderForUser(.kimi)
            pressDone.value = true
        }
        await waitUntil { fetches.started == 1 }
        // A settings change or an account switch replaces the request in flight.
        let replacement = Task { @MainActor in await store.refreshProvider(.kimi) }
        await waitUntil { fetches.started == 2 }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!pressDone.value, "The spinner stays until the replacing request publishes")
        fetches.release(2)
        await replacement.value
        await press.value
        #expect(pressDone.value)
        #expect(fetches.started == 2)
    }

    private static func makeStore() -> UsageStore {
        let settings = testSettingsStore(
            suiteName: "NativeManualRefreshCoalescingTests",
            keychainAccessPolicy: .init(setDisabled: { _ in }, isExplicitlyDisabled: { true }))
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.costUsageEnabled = false
        settings.openAIWebAccessEnabled = false
        settings.providerDetectionCompleted = true
        for provider in UsageProvider.allCases {
            guard let metadata = ProviderRegistry.shared.metadata[provider] else { continue }
            // Provider-specific by design: the fixture refreshes one provider without account fan-out.
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: provider == .kimi)
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let environment = [
            "HOME": root.path,
            "CODEX_HOME": root.appendingPathComponent(".codex", isDirectory: true).path,
            "XDG_CONFIG_HOME": root.appendingPathComponent(".config", isDirectory: true).path,
        ]
        return UsageStore(
            fetcher: UsageFetcher(environment: environment),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: environment)
    }
}

@MainActor
private final class DoneFlag {
    var value = false
}

/// Stands in for a provider fetch: each one waits until the test releases it or its request is cancelled.
@MainActor
private final class ProviderFetchGate {
    private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var finished: Set<Int> = []
    private(set) var started = 0
    private(set) var cancelled: [Int] = []

    func run() async {
        self.started += 1
        let id = self.started
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if self.finished.contains(id) {
                    continuation.resume()
                } else {
                    self.waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor in
                self.cancelled.append(id)
                self.release(id)
            }
        }
    }

    func release(_ id: Int) {
        self.finished.insert(id)
        self.waiters.removeValue(forKey: id)?.resume()
    }
}

/// Returns as soon as the condition holds; the ceiling is generous because the full suite runs in parallel.
@MainActor
private func waitUntil(timeout: Duration = .seconds(20), _ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while !condition(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }
}
