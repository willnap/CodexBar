import AppKit
import CodexBarCore
import CryptoKit
import Foundation
import Observation

/// A dial's local usage, and when a remembered reading stands in for a live one that is not published yet.
struct NativeOrbitResolvedLocalUsage {
    let usage: NativeOrbitLocalUsage
    /// The measurement time of the last-known reading shown in place of a live publication; nil for live data.
    var lastKnownAt: Date?
}

/// Codable mirror of every `CostUsageTokenSnapshot` field the dials read (period summaries, historical inspection,
/// zero-versus-unknown coverage and provenance). Projects, sessions and hourly buckets are not dial inputs.
struct NativeOrbitPersistedUsageReport: Codable, Equatable, Sendable {
    static let maximumSlices = 250_000
    static let maximumDays = 800

    let currency: String
    let historyDays: Int
    let coverageEstablished: Bool
    let scanPartial: Bool
    let label: String?
    let bucketTimeZoneIdentifier: String?
    let coverageThrough: Date?
    let provenance: String
    let tokens: Int?
    let cost: Double?
    let requests: Int?
    let daily: [CostUsageDailyReport.Entry]
    /// Exact event slices as parallel columns: seconds since 1970, tokens, cost and completeness bits
    /// (1 = tokens complete, 2 = cost complete). Columns keep tens of thousands of requests compact.
    let sliceTimes: [Double]
    let sliceTokens: [Int?]
    let sliceCosts: [Double?]
    let sliceFlags: [UInt8]
    let updatedAt: Date

    init?(_ report: CostUsageTokenSnapshot) {
        guard report.daily.count <= Self.maximumDays, report.quotaSlices.count <= Self.maximumSlices else {
            return nil
        }
        self.currency = report.currencyCode
        self.historyDays = report.historyDays
        self.coverageEstablished = report.historyCoverageIsEstablished
        self.scanPartial = report.historyScanIsPartial
        self.label = report.historyLabel
        self.bucketTimeZoneIdentifier = report.bucketTimeZoneIdentifier
        self.coverageThrough = report.coverageThrough
        self.provenance = report.costProvenance.rawValue
        self.tokens = report.last30DaysTokens
        self.cost = report.last30DaysCostUSD
        self.requests = report.last30DaysRequests
        self.daily = report.daily
        self.sliceTimes = report.quotaSlices.map(\.timestamp.timeIntervalSince1970)
        self.sliceTokens = report.quotaSlices.map(\.totalTokens)
        self.sliceCosts = report.quotaSlices.map(\.costUSD)
        self.sliceFlags = report.quotaSlices.map { ($0.tokensAreComplete ? 1 : 0) | ($0.costIsComplete ? 2 : 0) }
        self.updatedAt = report.updatedAt
    }

    /// The report as published, or nil when the stored document is malformed.
    func snapshot() -> CostUsageTokenSnapshot? {
        let count = self.sliceTimes.count
        guard self.updatedAt.timeIntervalSince1970.isFinite, self.historyDays > 0,
              self.daily.count <= Self.maximumDays, count <= Self.maximumSlices,
              self.sliceTokens.count == count, self.sliceCosts.count == count, self.sliceFlags.count == count,
              self.sliceTimes.allSatisfy(\.isFinite),
              self.bucketTimeZoneIdentifier.map({ TimeZone(identifier: $0) != nil }) ?? true,
              self.coverageThrough.map(\.timeIntervalSince1970.isFinite) ?? true,
              let provenance = CostProvenance(rawValue: self.provenance)
        else { return nil }
        let slices = (0..<count).map { index in
            CostUsageTimedEntry(
                timestamp: Date(timeIntervalSince1970: self.sliceTimes[index]),
                totalTokens: self.sliceTokens[index],
                costUSD: self.sliceCosts[index],
                tokensAreComplete: self.sliceFlags[index] & 1 != 0,
                costIsComplete: self.sliceFlags[index] & 2 != 0)
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
            daily: self.daily,
            quotaSlices: slices,
            updatedAt: self.updatedAt)
    }
}

/// One provider's remembered dial inputs, keyed by an opaque owner digest (never an email, path or account ID).
struct NativeOrbitLastKnownUsageDocument: Codable, Sendable {
    static let currentVersion = 1

    struct Entry: Codable, Sendable {
        let report: NativeOrbitPersistedUsageReport
        let scope: String
        let bucketTimeZoneIdentifier: String?
        let isAccountAttributed: Bool
        let isStale: Bool
        let unattributedDays: [String]

