import CodexBarCore
import Foundation
import Observation
import Testing
@testable import CodexBar

@MainActor
struct NativeGaugeStateTests {
    @Test func `provider status reaches the custom symbol without discarding usage`() {
        let store = self.store()
        store.snapshots[.kimi] = self.snapshot(used: 40)
        for (indicator, health) in [
            (ProviderStatusIndicator.minor, ComputeGauge.Health.live),
            (.major, .outage), (.critical, .outage), (.maintenance, .paused), (.none, .live),
        ] {
            store.statuses[.kimi] = ProviderStatus(indicator: indicator, description: nil, updatedAt: nil)
            let gauge = store.nativeServiceGauge(for: .kimi)
            #expect(gauge.health == health)
            #expect(gauge.resolvedWindows[0].usedFraction == 0.4)
        }
    }

    @Test(arguments: [UsageProvider.codex, .claude])
    func `minor provider incident does not mark fresh account usage stale`(provider: UsageProvider) {
        let snapshot = self.snapshot(used: 40)
        let gauge = NativeUsageGaugeProjection.state(provider: provider, snapshot: snapshot, status: .minor)
        #expect(gauge.health == .live)
        #expect(gauge.resolvedWindows[0].usedFraction == 0.4)
    }

    @Test func `minor provider incident preserves actual measurement health`() {
        let stale = NativeUsageGaugeProjection.state(
            provider: .claude,
            snapshot: self.snapshot(used: 40),
            error: "Usage refresh failed",
            status: .minor)
        #expect(stale.health == .stale)
        #expect(stale.resolvedWindows[0].usedFraction == 0.4)
        let unknown = NativeUsageGaugeProjection.state(provider: .claude, snapshot: nil, status: .minor)
        #expect(unknown.health == .unknown)
        let unavailable = NativeUsageGaugeProjection.state(
            provider: .claude, snapshot: nil, status: .minor, hasAccess: false)
        #expect(unavailable.health == .offline)
    }

    @Test func `weekly usage pace drives brief fast and slow symbol notices`() {
        let store = self.store()
        for (used, pace) in [(80.0, ComputeGauge.Pace.extreme), (58, .fast), (20, .slow), (50, .normal)] {
            store.snapshots[.kimi] = self.snapshot(used: used)
            #expect(store.nativeServiceGauge(for: .kimi).pace == pace)
        }
    }

    @Test func `disabled provider uses the disabled symbol even with a prior measurement`() {
        let store = self.store()
        store.snapshots[.kimi] = self.snapshot(used: 40)
        enableTestProviders([], settings: store.settings)
        #expect(store.nativeServiceGauge(for: .kimi).health == .disabled)
    }

    @Test func `typed missing credentials reach only their saved account with notifications disabled`() throws {
        let store = self.store()
        store.settings.addTokenAccount(provider: .kimi, label: "First", token: "fixture-first")
        store.settings.addTokenAccount(provider: .kimi, label: "Second", token: "fixture-second")
        let accounts = store.settings.tokenAccounts(for: .kimi)
        store.settings.setActiveTokenAccountIndex(0, for: .kimi)
        let first = try #require(UsageStore.warningTokenAccountDiscriminator(accounts[0]))
        let second = try #require(UsageStore.warningTokenAccountDiscriminator(accounts[1]))
        store.handleCredentialOutcome(provider: .kimi, account: first, result: .failure(KimiAPIError.invalidToken))
        #expect(store.nativeServiceGauge(for: .kimi).health == .authentication)
        store.handleCredentialOutcome(provider: .kimi, account: second, result: .success(self.result()))
        #expect(store.nativeServiceGauge(for: .kimi).health == .authentication)
        store.settings.setActiveTokenAccountIndex(1, for: .kimi)
        #expect(store.nativeServiceGauge(for: .kimi).health == .unknown)
        store.settings.setActiveTokenAccountIndex(0, for: .kimi)
        store.handleCredentialOutcome(provider: .kimi, account: first, result: .success(self.result(source: "cache")))
        #expect(store.nativeServiceGauge(for: .kimi).health == .authentication)
        store.handleCredentialOutcome(provider: .kimi, account: first, result: .failure(URLError(.timedOut)))
        #expect(store.nativeServiceGauge(for: .kimi).health == .authentication)
        store.handleCredentialOutcome(provider: .kimi, account: first, result: .success(self.result()))
        #expect(store.nativeServiceGauge(for: .kimi).health == .unknown)
    }

