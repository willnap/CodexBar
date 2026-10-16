import Foundation

/// Stable identity for one account row surfaced by a multi-account source adapter.
///
/// `source` names the adapter (for example `claude-swap`) and `opaqueID` is the
/// source-issued identifier (for example a numeric slot). Identity never derives
/// from emails or credential material, per
/// `docs/claude-multi-account-and-status-items.md`.
public struct ProviderAccountIdentity: Hashable, Sendable {
    public let source: String
    public let opaqueID: String

    public init(source: String, opaqueID: String) {
        self.source = source
        self.opaqueID = opaqueID
    }
}

/// What a multi-account source reports about one account's login and usage, for warning surfaces.
public enum ProviderAccountCondition: Sendable, Equatable {
    case ok
    /// The saved login is expired, revoked, missing, unreadable or belongs to another account.
    case credentialProblem
    /// The source could not measure usage this time.
    case usageUnavailable
    /// The account has no subscription usage to measure (for example an API-key login).
    case notApplicable
    /// A status this build does not recognize.
    case unrecognized
}

public enum ProviderAccountCredentialIssue: Sendable, Equatable {
    case signIn
    case keychain
    case wrongAccount
}

/// Provider-neutral projection of one account's usage, consumed by menus (and,
/// later, per-account status items) without teaching UI code about any specific
/// credential source.
public struct ProviderAccountUsageSnapshot: Identifiable, Sendable {
    public let id: ProviderAccountIdentity
    public let provider: UsageProvider
    /// Display-only label (may contain personal data such as an email); UI is
    /// responsible for privacy redaction. Never logged or persisted.
    public let displayLabel: String
    /// Display-only source email, kept separate from `displayLabel` so aliases and
    /// `email · org` disambiguation cannot leak into identity.
    public let accountEmail: String?
    /// Display-only organization evidence for detecting a replaced slot. Never a stable identity or persisted.
    public let accountOrganizationName: String?
    /// Source-issued organization UUID used only to match local transcript evidence. Never persisted or logged.
    public let sourceOrganizationID: String?
    public let isActive: Bool
    /// Whether the source can activate this slot or explicitly repair its selected credential state.
    /// Activation remains source-owned; CodexBar never handles credential material.
    public let canActivate: Bool
    /// Explicit source permission for unattended rotation; repairable or disabled slots remain manual-only.
    public let autoSwitchEligible: Bool
    /// Whether `snapshot` is a last-known measurement the source served because
    /// live usage was unavailable, rather than a current one. Such a snapshot is
    /// fine on a card that shows its age, but must not drive age-less surfaces.
    public let usesLastKnownUsage: Bool
    public let snapshot: UsageSnapshot?
    public let error: String?
    public let sourceLabel: String?
    public let condition: ProviderAccountCondition
    public let credentialIssue: ProviderAccountCredentialIssue?

    public init(
        id: ProviderAccountIdentity,
        provider: UsageProvider,
        displayLabel: String,
        accountEmail: String? = nil,
        accountOrganizationName: String? = nil,
        sourceOrganizationID: String? = nil,
        isActive: Bool,
        canActivate: Bool = false,
        autoSwitchEligible: Bool = false,
        usesLastKnownUsage: Bool = false,
        snapshot: UsageSnapshot?,
        error: String?,
        sourceLabel: String?,
        condition: ProviderAccountCondition = .ok,
        credentialIssue: ProviderAccountCredentialIssue? = nil)
    {
        self.id = id
        self.provider = provider
        self.displayLabel = displayLabel
        self.accountEmail = accountEmail
        self.accountOrganizationName = accountOrganizationName
        self.sourceOrganizationID = sourceOrganizationID
        self.isActive = isActive
        self.canActivate = canActivate
        self.autoSwitchEligible = autoSwitchEligible
        self.usesLastKnownUsage = usesLastKnownUsage
        self.snapshot = snapshot
        self.error = error
        self.sourceLabel = sourceLabel
        self.condition = condition
        self.credentialIssue = credentialIssue
    }
}
