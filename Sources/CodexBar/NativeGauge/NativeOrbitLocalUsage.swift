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

    func nativeOrbitClaudeLocalUsage(_ account: ProviderAccountUsageSnapshot? = nil) -> NativeOrbitLocalUsage? {
        if let account {
            return Self.nativeOrbitClaudeLocalUsage(
                account: account,
                accounts: self.claudeSwapAccountSnapshots,
                bucketTimeZoneIdentifier: self.settings.costUsageBucketCalendar.timeZone.identifier,
                publication: self.claudeOrganizationUsagePublication)
        }
        if let local = self.nativeOrbitClaudeAmbientUsage() { return local }
        // Provider-specific by design: the fallback consumes only previously verified Claude transcript reports.
        let report = self.spendDashboardTokenSnapshotPublicationForCurrentConfig(for: .claude)?.snapshot
            ?? self.tokenSnapshotForCurrentProviderConfig(for: .claude)?.snapshot
        guard let report else { return nil }
        // Claude transcript history spans the machine, including earlier logins. Keep this provenance explicit.
        return NativeOrbitLocalUsage(
            snapshot: report,
            scope: .localMachine,
            bucketTimeZoneIdentifier: self.settings.costUsageBucketTimeZoneIdentifier)
    }

    /// Reuse already verified background reports; rendering must not scan logs or read authentication files.
    func nativeOrbitCodexLocalUsage(_ account: CodexVisibleAccount) -> NativeOrbitLocalUsage? {
        Self.nativeOrbitCodexLocalUsage(
            account: account,
            homePath: self.nativeCodexHomePath(account),
            bucketTimeZoneIdentifier: self.settings.costUsageBucketTimeZoneIdentifier,
            publication: self.spendDashboardPublication)
    }

    nonisolated static func nativeOrbitCodexLocalUsage(
        account: CodexVisibleAccount,
        homePath: String?,
        bucketTimeZoneIdentifier: String,
        publication: SpendDashboardPublication) -> NativeOrbitLocalUsage?
    {
        guard let configuration = publication.configuration, configuration.costUsageEnabled,
              configuration.bucketTimeZoneIdentifier == bucketTimeZoneIdentifier,
              let homePath = CodexHomeScope.normalizedHomePath(homePath),
              let fingerprint = CodexAuthFingerprint.normalize(account.authFingerprint) else { return nil }
        let source = switch account.selectionSource {
        case .liveSystem: "live"
        case let .managedAccount(id): "managed:\(id.uuidString.lowercased())"
        case let .profileHome(path): "profile:\(path)"
        }
        // This is SpendDashboardSource's existing cache ownership format, using only cached reconciled evidence.
        let material = [account.id, source, homePath, fingerprint, bucketTimeZoneIdentifier].joined(separator: "\u{0}")
        let digest = SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
        let owner = "\(account.id)|\(digest)"
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
