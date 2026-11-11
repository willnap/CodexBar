import Foundation

/// One request instant of a report: when, and the tokens and cost recorded at it.
public struct CostUsageTimedEntry: Sendable, Equatable {
    public let timestamp: Date
    /// Zero when the entry has no token count or no cost: `flags` says which it has. Two optionals and two
    /// booleans padded an entry to 40 bytes; a report lists one for every request instant, and several lists are
    /// alive at a time.
    private let tokens: Int
    private let cost: Double
    private let flags: UInt8

    private static let hasTokens: UInt8 = 1
    private static let hasCost: UInt8 = 2
    private static let completeTokens: UInt8 = 4
    private static let completeCost: UInt8 = 8

    public var totalTokens: Int? {
        self.flags & Self.hasTokens != 0 ? self.tokens : nil
    }

    public var costUSD: Double? {
        self.flags & Self.hasCost != 0 ? self.cost : nil
    }

    public var tokensAreComplete: Bool {
        self.flags & Self.completeTokens != 0
    }

    public var costIsComplete: Bool {
        self.flags & Self.completeCost != 0
    }

    public init(
        timestamp: Date,
        totalTokens: Int?,
        costUSD: Double?,
        tokensAreComplete: Bool = true,
        costIsComplete: Bool = true)
    {
        self.timestamp = timestamp
        self.tokens = totalTokens ?? 0
        self.cost = costUSD ?? 0
        var flags: UInt8 = 0
        if totalTokens != nil { flags |= Self.hasTokens }
        if costUSD != nil { flags |= Self.hasCost }
        if tokensAreComplete, totalTokens.map({ $0 >= 0 }) == true { flags |= Self.completeTokens }
        if costIsComplete, costUSD.map({ $0.isFinite && $0 >= 0 }) == true { flags |= Self.completeCost }
        self.flags = flags
    }
}
