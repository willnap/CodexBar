import CodexBarCore
import Foundation

struct PlanUtilizationSeriesName: RawRepresentable, Hashable, Codable, ExpressibleByStringLiteral, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(stringLiteral value: StringLiteralType) {
        self.rawValue = value
    }

    static let session: Self = "session"
    static let weekly: Self = "weekly"
    static let monthly: Self = "monthly"
    static let opus: Self = "opus"
    static let antigravityGemini: Self = "antigravityGemini"
    static let antigravityClaudeGPT: Self = "antigravityClaudeGPT"

    var isNativeQuotaObservation: Bool {
        self.rawValue.hasPrefix("nativeQuota:")
    }

    var isNativeMetricObservation: Bool {
        self.rawValue.hasPrefix("nativeMetric:")
    }

    var isQuotaObservation: Bool {
        self == .antigravityGemini || self == .antigravityClaudeGPT
    }

    func canonicalWindowMinutes(_ windowMinutes: Int) -> Int {
        switch self {
        case .session where (295...305).contains(windowMinutes):
            300
        case .weekly where (10070...10090).contains(windowMinutes):
            10080
        default:
            windowMinutes
        }
    }
}

struct PlanUtilizationHistoricalPeriod: Codable, Equatable, Hashable, Sendable {
    let startsAt: Date
    let approximate: Bool
    let accountingComplete: Bool
    let boundaryToleranceSeconds: Double?
    let coverageComplete: Bool?
    let coverageStart: Date?
    let dataAsOf: Date?
    let sourcePeriodID: String?

    private enum CodingKeys: String, CodingKey {
        case startsAt, startsAtReferenceTime, approximate, accountingComplete
        case boundaryToleranceSeconds, coverageComplete, coverageStartReferenceTime, dataAsOfReferenceTime,
             sourcePeriodID
    }

    init(
        startsAt: Date,
        approximate: Bool,
        accountingComplete: Bool,
        boundaryToleranceSeconds: Double? = nil,
        coverageComplete: Bool? = nil,
        coverageStart: Date? = nil,
        dataAsOf: Date? = nil,
        sourcePeriodID: String? = nil)
    {
        self.startsAt = startsAt
        self.approximate = approximate
        self.accountingComplete = accountingComplete
        self.boundaryToleranceSeconds = boundaryToleranceSeconds
        self.coverageComplete = coverageComplete
        self.coverageStart = coverageStart
        self.dataAsOf = dataAsOf
        self.sourcePeriodID = sourcePeriodID
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let exact = try values.decodeIfPresent(Double.self, forKey: .startsAtReferenceTime), exact.isFinite {
            self.startsAt = Date(timeIntervalSinceReferenceDate: exact)
        } else {
            self.startsAt = try values.decode(Date.self, forKey: .startsAt)
        }
        self.approximate = try values.decode(Bool.self, forKey: .approximate)
        self.accountingComplete = try values.decode(Bool.self, forKey: .accountingComplete)
        self.boundaryToleranceSeconds = try values.decodeIfPresent(Double.self, forKey: .boundaryToleranceSeconds)
        self.coverageComplete = try values.decodeIfPresent(Bool.self, forKey: .coverageComplete)
        self.coverageStart = try values.decodeIfPresent(Double.self, forKey: .coverageStartReferenceTime)
            .flatMap { $0.isFinite ? Date(timeIntervalSinceReferenceDate: $0) : nil }
        self.dataAsOf = try values.decodeIfPresent(Double.self, forKey: .dataAsOfReferenceTime)
            .flatMap { $0.isFinite ? Date(timeIntervalSinceReferenceDate: $0) : nil }
        self.sourcePeriodID = try values.decodeIfPresent(String.self, forKey: .sourcePeriodID)
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.startsAt, forKey: .startsAt)
        try values.encode(self.startsAt.timeIntervalSinceReferenceDate, forKey: .startsAtReferenceTime)
        try values.encode(self.approximate, forKey: .approximate)
        try values.encode(self.accountingComplete, forKey: .accountingComplete)
        try values.encodeIfPresent(self.boundaryToleranceSeconds, forKey: .boundaryToleranceSeconds)
        try values.encodeIfPresent(self.coverageComplete, forKey: .coverageComplete)
        try values.encodeIfPresent(
            self.coverageStart?.timeIntervalSinceReferenceDate,
            forKey: .coverageStartReferenceTime)
        try values.encodeIfPresent(self.dataAsOf?.timeIntervalSinceReferenceDate, forKey: .dataAsOfReferenceTime)
        try values.encodeIfPresent(self.sourcePeriodID, forKey: .sourcePeriodID)
    }
}

