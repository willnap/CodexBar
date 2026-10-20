import AppKit
import CodexBarCore
import Observation
import QuartzCore
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
        var statusPage: () -> Void = {}
        var availableUpdate: () -> String? = { nil }
        var checkForUpdates: (() -> Void)?
        var canLaunchLogin: () -> Bool = { false }
        var didClose: () -> Void = {}
    }

    static let contentSize = NSSize(width: 240, height: NativeOrbitPopupView.contentHeight(showsFooter: false))
    private let provider: UsageProvider
    private let store: UsageStore
    private let settings: SettingsStore
    private let actions: Actions
    private weak var statusButton: NSStatusBarButton?
    private weak var popover: NSPopover?
    private let canSignIn: Bool
    private let hasDashboard: () -> Bool
    private let claudeArchiveReader: NativeClaudeLocalArchive
    let orbitState = NativeOrbitPopupState()
    let manualRefresh = NativePopoverManualRefresh()
    /// When the toolbar's newest load started; a column measured well before it was not brought up to date.
    private var manualLoadStartedAt: Date?
    private var badgeTask: Task<Void, Never>?
    private var readinessCheckTask: Task<Void, Never>?
    private var badgeIdentityKey = ""
    private(set) var presentationClockTask: Task<Void, Never>?
    private var claudeArchiveTask: Task<Void, Never>?
    private var claudeFileArchiveHistory: [PlanUtilizationSeriesHistory] = []
    /// Store changes arrive continuously from background scans. A closed popup coalesces them so clicks never
    /// wait behind presentation rebuilds; an open popup follows them promptly.
    private var isInCombinedPresentation = false
    private var presentationDirty = false
    private var presentationRefreshTask: Task<Void, Never>?
    private let startupOwner = UUID()
    private let startupLaunch: NativeOrbitStartupLaunch
    private var startupTask: Task<Void, Never>?
    private var startupSelection = NativeOrbitStartupSelection()
    private var switchingCheckedAt: Date?

    init(
        provider: UsageProvider,
        store: UsageStore,
        settings: SettingsStore,
        button: NSStatusBarButton,
        actions: Actions,
        canSignIn: Bool,
        signInTitle: String,
        hasDashboard: @escaping () -> Bool,
        claudeArchiveReader: NativeClaudeLocalArchive = .shared,
        startupLaunch: NativeOrbitStartupLaunch = .shared)
    {
        self.startupLaunch = startupLaunch
        self.provider = provider
        self.store = store
        self.settings = settings
        self.statusButton = button
        self.actions = actions
        self.canSignIn = canSignIn
        self.claudeArchiveReader = claudeArchiveReader
        _ = signInTitle
        self.hasDashboard = hasDashboard
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
        self.readinessCheckTask?.cancel()
        self.startupTask?.cancel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func loadView() {
        self.store.prepareNativeAccountInventory(for: self.provider)
        self.refreshPresentation()
        self.view = NSHostingView(rootView: NativeOrbitPopupView(
            state: self.orbitState,
            activate: { [weak self] id in self?.activateAccount(id: id) },
            signIn: self.canSignIn ? self.actions.signIn : nil,
            refresh: { [weak self] in self?.refreshUsage() },
            settings: { [weak self] in self?.openSettings() },
            lightAction: { [weak self] accountID, action in self?.handleLight(action, accountID: accountID) }))
        self.view.frame = NSRect(origin: .zero, size: self.preferredContentSize)
        self.observePresentation()
        self.reloadClaudeLocalArchive()
    }

    func prepare() {
        _ = self.view
        self.reloadClaudeLocalArchive()
        self.view.layoutSubtreeIfNeeded()
        self.orbitState.prepareStartupArtwork(
            screen: self.statusButton?.window?.screen,
            appearance: self.isViewLoaded ? self.view.effectiveAppearance : nil)
    }

    private func observePresentation() {
        guard !self.orbitState.startup.isActive else {
            self.presentationDirty = true
            return
        }
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

    /// How long a closed popover gathers changes before rebuilding its columns. A refresh publishes many changes over
    /// a minute or two, and each rebuild re-renders every column nobody sees; opening applies any pending change at
    /// once.
    var hiddenPresentationDelay: Duration = .seconds(30)

    private func schedulePresentationRefresh() {
        self.presentationDirty = true
        guard self.presentationRefreshTask == nil else { return }
        let delay: Duration = (self.popover?.isShown == true || self.isInCombinedPresentation) ? .milliseconds(150) :
            self.hiddenPresentationDelay
        self.presentationRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.presentationRefreshTask = nil
            if self.presentationDirty { self.observePresentation() }
        }
    }

    private func refreshPresentation() {
        // Account receipts and archive scans can publish several times during a sweep. Keep the prepared
        // chart and glass trees stable until it ends, then apply the latest complete presentation once.
        guard !self.orbitState.startup.isActive else {
            self.presentationDirty = true
            return
        }
        let update = self.actions.availableUpdate()
        let accounts = self.store.nativeOrbitAccounts(for: self.provider)
        let metadata = self.store.metadata(for: self.provider)
        let statusURL = metadata.statusPageURL ?? metadata.statusLinkURL
        let hasStatusPage = statusURL.flatMap(URL.init(string:)) != nil
        self.orbitState.accounts = accounts.map { account in
            var row = account
            if let version = update {
                row.warnings = NativeOrbitWarningLight.merged(row.warnings + [
                    .init(.update, .opportunity, "CodexBar \(version) is available.", action: .checkForUpdates),
                ])
            }
            row.warnings = row.warnings.map {
                $0.resolvingAction(
                    hasStatusPage: hasStatusPage,
                    hasDashboard: self.hasDashboard(),
                    canSignIn: self.canSignIn && self.actions.canLaunchLogin() && accounts.count == 1)
            }
            return row
        }
        let switched = self.startupSelection.receive(
            activeID: self.startupAccountOwner)
        // Provider-specific by design: Claude excludes only the exact owners already shown by ClaudeSwap rows.
        self.orbitState.claudeLocalArchiveHistory = NativeOrbitClaudeLocalArchive.mergedHistories(
            fileHistories: self.claudeFileArchiveHistory,
            buckets: self.store.nativeHistoryAvailable(.claude) ? self.store.planUtilizationHistory[.claude] : nil,
            excludingOwnerKeys: Set(self.store.claudeSwapAccountSnapshots.compactMap(
                UsageStore.nativeOrbitClaudeHistoryKey)),
            provider: self.provider)
        // Provider-specific by design: anonymous Codex log readings stay outside every named account column.
        self.orbitState.codexLocalArchiveHistory = self.provider == .codex && self.store.nativeHistoryAvailable(.codex)
            ? (self.store.planUtilizationHistory[.codex]?.unscoped ?? []) : []
        // Provider-specific by design: Kimi archives exclude only the accepted credential owner's bucket.
        self.orbitState.kimiLocalArchiveHistory = self.provider == .kimi && self.store.nativeHistoryAvailable(.kimi)
            ? NativeOrbitKimiLocalArchive.histories(
                self.store.planUtilizationHistory[.kimi] ?? .init(),
                excludingAcceptedOwnerKey: self.store.snapshot(for: UsageProvider.kimi.instanceID)
                    .flatMap(UsageStore.nativeKimiHistoryAccountKey)) : []
        self.orbitState.now = Date()
        // The spinner follows the toolbar's own load; background refreshes publish without one.
        self.orbitState.isRefreshing = self.manualRefresh.isLoading
        if self.orbitState.refreshIssue != nil, !self.manualRefresh.isLoading {
            self.orbitState.refreshIssue = Self.refreshIssue(
                self.orbitState.accounts,
                requestedAt: self.manualLoadStartedAt)
        }
        self.updateSwitchingAvailability()
        let color = self.settings.accentColor(for: self.provider)
        self.orbitState.accent = Color(red: color.red, green: color.green, blue: color.blue)
        let badgeKey = NativeOrbitBadgeResolver.identityKey(self.orbitState.accounts)
        if NativeOrbitBadgeResolver.shouldResolve(self.orbitState.accounts, previousKey: self.badgeIdentityKey) {
            self.badgeIdentityKey = badgeKey
            self.orbitState.badges = NativeOrbitBadgeResolver.initialBadges(self.orbitState.accounts)
            self.badgeTask = Task { [weak self] in
                guard let self else { return }
                await NativeOrbitBadgeResolver.resolve(self.orbitState)
            }
        }
        self.orbitState.startupHistoryReady = self.store.nativeHistoryAvailable(self.provider)
        self.orbitState.startupStatusReady = !self.settings.statusChecksEnabled
            || (metadata.statusPageURL == nil && metadata.statusWorkspaceProductID == nil)
            || self.store.statuses[self.provider.instanceID] != nil
            || self.store.nativeStatusFetchFailures.contains(self.provider.instanceID)
        self.updateReadiness()
        let count = self.orbitState.layoutColumns
        let availableWidth = self.statusButton?.window?.screen?.visibleFrame.width ?? 1200
        let showsFooter = count > 1 || (self.orbitState.accounts.first?.updatedAt == nil && self.canSignIn)
        self.preferredContentSize = NSSize(
            width: min(CGFloat(count * 240 + (count - 1)), availableWidth - 40),
            height: NativeOrbitPopupView.contentHeight(showsFooter: showsFooter))
        self.popover?.contentSize = self.preferredContentSize
        if !self.startupLaunch.hasShown, self.popover?.isShown != true, !self.isInCombinedPresentation {
            self.orbitState.prepareStartupArtwork(
                screen: self.statusButton?.window?.screen,
                appearance: self.isViewLoaded ? self.view.effectiveAppearance : nil)
        }
        NativeOrbitHistoryInspectionProof.write(provider: self.provider, store: self.store, state: self.orbitState)
        if switched, self.popover?.isShown == true {
            self.orbitState.armStartup(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
            self.orbitState.prepareStartupArtwork(
                screen: self.statusButton?.window?.screen,
                appearance: self.isViewLoaded ? self.view.effectiveAppearance : nil)
            self.startStartup()
        }
    }

    private var startupAccountOwner: String? {
        guard let account = self.orbitState.accounts.first(where: \.isActive) else { return nil }
        // Provider-specific by design: Codex profiles and ClaudeSwap slots have different stable owner-key schemes.
        switch account.selection {
        case let .codex(owner): return UsageStore.widgetCodexAccountID(owner) ?? account.id
        case let .claudeSwap(owner): return UsageStore.nativeOrbitClaudeHistoryKey(owner)
        default: return account.id
        }
    }

    /// Readiness and the layout's column count. Ready, the popup remembers how many columns it showed, so the next
    /// launch lays the popup out for them before they load. Not ready, it checks again when the wait runs out.
    private func updateReadiness() {
        let key = "nativePopupColumns.\(self.provider.rawValue)"
        let defaults = self.settings.userDefaults
        let ready = self.store.nativePopupIsReady(for: self.provider, accounts: self.orbitState.accounts)
        let shown = max(1, self.orbitState.accounts.count)
        if ready {
            if defaults.integer(forKey: key) != shown { defaults.set(shown, forKey: key) }
            self.readinessCheckTask?.cancel()
            self.readinessCheckTask = nil
        } else if self.readinessCheckTask == nil {
            let wait = self.store.nativePopupReadinessWaitRemaining()
            self.readinessCheckTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard let self, !Task.isCancelled else { return }
                self.readinessCheckTask = nil
                self.refreshPresentation()
            }
        }
        if self.orbitState.isReady != ready { self.orbitState.isReady = ready }
        let columns = ready ? shown : max(shown, defaults.integer(forKey: key))
        if self.orbitState.layoutColumns != columns { self.orbitState.layoutColumns = columns }
    }

    /// Why this setup cannot switch the provider's login, rechecked at most every half minute (it reads a config
    /// file). Only providers whose logins CodexBar switches have a reason.
    private func updateSwitchingAvailability() {
        let now = Date()
        if let checked = self.switchingCheckedAt, now.timeIntervalSince(checked) < 30 { return }
        self.switchingCheckedAt = now
        let environment = self.store.environmentBase
        // Provider-specific by design: only Codex and Claude Code logins are switched, each with its own requirements.
        let reason: String? = switch self.provider {
        case .codex: NativeCodexActivationCapability.unavailabilityReason(environment: environment)
        case .claude: NativeAccountActivationVerification.claudeEnvironmentAllowsActivation(environment) ? nil
            : "Switching needs a Claude Code login without token or profile environment overrides."
        default: nil
        }
        if self.orbitState.switchingUnavailable != reason { self.orbitState.switchingUnavailable = reason }
    }

    func handleLight(_ action: NativeOrbitWarningLight.Action, accountID: String) {
        guard self.orbitState.accounts.contains(where: { $0.id == accountID }) else { return }
        switch action {
        case .signIn:
            // One account signs in from here; several re-authenticate the one that failed in Settings.
            if self.canSignIn, self.actions.canLaunchLogin(), self.orbitState.accounts.count == 1 {
                self.actions.signIn()
            } else {
                self.openSettings()
            }
        case .statusPage: self.actions.statusPage()
        case .refresh: self.refreshUsage()
        case .settings: self.openSettings()
        case .dashboard: self.actions.dashboard()
        case .details: self.openSettings()
        case .checkForUpdates:
            if let check = self.actions.checkForUpdates {
                check()
            } else {
                self.openSettings()
            }
        case .networkSettings, .notificationSettings, .timeZoneSettings:
            let pane = switch action {
            case .networkSettings: "Network"
            case .notificationSettings: "Notifications"
            default: "DateAndTime"
            }
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/PreferencePanes/\(pane).prefPane"))
        }
    }

    /// Every press of the toolbar's refresh lands here; `NativePopoverManualRefresh` decides whether it starts a
    /// load, joins the running one, or queues one more after it.
    func refreshUsage() {
        let press = self.manualRefresh.press(
            load: { [weak self] in
                self?.manualLoadStartedAt = Date()
                await self?.actions.refresh()
            },
            enrich: { [weak self] startedAt in await self?.actions.enrich(startedAt) },
            completion: { [weak self] outcome in self?.finishManualRefresh(outcome) })
        CodexBarLog.logger("native-gauges").info(
            "Native popup refresh pressed",
            metadata: [
                "provider": self.provider.rawValue,
                "press": "\(press)",
                "providerBusy": self.store.refreshingProviders.contains(self.provider.instanceID) ? "1" : "0",
                "storeBusy": self.store.isRefreshing ? "1" : "0",
            ])
        guard press == .started else { return }
        self.reloadClaudeLocalArchive()
        self.orbitState.refreshIssue = nil
        self.orbitState.isRefreshing = true
    }

    private func finishManualRefresh(_ outcome: NativePopoverManualRefresh.Outcome) {
        // Show the published readings at once instead of after the usual coalescing delay.
        self.presentationRefreshTask?.cancel()
        self.presentationRefreshTask = nil
        self.observePresentation()
        self.orbitState.refreshIssue = switch outcome {
        case .finished: Self.refreshIssue(
                self.store.nativeOrbitAccounts(for: self.provider), requestedAt: self.manualLoadStartedAt)
        case .timedOut: NativeOrbitRefreshIssue(kind: .slow, detail: L("native_refresh_timed_out"))
        }
        self.orbitState.isRefreshing = false
    }

    /// A column measured this long before the toolbar's load started was not brought up to date by it.
    static let refreshFreshnessTolerance: TimeInterval = 60
    /// claude-swap measures an idle account at most every 10 minutes (plus 10 % jitter) and serves that reading in
    /// between; the press runs its list, so only a reading older than its schedule allows was left behind.
    static let claudeSwapFreshnessTolerance: TimeInterval = 12 * 60

    /// The columns' own failures, and the columns the toolbar's last load could not bring up to date, so the toolbar
    /// never reports a refresh that left a reading old as if it had succeeded. A failure outranks a stale column.
    static func refreshIssue(
        _ accounts: [NativeOrbitAccountPresentation],
        requestedAt: Date? = nil) -> NativeOrbitRefreshIssue?
    {
        var failed = false
        let messages = accounts.compactMap { account -> String? in
            let message: String
            if let status = account.statusText?.trimmingCharacters(in: .whitespacesAndNewlines), !status.isEmpty {
                failed = true
                message = status
            } else if let requestedAt, let updated = account.updatedAt,
                      updated < requestedAt.addingTimeInterval(-Self.freshnessTolerance(account))
            {
                message = Self.notRefreshedNotice(account, measuredAt: updated)
            } else {
                return nil
            }
            return accounts.count > 1 ? "\(account.label): \(message)" : message
        }
        guard !messages.isEmpty else { return nil }
        return NativeOrbitRefreshIssue(kind: failed ? .failed : .stale, detail: messages.joined(separator: "\n"))
    }

    private static func freshnessTolerance(_ account: NativeOrbitAccountPresentation) -> TimeInterval {
        // Provider-specific by design: claude-swap paces Anthropic's usage API itself; within its schedule a reading
        // is as fresh as its source allows.
        if case .claudeSwap = account.selection { return self.claudeSwapFreshnessTolerance }
        return self.refreshFreshnessTolerance
    }

    private static func notRefreshedNotice(_ account: NativeOrbitAccountPresentation, measuredAt: Date) -> String {
        let shown = L("Updated %@", NativeOrbitTooltip.moment(measuredAt, now: Date()))
        // Provider-specific by design: claude-swap paces Anthropic's usage API itself, so say why its row waited.
        if case .claudeSwap = account.selection { return shown + "\n" + L("native_refresh_claude_swap_paced") }
        return shown
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

    /// Combined pages share the prepared account model and the provider's existing action routes.
    func combinedSource() -> NativeCombinedAccountSource {
        .init(
            provider: self.provider,
            state: self.orbitState,
            activate: { [weak self] in self?.activateAccount(id: $0) },
            lightAction: { [weak self] id, action in self?.handleLight(action, accountID: id) },
            refresh: { [weak self] in self?.refreshUsage() },
            settings: { [weak self] in self?.openSettings() })
    }

    func beginCombinedPresentation() {
        self.isInCombinedPresentation = true
        self.cancelStartup()
        if self.presentationDirty { self.observePresentation() }
        self.orbitState.now = Date()
        self.reloadClaudeLocalArchive()
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

    func endCombinedPresentation() {
        self.isInCombinedPresentation = false
        self.presentationClockTask?.cancel()
        self.presentationClockTask = nil
        self.orbitState.inspectionDate = nil
    }

    func activateAccount(id: String) {
        self.cancelStartup()
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
        if notification.object is NSPopover, self.startupLaunch.reserve(self.startupOwner) {
            self.orbitState.armStartup(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        }
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
        if notification.object is NSPopover, self.startupLaunch.shown(self.startupOwner) {
            self.startStartup()
        }
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

    /// Commit the armed, fully laid-out face before starting its interpolation. Otherwise first-use layout
    /// and native glass setup spend the sweep's first frames preparing the view instead of showing it.
    private func startStartup() {
        self.startupTask?.cancel()
        self.startupTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            self.view.layoutSubtreeIfNeeded()
            self.view.window?.displayIfNeeded()
            CATransaction.flush()
            await Task.yield()
            guard !Task.isCancelled else { return }
            await self.orbitState.runStartup()
            guard !Task.isCancelled else { return }
            self.startupTask = nil
            if self.presentationDirty { self.observePresentation() }
        }
    }

    func popoverWillClose(_ notification: Notification) {
        self.cancelStartup()
    }

    private func cancelStartup() {
        self.startupTask?.cancel()
        self.startupTask = nil
        self.startupLaunch.cancel(self.startupOwner)
        self.orbitState.finishStartup()
        if self.presentationDirty { self.schedulePresentationRefresh() }
    }

    func popoverDidClose(_ notification: Notification) {
        self.cancelStartup()
        self.presentationClockTask?.cancel()
        self.presentationClockTask = nil
        self.claudeArchiveTask?.cancel()
        self.statusButton?.highlight(false)
        self.actions.didClose()
    }
}
