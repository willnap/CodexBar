import AppKit
import CodexBarCore

extension StatusItemController {
    func nativePopoverOpened(provider: UsageProvider, popover: NSPopover) {
        self.store.noteMenuOpened()
        self.nativePopoverRefreshScheduler.schedule(
            enabled: self.settings.refreshAllProvidersOnMenuOpen,
            isCurrent: { [weak self, weak popover] in
                guard let self, let popover else { return false }
                return !self.hasPreparedForAppShutdown && self.settings.refreshAllProvidersOnMenuOpen
                    && self.nativeUsagePopover === popover && popover.isShown
                    && self.nativeServiceRoute.provider == provider
            },
            refresh: { [weak self] in
                guard let self else { return }
                let providers = self.store.enabledProvidersForBackgroundWork().compactMap(\.firstPartyProvider)
                await ProviderInteractionContext.$current.withValue(.background) {
                    await withTaskGroup(of: Void.self) { group in
                        for provider in providers {
                            group.addTask {
                                await self.store.refreshProvider(provider, coalesceIfRefreshing: true)
                            }
                        }
                    }
                }
            })
    }

    /// The popup's refresh loads exactly what its columns show, so its spinner never waits behind work they do not
    /// display (provider status, token-history scans, Codex credits). Those follow in `enrichNativeServiceUsage`.
    /// It always fetches anew: a background request in flight is replaced rather than joined, since it may have
    /// started long before the press, and nothing in the background (scans, enrichment) is awaited first.
    func loadNativeServiceUsage(_ provider: UsageProvider) async {
        guard !self.hasPreparedForAppShutdown, self.isEnabled(provider) else { return }
        let started = ContinuousClock.now
        let wasBusy = self.store.refreshingProviders.contains(provider.instanceID)
        // Provider-specific by design: ClaudeSwap's list supplies the Claude columns while it owns them; the ambient
        // Claude login's fetch joins the load only when its reading measures one of those columns.
        let adapterOwnsColumns = provider == .claude && self.store.nativeClaudeSwapOwnsPresentation
        let ambientInLoad = adapterOwnsColumns && self.store.nativeClaudeAmbientMeasuresSwapColumn
        await self.withProviderInteraction(.userInitiated) {
            if adapterOwnsColumns {
                await self.store.refreshClaudeSwapColumnsForUser(includingAmbient: ambientInLoad)
            } else {
                await self.store.refreshProviderForUser(provider)
            }
        }
        let elapsed = started.duration(to: .now).components
        let milliseconds = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
        var metadata = [
            "provider": provider.rawValue,
            "milliseconds": String(format: "%.0f", milliseconds),
            "replacedBackgroundRefresh": wasBusy ? "1" : "0",
        ]
        if adapterOwnsColumns {
            metadata["ambientInLoad"] = ambientInLoad ? "1" : "0"
            metadata.merge(self.store.nativeClaudeAmbientOwnershipDiagnostics()) { current, _ in current }
        }
        CodexBarLog.logger("native-gauges").info("Native popup refresh loaded", metadata: metadata)
    }

    func enrichNativeServiceUsage(_ provider: UsageProvider, loadStartedAt: Date) async {
        guard !self.hasPreparedForAppShutdown, self.isEnabled(provider) else { return }
        // Provider-specific by design: an ambient Claude fetch that did not join the load follows as enrichment.
        if provider == .claude, self.store.nativeClaudeSwapOwnsPresentation,
           !self.store.nativeClaudeAmbientMeasuresSwapColumn
        {
            await self.performStoreRefresh(
                for: provider,
                refreshOpenMenusWhenComplete: false,
                interaction: .userInitiated)
            return
        }
        await self.withProviderInteraction(.userInitiated) {
            await self.performStoreRefreshEnrichment(
                for: provider,
                refreshStartedAt: loadStartedAt,
                refreshOpenMenusWhenComplete: false)
        }
    }

    func detachNativePresentationIfNeeded() {
        guard !self.settings.usesNativeGauges else { return }
        self.closeNativeServicePopover()
        self.nativeServicePopovers.removeAll()
        self.nativeCombinedPopover = nil
        self.nativeCombinedProviders = []
        for host in self.nativeGaugeHosts.values {
            host.removeFromSuperview()
        }
        self.nativeGaugeHosts.removeAll()
        for host in self.nativeCombinedGaugeHosts.values {
            host.removeFromSuperview()
        }
        self.nativeCombinedGaugeHosts.removeAll()
    }
}
