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
        var availableUpdate: () -> NativeOrbitWarningLight? = { nil }
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
    private var claudeArchivePoints: [NativeClaudeLocalArchivePoint]?
    private var claudeFileArchiveHistory: [PlanUtilizationSeriesHistory] = []
    /// Store changes arrive continuously from background scans. A closed popup coalesces them so clicks never
    /// wait behind presentation rebuilds; an open popup follows them promptly.
    private var isInCombinedPresentation = false
    private var presentationDirty = false
    private var lastPresentationAppliedAt: ContinuousClock.Instant?
    private var presentationRefreshTask: Task<Void, Never>?
    private let startupOwner = UUID()
    private let startupLaunch: NativeOrbitStartupLaunch
    private var startupTask: Task<Void, Never>?
    private var startupSelection = NativeOrbitStartupSelection()
    private var switchingCheckedAt: Date?
    private var hasPreparedPresentation = false

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
        self.preparePresentationIfNeeded()
        self.view = NSHostingView(rootView: NativeOrbitPopupView(
            state: self.orbitState,
            activate: { [weak self] id in self?.activateAccount(id: id) },
            signIn: self.canSignIn ? self.actions.signIn : nil,
            refresh: { [weak self] in self?.refreshUsage() },
            settings: { [weak self] in self?.openSettings() },
            lightAction: { [weak self] accountID, action in self?.handleLight(action, accountID: accountID) }))
        self.view.frame = NSRect(origin: .zero, size: self.preferredContentSize)
    }

    func prepare() {
        // The combined popup consumes this state directly. Constructing the standalone host here duplicates
        // every account chart at launch, even when that service's own popup is never shown.
        self.preparePresentationIfNeeded()
        self.reloadClaudeLocalArchive()
        if self.isViewLoaded { self.view.layoutSubtreeIfNeeded() }
        self.orbitState.prepareStartupArtwork(
            screen: self.statusButton?.window?.screen,
            appearance: self.statusButton?.effectiveAppearance ?? NSApp.effectiveAppearance)
    }

    private func preparePresentationIfNeeded() {
        guard !self.hasPreparedPresentation else { return }
        self.hasPreparedPresentation = true
        self.store.prepareNativeAccountInventory(for: self.provider)
        if !SettingsStore.isRunningTests { NativePopupInteraction.startMonitoring() }
        self.observePresentation()
        self.reloadClaudeLocalArchive()
    }

    /// While the combined popup's pages are being scrolled, changes wait and land once they settle: rebuilding the
    /// columns under the pointer recomputed every chart mid-gesture.
    var holdsPresentation = false {
        didSet {
            guard self.holdsPresentation != oldValue else { return }
            if self.holdsPresentation {
                self.presentationRefreshTask?.cancel()
                self.presentationRefreshTask = nil
            } else if self.presentationDirty {
                self.schedulePresentationRefresh()
            }
        }
    }

    /// How far the charts' clock may trail the wall clock while no reading changes.
    static let clockStep: TimeInterval = 20

    /// The archive lanes are a union of thousands of readings: built again only when what they are built from
    /// changes, and otherwise returned in the same storage so nothing downstream sees a change.
    struct ArchiveMemo {
        struct Input: Equatable {
            let files: [PlanUtilizationSeriesHistory]
            let buckets: PlanUtilizationHistoryBuckets?
            let excluded: Set<String>
            let provider: UsageProvider
        }

        private var input: Input?
        private var output: [PlanUtilizationSeriesHistory] = []

        mutating func value(
            _ input: Input, build: (Input) -> [PlanUtilizationSeriesHistory]) -> [PlanUtilizationSeriesHistory]
        {
            if self.input == input { return self.output }
            self.output = build(input)
            self.input = input
            return self.output
        }
    }

    private var claudeArchiveMemo = ArchiveMemo()
    private var kimiArchiveMemo = ArchiveMemo()

    /// The ignition's armed face, drawn while the popup is still closed so the first opening after launch shows
    /// it at once. Readings keep arriving underneath it; only a run on screen holds them back.
    private(set) var isPrearmed = false

    private var startupHoldsPresentation: Bool {
        self.orbitState.startup.isActive && !self.isPrearmed
    }

    private func observePresentation() {
        guard !self.startupHoldsPresentation, !self.holdsPresentation else {
            self.presentationDirty = true
            return
        }
        self.presentationDirty = false
        self.lastPresentationAppliedAt = .now
        withObservationTracking {
            self.refreshPresentation()
        } onChange: { [weak self] in
            DispatchQueue.main.async { [weak self] in self?.schedulePresentationRefresh() }
        }
        if self.popover?.isShown != true, !self.isInCombinedPresentation,
           self.hiddenPresentationApplied?() != true
        {
            self.renderWhileHidden()
        }
    }

    /// Called after a change was applied while no popup shows this service, so whoever keeps its pages can draw
    /// them now, off screen, instead of inside the next opening. True when a combined popup took it.
    var hiddenPresentationApplied: (() -> Bool)?

    /// Draws this service's own popup off screen, so its next opening shows what is already drawn. The view is
    /// built here only when asked (`loading`): while the combined popup shows this service, a second copy of every
    /// chart would be kept for nothing.
    func renderWhileHidden(loading: Bool = false) {
        guard self.popover?.isShown != true, !self.isInCombinedPresentation, loading || self.isViewLoaded
        else { return }
        self.loadViewIfNeeded()
        self.offscreenHost.render(
            self.view,
            size: self.preferredContentSize,
            screen: self.statusButton?.window?.screen,
            appearance: self.popover?.effectiveAppearance)
    }

    private let offscreenHost = NativePopupOffscreenHost()

    /// The next show rebuilds the presentation, as after a background change (used by the opt-in benchmark).
    func invalidatePresentation() {
        self.presentationDirty = true
    }

    /// How long a closed popover gathers changes before rebuilding its columns. A refresh publishes many changes over
    /// a minute or two, and each rebuild re-renders every column nobody sees; opening applies any pending change at
    /// once.
    var hiddenPresentationDelay: Duration = .seconds(30)

    /// How often a popup on screen takes a background change. A refresh publishes many over half a minute, and each
    /// one applied rebuilds every dial and chart; at the old 150 ms that kept the main thread busy for the whole
    /// sweep. A press of the toolbar's refresh still shows its result at once.
    var shownPresentationInterval: Duration = SettingsStore.isRunningTests ? .zero : .milliseconds(900)
    /// The longest a change waits for the pointer to come to rest, so a reading never stays old under a hand that
    /// keeps moving.
    var longestInteractionDeferral: Duration = .seconds(8)

    private func schedulePresentationRefresh() {
        self.presentationDirty = true
        guard self.presentationRefreshTask == nil, !self.holdsPresentation else { return }
        let isShown = self.popover?.isShown == true || self.isInCombinedPresentation
        // Every page of the combined popup lands on the same shared beat, so its overview and charts are
        // prepared once for all of them instead of once per service.
        let delay: Duration = if isShown {
            max(
                NativeStoreChangePacer.delayToNextBeat(minimum: .milliseconds(150)),
                self.lastPresentationAppliedAt.map { self.shownPresentationInterval - $0.duration(to: .now) } ?? .zero)
        } else {
            self.hiddenPresentationDelay
        }
        self.presentationRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            // Never rebuild the columns under a moving pointer: wait for the hand to rest, within a bound.
            if isShown, let deferral = self?.longestInteractionDeferral {
                let deadline = ContinuousClock.now + deferral
                while !Task.isCancelled, NativePopupInteraction.isActive, ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.presentationRefreshTask = nil
            if self.presentationDirty { self.observePresentation() }
        }
    }

    private func refreshPresentation() {
        // Account receipts and archive scans can publish several times during a sweep. Keep the prepared
        // chart and glass trees stable until it ends, then apply the latest complete presentation once.
        guard !self.startupHoldsPresentation, !self.holdsPresentation else {
            self.presentationDirty = true
            return
        }
        let update = self.actions.availableUpdate()
        let accounts = self.store.nativeOrbitAccounts(for: self.provider)
        let metadata = self.store.metadata(for: self.provider)
        let statusURL = metadata.statusPageURL ?? metadata.statusLinkURL
        let hasStatusPage = statusURL.flatMap(URL.init(string:)) != nil
        // Nothing observed is written unless it changed. A refresh publishes dozens of store changes that leave
        // this service's columns as they were, and each write here redrew every dial and chart of the service.
        let rows = accounts.map { account in
            var row = account
            if let update {
                row.warnings = NativeOrbitWarningLight.merged(row.warnings + [update])
            }
            row.warnings = row.warnings.map {
                $0.resolvingAction(
                    hasStatusPage: hasStatusPage,
                    hasDashboard: self.hasDashboard(),
                    canSignIn: self.canSignIn && self.actions.canLaunchLogin() && accounts.count == 1)
            }
            return row
        }
        var changed = false
        if self.orbitState.accounts != rows {
            self.orbitState.accounts = rows
            changed = true
        }
        let switched = self.startupSelection.receive(
            activeID: self.startupAccountOwner)
        // Provider-specific by design: Claude excludes only the exact owners already shown by ClaudeSwap rows.
        let claudeArchive = self.claudeArchiveMemo.value(.init(
            files: self.claudeFileArchiveHistory,
            buckets: self.store.nativeHistoryAvailable(.claude) ? self.store.planUtilizationHistory[.claude] : nil,
            excluded: Set(self.store.claudeSwapAccountSnapshots.compactMap(UsageStore.nativeOrbitClaudeHistoryKey)),
            provider: self.provider))
        {
            NativeOrbitClaudeLocalArchive.mergedHistories(
                fileHistories: $0.files, buckets: $0.buckets, excludingOwnerKeys: $0.excluded, provider: $0.provider)
        }
        if self.orbitState.claudeLocalArchiveHistory != claudeArchive {
            self.orbitState.claudeLocalArchiveHistory = claudeArchive
            changed = true
        }
        // Provider-specific by design: anonymous Codex log readings stay outside every named account column.
        let codexArchive = self.provider == .codex && self.store.nativeHistoryAvailable(.codex)
            ? (self.store.planUtilizationHistory[.codex]?.unscoped ?? []) : []
        if self.orbitState.codexLocalArchiveHistory != codexArchive {
            self.orbitState.codexLocalArchiveHistory = codexArchive
            changed = true
        }
        // Provider-specific by design: Kimi archives exclude only the accepted credential owner's bucket.
        let kimiArchive = self.provider == .kimi && self.store.nativeHistoryAvailable(.kimi)
            ? self.kimiArchiveMemo.value(.init(
                files: [],
                buckets: self.store.planUtilizationHistory[.kimi] ?? .init(),
                excluded: Set([self.store.snapshot(for: UsageProvider.kimi.instanceID)
                        .flatMap(UsageStore.nativeKimiHistoryAccountKey)].compactMap(\.self)),
                provider: self.provider))
            {
                NativeOrbitKimiLocalArchive.histories(
                    $0.buckets ?? .init(), excludingAcceptedOwnerKey: $0.excluded.first)
            } : []
        if self.orbitState.kimiLocalArchiveHistory != kimiArchive {
            self.orbitState.kimiLocalArchiveHistory = kimiArchive
            changed = true
        }
        // The clock moves with the readings, and otherwise in steps: every chart is drawn against it.
        let date = Date()
        if changed || date.timeIntervalSince(self.orbitState.now) >= Self.clockStep || date < self.orbitState.now {
            self.orbitState.now = date
        }
        // The spinner follows the toolbar's own load; background refreshes publish without one.
        if self.orbitState.isRefreshing != self.manualRefresh.isLoading {
            self.orbitState.isRefreshing = self.manualRefresh.isLoading
        }
        if self.orbitState.refreshIssue != nil, !self.manualRefresh.isLoading {
            let issue = Self.refreshIssue(self.orbitState.accounts, requestedAt: self.manualLoadStartedAt)
            if self.orbitState.refreshIssue != issue { self.orbitState.refreshIssue = issue }
        }
        self.updateSwitchingAvailability()
        let color = self.settings.accentColor(for: self.provider)
        let accent = Color(red: color.red, green: color.green, blue: color.blue)
        if self.orbitState.accent != accent { self.orbitState.accent = accent }
        let badgeKey = NativeOrbitBadgeResolver.identityKey(self.orbitState.accounts)
        if NativeOrbitBadgeResolver.shouldResolve(self.orbitState.accounts, previousKey: self.badgeIdentityKey) {
            self.badgeIdentityKey = badgeKey
            self.orbitState.badges = NativeOrbitBadgeResolver.initialBadges(self.orbitState.accounts)
            self.badgeTask = Task { [weak self] in
                guard let self else { return }
                await NativeOrbitBadgeResolver.resolve(self.orbitState)
            }
        }
        let historyReady = self.store.nativeHistoryAvailable(self.provider)
        if self.orbitState.startupHistoryReady != historyReady { self.orbitState.startupHistoryReady = historyReady }
        let statusReady = !self.settings.statusChecksEnabled
            || (metadata.statusPageURL == nil && metadata.statusWorkspaceProductID == nil)
            || self.store.statuses[self.provider.instanceID] != nil
            || self.store.nativeStatusFetchFailures.contains(self.provider.instanceID)
        if self.orbitState.startupStatusReady != statusReady { self.orbitState.startupStatusReady = statusReady }
        self.updateReadiness()
        let count = self.orbitState.layoutColumns
        let availableWidth = self.statusButton?.window?.screen?.visibleFrame.width ?? 1200
        let showsFooter = NativeAccountUsePresentation.showsFooter(
            accounts: self.orbitState.accounts, canSignIn: self.canSignIn)
        self.preferredContentSize = NSSize(
            width: min(CGFloat(count * 240 + (count - 1)), availableWidth - 40),
            height: NativeOrbitPopupView.contentHeight(showsFooter: showsFooter))
        self.popover?.contentSize = self.preferredContentSize
        // Closed: build what the next opening draws while the readings change, so the click only draws it.
        if self.popover?.isShown != true, !self.isInCombinedPresentation {
            if self.startupLaunch.hasShown {
                self.orbitState.prepareForOpening()
            } else {
                self.orbitState.prepareStartupArtwork(
                    screen: self.statusButton?.window?.screen,
                    appearance: self.statusButton?.effectiveAppearance ?? NSApp.effectiveAppearance)
            }
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
        let entries = accounts.compactMap { account -> NativeOrbitRefreshIssue.Entry? in
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
            return .init(account: accounts.count > 1 ? account.label : nil, message: message)
        }
        guard !entries.isEmpty else { return nil }
        return NativeOrbitRefreshIssue(kind: failed ? .failed : .stale, entries: entries)
    }

    private static func freshnessTolerance(_ account: NativeOrbitAccountPresentation) -> TimeInterval {
        // Provider-specific by design: claude-swap paces Anthropic's usage API itself; within its schedule a reading
        // is as fresh as its source allows.
        if case .claudeSwap = account.selection { return self.claudeSwapFreshnessTolerance }
        return self.refreshFreshnessTolerance
    }

    private static func notRefreshedNotice(_ account: NativeOrbitAccountPresentation, measuredAt: Date) -> String {
        // Provider-specific by design: claude-swap paces Anthropic's usage API itself, so say why its row waited.
        if case .claudeSwap = account.selection { return L("native_refresh_claude_swap_paced") }
        return L("Updated %@", NativeOrbitTooltip.moment(measuredAt, now: Date()))
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
            // Reloaded on every opening and each minute while open; an unchanged archive leaves the columns as
            // they are instead of rebuilding every Claude chart.
            guard points != self.claudeArchivePoints else { return }
            self.claudeArchivePoints = points
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
            settings: { [weak self] in self?.openSettings() },
            holdPresentation: { [weak self] in self?.holdsPresentation = $0 })
    }

    func beginCombinedPresentation() {
        self.isInCombinedPresentation = true
        // An armed face drawn ahead for this opening stays as it is.
        if !self.isPrearmed { self.cancelStartup() }
        self.holdPendingPresentationWhileOpening()
        // The clock moves once the popup is on screen (`combinedPresentationDidShow`). Moving it here re-rendered
        // every dial and chart inside `NSPopover.show`, before the window could appear.
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

    /// The combined popup's first opening after launch runs every service's ignition check together, as a
    /// service's own popup does: armed before it appears, run once it has.
    func armCombinedStartup() {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if self.isPrearmed, self.orbitState.startup == (reduceMotion ? .reduced : .armed) {
            // Already drawn armed while closed: arming again would redraw every dial inside `NSPopover.show`.
            self.orbitState.refreshArmedPointer()
            return
        }
        self.orbitState.armStartup(reduceMotion: reduceMotion)
        self.orbitState.prepareStartupArtwork(
            screen: self.statusButton?.window?.screen,
            appearance: self.statusButton?.effectiveAppearance ?? NSApp.effectiveAppearance)
    }

    /// Arms the ignition while the combined popup is closed and has not been shown since launch.
    func prearmCombinedStartup() {
        guard !self.isPrearmed, !self.isInCombinedPresentation, self.popover?.isShown != true else { return }
        self.armCombinedStartup()
        self.isPrearmed = true
    }

    /// Another popup ran the ignition first: return to the live face.
    func releasePrearm() {
        guard self.isPrearmed else { return }
        self.isPrearmed = false
        self.orbitState.finishStartup()
        if self.presentationDirty { self.schedulePresentationRefresh() }
    }

    func runCombinedStartup(in view: NSView) {
        self.isPrearmed = false
        self.startupTask?.cancel()
        self.startupTask = Task { @MainActor [weak self] in
            view.layoutSubtreeIfNeeded()
            view.window?.displayIfNeeded()
            CATransaction.flush()
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            await self.orbitState.runStartup()
            guard !Task.isCancelled else { return }
            self.startupTask = nil
            NativeOrbitWarningHDRRaster.retainLiveFramesOnly()
            if self.presentationDirty { self.schedulePresentationRefresh() }
        }
    }

    /// The combined popup has finished appearing; see `popoverDidShow`.
    func combinedPresentationDidShow() {
        self.orbitState.now = Date()
        self.applyPendingPresentationAfterShowing()
        self.reloadClaudeLocalArchive()
    }

    func endCombinedPresentation() {
        self.cancelStartup()
        self.isInCombinedPresentation = false
        self.holdsPresentation = false
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
        if notification.object is NSPopover, self.startupLaunch.reserve(self.startupOwner) {
            self.isPrearmed = false
            self.orbitState.armStartup(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        } else {
            self.releasePrearm()
        }
        self.holdPendingPresentationWhileOpening()
        self.popover = notification.object as? NSPopover
        self.popover?.contentSize = self.preferredContentSize
        self.statusButton?.highlight(true)
    }

    /// Appear at once with the prepared columns. A rebuild queued now would run before the popup's first frame is
    /// committed (a `Task.yield` does not let the run loop draw), so the window would wait for it.
    private func holdPendingPresentationWhileOpening() {
        guard self.presentationDirty else { return }
        self.presentationRefreshTask?.cancel()
        self.presentationRefreshTask = nil
    }

    /// A pending background change and the Claude archive are applied once the popup has finished appearing.
    private func applyPendingPresentationAfterShowing() {
        guard self.presentationDirty else { return }
        self.presentationRefreshTask?.cancel()
        self.presentationRefreshTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            self.presentationRefreshTask = nil
            if self.presentationDirty { self.observePresentation() }
        }
    }

    func popoverDidShow(_ notification: Notification) {
        // The clock moves once the popup is on screen. Moving it in `popoverWillShow` redrew every dial and
        // chart inside `NSPopover.show`, before the window could appear.
        self.orbitState.now = Date()
        if self.isViewLoaded { self.offscreenHost.releaseIfVacated(by: self.view) }
        if notification.object is NSPopover, self.startupLaunch.shown(self.startupOwner) {
            self.startStartup()
        }
        self.applyPendingPresentationAfterShowing()
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
            NativeOrbitWarningHDRRaster.retainLiveFramesOnly()
            if self.presentationDirty { self.observePresentation() }
        }
    }

    func popoverWillClose(_ notification: Notification) {
        self.cancelStartup()
    }

    private func cancelStartup() {
        self.isPrearmed = false
        self.startupTask?.cancel()
        self.startupTask = nil
        self.startupLaunch.cancel(self.startupOwner)
        self.orbitState.finishStartup()
        // An ignition that was shown and then interrupted is over too.
        if self.startupLaunch.hasShown { NativeOrbitWarningHDRRaster.retainLiveFramesOnly() }
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