struct PlanUtilizationHistoryEntry: Codable, Equatable, Hashable, Sendable {
    let capturedAt: Date
    let usedPercent: Double
    let resetsAt: Date?
    let historicalPeriod: PlanUtilizationHistoricalPeriod?
    let nativeMetrics: NativeOrbitMetricObservation?
    let quotaDescriptor: NativeOrbitQuotaDescriptor?

    private enum CodingKeys: String, CodingKey {
        case capturedAt, usedPercent, resetsAt
        case capturedAtReferenceTime, resetsAtReferenceTime
        case historicalPeriod, nativeMetrics, quotaDescriptor
    }

    init(
        capturedAt: Date,
        usedPercent: Double,
        resetsAt: Date?,
        historicalPeriod: PlanUtilizationHistoricalPeriod? = nil,
        nativeMetrics: NativeOrbitMetricObservation? = nil,
        quotaDescriptor: NativeOrbitQuotaDescriptor? = nil)
    {
        self.capturedAt = capturedAt
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.historicalPeriod = historicalPeriod
        self.nativeMetrics = nativeMetrics
        self.quotaDescriptor = quotaDescriptor
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let exactCapture = try values.decodeIfPresent(Double.self, forKey: .capturedAtReferenceTime)
        let exactReset = try values.decodeIfPresent(Double.self, forKey: .resetsAtReferenceTime)
        self.capturedAt = if let exactCapture, exactCapture.isFinite {
            Date(timeIntervalSinceReferenceDate: exactCapture)
        } else {
            try values.decode(Date.self, forKey: .capturedAt)
        }
        self.nativeMetrics = try values.decodeIfPresent(NativeOrbitMetricObservation.self, forKey: .nativeMetrics)
        self.quotaDescriptor = try values.decodeIfPresent(NativeOrbitQuotaDescriptor.self, forKey: .quotaDescriptor)
        self.usedPercent = try values.decode(Double.self, forKey: .usedPercent)
        self.historicalPeriod = try values.decodeIfPresent(
            PlanUtilizationHistoricalPeriod.self,
            forKey: .historicalPeriod)
        self.resetsAt = if let exactReset, exactReset.isFinite {
            Date(timeIntervalSinceReferenceDate: exactReset)
        } else {
            try values.decodeIfPresent(Date.self, forKey: .resetsAt)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        // Keep the existing ISO dates for older clients, plus exact reference times so a restart cannot
        // round distinct source observations into the same second and replace one with another.
        try values.encode(self.capturedAt, forKey: .capturedAt)
        try values.encode(self.usedPercent, forKey: .usedPercent)
        try values.encodeIfPresent(self.resetsAt, forKey: .resetsAt)
        try values.encode(self.capturedAt.timeIntervalSinceReferenceDate, forKey: .capturedAtReferenceTime)
        try values.encodeIfPresent(self.resetsAt?.timeIntervalSinceReferenceDate, forKey: .resetsAtReferenceTime)
        try values.encodeIfPresent(self.historicalPeriod, forKey: .historicalPeriod)
        try values.encodeIfPresent(self.nativeMetrics, forKey: .nativeMetrics)
        try values.encodeIfPresent(self.quotaDescriptor, forKey: .quotaDescriptor)
    }

    static func precedes(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.capturedAt != rhs.capturedAt {
            return lhs.capturedAt < rhs.capturedAt
        }
        if lhs.usedPercent != rhs.usedPercent {
            return lhs.usedPercent < rhs.usedPercent
        }
        let lhsReset = lhs.resetsAt?.timeIntervalSince1970 ?? Date.distantPast.timeIntervalSince1970
        let rhsReset = rhs.resetsAt?.timeIntervalSince1970 ?? Date.distantPast.timeIntervalSince1970
        return lhsReset < rhsReset
    }
}

struct PlanUtilizationSeriesHistory: Codable, Equatable, Sendable {
    let name: PlanUtilizationSeriesName
    let windowMinutes: Int
    let entries: [PlanUtilizationHistoryEntry]

