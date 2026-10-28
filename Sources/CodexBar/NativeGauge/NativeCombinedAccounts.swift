import CodexBarCore
import Foundation

/// A common, absolute unit for both overview charts. Different currencies never share a scale.
enum NativeCombinedMetric: Equatable {
    case tokens
    case money(currency: String)

    var title: String {
        switch self {
        case .tokens: L("Tokens")
        case .money: L("Spend")
        }
    }

    func value(_ reading: NativeOrbitMetricSummary) -> Double? {
        let value: Double? = switch self {
        case .tokens: reading.tokens.map(Double.init)
        case let .money(currency): reading.currencyCode == currency ? reading.cost : nil
        }
        return value.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }

    func formatted(_ value: Double, compact: Bool = false) -> String {
        switch self {
        case .tokens:
            let count = Int(exactly: value.rounded()) ?? Int.max
            return compact ? NativeOrbitInstruments.compact(count) : "\(count.formatted()) tokens"
        case let .money(currency):
            return NativeOrbitInstruments.money(value, currency: currency)
        }
    }
}

/// Pure presentation policy: no credential reads, fetching, or changes to the selected login.
struct NativeCombinedAccounts {
    static let overviewID = "combined:overview"

    struct Connection: Equatable {
        let provider: UsageProvider
        let accounts: [NativeOrbitAccountPresentation]
        var hasSavedAccounts = false

        var isConnected: Bool {
            self.hasSavedAccounts || self.accounts.contains {
                $0.updatedAt != nil || $0.canActivate || $0.metrics.usage != nil
                    || $0.metrics.reportedBalance != nil || $0.metrics.primaryLocalUsage != nil
            }
        }
    }

    struct Page: Identifiable {
        let provider: UsageProvider
        let account: NativeOrbitAccountPresentation
        var id: String {
            Self.id(provider: self.provider, accountID: self.account.id)
        }

        static func id(provider: UsageProvider, accountID: String) -> String {
            "\(provider.rawValue):\(accountID)"
        }

        /// "Claude, name@example.com"; just the service for a login nothing identifies.
        var title: String {
            let service = ProviderDescriptorRegistry.descriptor(for: self.provider).metadata.displayName
            return self.account.isNamed ? service + ", " + self.account.label : service
        }
    }

    struct Indicator: Identifiable {
        let id: String
        let targetID: String
        let provider: UsageProvider?
        /// The provider mark its accounts emerge from and collapse into.
        var group: String?
        /// A provider mark showing its accounts, and those accounts: one platter holds them together.
        var expanded = false
        var accountID: String?
        var symbol: String?
        var currentSymbol: String?
        let label: String
        let selected: Bool
        /// How much of the mark's page is in the window, 0 to 1; a provider logo takes its most visible page.
        var visibility: Double = 0
    }

    struct Summary {
        var tokens: Int?
        var requests: Int?
        var costs: [String: Double] = [:]
        var isPartial = false

        init(_ readings: [NativeOrbitMetricSummary]) {
            for reading in readings {
                if let tokens = reading.tokens, tokens >= 0 {
                    self.tokens = Self.add(self.tokens, tokens)
                } else {
                    self.isPartial = true
                }
                if let requests = reading.requests, requests >= 0 {
                    self.requests = Self.add(self.requests, requests)
                }
                if let cost = reading.cost, cost.isFinite, cost >= 0 {
                    self.costs[reading.currencyCode, default: 0] += cost
                } else {
                    self.isPartial = true
                }
                self.isPartial = self.isPartial || reading.isPartial || reading.costIsPartial
                    || reading.costIsEstimated
            }
        }

        private static func add(_ current: Int?, _ value: Int) -> Int {
            let result = (current ?? 0).addingReportingOverflow(value)
            return result.overflow ? Int.max : result.partialValue
        }
    }

    let pages: [Page]
    let recentAccounts: [Page]
    private let capturedAt: Date
    private let liveReadings = LiveReadings()

    /// Value copies handed to the overview and its prepared chart share the same live totals. Inspected dates
    /// still use the original historical evaluator, so a cached current total cannot leak into past readings.
    private final class LiveReadings {
        private struct Key: Hashable {
            let days: Int
            let calendar: Calendar
        }

        private let lock = NSLock()
        private var values: [Key: [(page: Page, reading: NativeOrbitMetricSummary)]] = [:]

