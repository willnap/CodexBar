import CodexBarCore
import Foundation

/// Pure presentation policy: no credential reads, fetching, or changes to the selected login.
struct NativeCombinedAccounts {
    static let overviewID = "combined:overview"

    struct Connection {
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
    }

    struct Indicator: Identifiable {
        let id: String
        let targetID: String
        let provider: UsageProvider?
        var accountID: String?
        var symbol: String?
        var currentSymbol: String?
        let label: String
        let selected: Bool
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

    /// The combined popup needs at least one connected provider to open, even when combining always.
    static func shouldCombine(_ connections: [Connection], always: Bool = false) -> Bool {
        let connected = Set(connections.filter(\.isConnected).map(\.provider)).count
        return always ? connected > 0 : connected > 3
    }

    init(connections: [Connection], now: Date, preservingOrder: [String] = []) {
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
        // A provider stays contiguous; its most recently used account opens first. Freeze this order for a showing.
        var providers: [UsageProvider] = []
        for page in recent where !providers.contains(page.provider) {
            providers.append(page.provider)
        }
        let grouped = providers.flatMap { provider in recent.filter { $0.provider == provider } }
        let indexes = Dictionary(uniqueKeysWithValues: preservingOrder.enumerated().map { ($1, $0) })
        let providerIndexes = Dictionary(uniqueKeysWithValues: providers.map { provider in
            (provider, grouped.filter { $0.provider == provider }.compactMap { indexes[$0.id] }.min() ?? Int.max)
        })
        self.pages = preservingOrder.isEmpty ? grouped : grouped.sorted {
            if $0.provider != $1.provider {
                let left = providerIndexes[$0.provider] ?? Int.max
                let right = providerIndexes[$1.provider] ?? Int.max
                return left == right ? $0.provider.rawValue < $1.provider.rawValue : left < right
            }
            let left = indexes[$0.id] ?? Int.max
            let right = indexes[$1.id] ?? Int.max
            return left == right ? $0.id < $1.id : left < right
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

    func indicators(selectedID: String?, badges: [String: String] = [:]) -> [Indicator] {
        var result: [Indicator] = [.init(
            id: Self.overviewID,
            targetID: Self.overviewID,
            provider: nil,
            symbol: "square.stack.3d.up",
            label: L("All accounts"),
            selected: selectedID == Self.overviewID)]
        let selected = self.pages.first { $0.id == selectedID }
        var seen = Set<UsageProvider>()
        for page in self.pages where seen.insert(page.provider).inserted {
            let accounts = self.pages.filter { $0.provider == page.provider }
            result.append(.init(
                id: "provider:\(page.provider.rawValue)",
                targetID: selected.flatMap { $0.provider == page.provider ? $0.id : nil } ?? page.id,
                provider: page.provider,
                label: ProviderDescriptorRegistry.descriptor(for: page.provider).metadata.displayName,
                selected: selected?.provider == page.provider && accounts.count == 1))
            if selected?.provider == page.provider, accounts.count > 1 {
                result += accounts.map { account in
                    .init(
                        id: account.id,
                        targetID: account.id,
                        provider: page.provider,
                        accountID: account.account.id,
                        symbol: badges[account.id] ?? account.account.symbol,
                        label: account.account.label,
                        selected: selectedID == account.id)
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

    private func readings(days: Int, now: Date) -> [(page: Page, reading: NativeOrbitMetricSummary)] {
        var readings: [(page: Page, reading: NativeOrbitMetricSummary)] = []
        var seen = Set<UsageProvider>()
        for page in self.pages where seen.insert(page.provider).inserted {
            let pages = self.pages.filter { $0.provider == page.provider }
            let accounts = pages.map(\.account)
            let summaries = accounts.map { $0.metrics.summary(days: days, now: now) }
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
