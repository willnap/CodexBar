import Foundation
import Testing
@testable import CodexBarCore

struct KimiCodeProfileTests {
    @Test func `a phone login's profile gives its nickname and plan but no email`() throws {
        let profile = try #require(KimiUsageFetcher.parseCodeProfile(Data("""
        {"user_id":"u1","nickname":"Example User","phone":{"country_code":"44","number":"7700900000"},
         "user_level":30,"user_level_name":"Ultra","goods_version":2}
        """.utf8)))
        #expect(profile == .init(email: nil, name: "Example User", plan: "Ultra"))
    }

    @Test func `a profile without a user id or with blank fields is ignored field by field`() {
        #expect(KimiUsageFetcher.parseCodeProfile(Data(#"{"nickname":"x"}"#.utf8)) == nil)
        #expect(KimiUsageFetcher.parseCodeProfile(Data("not json".utf8)) == nil)
        #expect(KimiUsageFetcher.parseCodeProfile(Data(#"{"user_id":"u","email":" ","nickname":""}"#.utf8))
            == .init(email: nil, name: nil, plan: nil))
    }

    @Test func `profile names reach the identity without changing the history owner`() {
        var snapshot = KimiUsageSnapshot(weekly: nil, rateLimit: nil, updatedAt: Date())
        snapshot.historyOwnerID = "kimi-credential-v1:owner"
        snapshot.accountEmail = "user@example.com"
        snapshot.accountName = "Example User"
        let identity = snapshot.toUsageSnapshot().identity(for: .kimi)
        #expect(identity?.accountEmail == "user@example.com")
        #expect(identity?.accountName == "Example User")
        #expect(identity?.accountID == "kimi-credential-v1:owner")
    }
}