        func value(
            days: Int,
            calendar: Calendar,
            build: () -> [(page: Page, reading: NativeOrbitMetricSummary)])
            -> [(page: Page, reading: NativeOrbitMetricSummary)]
        {
            self.lock.withLock {
                let key = Key(days: days, calendar: calendar)
                if let value = self.values[key] { return value }
                let value = build()
                if self.values.count >= 16 { self.values.removeAll(keepingCapacity: true) }
                self.values[key] = value
                return value
            }
        }
    }

    /// The combined popup needs at least one connected provider to open, even when combining always.
    static func shouldCombine(_ connections: [Connection], always: Bool = false) -> Bool {
        let connected = Set(connections.filter(\.isConnected).map(\.provider)).count
        return always ? connected > 0 : connected > 3
    }

    init(connections: [Connection], now: Date, preservingOrder: [String] = []) {
        let timing = NativeCombinedRangeTiming.begin()
        defer { NativeCombinedRangeTiming.end("account-model", since: timing) }
        self.capturedAt = now
        let pages = connections.filter(\.isConnected).flatMap { connection in
            connection.accounts.map { Page(provider: connection.provider, account: $0) }
        }
        // Each account's history is scanned once, not once per comparison.
        let activity = Dictionary(
            pages.compactMap { page in Self.lastActivity(page.account, now: now).map { (page.id, $0) } },
            uniquingKeysWith: { first, _ in first })
        let recent = pages.sorted { lhs, rhs in
            let left = activity[lhs.id]
            let right = activity[rhs.id]
            if left != right { return (left ?? .distantPast) > (right ?? .distantPast) }
            if lhs.account.isActive != rhs.account.isActive { return lhs.account.isActive }
            return lhs.id < rhs.id
        }
        self.recentAccounts = Array(recent.prefix(3))
        // Accounts with usage left come first, most recently used first; drained ones follow. A provider's accounts
        // with usage left stay side by side, so they can be compared and switched; a drained one sorts on its own.
        let available = Set(pages.filter { Self.hasUsageLeft($0.account, now: now) }.map(\.id))
        let left = Dictionary(
            pages.compactMap { page in Self.usageLeft(page.account, now: now).map { (page.id, $0) } },
            uniquingKeysWith: { first, _ in first })
        let ranked = pages.sorted { lhs, rhs in
            let leftAvailable = available.contains(lhs.id)
            if leftAvailable != available.contains(rhs.id) { return leftAvailable }
            let leftActivity = activity[lhs.id]
            let rightActivity = activity[rhs.id]
            if leftActivity != rightActivity {
                return (leftActivity ?? .distantPast) > (rightActivity ?? .distantPast)
            }
            let leftRemaining = left[lhs.id] ?? 100
            let rightRemaining = left[rhs.id] ?? 100
            if leftRemaining != rightRemaining { return leftRemaining > rightRemaining }
            if lhs.account.isActive != rhs.account.isActive { return lhs.account.isActive }
            return lhs.id < rhs.id
        }
        var ordered: [Page] = []
        var placed = Set<String>()
        for page in ranked where !placed.contains(page.id) {
            let peers = available.contains(page.id)
                ? ranked.filter { $0.provider == page.provider && available.contains($0.id) } : [page]
            for peer in peers where placed.insert(peer.id).inserted {
                ordered.append(peer)
            }
        }
        // Freeze the order for a showing; accounts that appear meanwhile join at the end.
        let indexes = Dictionary(uniqueKeysWithValues: preservingOrder.enumerated().map { ($1, $0) })
        self.pages = preservingOrder.isEmpty ? ordered : ordered.enumerated().sorted {
            let left = indexes[$0.element.id] ?? Int.max
            let right = indexes[$1.element.id] ?? Int.max
            return left == right ? $0.offset < $1.offset : left < right
        }.map(\.element)
    }

    /// The least left of the account's current quota windows, in percent; nil without a current window.
    static func usageLeft(_ account: NativeOrbitAccountPresentation, now: Date) -> Double? {
        self.currentWindows(account, now: now).map(\.remainingPercent).min()
    }

    /// Like the fuel light: no current window is exhausted or down to its low-fuel reserve. An account without a
    /// quota window counts as having usage left.
    static func hasUsageLeft(_ account: NativeOrbitAccountPresentation, now: Date) -> Bool {
        self.currentWindows(account, now: now).allSatisfy { window in
            window.usedPercent < 100
                && window.remainingPercent > account.fuelReserve.percent(minutes: window.windowMinutes ?? .max)
        }
    }

