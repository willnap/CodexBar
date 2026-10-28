import CodexBarCore
import Foundation

/// claude-swap names its rows' plan nowhere: its reports carry its own source label in the plan's place. It keeps each
/// account's Claude profile (no credentials) beside its backups, as `.claude-config-<n>-<email>.json`, and that
/// profile's rate-limit tier names the plan ("default_claude_max_20x" → "Claude Max 20x"). An unreadable or
/// changed format simply leaves the row without a plan.
@MainActor
enum NativeClaudeSwapProfilePlan {
    private struct Profile: Decodable {
        struct Account: Decodable {
            let emailAddress: String?
            let organizationRateLimitTier: String?
            let userRateLimitTier: String?
            let billingType: String?
            let seatTier: String?
        }

        let oauthAccount: Account?
    }

    private static var cache: [URL: (modified: Date, plan: String?)] = [:]

    static func plan(email: String?, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        guard !SettingsStore.isRunningTests,
              let email = email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !email.isEmpty
        else { return nil }
        let directory = home.appendingPathComponent(".claude-swap-backup/configs", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return nil }
        for name in names where name.hasPrefix(".claude-config-") && name.lowercased().hasSuffix("-\(email).json") {
            let url = directory.appendingPathComponent(name)
            if let plan = self.plan(at: url, email: email) { return plan }
        }
        return nil
    }

    private static func plan(at url: URL, email: String) -> String? {
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate]
            as? Date else { return nil }
        if let cached = self.cache[url], cached.modified == modified { return cached.plan }
        let account = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Profile.self, from: $0) }?
            .oauthAccount
        let plan: String? = if let account,
                               account.emailAddress?.lowercased() == email
        {
            ClaudePlan.webLoginMethod(
                rateLimitTier: account.userRateLimitTier ?? account.organizationRateLimitTier,
                billingType: account.billingType,
                seatTier: account.seatTier)
        } else {
            nil
        }
        self.cache[url] = (modified, plan)
        return plan
    }
}
