import CodexBarCore
import Foundation

/// Lightweight source receipts in the existing verified provider/account history buckets.
/// Retains the measured daily totals without prompts, credentials, paths, or synthetic event times.
struct NativeOrbitUsageObservation: Codable, Hashable, Sendable {
    struct Day: Codable, Hashable, Sendable {
        let date: String
        let tokens: Int?
        let requests: Int?
        let cost: Double?
        let incompleteRequests: Int
        let unpricedRequests: Int?
        let unmeteredRequests: Int?
        let costPartial: Bool?
    }

    let currency: String
    let historyDays: Int
    let coverageEstablished: Bool
    let scanPartial: Bool
    let label: String?
    let bucketTimeZoneIdentifier: String?
    let coverageThrough: Date?
    let provenance: String
    let tokens: Int?
    let requests: Int?
    let cost: Double?
    let daily: [Day]

    init?(_ report: CostUsageTokenSnapshot) {
        guard (1...366).contains(report.historyDays), report.daily.count <= 366,
              report.quotaSlices.isEmpty else { return nil }
        self.currency = report.currencyCode
        self.historyDays = report.historyDays
        self.coverageEstablished = report.historyCoverageIsEstablished
        self.scanPartial = report.historyScanIsPartial
        self.label = report.historyLabel
        self.bucketTimeZoneIdentifier = report.bucketTimeZoneIdentifier
        self.coverageThrough = report.coverageThrough
        self.provenance = report.costProvenance.rawValue
        self.tokens = report.last30DaysTokens
        self.requests = report.last30DaysRequests
        self.cost = report.last30DaysCostUSD
        self.daily = report.daily.map {
            Day(
                date: $0.date,
                tokens: $0.totalTokens,
                requests: $0.requestCount,
                cost: $0.costUSD,
                incompleteRequests: $0.incompleteRequestCount,
                unpricedRequests: $0.unpricedRequestCount,
                unmeteredRequests: $0.unmeteredRequestCount,
                costPartial: $0.costIsPartial == true || $0.incompleteRequestCount > 0
                    || ($0.unpricedRequestCount ?? 0) > 0
                    || ($0.unmeteredRequestCount ?? 0) > 0
                    || ($0.modelBreakdowns ?? []).contains {
                        $0.costUSD.map { !$0.isFinite || $0 < 0 } ?? true
                    })
        }
        guard self.snapshot(at: report.updatedAt) != nil else { return nil }
    }

    func snapshot(at date: Date) -> CostUsageTokenSnapshot? {
        guard date.timeIntervalSince1970.isFinite, (1...366).contains(self.historyDays), self.daily.count <= 366,
              self.currency.utf8.count <= 16, (self.label?.utf8.count ?? 0) <= 512,
              (self.bucketTimeZoneIdentifier?.utf8.count ?? 0) <= 128,
              self.bucketTimeZoneIdentifier.map({ TimeZone(identifier: $0) != nil }) ?? true,
              self.coverageThrough.map(\.timeIntervalSince1970.isFinite) ?? true,
              let provenance = CostProvenance(rawValue: self.provenance),
              Self.validCount(self.tokens), Self.validCount(self.requests), Self.validMoney(self.cost)
        else { return nil }
        var dates: Set<String> = []
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        for day in self.daily {
            guard day.date.utf8.count == 10, let parsed = formatter.date(from: day.date),
                  formatter.string(from: parsed) == day.date,
                  dates.insert(day.date).inserted,
                  Self.validCount(day.tokens), Self.validCount(day.requests), Self.validMoney(day.cost),
                  day.incompleteRequests >= 0, Self.validCount(day.unpricedRequests),
                  Self.validCount(day.unmeteredRequests)
            else { return nil }
        }
        return CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: self.tokens,
            last30DaysCostUSD: self.cost,
            last30DaysRequests: self.requests,
            currencyCode: self.currency,
            historyDays: self.historyDays,
            historyCoverageIsEstablished: self.coverageEstablished,
            historyScanIsPartial: self.scanPartial,
            historyLabel: self.label,
            bucketTimeZoneIdentifier: self.bucketTimeZoneIdentifier,
            coverageThrough: self.coverageThrough,
            costProvenance: provenance,
            daily: self.daily.map {
                .init(
                    date: $0.date,
                    inputTokens: nil,
                    outputTokens: nil,
                    totalTokens: $0.tokens,
                    requestCount: $0.requests,
                    costUSD: $0.cost,
                    modelsUsed: nil,
                    modelBreakdowns: nil,
                    unpricedRequestCount: $0.unpricedRequests,
                    unmeteredRequestCount: $0.unmeteredRequests,
                    costIsPartial: $0.costPartial)
            }, updatedAt: date)
    }

    private static func validCount(_ value: Int?) -> Bool { value.map { $0 >= 0 } ?? true }
    private static func validMoney(_ value: Double?) -> Bool { value.map { $0.isFinite && $0 >= 0 } ?? true }
}
