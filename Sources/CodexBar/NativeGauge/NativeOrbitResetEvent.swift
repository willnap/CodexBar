import CodexBarCore
import Foundation

/// A quota window that started over, typed by what reset it.
///
/// Derived only from recorded history, so past resets appear as soon as their inputs exist: quota lanes (`usedPercent`
/// and `resetsAt` per observation), the account's reset inventory (`nativeMetric:resets`: available and used resets,
/// Codex `redeemedAt`), and, for an early reset nobody redeemed, the same provider's other accounts.
struct NativeOrbitResetEvent: Hashable, Sendable, Identifiable {
    enum Kind: String, Hashable, Sendable, CaseIterable {
        /// The window's countdown reached its scheduled `resetsAt`.
        case natural
        /// The user redeemed a banked reset; the reset inventory recorded the redemption.
        case manual
        /// The window started over before its schedule and no banked reset was redeemed.
        case provider
        /// The window started over before its schedule while no reset inventory was recorded around it, so the
        /// cause is unknown. Never guessed as either of the other early kinds.
        case early

        /// Only a redeemed banked reset changes the banked inventory.
        var isBankable: Bool {
            self == .manual
        }
    }

    let kind: Kind
    /// The scheduled reset, an exact redemption time, or the first observation that shows the reset.
    let date: Date
    /// The last observation before the reset when it is only bracketed by observations; nil when `date` is exact.
    let earliest: Date?
    /// Quota lanes that started over at this instant; empty for a redemption without a recorded quota drop.
    let laneIDs: [String]
    /// Banked resets redeemed at this instant.
    var quantity = 1

    var id: String {
        "\(self.kind.rawValue)|\(self.date.timeIntervalSinceReferenceDate)|\(self.laneIDs.joined(separator: ","))"
    }
}

// MARK: - Classification

extension NativeOrbitResetEvent {
    /// Observations of one refresh, and the reset times one window reports, differ by up to a poll's latency.
    static let sameInstant: TimeInterval = 120
    /// Usage falls only when a window starts over. A reset leaves at most half of the previous usage and at least
    /// five points less, so rounding and rolling windows are never mistaken for resets.
    static let minimumDrop = 5.0
    /// Two accounts dropping inside brackets this narrow, with nothing redeemed, were reset by their provider.
    static let providerWideBracket: TimeInterval = 3 * 3600

    static func isResetDrop(from before: Double, to after: Double) -> Bool {
        before - after >= self.minimumDrop && after <= before / 2
    }

    /// Providers whose accounts can bank resets. Accounts of other providers cannot redeem one, so their early
    /// resets are the provider's.
    static func providerBanksResets(_ provider: UsageProvider?) -> Bool {
        guard let provider else { return true }
        // Provider-specific by design: only these payloads report redeemable reset inventories.
        return [UsageProvider.codex, .claude, .grok].contains(provider)
    }

    /// A banked reset whose redemption the inventory recorded: exact (Codex `redeemedAt`), or between two inventory
    /// observations whose used resets rose (Claude) or whose available resets fell for another reason than expiry.
    struct Redemption: Hashable, Sendable {
        let date: Date
        let earliest: Date?
        var quantity: Int
    }

    private struct Drop {
        var laneIDs: [String]
        var lower: Date
        var upper: Date
        /// When the new window started, if its schedule places that inside the bracket (`resetsAt` minus the window
        /// length); else the reading that showed the reset.
        var start: Date
    }

    private struct LaneScan {
        var natural: [NativeOrbitResetEvent] = []
        var drops: [Drop] = []
    }