    /// Zero is reserved for observed quota samples with no advertised reset cadence.
    var hasSupportedCadence: Bool {
        self
            .windowMinutes > 0 ||
            (self.windowMinutes == 0 && (self.name.isQuotaObservation || self.name.isNativeQuotaObservation
                    || self.name.isNativeMetricObservation))
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case windowMinutes
        case entries
    }

    init(name: PlanUtilizationSeriesName, windowMinutes: Int, entries: [PlanUtilizationHistoryEntry]) {
        self.name = name
        self.windowMinutes = windowMinutes
        self.entries = entries.sorted(by: PlanUtilizationHistoryEntry.precedes)
    }

    /// A prefix of this already ordered history keeps its exact source ordering without sorting it again.
    func prefix(through date: Date) -> Self {
        var lower = 0
        var upper = self.entries.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if self.entries[middle].capturedAt <= date { lower = middle + 1 } else { upper = middle }
        }
        if lower == self.entries.count { return self }
        return Self(name: self.name, windowMinutes: self.windowMinutes, orderedEntries: Array(self.entries[..<lower]))
    }

    /// The same ordered entries under another name, sharing their storage instead of sorting them again.
    func renamed(_ name: PlanUtilizationSeriesName) -> Self {
        Self(name: name, windowMinutes: self.windowMinutes, orderedEntries: self.entries)
    }

    private init(
        name: PlanUtilizationSeriesName, windowMinutes: Int, orderedEntries: [PlanUtilizationHistoryEntry])
    {
        self.name = name
        self.windowMinutes = windowMinutes
        self.entries = orderedEntries
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(PlanUtilizationSeriesName.self, forKey: .name)
        let windowMinutes = try container.decode(Int.self, forKey: .windowMinutes)
        let entries = try container.decode([PlanUtilizationHistoryEntry].self, forKey: .entries)
        self.init(name: name, windowMinutes: windowMinutes, entries: entries)
    }

    var latestCapturedAt: Date? {
        self.entries.last?.capturedAt
    }

    static func precedes(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.windowMinutes != rhs.windowMinutes {
            return lhs.windowMinutes < rhs.windowMinutes
        }
        return lhs.name.rawValue < rhs.name.rawValue
    }
}

struct PlanUtilizationHistorySelection {
    let accountKey: String?
    let histories: [PlanUtilizationSeriesHistory]
    let cacheIdentity: String

    init(accountKey: String?, histories: [PlanUtilizationSeriesHistory]) {
        self.accountKey = accountKey
        self.histories = histories
        self.cacheIdentity = "account:\(accountKey ?? UsageStore.planUtilizationUnscopedPreferredKey)"
    }

    private init(accountKey: String?, histories: [PlanUtilizationSeriesHistory], cacheIdentity: String) {
        self.accountKey = accountKey
        self.histories = histories
        self.cacheIdentity = cacheIdentity
    }

    static let unavailable = Self(accountKey: nil, histories: [], cacheIdentity: "unavailable")
}

struct PlanUtilizationHistoryBuckets: Equatable, Sendable {
    var preferredAccountKey: String?
    var unscoped: [PlanUtilizationSeriesHistory] = []
    var accounts: [String: [PlanUtilizationSeriesHistory]] = [:]
    var sessionEquivalentWindowPairIdentities: [String: String] = [:]

    private static let unscopedIdentityKey = "__codexbar_unscoped__"
    private static let invalidatedIdentity = "__codexbar_invalidated__"

    func histories(for accountKey: String?) -> [PlanUtilizationSeriesHistory] {
        guard let accountKey, !accountKey.isEmpty else { return self.unscoped }
        return self.accounts[accountKey] ?? []
    }

    func selection(for accountKey: String?) -> PlanUtilizationHistorySelection {
        PlanUtilizationHistorySelection(accountKey: accountKey, histories: self.histories(for: accountKey))
    }

