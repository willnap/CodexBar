import AppKit
import CodexBarCore
import Observation
import SwiftUI

/// Prepared once; the native host observes cached, account-owned readings independently of menu
/// events.
@MainActor
final class NativeServicePopoverController: NSViewController, NSPopoverDelegate {
    struct Actions {
        /// Loads what the columns show; `enrich` then completes the provider's slower stages in the background.
        let refresh: () async -> Void
        var enrich: (_ loadStartedAt: Date) async -> Void = { _ in }
        let signIn: () -> Void
        let dashboard: () -> Void
        let settings: () -> Void
        let advanced: () -> Void
        let quit: () -> Void
        let selectCodexAccount: (CodexVisibleAccount) -> Void
        let selectTokenAccount: (UUID?) -> Void
        let selectClaudeSwapAccount: (ProviderAccountIdentity) -> Void
        var activateLogin: ((NativeOrbitAccountSelection) async -> NativeAccountActivationResult)?
        var refreshForSwitch: (() async -> Void)?
        var switchingAllowed: (() -> Bool)?
        var didClose: () -> Void = {}
    }

    static let contentSize = NSSize(width: 240, height: 513)
    private let provider: UsageProvider
    private let store: UsageStore
    private let settings: SettingsStore
    private let actions: Actions
    private weak var statusButton: NSStatusBarButton?
    private weak var popover: NSPopover?
    private let canSignIn: Bool
    private let claudeArchiveReader: NativeClaudeLocalArchive
    let orbitState = NativeOrbitPopupState()
    let manualRefresh = NativePopoverManualRefresh()
    private var badgeTask: Task<Void, Never>?
    private var badgeIdentityKey = ""
    private(set) var presentationClockTask: Task<Void, Never>?
    private var claudeArchiveTask: Task<Void, Never>?
    private var claudeFileArchiveHistory: [PlanUtilizationSeriesHistory] = []
    /// Store changes arrive continuously from background scans. A closed popup coalesces them so clicks never
    /// wait behind presentation rebuilds; an open popup follows them promptly.
    private var presentationDirty = false
    private var presentationRefreshTask: Task<Void, Never>?

    init(
        provider: UsageProvider,
        store: UsageStore,
        settings: SettingsStore,
        button: NSStatusBarButton,
        actions: Actions,
        canSignIn: Bool,
        signInTitle: String,
        hasDashboard: @escaping () -> Bool,
        claudeArchiveReader: NativeClaudeLocalArchive = .shared)
    {
        self.provider = provider
        self.store = store
        self.settings = settings
        self.statusButton = button
        self.actions = actions
        self.canSignIn = canSignIn
        self.claudeArchiveReader = claudeArchiveReader
        _ = signInTitle
        _ = hasDashboard
        super.init(nibName: nil, bundle: nil)
        if let activate = actions.activateLogin, let refresh = actions.refreshForSwitch,
           let allowed = actions.switchingAllowed
        {
            self.orbitState.accountSwitch = NativeAccountSwitchController(
                provider: provider,
                store: store,
                defaults: settings.userDefaults,
                activate: activate,
                refresh: refresh,
                allowed: allowed)
        }
    }

    deinit {
        self.presentationRefreshTask?.cancel()
        self.presentationClockTask?.cancel()
        self.badgeTask?.cancel()
        self.claudeArchiveTask?.cancel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func loadView() {
        self.refreshPresentation()
        self.view = NSHostingView(rootView: NativeOrbitPopupView(
            state: self.orbitState,
            activate: { [weak self] id in self?.activateAccount(id: id) },
            signIn: self.canSignIn ? self.actions.signIn : nil,
            refresh: { [weak self] in self?.refreshUsage() },
            settings: { [weak self] in self?.openSettings() }))
        self.view.frame = NSRect(origin: .zero, size: self.preferredContentSize)
        self.observePresentation()
        self.reloadClaudeLocalArchive()
    }

    func prepare() {
        _ = self.view
        self.reloadClaudeLocalArchive()
        self.view.layoutSubtreeIfNeeded()
    }

    private func observePresentation() {
        self.presentationDirty = false
        withObservationTracking {
            self.refreshPresentation()
        } onChange: { [weak self] in
            DispatchQueue.main.async { [weak self] in self?.schedulePresentationRefresh() }
        }
    }

    /// The next show rebuilds the presentation, as after a background change (used by the opt-in benchmark).
    func invalidatePresentation() {
        self.presentationDirty = true
    }

    private func schedulePresentationRefresh() {
        self.presentationDirty = true
        guard self.presentationRefreshTask == nil else { return }
        let delay: Duration = self.popover?.isShown == true ? .milliseconds(150) : .seconds(3)
        self.presentationRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.presentationRefreshTask = nil
            if self.presentationDirty { self.observePresentation() }
        }
    }

