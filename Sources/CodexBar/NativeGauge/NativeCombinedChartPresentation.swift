import Foundation

/// Every selectable range is ready before a range click; refreshes retain the preceding complete set.
struct NativeCombinedChartPresentation {
    /// How long the accounts must stay unchanged before a drawn chart is prepared again. Zero under test.
    @MainActor static var settleDelay: Duration = SettingsStore.isRunningTests ? .zero : .seconds(2)

    struct Source: Equatable {
        let now: Date
        let ids: [String]
        let accounts: [NativeOrbitAccountPresentation]
    }

    struct Request: Equatable {
        let now: Date
        let days: Int
        let moneyCurrency: String?
        let ids: [String]
        let accounts: [NativeOrbitAccountPresentation]

        /// Selecting a different range or metric consumes prepared data instead of restarting its task.
        var source: Source {
            Source(now: self.now, ids: self.ids, accounts: self.accounts)
        }
    }

    struct Snapshot {
        let request: Request
        let history: NativeCombinedTokenHistory.Prepared
        let model: NativeCombinedAccounts
        let labels: [String: String]
    }

    private(set) var requested: Request?
    private var prepared: [Int: Snapshot] = [:]
    private var latest: Snapshot?

    var visible: Snapshot? {
        self.requested.flatMap { self.snapshot(prepared: $0.days) } ?? self.latest
    }

    /// The prepared range that covers `days`: the narrowest of day, week and month that does.
    func snapshot(days: Int) -> Snapshot? {
        let range = NativeOrbitRange.standard.first { $0 >= days } ?? NativeOrbitRange.standard.last ?? days
        return self.prepared[range] ?? self.visible
    }

    private func snapshot(prepared days: Int) -> Snapshot? {
        self.prepared[NativeOrbitRange.standard.first { $0 >= days } ?? days]
    }

    mutating func begin(_ request: Request) {
        self.requested = request
    }

    /// Publish the new ranges together, so a refresh never leaves only the selected range ready.
    @discardableResult
    mutating func publish(_ snapshots: [Snapshot]) -> Bool {
        guard let source = self.requested?.source, !snapshots.isEmpty,
              snapshots.allSatisfy({ $0.request.source == source }) else { return false }
        var next = self.latest?.request.source == source ? self.prepared : [:]
        for snapshot in snapshots {
            next[snapshot.request.days] = snapshot
        }
        self.prepared = next
        self.latest = snapshots.last
        return true
    }

    /// All ranges in one pass away from the main actor; see `NativeCombinedTokenHistory.prepare`.
    @MainActor static func prepare(
        request: Request, model: NativeCombinedAccounts, labels: [String: String]) async -> [Snapshot]?
    {
        struct Range: Sendable {
            let days: Int
            let currency: String?
            let history: NativeCombinedTokenHistory.Prepared
        }
        let detached = model.detached()
        let now = request.now
        let ranges: [Range]? = await NativeCombinedTokenHistory.away {
            let model = detached.model()
            var ranges: [Range] = []
            for days in NativeOrbitRangeControl.ranges {
                let costs = model.summary(days: days, now: now).costs
                let currency = costs.count == 1 ? costs.keys.first : nil
                guard let history = NativeCombinedTokenHistory.plot(
                    model: model, days: days, now: now, moneyCurrency: currency) else { return nil }
                ranges.append(Range(days: days, currency: currency, history: history))
            }
            return ranges
        }
        return ranges?.map { range in
            Snapshot(
                request: .init(
                    now: request.now,
                    days: range.days,
                    moneyCurrency: range.currency,
                    ids: request.ids,
                    accounts: request.accounts),
                history: range.history,
                model: model,
                labels: labels)
        }
    }
}