    mutating func setHistories(_ histories: [PlanUtilizationSeriesHistory], for accountKey: String?) {
        let sorted = histories.sorted(by: PlanUtilizationSeriesHistory.precedes)
        guard let accountKey, !accountKey.isEmpty else {
            self.unscoped = sorted
            return
        }
        if sorted.isEmpty {
            self.accounts.removeValue(forKey: accountKey)
        } else {
            self.accounts[accountKey] = sorted
        }
    }

    func sessionEquivalentWindowPairIdentity(for accountKey: String?) -> String? {
        self.sessionEquivalentWindowPairIdentities[Self.identityKey(for: accountKey)]
    }

    mutating func setSessionEquivalentWindowPairIdentity(_ identity: String?, for accountKey: String?) {
        let key = Self.identityKey(for: accountKey)
        if let identity {
            self.sessionEquivalentWindowPairIdentities[key] = identity
        } else {
            self.sessionEquivalentWindowPairIdentities.removeValue(forKey: key)
        }
    }

    mutating func invalidateSessionEquivalentWindowPairIdentity(for accountKey: String?) {
        self.sessionEquivalentWindowPairIdentities[Self.identityKey(for: accountKey)] = Self.invalidatedIdentity
    }

    mutating func moveSessionEquivalentWindowPairIdentity(
        from sourceAccountKey: String?,
        to targetAccountKey: String?)
    {
        let sourceKey = Self.identityKey(for: sourceAccountKey)
        let targetKey = Self.identityKey(for: targetAccountKey)
        guard sourceKey != targetKey,
              let sourceIdentity = self.sessionEquivalentWindowPairIdentities[sourceKey]
        else {
            return
        }

        if let targetIdentity = self.sessionEquivalentWindowPairIdentities[targetKey],
           targetIdentity != sourceIdentity
        {
            self.sessionEquivalentWindowPairIdentities[targetKey] = Self.invalidatedIdentity
        } else {
            self.sessionEquivalentWindowPairIdentities[targetKey] = sourceIdentity
        }
        self.sessionEquivalentWindowPairIdentities.removeValue(forKey: sourceKey)
    }

    var isEmpty: Bool {
        self.unscoped.isEmpty && self.accounts.values.allSatisfy(\.isEmpty)
    }

    private static func identityKey(for accountKey: String?) -> String {
        guard let accountKey, !accountKey.isEmpty else { return self.unscopedIdentityKey }
        return accountKey
    }
}

private struct ProviderHistoryDocument: Codable, Sendable {
    let version: Int
    let preferredAccountKey: String?
    let unscoped: [PlanUtilizationSeriesHistory]
    let accounts: [String: [PlanUtilizationSeriesHistory]]
    let sessionEquivalentWindowPairIdentities: [String: String]
}

struct PlanUtilizationHistoryStore: Sendable {
    fileprivate static let providerSchemaVersion = 1
    private static let log = CodexBarLog.logger("plan-history")

    let directoryURL: URL?

    init(directoryURL: URL? = Self.defaultDirectoryURL()) {
        self.directoryURL = directoryURL
    }

    static func defaultAppSupport() -> Self {
        Self()
    }

    /// Loads the persisted histories on a utility-priority detached task.
    ///
    /// The on-disk decode is synchronous I/O + JSON parsing that can take
    /// ~150 ms for mature two-year histories and must not run on the app
    /// startup main thread. The returned dictionary is safe to apply on the
    /// main actor once decoding completes.
    func loadAsync() async -> [ProviderInstanceID: PlanUtilizationHistoryBuckets] {
        await Task.detached(priority: .utility) { self.load() }.value
    }

