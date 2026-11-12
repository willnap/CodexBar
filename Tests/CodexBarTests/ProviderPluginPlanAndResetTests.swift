import Foundation
import Testing
@testable import CodexBarCore

/// A plugin reports resets and its plan in the same shared form the built-in providers fill.
struct ProviderPluginPlanAndResetTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func map(_ fields: [String: Any]) throws -> UsageSnapshot {
        var usage: [String: Any] = ["primary": ["usedPercent": 10, "windowMinutes": 300]]
        usage.merge(fields) { _, new in new }
        return try ProviderPluginSnapshotMapper.map(JSONProviderPluginValue(usage), provider: .bifrost, now: self.now)
    }

    @Test func `a plugin's plan and price reach the snapshot`() throws {
        let snapshot = try self.map(["plan": [
            "company": "Acme",
            "name": "Acme Pro",
            "formerNames": ["Pro 10x"],
            "price": ["monthlyAmount": 49.5, "currency": "eur", "billedEvery": "year", "includesTax": true],
        ]])
        let plan = try #require(snapshot.providerPlan)
        #expect(plan.company == "Acme")
        #expect(plan.name == "Acme Pro")
        #expect(plan.formerNames == ["Pro 10x"])
        #expect(plan.price?.monthlyAmount == 49.5)
        #expect(plan.price?.currencyCode == "EUR")
        #expect(plan.price?.billedEvery == .year)
        #expect(plan.price?.includesTax == true)
        #expect(plan.price?.source == .reported)
        #expect(snapshot.planDetails(for: .bifrost, planName: nil) == plan)
        // A name alone is a plan too; no plan at all leaves the snapshot without one.
        #expect(try self.map(["plan": ["name": "Free"]]).providerPlan?.price == nil)
        #expect(try self.map([:]).providerPlan == nil)
    }

    @Test func `a malformed plan is refused instead of shown`() {
        for plan: [String: Any] in [
            [:],
            ["price": ["monthlyAmount": 20]],
            ["price": ["monthlyAmount": 20, "currency": "dollars"]],
            ["price": ["monthlyAmount": -1, "currency": "USD"]],
            ["price": ["monthlyAmount": "20", "currency": "USD"]],
            ["price": ["monthlyAmount": 20, "currency": "USD", "billedEvery": "week"]],
            ["name": "Pro", "price": ["monthlyAmount": 20, "currency": "USD", "weekly": true]],
            ["name": "Pro", "formerNames": "Pro 5x"],
            ["name": "Pro", "seats": 3],
        ] {
            #expect(throws: (any Error).self) { try self.map(["plan": plan]) }
        }
    }

    @Test func `a plugin's resets reach the snapshot with what each clears`() throws {
        let snapshot = try self.map(["resets": [
            ["available": true, "expiresAt": "2027-02-01T00:00:00Z"],
            [
                "available": true,
                "clears": ["tertiary"],
                "givesBackWiderUsage": true,
                "label": "Model reset",
                "grantedAt": "2027-01-01T00:00:00Z",
            ],
            ["available": false, "usedAt": "2027-01-10T00:00:00Z"],
        ]])
        let resets = try #require(snapshot.resetInventory(for: .bifrost)?.resets)
        #expect(resets.count == 3)
        #expect(resets[0].scope == .everything)
        #expect(resets[0].expiresAt != nil)
        #expect(resets[1].scope == .windows(["tertiary"]))
        #expect(resets[1].givesBackWiderUsage)
        #expect(resets[1].label == "Model reset")
        #expect(!resets[2].isAvailable)
        #expect(resets[2].usedAt != nil)
        #expect(throws: (any Error).self) { try self.map(["resets": [["expiresAt": "2027-02-01T00:00:00Z"]]]) }
        #expect(throws: (any Error).self) { try self.map(["resets": [["available": true, "clears": "primary"]]]) }
    }
}
