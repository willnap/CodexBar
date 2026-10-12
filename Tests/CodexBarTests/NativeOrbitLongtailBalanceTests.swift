import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

/// Long-tail providers whose extra-usage balance is measured in credits or non-money units.
struct NativeOrbitLongtailBalanceTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Warp

    @Test
    func `Warp add-on credits become a credit balance that never establishes spend`() throws {
        let snapshot = try WarpUsageFetcher._parseResponseForTesting(Data(Self.warpResponse(grants: """
        "bonusGrants": [{"requestCreditsGranted": 500, "requestCreditsRemaining": 120}],
        "workspaces": [{"bonusGrantsInfo": {"grants": [
          {"requestCreditsGranted": 100, "requestCreditsRemaining": 30}
        ]}}]
        """).utf8)).toUsageSnapshot()
        let cost = try #require(snapshot.providerCost)
        #expect(cost.balance == 150)
        #expect(cost.currencyCode == "Credits")
        #expect(cost.usageIsUnavailable == true)
        #expect(cost.limit == 0)
        #expect(cost.spendLimitWindow == nil)
    }

    @Test
    func `Warp empty grant list measures a zero balance but a missing list measures nothing`() throws {
        let empty = try WarpUsageFetcher._parseResponseForTesting(Data(Self.warpResponse(grants: """
        "bonusGrants": [], "workspaces": []
        """).utf8)).toUsageSnapshot()
        #expect(empty.providerCost?.balance == 0)

        let missing = try WarpUsageFetcher._parseResponseForTesting(Data(Self.warpResponse(grants: """
        "workspaces": []
        """).utf8)).toUsageSnapshot()
        #expect(missing.providerCost == nil)
    }

    // MARK: - Augment

    @Test
    func `Augment remaining credits become a credit balance`() throws {
        let snapshot = AugmentStatusSnapshot(
            creditsRemaining: 11657,
            creditsUsed: 953_170,
            creditsLimit: 964_827,
            billingCycleEnd: nil,
            accountEmail: nil,
            accountPlan: nil,
            rawJSON: nil).toUsageSnapshot()
        let cost = try #require(snapshot.providerCost)
        #expect(cost.balance == 11657)
        #expect(cost.currencyCode == "Credits")
        #expect(cost.usageIsUnavailable == true)
        #expect(AugmentStatusSnapshot(
            creditsRemaining: nil,
            creditsUsed: 1,
            creditsLimit: 2,
            billingCycleEnd: nil,
            accountEmail: nil,
            accountPlan: nil,
            rawJSON: nil).toUsageSnapshot().providerCost == nil)
    }

    // MARK: - JetBrains

    @Test
    func `JetBrains top-up credits become a credit balance in displayed credits`() throws {
        let topUp = try #require(JetBrainsTopUpQuota(maximum: 5_489_986.397, available: 5_489_986.397))
        let snapshot = try JetBrainsStatusSnapshot(
            quotaInfo: JetBrainsQuotaInfo(
                type: "Available",
                used: 353_265.849,
                maximum: 1_000_000,
                available: 646_734.151,
                until: nil,
                topUp: topUp),
            refillInfo: nil,
            detectedIDE: nil).toUsageSnapshot()
        let cost = try #require(snapshot.providerCost)
        #expect(abs((cost.balance ?? 0) - 54.89986397) < 0.000001)
        #expect(cost.currencyCode == "Credits")
        #expect(cost.usageIsUnavailable == true)

        let withoutTopUp = try JetBrainsStatusSnapshot(
            quotaInfo: JetBrainsQuotaInfo(type: nil, used: 1, maximum: 2, available: nil, until: nil),
            refillInfo: nil,
            detectedIDE: nil).toUsageSnapshot()
        #expect(withoutTopUp.providerCost == nil)
    }

    // MARK: - Venice

    @Test
    func `Venice web session total credits become a credit balance`() throws {
        let snapshot = try VeniceWebUsageFetcher.snapshot(fromClaims: Self.veniceClaims(), now: self.now)
        let cost = try #require(snapshot.providerCost)
        #expect(cost.balance == 9600)
        #expect(cost.currencyCode == "Credits")
        #expect(cost.usageIsUnavailable == true)
        #expect(cost.balanceUpdatedAt == self.now)
    }

    #if canImport(JavaScriptCore)
    @Test
    func `Venice API balance keeps the consumption currency and never becomes money when it is DIEM`() async throws {
        let diem = try await Self.veniceAPI("""
        {"canConsume": true, "consumptionCurrency": "DIEM",
         "balances": {"diem": "90.50", "usd": "25.75"}, "diemEpochAllocation": 100}
        """)
        #expect(diem.primary?.usedPercent == 9.5)
        let diemCost = try #require(diem.providerCost)
        #expect(diemCost.balance == 90.5)
        #expect(diemCost.currencyCode == "DIEM")
        #expect(diemCost.usageIsUnavailable == true)

        let usd = try await Self.veniceAPI("""
        {"canConsume": true, "consumptionCurrency": "USD", "balances": {"diem": null, "usd": 25.75}}
        """)
        #expect(usd.primary?.resetDescription == "$25.75 USD remaining")
        #expect(usd.providerCost?.balance == 25.75)
        #expect(usd.providerCost?.currencyCode == "USD")
        #expect(usd.providerCost?.usageIsUnavailable == true)

        let bundled = try await Self.veniceAPI("""
        {"canConsume": true, "consumptionCurrency": "BUNDLED_CREDITS",
         "balances": {"diem": 50, "usd": 10}, "diemEpochAllocation": 100}
        """)
        #expect(bundled.providerCost == nil)
    }

    // MARK: - Ollama

    @Test(arguments: BundledPluginTestSupport.engines)
    func `Ollama API strategy attaches the typed wallet while the plugin snapshot stays upstream shaped`(
        engine: ProviderPluginEngineKind) async throws
    {
        let plugin = try await OllamaAPIBalanceTests.fetch(engine: engine)
        #expect(plugin.providerCost == nil)
        #expect(plugin.detailRow(label: "Credit balance")?.usageValue == 18.25)

        let usage = OllamaProviderDescriptor.attachingCreditBalance(to: plugin)
        let cost = try #require(usage.providerCost)
        #expect(cost.balance == 18.25)
        #expect(cost.currencyCode == "USD")
        #expect(cost.usageIsUnavailable == true)
        #expect(cost.spendLimitWindow == nil)
    }

    @Test
    func `Ollama API fetch strategy result carries the wallet balance`() async throws {
        let browserDetection = BrowserDetection(cacheTTL: 0)
        let context = ProviderFetchContext(
            runtime: .cli,
            sourceMode: .api,
            includeCredits: false,
            webTimeout: 15,
            webDebugDumpHTML: false,
            verbose: false,
            env: ["OLLAMA_API_KEY": "fixture-key"],
            settings: nil,
            fetcher: UsageFetcher(),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection)
        let strategy = OllamaProviderDescriptor.apiStrategy(
            transport: OllamaAPIBalanceTests.transport(OllamaAPIBalanceTests.fixture))
        let result = try await strategy.fetch(context)
        #expect(result.strategyID == "ollama.api")
        #expect(result.usage.providerCost?.balance == 18.25)
    }
    #endif

    @Test
    func `Ollama cookie wallet balance is typed from the captured amount`() throws {
        #expect(OllamaUsageParser.dollars("$1,234.50") == 1234.5)
        #expect(OllamaUsageParser.dollars("$0.00") == 0)
        #expect(OllamaUsageParser.dollars("1,234.50") == nil)
        #expect(OllamaUsageParser.dollars("$1.2.3") == nil)
        let usage = try OllamaUsageParser.parse(html: """
        <section><div><h2>Usage credits<span>pro</span></h2><span>$1,018.25</span>
        <p>Refills to $30 in 3 weeks.</p></div>
        <div><span>Monthly credits used</span><span>$4.50</span></div></section>
        """).toUsageSnapshot()
        let row = try #require(usage.detailRow(label: "Credit balance"))
        #expect(row.value == "$1,018.25")
        #expect(row.usageValue == 1018.25)
        #expect(OllamaProviderDescriptor.attachingCreditBalance(to: usage).providerCost?.balance == row.usageValue)
    }

    // MARK: - Native dial

    @Test
    func `Native metrics show non-money balances in their own unit without reported spend`() {
        for (unit, provider) in [("Credits", UsageProvider.warp), ("DIEM", .venice)] {
            let snapshot = UsageSnapshot(
                primary: nil,
                secondary: nil,
                providerCost: ProviderCostSnapshot(
                    used: 0,
                    limit: 0,
                    currencyCode: unit,
                    balance: 42,
                    balanceUpdatedAt: self.now,
                    usageIsUnavailable: true,
                    updatedAt: self.now),
                updatedAt: self.now)
            let metrics = NativeOrbitAccountMetrics.make(
                provider: provider, snapshot: snapshot, usage: nil, now: self.now)
            #expect(metrics.reportedBalance == NativeOrbitReportedBalance(
                value: 42, unit: unit, isWorkspace: false, updatedAt: self.now))
            #expect(metrics.reportedSpend == nil)
            #expect(metrics.extraUsageFraction == nil)
            let samples = UsageStore.nativeOrbitMetricSamples(provider: provider, snapshot: snapshot)
            #expect(samples.contains { $0.entry.nativeMetrics?.balance?.unit == unit })
        }
    }

    // MARK: - Saved-account cached reports

    @Test
    func `Saved account owns a cached report only when its credential fingerprint matches`() {
        let token = "WorkosCursorSessionToken=fixture-session"
        let owned = Self.cursorReport(fingerprint: CookieHeaderCache.credentialFingerprint(token))
        #expect(UsageStore.nativeOrbitCachedReport(owned, belongsTo: Self.account(token: "Cookie: \(token)")))
        #expect(!UsageStore.nativeOrbitCachedReport(owned, belongsTo: Self.account(token: "other=session")))
        #expect(!UsageStore.nativeOrbitCachedReport(
            Self.cursorReport(fingerprint: nil),
            belongsTo: Self.account(token: token)))
        #expect(!UsageStore.nativeOrbitCachedReport(owned, belongsTo: Self.account(token: "   ")))
        #expect(UsageStore.nativeOrbitCachedUsage(
            provider: .cursor, report: owned, bucketTimeZoneIdentifier: "UTC")?.scope == .account)
    }

    @Test
    func `Stale machine-local usage receipts never return as account totals`() {
        let histories = [
            PlanUtilizationSeriesHistory(name: "nativeMetric:usage", windowMinutes: 0, entries: []),
            PlanUtilizationSeriesHistory(name: "nativeMetric:balance", windowMinutes: 0, entries: []),
        ]
        for provider in [UsageProvider.grok, .mimo] {
            #expect(UsageStore.nativeOrbitHistoryDroppingMachineLocalReceipts(histories, provider: provider)
                .map(\.name.rawValue) == ["nativeMetric:balance"])
        }
        #expect(UsageStore.nativeOrbitHistoryDroppingMachineLocalReceipts(histories, provider: .bedrock).count == 2)
    }

    // MARK: - Fixtures

    private static func warpResponse(grants: String) -> String {
        """
        {"data": {"user": {"__typename": "UserOutput", "user": {
          "requestLimitInfo": {"isUnlimited": false, "nextRefreshTime": "2026-02-28T19:16:33.462988Z",
            "requestLimit": 1000, "requestsUsedSinceLastRefresh": 5},
          \(grants)
        }}}}
        """
    }

    private static func veniceClaims() -> [String: Any] {
        [
            "userType": "MAX",
            "bundledCredits": 9100,
            "veniceCredits": 9600,
            "exp": 1_893_456_000,
            "bundledCreditsUsage": [
                "availableCredits": 9100,
                "monthlyRefillCredits": 22500,
                "usedThisCycle": 13400,
            ] as [String: Any],
        ]
    }

    #if canImport(JavaScriptCore)
    private static func veniceAPI(_ body: String) async throws -> UsageSnapshot {
        let transport = ProviderHTTPTransportHandler { request in
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]))
            return (Data(body.utf8), response)
        }
        let runtime = try ProviderPluginRuntime(bundledPlugin: "venice", transport: transport)
        return try await runtime.fetchUsage(secrets: ["VENICE_API_KEY": "fixture-key"])
    }
    #endif

    private static func cursorReport(fingerprint: String?) -> CostUsageTokenSnapshot {
        CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: 10,
            last30DaysCostUSD: 1,
            credentialScopeFingerprint: fingerprint,
            daily: [],
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    private static func account(token: String) -> ProviderTokenAccount {
        ProviderTokenAccount(
            id: UUID(),
            label: "Fixture",
            token: token,
            addedAt: 0,
            lastUsed: nil)
    }
}