    /// Decodes every provider's file concurrently and reports each one as it lands, so a small file never waits
    /// behind a large one; returns them all once every file is read.
    func loadAsync(
        reporting report: @escaping @Sendable (ProviderInstanceID, PlanUtilizationHistoryBuckets) async -> Void) async
        -> [ProviderInstanceID: PlanUtilizationHistoryBuckets]
    {
        guard let directoryURL = self.directoryURL,
              let fileURLs = try? FileManager.default.contentsOfDirectory(
                  at: directoryURL,
                  includingPropertiesForKeys: nil)
        else { return [:] }
        return await withTaskGroup(of: (ProviderInstanceID, PlanUtilizationHistoryBuckets)?.self) { group in
            for fileURL in fileURLs where fileURL.pathExtension == "json" {
                guard let instanceID = ProviderInstanceID(rawValue: fileURL.deletingPathExtension().lastPathComponent)
                else { continue }
                group.addTask(priority: .userInitiated) {
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    guard let data = try? Data(contentsOf: fileURL),
                          let decoded = try? decoder.decode(ProviderHistoryDocument.self, from: data)
                    else { return nil }
                    return (instanceID, Self.decodeProvider(decoded))
                }
            }
            var output: [ProviderInstanceID: PlanUtilizationHistoryBuckets] = [:]
            for await result in group {
                guard let (instanceID, buckets) = result else { continue }
                output[instanceID] = buckets
                await report(instanceID, buckets)
            }
            return output
        }
    }

    /// Writes each provider's document; `onlyInstanceIDs` limits the pass to those providers and leaves the
    /// other files as they are.
    @discardableResult
    func save(
        _ providers: [ProviderInstanceID: PlanUtilizationHistoryBuckets],
        onlyInstanceIDs: Set<ProviderInstanceID>? = nil) -> Set<ProviderInstanceID>
    {
        guard let directoryURL = self.directoryURL else { return [] }
        let knownInstanceIDs = Set(UsageProvider.allCases.map(\.instanceID)).union(providers.keys)
            .filter { onlyInstanceIDs?.contains($0) ?? true }
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true)
        } catch {
            Self.log.error("Failed to create quota history directory: \(error.localizedDescription)")
            return knownInstanceIDs
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        var failures: Set<ProviderInstanceID> = []

        for instanceID in knownInstanceIDs.sorted(by: { $0.rawValue < $1.rawValue }) {
            do {
                let fileURL = self.providerFileURL(for: instanceID)
                let buckets = providers[instanceID] ?? PlanUtilizationHistoryBuckets()
                let unscoped = Self.sortedHistories(buckets.unscoped)
                let accounts = Self.sortedAccounts(buckets.accounts)
                guard !unscoped.isEmpty || !accounts.isEmpty || !buckets.sessionEquivalentWindowPairIdentities.isEmpty
                else {
                    if FileManager.default.fileExists(atPath: fileURL.path) {
                        try FileManager.default.removeItem(at: fileURL)
                    }
                    continue
                }

                let payload = ProviderHistoryDocument(
                    version: Self.providerSchemaVersion,
                    preferredAccountKey: buckets.preferredAccountKey,
                    unscoped: unscoped,
                    accounts: accounts,
                    sessionEquivalentWindowPairIdentities: buckets.sessionEquivalentWindowPairIdentities)
                let data = try encoder.encode(payload)
                if let existingData = try? Data(contentsOf: fileURL),
                   existingData == data
                {
                    continue
                }
                try data.write(to: fileURL, options: Data.WritingOptions.atomic)
            } catch {
                failures.insert(instanceID)
                Self.log.error("Failed to save \(instanceID.rawValue) quota history: \(error.localizedDescription)")
            }
        }
        return failures
    }

    func load() -> [ProviderInstanceID: PlanUtilizationHistoryBuckets] {
        guard let directoryURL = self.directoryURL,
              let fileURLs = try? FileManager.default.contentsOfDirectory(
                  at: directoryURL,
                  includingPropertiesForKeys: nil)
        else { return [:] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var output: [ProviderInstanceID: PlanUtilizationHistoryBuckets] = [:]

        for fileURL in fileURLs where fileURL.pathExtension == "json" {
            guard let instanceID = ProviderInstanceID(rawValue: fileURL.deletingPathExtension().lastPathComponent)
            else { continue }
            guard let data = try? Data(contentsOf: fileURL),
                  let decoded = try? decoder.decode(ProviderHistoryDocument.self, from: data)
            else {
                continue
            }

            output[instanceID] = Self.decodeProvider(decoded)
        }

        return output
    }

    private static func decodeProvider(_ providerHistory: ProviderHistoryDocument) -> PlanUtilizationHistoryBuckets {
        PlanUtilizationHistoryBuckets(
            preferredAccountKey: providerHistory.preferredAccountKey,
            unscoped: self.sortedHistories(providerHistory.unscoped),
            accounts: self.sortedAccounts(providerHistory.accounts),
            sessionEquivalentWindowPairIdentities: providerHistory.sessionEquivalentWindowPairIdentities)
    }

    private static func sortedAccounts(
        _ accounts: [String: [PlanUtilizationSeriesHistory]]) -> [String: [PlanUtilizationSeriesHistory]]
    {
        Dictionary(
            uniqueKeysWithValues: accounts.compactMap { accountKey, histories in
                let sorted = Self.sortedHistories(histories)
                guard !sorted.isEmpty else { return nil }
                return (accountKey, sorted)
            })
    }

    private static func sortedHistories(_ histories: [PlanUtilizationSeriesHistory]) -> [PlanUtilizationSeriesHistory] {
        histories.filter { $0.hasSupportedCadence && !$0.entries.isEmpty }
            .sorted(by: PlanUtilizationSeriesHistory.precedes)
    }

    private static func defaultDirectoryURL() -> URL? {
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = root.appendingPathComponent("com.steipete.codexbar", isDirectory: true)
        return dir.appendingPathComponent("history", isDirectory: true)
    }

    private func providerFileURL(for instanceID: ProviderInstanceID) -> URL {
        let directoryURL = self.directoryURL ?? URL(fileURLWithPath: "/dev/null", isDirectory: true)
        return directoryURL.appendingPathComponent("\(instanceID.rawValue).json", isDirectory: false)
    }
}

