import Foundation

/// Every selectable range is ready before a range click; refreshes retain the preceding complete set.
struct NativeCombinedChartPresentation {
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
        self.requested.flatMap { self.prepared[$0.days] } ?? self.latest
    }

    func snapshot(days: Int) -> Snapshot? {
        self.prepared[days] ?? self.visible
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

    @MainActor static func prepare(
        request: Request, model: NativeCombinedAccounts, labels: [String: String]) async -> [Snapshot]?
    {
        var snapshots: [Snapshot] = []
        for days in NativeOrbitRangeControl.ranges {
            let costs = model.summary(days: days, now: request.now).costs
            let currency = costs.count == 1 ? costs.keys.first : nil
            guard let history = await NativeCombinedTokenHistory.prepare(
                model: model, days: days, now: request.now, moneyCurrency: currency) else { return nil }
            snapshots.append(.init(
                request: .init(
                    now: request.now,
                    days: days,
                    moneyCurrency: currency,
                    ids: request.ids,
                    accounts: request.accounts),
                history: history,
                model: model,
                labels: labels))
        }
        return snapshots
    }
}
