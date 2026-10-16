import CodexBarCore
import CryptoKit
import Foundation

extension UsageStore {
    nonisolated static func nativeOrbitClaudeLocalUsage(
        account: ProviderAccountUsageSnapshot,
        accounts: [ProviderAccountUsageSnapshot],
        bucketTimeZoneIdentifier: String,
        publication: ClaudeOrganizationUsagePublication?) -> NativeOrbitLocalUsage?
    {
        // Provider-specific by design: organization-attributed transcripts belong only to verified Claude rows.
        guard let publication, account.provider == .claude,
              publication.bucketTimeZoneIdentifier == bucketTimeZoneIdentifier,
              let organization = account.sourceOrganizationID,
              publication.owners[account.id] == organization,
              ClaudeOrganizationUsagePublication.owners(for: accounts)[account.id] == organization,
              let report = publication.reports[organization] else { return nil }
        return NativeOrbitLocalUsage(
            snapshot: report,
            scope: .localMachine,
            bucketTimeZoneIdentifier: publication.bucketTimeZoneIdentifier)
    }

    /// Owner digest of a ClaudeSwap row's organization report: the slot, its organization (unique among the visible
    /// rows, as for live attribution), the account's email fingerprint and the bucket zone.
    nonisolated static func nativeOrbitClaudeLastKnownOwner(
        account: ProviderAccountUsageSnapshot,
        accounts: [ProviderAccountUsageSnapshot],
        bucketTimeZoneIdentifier: String) -> String?
    {
        // Provider-specific by design: only a uniquely attributable ClaudeSwap organization owner is remembered.
        guard account.provider == .claude, account.id.source == ClaudeSwapAccountProjection.sourceName,
              let organization = account.sourceOrganizationID,
              ClaudeOrganizationUsagePublication.owners(for: accounts)[account.id] == organization,
              let fingerprint = ClaudeSwapRetainedUsageStore.ownershipFingerprint(for: account) else { return nil }
        return NativeOrbitLastKnownUsageStore.ownerDigest([
            "claude-swap", account.id.opaqueID, organization, fingerprint, bucketTimeZoneIdentifier,
        ])
    }

    func nativeOrbitClaudeLocalUsage(_ account: ProviderAccountUsageSnapshot? = nil) -> NativeOrbitLocalUsage? {
        self.nativeOrbitClaudeResolvedLocalUsage(account)?.usage
    }

    /// The account's live organization report, or until the projection has served this owner, its last known one.
    func nativeOrbitClaudeResolvedLocalUsage(
        _ account: ProviderAccountUsageSnapshot? = nil) -> NativeOrbitResolvedLocalUsage?
    {
        guard let account else { return self.nativeOrbitClaudeResolvedAmbientUsage() }
        let accounts = self.claudeSwapAccountSnapshots
        let zone = self.settings.costUsageBucketCalendar.timeZone.identifier
        let publication = self.claudeOrganizationUsagePublication
        let owner = Self.nativeOrbitClaudeLastKnownOwner(
            account: account, accounts: accounts, bucketTimeZoneIdentifier: zone)
        if let live = Self.nativeOrbitClaudeLocalUsage(
            account: account,
            accounts: accounts,
            bucketTimeZoneIdentifier: zone,
            publication: publication)
        {
            // Provider-specific by design: Claude's per-account reports are owned by ClaudeSwap organizations, and
            // their last-known copies are keyed by that owner.
            self.nativeLastKnownUsage.record(.claude, owner: owner, usage: live)
            return NativeOrbitResolvedLocalUsage(usage: live)
        }
        // A projection that already served this owner is authoritative, even when it has no report for it.
        if let publication, publication.bucketTimeZoneIdentifier == zone,
           let organization = account.sourceOrganizationID, publication.owners[account.id] == organization
        {
            return nil
        }
        return self.nativeLastKnownUsage.usage(.claude, owner: owner)
    }

    private func nativeOrbitClaudeResolvedAmbientUsage() -> NativeOrbitResolvedLocalUsage? {
        let owner = self.nativeClaudeAmbientLastKnownOwner()
        if let local = self.nativeOrbitClaudeAmbientUsage() {
            self.nativeLastKnownUsage.record(.claude, owner: owner, usage: local)
            return NativeOrbitResolvedLocalUsage(usage: local)
        }
        // Provider-specific by design: the fallback consumes only previously verified Claude transcript reports.
        let report = self.spendDashboardTokenSnapshotPublicationForCurrentConfig(for: .claude)?.snapshot
            ?? self.tokenSnapshotForCurrentProviderConfig(for: .claude)?.snapshot
        guard let report else { return self.nativeLastKnownUsage.usage(.claude, owner: owner) }
        // Claude transcript history spans the machine, including earlier logins. Keep this provenance explicit.
        return NativeOrbitResolvedLocalUsage(usage: NativeOrbitLocalUsage(
            snapshot: report,
            scope: .localMachine,
            bucketTimeZoneIdentifier: self.settings.costUsageBucketTimeZoneIdentifier))
    }

