import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct NativeOrbitWarningEligibilityTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func `Claude without a live session is not missing data for unused exhausted or absent weekly limits`() {
        let absentSession = self.window(placeholder: true)
        for primary in [nil, absentSession] {
            for secondary in [nil, self.window(used: 0, minutes: 10080), self.window(used: 100, minutes: 10080)] {
                let snapshot = UsageSnapshot(primary: primary, secondary: secondary, updatedAt: self.now)
                #expect(!self.lights(provider: .claude, snapshot: snapshot)
                    .contains { [.partialReading, .notReported].contains($0.kind) })
            }
        }
    }

    @Test func `Claude quota capability unavailable is not a warning`() {
        let snapshot = UsageSnapshot(primary: self.window(placeholder: true), secondary: nil, updatedAt: self.now)
        #expect(snapshot.rateLimitsUnavailable(for: .claude))
        #expect(!self.lights(provider: .claude, snapshot: snapshot)
            .contains { [.partialReading, .notReported].contains($0.kind) })
    }

    @Test func `an optional unknown model quota never measured before is not missing data`() {
        #expect(!self.lights(provider: .claude, snapshot: self.unknownModel())
            .contains { $0.kind == .partialReading })
    }

    @Test func `a recently measured model quota missing within its current cycle warns`() {
        let history = [self.quota(
            id: "tertiary", used: 35, minutes: 10080, captured: -300, reset: 3600)]
        #expect(self.lights(provider: .claude, snapshot: self.unknownModel(), history: history)
            .contains { $0.kind == .partialReading })
    }

    @Test func `expired stale or different model evidence cannot establish an expected current quota`() {
        for history in [
            self.quota(id: "tertiary", used: 35, minutes: 10080, captured: -300, reset: -60),
            self.quota(id: "tertiary", used: 35, minutes: 10080, captured: -10800, reset: 3600),
            self.quota(id: "tertiary", used: 0, minutes: 10080, captured: -300, reset: 3600),
            self.quota(id: "another-model", used: 35, minutes: 10080, captured: -300, reset: 3600),
        ] {
            #expect(!self.lights(provider: .claude, snapshot: self.unknownModel(), history: [history])
                .contains { $0.kind == .partialReading })
        }
    }

    @Test func `a genuine measured Claude session newly reset to zero is complete`() {
        let session = self.window()
        let snapshot = UsageSnapshot(primary: session, secondary: self.window(minutes: 10080), updatedAt: self.now)
        #expect(session.measured != nil)
        #expect(!self.lights(provider: .claude, snapshot: snapshot).contains { $0.kind == .partialReading })
    }

    @Test func `an Amp period-only quota without a reset never promised a reset timestamp`() {
        let snapshot = UsageSnapshot(
            primary: self.window(used: 42, minutes: 1440, reset: nil), secondary: nil, updatedAt: self.now)
        #expect(!self.lights(provider: .amp, snapshot: snapshot).contains { $0.kind == .notReported })
    }

    @Test func `a reset disappearing from a recently measured current window warns`() {
        let snapshot = UsageSnapshot(
            primary: self.window(used: 42, minutes: 1440, reset: nil), secondary: nil, updatedAt: self.now)
        let history = [self.quota(id: "primary", used: 35, minutes: 1440, captured: -300, reset: 3600)]
        #expect(self.lights(provider: .amp, snapshot: snapshot, history: history)
            .contains { $0.kind == .notReported })
    }

    @Test func `an expired or different window cannot require a new reset timestamp`() {
        let snapshot = UsageSnapshot(
            primary: self.window(used: 42, minutes: 1440, reset: nil), secondary: nil, updatedAt: self.now)
        for history in [
            self.quota(id: "primary", used: 35, minutes: 1440, captured: -300, reset: -60),
            self.quota(id: "primary", used: 35, minutes: 300, captured: -300, reset: 3600),
        ] {
            #expect(!self.lights(provider: .amp, snapshot: snapshot, history: [history])
                .contains { $0.kind == .notReported })
        }
    }

    @Test func `Codex zero credits without a funded pool or activity is not exhaustion`() {
        for available in [nil, false] {
            let metrics = self.codexMetrics(available: available)
            #expect(metrics.reportedBalance?.value == 0)
            #expect(!self.lights(provider: .codex, metrics: metrics).contains { $0.kind == .credits })
        }
    }

    @Test func `a measured zero balance alone never proves any providers credits were exhausted`() {
        for provider in [UsageProvider.codex, .openrouter, .kimi] {
            let metrics = self.balanceMetrics(provider: provider, value: 0)
            #expect(!self.lights(provider: provider, metrics: metrics).contains { $0.kind == .credits })
        }
    }

    @Test func `a balance depleted from a matching funded pool still warns`() {
        for provider in [UsageProvider.codex, .openrouter, .kimi] {
            let metrics = self.balanceMetrics(provider: provider, value: 0)
            let previous = NativeOrbitReportedBalance(
                value: 30,
                unit: self.unit(provider),
                isWorkspace: false,
                updatedAt: self.now.addingTimeInterval(-3600))
            #expect(self.lights(provider: provider, metrics: metrics, history: self.balances([previous]))
                .contains { $0.kind == .credits && $0.severity == .critical })
        }
    }

    @Test func `foreign scope currency invalid value or future balance is not prior funding`() {
        let metrics = self.codexMetrics()
        for previous in [
            NativeOrbitReportedBalance(
                value: 30,
                unit: "Credits",
                isWorkspace: true,
                updatedAt: self.now.addingTimeInterval(-3600)),
            NativeOrbitReportedBalance(
                value: 30,
                unit: "USD",
                isWorkspace: false,
                updatedAt: self.now.addingTimeInterval(-3600)),
            NativeOrbitReportedBalance(
                value: .infinity,
                unit: "Credits",
                isWorkspace: false,
                updatedAt: self.now.addingTimeInterval(-3600)),
            NativeOrbitReportedBalance(
                value: 30,
                unit: "Credits",
                isWorkspace: false,
                updatedAt: self.now.addingTimeInterval(60)),
            NativeOrbitReportedBalance(
                value: 0,
                unit: "Credits",
                isWorkspace: false,
                updatedAt: self.now.addingTimeInterval(-3600)),
        ] {
            #expect(!self.lights(provider: .codex, metrics: metrics, history: self.balances([previous]))
                .contains { $0.kind == .credits })
        }
    }

    @Test func `newer unavailable or foreign pool receipts break earlier funding evidence`() {
        let metrics = self.codexMetrics()
        let prior = NativeOrbitReportedBalance(
            value: 30, unit: "Credits", isWorkspace: false, updatedAt: self.now.addingTimeInterval(-3600))
        let barrierDate = self.now.addingTimeInterval(-300)
        let barriers: [NativeOrbitReportedBalance?] = [
            nil,
            .init(value: 0, unit: "USD", isWorkspace: false, updatedAt: barrierDate),
            .init(value: 0, unit: "Credits", isWorkspace: true, updatedAt: barrierDate),
        ]
        for barrier in barriers {
            var entries = self.balances([prior])[0].entries
            entries.append(.init(
                capturedAt: barrierDate, usedPercent: 0, resetsAt: nil, nativeMetrics: .init(balance: barrier)))
            let history = [PlanUtilizationSeriesHistory(
                name: .init(rawValue: "nativeMetric:balance"), windowMinutes: 0, entries: entries)]
            #expect(!self.lights(provider: .codex, metrics: metrics, history: history)
                .contains { $0.kind == .credits })
        }
    }

    @Test func `a newer matching zero receipt retains the same pools earlier funding evidence`() {
        let metrics = self.codexMetrics()
        let history = self.balances([
            .init(value: 30, unit: "Credits", isWorkspace: false, updatedAt: self.now.addingTimeInterval(-3600)),
            .init(value: 0, unit: "Credits", isWorkspace: false, updatedAt: self.now.addingTimeInterval(-300)),
        ])
        #expect(self.lights(provider: .codex, metrics: metrics, history: history)
            .contains { $0.kind == .credits && $0.severity == .critical })
    }

    @Test func `matching funded balance currency and credit units are case insensitive`() {
        for provider in [UsageProvider.codex, .openrouter] {
            let metrics = self.balanceMetrics(provider: provider, value: 0)
            let history = self.balances([.init(
                value: 30,
                unit: self.unit(provider).lowercased(),
                isWorkspace: false,
                updatedAt: self.now.addingTimeInterval(-3600))])
            #expect(self.lights(provider: provider, metrics: metrics, history: history)
                .contains { $0.kind == .credits && $0.severity == .critical })
        }
    }

    @Test func `included Codex credit consumption alone does not prove the purchased pool was funded`() {
        let event = CreditEvent(date: self.now.addingTimeInterval(-300), service: "Fixture", creditsUsed: 2)
        let metrics = self.codexMetrics(events: [event])
        #expect(metrics.creditUsageEvents.count == 1)
        #expect(!self.lights(provider: .codex, metrics: metrics).contains { $0.kind == .credits })
    }

    @Test func `zero invalid future or old credit events do not establish recent funding`() {
        for event in [
            CreditEvent(date: self.now.addingTimeInterval(-300), service: "Fixture", creditsUsed: 0),
            CreditEvent(date: self.now.addingTimeInterval(-300), service: "Fixture", creditsUsed: -1),
            CreditEvent(date: self.now.addingTimeInterval(60), service: "Fixture", creditsUsed: 2),
            CreditEvent(date: self.now.addingTimeInterval(-259_200), service: "Fixture", creditsUsed: 2),
        ] {
            #expect(!self.lights(provider: .codex, metrics: self.codexMetrics(events: [event]))
                .contains { $0.kind == .credits })
        }
    }

    @Test func `an actual negative balance remains critical without funding history`() {
        for provider in [UsageProvider.codex, .openrouter, .kimi] {
            #expect(self.lights(provider: provider, metrics: self.balanceMetrics(provider: provider, value: -1))
                .contains { $0.kind == .credits && $0.severity == .critical })
        }
    }

    @Test func `aged cached display alone does not create an old reading warning`() {
        #expect(!self.evaluated(self.account()).contains { $0.kind == .oldReading })
    }

    @Test func `an explicit old reading condition remains visible`() {
        var account = self.account()
        account.warnings = [.init(.oldReading, .caution, "The latest refresh failed.", action: .refresh)]
        #expect(self.evaluated(account).contains { $0.kind == .oldReading })
    }

    private func window(
        used: Double = 0, minutes: Int = 300, reset: TimeInterval? = 18000, placeholder: Bool = false) -> RateWindow
    {
        .init(
            usedPercent: used,
            windowMinutes: minutes,
            resetsAt: reset.map(self.now.addingTimeInterval),
            resetDescription: nil,
            isSyntheticPlaceholder: placeholder)
    }

    private func unknownModel() -> UsageSnapshot {
        .init(
            primary: nil,
            secondary: self.window(minutes: 10080),
            extraRateWindows: [.init(
                id: "tertiary", title: "Fable", window: self.window(minutes: 10080, reset: 3600), usageKnown: false)],
            updatedAt: self.now)
    }

    private func quota(
        id: String, used: Double, minutes: Int, captured: TimeInterval, reset: TimeInterval)
        -> PlanUtilizationSeriesHistory
    {
        .init(name: .init(rawValue: "nativeQuota:" + id), windowMinutes: minutes, entries: [.init(
            capturedAt: self.now.addingTimeInterval(captured),
            usedPercent: used,
            resetsAt: self.now.addingTimeInterval(reset))])
    }

    private func codexMetrics(available: Bool? = nil, events: [CreditEvent] = []) -> NativeOrbitAccountMetrics {
        NativeOrbitAccountMetrics.make(
            provider: .codex,
            snapshot: nil,
            usage: nil,
            now: self.now,
            credits: .init(
                remaining: 0,
                events: events,
                updatedAt: self.now,
                balanceReadSucceeded: true,
                creditsAvailable: available))
    }

    private func unit(_ provider: UsageProvider) -> String {
        provider == .codex ? CodexExtraUsageCost.currencyCode : "USD"
    }

    private func balanceMetrics(provider: UsageProvider, value: Double) -> NativeOrbitAccountMetrics {
        var metrics = NativeOrbitAccountMetrics.empty
        metrics.reportedBalance = .init(
            value: value,
            unit: self.unit(provider),
            isWorkspace: false,
            updatedAt: self.now)
        return metrics
    }

    private func balances(_ values: [NativeOrbitReportedBalance]) -> [PlanUtilizationSeriesHistory] {
        [.init(name: .init(rawValue: "nativeMetric:balance"), windowMinutes: 0, entries: values.map { value in
            .init(capturedAt: value.updatedAt, usedPercent: 0, resetsAt: nil, nativeMetrics: .init(balance: value))
        })]
    }

    private func lights(
        provider: UsageProvider,
        snapshot: UsageSnapshot? = nil,
        metrics: NativeOrbitAccountMetrics = .empty,
        history: [PlanUtilizationSeriesHistory] = []) -> [NativeOrbitWarningLight]
    {
        NativeOrbitWarningSignals.account(
            provider: provider, snapshot: snapshot, metrics: metrics, history: history, now: self.now)
    }

    private func account() -> NativeOrbitAccountPresentation {
        var gauge = ComputeGauge.State()
        gauge.provider = "claude"
        return .init(
            id: "eligibility-fixture",
            label: "Fixture",
            email: nil,
            symbol: "person",
            isActive: true,
            canActivate: false,
            gauge: gauge,
            updatedAt: self.now.addingTimeInterval(-3600),
            history: [],
            odometer: nil,
            odometerHelp: nil,
            statusText: nil,
            selection: .none)
    }

    private func evaluated(_ account: NativeOrbitAccountPresentation) -> [NativeOrbitWarningLight] {
        let state = NativeOrbitPopupState()
        state.now = self.now
        state.accounts = [account]
        return NativeOrbitWarningEvaluation.lights(
            account: account,
            peers: [account],
            projection: state.projection(for: account),
            date: nil,
            now: self.now,
            days: 1)
    }
}
