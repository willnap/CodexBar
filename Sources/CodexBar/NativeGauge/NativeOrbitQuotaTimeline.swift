import CodexBarCore
import Foundation

/// The quota's meaning at its observation, independent of the account's current display configuration.
struct NativeOrbitQuotaDescriptor: Codable, Hashable, Sendable {
    var label: String?
    /// nil is an explicitly unknown cadence; a missing descriptor instead identifies legacy data.
    var windowMinutes: Int?
    var utilizationKnown: Bool?

    var period: TimeInterval? {
        self.windowMinutes.flatMap { $0 > 0 ? Double($0) * 60 : nil }
    }
}

/// Only covered IDs can be declared absent. Adjunct reads cannot remove a base or another adjunct quota.
struct NativeOrbitQuotaSchemaObservation: Codable, Hashable, Sendable {
    let coveredIDs: [String]
    let windows: [String: NativeOrbitQuotaDescriptor]
}

struct NativeOrbitQuotaTimeline {
    enum Membership: Equatable {
        case unknown
        case absent
        case present(NativeOrbitQuotaDescriptor)
    }

    private struct Receipt {
        let date: Date
        let descriptor: NativeOrbitQuotaDescriptor?
    }

    private let receipts: [String: [Receipt]]

    init(history: [PlanUtilizationSeriesHistory]) {
        var receipts: [String: [Receipt]] = [:]
        let entries = history.filter { $0.name.rawValue == "nativeMetric:quotaSchema" }.flatMap(\.entries)
            .sorted(by: PlanUtilizationHistoryEntry.precedes)
        for entry in entries {
            guard let schema = entry.nativeMetrics?.quotaSchema else { continue }
            for id in Set(schema.coveredIDs) {
                receipts[id, default: []].append(.init(date: entry.capturedAt, descriptor: schema.windows[id]))
            }
        }
        self.receipts = receipts
    }

    static func quotaID(_ history: PlanUtilizationSeriesHistory, provider: UsageProvider?) -> String? {
        if history.name.isNativeQuotaObservation { return history.name.rawValue }
        // Provider-specific by design: Kimi's legacy session/weekly transport slots are reversed.
        switch history.name {
        case .session where history.windowMinutes == 300:
            return provider == .kimi ? "nativeQuota:secondary" : "nativeQuota:primary"
        case .weekly where history.windowMinutes == 10080:
            return provider == .kimi ? "nativeQuota:primary" : "nativeQuota:secondary"
        case .monthly where provider == .kimi: return "nativeQuota:kimi-monthly"
        default: return nil
        }
    }

    func membership(_ id: String, at date: Date) -> Membership {
        guard let entries = self.receipts[id] else { return .unknown }
        let end = Self.firstAfter(date, in: entries)
        guard end > 0 else { return .unknown }
        return entries[end - 1].descriptor.map(Membership.present) ?? .absent
    }

    func isAbsent(_ id: String, at date: Date) -> Bool {
        self.membership(id, at: date) == .absent
    }

    func isUnmeasured(_ id: String, at date: Date) -> Bool {
        if case let .present(descriptor) = self.membership(id, at: date) {
            return descriptor.utilizationKnown == false
        }
        return false
    }

    private static func firstAfter(_ date: Date, in entries: [Receipt]) -> Int {
        var lower = 0
        var upper = entries.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if entries[middle].date <= date { lower = middle + 1 } else { upper = middle }
        }
        return lower
    }

    func declaredWindows(at date: Date) -> [String: NativeOrbitQuotaDescriptor] {
        self.receipts.keys.reduce(into: [:]) { result, id in
            if case let .present(descriptor) = self.membership(id, at: date) { result[id] = descriptor }
        }
    }

    /// A removal and return inside an otherwise normal polling gap is still a lifecycle break.
    func canJoin(_ id: String, from start: Date, to end: Date) -> Bool {
        guard !self.isAbsent(id, at: start), !self.isAbsent(id, at: end),
              !self.isUnmeasured(id, at: start), !self.isUnmeasured(id, at: end) else { return false }
        guard let entries = self.receipts[id] else { return true }
        let lower = Self.firstAfter(start, in: entries)
        let upper = Self.firstAfter(end, in: entries)
        var previous = lower > 0 ? entries[lower - 1].descriptor : nil
        for receipt in entries[lower..<upper] {
            guard let descriptor = receipt.descriptor, descriptor.utilizationKnown != false else { return false }
            if let previous, previous.windowMinutes != descriptor.windowMinutes { return false }
            previous = descriptor
        }
        return true
    }
}

extension PlanUtilizationHistoryEntry {
    func withQuotaDescriptor(_ descriptor: NativeOrbitQuotaDescriptor) -> Self {
        guard self.quotaDescriptor == nil else { return self }
        return Self(
            capturedAt: self.capturedAt,
            usedPercent: self.usedPercent,
            resetsAt: self.resetsAt,
            historicalPeriod: self.historicalPeriod,
            nativeMetrics: self.nativeMetrics,
            quotaDescriptor: descriptor)
    }
}

extension UsageStore {
    nonisolated static func nativeOrbitQuotaSchema(
        provider: UsageProvider, snapshot: UsageSnapshot) -> NativeOrbitQuotaSchemaObservation?
    {
        guard let presence = snapshot.quotaWindowPresence, !presence.isEmpty else { return nil }
        let labels = self.nativeOrbitQuotaLabels(provider: provider, snapshot: snapshot)
        let measured = self.nativeOrbitQuotaWindowMap(provider: provider, snapshot: snapshot)
        var windows: [String: NativeOrbitQuotaDescriptor] = [:]
        for (id, present) in presence where present {
            let key = "nativeQuota:" + id
            // Provider-specific by design: these source slots are explicitly five_hour and seven_day,
            // even when the response omits utilization and no RateWindow can be constructed.
            let minutes = measured[key]?.windowMinutes ?? (provider == .claude
                ? (id == "primary" ? 300 : id == "secondary" ? 10080 : nil) : nil)
            windows[key] = .init(label: labels[key], windowMinutes: minutes, utilizationKnown: measured[key] != nil)
        }
        return .init(coveredIDs: presence.keys.map { "nativeQuota:" + $0 }.sorted(), windows: windows)
    }
}
