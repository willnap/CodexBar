import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct NativeOrbitWarningLightTests {
    typealias Kind = NativeOrbitWarningLight.Kind

    private func kind(_ error: Error, _ provider: UsageProvider = .claude) -> Kind? {
        NativeOrbitFetchFault.light(for: error, provider: provider)?.kind
    }

    @Test func `failures light the light for their cause, from the error's type`() {
        #expect(self.kind(ClaudeOAuthFetchError.unauthorized) == .signIn)
        #expect(self.kind(CodexOAuthFetchError.unauthorized, .codex) == .signIn)
        #expect(self.kind(KimiAPIError.invalidToken, .kimi) == .signIn)
        #expect(self.kind(ClaudeOAuthFetchError.rateLimited(retryAfter: nil)) == .rateLimited)
        #expect(self.kind(ClaudeOAuthFetchError.serverError(429, nil)) == .rateLimited)
        #expect(self.kind(ClaudeOAuthFetchError.serverError(503, "Unavailable")) == .providerIncident)
        #expect(self.kind(CodexOAuthFetchError.serverError(500, nil), .codex) == .providerIncident)
        #expect(self.kind(CodexOAuthFetchError.serverError(403, nil), .codex) == .signIn)
        #expect(self.kind(KimiAPIError.apiError("boom"), .kimi) == .providerIncident)
        #expect(self.kind(ClaudeOAuthFetchError.networkError(URLError(.notConnectedToInternet))) == .offline)
        #expect(self.kind(URLError(.timedOut)) == .offline)
        #expect(self.kind(KimiAPIError.networkError("offline"), .kimi) == .offline)
        #expect(self.kind(CodexOAuthFetchError.invalidResponse, .codex) == .readFailed)
        #expect(self.kind(KimiAPIError.parseFailed("bad"), .kimi) == .readFailed)
        #expect(self.kind(DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "x"))) == .readFailed)
        #expect(self.kind(ClaudeUsageError.claudeNotInstalled) == .helper)
        #expect(self.kind(ProviderFetchError.noAvailableStrategy(.kiro), .kiro) == .helper)
    }

    @Test func `a Codex app-server request failure lights by the status it reports`() {
        #expect(CodexRPCFailure.httpStatus(of: RPCWireError.requestFailed(
            "failed to fetch codex rate limits: GET https://chatgpt.com/backend-api/wham/usage failed: 401 Unauthorized"))
            == 401)
        #expect(CodexRPCFailure.httpStatus(of: RPCWireError.requestFailed("socket closed")) == nil)
        #expect(self.kind(RPCWireError.requestFailed("GET … failed: 401 Unauthorized; body={"), .codex) == .signIn)
        #expect(self.kind(RPCWireError.requestFailed("GET … failed: 503 Service Unavailable"), .codex)
            == .providerIncident)
        #expect(self.kind(RPCWireError.requestFailed("GET … failed: 429 Too Many Requests"), .codex) == .rateLimited)
        #expect(self.kind(RPCWireError.startFailed("no codex binary"), .codex) == .helper)
        #expect(self.kind(RPCWireError.timeout(method: "account/rateLimits/read"), .codex) == .readFailed)
    }

    @Test func `classified provider errors map every kind`() {
        let expected: [ProviderFetchClassifiedError.Kind: Kind] = [
            .authenticationExpired: .signIn, .missingCredential: .signIn,
            .permissionDenied: .signIn, .rateLimited: .rateLimited, .providerUnavailable: .providerIncident,
            .apiFailure: .providerIncident, .networkFailure: .offline, .parseFailure: .readFailed,
        ]
        for errorKind in ProviderFetchClassifiedError.Kind.allCases {
            let error = ProviderFetchClassifiedError(kind: errorKind, message: "fixture")
            #expect(self.kind(error) == expected[errorKind], "\(errorKind)")
        }
    }

    @Test func `cancellation lights nothing`() {
        #expect(self.kind(CancellationError()) == nil)
        #expect(self.kind(URLError(.cancelled)) == nil)
        #expect(self.kind(ClaudeOAuthFetchError.networkError(URLError(.cancelled))) == nil)
    }

    @Test func `sign-in and limit failures are red; the rest amber`() {
        #expect(NativeOrbitFetchFault.light(for: ClaudeOAuthFetchError.unauthorized, provider: .claude)?.severity
            == .critical)
        #expect(NativeOrbitFetchFault.light(for: URLError(.timedOut), provider: .claude)?.severity == .caution)
    }

    @Test func `one light per kind, its most severe reading, in spot order`() {
        let merged = NativeOrbitWarningLight.merged([
            .init(.oldReading, .caution, "a"),
            .init(.quota, .caution, "projected"),
            .init(.quota, .critical, "reached"),
            .init(.signIn, .critical, "key"),
            .init(.quota, .caution, "projected again"),
        ])
        #expect(merged.map(\.kind) == [.signIn, .quota, .oldReading])
        #expect(merged.first { $0.kind == .quota }?.detail == "reached")
    }

    @Test(arguments: [1, 2, 3])
    func `every light has its own spot, clear of the marks and inside the innermost ring`(lanes: Int) {
        let size = NativeOrbitWarningLightsView.size(lanes: lanes)
        let spots = Kind.allCases.map { NativeOrbitWarningLightsView.spot($0, lanes: lanes) }
        #expect(Set(spots.map { "\($0.x),\($0.y)" }).count == Kind.allCases.count)
        // The innermost ring's inner edge, in the 216 pt dial.
        let scale: CGFloat = 216 / NativeOrbitSymbol.canvas
        let free = (NativeOrbitSymbol.radii[lanes - 1] - NativeOrbitSymbol.stroke / 2) * scale
        // The marks in the dial's middle (`NativeOrbitGaugeWidget.identity`): parent mark, product mark, badge.
        let compact = lanes == 3
        let marks = [
            CGRect(x: -7.5, y: (compact ? -24 : -34) - 7.5, width: 15, height: 15),
            CGRect(x: compact ? -14 : -21, y: compact ? -11 : -17, width: compact ? 28 : 42, height: compact ? 22 : 34),
            CGRect(x: -8.5, y: (compact ? 24 : 44) - 8.5, width: 17, height: 17),
        ]
        for (kind, spot) in zip(Kind.allCases, spots) {
            #expect(hypot(spot.x, spot.y) + size / 2 < free, "\(kind) leaves the dial's middle")
            let lamp = CGRect(x: spot.x - size / 2, y: spot.y - size / 2, width: size, height: size)
            #expect(!marks.contains { $0.intersects(lamp) }, "\(kind) covers a mark")
            #expect((spot.x < 0) == (kind.rawValue < NativeOrbitWarningLightsView.perSide), "\(kind) on the wrong side")
        }
        // Neighbours down a side never overlap.
        for side in 0..<2 {
            let column = spots[(side * 6)..<(side * 6 + 6)]
            for (upper, lower) in zip(column, column.dropFirst()) {
                #expect(hypot(upper.x - lower.x, upper.y - lower.y) > size)
            }
        }
    }

    @Test func `a failed fetch lights its account's light until a fresh reading turns it off`() {
        let store = self.store()
        let key = CredentialNotificationKey(provider: .kimi, account: "default")
        store.handleCredentialOutcome(provider: .kimi, result: .failure(URLError(.notConnectedToInternet)))
        #expect(store.nativeFetchFaults[key]?.kind == .offline)
        // A cached reading cannot prove the provider is reachable again.
        store.handleCredentialOutcome(provider: .kimi, result: .success(self.result(source: "cache")))
        #expect(store.nativeFetchFaults[key]?.kind == .offline)
        store.handleCredentialOutcome(provider: .kimi, result: .failure(CancellationError()))
        #expect(store.nativeFetchFaults[key]?.kind == .offline)
        store.handleCredentialOutcome(provider: .kimi, result: .success(self.result()))
        #expect(store.nativeFetchFaults[key] == nil)
        store.handleCredentialOutcome(
            provider: .kimi, account: "other", result: .failure(KimiAPIError.invalidToken))
        #expect(store.nativeFetchFaults[key] == nil)
        #expect(store.nativeFetchFaults[.init(provider: .kimi, account: "other")]?.kind == .signIn)
    }

    @Test func `an error nothing else explains lights the reading-failed light`() {
        let store = self.store()
        let lights = store.nativeOrbitWarnings(
            provider: .kimi,
            faultScope: nil,
            updatedAt: Date(),
            metrics: .empty,
            error: "Something odd happened.\nSecond line",
            extra: [],
            errorExplained: false)
        #expect(lights.map(\.kind) == [.readFailed])
        #expect(lights.first?.detail == "Couldn’t read usage: Something odd happened.")
        let explained = store.nativeOrbitWarnings(
            provider: .kimi,
            faultScope: nil,
            updatedAt: Date(),
            metrics: .empty,
            error: "API-key account",
            extra: [],
            errorExplained: true)
        #expect(explained.isEmpty)
        let keyed = store.nativeOrbitWarnings(
            provider: .kimi,
            faultScope: nil,
            updatedAt: Date(),
            metrics: .empty,
            error: "Token expired",
            extra: [.init(.signIn, .critical, "Token expired")],
            errorExplained: false)
        #expect(keyed.map(\.kind) == [.signIn])
    }

    @Test func `provider status lights the incident or the maintenance light`() {
        let store = self.store()
        store.statuses[UsageProvider.kimi.instanceID] = ProviderStatus(
            indicator: .major, description: "Elevated errors", updatedAt: Date())
        var lights = store.nativeOrbitWarnings(
            provider: .kimi,
            faultScope: nil,
            updatedAt: Date(),
            metrics: .empty,
            error: nil,
            extra: [],
            errorExplained: false)
        #expect(lights.map(\.kind) == [.providerIncident])
        #expect(lights.first?.severity == .critical)
        #expect(lights.first?.action == .statusPage)
        store.statuses[UsageProvider.kimi.instanceID] = ProviderStatus(
            indicator: .maintenance, description: nil, updatedAt: Date())
        lights = store.nativeOrbitWarnings(
            provider: .kimi,
            faultScope: nil,
            updatedAt: Date(),
            metrics: .empty,
            error: nil,
            extra: [],
            errorExplained: false)
        #expect(lights.map(\.kind) == [.maintenance])
    }

    @Test func `an old reading lights the clock unless refresh is manual`() {
        let store = self.store()
        store.settings.refreshFrequency = .fiveMinutes
        let old = Date().addingTimeInterval(-20 * 60)
        #expect(store.nativeOrbitWarnings(
            provider: .kimi,
            faultScope: nil,
            updatedAt: old,
            metrics: .empty,
            error: nil,
            extra: [],
            errorExplained: false).map(\.kind) == [.oldReading])
        #expect(store.nativeOrbitWarnings(
            provider: .kimi,
            faultScope: nil,
            updatedAt: Date().addingTimeInterval(-10 * 60),
            metrics: .empty,
            error: nil,
            extra: [],
            errorExplained: false).isEmpty)
        store.settings.refreshFrequency = .manual
        #expect(store.nativeOrbitWarnings(
            provider: .kimi,
            faultScope: nil,
            updatedAt: old,
            metrics: .empty,
            error: nil,
            extra: [],
            errorExplained: false).isEmpty)
    }

    @Test func `extra usage near its cap lights the spend-cap light`() {
        let store = self.store()
        var metrics = NativeOrbitAccountMetrics.empty
        metrics.reportedSpend = ProviderCostSnapshot(
            used: 46, limit: 50, currencyCode: "USD", period: "Monthly", updatedAt: Date())
        var lights = store.nativeOrbitWarnings(
            provider: .kimi,
            faultScope: nil,
            updatedAt: Date(),
            metrics: metrics,
            error: nil,
            extra: [],
            errorExplained: false)
        #expect(lights.map(\.kind) == [.spendCap])
        #expect(lights.first?.severity == .caution)
        metrics.reportedSpend = ProviderCostSnapshot(
            used: 50, limit: 50, currencyCode: "USD", period: "Monthly", updatedAt: Date())
        lights = store.nativeOrbitWarnings(
            provider: .kimi,
            faultScope: nil,
            updatedAt: Date(),
            metrics: metrics,
            error: nil,
            extra: [],
            errorExplained: false)
        #expect(lights.first?.severity == .critical)
        metrics.reportedSpend = ProviderCostSnapshot(
            used: 10, limit: 50, currencyCode: "USD", period: "Monthly", updatedAt: Date())
        #expect(store.nativeOrbitWarnings(
            provider: .kimi,
            faultScope: nil,
            updatedAt: Date(),
            metrics: metrics,
            error: nil,
            extra: [],
            errorExplained: false).isEmpty)
    }

    @Test func `claude-swap statuses light the sign-in, old-reading and helper lights`() {
        let store = self.store()
        func row(_ condition: ProviderAccountCondition, lastKnown: Bool = false) -> ProviderAccountUsageSnapshot {
            ProviderAccountUsageSnapshot(
                id: .init(source: ClaudeSwapAccountProjection.sourceName, opaqueID: "1"),
                provider: .claude,
                displayLabel: "fixture@example.invalid",
                isActive: true,
                usesLastKnownUsage: lastKnown,
                snapshot: UsageSnapshot(primary: nil, secondary: nil, updatedAt: Date().addingTimeInterval(-3600)),
                error: condition == .ok ? nil : "Token expired. Switch to this account in claude-swap to refresh it.",
                sourceLabel: ClaudeSwapAccountProjection.sourceLabel,
                condition: condition)
        }
        #expect(store.nativeOrbitClaudeSwapWarnings(row(.credentialProblem)).lights.map(\.kind) == [.signIn])
        #expect(store.nativeOrbitClaudeSwapWarnings(row(.ok, lastKnown: true)).lights.map(\.kind) == [.oldReading])
        #expect(store.nativeOrbitClaudeSwapWarnings(row(.notApplicable)).explained)
        store.claudeSwapLastError = "cswap: command not found"
        #expect(store.nativeOrbitClaudeSwapWarnings(row(.ok)).lights.map(\.kind) == [.helper])
    }

    @Test func `claude-swap statuses map to conditions`() {
        let cases: [(ClaudeSwapUsageStatus, ProviderAccountCondition)] = [
            (.ok, .ok), (.tokenExpired, .credentialProblem), (.reloginRequired, .credentialProblem),
            (.keychainUnavailable, .credentialProblem), (.noCredentials, .credentialProblem),
            (.foreignCredential, .credentialProblem), (.unavailable, .usageUnavailable), (.apiKey, .notApplicable),
            (.unknown("new"), .unrecognized),
        ]
        for (status, condition) in cases {
            #expect(ClaudeSwapAccountProjection.condition(for: status) == condition)
        }
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

    private func store() -> UsageStore {
        let settings = testSettingsStore(suiteName: "native-warning-lights", userDefaults: InMemoryUserDefaults())
        enableTestProviders([.kimi], settings: settings)
        settings.statusChecksEnabled = true
        return UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
    }
}