        init?(_ usage: NativeOrbitLocalUsage) {
            guard let report = NativeOrbitPersistedUsageReport(usage.snapshot) else { return nil }
            self.report = report
            self.scope = usage.scope.rawValue
            self.bucketTimeZoneIdentifier = usage.bucketTimeZoneIdentifier
            self.isAccountAttributed = usage.isAccountAttributed
            self.isStale = usage.isStale
            self.unattributedDays = usage.unattributedDays.sorted()
        }

        var usage: NativeOrbitLocalUsage? {
            guard let snapshot = self.report.snapshot(),
                  let scope = NativeOrbitUsageScope(rawValue: self.scope),
                  self.bucketTimeZoneIdentifier.map({ TimeZone(identifier: $0) != nil }) ?? true,
                  self.unattributedDays.count <= NativeOrbitPersistedUsageReport.maximumDays
            else { return nil }
            return NativeOrbitLocalUsage(
                snapshot: snapshot,
                scope: scope,
                bucketTimeZoneIdentifier: self.bucketTimeZoneIdentifier,
                isAccountAttributed: self.isAccountAttributed,
                isStale: self.isStale,
                unattributedDays: Set(self.unattributedDays))
        }
    }

    let version: Int
    let provider: String
    let savedAt: Date
    let entries: [String: Entry]
}

/// Atomic, bounded, owner-only files under Application Support; unreadable or foreign documents are ignored.
enum NativeOrbitLastKnownUsageFile {
    static let maximumBytes = 32 * 1024 * 1024
    /// Provider-specific by design: only these providers' local-usage resolvers record last-known dial inputs, so
    /// launch reads just their files instead of probing one per provider.
    static let providers: [UsageProvider] = [.claude, .codex, .kimi]

    static func defaultDirectory() -> URL? {
        if TestProcessSafety.isRunning { return nil }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return base?
            .appendingPathComponent("CodexBar", isDirectory: true)
            .appendingPathComponent("native-last-known-usage", isDirectory: true)
    }

    static func url(for provider: UsageProvider, in directory: URL) -> URL {
        directory.appendingPathComponent("\(provider.rawValue).json", isDirectory: false)
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "+inf", negativeInfinity: "-inf", nan: "nan")
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "+inf", negativeInfinity: "-inf", nan: "nan")
        return decoder
    }

    /// Entries of a current-version document for `provider` measured within `maximumAge` of `now`.
    static func load(
        _ provider: UsageProvider,
        directory: URL,
        now: Date,
        maximumAge: TimeInterval) -> [String: NativeOrbitLocalUsage]
    {
        let url = self.url(for: provider, in: directory)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= self.maximumBytes,
              let data = try? Data(contentsOf: url),
              let document = try? self.decoder().decode(NativeOrbitLastKnownUsageDocument.self, from: data),
              document.version == NativeOrbitLastKnownUsageDocument.currentVersion,
              document.provider == provider.rawValue
        else { return [:] }
        return document.entries.compactMapValues { entry in
            guard let usage = entry.usage,
                  abs(now.timeIntervalSince(usage.snapshot.updatedAt)) <= maximumAge else { return nil }
            return usage
        }
    }

    @discardableResult
    static func save(
        _ entries: [String: NativeOrbitLocalUsage],
        provider: UsageProvider,
        directory: URL,
        savedAt: Date) -> Bool
    {
        let document = NativeOrbitLastKnownUsageDocument(
            version: NativeOrbitLastKnownUsageDocument.currentVersion,
            provider: provider.rawValue,
            savedAt: savedAt,
            entries: entries.compactMapValues(NativeOrbitLastKnownUsageDocument.Entry.init))
        let url = self.url(for: provider, in: directory)
        do {
            let data = try self.encoder().encode(document)
            guard data.count <= self.maximumBytes else { return false }
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            return false
        }
    }
}

/// Remembers every account's latest published dial inputs and restores them at launch, so a dial shows its last
/// known values at once and updates in place when the live publication lands.
///
/// Readers ask by owner digest, built from the same evidence the live ownership checks use (account, organization,
/// session home, credentials, bucket time zone), so a remembered reading never reaches another account.
@MainActor
@Observable
final class NativeOrbitLastKnownUsageStore {
    /// Entries older than this are not restored; they cannot describe any selectable dial period.
    static let maximumAge: TimeInterval = 32 * 86400
    static let maximumEntriesPerProvider = 16
    /// The first change is written soon after it is published; later ones at most this often.
    static let saveInterval: TimeInterval = 5 * 60
    static let firstSaveDelay: TimeInterval = 5

