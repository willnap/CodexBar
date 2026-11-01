import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct NativeOrbitWarningLightTests {
    typealias Kind = NativeOrbitWarningLight.Kind

    @Test func `the native catalogue has all 51 independent lights`() {
        #expect(Kind.allCases.count == 51)
    }

    @Test func `secure transport errors stay separate from an unreachable host`() {
        #expect(self.kind(URLError(.secureConnectionFailed))?.name == "Secure connection failed")
        #expect(self.kind(URLError(.serverCertificateUntrusted))?.name == "Secure connection failed")
    }

    @Test func `provider protocol failures and capacity failures have distinct lamps`() {
        #expect(self.kind(ClaudeOAuthFetchError.invalidResponse)?.name == "Provider changed its data")
        #expect(self.kind(ClaudeOAuthFetchError.serverError(529, nil))?.name == "Overloaded")
        #expect(self.kind(ClaudeOAuthFetchError.serverError(503, "overloaded_error"))?.name == "Overloaded")
        #expect(self.kind(ClaudeOAuthFetchError.serverError(502, nil))?.name == "Usage figures failing")
        #expect(self.kind(ClaudeWebAPIFetcher.FetchError.cloudflareChallenge)?.name == "Blocked by a bot check")
        #expect(self.kind(ClaudeOAuthCredentialsError.keychainAccessRevoked)?.name == "Keychain access blocked")
    }

    private func kind(_ error: Error, _ provider: UsageProvider = .claude) -> Kind? {
        NativeOrbitFetchFault.light(for: error, provider: provider)?.kind
    }

    @Test func `failures light the light for their cause, from the error's type`() {
        #expect(self.kind(ClaudeOAuthFetchError.unauthorized) == .signIn)
        #expect(self.kind(CodexOAuthFetchError.unauthorized, .codex) == .signIn)
        #expect(self.kind(KimiAPIError.invalidToken, .kimi) == .signIn)
        #expect(self.kind(ClaudeOAuthFetchError.rateLimited(retryAfter: nil)) == .rateLimited)
        #expect(self.kind(ClaudeOAuthFetchError.serverError(429, nil)) == .rateLimited)
        #expect(self.kind(ClaudeOAuthFetchError.serverError(503, "Unavailable")) == .usageFailing)
        #expect(self.kind(CodexOAuthFetchError.serverError(500, nil), .codex) == .usageFailing)
        #expect(self.kind(CodexOAuthFetchError.serverError(403, nil), .codex) == .permission)
        #expect(self.kind(KimiAPIError.apiError("boom"), .kimi) == .usageFailing)
        #expect(self.kind(ClaudeOAuthFetchError.networkError(URLError(.notConnectedToInternet))) == .offline)
        #expect(self.kind(URLError(.timedOut)) == .offline)
        #expect(self.kind(KimiAPIError.networkError("offline"), .kimi) == .offline)
        #expect(self.kind(CodexOAuthFetchError.invalidResponse, .codex) == .apiChanged)
        #expect(self.kind(KimiAPIError.parseFailed("bad"), .kimi) == .apiChanged)
        #expect(self.kind(DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "x"))) == .apiChanged)
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
            == .usageFailing)
        #expect(self.kind(RPCWireError.requestFailed("GET … failed: 429 Too Many Requests"), .codex) == .rateLimited)
        #expect(self.kind(RPCWireError.startFailed("no codex binary"), .codex) == .helper)
        #expect(self.kind(RPCWireError.timeout(method: "account/rateLimits/read"), .codex) == .helper)
    }

    @Test func `classified provider errors map every kind`() {
        let expected: [ProviderFetchClassifiedError.Kind: Kind] = [
            .authenticationExpired: .signIn, .missingCredential: .signIn,
            .permissionDenied: .permission, .rateLimited: .rateLimited, .providerUnavailable: .usageFailing,
            .apiFailure: .usageFailing, .networkFailure: .offline, .parseFailure: .apiChanged,
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

    @Test func `each catalogue light has its own stable key and semantic symbol`() {
        #expect(Set(Kind.allCases.map(\.catalogueKey)).count == 51)
        #expect(Kind.allCases.allSatisfy { !$0.symbol.isEmpty && !$0.name.isEmpty && !$0.category.isEmpty })
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

    @Test func `a retired request cannot introduce or clear account warning state`() {
        let store = self.store()
        let key = CredentialNotificationKey(provider: .kimi, account: "default")
        store.handleCredentialOutcome(
            provider: .kimi, result: .failure(KimiAPIError.invalidToken), isCurrent: { false })
        #expect(store.nativeFetchFaults[key] == nil)
        #expect(!store.nativeAuthenticationFailures.contains(key))
        store.handleCredentialOutcome(provider: .kimi, result: .failure(KimiAPIError.invalidToken))
        #expect(store.nativeFetchFaults[key]?.kind == .signIn)
        store.handleCredentialOutcome(provider: .kimi, result: .success(self.result()), isCurrent: { false })
        #expect(store.nativeFetchFaults[key]?.kind == .signIn)
        #expect(store.nativeAuthenticationFailures.contains(key))
    }

    @Test func `each typed fetch fault is scoped and a verified fresh outcome clears it`() {
        let errors: [(Kind, any Error)] = [
            (.overloaded, ClaudeOAuthFetchError.serverError(529, nil)),
            (.usageFailing, ClaudeOAuthFetchError.serverError(502, nil)),
            (.rateLimited, ClaudeOAuthFetchError.rateLimited(retryAfter: nil)),
            (.apiChanged, ClaudeOAuthFetchError.invalidResponse),
            (.botCheck, ClaudeWebAPIFetcher.FetchError.cloudflareChallenge),
            (.unreachable, URLError(.cannotFindHost)),
            (.insecure, URLError(.serverCertificateUntrusted)),
            (.signIn, ClaudeOAuthFetchError.unauthorized),
            (.keychain, ClaudeOAuthCredentialsError.keychainAccessRevoked),
            (.permission, ClaudeOAuthFetchError.serverError(403, nil)),
            (.browserSession, ClaudeWebAPIFetcher.FetchError.noSessionKeyFound),
            (.unknownError, NSError(domain: "fixture", code: 123)),
            (.helper, ClaudeUsageError.claudeNotInstalled),
            (.update, ClaudeSwapListParserError.unsupportedSchemaVersion(999)),
            (.unavailableHere, ClaudeWebAPIFetcher.FetchError.notSupportedOnThisPlatform),
        ]
        let store = self.store()
        let key = CredentialNotificationKey(provider: .claude, account: "fixture")
        for (kind, error) in errors {
            store.handleCredentialOutcome(provider: .claude, account: "fixture", result: .failure(error))
            #expect(store.nativeFetchFaults[key]?.kind == kind)
            #expect(store.nativeFetchFaults[.init(provider: .codex, account: "fixture")] == nil)
            store.handleCredentialOutcome(provider: .claude, account: "fixture", result: .success(self.result()))
            #expect(store.nativeFetchFaults[key] == nil)
        }
    }

    @Test func `refresh activity records its deadline and clears on completion`() {
        let store = self.store()
        store.beginNativeWarningRefresh(.kimi)
        #expect(store.nativeWarningRefreshStartedAt[.kimi] != nil)
        store.nativeWarningRefreshStartedAt[.kimi] = Date().addingTimeInterval(-121)
        #expect(store.nativeOrbitWarnings(
            provider: .kimi,
            faultScope: nil,
            updatedAt: Date(),
            metrics: .empty,
            error: nil,
            extra: [],
            errorExplained: false)
            .contains { $0.kind == .refreshStuck })
        store.endNativeWarningRefresh(.kimi)
        #expect(store.nativeWarningRefreshStartedAt[.kimi] == nil)
        #expect(!store.nativeOrbitWarnings(
            provider: .kimi,
            faultScope: nil,
            updatedAt: Date(),
            metrics: .empty,
            error: nil,
            extra: [],
            errorExplained: false)
            .contains { $0.kind == .refreshStuck })
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
        #expect(lights.first?.action == .refresh)
        #expect(lights.first?.tooltip(account: nil).contains("Something odd happened") == false)
        #expect(lights.first?.tooltip(account: nil).contains("Second line") == false)
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

    @Test func `disabling status checks clears a failed status light until checks resume`() {
        let store = self.store()
        store.nativeStatusFetchFailures.insert(UsageProvider.kimi.instanceID)
        func kinds() -> Set<Kind> {
            Set(store.nativeOrbitWarnings(
                provider: .kimi,
                faultScope: nil,
                updatedAt: Date(),
                metrics: .empty,
                error: nil,
                extra: [],
                errorExplained: false).map(\.kind))
        }
        #expect(kinds().contains(.statusUnknown))
        store.settings.statusChecksEnabled = false
        #expect(!kinds().contains(.statusUnknown))
        store.settings.statusChecksEnabled = true
        #expect(kinds().contains(.statusUnknown))
        store.nativeStatusFetchFailures.remove(UsageProvider.kimi.instanceID)
        #expect(!kinds().contains(.statusUnknown))
    }

    @Test func `disabling extra usage clears its historical spend cap warning`() {
        let store = self.store()
        var metrics = NativeOrbitAccountMetrics.empty
        func kinds() -> Set<Kind> {
            Set(store.nativeOrbitWarnings(
                provider: .kimi,
                faultScope: nil,
                updatedAt: Date(),
                metrics: metrics,
                error: nil,
                extra: [],
                errorExplained: false).map(\.kind))
        }
        metrics.reportedSpend = ProviderCostSnapshot(
            used: 50, limit: 50, currencyCode: "USD", period: "Monthly", updatedAt: Date())
        #expect(kinds().contains(.spendCap))
        metrics.reportedSpend = ProviderCostSnapshot(
            used: 50, limit: 50, currencyCode: "USD", period: "Monthly", isDisabled: true, updatedAt: Date())
        #expect(!kinds().contains(.spendCap))
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
            errorExplained: false).map(\.kind) == [.autoRefreshOff])
        #expect(store.nativeOrbitWarnings(
            provider: .kimi,
            faultScope: nil,
            updatedAt: old,
            metrics: .empty,
            error: nil,
            extra: [],
            errorExplained: false).first { $0.kind == .autoRefreshOff }?.severity == .opportunity)
    }

    @Test func `partial local log scans light until a complete rescan replaces them`() {
        let store = self.store()
        func metrics(partial: Bool) -> NativeOrbitAccountMetrics {
            let report = CostUsageTokenSnapshot(
                sessionTokens: nil,
                sessionCostUSD: nil,
                last30DaysTokens: 0,
                last30DaysCostUSD: 0,
                historyScanIsPartial: partial,
                daily: [],
                updatedAt: Date())
            var metrics = NativeOrbitAccountMetrics.empty
            metrics.localCostUsage = .init(snapshot: report, scope: .localMachine, bucketTimeZoneIdentifier: nil)
            return metrics
        }
        func kinds(_ metrics: NativeOrbitAccountMetrics) -> Set<Kind> {
            Set(store.nativeOrbitWarnings(
                provider: .kimi,
                faultScope: nil,
                updatedAt: Date(),
                metrics: metrics,
                error: nil,
                extra: [],
                errorExplained: false).map(\.kind))
        }
        #expect(kinds(metrics(partial: true)).contains(.localLogs))
        #expect(!kinds(metrics(partial: false)).contains(.localLogs))
    }

    @Test func `system callbacks reach native lights and recovery clears the same live store`() {
        let store = self.store()
        let system = NativeOrbitSystemSignals.shared
        let now = Date()
        let originalFailures = system.historyWriteFailures
        let originalZone = TimeZone.autoupdatingCurrent.identifier
        defer {
            system.recordNetworkPath(isSatisfied: true)
            system.recordNotificationAuthorization(isDenied: false)
            system.recordHistoryWriteFailures(originalFailures)
            system.recordTimeZone(identifier: originalZone, at: .distantPast)
        }
        func kinds(at date: Date = Date()) -> Set<Kind> {
            Set(store.nativeOrbitWarnings(
                provider: .kimi,
                faultScope: nil,
                updatedAt: date,
                metrics: .empty,
                error: nil,
                extra: [],
                errorExplained: false,
                now: date).map(\.kind))
        }
        system.recordNetworkPath(isSatisfied: false)
        system.recordHistoryWriteFailures([.kimi])
        system.recordNotificationAuthorization(isDenied: true)
        store.settings.quotaWarningNotificationsEnabled = true
        let differentZone = originalZone == "Europe/London" ? "America/New_York" : "Europe/London"
        system.recordTimeZone(identifier: differentZone, at: now)
        #expect(kinds(at: now).isSuperset(of: [.macOffline, .storage, .notifications, .timeZone]))
        let live = store.nativeOrbitWarnings(
            provider: .kimi,
            faultScope: nil,
            updatedAt: now,
            metrics: .empty,
            error: nil,
            extra: [],
            errorExplained: false,
            now: now)
        #expect(live.first { $0.kind == .notifications }?.action == .notificationSettings)
        system.recordNetworkPath(isSatisfied: true)
        system.recordHistoryWriteFailures([])
        system.recordNotificationAuthorization(isDenied: false)
        #expect(kinds(at: now.addingTimeInterval(86401)).isDisjoint(with:
            [.macOffline, .storage, .notifications, .timeZone]))
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

    @Test func `adapter foreign-login and Keychain faults clear when the account reports healthy`() throws {
        let store = self.store()
        func account(_ status: ClaudeSwapUsageStatus) throws -> ProviderAccountUsageSnapshot {
            let list = ClaudeSwapAccountList(activeAccountNumber: 1, accounts: [
                ClaudeSwapAccountRow(
                    number: 1,
                    email: "fixture@example.invalid",
                    isActive: true,
                    usageStatus: status,
                    fiveHour: nil,
                    sevenDay: nil),
            ])
            return try #require(ClaudeSwapAccountProjection.accountSnapshots(from: list).first)
        }
        #expect(try store.nativeOrbitClaudeSwapWarnings(account(.foreignCredential)).lights
            .map(\.kind) == [.wrongAccount])
        #expect(try store.nativeOrbitClaudeSwapWarnings(account(.keychainUnavailable)).lights
            .map(\.kind) == [.keychain])
        #expect(try store.nativeOrbitClaudeSwapWarnings(account(.ok)).lights.isEmpty)
    }

    @Test func `claude-swap statuses map to conditions`() {
        let cases: [(ClaudeSwapUsageStatus, ProviderAccountCondition)] = [
            (.ok, .ok), (.tokenExpired, .usageUnavailable), (.reloginRequired, .credentialProblem),
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