    /// A window whose reset has passed has refilled, whatever its last reading said.
    private static func currentWindows(_ account: NativeOrbitAccountPresentation, now: Date) -> [RateWindow] {
        account.quotaWindows.values.filter { window in
            window.usedPercent.isFinite && window.usedPercent >= 0 && (window.resetsAt.map { $0 > now } ?? true)
        }
    }

    static func lastActivity(_ account: NativeOrbitAccountPresentation, now: Date) -> Date? {
        var dates = account.metrics.quotaConsumption
        if dates.isEmpty { dates = NativeOrbitActivity.consumptionDates(account.history) }
        for usage in [account.metrics.usage, account.metrics.localCostUsage.flatMap {
            $0.isAccountAttributed ? $0.snapshot : nil
        }].compactMap(\.self) {
            dates += usage.quotaSlices.filter { ($0.totalTokens ?? 0) > 0 || ($0.costUSD ?? 0) > 0 }.map(\.timestamp)
        }
        dates += account.metrics.creditUsageEvents.filter { $0.creditsUsed > 0 }.map(\.date)
        return dates.filter { $0 <= now }.max()
    }

    func indicators(
        selectedID: String?,
        badges: [String: String] = [:],
        visibility: [String: Double] = [:]) -> [Indicator]
    {
        var result: [Indicator] = [.init(
            id: Self.overviewID,
            targetID: Self.overviewID,
            provider: nil,
            symbol: "chart.pie.fill",
            label: L("All accounts"),
            selected: selectedID == Self.overviewID,
            visibility: visibility[Self.overviewID] ?? 0)]
        // One mark per run of a provider's adjacent pages. A drained account sorted away from its provider's
        // others is a run of its own, so the marks follow the pages' order.
        var runs: [[Page]] = []
        for page in self.pages {
            if runs.last?.first?.provider == page.provider {
                runs[runs.count - 1].append(page)
            } else {
                runs.append([page])
            }
        }
        var seen = Set<UsageProvider>()
        for run in runs {
            guard let first = run.first else { continue }
            let group = seen.insert(first.provider).inserted
                ? "provider:\(first.provider.rawValue)" : "provider:\(first.provider.rawValue):\(first.id)"
            let selected = run.first { $0.id == selectedID }
            let expanded = selected != nil && run.count > 1
            result.append(.init(
                id: group,
                targetID: selected?.id ?? first.id,
                provider: first.provider,
                group: group,
                expanded: expanded,
                label: ProviderDescriptorRegistry.descriptor(for: first.provider).metadata.displayName,
                selected: selected != nil && run.count == 1,
                visibility: run.map { visibility[$0.id] ?? 0 }.max() ?? 0))
            if expanded {
                result += run.map { account in
                    .init(
                        id: account.id,
                        targetID: account.id,
                        provider: first.provider,
                        group: group,
                        expanded: true,
                        accountID: account.account.id,
                        symbol: badges[account.id] ?? account.account.symbol,
                        label: account.account.label,
                        selected: selectedID == account.id,
                        visibility: visibility[account.id] ?? 0)
                }
            }
        }
        return result
    }

    /// Only an unattributed machine-wide report is shared. Attributed requests and separate profile reports
    /// belong to distinct accounts even when their display scope is the same.
    func summary(days: Int, now: Date) -> Summary {
        Summary(self.readings(days: days, now: now).map(\.reading))
    }

    struct Share: Identifiable {
        let page: Page
        let tokens: Int
        var id: String {
            self.page.id
        }
    }

    /// Each account's tokens in the range, a shared machine-wide report counted once (with its provider's first
    /// account), largest first. Accounts without a token count are absent rather than zero.
    func tokenShares(days: Int, now: Date) -> [Share] {
        self.readings(days: days, now: now).compactMap { page, reading in
            reading.tokens.flatMap { $0 > 0 ? Share(page: page, tokens: $0) : nil }
        }.sorted { $0.tokens == $1.tokens ? $0.page.id < $1.page.id : $0.tokens > $1.tokens }
    }

    struct MetricShare: Identifiable {
        let page: Page
        let value: Double
        var id: String {
            self.page.id
        }
    }

