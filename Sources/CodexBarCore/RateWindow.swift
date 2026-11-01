import Foundation

public struct RateWindow: Codable, Equatable, Sendable {
    /// Provider usage value, intentionally not normalized globally. Pace and provider-specific diagnostics may
    /// preserve raw over-quota values; display-only projections should use `UsagePercent.displayClamped`.
    public let usedPercent: Double
    /// Optional provider-supplied label for generic usage-window presentation.
    public let title: String?
    public let windowMinutes: Int?
    public let resetsAt: Date?
    /// Optional textual reset description (used by Claude CLI UI scrape).
    public let resetDescription: String?
    /// Absolute allowance and its unit, when reported alongside the percentage.
    public let quotaLimit: Double?
    public let quotaUnit: String?
    /// Optional percent restored on the next regeneration tick for providers with rolling recovery.
    public let nextRegenPercent: Double?
    /// Whether this window was synthesized to stand in for a quota lane the provider did not actually
    /// report, rather than being a real zero-usage window.
    ///
    /// Claude web returns a `0%` five-hour window when `five_hour` is `null` (an account with no live
    /// session but a real weekly lane). Lane classifiers — e.g. the combined "Session + Weekly" menu-bar
    /// metric — must treat such a window as "no session lane present" instead of surfacing a phantom
    /// `5h 0%`/`5h 100%` session. A genuine session, even one freshly reset to 0%, is NOT a placeholder.
    /// Missing values decode as `false` for older cached payloads.
    public let isSyntheticPlaceholder: Bool

    public init(
        usedPercent: Double,
        windowMinutes: Int?,
        resetsAt: Date?,
        resetDescription: String?,
        quotaLimit: Double? = nil,
        quotaUnit: String? = nil,
        nextRegenPercent: Double? = nil,
        isSyntheticPlaceholder: Bool = false,
        title: String? = nil)
    {
        self.usedPercent = usedPercent
        self.title = title
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
        self.resetDescription = resetDescription
        self.quotaLimit = quotaLimit
        self.quotaUnit = quotaUnit
        self.nextRegenPercent = nextRegenPercent
        self.isSyntheticPlaceholder = isSyntheticPlaceholder
    }

    private enum CodingKeys: String, CodingKey {
        case usedPercent
        case title
        case windowMinutes
        case resetsAt
        case resetDescription
        case quotaLimit
        case quotaUnit
        case nextRegenPercent
        case isSyntheticPlaceholder
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.usedPercent = try container.decode(Double.self, forKey: .usedPercent)
        self.title = try container.decodeIfPresent(String.self, forKey: .title)
        self.windowMinutes = try container.decodeIfPresent(Int.self, forKey: .windowMinutes)
        self.resetsAt = try container.decodeIfPresent(Date.self, forKey: .resetsAt)
        self.resetDescription = try container.decodeIfPresent(String.self, forKey: .resetDescription)
        self.quotaLimit = try container.decodeIfPresent(Double.self, forKey: .quotaLimit)
        self.quotaUnit = try container.decodeIfPresent(String.self, forKey: .quotaUnit)
        self.nextRegenPercent = try container.decodeIfPresent(Double.self, forKey: .nextRegenPercent)
        self.isSyntheticPlaceholder =
            try container.decodeIfPresent(Bool.self, forKey: .isSyntheticPlaceholder) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.usedPercent, forKey: .usedPercent)
        try container.encodeIfPresent(self.title, forKey: .title)
        try container.encodeIfPresent(self.windowMinutes, forKey: .windowMinutes)
        try container.encodeIfPresent(self.resetsAt, forKey: .resetsAt)
        try container.encodeIfPresent(self.resetDescription, forKey: .resetDescription)
        try container.encodeIfPresent(self.quotaLimit, forKey: .quotaLimit)
        try container.encodeIfPresent(self.quotaUnit, forKey: .quotaUnit)
        try container.encodeIfPresent(self.nextRegenPercent, forKey: .nextRegenPercent)
        // Only persist the flag when set, keeping payloads identical for the common (real-window) case.
        if self.isSyntheticPlaceholder {
            try container.encode(true, forKey: .isSyntheticPlaceholder)
        }
    }

    /// A synthetic placeholder has no measured quota value, even when its stored percent is zero.
    public var measured: Self? {
        self.isSyntheticPlaceholder ? nil : self
    }

    public var remainingPercent: Double {
        max(0, 100 - self.usedPercent)
    }

    public func backfillingResetTime(from cached: RateWindow?, now: Date = .init()) -> RateWindow {
        if self.resetsAt != nil {
            return self
        }
        guard let cachedReset = cached?.resetsAt, cachedReset > now else { return self }
        let windowMinutes = if let windowMinutes = self.windowMinutes, windowMinutes > 0 {
            windowMinutes
        } else {
            cached?.windowMinutes
        }
        return RateWindow(
            usedPercent: self.usedPercent,
            windowMinutes: windowMinutes,
            resetsAt: cachedReset,
            resetDescription: self.resetDescription ?? cached?.resetDescription,
            quotaLimit: self.quotaLimit,
            quotaUnit: self.quotaUnit,
            nextRegenPercent: self.nextRegenPercent,
            // Preserve the placeholder marker: backfilling a stale reset onto Claude web's null-session
            // placeholder must not let it masquerade as a real session lane.
            isSyntheticPlaceholder: self.isSyntheticPlaceholder,
            title: self.title)
    }
}