    /// Every reset recorded in `quotaHistories`, typed with the account's inventory (`metricHistories`) and the
    /// quota histories of the provider's other accounts. Natural resets need prior usage to restore; an early drop
    /// needs a known schedule to be early against.
    static func events(
        quotaHistories: [PlanUtilizationSeriesHistory],
        metricHistories: [PlanUtilizationSeriesHistory],
        provider: UsageProvider?,
        peerHistories: [[PlanUtilizationSeriesHistory]] = [],
        now: Date) -> [Self]
    {
        let scan = self.scan(quotaHistories, now: now)
        var events = self.merged(scan.natural)
        var pool = self.redemptions(in: metricHistories)
        let inventory = self.inventoryDates(metricHistories)
        let peerDrops = peerHistories.flatMap { self.scan($0, now: now).drops }
            .filter { $0.upper.timeIntervalSince($0.lower) <= self.providerWideBracket }
        let skew = NativeOrbitAccountMetrics.sameRefreshSkew
        for drop in self.grouped(scan.drops) {
            if let index = self.redemptionIndex(for: drop, in: pool) {
                let redemption = pool[index]
                pool[index].quantity -= 1
                let earliest = redemption.earliest.map { max($0, drop.lower) }
                events.append(Self(
                    kind: .manual,
                    date: earliest.map { max($0, min(redemption.date, drop.start)) } ?? redemption.date,
                    earliest: earliest,
                    laneIDs: drop.laneIDs))
                continue
            }
            // No redemption: the provider reset it only when an inventory reading on each side proves nothing was
            // redeemed, the provider has no banked resets, or another account started over in the same bracket.
            let covered = !self.providerBanksResets(provider)
                || (inventory.contains { $0 <= drop.lower.addingTimeInterval(skew) }
                    && inventory.contains { $0 >= drop.upper.addingTimeInterval(-skew) })
            let providerWide = drop.upper.timeIntervalSince(drop.lower) <= self.providerWideBracket
                && peerDrops.contains {
                    $0.lower < drop.upper.addingTimeInterval(self.sameInstant)
                        && $0.upper > drop.lower.addingTimeInterval(-self.sameInstant)
                }
            events.append(Self(
                kind: covered || providerWide ? .provider : .early,
                date: drop.start,
                earliest: drop.lower,
                laneIDs: drop.laneIDs))
        }
        // A redemption is a reset even when no quota observation brackets it.
        for redemption in pool where redemption.quantity > 0 && redemption.date <= now {
            events.append(Self(
                kind: .manual,
                date: redemption.date,
                earliest: redemption.earliest,
                laneIDs: [],
                quantity: redemption.quantity))
        }
        return events.sorted {
            $0.date != $1.date ? $0.date < $1.date : $0.kind.rawValue < $1.kind.rawValue
        }
    }

    static func redemptions(in metricHistories: [PlanUtilizationSeriesHistory]) -> [Redemption] {
        let observations = metricHistories.filter { $0.name.rawValue == "nativeMetric:resets" }
            .flatMap(\.entries)
            .compactMap { entry in entry.nativeMetrics?.resets.map { (date: entry.capturedAt, inventory: $0) } }
            .sorted { $0.date < $1.date }
        var exact: [Date] = []
        for observation in observations {
            for date in observation.inventory.redeemedDates ?? []
                where !exact.contains(where: { abs($0.timeIntervalSince(date)) < 1 })
            {
                exact.append(date)
            }
        }
        exact.sort()
        var result = exact.map { Redemption(date: $0, earliest: nil, quantity: 1) }
        for (before, after) in zip(observations, observations.dropFirst()) where after.date > before.date {
            // Count both readings at the later instant, so grants that expired in between are not redemptions.
            let consumed = if let previous = before.inventory.usedCount(at: after.date),
                              let current = after.inventory.usedCount(at: after.date)
            {
                current - previous
            } else {
                before.inventory.available(at: after.date).count - after.inventory.available(at: after.date).count
            }
            let reported = exact.count { $0 > before.date && $0 <= after.date }
            if consumed - reported > 0 {
                result.append(Redemption(date: after.date, earliest: before.date, quantity: consumed - reported))
            }
        }
        return result
    }

    /// Redemptions in the rolling Day / 7D / 30D period that ends at `now`.
    static func redemptions(
        in metricHistories: [PlanUtilizationSeriesHistory],
        days: Int,
        now: Date,
        calendar: Calendar = .current,
        prepared: NativeOrbitPreparedMetricHistory? = nil) -> [Redemption]
    {
        let start = NativeOrbitChartAxis.start(now: now, days: days, calendar: calendar)
        let all = prepared.flatMap { $0.matches(metricHistories) ? $0.resetRedemptions : nil }
            ?? self.redemptions(in: metricHistories)
        return all.filter { $0.date >= start && $0.date <= now }
    }

    private static func redemptionIndex(for drop: Drop, in pool: [Redemption]) -> Int? {
        pool.firstIndex {
            $0.earliest == nil && $0.quantity > 0
                && $0.date > drop.lower.addingTimeInterval(-self.sameInstant)
                && $0.date <= drop.upper.addingTimeInterval(self.sameInstant)
        } ?? pool.firstIndex { redemption in
            guard let earliest = redemption.earliest, redemption.quantity > 0 else { return false }
            return earliest < drop.upper && redemption.date > drop.lower
        }
    }

    private static func inventoryDates(_ metricHistories: [PlanUtilizationSeriesHistory]) -> [Date] {
        metricHistories.filter { $0.name.rawValue == "nativeMetric:resets" }.flatMap(\.entries)
            .filter { $0.nativeMetrics?.resets != nil }.map(\.capturedAt)
    }

