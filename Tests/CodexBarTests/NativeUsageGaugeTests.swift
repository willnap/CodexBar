import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct NativeUsageGaugeTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func `recorded local usage selects one Codex two Claude and two Kimi bars`() {
        /// Values read from the local app's saved usage on 2026-10-10, without account identifiers.
        func window(_ used: Double, minutes: Int) -> RateWindow {
            RateWindow(usedPercent: used, windowMinutes: minutes, resetsAt: nil, resetDescription: nil)
        }
        let codex = UsageSnapshot(primary: nil, secondary: window(48, minutes: 10080), updatedAt: self.now)
        let codexGauge = NativeUsageGaugeProjection.state(
            provider: .codex,
            snapshot: codex,
            codexProjection: self.projection(snapshot: codex))
        #expect(codexGauge.resolvedWindows.map(\.id) == ["weekly"])
        #expect(codexGauge.resolvedWindows[0].usedFraction == 0.48)
        let claude = UsageSnapshot(
            primary: window(59, minutes: 300),
            secondary: window(43, minutes: 10080),
            updatedAt: self.now)
        let claudeGauge = NativeUsageGaugeProjection.state(provider: .claude, snapshot: claude)
        #expect(claudeGauge.resolvedWindows.map(\.usedFraction) == [0.43, 0.59])
        let kimi = UsageSnapshot(
            primary: nil,
            secondary: window(0, minutes: 300),
            extraRateWindows: [NamedRateWindow(
                id: "kimi-monthly",
                title: "Total usage",
                window: window(56.7, minutes: ProviderPaceCapability.monthlyWindowSentinelMinutes))],
            updatedAt: self.now)
        let kimiGauge = NativeUsageGaugeProjection.state(provider: .kimi, snapshot: kimi)
        #expect(kimiGauge.resolvedWindows.map(\.id) == ["kimi-monthly", "secondary"])
        #expect(abs((kimiGauge.resolvedWindows[0].usedFraction ?? 0) - 0.567) < 0.000001)
        #expect(kimiGauge.resolvedWindows[1].usedFraction == 0)
    }

    @Test func `missing usage stays unknown instead of showing sample values`() {
        let state = NativeUsageGaugeProjection.state(provider: .codex, snapshot: nil)
        #expect(state.health == .unknown)
        #expect(state.resolvedWindows.count == 1)
        #expect(state.resolvedWindows.first?.usedFraction == nil)
    }

    @Test func `real windows preserve amounts ordering and provider reset deadlines`() {
        let deadline = self.now.addingTimeInterval(3600)
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 0, windowMinutes: 300, resetsAt: deadline, resetDescription: nil),
            secondary: RateWindow(usedPercent: 140, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            updatedAt: self.now)
        let state = NativeUsageGaugeProjection.state(provider: .claude, snapshot: snapshot)
        #expect(state.productID == "claudecode")
        #expect(state.resolvedWindows.map(\.id) == ["secondary", "primary"])
        #expect(state.resolvedWindows[0].usedFraction == 1)
        #expect(state.resolvedWindows[1].usedFraction == 0)
        #expect(state.resolvedWindows[1].countdown?.nextReset == deadline)
        #expect(state.resolvedWindows[0].countdown?.nextReset == nil)
    }

    @Test func `synthetic session does not create a phantom quota ring`() {
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 0,
                windowMinutes: 300,
                resetsAt: nil,
                resetDescription: nil,
                isSyntheticPlaceholder: true),
            secondary: RateWindow(usedPercent: 25, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            updatedAt: self.now)
        let state = NativeUsageGaugeProjection.state(provider: .claude, snapshot: snapshot)
        #expect(state.resolvedWindows.count == 1)
        #expect(state.resolvedWindows[0].id == "secondary")
    }

    @Test func `reported regeneration projects next recovery instead of a full reset`() {
        let deadline = self.now.addingTimeInterval(600)
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 75,
                windowMinutes: 1440,
                resetsAt: deadline,
                resetDescription: nil,
                nextRegenPercent: 12.5),
            secondary: nil,
            updatedAt: self.now)
        let window = NativeUsageGaugeProjection.state(provider: .claude, snapshot: snapshot).resolvedWindows[0]
        #expect(window.recovery == .nextRecovery)
        #expect(window.recoveryDescription(at: self.now) == "Next recovery in 10m")
        #expect(window.usedFraction == 0.75)
        #expect(window.countdown?.nextReset == deadline)
    }

    @Test func `regeneration without a deadline stays unknown`() {
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 75,
                windowMinutes: 1440,
                resetsAt: nil,
                resetDescription: nil,
                nextRegenPercent: 12.5),
            secondary: nil,
            updatedAt: self.now)
        let window = NativeUsageGaugeProjection.state(provider: .claude, snapshot: snapshot).resolvedWindows[0]
        #expect(window.recovery == .nextRecovery)
        #expect(window.recoveryDescription(at: self.now) == "Next recovery time unknown")
        #expect(window.countdown?.nextReset == nil)
    }

    @Test func `missing or invalid regeneration does not invent a recovery tick`() {
        for amount: Double? in [nil, 0, -1, .nan, .infinity] {
            let snapshot = UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 75,
                    windowMinutes: 1440,
                    resetsAt: self.now.addingTimeInterval(600),
                    resetDescription: nil,
                    nextRegenPercent: amount),
                secondary: nil,
                updatedAt: self.now)
            let window = NativeUsageGaugeProjection.state(provider: .claude, snapshot: snapshot).resolvedWindows[0]
            #expect(window.recovery == .reset)
        }
    }

    @Test func `invalid percentage is unknown and elapsed reset never restores capacity`() {
        let deadline = self.now.addingTimeInterval(-60)
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: .nan, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 100, windowMinutes: 300, resetsAt: deadline, resetDescription: nil),
            updatedAt: self.now)
        let state = NativeUsageGaugeProjection.state(provider: .kimi, snapshot: snapshot)
        #expect(state.resolvedWindows.first(where: { $0.id == "primary" })?.usedFraction == nil)
        #expect(state.resolvedWindows.first(where: { $0.id == "secondary" })?.usedFraction == 1)
        #expect(state.resolvedWindows.first(where: { $0.id == "secondary" })?.countdown?.nextReset == deadline)
    }

    @Test func `clicking another service switches directly and clicking again closes`() {
        var route = NativeServicePresentationRoute()
        route.toggle(.codex)
        #expect(route.provider == .codex)
        route.toggle(.claude)
        #expect(route.provider == .claude)
        route.toggle(.claude)
        #expect(route.provider == nil)
    }

    @Test func `Codex weekly exhaustion also caps the short window gauge`() {
        let weeklyReset = self.now.addingTimeInterval(86400)
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 1,
                windowMinutes: 300,
                resetsAt: self.now.addingTimeInterval(3600),
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 120,
                windowMinutes: 10080,
                resetsAt: weeklyReset,
                resetDescription: nil), updatedAt: self.now)
        let projection = self.projection(snapshot: snapshot)
        let state = NativeUsageGaugeProjection.state(
            provider: .codex, snapshot: snapshot, codexProjection: projection)
        #expect(state.resolvedWindows.first(where: { $0.id == "session" })?.usedFraction == 1)
        #expect(state.resolvedWindows.first(where: { $0.id == "session" })?.countdown?.nextReset == weeklyReset)
    }

    @Test func `real Codex monthly credit quota renders before rate usage loads`() {
        let reset = self.now.addingTimeInterval(14 * 86400)
        let credits = CreditsSnapshot(
            remaining: 0,
            events: [],
            updatedAt: self.now,
            codexCreditLimit: CodexCreditLimitSnapshot(
                used: 27,
                limit: 100,
                remainingPercent: 73,
                resetsAt: reset,
                updatedAt: self.now))
        let state = NativeUsageGaugeProjection.state(
            provider: .codex, snapshot: nil, codexProjection: self.projection(credits: credits))
        #expect(state.health == .live)
        #expect(state.resolvedWindows.count == 1)
        #expect(state.resolvedWindows[0].id == "monthly")
        #expect(state.resolvedWindows[0].usedFraction == 0.27)
        #expect(state.resolvedWindows[0].countdown?.nextReset == reset)
        #expect(state.resolvedWindows[0].countdown?.isReliable == false)
    }

    @Test func `credit balance alone does not invent a quota or percentage`() {
        let credits = CreditsSnapshot(remaining: 42, events: [], updatedAt: self.now)
        let state = NativeUsageGaugeProjection.state(
            provider: .codex, snapshot: nil, codexProjection: self.projection(credits: credits))
        #expect(state.health == .unknown)
        #expect(state.resolvedWindows[0].usedFraction == nil)
    }

    @Test func `Kimi monthly limit is a third real gauge window`() {
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 22, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 81, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            extraRateWindows: [NamedRateWindow(
                id: "kimi-monthly",
                title: "Monthly",
                window: RateWindow(
                    usedPercent: 97,
                    windowMinutes: 43200,
                    resetsAt: self.now.addingTimeInterval(86400),
                    resetDescription: nil))],
            updatedAt: self.now)
        let state = NativeUsageGaugeProjection.state(provider: .kimi, snapshot: snapshot)
        #expect(state.resolvedWindows.map(\.id) == ["kimi-monthly", "primary", "secondary"])
        #expect(state.resolvedWindows.map(\.usedFraction) == [0.97, 0.22, 0.81])
    }

    @Test func `unknown named quota never becomes an empty allowance`() {
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            extraRateWindows: [NamedRateWindow(
                id: "kimi-monthly",
                title: "Monthly",
                window: RateWindow(
                    usedPercent: 0, windowMinutes: 43200, resetsAt: nil, resetDescription: nil),
                usageKnown: false)],
            updatedAt: self.now)
        let state = NativeUsageGaugeProjection.state(provider: .kimi, snapshot: snapshot)
        #expect(state.resolvedWindows[0].id == "kimi-monthly")
        #expect(state.resolvedWindows[0].usedFraction == nil)
    }

    @Test @MainActor func `switching saved accounts changes both gauge and card and clears an uncached account`() {
        let settings = testSettingsStore(
            suiteName: "NativeAccountGauge", userDefaults: InMemoryUserDefaults())
        settings.addTokenAccount(provider: .kimi, label: "Personal", token: "fixture-personal")
        settings.addTokenAccount(provider: .kimi, label: "Work", token: "fixture-work")
        settings.addTokenAccount(provider: .kimi, label: "New", token: "fixture-new")
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        let accounts = settings.tokenAccounts(for: .kimi)
        for (index, percent) in [(0, 12.0), (1, 89.0)] {
            store.cacheTokenAccountSnapshot(
                provider: .kimi,
                account: accounts[index],
                snapshot: UsageSnapshot(
                    primary: RateWindow(
                        usedPercent: percent,
                        windowMinutes: 10080,
                        resetsAt: nil,
                        resetDescription: nil),
                    secondary: nil,
                    updatedAt: self.now),
                sourceLabel: "fixture")
        }
        settings.setActiveTokenAccountIndex(0, for: .kimi)
        store.activateCachedTokenAccountSnapshot(provider: .kimi, accountID: accounts[0].id)
        #expect(store.nativeServiceGauge(for: .kimi).resolvedWindows[0].usedFraction == 0.12)
        settings.setActiveTokenAccountIndex(1, for: .kimi)
        store.activateCachedTokenAccountSnapshot(provider: .kimi, accountID: accounts[1].id)
        #expect(store.nativeServiceGauge(for: .kimi).resolvedWindows[0].usedFraction == 0.89)
        #expect(store.nativeServiceCardModel(for: .kimi).metrics.first?.percent == 11)
        settings.setActiveTokenAccountIndex(2, for: .kimi)
        store.activateCachedTokenAccountSnapshot(provider: .kimi, accountID: accounts[2].id)
        #expect(store.nativeServiceGauge(for: .kimi).resolvedWindows[0].usedFraction == nil)
        #expect(store.nativeServiceCardModel(for: .kimi).metrics.isEmpty)
    }

    private func projection(snapshot: UsageSnapshot? = nil, credits: CreditsSnapshot? = nil)
    -> CodexConsumerProjection {
        CodexConsumerProjection.make(surface: .menuBar, context: .init(
            snapshot: snapshot,
            rawUsageError: nil,
            liveCredits: credits,
            rawCreditsError: nil,
            liveDashboard: nil,
            rawDashboardError: nil,
            dashboardAttachmentAuthorized: false,
            dashboardRequiresLogin: false,
            now: self.now))
    }
}