    private struct Signature: Equatable {
        let updatedAt: Date
        let coverageThrough: Date?
        let days: Int
        let slices: Int
        let lastDay: String?
        let lastDayTokens: Int?
        let lastDayCost: Double?
        let scope: String
        let flags: [Bool]
        let unattributedDays: Int

        init(_ usage: NativeOrbitLocalUsage) {
            let report = usage.snapshot
            self.updatedAt = report.updatedAt
            self.coverageThrough = report.coverageThrough
            self.days = report.daily.count
            self.slices = report.quotaSlices.count
            self.lastDay = report.daily.last?.date
            self.lastDayTokens = report.daily.last?.totalTokens
            self.lastDayCost = report.daily.last?.costUSD
            self.scope = usage.scope.rawValue + (usage.bucketTimeZoneIdentifier ?? "")
            self.flags = [
                usage.isAccountAttributed, usage.isStale, report.historyCoverageIsEstablished,
                report.historyScanIsPartial,
            ]
            self.unattributedDays = usage.unattributedDays.count
        }
    }

    private struct Entry {
        let usage: NativeOrbitLocalUsage
        let signature: Signature
    }

    /// Bumped only when restored entries land, so a presentation built before the disk read refreshes once.
    private(set) var revision: UInt64 = 0
    @ObservationIgnored private var entries: [UsageProvider: [String: Entry]] = [:]
    @ObservationIgnored private let directory: URL?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var saveTasks: [UsageProvider: Task<Void, Never>] = [:]
    @ObservationIgnored private var lastSaveAt: [UsageProvider: Date] = [:]
    @ObservationIgnored private var dirty: Set<UsageProvider> = []
    @ObservationIgnored private var terminationObserver: NSObjectProtocol?
    /// Launch evidence for the opt-in inspection dump: when the restored entries landed and how many.
    @ObservationIgnored private(set) var restoredAt: Date?
    @ObservationIgnored private(set) var restoredCounts: [UsageProvider: Int] = [:]

    init(directory: URL?) {
        self.directory = directory
    }

    /// The app's store: starts reading the remembered entries at once. Test processes never touch the user's files.
    static func launching() -> NativeOrbitLastKnownUsageStore {
        let store = NativeOrbitLastKnownUsageStore(directory: NativeOrbitLastKnownUsageFile.defaultDirectory())
        store.loadPersisted()
        return store
    }

    /// Reads the remembered entries off the main actor; live entries recorded meanwhile take precedence.
    func loadPersisted(now: Date = Date()) {
        guard let directory = self.directory, self.loadTask == nil else { return }
        self.observeTermination()
        let maximumAge = Self.maximumAge
        // Start reading at once; the app is still launching on the main actor.
        let read = Task.detached(priority: .userInitiated) {
            var restored: [UsageProvider: [String: NativeOrbitLocalUsage]] = [:]
            for provider in NativeOrbitLastKnownUsageFile.providers {
                restored[provider] = NativeOrbitLastKnownUsageFile.load(
                    provider, directory: directory, now: now, maximumAge: maximumAge)
            }
            return restored
        }
        self.loadTask = Task(priority: .userInitiated) { @MainActor [weak self] in
            let restored = await read.value
            guard let self else { return }
            self.adopt(restored)
        }
    }

    func waitForLoad() async {
        await self.loadTask?.value
    }

    /// Restored entries never replace a live reading recorded while the disk read ran.
    func adopt(_ restored: [UsageProvider: [String: NativeOrbitLocalUsage]]) {
        var adopted = 0
        for (provider, usages) in restored {
            for (owner, usage) in usages where self.entries[provider]?[owner] == nil {
                self.entries[provider, default: [:]][owner] = Entry(usage: usage, signature: Signature(usage))
                adopted += 1
            }
            self.restoredCounts[provider] = usages.count
        }
        self.restoredAt = Date()
        if adopted > 0 { self.revision &+= 1 }
    }