    func shares(metric: NativeCombinedMetric, days: Int, now: Date) -> [MetricShare] {
        self.readings(days: days, now: now).compactMap { page, reading in
            metric.value(reading).flatMap { $0 > 0 ? MetricShare(page: page, value: $0) : nil }
        }.sorted { $0.value == $1.value ? $0.id < $1.id : $0.value > $1.value }
    }

    func readings(days: Int, now: Date) -> [(page: Page, reading: NativeOrbitMetricSummary)] {
        guard now == self.capturedAt else { return self.computeReadings(days: days, now: now) }
        return self.liveReadings.value(days: days, calendar: .current) {
            self.computeReadings(days: days, now: now)
        }
    }

    private func computeReadings(days: Int, now: Date) -> [(page: Page, reading: NativeOrbitMetricSummary)] {
        let timing = NativeCombinedRangeTiming.begin()
        defer { NativeCombinedRangeTiming.end("all-readings", since: timing) }
        var readings: [(page: Page, reading: NativeOrbitMetricSummary)] = []
        var seen = Set<UsageProvider>()
        for page in self.pages where seen.insert(page.provider).inserted {
            let pages = self.pages.filter { $0.provider == page.provider }
            let accounts = pages.map(\.account)
            let summaries = accounts.map {
                $0.metrics.at(now, observedAt: $0.updatedAt, history: $0.history).summary(days: days, now: now)
            }
            let ownedTokens = zip(accounts, summaries).contains {
                $1.tokens != nil && !Self.isSharedMachine($0.metrics, scope: $1.usageScope, cost: false)
            }
            let ownedCosts = zip(accounts, summaries).contains {
                $1.cost != nil && !Self.isSharedMachine(
                    $0.metrics, scope: $1.costUsageScope ?? $1.usageScope, cost: true)
            }
            var includedMachineTokens = false
            var includedMachineCosts = false
            for (page, var summary) in zip(pages, summaries) {
                let account = page.account
                if Self.isSharedMachine(account.metrics, scope: summary.usageScope, cost: false) {
                    if ownedTokens || includedMachineTokens {
                        summary.tokens = nil
                        summary.requests = nil
                    }
                    includedMachineTokens = true
                    summary.isPartial = true
                }
                if Self.isSharedMachine(
                    account.metrics, scope: summary.costUsageScope ?? summary.usageScope, cost: true)
                {
                    if ownedCosts || includedMachineCosts { summary.cost = nil }
                    includedMachineCosts = true
                    summary.costIsPartial = true
                }
                readings.append((page, summary))
            }
        }
        return readings
    }

    private static func isSharedMachine(
        _ metrics: NativeOrbitAccountMetrics, scope: NativeOrbitUsageScope, cost: Bool) -> Bool
    {
        guard scope == .localMachine else { return false }
        let local = cost ? metrics.localCostUsage ?? metrics.primaryLocalUsage
            : metrics.primaryLocalUsage ?? metrics.localCostUsage
        return local?.isAccountAttributed != true
    }
}

/// Range, selection and hover updates keep the same account inventory. Rebuilding it would rescan every idle
/// account's histories before the range change can reach any chart.
@MainActor
final class NativeCombinedAccountsMemo {
    private struct Source: Equatable {
        let connections: [NativeCombinedAccounts.Connection]
        let now: Date
        let order: [String]
        let calendar: Calendar
    }

    private var source: Source?
    private var model: NativeCombinedAccounts?

    func value(
        connections: [NativeCombinedAccounts.Connection],
        now: Date,
        preservingOrder: [String]) -> NativeCombinedAccounts
    {
        let source = Source(connections: connections, now: now, order: preservingOrder, calendar: .current)
        if self.source == source, let model = self.model { return model }
        let model = NativeCombinedAccounts(connections: connections, now: now, preservingOrder: preservingOrder)
        self.source = source
        self.model = model
        return model
    }
}

extension UsageStore {
    func nativeCombinedConnections() -> [NativeCombinedAccounts.Connection] {
        self.settings.orderedFirstPartyProviders().filter { self.isEnabled($0) }.map { provider in
            .init(
                provider: provider,
                accounts: self.nativeOrbitAccounts(for: provider),
                hasSavedAccounts: !self.settings.tokenAccounts(for: provider).isEmpty
                    // Provider-specific by design: Codex and ClaudeSwap save logins outside the token inventory.
                    || (provider == .codex && self.nativeCodexAccountProjection?.visibleAccounts.isEmpty == false)
                    || (provider == .claude && !self.claudeSwapAccountSnapshots.isEmpty))
        }
    }
}
