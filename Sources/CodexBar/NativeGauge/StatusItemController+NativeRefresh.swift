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
    func loadNativeServiceUsage(_ provider: UsageProvider) async {
        guard !self.hasPreparedForAppShutdown, self.isEnabled(provider) else { return }
        let started = ContinuousClock.now
        // Provider-specific by design: ClaudeSwap's account list, not the ambient Claude login, supplies the Claude
        // columns while it owns them; the ambient reading follows with the enrichment.
        let adapterOwnsColumns = provider == .claude && self.store.nativeClaudeSwapOwnsPresentation
        await self.withProviderInteraction(.userInitiated) {
            if adapterOwnsColumns {
                await self.store.refreshClaudeSwapAccounts()
            } else {
                await self.store.refreshProvider(provider)
            }
        }
        let elapsed = started.duration(to: .now).components
        let milliseconds = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
        CodexBarLog.logger("native-gauges").info(
            "Native popup refresh loaded",
            metadata: ["provider": provider.rawValue, "milliseconds": String(format: "%.0f", milliseconds)])
    }

    func enrichNativeServiceUsage(_ provider: UsageProvider, loadStartedAt: Date) async {
        guard !self.hasPreparedForAppShutdown, self.isEnabled(provider) else { return }
        // Provider-specific by design: with ClaudeSwap owning the columns, the ambient Claude fetch is enrichment.
        if provider == .claude, self.store.nativeClaudeSwapOwnsPresentation {
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
        for host in self.nativeGaugeHosts.values {
            host.removeFromSuperview()
        }
        self.nativeGaugeHosts.removeAll()
    }
}