    private func refreshPresentation() {
        self.orbitState.accounts = self.store.nativeOrbitAccounts(for: self.provider)
        // Provider-specific by design: Claude excludes only the exact owners already shown by ClaudeSwap rows.
        self.orbitState.claudeLocalArchiveHistory = NativeOrbitClaudeLocalArchive.mergedHistories(
            fileHistories: self.claudeFileArchiveHistory,
            buckets: self.store.planUtilizationHistoryLoaded ? self.store.planUtilizationHistory[.claude] : nil,
            excludingOwnerKeys: Set(self.store.claudeSwapAccountSnapshots.compactMap(
                UsageStore.nativeOrbitClaudeHistoryKey)),
            provider: self.provider)
        // Provider-specific by design: anonymous Codex log readings stay outside every named account column.
        self.orbitState.codexLocalArchiveHistory = self.provider == .codex && self.store.planUtilizationHistoryLoaded
            ? (self.store.planUtilizationHistory[.codex]?.unscoped ?? []) : []
        // Provider-specific by design: Kimi archives exclude only the accepted credential owner's bucket.
        self.orbitState.kimiLocalArchiveHistory = self.provider == .kimi && self.store.planUtilizationHistoryLoaded
            ? NativeOrbitKimiLocalArchive.histories(
                self.store.planUtilizationHistory[.kimi] ?? .init(),
                excludingAcceptedOwnerKey: self.store.snapshot(for: UsageProvider.kimi.instanceID)
                    .flatMap(UsageStore.nativeKimiHistoryAccountKey)) : []
        self.orbitState.now = Date()
        // The spinner follows the toolbar's own load; background refreshes publish without one.
        self.orbitState.isRefreshing = self.manualRefresh.isLoading
        if self.orbitState.refreshError != nil, !self.manualRefresh.isLoading {
            self.orbitState.refreshError = Self.refreshError(self.orbitState.accounts)
        }
        let color = self.settings.accentColor(for: self.provider)
        self.orbitState.accent = Color(red: color.red, green: color.green, blue: color.blue)
        let badgeKey = NativeOrbitBadgeResolver.identityKey(self.orbitState.accounts)
        if badgeKey != self.badgeIdentityKey {
            self.badgeIdentityKey = badgeKey
            self.orbitState.badges = NativeOrbitBadgeResolver.initialBadges(self.orbitState.accounts)
            self.badgeTask = Task { [weak self] in
                guard let self else { return }
                await NativeOrbitBadgeResolver.resolve(self.orbitState)
            }
        }
        let count = max(1, self.orbitState.accounts.count)
        let availableWidth = self.statusButton?.window?.screen?.visibleFrame.width ?? 1200
        let footerHeight = self.orbitState.accounts.count > 1
            || (self.orbitState.accounts.first?.updatedAt == nil && self.canSignIn) ? 28 : 0
        self.preferredContentSize = NSSize(
            width: min(CGFloat(count * 240 + (count - 1)), availableWidth - 40),
            height: CGFloat(513 + footerHeight))
        self.popover?.contentSize = self.preferredContentSize
        NativeOrbitHistoryInspectionProof.write(provider: self.provider, store: self.store, state: self.orbitState)
    }

