import Foundation

public struct ProviderIdentitySnapshot: Codable, Sendable {
    public let providerID: ProviderInstanceID?
    public let accountEmail: String?
    public let accountOrganization: String?
    public let loginMethod: String?
    public let accountID: String?
    public let historyOwnerAliases: [String]?
    /// The account's own display name where the service reports one but no email (a Kimi phone login's nickname).
    /// Display only; never identity.
    public let accountName: String?
    /// Live-only verified ownership for saved-account widgets; never changes sync or hook identity.
    public private(set) var widgetAccountOwnerID: String?

    private enum CodingKeys: String, CodingKey {
        case providerID, accountEmail, accountOrganization, loginMethod, accountID, historyOwnerAliases, accountName
    }

    public init(
        providerID: ProviderInstanceID?,
        accountEmail: String?,
        accountOrganization: String?,
        loginMethod: String?,
        accountID: String? = nil,
        historyOwnerAliases: [String]? = nil,
        widgetAccountOwnerID: String? = nil,
        accountName: String? = nil)
    {
        self.providerID = providerID
        self.accountEmail = accountEmail
        self.accountOrganization = accountOrganization
        self.loginMethod = loginMethod
        self.accountID = accountID
        self.historyOwnerAliases = historyOwnerAliases
        self.widgetAccountOwnerID = widgetAccountOwnerID
        self.accountName = accountName
    }

    public func scoped(to instanceID: ProviderInstanceID) -> ProviderIdentitySnapshot {
        if self.providerID == instanceID {
            return self
        }
        return ProviderIdentitySnapshot(
            providerID: instanceID,
            accountEmail: self.accountEmail,
            accountOrganization: self.accountOrganization,
            loginMethod: self.loginMethod,
            accountID: self.accountID,
            historyOwnerAliases: self.historyOwnerAliases,
            accountName: self.accountName)
    }

    public func scoped(to provider: UsageProvider) -> ProviderIdentitySnapshot {
        self.scoped(to: provider.instanceID)
    }
}

public enum UsageDataConfidence: String, Codable, Equatable, Sendable {
    case exact
    case estimated
    case percentOnly
    case unknown
}
