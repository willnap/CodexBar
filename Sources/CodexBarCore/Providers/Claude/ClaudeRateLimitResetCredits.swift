import Foundation

/// Claude usage-limit resets ("Reset for free" in Claude Settings > Usage), read from the `cedar_ember`
/// block of the Claude Web or OAuth usage response.
///
/// Display-safe, live-only inventory. Grant identifiers are redemption handles; they are never decoded, so
/// they never enter a UsageSnapshot, its persisted JSON, or CLI output. The usage request skips the URL cache,
/// so the raw response is not kept on disk either.
public struct ClaudeRateLimitResetCreditsSnapshot: Sendable, Equatable {
    static let detailLabel = "Limit Reset Credits"

    /// Expiry of each reset available at `updatedAt`; a grant with `resets_left: 2` contributes two entries.
    /// Nil means the reset has no expiry.
    public let expirations: [Date?]
    /// Provider-confirmed used resets in grants that are still current; no redemption identifiers.
    public let usedExpirations: [Date?]
    /// The current grants themselves, with what each clears; empty when the source gave only the two lists above.
    public let grants: [Grant]
    public let updatedAt: Date

    /// One current grant, without its redemption handle.
    public struct Grant: Sendable, Equatable {
        public let startsAt: Date?
        public let expiresAt: Date?
        public let left: Int
        public let used: Int
        /// Claude's keys for the limits a reset from this grant clears (`seven_day`, `five_hour`, or a
        /// model-scoped key); nil when the grant does not say.
        public let clears: [String]?
        /// Whether a reset from it also returns the weekly usage that went to the model it clears.
        public let givesBackWeekly: Bool
        public let label: String?

        public init(
            startsAt: Date? = nil,
            expiresAt: Date?,
            left: Int,
            used: Int,
            clears: [String]? = nil,
            givesBackWeekly: Bool = false,
            label: String? = nil)
        {
            self.startsAt = startsAt
            self.expiresAt = expiresAt
            self.left = max(0, left)
            self.used = max(0, used)
            self.clears = clears
            self.givesBackWeekly = givesBackWeekly
            self.label = label
        }
    }

    public init(expirations: [Date?], updatedAt: Date, usedExpirations: [Date?] = [], grants: [Grant] = []) {
        self.expirations = expirations
        self.usedExpirations = usedExpirations
        self.grants = grants
        self.updatedAt = updatedAt
    }

    /// Expiry of each reset still available at `date`, soonest first; resets without an expiry sort last.
    public func availableExpirations(at date: Date) -> [Date?] {
        self.expirations
            .filter { expiresAt in expiresAt.map { $0 > date } ?? true }
            .sorted { lhs, rhs in
                switch (lhs, rhs) {
                case let (lhs?, rhs?): lhs < rhs
                case (_?, nil): true
                default: false
                }
            }
    }

    /// CLI text, CLI JSON, and `codexbar serve` read reset inventory from the generic `usage.details`
    /// surface; the app renders the typed snapshot instead.
    func detailSections(now: Date) -> [ProviderDetailSection] {
        let expirations = self.availableExpirations(at: now)
        guard !expirations.isEmpty else { return [] }
        let value = expirations.count == 1 ? "1 available" : "\(expirations.count) available"
        let nextExpiry = expirations.first.flatMap(\.self)
        return [
            .makeSection(rows: [
                .makeRow(
                    label: Self.detailLabel,
                    value: value,
                    secondaryValue: nextExpiry.map {
                        "Expires \(UsageFormatter.resetDescription(from: $0, now: now))"
                    }),
            ]),
        ]
    }
}

/// Raw `cedar_ember` block. Only an eligible account's received grants list is a measured inventory, so an empty
/// list holds zero resets. Ineligible accounts and missing grants stay unknown. A malformed grant is dropped
/// without hiding the rest; an implausibly large inventory yields nothing.
struct ClaudeLimitResetStatusResponse: Decodable {
    /// Observed grants hold one reset each. Each reset renders as its own row, so a larger total is
    /// treated as malformed instead of allocated.
    static let maximumResets = 50
    /// Upper bound on grant records, checked before the block is decoded.
    static let maximumGrantRecords = 200

    let eligible: Bool
    let ineligibleReason: String?
    let grants: [ClaudeLimitResetGrantResponse]
    let grantsReceived: Bool

    private enum CodingKeys: String, CodingKey {
        case eligible
        case ineligibleReason = "ineligible_reason"
        case grants
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.eligible = try container.decode(Bool.self, forKey: .eligible)
        self.ineligibleReason = try container.decodeIfPresent(String.self, forKey: .ineligibleReason)
        var grants: [ClaudeLimitResetGrantResponse] = []
        guard container.contains(.grants), try !container.decodeNil(forKey: .grants) else {
            self.grants = grants
            self.grantsReceived = false
            return
        }
        self.grantsReceived = true
        var records = try container.nestedUnkeyedContainer(forKey: .grants)
        while !records.isAtEnd {
            guard records.currentIndex < Self.maximumGrantRecords else {
                throw DecodingError.dataCorruptedError(
                    forKey: .grants,
                    in: container,
                    debugDescription: "Too many reset grants")
            }
            if let grant = try records.decode(LossyGrant.self).grant {
                grants.append(grant)
            }
        }
        self.grants = grants
    }