    func refreshUsage() {
        let started = self.manualRefresh.start(
            load: { [weak self] in await self?.actions.refresh() },
            enrich: { [weak self] startedAt in await self?.actions.enrich(startedAt) },
            completion: { [weak self] outcome in self?.finishManualRefresh(outcome) })
        guard started else { return }
        self.reloadClaudeLocalArchive()
        self.orbitState.refreshError = nil
        self.orbitState.isRefreshing = true
    }

    private func finishManualRefresh(_ outcome: NativePopoverManualRefresh.Outcome) {
        // Show the published readings at once instead of after the usual coalescing delay.
        self.presentationRefreshTask?.cancel()
        self.presentationRefreshTask = nil
        self.observePresentation()
        self.orbitState.refreshError = switch outcome {
        case .finished: Self.refreshError(self.orbitState.accounts)
        case .timedOut: L("native_refresh_timed_out")
        }
        self.orbitState.isRefreshing = false
    }

    /// The columns' own failures, so the toolbar reports why a refresh left a reading out of date.
    static func refreshError(_ accounts: [NativeOrbitAccountPresentation]) -> String? {
        let failures = accounts.compactMap { account -> String? in
            guard let status = account.statusText?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !status.isEmpty else { return nil }
            return accounts.count > 1 ? "\(account.label): \(status)" : status
        }
        return failures.isEmpty ? nil : failures.joined(separator: "\n")
    }

    func openSettings() {
        self.actions.settings()
    }

    private func reloadClaudeLocalArchive() {
        // Provider-specific by design: only Claude has this companion archive, whose account was never recorded.
        guard self.provider == .claude, self.settings.nativeDesignEnabled,
              self.store.isEnabled(self.provider) else { return }
        self.claudeArchiveTask?.cancel()
        let reader = self.claudeArchiveReader
        self.claudeArchiveTask = Task(priority: .utility) { @MainActor [weak self] in
            let points = await reader.load()
            guard !Task.isCancelled, let self, self.settings.nativeDesignEnabled,
                  self.store.isEnabled(self.provider) else { return }
            self.claudeFileArchiveHistory = NativeOrbitClaudeLocalArchive.histories(points)
            self.refreshPresentation()
        }
    }

    func activateAccount(id: String) {
        guard let account = self.orbitState.accounts.first(where: { $0.id == id }),
              account.canActivate else { return }
        if let switching = self.orbitState.accountSwitch {
            switching.activate(account)
            return
        }
        // Provider-specific by design: Activation dispatches each cached row to its existing
        // account-owner action.
        switch account.selection {
        case let .codex(account): self.actions.selectCodexAccount(account)
        case let .token(id): self.actions.selectTokenAccount(id)
        case let .claudeSwap(account): self.actions.selectClaudeSwapAccount(account.id)
        case .none: break
        }
    }

    func popoverWillShow(_ notification: Notification) {
        // Appear at once with the prepared columns; a pending background change is applied right after showing,
        // so the click never waits behind a presentation rebuild.
        self.orbitState.now = Date()
        if self.presentationDirty {
            self.presentationRefreshTask?.cancel()
            self.presentationRefreshTask = Task { @MainActor [weak self] in
                await Task.yield()
                guard let self, !Task.isCancelled else { return }
                self.presentationRefreshTask = nil
                if self.presentationDirty { self.observePresentation() }
            }
        }
        self.reloadClaudeLocalArchive()
        self.popover = notification.object as? NSPopover
        self.popover?.contentSize = self.preferredContentSize
        self.statusButton?.highlight(true)
    }

    func popoverDidShow(_ notification: Notification) {
        self.presentationClockTask?.cancel()
        self.presentationClockTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                self?.refreshPresentation()
                self?.reloadClaudeLocalArchive()
            }
        }
    }

    func popoverDidClose(_ notification: Notification) {
        self.presentationClockTask?.cancel()
        self.presentationClockTask = nil
        self.claudeArchiveTask?.cancel()
        self.statusButton?.highlight(false)
        self.actions.didClose()
    }
}
