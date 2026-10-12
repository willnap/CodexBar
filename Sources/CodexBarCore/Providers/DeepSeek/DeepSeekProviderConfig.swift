import Foundation

extension ProviderConfig {
    public var deepseekProfileID: String? {
        get { self.extensionValue(forKey: "deepseekProfileID") }
        set { self.setExtensionValue(newValue, forKey: "deepseekProfileID") }
    }

    public var deepseekProfileScope: String? {
        get { self.extensionValue(forKey: "deepseekProfileScope") }
        set { self.setExtensionValue(newValue, forKey: "deepseekProfileScope") }
    }

    public var deepseekProfileBindings: [String: String]? {
        get { self.extensionValue(forKey: "deepseekProfileBindings") }
        set { self.setExtensionValue(newValue, forKey: "deepseekProfileBindings") }
    }

    /// Session fingerprints retain their owner even when another account's profile becomes selected.
    public var deepseekPlatformTokenScopes: [String: String]? {
        get { self.extensionValue(forKey: "deepseekPlatformTokenScopes") }
        set { self.setExtensionValue(newValue, forKey: "deepseekPlatformTokenScopes") }
    }

    public var sanitizedDeepSeekProfileID: String? {
        SettingsValue.cleaned(self.deepseekProfileID).map(DeepSeekSettingsReader.canonicalProfileID)
    }

    public var sanitizedDeepSeekProfileScope: String? {
        SettingsValue.cleaned(self.deepseekProfileScope)
    }

    public var sanitizedDeepSeekProfileBindings: [String: String]? {
        self.deepseekProfileBindings.map { bindings in
            bindings.reduce(into: [:]) { result, binding in
                guard let scope = SettingsValue.cleaned(binding.key),
                      let profile = SettingsValue.cleaned(binding.value) else { return }
                result[scope] = DeepSeekSettingsReader.canonicalProfileID(profile)
            }
        }
    }

    public var sanitizedDeepSeekPlatformTokenScopes: [String: String]? {
        self.deepseekPlatformTokenScopes.map { bindings in
            bindings.reduce(into: [:]) { result, binding in
                guard let fingerprint = SettingsValue.cleaned(binding.key),
                      let scope = SettingsValue.cleaned(binding.value) else { return }
                result[fingerprint] = scope
            }
        }
    }

    public func deepseekProfileID(forScope scope: String) -> String? {
        self.sanitizedDeepSeekProfileBindings?[scope]
            ?? (self.sanitizedDeepSeekProfileScope == scope ? self.sanitizedDeepSeekProfileID : nil)
    }

    public func deepseekPlatformTokenScope(forToken token: String) -> String? {
        if let fingerprint = DeepSeekSettingsReader.profileScope(selectedTokenAccountID: nil, apiKey: token),
           let scope = self.sanitizedDeepSeekPlatformTokenScopes?[fingerprint] { return scope }
        return self.sanitizedDeepSeekProfileScope
    }
}