    /// Reuse already verified background reports; rendering must not scan logs or read authentication files.
    func nativeOrbitCodexLocalUsage(_ account: CodexVisibleAccount) -> NativeOrbitLocalUsage? {
        Self.nativeOrbitCodexLocalUsage(
            account: account,
            homePath: self.nativeCodexHomePath(account),
            bucketTimeZoneIdentifier: self.settings.costUsageBucketTimeZoneIdentifier,
            publication: self.spendDashboardPublication)
    }

    /// A remembered attributed reading follows its durable account when activation swaps managed/live homes.
    /// The live scanner still requires the stricter home/source key below before accepting a new report.
    static func nativeCodexLastKnownUsageOwner(
        account: CodexVisibleAccount,
        bucketTimeZoneIdentifier: String) -> String?
    {
        guard let accountID = widgetCodexAccountID(account),
              let fingerprint = CodexAuthFingerprint.normalize(account.authFingerprint) else { return nil }
        return NativeOrbitLastKnownUsageStore.ownerDigest([
            "codex-remembered-account", accountID, fingerprint, bucketTimeZoneIdentifier,
        ])
    }

    /// SpendDashboardSource's cache ownership for one Codex home: the reconciled account, its selection source,
    /// session home, credential fingerprint and bucket zone.
    nonisolated static func nativeCodexLocalUsageOwner(
        account: CodexVisibleAccount,
        homePath: String?,
        bucketTimeZoneIdentifier: String) -> String?
    {
        guard let homePath = CodexHomeScope.normalizedHomePath(homePath),
              let fingerprint = CodexAuthFingerprint.normalize(account.authFingerprint) else { return nil }
        let source = switch account.selectionSource {
        case .liveSystem: "live"
        case let .managedAccount(id): "managed:\(id.uuidString.lowercased())"
        case let .profileHome(path): "profile:\(path)"
        }
        // This is SpendDashboardSource's existing cache ownership format, using only cached reconciled evidence.
        let material = [account.id, source, homePath, fingerprint, bucketTimeZoneIdentifier].joined(separator: "\u{0}")
        let digest = SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
        return "\(account.id)|\(digest)"
    }

    nonisolated static func nativeOrbitCodexLocalUsage(
        account: CodexVisibleAccount,
        homePath: String?,
        bucketTimeZoneIdentifier: String,
        publication: SpendDashboardPublication) -> NativeOrbitLocalUsage?
    {
        guard let configuration = publication.configuration, configuration.costUsageEnabled,
              configuration.bucketTimeZoneIdentifier == bucketTimeZoneIdentifier,
              let owner = nativeCodexLocalUsageOwner(
                  account: account,
                  homePath: homePath,
                  bucketTimeZoneIdentifier: bucketTimeZoneIdentifier) else { return nil }
        let publishedOwners = configuration.codexAccountIdentities.filter { $0.hasPrefix(account.id + "|") }
        guard publishedOwners == [owner] else { return nil }
        let sourceID = "codex:\(account.id)"
        // Provider-specific by design: this publication is an individually verified Codex home scan.
        let sources = publication.sources.filter { $0.id == sourceID && $0.provider == .codex }
        let inputs = publication.inputs
            .filter { $0.id == sourceID && $0.provider == .codex && $0.sourceKind == .native }
        // A retained report after a failed refresh is still this home's measured history, as a lower bound.
        guard sources.count == 1, let state = sources.first?.state, state == .available || state == .staleLastKnown,
              inputs.count == 1, let input = inputs.first else { return nil }
        // Managed homes are CodexBar's credential probes and profile homes may never run sessions: an empty scan
        // there is no evidence about the account's spend.
        if account.selectionSource != .liveSystem, Self.nativeCodexReportIsEmpty(input.snapshot) { return nil }
        return NativeOrbitLocalUsage(
            snapshot: input.snapshot,
            scope: account.selectionSource == .liveSystem ? .localMachine : .localProfile,
            bucketTimeZoneIdentifier: configuration.bucketCalendar.timeZone.identifier,
            isStale: state == .staleLastKnown)
    }
}
