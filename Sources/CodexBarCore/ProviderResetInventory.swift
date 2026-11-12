import Foundation

/// One limit reset an account holds or has used, in terms every provider shares.
///
/// Providers report these in shapes of their own (Codex reset credits, Claude reset grants, Grok remaining resets,
/// a plugin's own list). What the app shows about a reset does not depend on which it was: whether it is still
/// available, when it lapses, when it was used, and above all what it clears. A reset that clears everything the
/// account is limited by and one that clears a single model's allowance are different things to hold.
public struct ProviderReset: Sendable, Equatable, Hashable {
    public enum Scope: Sendable, Equatable, Hashable {
        /// Clears every limit the account has.
        case everything
        /// Clears only these usage windows, named by the snapshot's own window ids: `primary`, `secondary`,
        /// `tertiary`, or an extra window's id.
        case windows([String])
    }

    public let isAvailable: Bool
    /// When it lapses unused, or when the grant a used one came from ends; nil when it has no end.
    public let expiresAt: Date?
    /// When it was used; nil while available, and when the provider counts it used without saying when.
    public let usedAt: Date?
    /// When the account was given it, when the provider says.
    public let grantedAt: Date?
    public let scope: Scope
    /// Whether using it also returns the part of a wider window's usage that its own windows took up.
    public let givesBackWiderUsage: Bool
    /// The provider's own words for it, when it has any.
    public let label: String?

    public init(
        isAvailable: Bool,
        expiresAt: Date?,
        usedAt: Date? = nil,
        grantedAt: Date? = nil,
        scope: Scope = .everything,
        givesBackWiderUsage: Bool = false,
        label: String? = nil)
    {
        self.isAvailable = isAvailable
        self.expiresAt = expiresAt
        self.usedAt = usedAt
        self.grantedAt = grantedAt
        self.scope = scope
        self.givesBackWiderUsage = givesBackWiderUsage
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.label = trimmed?.isEmpty == false ? trimmed : nil
    }
}

/// Every reset a provider reported for an account at one reading.
public struct ProviderResetInventory: Sendable, Equatable {
    /// More than this is a malformed reading, not an inventory.
    public static let maximumResets = 50
    /// How long a reset with a known time of use still counts as used.
    public static let usedInterval: TimeInterval = 86400

    public let resets: [ProviderReset]
    public let updatedAt: Date

    public init(resets: [ProviderReset], updatedAt: Date) {
        self.resets = Array(resets.prefix(Self.maximumResets))
        self.updatedAt = updatedAt
    }

    /// Resets still available at `date`, soonest to lapse first; ones without an end sort last.
    public func available(at date: Date) -> [ProviderReset] {
        self.resets.enumerated()
            .filter { $0.element.isAvailable && ($0.element.expiresAt.map { $0 > date } ?? true) }
            .sorted { lhs, rhs in
                switch (lhs.element.expiresAt, rhs.element.expiresAt) {
                case let (left?, right?) where left != right: left < right
                case (_?, nil): true
                case (nil, _?): false
                default: lhs.offset < rhs.offset
                }
            }
            .map(\.element)
    }

    /// Resets that count as used at `date`: used within the last day when the provider says when, otherwise for
    /// as long as the grant they came from is current.
    public func used(at date: Date) -> [ProviderReset] {
        self.resets.filter { reset in
            guard !reset.isAvailable else { return false }
            if let usedAt = reset.usedAt {
                return usedAt <= date && date.timeIntervalSince(usedAt) < Self.usedInterval
            }
            return reset.expiresAt.map { $0 > date } ?? true
        }
    }
}

extension UsageSnapshot {
    /// The account's resets in the shared form, whichever way `provider` reports them: in that form already (a
    /// plugin's list), or in a payload of its own. A payload belonging to another provider is never read: a
    /// snapshot shows only what its own provider said.
    public func resetInventory(for provider: UsageProvider) -> ProviderResetInventory? {
        if let providerResets { return providerResets }
        // Provider-specific by design: each of these payloads is one provider's own reset format.
        switch provider {
        case .codex:
            return self.codexResetCredits.map(ProviderResetInventory.init)
        case .claude:
            return self.claudeResetCredits.map {
                ProviderResetInventory($0, extraWindowIDs: (self.extraRateWindows ?? []).map(\.id))
            }
        case .grok:
            return self.grokResetCredits.map(ProviderResetInventory.init)
        default:
            return nil
        }
    }
}

