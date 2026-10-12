import CodexBarCore
import Foundation

extension UsageStore {
    /// Ambient-row usage reports. Account reports and machine-local scans stay separately labeled.
    func nativeOrbitAmbientUsageReports(
        for provider: UsageProvider,
        snapshot: UsageSnapshot?) -> (usage: CostUsageTokenSnapshot?, local: NativeOrbitLocalUsage?)
    {
        let report = snapshot?.costUsage ?? self.tokenSnapshot(
            fromProviderSnapshot: snapshot,
            provider: provider,
            historyDays: self.settings.costUsageHistoryDays)
        // Provider-specific by design: Claude transcripts and Kimi wires describe this Mac, with explicit provenance.
        let ambient = self.nativeOrbitAmbientLocalUsage(for: provider)
        if Self.nativeOrbitSnapshotReportIsMachineLocal(provider), let report {
            return (nil, ambient ?? NativeOrbitLocalUsage(
                snapshot: report,
                scope: .localMachine,
                bucketTimeZoneIdentifier: report.bucketTimeZoneIdentifier
                    ?? self.settings.costUsageBucketTimeZoneIdentifier))
        }
        return (report, ambient ?? self.nativeOrbitCachedUsageReport(for: provider))
    }

    /// Live snapshot reports built from this Mac's session logs rather than an account endpoint.
    nonisolated static func nativeOrbitSnapshotReportIsMachineLocal(_ provider: UsageProvider) -> Bool {
        // Provider-specific by design: Grok session scans and the MiMo tracker cache publish local counters.
        provider == .grok || provider == .mimo
    }

    /// Usage receipts recorded before machine-local reports were excluded from account history would be restored as
    /// account totals; this Mac's scan is reread from its own dated buckets instead.
    nonisolated static func nativeOrbitHistoryDroppingMachineLocalReceipts(
        _ histories: [PlanUtilizationSeriesHistory],
        provider: UsageProvider) -> [PlanUtilizationSeriesHistory]
    {
        guard self.nativeOrbitSnapshotReportIsMachineLocal(provider) else { return histories }
        return histories.filter { $0.name.rawValue != "nativeMetric:usage" }
    }

    /// Providers whose spend/token history comes only from the background cost scan, never from the live snapshot.
    nonisolated static func nativeOrbitUsesCachedUsageReport(_ provider: UsageProvider) -> Bool {
        // Provider-specific by design: Claude and Codex own verified per-account report adapters.
        provider != .claude && self.usesSpendDashboardIndependentTokenSnapshot(provider)
    }

    /// Reuses the already published background report for the ambient row; rendering never starts a scan.
    func nativeOrbitCachedUsageReport(for provider: UsageProvider) -> NativeOrbitLocalUsage? {
        guard Self.nativeOrbitUsesCachedUsageReport(provider),
              self.settings.isCostUsageEffectivelyEnabled(for: provider),
              // A selected saved account owns its credential scope; the ambient report cannot describe it.
              self.settings.effectiveSelectedTokenAccount(for: provider) == nil,
              let report = self.spendDashboardTokenSnapshotPublicationForCurrentConfig(for: provider)?.snapshot
              ?? self.tokenSnapshotForCurrentProviderConfig(for: provider)?.snapshot
        else { return nil }
        return Self.nativeOrbitCachedUsage(
            provider: provider,
            report: report,
            bucketTimeZoneIdentifier: self.settings.costUsageBucketTimeZoneIdentifier)
    }

    /// A saved account's row shows the background report only when that report was fetched with the account's own
    /// credential; a matching credential fingerprint is the ownership proof, never the selection state.
    func nativeOrbitCachedUsageReport(
        for provider: UsageProvider,
        tokenAccount: ProviderTokenAccount) -> NativeOrbitLocalUsage?
    {
        guard Self.nativeOrbitUsesCachedUsageReport(provider),
              self.settings.isCostUsageEffectivelyEnabled(for: provider),
              let report = self.spendDashboardTokenSnapshotPublicationForCurrentConfig(for: provider)?.snapshot
              ?? self.tokenSnapshotForCurrentProviderConfig(for: provider)?.snapshot,
              Self.nativeOrbitCachedReport(report, belongsTo: tokenAccount)
        else { return nil }
        return Self.nativeOrbitCachedUsage(
            provider: provider,
            report: report,
            bucketTimeZoneIdentifier: self.settings.costUsageBucketTimeZoneIdentifier)
    }

    /// Only credential-scoped reports (Cursor dashboard fetches) carry the fingerprint this comparison needs.
    nonisolated static func nativeOrbitCachedReport(
        _ report: CostUsageTokenSnapshot,
        belongsTo account: ProviderTokenAccount) -> Bool
    {
        guard let fingerprint = report.credentialScopeFingerprint,
              CookieHeaderNormalizer.normalize(account.token) != nil
        else { return false }
        return CookieHeaderCache.credentialFingerprint(account.token) == fingerprint
    }

    nonisolated static func nativeOrbitCachedUsage(
        provider: UsageProvider,
        report: CostUsageTokenSnapshot,
        bucketTimeZoneIdentifier: String) -> NativeOrbitLocalUsage?
    {
        guard self.nativeOrbitUsesCachedUsageReport(provider) else { return nil }
        // Provider-specific by design: Bedrock billing and credential-scoped Cursor dashboard reports describe the
        // signed-in account. Local stores and exported Cursor CSVs describe activity recorded on this Mac.
        let scope: NativeOrbitUsageScope = switch provider {
        case .bedrock: .account
        case .cursor: report.credentialScopeFingerprint == nil ? .localMachine : .account
        default: .localMachine
        }
        return NativeOrbitLocalUsage(
            snapshot: report,
            scope: scope,
            bucketTimeZoneIdentifier: report.bucketTimeZoneIdentifier ?? bucketTimeZoneIdentifier)
    }
}
