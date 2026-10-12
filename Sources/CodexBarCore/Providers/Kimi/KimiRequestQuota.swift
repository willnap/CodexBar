import Foundation

/// Absolute request counters reported by Kimi; these are quota counters, never token or dollar totals.
public struct KimiRequestQuota: Codable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let used: Int
    public let limit: Int
    public let windowMinutes: Int?
    public let resetsAt: Date?

    public var remaining: Int {
        max(0, self.limit - self.used)
    }

    public init(id: String, title: String, used: Int, limit: Int, windowMinutes: Int?, resetsAt: Date?) {
        self.id = id
        self.title = title
        self.used = used
        self.limit = limit
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
    }
}
