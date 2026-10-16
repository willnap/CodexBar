import CodexBarCore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBar

struct NativeOrbitPluginBalanceTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test(arguments: BundledPluginTestSupport.engines)
    func `explicit plugin balances preserve units without inventing spend or quota`(
        engine: ProviderPluginEngineKind) async throws
    {
        for (amount, unit) in [(12.5, "USD"), (75.0, "points"), (9.25, "HC"), (0.0, "credits"), (-2.5, "CNY")] {
            let snapshot = try await self.fetch("{balance:{value:\(amount),unit:'\(unit)'}}", engine: engine)
            let cost = try #require(snapshot.providerCost)
            #expect(cost.balance == amount)
            #expect(cost.currencyCode == unit)
            #expect(cost.balanceUpdatedAt == self.now)
            #expect(cost.usageIsUnavailable == true)
            #expect(snapshot.measuredRateWindows.isEmpty)
            let metrics = NativeOrbitAccountMetrics.make(
                provider: .tinyapi,
                snapshot: snapshot,
                usage: nil,
                now: self.now)
            #expect(metrics.reportedSpend == nil)
            #expect(metrics.summary(days: 7, now: self.now).cost == nil)
            #expect(metrics.reportedBalance?.value == amount)
            #expect(metrics.reportedBalance?.unit == unit)
            #expect(NativeOrbitMonetaryInstrument.mode(provider: .tinyapi, windows: [], metrics: metrics) == .balance)
            let reading = NativeOrbitMonetaryInstrument.reading(
                mode: .balance,
                metrics: metrics,
                days: 7,
                now: self.now)
            #expect(reading.amount == amount)
            #expect(reading.currencyCode == unit)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `explicit balance source time survives polling`(engine: ProviderPluginEngineKind) async throws {
        let source = self.now.addingTimeInterval(-600)
        let date = ISO8601DateFormatter().string(from: source)
        let snapshot = try await self.fetch(
            "{balance:{value:25,unit:'USD',updatedAt:'\(date)'}}", engine: engine)
        #expect(snapshot.updatedAt == self.now)
        #expect(snapshot.providerCost?.balanceUpdatedAt == source)
        let metrics = NativeOrbitAccountMetrics.make(provider: .moonshot, snapshot: snapshot, usage: nil, now: self.now)
        #expect(metrics.reportedBalance?.updatedAt == source)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `explicit balances reject malformed values units and dates`(engine: ProviderPluginEngineKind) async {
        let invalid = [
            "[]", "12", "'12'", "true", "{}", "{value:12}", "{unit:'USD'}",
            "{value:'12',unit:'USD'}", "{value:true,unit:'USD'}", "{value:null,unit:'USD'}",
            "{value:NaN,unit:'USD'}", "{value:Infinity,unit:'USD'}",
            "{value:12,unit:12}", "{value:12,unit:''}", "{value:12,unit:'   '}",
            "{value:12,unit:'USD\\ncredits'}", "{value:12,unit:'USD',updatedAt:'bad-date'}",
            "{value:12,unit:'USD',updatedAt:'2099-01-01T00:00:00Z'}",
            "{value:12,unit:'USD',unknown:true}",
        ]
        for value in invalid {
            await #expect(throws: ProviderPluginError.self) {
                try await self.fetch("{balance:\(value)}", engine: engine)
            }
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `a second cost pool cannot silently replace an explicit balance`(engine: ProviderPluginEngineKind) async {
        await #expect(throws: ProviderPluginError.self) {
            try await self.fetch(
                "{balance:{value:12,unit:'points'},cost:{used:5,currency:'USD'}}", engine: engine)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `detail values alone never become an inferred balance`(engine: ProviderPluginEngineKind) async throws {
        let snapshot = try await self.fetch(
            "{details:[{title:'Account',rows:[{label:'Credits',value:'12 points',usageValue:12}]}]}", engine: engine)
        #expect(snapshot.providerCost == nil)
        #expect(snapshot.measuredRateWindows.isEmpty)
    }

    private func fetch(
        _ payload: String, engine: ProviderPluginEngineKind, at date: Date? = nil) async throws -> UsageSnapshot
    {
        let source = """
        defineProvider({id:'tinyapi',name:'Balance fixture',endpoints:['https://fixture.invalid'],
          settings:[],async fetchUsage(ctx){return \(payload);}});
        """
        return try await ProviderPluginRuntime(source: source, engine: engine).fetchUsage(now: date ?? self.now)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `explicit unavailable balance records a tombstone that breaks funding continuity`(
        engine: ProviderPluginEngineKind) async throws
    {
        let absent = try await self.fetch(
            "{balance:null}", engine: engine, at: self.now.addingTimeInterval(-300))
        #expect(absent.providerCost?.balance == nil)
        #expect(absent.providerCost?.balanceUpdatedAt == self.now.addingTimeInterval(-300))
        #expect(absent.providerCost?.usageIsUnavailable == true)
        let absentSamples = UsageStore.nativeOrbitMetricSamples(provider: .tinyapi, snapshot: absent)
        #expect(absentSamples.contains {
            $0.name.rawValue == "nativeMetric:balance" && $0.entry.nativeMetrics?.balance == nil
        })
        let positive = try await self.fetch(
            "{balance:{value:12,unit:'credits'}}", engine: engine, at: self.now.addingTimeInterval(-900))
        let zero = try await self.fetch("{balance:{value:0,unit:'credits'}}", engine: engine)
        let samples = [positive, absent, zero].flatMap {
            UsageStore.nativeOrbitMetricSamples(provider: .tinyapi, snapshot: $0)
        }.filter { $0.name.rawValue == "nativeMetric:balance" }
        #expect(samples.count == 3)
        let history = [PlanUtilizationSeriesHistory(
            name: .init(rawValue: "nativeMetric:balance"), windowMinutes: 0, entries: samples.map(\.entry))]
        let metrics = NativeOrbitAccountMetrics.make(provider: .tinyapi, snapshot: zero, usage: nil, now: self.now)
        let balance = try #require(metrics.reportedBalance)
        #expect(!NativeOrbitWarningEvidence.wasFunded(balance, history: history))
        #expect(NativeOrbitMonetaryInspection.balanceRate(balance, history: history) == nil)
        let omitted = try await self.fetch("{empty:true}", engine: engine)
        #expect(UsageStore.nativeOrbitMetricSamples(provider: .tinyapi, snapshot: omitted)
            .allSatisfy { $0.name.rawValue != "nativeMetric:balance" })
        await #expect(throws: ProviderPluginError.self) {
            try await self.fetch("{balance:null,cost:{used:3,currency:'USD'}}", engine: engine)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `unavailable wallet in measured spend retains its own dated absence`(
        engine: ProviderPluginEngineKind) async throws
    {
        let date = ISO8601DateFormatter().string(from: self.now.addingTimeInterval(-300))
        let snapshot = try await self.fetch(
            "{cost:{used:3.25,currency:'USD',balance:null,balanceUpdatedAt:'\(date)'}}", engine: engine)
        #expect(snapshot.providerCost?.used == 3.25)
        #expect(snapshot.providerCost?.balance == nil)
        #expect(snapshot.providerCost?.balanceUpdatedAt == self.now.addingTimeInterval(-300))
        let samples = UsageStore.nativeOrbitMetricSamples(provider: .sailresearch, snapshot: snapshot)
        #expect(samples.contains {
            $0.name.rawValue == "nativeMetric:balance" && $0.entry.nativeMetrics?.balance == nil
                && $0.entry.capturedAt == self.now.addingTimeInterval(-300)
        })
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `explicit subscription evidence preserves billing status and rejects wrong types`(
        engine: ProviderPluginEngineKind) async throws
    {
        let snapshot = try await self.fetch(
            "{empty:true,subscriptionStatus:'past_due',subscriptionIsActive:false}", engine: engine)
        #expect(snapshot.subscriptionStatus == "past_due")
        #expect(snapshot.subscriptionIsActive == false)
        for payload in [
            "{empty:true,subscriptionStatus:3}", "{empty:true,subscriptionStatus:true}",
            "{empty:true,subscriptionStatus:[]}", "{empty:true,subscriptionStatus:{}}",
            "{empty:true,subscriptionIsActive:'false'}", "{empty:true,subscriptionIsActive:0}",
            "{empty:true,subscriptionIsActive:[]}", "{empty:true,subscriptionIsActive:{}}",
        ] {
            await #expect(throws: ProviderPluginError.self) { try await self.fetch(payload, engine: engine) }
        }
    }

    @Test(
        arguments: ["moonshot", "poe", "hyper", "linkup", "tinyapi", "sofya", "sailresearch"],
        BundledPluginTestSupport.engines)
    func `actual balance plugins preserve source values through native projection`(
        provider: String, engine: ProviderPluginEngineKind) async throws
    {
        for amount in [12.5, 0] {
            let snapshot = try await self.bundled(provider, amount: amount, engine: engine)
            let owner = try #require(UsageProvider(rawValue: provider))
            let unit = ["poe": "points", "hyper": "HC", "tinyapi": "credits", "sofya": "credits"][provider] ?? "USD"
            let metrics = NativeOrbitAccountMetrics.make(provider: owner, snapshot: snapshot, usage: nil, now: self.now)
            #expect(snapshot.measuredRateWindows.isEmpty)
            #expect(metrics.reportedBalance?.value == amount)
            #expect(metrics.reportedBalance?.unit == unit)
            #expect(metrics.reportedBalance?.updatedAt == self.now)
            if provider == "sailresearch" {
                #expect(metrics.reportedSpend?.used == 3.25)
                #expect(metrics.reportedSpend?.period == "Last 7 days spend")
            } else {
                #expect(metrics.reportedSpend == nil)
            }
            #expect(NativeOrbitMonetaryInstrument.mode(provider: owner, windows: [], metrics: metrics) == .balance)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `optional balances remain absent instead of combining separate pools`(
        engine: ProviderPluginEngineKind) async throws
    {
        for provider in ["poe", "sofya", "sailresearch"] {
            let snapshot = try await self.bundled(provider, amount: nil, engine: engine)
            #expect(snapshot.providerCost?.balance == nil)
            #expect(snapshot.providerCost?.balanceUpdatedAt == self.now)
            if provider == "sailresearch" { #expect(snapshot.providerCost?.used == 3.25) }
        }
    }

    @Test(arguments: ["sub2api", "sakana", "zai", "museai", "manus"], BundledPluginTestSupport.engines)
    func `optional wallet balances coexist with their own subscription quotas`(
        provider: String, engine: ProviderPluginEngineKind) async throws
    {
        let owner = try #require(UsageProvider(rawValue: provider))
        let unit = ["sub2api": "credits", "zai": "CNY", "manus": "credits"][provider] ?? "USD"
        for amount in [12.5, 0, nil] as [Double?] {
            let snapshot = try await self.bundled(provider, amount: amount, engine: engine)
            let metrics = NativeOrbitAccountMetrics.make(provider: owner, snapshot: snapshot, usage: nil, now: self.now)
            #expect(metrics.reportedBalance?.value == amount)
            #expect(metrics.reportedBalance?.unit == (amount == nil ? nil : unit))
            #expect(metrics.reportedSpend == nil)
            if amount == nil { #expect(snapshot.providerCost?.balanceUpdatedAt == self.now) }
            if ["sakana", "zai", "museai"].contains(provider) {
                #expect(snapshot.measuredRateWindows.first?.usedPercent == 25)
            }
        }
    }

    private func bundled(
        _ provider: String, amount: Double?, engine: ProviderPluginEngineKind) async throws -> UsageSnapshot
    {
        let transport = ProviderHTTPTransportHandler { request in
            let url = try #require(request.url)
            let value = amount.map { String($0) } ?? "null"
            let body: String = switch provider {
            case "moonshot":
                """
                {"code":0,"scode":"0","status":true,
                "data":{"available_balance":\(value),"cash_balance":\(value),"voucher_balance":0}}
                """
            case "poe": url.path.hasSuffix("current_balance")
                ? "{\"current_point_balance\":\(value)}" : "{\"data\":[]}"
            case "hyper", "linkup": "{\"balance\":\(value)}"
            case "tinyapi": "{\"success\":true,\"data\":{\"totalAvailable\":\(value)}}"
            case "sofya": amount == nil
                ? "{\"plan_credits\":10,\"purchased_credits\":2.5}"
                : "{\"credits\":\(value),\"plan_credits\":10,\"purchased_credits\":2.5}"
            case "sub2api": "{\"mode\":\"unrestricted\",\"isValid\":true,\"balance\":\(value),\"unit\":\"credits\"}"
            case "manus": amount == nil ? "{\"freeCredits\":0}" : "{\"totalCredits\":\(value)}"
            case "sakana": url.query == nil
                ? "<p>5-hour</p><p>25% used</p>"
                : amount == nil ? "<html></html>"
                : "<h2>Credit balance</h2><p class=\"tabular-nums\">$\(value)</p>"
            case "zai": url.path.contains("quota")
                ? """
                {"code":200,"success":true,"data":{"limits":[
                {"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":25}]}}
                """
                : url.path.contains("account") ? "{\"success\":true,\"data\":{\"availableBalance\":\(value)}}"
                : "{\"code\":200,\"success\":true,\"data\":{}}"
            case "museai":
                """
                1:{"success":true,"subscription":{"usage":{"percentUsed":25},
                "topupBalance":\(amount.map { String($0 * 1e6) } ?? "null"),"topupTotal":20000000}}
                """.replacingOccurrences(of: "\n", with: "")
            default:
                """
                {"object":"usage.summary","available":true,"has_metronome_customer":true,
                "balance_unavailable":\(amount == nil),"balance":\((amount ?? 0) * 100),
                "period_spend":325,"effective_range":"7d"}
                """
            }
            return try (Data(body.utf8), #require(HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
        // Read the actual checked-in source, not a previously packaged plugin resource.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/CodexBarCore/Resources/Plugins/\(provider).js"),
            encoding: .utf8)
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: storage) }
        if provider == "museai" {
            try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
            let data = Data(#"{"version":1,"values":{"actionID":"fixture-action"}}"#.utf8)
            try data.write(to: storage.appendingPathComponent("museai.json"))
        }
        return try await ProviderPluginRuntime(
            source: source, transport: transport, engine: engine, storageDirectory: storage).fetchUsage(
            settings: [
                "BASE_URL": "https://api.moonshot.ai", "SUB2API_BASE_URL": "https://sub2api.fixture",
                "Z_AI_REGION": "bigmodel-cn",
            ],
            secrets: [
                "MOONSHOT_API_KEY": "fixture", "POE_API_KEY": "fixture", "HYPER_API_KEY": "fixture",
                "LINKUP_API_KEY": "fixture", "SOFYA_API_KEY": "fixture", "SAIL_API_KEY": "fixture",
                "SUB2API_API_KEY": "fixture", "SAKANA_COOKIE": "session=fixture", "Z_AI_API_KEY": "fixture",
            ],
            now: self.now,
            cookieSource: .manual,
            cookieResolver: { _, _ in "session_id=synthetic" })
    }
}
