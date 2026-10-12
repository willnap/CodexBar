import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct NativeAccountAutoSwitchTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test
    func `exhaustion selects the candidate with most minimum headroom`() {
        let rows = [
            self.account("active", active: true, usage: [100, 40]),
            self.account("a", usage: [10, 70]),
            self.account("b", usage: [40, 40]),
        ]
        let decision = NativeAccountAutoSwitchPolicy.decision(
            accounts: rows,
            attempted: [],
            now: self.now)
        #expect(decision?.targetID == "b")
    }

    @Test
    func `weekly only accounts do not require a synthetic session`() {
        let rows = [
            self.account("active", active: true, usage: [nil, 100]),
            self.account("next", usage: [nil, 20]),
        ]
        #expect(NativeAccountAutoSwitchPolicy.decision(
            accounts: rows,
            attempted: [],
            now: self.now)?
            .targetID == "next")
    }

    @Test
    func `missing blocking slots and nearly exhausted candidates cannot switch`() {
        let active = self.account("active", active: true, usage: [100, 70])
        for candidate in [
            self.account("next", usage: [20, nil]),
            self.account("next", usage: [0, 90]),
        ] {
            #expect(NativeAccountAutoSwitchPolicy.decision(
                accounts: [active, candidate],
                attempted: [],
                now: self.now) == nil)
        }
    }

    @Test
    func `stale disabled and failed readings cannot authorize switching`() {
        let active = self.account("active", active: true, usage: [100])
        var stale = self.account("stale", usage: [10], age: 301)
        stale.autoSwitchEligible = true
        var disabled = self.account("disabled", usage: [10])
        disabled.autoSwitchEligible = false
        for candidate in [stale, disabled, self.account("failed", usage: [10], healthy: false)] {
            #expect(NativeAccountAutoSwitchPolicy.decision(
                accounts: [active, candidate],
                attempted: [],
                now: self.now) == nil)
        }
        #expect(NativeAccountAutoSwitchPolicy.decision(
            accounts: [
                self.account("old", active: true, usage: [100], age: 301),
                self.account("new", usage: [0]),
            ],
            attempted: [],
            now: self.now) == nil)
    }

    @Test
    func `reset due and ambiguous active identities do not switch`() {
        let candidate = self.account("next", usage: [0])
        #expect(NativeAccountAutoSwitchPolicy.decision(
            accounts: [
                self.account("active", active: true, usage: [100], resetOffset: -1),
                candidate,
            ],
            attempted: [],
            now: self.now) == nil)
        #expect(NativeAccountAutoSwitchPolicy.decision(
            accounts: [
                self.account("a", active: true, usage: [100]),
                self.account("b", active: true, usage: [100]),
                candidate,
            ],
            attempted: [],
            now: self.now) == nil)
    }

    @Test
    func `one attempt per exhaustion tolerates reset rounding and respects manual cooldown`() throws {
        let rows = [
            self.account("active", active: true, usage: [100]),
            self.account("next", usage: [0]),
        ]
        let initial = try #require(NativeAccountAutoSwitchPolicy.decision(
            accounts: rows,
            attempted: [],
            now: self.now))
        let rounded = [
            self.account("active", active: true, usage: [100], resetOffset: 86370),
            rows[1],
        ]
        #expect(NativeAccountAutoSwitchPolicy.decision(
            accounts: rounded,
            attempted: [initial.exhaustion],
            now: self.now) == nil)
        #expect(NativeAccountAutoSwitchPolicy.decision(
            accounts: rows,
            attempted: [],
            now: self.now,
            cooldownUntil: self.now.addingTimeInterval(600)) == nil)
    }

    @Test
    func `healthy active account never rotates and invalid readings fail closed`() {
        for used in [50.0, Double.nan, -1] {
            #expect(NativeAccountAutoSwitchPolicy.decision(
                accounts: [
                    self.account("active", active: true, usage: [used]),
                    self.account("next", usage: [0]),
                ],
                attempted: [],
                now: self.now) == nil)
        }
    }

    @Test
    func `stopping prevents a queued login change`() async {
        var activations = 0
        let controller = self.controller { _ in
            activations += 1
            return .activated
        }
        controller.activate(self.account("next", usage: [0]))
        controller.stop()
        for _ in 0..<100 where controller.inFlightID != nil {
            await Task.yield()
        }
        #expect(activations == 0)
        #expect(controller.inFlightID == nil)
        controller.activate(self.account("next", usage: [0]))
        #expect(controller.inFlightID == nil)
    }

    @Test
    func `stopping allows an admitted credential transaction to finish`() async throws {
        var release: CheckedContinuation<Void, Never>?
        var completed = false
        var wasCancelled = false
        let controller = self.controller { _ in
            await withCheckedContinuation { release = $0 }
            wasCancelled = Task.isCancelled
            completed = true
            return .activated
        }
        controller.activate(self.account("next", usage: [0]))
        for _ in 0..<1000 where release == nil {
            await Task.yield()
        }
        let continuation = try #require(release)
        controller.stop()
        continuation.resume()
        for _ in 0..<1000 where !completed {
            await Task.yield()
        }
        #expect(completed)
        #expect(!wasCancelled)
        #expect(controller.inFlightID == nil)
    }

    @Test
    func `only the explicit switch may ask the desktop app to quit`() async {
        var policies: [NativeCodexDesktopQuitPolicy] = []
        let controller = self.controller { _ in
            policies.append(NativeCodexDesktopHandoff.quitPolicy)
            return .activated
        }
        controller.activate(self.account("next", usage: [0]))
        for _ in 0..<1000 where policies.isEmpty || controller.inFlightID != nil {
            await Task.yield()
        }
        #expect(policies == [.askToQuit])
    }

    @Test
    func `automatic switching defers for an open desktop app and resumes once it quits`() async {
        var policies: [NativeCodexDesktopQuitPolicy] = []
        var notifications: [String] = []
        var desktopOpen = true
        let now = Date()
        let rows = [
            self.account("active", active: true, usage: [100], at: now),
            self.account("next", usage: [0], at: now),
        ]
        // Created inside an explicit switch's scope: the automatic task must not inherit its permission.
        let controller = NativeCodexDesktopHandoff.$quitPolicy.withValue(.askToQuit) {
            self.controller(
                automatic: true,
                accounts: { rows },
                notify: { _, body in notifications.append(body) },
                activate: { _ in
                    policies.append(NativeCodexDesktopHandoff.quitPolicy)
                    return desktopOpen ? .deferred("ChatGPT is open.") : .activated
                })
        }
        for _ in 0..<1000 where policies.isEmpty || controller.inFlightID != nil {
            await Task.yield()
        }
        #expect(policies == [.never])
        #expect(notifications == ["ChatGPT is open. Next account: next."])
        #expect(controller.error == "ChatGPT is open.")

        desktopOpen = false
        controller.desktopDidQuit()
        for _ in 0..<1000 where policies.count < 2 || controller.inFlightID != nil {
            await Task.yield()
        }
        #expect(policies == [.never, .never])
        #expect(notifications.count == 1)
    }

    private func controller(
        automatic: Bool = false,
        accounts: (() -> [NativeOrbitAccountPresentation])? = nil,
        notify: @escaping (String, String) -> Void = { _, _ in },
        activate: @escaping (NativeOrbitAccountSelection) async -> NativeAccountActivationResult)
        -> NativeAccountSwitchController
    {
        let defaults = InMemoryUserDefaults()
        defaults.set(automatic, forKey: "nativeAutoSwitch.codex")
        let settings = testSettingsStore(
            suiteName: "NativeSwitchLifecycle",
            userDefaults: defaults,
            nativeDesignEnabled: true)
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        return NativeAccountSwitchController(
            provider: .codex,
            store: store,
            defaults: defaults,
            activate: activate,
            refresh: {},
            allowed: { true },
            accounts: accounts,
            notify: notify)
    }

    private func account(
        _ id: String,
        active: Bool = false,
        usage: [Double?],
        age: TimeInterval = 0,
        resetOffset: TimeInterval = 86400,
        healthy: Bool = true,
        at reference: Date? = nil) -> NativeOrbitAccountPresentation
    {
        let now = reference ?? self.now
        var gauge = ComputeGauge.State()
        gauge.health = healthy ? .live : .stale
        return NativeOrbitAccountPresentation(
            id: id,
            label: id,
            email: nil,
            symbol: "person",
            isActive: active,
            canActivate: !active,
            gauge: gauge,
            updatedAt: now.addingTimeInterval(-age),
            history: [],
            odometer: nil,
            odometerHelp: nil,
            statusText: nil,
            selection: .none,
            autoSwitchEligible: !active,
            autoSwitchWindows: usage.enumerated().map { index, value in
                value.map { RateWindow(
                    usedPercent: $0,
                    windowMinutes: index == 0 ? 300 : 10080,
                    resetsAt: now.addingTimeInterval(resetOffset),
                    resetDescription: nil) }
            })
    }
}