    /// The remembered reading for `owner`, marked as a retained lower bound and stamped with its measurement time.
    func usage(_ provider: UsageProvider, owner: String?) -> NativeOrbitResolvedLocalUsage? {
        _ = self.revision
        guard let owner, let entry = self.entries[provider]?[owner] else { return nil }
        var usage = entry.usage
        usage.isStale = true
        return NativeOrbitResolvedLocalUsage(usage: usage, lastKnownAt: entry.usage.snapshot.updatedAt)
    }

    /// Every remembered reading for `provider`, as it would be written to disk.
    func rememberedUsages(_ provider: UsageProvider) -> [String: NativeOrbitLocalUsage] {
        (self.entries[provider] ?? [:]).mapValues(\.usage)
    }

    /// Remembers a live reading. Called while rendering, so it never touches observed state; unchanged readings
    /// cost one signature comparison.
    func record(_ provider: UsageProvider, owner: String?, usage: NativeOrbitLocalUsage) {
        guard let owner else { return }
        let signature = Signature(usage)
        guard self.entries[provider]?[owner]?.signature != signature else { return }
        var providerEntries = self.entries[provider] ?? [:]
        providerEntries[owner] = Entry(usage: usage, signature: signature)
        if providerEntries.count > Self.maximumEntriesPerProvider {
            let keep = providerEntries.sorted { $0.value.usage.snapshot.updatedAt > $1.value.usage.snapshot.updatedAt }
                .prefix(Self.maximumEntriesPerProvider).map(\.key)
            providerEntries = providerEntries.filter { keep.contains($0.key) }
        }
        self.entries[provider] = providerEntries
        self.scheduleSave(provider)
    }

    private func scheduleSave(_ provider: UsageProvider) {
        guard self.directory != nil else { return }
        self.dirty.insert(provider)
        guard self.saveTasks[provider] == nil else { return }
        let elapsed = self.lastSaveAt[provider].map { Date().timeIntervalSince($0) } ?? .infinity
        let delay = max(Self.firstSaveDelay, Self.saveInterval - elapsed)
        self.saveTasks[provider] = Task(priority: .utility) { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.saveTasks[provider] = nil
            await self.save(provider)
        }
    }

    private func save(_ provider: UsageProvider) async {
        guard let directory = self.directory, self.dirty.remove(provider) != nil else { return }
        let usages = (self.entries[provider] ?? [:]).mapValues(\.usage)
        let now = Date()
        self.lastSaveAt[provider] = now
        await Task.detached(priority: .utility) {
            NativeOrbitLastKnownUsageFile.save(usages, provider: provider, directory: directory, savedAt: now)
        }.value
    }

    /// Writes pending readings before the app quits, so the next launch starts from the newest values.
    func flushSynchronously() {
        guard let directory = self.directory else { return }
        for provider in self.dirty {
            self.saveTasks[provider]?.cancel()
            self.saveTasks[provider] = nil
            NativeOrbitLastKnownUsageFile.save(
                (self.entries[provider] ?? [:]).mapValues(\.usage),
                provider: provider,
                directory: directory,
                savedAt: Date())
        }
        self.dirty.removeAll()
    }

    private func observeTermination() {
        guard self.terminationObserver == nil else { return }
        self.terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main)
        { [weak self] _ in
            MainActor.assumeIsolated { self?.flushSynchronously() }
        }
    }

    // MARK: - Owner digests

    /// SHA-256 over the owner evidence; only this digest is written to disk.
    nonisolated static func ownerDigest(_ parts: [String]) -> String {
        SHA256.hash(data: Data(parts.joined(separator: "\u{0}").utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

extension NativeOrbitAccountPresentation {
    /// Quiet help for corners showing a remembered reading until the live one lands, e.g. "Last updated 3 min ago".
    static func lastKnownUsageHelp(_ lastKnownAt: Date?, now: Date) -> String? {
        guard let lastKnownAt else { return nil }
        let seconds = max(0, now.timeIntervalSince(lastKnownAt))
        let age = switch seconds {
        case ..<60: "just now"
        case ..<3600: "\(Int(seconds / 60)) min ago"
        case ..<86400: "\(Int(seconds / 3600)) h ago"
        default: "\(Int(seconds / 86400)) d ago"
        }
        return "Last updated \(age)"
    }

    /// " · Last updated 3 min ago" for the live (not hovered) token and spend corners, or "" for live data.
    func lastKnownUsageHelpSuffix(now: Date) -> String {
        Self.lastKnownUsageHelp(self.usageLastKnownAt, now: now).map { " · \($0)" } ?? ""
    }
}
