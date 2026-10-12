import AppKit
import CodexBarCore
import Foundation
import Observation

enum NativeAccountAutoSwitchPolicy {
    struct Exhaustion: Equatable {
        let accountID: String
        let slot: Int
        let reset: Date

        func matches(_ other: Self) -> Bool {
            self.accountID == other.accountID && self.slot == other.slot &&
                abs(self.reset.timeIntervalSince(other.reset)) <= 120
        }
    }

    struct Decision {
        let exhaustion: Exhaustion
        let targetID: String
    }

    static func decision(
        accounts: [NativeOrbitAccountPresentation],
        attempted: [Exhaustion],
        now: Date,
        cooldownUntil: Date? = nil) -> Decision?
    {
        guard cooldownUntil.map({ $0 <= now }) ?? true,
              Set(accounts.map(\.id)).count == accounts.count else { return nil }
        let active = accounts.filter(\.isActive)
        guard active.count == 1, let current = active.first,
              Self.isFresh(current, now: now) else { return nil }
        let blocking = current.autoSwitchWindows.enumerated().filter {
            $0.element?.isSyntheticPlaceholder == false
        }
        guard !blocking.isEmpty,
              blocking
                  .allSatisfy({
                      $0.element?.usedPercent
                          .isFinite == true && ($0.element?.usedPercent ?? -1) >= 0 }),
                  let exhausted = blocking.first(where: { ($0.element?.usedPercent ?? 0) >= 100 }),
                  let reset = exhausted.element?.resetsAt, reset > now else { return nil }
        let event = Exhaustion(accountID: current.id, slot: exhausted.offset, reset: reset)
        guard !attempted.contains(where: { $0.matches(event) }) else { return nil }
        let candidates = accounts.filter { account in
            guard !account.isActive, account.canActivate, account.autoSwitchEligible,
                  Self.isFresh(account, now: now),
                  blocking.allSatisfy({ slot, _ in
                      account.autoSwitchWindows.indices.contains(slot) &&
                          Self.hasHeadroom(account.autoSwitchWindows[slot], now: now)
                  }) else { return false }
            return account.autoSwitchWindows.compactMap(\.self).allSatisfy {
                $0.isSyntheticPlaceholder || Self.hasHeadroom($0, now: now)
            }
        }.sorted { left, right in
            let a = left.autoSwitchWindows.compactMap { $0?.usedPercent }.max() ?? 100
            let b = right.autoSwitchWindows.compactMap { $0?.usedPercent }.max() ?? 100
            return a == b ? left.id < right.id : a < b
        }
        guard let target = candidates.first else { return nil }
        return Decision(exhaustion: event, targetID: target.id)
    }

    private static func isFresh(_ account: NativeOrbitAccountPresentation, now: Date) -> Bool {
        guard account.gauge.health == .live, let updated = account.updatedAt else { return false }
        return (-30...300).contains(now.timeIntervalSince(updated))
    }

    private static func hasHeadroom(_ window: RateWindow?, now: Date) -> Bool {
        guard let window, !window.isSyntheticPlaceholder, window.usedPercent.isFinite,
              (0..<90).contains(window.usedPercent) else { return false }
        return window.resetsAt.map { $0 > now } ?? true
    }
}

/// One retained coordinator per provider. Monitoring continues while its popup is closed.
@MainActor
@Observable
final class NativeAccountSwitchController {
    private(set) var automatic: Bool
    private(set) var inFlightID: String?
    private(set) var error: String?
    private(set) var canAutomate = false
    let provider: UsageProvider
    private let store: UsageStore
    private let defaults: UserDefaults
    private let activateLogin: (NativeOrbitAccountSelection) async -> NativeAccountActivationResult
    private let refresh: () async -> Void
    private let allowed: () -> Bool
    private let accountsOverride: (() -> [NativeOrbitAccountPresentation])?
    private let notify: (_ title: String, _ body: String) -> Void
    private let workspaceCenter: NotificationCenter
    private var attempted: [NativeAccountAutoSwitchPolicy.Exhaustion] = []
    private var notifiedDeferrals: [NativeAccountAutoSwitchPolicy.Exhaustion] = []
    private var cooldownUntil: Date?
    private var desktopQuitObserver: (any NSObjectProtocol)?
    private var task: Task<Void, Never>?
    private var stopped = false
    private var transactionStarted = false

    init(
        provider: UsageProvider,
        store: UsageStore,
        defaults: UserDefaults,
        activate: @escaping (NativeOrbitAccountSelection) async -> NativeAccountActivationResult,
        refresh: @escaping () async -> Void,
        allowed: @escaping () -> Bool,
        accounts: (() -> [NativeOrbitAccountPresentation])? = nil,
        notify: @escaping (_ title: String, _ body: String) -> Void = { title, body in
            AppNotifications.shared.post(idPrefix: "native-auto-switch", title: title, body: body)
        },
        workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter)
    {
        self.provider = provider
        self.store = store
        self.defaults = defaults
        self.activateLogin = activate
        self.refresh = refresh
        self.allowed = allowed
        self.accountsOverride = accounts
        self.notify = notify
        self.workspaceCenter = workspaceCenter
        self.automatic = defaults.bool(forKey: "nativeAutoSwitch.\(provider.rawValue)")
        self.observe()
    }

    isolated deinit {
        self.task?.cancel()
        self.stopWatchingDesktop()
    }

