import CodexBarCore
import Foundation

extension SettingsStore {
    func deepseekProfileID(apiKey: String?) -> String {
        _ = self.configRevision
        _ = self.providerDetailSettingsRevision
        guard let config = self.config.providerConfig(for: .deepseek) else { return "" }
        let accountID = self.selectedTokenAccount(for: .deepseek)?.id
        let expectedScope = DeepSeekSettingsReader.profileScope(selectedTokenAccountID: accountID, apiKey: apiKey)
        guard let expectedScope else { return "" }
        return config.deepseekProfileID(forScope: expectedScope) ?? ""
    }

    func setDeepSeekProfileID(_ newValue: String, apiKey: String?) {
        let profileID = self.normalizedConfigValue(newValue)
        let profileScope = DeepSeekSettingsReader.profileScope(
            selectedTokenAccountID: self.selectedTokenAccount(for: .deepseek)?.id,
            apiKey: apiKey)
        guard profileID == nil || profileScope != nil else { return }
        self.updateProviderDetailConfig(provider: .deepseek) { entry in
            var bindings = entry.sanitizedDeepSeekProfileBindings ?? [:]
            if let priorScope = entry.sanitizedDeepSeekProfileScope,
               let priorProfile = entry.sanitizedDeepSeekProfileID,
               bindings[priorScope] == nil
            {
                bindings[priorScope] = priorProfile
            }
            if let token = entry.sanitizedCookieHeader,
               let fingerprint = DeepSeekSettingsReader.profileScope(selectedTokenAccountID: nil, apiKey: token)
            {
                var owners = entry.sanitizedDeepSeekPlatformTokenScopes ?? [:]
                if owners[fingerprint] == nil {
                    owners[fingerprint] = entry.sanitizedDeepSeekProfileScope ?? "unbound"
                }
                entry.deepseekPlatformTokenScopes = owners
            }
            if let profileScope { bindings[profileScope] = profileID }
            entry.deepseekProfileBindings = bindings
            entry.deepseekProfileID = profileID
            entry.deepseekProfileScope = profileID == nil ? nil : profileScope
        }
    }
}