    /// `usable_now` is not consulted: a saved reset counts even while Claude gates redemption. A grant that has
    /// not started yet is left out until a refresh after its start.
    func snapshot(updatedAt: Date) -> ClaudeRateLimitResetCreditsSnapshot? {
        guard self.eligible, self.grantsReceived else { return nil }
        var expirations: [Date?] = []
        var used: [Date?] = []
        var current: [ClaudeRateLimitResetCreditsSnapshot.Grant] = []
        for grant in self.grants {
            guard !grant.paused, grant.startsAt.map({ $0 <= updatedAt }) ?? true,
                  grant.endsAt.map({ $0 > updatedAt }) ?? true else { continue }
            let consumed = (grant.resetsTotal ?? grant.resetsLeft) - grant.resetsLeft
            guard grant.resetsLeft <= Self.maximumResets - expirations.count - used.count,
                  consumed <= Self.maximumResets - expirations.count - used.count - grant.resetsLeft
            else { return nil }
            expirations.append(contentsOf: repeatElement(grant.endsAt, count: grant.resetsLeft))
            used.append(contentsOf: repeatElement(grant.endsAt, count: consumed))
            current.append(.init(
                startsAt: grant.startsAt,
                expiresAt: grant.endsAt,
                left: grant.resetsLeft,
                used: consumed,
                clears: grant.clears,
                givesBackWeekly: grant.givesBackWeekly,
                label: grant.label))
        }
        return ClaudeRateLimitResetCreditsSnapshot(
            expirations: expirations, updatedAt: updatedAt, usedExpirations: used, grants: current)
    }

    private struct LossyGrant: Decodable {
        let grant: ClaudeLimitResetGrantResponse?

        init(from decoder: Decoder) throws {
            self.grant = try? ClaudeLimitResetGrantResponse(from: decoder)
        }
    }
}

struct ClaudeLimitResetGrantResponse: Decodable {
    let resetsLeft: Int
    let resetsTotal: Int?
    let startsAt: Date?
    let endsAt: Date?
    /// Required: a grant whose pause state is unknown is dropped rather than counted.
    let paused: Bool
    /// What a reset from this grant clears. All three are additions to the payload: absent or malformed, the
    /// grant still counts, and simply does not say.
    let clears: [String]?
    let givesBackWeekly: Bool
    let label: String?

    private enum CodingKeys: String, CodingKey {
        case resetsLeft = "resets_left"
        case resetsTotal = "resets_total"
        case startsAt = "starts_at"
        case endsAt = "ends_at"
        case paused
        case clears
        case givesBackWeekly = "gives_back_weekly"
        case label
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.resetsLeft = try container.decode(Int.self, forKey: .resetsLeft)
        self.resetsTotal = try container.decodeIfPresent(Int.self, forKey: .resetsTotal)
        self.startsAt = try Self.decodeBound(container, forKey: .startsAt)
        self.endsAt = try Self.decodeBound(container, forKey: .endsAt)
        self.paused = try container.decode(Bool.self, forKey: .paused)
        let clears = try? container.decodeIfPresent([String].self, forKey: .clears)
        self.clears = clears.map { $0.filter { !$0.isEmpty && $0.utf8.count <= 64 } }.flatMap {
            $0.isEmpty || $0.count > 16 ? nil : $0
        }
        self.givesBackWeekly = (try? container.decodeIfPresent(Bool.self, forKey: .givesBackWeekly)) ?? false
        let label = try? container.decodeIfPresent(String.self, forKey: .label)
        self.label = label.flatMap { $0.utf8.count <= 120 ? $0 : nil }
        guard self.resetsLeft >= 0, self.resetsTotal.map({ $0 >= self.resetsLeft }) ?? true else {
            throw DecodingError.dataCorruptedError(
                forKey: .resetsLeft,
                in: container,
                debugDescription: "resets_left must be between 0 and resets_total")
        }
    }

    /// True when the grant offers a reset at `date`: not paused, not used up, started, and not expired.
    func isAvailable(at date: Date) -> Bool {
        guard !self.paused, self.resetsLeft > 0 else { return false }
        if let startsAt = self.startsAt, startsAt > date { return false }
        if let endsAt = self.endsAt, endsAt <= date { return false }
        return true
    }

    /// An absent or null bound is open; a supplied but unreadable bound is malformed, never unbounded.
    private static func decodeBound(
        _ container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys) throws -> Date?
    {
        guard let raw = try container.decodeIfPresent(String.self, forKey: key) else { return nil }
        guard let date = ISO8601DateParser.parse(raw) else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "Unreadable ISO-8601 bound")
        }
        return date
    }
}