    @Test func `quota error text cannot manufacture an authentication state`() {
        let store = self.store()
        store.handleCredentialOutcome(provider: .kimi, result: .failure(
            ProviderFetchClassifiedError(kind: .rateLimited, message: "Token expired; login required")))
        #expect(store.nativeServiceGauge(for: .kimi).health == .unknown)
    }

    @Test func `typed auth changes alone wake the production icon observation and retained symbol`() {
        let store = self.store()
        let model = NativeGaugeRenderState()
        let recorder = NativeGaugeObservationRecorder()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        model.update(state: store.nativeServiceGauge(for: .kimi), accountID: nil, at: now)
        withObservationTracking {
            _ = store.iconObservationToken
        } onChange: {
            MainActor.assumeIsolated { recorder.changes += 1 }
        }
        store.handleCredentialOutcome(provider: .kimi, result: .failure(KimiAPIError.invalidToken))
        #expect(recorder.changes == 1)
        model.update(state: store.nativeServiceGauge(for: .kimi), accountID: nil, at: now.addingTimeInterval(60))
        #expect(model.state.health == .authentication)
        #expect(model.state.healthEventAt == now.addingTimeInterval(60))
        withObservationTracking {
            _ = store.iconObservationToken
        } onChange: {
            MainActor.assumeIsolated { recorder.changes += 1 }
        }
        store.handleCredentialOutcome(provider: .kimi, result: .success(self.result()))
        #expect(recorder.changes == 2)
        model.update(state: store.nativeServiceGauge(for: .kimi), accountID: nil, at: now.addingTimeInterval(120))
        #expect(model.state.health == .unknown)
        #expect(model.state.healthEventAt == now.addingTimeInterval(120))
    }

    @Test func `ClaudeSwap health cannot inherit a saved Claude token failure`() throws {
        let store = self.store()
        enableTestProviders([.claude], settings: store.settings)
        store.settings.addTokenAccount(provider: .claude, label: "Saved", token: "fixture-cookie")
        let account = try #require(store.settings.tokenAccounts(for: .claude).first)
        let scope = try #require(UsageStore.warningTokenAccountDiscriminator(account))
        store.selectNativeTokenAccount(account.id, for: .claude)
        #expect(store.settings.effectiveSelectedTokenAccount(for: .claude)?.id == account.id)
        store.handleCredentialOutcome(
            provider: .claude,
            account: scope,
            result: .failure(ClaudeOAuthFetchError.unauthorized))
        store.settings.claudeSwapEnabled = true
        store.settings.claudeSwapShowSingleAccount = true
        store.claudeSwapAccountSnapshots = [ProviderAccountUsageSnapshot(
            id: ProviderAccountIdentity(source: "claude-swap", opaqueID: "fixture-slot"),
            provider: .claude,
            displayLabel: "Adapter account",
            isActive: true,
            snapshot: self.snapshot(used: 40),
            error: nil,
            sourceLabel: "fixture")]
        #expect(store.nativeClaudeSwapOwnsPresentation)
        #expect(store.nativeServiceGauge(for: .claude).health == .live)
        #expect(store.nativeServiceGauge(for: .claude).resolvedWindows[0].usedFraction == 0.4)
    }

