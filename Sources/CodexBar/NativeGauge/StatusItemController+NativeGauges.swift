import AppKit
import CodexBarCore
import SwiftUI

extension StatusItemController {
    func applyNativeGauge(for provider: UsageProvider) {
        guard let item = self.statusItems[provider.instanceID],
              let button = item.button else { return }
        let presentation = self.store.nativeServicePresentation(for: provider)
        let state = presentation.gauge
        let host: NativeGaugeHostingView
        if let existing = self.nativeGaugeHosts[provider.instanceID],
           existing.superview === button
        {
            host = existing
        } else {
            self.nativeGaugeHosts[provider.instanceID]?.removeFromSuperview()
            host = NativeGaugeHostingView(rootView: AnyView(EmptyView()))
            button.addSubview(host)
            self.nativeGaugeHosts[provider.instanceID] = host
        }
        button.image = nil
        button.title = ""
        host.update(
            state: state,
            accountID: presentation.gaugeOwnershipID,
            button: button,
            item: item)
        let model = presentation.model
        let health: String = switch state.health {
        case .live: ""
        case .stale: L("Usage delayed or service degraded")
        case .unknown: L("Usage unknown")
        case .paused: L("Service maintenance")
        case .offline: L("No usage access")
        case .outage: L("Service outage")
        case .disabled: L("Provider disabled")
        case .authentication: L("Sign in required")
        }
        let pace = state.pace == .normal ? "" : "\(L("Usage pace")): \(state.pace.rawValue)"
        let label = [model.providerName, model.email, health, state.usageSummary(at: .now), pace]
            .filter { !$0.isEmpty }.joined(separator: ". ")
        button.toolTip = label
        button.setAccessibilityLabel(label)
        NativeGaugeDiagnostics.record(
            provider: provider,
            presentation: presentation,
            item: item,
            host: host)
    }

    func attachNativeServiceButtons() {
        if !self.nativeSystemSourcePrepared {
            self.nativeSystemSourcePrepared = true
            if self.settings.codexUsageDataSource != .pat {
                self.settings.codexActiveSource = .liveSystem
            }
        }
        for provider in UsageProvider.allCases
            where self.isEnabled(provider) || self.fallbackProvider == provider
        {
            let item = self.lazyStatusItem(for: provider)
            item.menu = nil
            item.button?.target = self
            item.button?.action = #selector(self.nativeServiceClicked(_:))
            item.button?.sendAction(on: [.leftMouseDown, .rightMouseUp])
            if let button = item.button { _ = self.nativePopover(for: provider, button: button) }
        }
        let visibleIDs = Set(self.statusItems.keys)
        for id in Array(self.nativeGaugeHosts.keys) where !visibleIDs.contains(id) {
            self.nativeGaugeHosts.removeValue(forKey: id)?.removeFromSuperview()
        }
        for id in Array(self.nativeServicePopovers.keys)
            where id.firstPartyProvider.map({ !self.isVisible($0) }) ?? true
        {
            self.removeNativeServicePopover(for: id)
        }
        if let provider = self.nativeServiceRoute.provider, !self.isVisible(provider) {
            self.closeNativeServicePopover()
        }
    }

