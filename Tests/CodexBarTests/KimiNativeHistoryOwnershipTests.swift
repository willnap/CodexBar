import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct KimiNativeHistoryOwnershipTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func `Kimi requests attach stable opaque credential ownership across both transports`() async throws {
        let transport = ProviderHTTPTransportHandler { request in
            let url = try #require(request.url)
            let body = if url.path.hasSuffix("/usages") {
                #"{"usage":{"limit":"100","used":"25","remaining":"75"}}"#
            } else if url.path.hasSuffix("/GetUsages") {
                #"{"usages":[{"scope":"FEATURE_CODING","detail":{"limit":"100","used":"25"}}]}"#
            } else {
                "{}"
            }
            return try (Data(body.utf8), #require(HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
        let first = try await KimiUsageFetcher.fetchCodeAPIUsage(
            apiKey: "fixture-one", now: self.now, transport: transport).toUsageSnapshot()
        let repeated = try await KimiUsageFetcher.fetchCodeAPIUsage(
            apiKey: "fixture-one", now: self.now.addingTimeInterval(60), transport: transport).toUsageSnapshot()
        let rotated = try await KimiUsageFetcher.fetchCodeAPIUsage(
            apiKey: "fixture-two", now: self.now, transport: transport).toUsageSnapshot()
        let otherRegion = try await KimiUsageFetcher.fetchCodeAPIUsage(
            apiKey: "fixture-one", region: .international, now: self.now, transport: transport).toUsageSnapshot()
        let web = try await KimiUsageFetcher.fetchUsage(
            authToken: "fixture-one", now: self.now, transport: transport).toUsageSnapshot()
        let owner = try #require(first.identity?.accountID)
        #expect(owner.hasPrefix("kimi-credential-v1:"))
        #expect(!owner.contains("fixture-one"))
        #expect(owner == repeated.identity?.accountID)
        #expect(owner != rotated.identity?.accountID)
        #expect(owner != otherRegion.identity?.accountID)
        #expect(owner != web.identity?.accountID)
        #expect(web.identity?.accountID != nil)
        #expect(first.identity?.accountEmail == nil)
        let enriched = try await KimiUsageFetcher.fetchCodeAPIUsage(
            apiKey: "fixture-one", webAuthToken: "fixture-web", now: self.now, transport: transport).toUsageSnapshot()
        #expect(owner != enriched.identity?.accountID)
    }

    @Test func `Kimi history survives reload and isolates credential rotation without adopting unscoped data`()
        async throws
    {
        let store = self.store()
        let old = PlanUtilizationSeriesHistory(name: "nativeQuota:primary", windowMinutes: 10080, entries: [
            .init(capturedAt: self.now.addingTimeInterval(-60), usedPercent: 99, resetsAt: nil),
        ])
        store.planUtilizationHistory[.kimi] = PlanUtilizationHistoryBuckets(unscoped: [old])
        let first = try self.snapshot(credential: "fixture-one", at: self.now)
        let repeated = try self.snapshot(credential: "fixture-one", at: self.now.addingTimeInterval(60))
        for snapshot in [first, repeated] {
            store.snapshots[.kimi] = snapshot
            await store.recordPlanUtilizationHistorySample(provider: .kimi, snapshot: snapshot)
        }
        let firstKey = try #require(UsageStore.planUtilizationIdentityAccountKey(provider: .kimi, snapshot: first))
        #expect(store.planUtilizationHistory[.kimi]?.accounts[firstKey]?
            .first { $0.name.rawValue == "nativeQuota:primary" }?.entries.count == 2)
        #expect(store.planUtilizationHistory[.kimi]?.unscoped == [old])
        let rotated = try self.snapshot(credential: "fixture-two", at: self.now.addingTimeInterval(120))
        store.snapshots[.kimi] = rotated
        await store.recordPlanUtilizationHistorySample(provider: .kimi, snapshot: rotated)
        let rotatedKey = try #require(UsageStore.planUtilizationIdentityAccountKey(provider: .kimi, snapshot: rotated))
        #expect(rotatedKey != firstKey)
        #expect(store.nativeOrbitAccounts(for: .kimi)[0].history.filter(\.name.isNativeQuotaObservation)
            .allSatisfy { $0.entries.count == 1 && $0.entries.first?.capturedAt == rotated.updatedAt })
        let reloaded = self.store()
        reloaded.planUtilizationHistory = store.planUtilizationHistory
        reloaded.snapshots[.kimi] = try JSONDecoder().decode(UsageSnapshot.self, from: JSONEncoder().encode(repeated))
        #expect(reloaded.planUtilizationHistorySelection(for: .kimi, readOnly: true).accountKey == firstKey)
        #expect(reloaded.nativeOrbitAccounts(for: .kimi)[0].history.first {
            $0.name.rawValue == "nativeQuota:primary"
        }?.entries.count == 2)
        reloaded.snapshots[.kimi] = UsageSnapshot(primary: first.primary, secondary: nil, updatedAt: self.now)
        #expect(reloaded.planUtilizationHistorySelection(for: .kimi, readOnly: true).accountKey == nil)
    }

    @Test func `rotating JWT access and enrichment tokens retain one successful account timeline`() throws {
        let first = try self.jwt(subject: "fixture-owner", issued: 1)
        let rotated = try self.jwt(subject: "fixture-owner", issued: 2)
        let other = try self.jwt(subject: "other-owner", issued: 3)
        let web = KimiRegion.china.webBaseURL
        #expect(KimiUsageFetcher.historyOwnerID(endpoint: web, credential: first)
            == KimiUsageFetcher.historyOwnerID(endpoint: web, credential: rotated))
        #expect(KimiUsageFetcher.historyOwnerID(endpoint: web, credential: first)
            != KimiUsageFetcher.historyOwnerID(endpoint: web, credential: other))
        #expect(KimiUsageFetcher.historyOwnerID(
            endpoint: KimiRegion.china.apiBaseURL,
            credential: "fixture-key",
            enrichmentCredential: first)
            == KimiUsageFetcher.historyOwnerID(
                endpoint: KimiRegion.china.apiBaseURL,
                credential: "fixture-key",
                enrichmentCredential: rotated))
    }

    @Test func `verified refresh aliases recover existing Kimi history while unrelated buckets stay isolated`()
        async throws
    {
        let store = self.store()
        let first = try self.snapshot(credential: "fixture-old", at: self.now.addingTimeInterval(-120))
        store.snapshots[.kimi] = first
        await store.recordPlanUtilizationHistorySample(provider: .kimi, snapshot: first)
        let unrelated = try self.snapshot(credential: "fixture-unrelated", at: self.now.addingTimeInterval(-60))
        store.snapshots[.kimi] = unrelated
        await store.recordPlanUtilizationHistorySample(provider: .kimi, snapshot: unrelated)
        let currentOwner = "kimi-credential-v1:" + String(repeating: "a", count: 64)
        let current = try UsageSnapshot(
            primary: first.primary,
            secondary: nil,
            updatedAt: self.now,
            identity: ProviderIdentitySnapshot(
                providerID: .kimi,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: nil,
                accountID: currentOwner,
                historyOwnerAliases: [#require(first.identity?.accountID)]))
        store.snapshots[.kimi] = current
        await store.recordPlanUtilizationHistorySample(provider: .kimi, snapshot: current)
        let row = try #require(store.nativeOrbitAccounts(for: .kimi).first)
        let lane = try #require(row.history.first { $0.name.rawValue == "nativeQuota:primary" })
        #expect(lane.entries.map(\.capturedAt) == [first.updatedAt, self.now])
        let unrelatedKey = try #require(UsageStore.planUtilizationIdentityAccountKey(
            provider: .kimi, snapshot: unrelated))
        #expect(store.planUtilizationHistory[.kimi]?.accounts[unrelatedKey]?.first {
            $0.name.rawValue == "nativeQuota:primary"
        }?.entries.map(\.capturedAt) == [unrelated.updatedAt])
    }

    private func jwt(subject: String, issued: Int) throws -> String {
        let claims = try JSONSerialization.data(withJSONObject: [
            "sub": subject, "iss": "https://auth.kimi.com", "iat": issued,
        ])
        let encoded = claims.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "fixture." + encoded + ".signature"
    }

    private func snapshot(credential: String, at date: Date) throws -> UsageSnapshot {
        let owner = try #require(KimiUsageFetcher.historyOwnerID(
            endpoint: KimiRegion.china.apiBaseURL, credential: credential))
        return UsageSnapshot(
            primary: RateWindow(usedPercent: 25, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: date,
            identity: ProviderIdentitySnapshot(
                providerID: .kimi, accountEmail: nil, accountOrganization: nil, loginMethod: nil, accountID: owner))
    }

    private func store() -> UsageStore {
        let settings = testSettingsStore(
            suiteName: "KimiNativeHistoryOwnership", userDefaults: InMemoryUserDefaults(), nativeDesignEnabled: true)
        enableTestProviders([.kimi], settings: settings)
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        store._cancelPlanUtilizationHistoryLoadForTesting()
        return store
    }
}
