import Foundation

public enum ProviderEnvironmentResolver {
    public static func resolve(
        base: [String: String],
        provider: UsageProvider,
        config: ProviderConfig?,
        selectedAccount: ProviderTokenAccount?) -> [String: String]
    {
        var environment = ProviderConfigEnvironment.applyProviderConfigOverrides(
            base: base,
            provider: provider,
            config: config)
        if let selectedAccount {
            TokenAccountSupportCatalog.scrubEnvironmentForSelectedAccount(
                &environment,
                provider: provider,
                token: selectedAccount.token)
            if let override = TokenAccountSupportCatalog.envOverride(
                for: provider,
                token: selectedAccount.token)
            {
                environment.merge(override) { _, selectedAccountValue in selectedAccountValue }
            }
            ProviderDescriptorRegistry.descriptor(for: provider).credentials?.applySelectedAccount(
                environment: &environment,
                account: selectedAccount)
        }
        // Provider-specific by design: DeepSeek browser profiles and manual sessions are bound to API account scopes.
        if provider == .deepseek {
            Self.applyDeepSeekProfile(
                base: base, config: config, selectedAccountID: selectedAccount?.id, environment: &environment)
        }
        return environment
    }

    private static func applyDeepSeekProfile(
        base: [String: String], config: ProviderConfig?, selectedAccountID: UUID?, environment: inout [String: String])
    {
        guard let config, config.deepseekProfileBindings != nil else { return }
        let apiKey = DeepSeekSettingsReader.apiKey(environment: environment)
        guard let scope = DeepSeekSettingsReader.profileScope(
            selectedTokenAccountID: selectedAccountID, apiKey: apiKey) else { return }
        // Resolve the session owner before projecting the selected account's profile scope.
        if let token = DeepSeekSettingsReader.platformToken(environment: environment) {
            let owner = config.sanitizedCookieHeader != nil
                ? config.deepseekPlatformTokenScope(forToken: token)
                : DeepSeekSettingsReader.profileScope(environment: base)
            let standaloneBrowserSession = apiKey == nil && (owner == nil || owner == "unbound")
            if owner != scope, !standaloneBrowserSession {
                for key in DeepSeekSettingsReader.platformTokenEnvironmentKeys {
                    environment[key] = nil
                }
            }
        }
        if let profile = config.deepseekProfileID(forScope: scope) {
            environment[DeepSeekSettingsReader.profileIDEnvironmentKey] = profile
            environment[DeepSeekSettingsReader.profileScopeEnvironmentKey] = scope
        }
    }
}
