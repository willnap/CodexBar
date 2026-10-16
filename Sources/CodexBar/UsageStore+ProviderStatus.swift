import CodexBarCore
import Foundation

extension UsageStore {
    func refreshProviderStatus(_ provider: UsageProvider) async {
        guard self.settings.statusChecksEnabled else { return }
        guard let meta = self.providerMetadata[provider] else { return }
        let publicationRevision = self.providerPublicationRevision(for: provider)
        self.providerStatusRequestGeneration &+= 1
        let requestGeneration = self.providerStatusRequestGeneration

        do {
            let status: ProviderStatus
            var components: [ProviderStatusComponent]?
            if let override = self._test_providerStatusFetchOverride {
                status = try await override(provider)
            } else if let urlString = meta.statusPageURL, let baseURL = URL(string: urlString) {
                let summary = try await ProviderStatusFetcher.fetchStatusSummary(from: baseURL)
                status = summary.status
                components = summary.components
            } else if let productID = meta.statusWorkspaceProductID {
                status = try await ProviderStatusFetcher.fetchWorkspaceStatus(productID: productID)
            } else {
                return
            }
            guard self.statusRefreshPublicationIsCurrent(
                publicationRevision, requestGeneration: requestGeneration, for: provider) else { return }
            // A failed newer request provides no status evidence, so only a successful
            // publication retires earlier requests for this provider.
            self.providerStatusPublishedGenerations[provider.instanceID] = requestGeneration
            self.statuses[provider.instanceID] = status
            self.nativeStatusFetchFailures.remove(provider.instanceID)
            // A newer summary supersedes the old component evidence too. Retaining old rows here can
            // assert a stale component outage indefinitely after the current summary reports recovery.
            if let components {
                self.statusComponents[provider.instanceID] = components
            } else {
                self.statusComponents.removeValue(forKey: provider.instanceID)
            }
            self.emitProviderStatusHooks(provider: provider, indicator: status.indicator)
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
            guard self.statusRefreshPublicationIsCurrent(
                publicationRevision, requestGeneration: requestGeneration, for: provider) else { return }
            self.recordStartupConnectivityRetryableFailure(error)
            self.nativeStatusFetchFailures.insert(provider.instanceID)
            // A failed fetch provides no new status information. Preserve a last good status
            // to avoid flapping, or leave it unset until the first successful fetch.
        }
    }

    private func statusRefreshPublicationIsCurrent(
        _ publicationRevision: ProviderPublicationRevision,
        requestGeneration: UInt64,
        for provider: UsageProvider) -> Bool
    {
        self.providerPublicationRevisionIsCurrent(publicationRevision, for: provider) &&
            requestGeneration >= self.providerStatusPublishedGenerations[provider.instanceID, default: 0] &&
            self.settings.statusChecksEnabled &&
            self.settings.isProviderEnabledCached(
                provider: provider,
                metadataByProvider: self.providerMetadata)
    }
}