extension ProviderHistoryDocument {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == PlanUtilizationHistoryStore.providerSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .version,
                in: container,
                debugDescription: "Unsupported provider history schema version \(version)")
        }
        self.version = version
        self.preferredAccountKey = try container.decodeIfPresent(String.self, forKey: .preferredAccountKey)
        self.unscoped = try container.decode([PlanUtilizationSeriesHistory].self, forKey: .unscoped)
        self.accounts = try container.decode([String: [PlanUtilizationSeriesHistory]].self, forKey: .accounts)
        self.sessionEquivalentWindowPairIdentities = try container.decodeIfPresent(
            [String: String].self,
            forKey: .sessionEquivalentWindowPairIdentities) ?? [:]
    }
}

/// One-shot synchronization primitive used by `UsageStore.init` to defer the
/// utility-priority plan-utilization history load until a test chooses to
/// release it. The default `nil` gate is open and the load proceeds immediately.
///
/// Used to verify that `UsageStore.init` returns before disk I/O completes and
/// that the history is applied exactly once after the gate opens.
final class PlanUtilizationHistoryLoadGate: @unchecked Sendable {
    private enum State {
        case closed
        case open
        case cancelled
    }

    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Bool, Never>] = []
    private var state: State = .closed

    init() {}

    var isOpen: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.state == .open
    }

    var isCancelled: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.state == .cancelled
    }

    func wait() async -> Bool {
        await withCheckedContinuation { continuation in
            self.lock.lock()
            switch self.state {
            case .open:
                self.lock.unlock()
                continuation.resume(returning: true)
            case .cancelled:
                self.lock.unlock()
                continuation.resume(returning: false)
            case .closed:
                self.continuations.append(continuation)
                self.lock.unlock()
            }
        }
    }

    func open() {
        self.lock.lock()
        guard self.state == .closed else {
            self.lock.unlock()
            return
        }
        self.state = .open
        let pending = self.continuations
        self.continuations.removeAll()
        self.lock.unlock()
        for continuation in pending {
            continuation.resume(returning: true)
        }
    }

    /// Cancels this one-shot gate and resumes pending or future waiters with
    /// `false`. Cancellation is sticky so it cannot race ahead of `wait()` and
    /// lose the wakeup that drains the load task.
    func cancel() {
        self.lock.lock()
        guard self.state == .closed else {
            self.lock.unlock()
            return
        }
        self.state = .cancelled
        let pending = self.continuations
        self.continuations.removeAll()
        self.lock.unlock()
        for continuation in pending {
            continuation.resume(returning: false)
        }
    }
}
