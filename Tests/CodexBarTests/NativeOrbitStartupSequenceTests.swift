import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct NativeOrbitStartupSequenceTests {
    @Test func `arming and completing startup preserve the actual account evidence`() async {
        let state = NativeOrbitPopupState()
        let account = self.account()
        state.accounts = [account]
        state.badges = [account.id: "Fixture badge"]
        state.startupHistoryReady = false
        state.startupStatusReady = false
        let now = state.now
        state.armStartup(reduceMotion: false)
        #expect(state.startup == .armed)
        #expect(state.startupCheckpoint == 0)
        #expect(!state.isBulbCheck)
        self.expectEvidence(state, matches: account)
        await state.runStartup()
        #expect(state.startup == .live)
        #expect(state.startupCheckpoint == 4)
        #expect(!state.isBulbCheck)
        #expect(!state.startupHistoryReady && !state.startupStatusReady)
        #expect(state.now == now)
        #expect(state.badges == [account.id: "Fixture badge"])
        self.expectEvidence(state, matches: account)
    }

    @Test func `reduced startup reveals actual readings without testing bulbs or changing evidence`() async {
        let state = NativeOrbitPopupState()
        let account = self.account()
        state.accounts = [account]
        state.armStartup(reduceMotion: true)
        #expect(state.startup == .reduced)
        #expect(!state.startup.testsLamps)
        #expect(!state.isBulbCheck)
        self.expectEvidence(state, matches: account)
        await state.runStartup()
        #expect(state.startup == .live)
        #expect(state.startupCheckpoint == 0)
        #expect(!state.isBulbCheck)
        self.expectEvidence(state, matches: account)
    }

    @Test func `finishing while the sweep sleeps prevents its later checkpoints from returning`() async {
        let state = NativeOrbitPopupState()
        state.armStartup(reduceMotion: false)
        let running = await self.startSweep(state)
        state.finishStartup()
        await running.value
        #expect(state.startup == .live)
        #expect(state.startupCheckpoint == 0)
        #expect(!state.isBulbCheck)
    }

    @Test func `a sleeping previous generation cannot advance a newly armed startup`() async {
        let state = NativeOrbitPopupState()
        state.armStartup(reduceMotion: false)
        let previous = await self.startSweep(state)
        state.finishStartup()
        state.armStartup(reduceMotion: false)
        await previous.value
        #expect(state.startup == .armed)
        #expect(state.startupCheckpoint == 0)
        state.finishStartup()
    }

    @Test func `cancelling a previous generation cannot finish a newly armed startup`() async {
        let state = NativeOrbitPopupState()
        state.armStartup(reduceMotion: false)
        let previous = await self.startSweep(state)
        state.finishStartup()
        state.armStartup(reduceMotion: true)
        previous.cancel()
        await previous.value
        #expect(state.startup == .reduced)
        #expect(state.startupCheckpoint == 0)
        state.finishStartup()
    }

    @Test func `a task cancelled before it runs leaves the newly armed generation alone`() async {
        let state = NativeOrbitPopupState()
        state.armStartup(reduceMotion: false)
        let previous = Task { @MainActor in await state.runStartup() }
        // The test owns the main actor until await, so the previous task has not entered runStartup yet.
        previous.cancel()
        state.finishStartup()
        state.armStartup(reduceMotion: false)
        await previous.value
        #expect(state.startup == .armed)
        #expect(state.startupCheckpoint == 0)
        state.finishStartup()
    }

    @Test func `cancelling the current sweep returns to its real live display`() async {
        let state = NativeOrbitPopupState()
        state.armStartup(reduceMotion: false)
        let running = await self.startSweep(state)
        running.cancel()
        await running.value
        #expect(state.startup == .live)
        #expect(state.startupCheckpoint == 0)
        #expect(!state.isBulbCheck)
    }

    @Test func `beginning historical inspection finishes the startup before changing the inspected date`() async {
        let state = NativeOrbitPopupState()
        state.armStartup(reduceMotion: false)
        let running = await self.startSweep(state)
        let inspected = Date(timeIntervalSince1970: 1_700_000_000)
        state.inspect(inspected)
        #expect(state.startup == .live)
        #expect(state.inspectionDate == inspected)
        await running.value
        #expect(state.startup == .live)
        #expect(state.startupCheckpoint == 0)
    }

    @Test func `arming clears inspection and stationary synthetic hover cannot cancel any startup stage`() {
        let state = NativeOrbitPopupState()
        let pointer = CGPoint(x: 240, y: 320)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        for phase in [NativeOrbitStartupPhase.armed, .sweeping, .settling, .reduced] {
            state.inspectionDate = date
            state.armStartup(reduceMotion: phase == .reduced, pointerLocation: pointer)
            #expect(state.inspectionDate == nil)
            state.startup = phase
            state.startupCheckpoint = 1
            state.inspect(date, source: "hover", pointerLocation: pointer)
            #expect(state.startup == phase)
            #expect(state.startupCheckpoint == 1)
            #expect(state.inspectionDate == nil)
            state.finishStartup()
        }
    }

    @Test func `a real pointer move still interrupts the running sweep and reveals the inspected reading`() async {
        let state = NativeOrbitPopupState()
        let pointer = CGPoint(x: 240, y: 320)
        state.armStartup(reduceMotion: false, pointerLocation: pointer)
        let running = await self.startSweep(state)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        state.inspect(date, source: "hover", pointerLocation: CGPoint(x: pointer.x + 1, y: pointer.y))
        #expect(state.startup == .live)
        #expect(state.inspectionDate == date)
        await running.value
        #expect(state.startup == .live)
        #expect(state.startupCheckpoint == 0)
    }

    @Test func `startup hover policy checks actual pointer position without a timing or distance threshold`() {
        let pointer = CGPoint(x: 240, y: 320)
        let policy = NativeOrbitStartupHoverPolicy(armedPosition: pointer)
        #expect(!policy.acceptsHover(at: pointer))
        #expect(policy.acceptsHover(at: CGPoint(x: pointer.x + 0.01, y: pointer.y)))
    }

    @Test func `startup readiness comes from actual receipts and terminal status rather than the clock`() {
        let state = NativeOrbitPopupState()
        state.startupHistoryReady = false
        state.startupStatusReady = false
        state.armStartup(reduceMotion: false)
        state.startupCheckpoint = 4
        #expect(state.startupReadiness(for: self.account(updatedAt: nil)) == .pending)
        #expect(state.startupReadiness(for: self.account()) == .init(
            readingReady: true, historyReady: false, statusReady: false))
        #expect(state.startupReadiness(for: self.account(updatedAt: nil, statusText: "Fixture sign in required"))
            == .init(readingReady: true, historyReady: false, statusReady: false))
        state.finishStartup()
        #expect(state.startupReadiness(for: self.account(updatedAt: nil)) == .pending)
    }

    @Test func `account switch sweep follows a confirmed owner change and ignores temporary missing owners`() {
        var selection = NativeOrbitStartupSelection()
        let owners: [String?] = ["personal", "personal", nil, "personal", "work", "work", "personal"]
        let replayed = owners.map { selection.receive(activeID: $0) }
        #expect(replayed == [false, false, false, false, true, false, true])
    }

    private func startSweep(_ state: NativeOrbitPopupState) async -> Task<Void, Never> {
        let running = Task { @MainActor in await state.runStartup() }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while state.startup == .armed, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(state.startup == .sweeping)
        return running
    }

    @Test func `warning memo follows direct inspection changes and replacement account evidence`() throws {
        let state = NativeOrbitPopupState()
        var account = self.account()
        state.now = try #require(account.updatedAt)
        state.accounts = [account]
        #expect(state.warningLights(for: state.accounts[0]).contains { $0.kind == .billing })
        state.inspectionDate = state.now.addingTimeInterval(-3600)
        #expect(!state.warningLights(for: state.accounts[0]).contains { $0.kind == .billing })
        state.inspectionDate = nil
        #expect(state.warningLights(for: state.accounts[0]).contains { $0.kind == .billing })
        account.warnings = []
        state.accounts = [account]
        #expect(!state.warningLights(for: state.accounts[0]).contains { $0.kind == .billing })
    }

    @Test func `an unavailable spending chart is reconsidered after account evidence changes`() throws {
        let state = NativeOrbitPopupState()
        var account = self.account()
        state.now = try #require(account.updatedAt)
        state.accounts = [account]
        #expect(state.spendingHistory(for: state.accounts[0]) == nil)
        var moneyGauge = ComputeGauge.State()
        moneyGauge.provider = UsageProvider.openrouter.rawValue
        moneyGauge.windows = [.init(id: "monetary-budget", label: "Budget", period: 86400, used: 0.1)]
        account = self.account(gaugeOverride: moneyGauge, histories: [])
        account.metrics.reportedSpend = ProviderCostSnapshot(
            used: 10, limit: 100, currencyCode: "USD", updatedAt: state.now)
        state.accounts = [account]
        #expect(state.spendingHistory(for: state.accounts[0]) != nil)
    }

    @Test func `range changes keep complete quota marks and update the exact observation snap span`() {
        let state = NativeOrbitPopupState()
        state.now = Date(timeIntervalSince1970: 1_700_000_000)
        let older = state.now.addingTimeInterval(-2 * 86400)
        let history = self.account().history + [PlanUtilizationSeriesHistory(
            name: "nativeMetric:usage",
            windowMinutes: 0,
            entries: [.init(capturedAt: older, usedPercent: 0, resetsAt: nil)])]
        state.accounts = [self.account(histories: history)]
        let account = state.accounts[0]
        let dates = state.lanes(for: account).flatMap { $0.samples.map(\.date) }
        #expect(!state.observationDates(for: account).contains(older))
        state.days = 7
        #expect(state.observationDates(for: account).contains(older))
        #expect(state.lanes(for: account).flatMap { $0.samples.map(\.date) } == dates)
        state.days = 1
        #expect(!state.observationDates(for: account).contains(older))
    }

    private func expectEvidence(_ state: NativeOrbitPopupState, matches account: NativeOrbitAccountPresentation) {
        #expect(state.accounts.count == 1)
        #expect(state.accounts.first?.id == account.id)
        #expect(state.accounts.first?.gauge == account.gauge)
        #expect(state.accounts.first?.updatedAt == account.updatedAt)
        #expect(state.accounts.first?.history == account.history)
        #expect(state.accounts.first?.odometer == account.odometer)
        #expect(state.accounts.first?.warnings == account.warnings)
    }

    private func account(
        updatedAt: Date? = Date(timeIntervalSince1970: 1_700_000_000),
        statusText: String? = nil,
        gaugeOverride: ComputeGauge.State? = nil,
        histories: [PlanUtilizationSeriesHistory]? = nil) -> NativeOrbitAccountPresentation
    {
        let observed = Date(timeIntervalSince1970: 1_700_000_000)
        var gauge = ComputeGauge.State()
        gauge.provider = UsageProvider.codex.rawValue
        gauge.weeklyUsed = 0.27
        gauge.fiveHourUsed = 0.61
        gauge.accessibilityDescription = "Fixture account has 73 percent weekly allowance remaining"
        var account = NativeOrbitAccountPresentation(
            id: "startup-fixture",
            label: "Fixture",
            email: nil,
            symbol: "person",
            isActive: false,
            canActivate: false,
            gauge: gaugeOverride ?? gauge,
            updatedAt: updatedAt,
            history: histories ?? [.init(name: "nativeQuota:primary", windowMinutes: 300, entries: [
                .init(capturedAt: observed, usedPercent: 61, resetsAt: nil),
            ])],
            odometer: "12345",
            odometerHelp: "Fixture token reading",
            statusText: statusText,
            selection: .none)
        account.warnings = [.init(.billing, .critical, "Fixture billing fault")]
        return account
    }
}