    @Test func `anonymous Claude scope follows accepted fingerprint profile and source only`() {
        let environment = ["CLAUDE_CONFIG_DIR": "/tmp/native-gauge-anonymous-claude-fixture"]
        let store = self.store(environment: environment)
        enableTestProviders([.claude], settings: store.settings)
        store.settings.claudeUsageDataSource = .oauth
        let profile = ClaudeOAuthCredentialsStore.credentialsProfileIdentifier(environment: environment)
        #expect(store.nativeClaudeCredentialProfileIdentifier == profile)
        let first = store.credentialAccount(provider: .claude, context: self.context(
            fingerprint: "fixture-first", source: "oauth", profile: profile))
        store.handleCredentialOutcome(
            provider: .claude,
            account: first,
            result: .failure(ClaudeOAuthFetchError.unauthorized))
        #expect(store.nativeServiceGauge(for: .claude).health == .authentication)
        store.settings.claudeUsageDataSource = .cli
        #expect(store.nativeServiceGauge(for: .claude).health == .unknown)
        store.settings.claudeUsageDataSource = .oauth
        _ = store.credentialAccount(provider: .claude, context: self.context(
            fingerprint: "fixture-second", source: "oauth", profile: profile))
        #expect(store.nativeServiceGauge(for: .claude).health == .unknown)
        _ = store.credentialAccount(provider: .claude, context: self.context(
            fingerprint: "fixture-first", source: "oauth", profile: "different-profile"))
        #expect(store.nativeServiceGauge(for: .claude).health == .unknown)
    }

    @Test func `missing Claude credentials use a validated profile scope instead of ambient default`() {
        let environment = ["CLAUDE_CONFIG_DIR": "/tmp/native-gauge-missing-claude-fixture"]
        let store = self.store(environment: environment)
        enableTestProviders([.claude], settings: store.settings)
        store.settings.claudeUsageDataSource = .oauth
        let profile = ClaudeOAuthCredentialsStore.credentialsProfileIdentifier(environment: environment)
        #expect(store.nativeClaudeCredentialProfileIdentifier == profile)
        let scope = store.credentialAccount(provider: .claude, context: self.context(
            fingerprint: nil, source: "oauth", profile: profile))
        #expect(scope != "default")
        store.handleCredentialOutcome(
            provider: .claude,
            account: scope,
            result: .failure(ClaudeOAuthCredentialsError.notFound))
        #expect(store.nativeServiceGauge(for: .claude).health == .authentication)
        store.handleCredentialOutcome(provider: .claude, account: scope, result: .success(self.result()))
        #expect(store.nativeServiceGauge(for: .claude).health == .unknown)
    }

    private func context(fingerprint: String?, source: String, profile: String) -> UsageStore
    .ProviderRefreshOutcomeContext {
        .init(
            generation: 0,
            includesCredits: false,
            claudeUsesConsumerAutoPipeline: true,
            codexExpectedGuard: nil,
            tokenAccount: nil,
            priorTokenAccountSnapshot: nil,
            codexLimitResetOwnerKey: nil,
            claudeOAuthHistoryPersistentRefHash: nil,
            claudeOAuthActiveAccountObservation: .stable(identity: nil),
            claudeCredentialFingerprint: fingerprint,
            claudeCredentialSource: source,
            claudeCredentialProfileIdentifier: profile)
    }

    private func result(source: String = "oauth") -> ProviderFetchResult {
        ProviderFetchResult(
            usage: UsageSnapshot(primary: nil, secondary: nil, updatedAt: Date()),
            credits: nil,
            dashboard: nil,
            sourceLabel: source,
            strategyID: "fixture",
            strategyKind: .oauth)
    }

    private func snapshot(used: Double) -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(
                usedPercent: used,
                windowMinutes: 10080,
                resetsAt: Date().addingTimeInterval(3.5 * 86400),
                resetDescription: nil),
            secondary: nil,
            updatedAt: Date())
    }

    private func store(environment: [String: String] = [:]) -> UsageStore {
        let settings = testSettingsStore(suiteName: "native-gauge-state", userDefaults: InMemoryUserDefaults())
        enableTestProviders([.kimi], settings: settings)
        settings.paceVisible = true
        settings.statusChecksEnabled = true
        return UsageStore(
            fetcher: UsageFetcher(environment: environment),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: environment)
    }
}

@MainActor
private final class NativeGaugeObservationRecorder {
    var changes = 0
}