    func stop() {
        self.stopped = true
        self.stopWatchingDesktop()
        // Let a credential transaction finish atomically; only cancel pending preflight work.
        if !self.transactionStarted { self.task?.cancel() }
    }

    func setAutomatic(_ enabled: Bool) {
        guard !self.stopped else { return }
        self.automatic = enabled
        self.defaults.set(enabled, forKey: "nativeAutoSwitch.\(self.provider.rawValue)")
        self.error = nil
    }

    func activate(_ account: NativeOrbitAccountPresentation) {
        guard !self.stopped, self.task == nil, account.canActivate, self.allowed() else { return }
        self.cooldownUntil = Date().addingTimeInterval(600)
        self.inFlightID = account.id
        self.error = nil
        self.task = Task { [weak self] in
            guard let self else { return }
            guard !self.stopped, !Task.isCancelled, self.allowed() else {
                self.finish(nil)
                return
            }
            self.transactionStarted = true
            // Only this explicit action may ask the desktop app to quit for the switch.
            let result = await NativeCodexDesktopHandoff.$quitPolicy.withValue(.askToQuit) {
                await self.activateLogin(account.selection)
            }
            self.finish(result)
        }
    }

    private func currentAccounts() -> [NativeOrbitAccountPresentation] {
        self.accountsOverride?() ?? self.store.nativeOrbitAccounts(for: self.provider)
    }

    private func observe() {
        guard !self.stopped else { return }
        let input = withObservationTracking {
            (self.currentAccounts(), self.automatic, self.allowed())
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observe() }
        }
        self.evaluate(accounts: input.0, automatic: input.1, allowed: input.2)
    }

    private func evaluate(accounts: [NativeOrbitAccountPresentation], automatic: Bool, allowed: Bool) {
        // Provider-specific by design: Unattended switching requires Codex's stable account identity.
        // ClaudeSwap currently exposes reusable slots, so it supports manual activation only.
        self.canAutomate = accounts.count > 1 && self.provider == .codex &&
            accounts.contains(where: { $0.canActivate && $0.autoSwitchEligible })
        guard automatic, allowed, self.canAutomate, self.task == nil,
              let decision = NativeAccountAutoSwitchPolicy.decision(
                  accounts: accounts,
                  attempted: self.attempted,
                  now: Date(),
                  cooldownUntil: self.cooldownUntil)
        else { return }
        self.inFlightID = decision.targetID
        self.error = nil
        self.task = Task { [weak self] in
            guard let self else { return }
            // A displayed cached reading never directly authorizes an automatic credential change.
            await self.refresh()
            let accounts = self.currentAccounts()
            guard !self.stopped, !Task.isCancelled, self.automatic, self.allowed(),
                  let confirmed = NativeAccountAutoSwitchPolicy.decision(
                      accounts: accounts,
                      attempted: self.attempted,
                      now: Date(),
                      cooldownUntil: self.cooldownUntil),
                  confirmed.exhaustion.matches(decision.exhaustion),
                  confirmed.targetID == decision.targetID,
                  let target = accounts.first(where: { $0.id == confirmed.targetID })
            else {
                self.finish(nil)
                return
            }
            self.attempted.append(confirmed.exhaustion)
            self.cooldownUntil = Date().addingTimeInterval(600)
            self.transactionStarted = true
            // Explicitly never: a task created during a manual switch would otherwise inherit its permission.
            let result = await NativeCodexDesktopHandoff.$quitPolicy.withValue(.never) {
                await self.activateLogin(target.selection)
            }
            if case let .deferred(reason) = result {
                self.postpone(confirmed.exhaustion, target: target, reason: reason)
            }
            self.finish(result)
        }
    }

    /// Auto Switch never quits the desktop app. A deferred switch stays pending, retries as soon as that app quits
    /// (or after the cooldown), and is announced once per exhaustion.
    private func postpone(
        _ exhaustion: NativeAccountAutoSwitchPolicy.Exhaustion,
        target: NativeOrbitAccountPresentation,
        reason: String)
    {
        self.attempted.removeAll { $0.matches(exhaustion) }
        if !self.notifiedDeferrals.contains(where: { $0.matches(exhaustion) }) {
            self.notifiedDeferrals.append(exhaustion)
            self.notify("Auto Switch is waiting", "\(reason) Next account: \(target.label).")
        }
        guard self.desktopQuitObserver == nil, !self.stopped else { return }
        self.desktopQuitObserver = self.workspaceCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main)
        { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == NativeCodexDesktopHandoff.bundleIdentifier else { return }
            MainActor.assumeIsolated { self?.desktopDidQuit() }
        }
    }

    func desktopDidQuit() {
        self.stopWatchingDesktop()
        guard !self.stopped else { return }
        self.cooldownUntil = nil
        // Re-evaluate without registering a second observation of the same inputs.
        self.evaluate(accounts: self.currentAccounts(), automatic: self.automatic, allowed: self.allowed())
    }

    private func stopWatchingDesktop() {
        if let observer = self.desktopQuitObserver { self.workspaceCenter.removeObserver(observer) }
        self.desktopQuitObserver = nil
    }

    private func finish(_ result: NativeAccountActivationResult?) {
        self.transactionStarted = false
        if case let .failed(message) = result { self.error = message }
        if case let .unavailable(message) = result { self.error = message }
        if case let .deferred(message) = result { self.error = message }
        self.inFlightID = nil
        self.task = nil
    }
}