extension ProviderResetInventory {
    /// Codex reset credits. Its `reset_type` has not been seen to name anything narrower than the account's
    /// limits, so every credit clears everything; the title is kept as its label.
    public init(_ codex: CodexRateLimitResetCreditsSnapshot) {
        self.init(
            resets: codex.credits.compactMap { credit in
                switch credit.status {
                case .available:
                    ProviderReset(
                        isAvailable: true,
                        expiresAt: credit.expiresAt,
                        grantedAt: credit.grantedAt,
                        label: credit.title)
                case .redeemed:
                    credit.redeemedAt.map {
                        ProviderReset(
                            isAvailable: false,
                            expiresAt: credit.expiresAt,
                            usedAt: $0,
                            grantedAt: credit.grantedAt,
                            label: credit.title)
                    }
                default: nil
                }
            },
            updatedAt: codex.updatedAt)
    }

    public init(_ grok: GrokRateLimitResetCreditsSnapshot) {
        self.init(
            resets: grok.expirations.map { ProviderReset(isAvailable: true, expiresAt: $0) },
            updatedAt: grok.updatedAt)
    }

    /// Claude reset grants. A grant lists the limits it clears by Claude's own keys; `extraWindowIDs` are the
    /// snapshot's extra windows, among which the model-scoped weekly lanes stand for every key that is neither the
    /// session nor the weekly limit.
    public init(_ claude: ClaudeRateLimitResetCreditsSnapshot, extraWindowIDs: [String]) {
        guard !claude.grants.isEmpty else {
            // An inventory read without grant detail: counts and ends only.
            self.init(
                resets: claude.expirations.map { ProviderReset(isAvailable: true, expiresAt: $0) }
                    + claude.usedExpirations.map { ProviderReset(isAvailable: false, expiresAt: $0) },
                updatedAt: claude.updatedAt)
            return
        }
        let scoped = extraWindowIDs.filter { $0.hasPrefix(Self.claudeScopedWindowPrefix) }
        var resets: [ProviderReset] = []
        for grant in claude.grants {
            let scope = Self.claudeScope(grant.clears, scopedWindowIDs: scoped)
            func reset(available: Bool) -> ProviderReset {
                ProviderReset(
                    isAvailable: available,
                    expiresAt: grant.expiresAt,
                    grantedAt: grant.startsAt,
                    scope: scope,
                    givesBackWiderUsage: grant.givesBackWeekly,
                    label: grant.label)
            }
            resets += Array(repeating: reset(available: true), count: grant.left)
            resets += Array(repeating: reset(available: false), count: grant.used)
        }
        self.init(resets: resets, updatedAt: claude.updatedAt)
    }

    static let claudeScopedWindowPrefix = "claude-weekly-scoped-"
    /// The window a model-scoped key stands for when the snapshot shows no such lane.
    static let claudeScopedWindowFallback = "claude-weekly-scoped"

    /// A grant with no list clears everything. Otherwise `five_hour` is the session window, `seven_day` the
    /// weekly one, and any other key a model-scoped weekly lane.
    static func claudeScope(_ clears: [String]?, scopedWindowIDs: [String]) -> ProviderReset.Scope {
        guard let clears, !clears.isEmpty else { return .everything }
        var windows: [String] = []
        for key in clears {
            switch key {
            case "five_hour": windows.append("primary")
            case "seven_day": windows.append("secondary")
            default: windows += scopedWindowIDs.isEmpty ? [Self.claudeScopedWindowFallback] : scopedWindowIDs
            }
        }
        var seen = Set<String>()
        return .windows(windows.filter { seen.insert($0).inserted })
    }
}