    @objc func nativeServiceClicked(_ sender: NSStatusBarButton) {
        guard let provider = self.statusItems.first(where: { $0.value.button === sender })?.key
            .firstPartyProvider
        else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            self.showNativeAdvancedActions(for: provider, button: sender)
            return
        }
        let waited = Self.clickWaitMilliseconds()
        let wasOpen = self.nativeUsagePopover?.isShown == true
        if !wasOpen { self.nativeServiceRoute.dismiss() }
        self.nativeServiceRoute.toggle(provider)
        guard self.nativeServiceRoute.provider != nil else {
            self.closeNativeServicePopover()
            return
        }
        self.lastMenuProvider = provider.instanceID
        self.nativeUsagePopover?.close()
        let opening = ContinuousClock.now
        let popover = self.nativePopover(for: provider, button: sender)
        self.nativeUsagePopover = popover
        // Become the active app while the popup is open, so the transient popover receives the click elsewhere
        // that dismisses it, exactly like any other app's popover.
        NSApp.activate()
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        let elapsed = opening.duration(to: .now).components
        let milliseconds = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
        CodexBarLog.logger("native-gauges").info(
            "Native popup shown",
            metadata: [
                "provider": provider.rawValue,
                "waitedMilliseconds": String(format: "%.1f", waited),
                "milliseconds": String(format: "%.1f", milliseconds),
            ])
        // Whether the popup can take the next click directly: activation is asynchronous, so check after it settles.
        Task { @MainActor [weak popover] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let popover, popover.isShown else { return }
            CodexBarLog.logger("native-gauges").info(
                "Native popup focus",
                metadata: [
                    "provider": provider.rawValue,
                    "appActive": NSApp.isActive ? "1" : "0",
                    "popupKey": popover.contentViewController?.view.window?.isKeyWindow == true ? "1" : "0",
                ])
        }
        self.nativePopoverOpened(provider: provider, popover: popover)
    }

    func nativePopover(for provider: UsageProvider, button sender: NSStatusBarButton) -> NSPopover {
        if let existing = self.nativeServicePopovers[provider.instanceID] { return existing }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        let implementation = ProviderCatalog.implementation(for: provider)
        let controller = NativeServicePopoverController(
            provider: provider,
            store: self.store,
            settings: self.settings,
            button: sender,
            actions: .init(
                refresh: { [weak self] in await self?.loadNativeServiceUsage(provider) },
                enrich: { [weak self] startedAt in
                    await self?.enrichNativeServiceUsage(provider, loadStartedAt: startedAt)
                },
                signIn: { [weak self] in self?.signInToNativeService(provider) },
                dashboard: { [weak self] in
                    guard let self else { return }
                    if let url = self.dashboardURL(for: provider) {
                        NSWorkspace.shared.open(url)
                    } else {
                        self.openNativeServiceSettings(provider)
                    }
                },
                settings: { [weak self] in self?.openNativeServiceSettings(provider) },
                advanced: { [weak self] in
                    guard let self,
                          let button = self.statusItems[provider.instanceID]?.button else { return }
                    self.showNativeAdvancedActions(for: provider, button: button)
                },
                quit: { [weak self] in self?.quit() },
                selectCodexAccount: { [weak self] account in
                    self?.handleCodexVisibleAccountSelection(account, menu: nil)
                },
                selectTokenAccount: { [weak self] accountID in
                    self?.selectNativeTokenAccount(accountID, provider: provider)
                },
                selectClaudeSwapAccount: { [weak self] id in
                    self?.handleClaudeSwapAccountSelection(id, menu: nil)
                },
                activateLogin: { [weak self] selection in
                    guard let self else { return .unavailable("Account switching is unavailable.") }
                    return await self.activateNativeAccount(
                        provider: provider,
                        selection: selection)
                },
                refreshForSwitch: { [weak self] in
                    guard let self else { return }
                    await self.store.refreshProvider(provider)
                    // Provider-specific by design: ClaudeSwap maintains its own inventory alongside
                    // Claude usage.
                    if provider == .claude { await self.store.refreshClaudeSwapAccounts() }
                },
                switchingAllowed: { [weak self] in
                    guard let self else { return false }
                    return !self.hasPreparedForAppShutdown && self.settings.usesNativeGauges && self
                        .isEnabled(provider) &&
                        !self.isNativeAccountActivationBlocked(provider: provider)
                },
                statusPage: { [weak self] in self?.openProviderStatusPage(provider) },
                availableUpdate: { [weak self] in
                    guard let self else { return nil }
                    return NativeAppUpdatePresentation.warning(updater: self.updater)
                },
                checkForUpdates: { [weak self] in
                    guard let self else { return }
                    self.closeNativeServicePopover()
                    NativeAppUpdatePresentation.open(updater: self.updater, showAbout: self.showSettingsAbout)
                },
                canLaunchLogin: { [weak self] in self?.nativeServiceCanLaunchLogin(provider) == true },
                didClose: { [weak self] in
                    self?.nativePopoverRefreshScheduler.cancel()
                    // Hand activation back once nothing of ours is on screen (e.g. closed from its status item).
                    if NSApp.isActive, !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeKey }) {
                        NSApp.deactivate()
                    }
                }),
            canSignIn: implementation != nil,
            signInTitle: implementation?.supportsLoginFlow == true ? L("Sign In…") : L("Connect…"),
            hasDashboard: { [weak self] in self?.dashboardURL(for: provider) != nil })
        popover.contentViewController = controller
        popover.contentSize = NativeServicePopoverController.contentSize
        popover.delegate = controller
        controller.prepare()
        popover.contentSize = controller.preferredContentSize
        self.nativeServicePopovers[provider.instanceID] = popover
        return popover
    }

    func closeNativeServicePopover() {
        self.nativePopoverRefreshScheduler.cancel()
        self.nativeUsagePopover?.close()
        self.nativeUsagePopover = nil
        self.nativeServiceRoute.dismiss()
    }

    func removeNativeServicePopover(for instanceID: ProviderInstanceID) {
        guard let popover = self.nativeServicePopovers.removeValue(forKey: instanceID)
        else { return }
        (popover.contentViewController as? NativeServicePopoverController)?.orbitState.accountSwitch?.stop()
        if popover === self.nativeUsagePopover { self.closeNativeServicePopover() }
        popover.close()
    }

    private func refreshNativeService(_ provider: UsageProvider) {
        self.startManualRefresh(
            for: provider.instanceID,
            originatingMenuID: nil,
            originatingMenuInteractionGeneration: nil)
    }

    private func signInToNativeService(_ provider: UsageProvider) {
        guard self.nativeServiceCanLaunchLogin(provider) else {
            self.configureNativeService(provider)
            return
        }
        self.closeNativeServicePopover()
        Task { @MainActor [weak self] in
            await self?.runLoginFlowFromSettings(provider: provider)
        }
    }

    private func nativeServiceCanLaunchLogin(_ provider: UsageProvider) -> Bool {
        // Provider-specific by design: Managed Codex and ClaudeSwap accounts must reconnect through
        // their scoped
        // account settings.
        if provider == .codex, self.settings.codexActiveSource != .liveSystem {
            return false
        }
        if provider == .claude, self.store.nativeClaudeSwapOwnsPresentation {
            return false
        }
        if self.settings.effectiveSelectedTokenAccount(for: provider) != nil {
            return false
        }
        guard ProviderCatalog.implementation(for: provider)?.supportsLoginFlow == true else {
            return false
        }
        return true
    }

    private func configureNativeService(_ provider: UsageProvider) {
        self.closeNativeServicePopover()
        let sender = NSMenuItem()
        sender.representedObject = provider.rawValue
        self.showProviderSettings(sender)
    }

    /// Settings opens at once; the popup stays for the toolbar gear's turn, then fades out over it.
    private func openNativeServiceSettings(_ provider: UsageProvider) {
        let popover = self.nativeUsagePopover
        let sender = NSMenuItem()
        sender.representedObject = provider.rawValue
        self.showProviderSettings(sender)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, let popover, self.nativeUsagePopover === popover else { return }
            self.closeNativeServicePopover()
        }
    }

    private func selectNativeTokenAccount(_ accountID: UUID?, provider: UsageProvider) {
        self.store.selectNativeTokenAccount(accountID, for: provider)
        self.updateIcons()
        self.refreshNativeService(provider)
    }

    private func showNativeAdvancedActions(for provider: UsageProvider, button: NSStatusBarButton) {
        self.closeNativeServicePopover()
        self.lastMenuProvider = provider.instanceID
        let menu = self.makeMenu(for: provider)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
    }
}