    private static func scan(_ histories: [PlanUtilizationSeriesHistory], now: Date) -> LaneScan {
        var result = LaneScan()
        for history in histories where !history.name.isNativeMetricObservation {
            let laneID = history.name.rawValue
            // Server period totals are aggregates, not instants; entries are already in capture order.
            let entries = history.entries.filter {
                $0.historicalPeriod == nil && $0.usedPercent.isFinite && $0.usedPercent >= 0 && $0.capturedAt <= now
            }
            for (before, after) in zip(entries, entries.dropFirst()) where after.capturedAt > before.capturedAt {
                guard let schedule = before.resetsAt, schedule > before.capturedAt else { continue }
                let dropped = self.isResetDrop(from: before.usedPercent, to: after.usedPercent)
                if schedule <= after.capturedAt
                    || (dropped && schedule.timeIntervalSince(after.capturedAt) <= self.sameInstant)
                {
                    if before.usedPercent > 0 {
                        result.natural.append(Self(kind: .natural, date: schedule, earliest: nil, laneIDs: [laneID]))
                    }
                } else if dropped {
                    let started = after.resetsAt.map { $0.addingTimeInterval(-Double(history.windowMinutes) * 60) }
                    let start = started.flatMap { history.windowMinutes > 0
                        && $0 >= before.capturedAt && $0 <= after.capturedAt ? $0 : nil
                    } ?? after.capturedAt
                    result.drops.append(Drop(
                        laneIDs: [laneID], lower: before.capturedAt, upper: after.capturedAt, start: start))
                }
            }
            // A countdown that has run out is a reset even before the next observation arrives.
            if let last = entries.last, let schedule = last.resetsAt, schedule > last.capturedAt, schedule <= now,
               last.usedPercent > 0
            {
                result.natural.append(Self(kind: .natural, date: schedule, earliest: nil, laneIDs: [laneID]))
            }
        }
        return result
    }

    /// Windows that reset together (one refresh, one redemption) become one event.
    private static func merged(_ events: [Self]) -> [Self] {
        var result: [Self] = []
        for event in events.sorted(by: { $0.date < $1.date }) {
            if let last = result.last, last.kind == event.kind,
               event.date.timeIntervalSince(last.date) <= self.sameInstant
            {
                result[result.count - 1] = Self(
                    kind: last.kind,
                    date: last.date,
                    earliest: last.earliest,
                    laneIDs: Array(Set(last.laneIDs + event.laneIDs)).sorted(),
                    quantity: last.quantity)
            } else {
                result.append(event)
            }
        }
        return result
    }

    private static func grouped(_ drops: [Drop]) -> [Drop] {
        var result: [Drop] = []
        for drop in drops.sorted(by: { $0.upper < $1.upper }) {
            if var last = result.last, drop.upper.timeIntervalSince(last.upper) <= self.sameInstant,
               drop.lower < last.upper, last.lower < drop.upper
            {
                // Each lane saw the reset after its own last reading, so the shared bracket is the narrowest, and
                // the reset came no later than the first window that started again.
                last.laneIDs = Array(Set(last.laneIDs + drop.laneIDs)).sorted()
                last.lower = max(last.lower, drop.lower)
                last.upper = min(last.upper, drop.upper)
                last.start = min(last.upper, max(last.lower, min(last.start, drop.start)))
                result[result.count - 1] = last
            } else {
                result.append(drop)
            }
        }
        return result
    }
}

// MARK: - Presentation

extension NativeOrbitResetEvent {
    /// The company that resets a provider's windows early.
    static func resetterName(_ provider: UsageProvider?) -> String {
        guard let provider else { return "the provider" }
        // Provider-specific by design: Codex and Claude Code windows are reset by their parent companies.
        switch provider {
        case .codex: return "OpenAI"
        case .claude: return "Anthropic"
        default: return ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName
        }
    }

    func title(provider: UsageProvider?) -> String {
        switch self.kind {
        case .natural: "Window reset"
        case .manual: self.quantity > 1 ? "You used \(self.quantity) banked resets" : "You used a banked reset"
        case .provider: "Reset early by \(Self.resetterName(provider))"
        case .early: "Reset early, cause unknown"
        }
    }

    /// The chart's hover line has room for a few words only.
    func shortTitle(provider: UsageProvider?) -> String {
        switch self.kind {
        case .natural: "Window reset"
        case .manual: "Reset by you"
        case .provider: "Reset by \(Self.resetterName(provider))"
        case .early: "Early reset"
        }
    }

    /// What the reset's rule says to VoiceOver: "You used a banked reset: Session, Weekly, Oct 13, 3:42 PM".
    func help(provider: UsageProvider?, laneLabels: [String]) -> String {
        self.title(provider: provider) + (laneLabels.isEmpty ? "" : ": " + laneLabels.joined(separator: ", "))
            + ", " + self.date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }
}
