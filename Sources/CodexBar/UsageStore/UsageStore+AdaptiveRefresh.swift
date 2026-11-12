import CodexBarCore
import CoreGraphics
import Foundation

/// Wiring around `AdaptiveRefreshPolicy` for `UsageStore.startTimer()`: gathering live signals,
/// logging the resulting decision, and applying the DEBUG-only sleep-duration override used by
/// tests. Split out of UsageStore.swift to keep that file's class body under the lint line limit.
extension UsageStore {
    nonisolated static func effectiveAutomaticRefreshInterval(
        _ requested: TimeInterval?,
        lowPowerModeEnabled: Bool) -> TimeInterval?
    {
        BackgroundWorkPowerPolicy.automaticInterval(
            requested,
            lowPowerModeEnabled: lowPowerModeEnabled)
    }

    func effectiveTimerSleepDuration(_ computed: Duration) -> Duration {
        #if DEBUG
        self.refreshTimerSleepOverrideForTesting ?? computed
        #else
        computed
        #endif
    }

    /// Pure wiring helper: builds the `AdaptiveRefreshPolicy.Input` from explicit values and
    /// returns the resulting decision. `startTimer()` supplies live `ProcessInfo` state and
    /// `lastMenuOpenAt` at call time; this stays a plain, testable function of its arguments.
    nonisolated static func adaptiveRefreshDecision(
        now: Date,
        lastMenuOpenAt: Date?,
        lastCodingActivityAt: Date? = nil,
        lastUserActivityAt: Date? = nil,
        usagePace: Double? = nil,
        lowPowerModeEnabled: Bool,
        thermalState: ProcessInfo.ThermalState,
        policy: AdaptiveRefreshPolicy = AdaptiveRefreshPolicy()) -> AdaptiveRefreshPolicy.Decision
    {
        policy.nextDelay(for: AdaptiveRefreshPolicy.Input(
            now: now,
            lastMenuOpenAt: lastMenuOpenAt,
            lastCodingActivityAt: lastCodingActivityAt,
            lowPowerModeEnabled: lowPowerModeEnabled,
            thermalState: thermalState,
            lastUserActivityAt: lastUserActivityAt,
            usagePace: usagePace))
    }

    /// Feeds the readings now in the store to the pace tracker and returns the fastest pace among the quotas in
    /// use. Every service's current reading counts; an account switched away from stops counting.
    func currentUsagePace(now: Date) -> Double? {
        var keys = Set<String>()
        for (instance, snapshot) in self.snapshots {
            let account = snapshot.identity?.accountEmail ?? ""
            var lanes: [(String, RateWindow?)] = [
                ("primary", snapshot.primary),
                ("secondary", snapshot.secondary),
                ("tertiary", snapshot.tertiary),
            ]
            lanes += (snapshot.extraRateWindows ?? []).filter(\.usageKnown).map { ($0.id, $0.window) }
            for (id, candidate) in lanes {
                guard let window = candidate?.measured, let minutes = window.windowMinutes, minutes > 0
                else { continue }
                let key = "\(instance.rawValue)|\(account)|\(id)"
                keys.insert(key)
                self.usageVelocity.note(
                    key: key,
                    usedPercent: window.usedPercent,
                    windowSeconds: TimeInterval(minutes) * 60,
                    at: snapshot.updatedAt)
            }
        }
        self.usageVelocity.retain(keys: keys)
        return self.usageVelocity.fastestPace(now: now)
    }

    /// When the person last touched the keyboard or pointer, from the window server's idle clock. It needs no
    /// permission and identifies nothing about what they did. Tests get nil so the decision table they assert
    /// never depends on whoever is using the build machine.
    static func lastUserActivityDate(now: Date = Date()) -> Date? {
        guard !SettingsStore.isRunningTests, let anyInput = CGEventType(rawValue: ~0) else { return nil }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        guard idle.isFinite, idle >= 0 else { return nil }
        return now.addingTimeInterval(-idle)
    }

    /// The live decision for `store` at `now`, with the delay the power policy allows.
    private static func liveAdaptiveDecision(
        for store: UsageStore,
        now: Date) -> (decision: AdaptiveRefreshPolicy.Decision, effectiveDelay: TimeInterval)
    {
        let decision = Self.adaptiveRefreshDecision(
            now: now,
            lastMenuOpenAt: store.lastMenuOpenAt,
            lastCodingActivityAt: store.settings.adaptiveActivityScanningEnabled
                ? store.lastCodingActivityAt
                : nil,
            lastUserActivityAt: Self.lastUserActivityDate(now: now),
            usagePace: store.currentUsagePace(now: now),
            lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermalState: ProcessInfo.processInfo.thermalState)
        let requestedDelay = TimeInterval(decision.delay.components.seconds)
        let effectiveDelay = Self.effectiveAutomaticRefreshInterval(
            requestedDelay,
            lowPowerModeEnabled: store.settings.backgroundWorkLowPowerModeEnabled) ?? requestedDelay
        return (decision, effectiveDelay)
    }

    /// The adaptive timer never sleeps longer than this in one stretch. A wait decided while idle (up to half an
    /// hour) is re-read at this pace, so returning to the Mac, waking it, or leaving Low Power Mode shortens the
    /// wait already under way instead of taking effect one long sleep later.
    nonisolated static let adaptiveTimerSlice: Duration = .seconds(60)

    /// What is left of the wait that began at `startedAt`, under the decision the live signals give now. Returns
    /// nil once the store has deallocated, ending the loop.
    static func remainingAdaptiveTimerSleep(for store: UsageStore?, since startedAt: Date) async -> Duration? {
        guard let store else { return nil }
        let now = Date()
        let live = Self.liveAdaptiveDecision(for: store, now: now)
        let dueAt = Self.adaptiveTimerDueDate(
            scheduledAt: store.adaptiveRefreshScheduledAt,
            startedAt: startedAt,
            liveDelay: live.effectiveDelay)
        if store.adaptiveRefreshScheduledAt != dueAt {
            store.adaptiveRefreshScheduledAt = dueAt
            store.logAdaptiveRefreshDecision(live.decision)
        }
        return .seconds(max(0, dueAt.timeIntervalSince(now)))
    }

    /// The adaptive timer's loop. `store` is read anew for each brief decision and never held across a sleep, so
    /// the store can deallocate mid-wait, which ends the loop.
    nonisolated static func runAdaptiveRefreshTimer(for store: @escaping @Sendable () -> UsageStore?) async {
        let activity = Self.beginScheduledRefreshActivity()
        defer { ProcessInfo.processInfo.endActivity(activity) }
        while !Task.isCancelled {
            let startedAt = Date()
            guard var sleepDuration = await Self.nextAdaptiveTimerSleepDuration(for: store()) else { return }
            // A long wait is slept in slices and re-read against the live signals after each one, so it shortens
            // as soon as the person is back at the Mac.
            while sleepDuration > Self.adaptiveTimerSlice {
                let sliceStartedAt = ContinuousClock.now
                try? await Task.sleep(for: Self.adaptiveTimerSlice)
                Self.noteTimerOversleep(ContinuousClock.now - sliceStartedAt, requested: Self.adaptiveTimerSlice)
                guard !Task.isCancelled,
                      let remaining = await Self.remainingAdaptiveTimerSleep(for: store(), since: startedAt)
                else { return }
                sleepDuration = remaining
            }
            if sleepDuration > .zero {
                try? await Task.sleep(for: sleepDuration)
            }
            guard !Task.isCancelled else { return }
            await store()?.refresh(enrichmentMode: .automatic)
        }
    }

    /// Polling on schedule is this app's job while nobody is looking at it. macOS may nap a menu bar app once the
    /// person is away and defer its timers. Recording stopped every night for some eleven hours, on every provider
    /// at once, although the Mac was awake and agents went on using the accounts; it resumed when the person came
    /// back. Holding an activity exempts the timers from App Nap. It allows idle system sleep, so the Mac still
    /// sleeps when it wants to.
    nonisolated static func beginScheduledRefreshActivity() -> NSObjectProtocol {
        ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Scheduled usage refresh")
    }

    /// A wait that ran far past what was asked for means the process was held back (or the Mac slept); say so,
    /// since a hole in recorded history is otherwise unexplained afterwards.
    nonisolated static func noteTimerOversleep(_ slept: Duration, requested: Duration) {
        guard slept > requested + .seconds(300) else { return }
        CodexBarLog.logger(LogCategories.adaptiveRefresh).warning(
            "timer overslept: \(slept.components.seconds)s for a \(requested.components.seconds)s wait")
    }

    /// A wait under way only ever shortens. Re-reading the signals part-way must not push a refresh back: a menu
    /// opened five minutes ago has by then left the fast cadence it was scheduled on.
    nonisolated static func adaptiveTimerDueDate(
        scheduledAt: Date?,
        startedAt: Date,
        liveDelay: TimeInterval) -> Date
    {
        let live = startedAt.addingTimeInterval(liveDelay)
        return scheduledAt.map { min($0, live) } ?? live
    }

    nonisolated static func shouldAdvanceAdaptiveTimer(scheduledAt: Date?, candidate: Date) -> Bool {
        guard let scheduledAt else { return true }
        return candidate < scheduledAt
    }

    func noteCodingActivityObserved(at date: Date, now: Date = Date()) {
        guard self.settings.adaptiveActivityScanningEnabled else { return }
        self.retainCodingActivityIfNewer(date)
        self.advanceAdaptiveTimerIfEarlier(at: now)
    }

    func advanceAdaptiveTimerIfEarlier(at date: Date) {
        guard self.settings.refreshFrequency.usesAdaptivePolicy else { return }
        let effectiveDelay = Self.liveAdaptiveDecision(for: self, now: date).effectiveDelay
        let candidate = date.addingTimeInterval(effectiveDelay)
        guard Self.shouldAdvanceAdaptiveTimer(
            scheduledAt: self.adaptiveRefreshScheduledAt,
            candidate: candidate)
        else { return }
        self.restartAdaptiveTimerPreservingResetBoundary()
    }

    /// Advances a fixed timer from the last scheduled tick instead of the refresh completion time.
    /// Missed ticks are skipped so a refresh that runs longer than its interval does not create
    /// overlapping catch-up refreshes.
    nonisolated static func nextFixedTimerScheduledAt(
        previousScheduledAt: ContinuousClock.Instant,
        completedAt: ContinuousClock.Instant,
        interval: Duration) -> ContinuousClock.Instant
    {
        precondition(interval > .zero)
        var scheduledAt = previousScheduledAt + interval
        while scheduledAt <= completedAt {
            scheduledAt += interval
        }
        return scheduledAt
    }

    nonisolated static func runFixedRefreshTimer(
        interval: Duration,
        sleepOverride: Duration? = nil,
        now: @escaping @Sendable () async -> ContinuousClock.Instant = { ContinuousClock.now },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        },
        refresh: @escaping @Sendable () async -> Void) async
    {
        precondition(interval > .zero)
        let activity = Self.beginScheduledRefreshActivity()
        defer { ProcessInfo.processInfo.endActivity(activity) }
        var scheduledAt = await now() + interval
        while !Task.isCancelled {
            let current = await now()
            let computedSleep = current >= scheduledAt ? .zero : scheduledAt - current
            do {
                try await sleep(sleepOverride ?? computedSleep)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await refresh()
            scheduledAt = await self.nextFixedTimerScheduledAt(
                previousScheduledAt: scheduledAt,
                completedAt: now(),
                interval: interval)
        }
    }

    func logAdaptiveRefreshDecision(_ decision: AdaptiveRefreshPolicy.Decision) {
        // Reason and delay only; never provider/account/email/path/credential/response data.
        // No "adaptive refresh: " prefix — the adaptiveRefresh log category already identifies the source.
        self.adaptiveRefreshLogger.debug(
            "reason=\(decision.reason.rawValue) delay=\(decision.delay.components.seconds)s")
    }

    /// Computes this tick's adaptive sleep duration (and logs the decision) while briefly holding a
    /// strong reference to `store`; returns nil once the store has deallocated, ending the loop.
    /// Kept as a separate call so the strong reference doesn't extend into the caller's `Task.sleep`.
    static func nextAdaptiveTimerSleepDuration(for store: UsageStore?) async -> Duration? {
        guard let store else { return nil }
        let now = Date()
        let live = Self.liveAdaptiveDecision(for: store, now: now)
        let decision = live.decision
        let effectiveDelay = live.effectiveDelay
        #if DEBUG
        store.adaptiveRefreshComputedIntervalForTesting = effectiveDelay
        #endif
        store.adaptiveRefreshScheduledAt = now.addingTimeInterval(effectiveDelay)
        store.logAdaptiveRefreshDecision(decision)
        return store.effectiveTimerSleepDuration(.seconds(effectiveDelay))
    }

    /// The refresh interval scheduling *heuristics* (reset-boundary refresh, OpenAI web staleness,
    /// persistent-CLI-session idle windows) should use as "how often does a normal refresh happen".
    /// This is deliberately distinct from `RefreshFrequency.seconds`, which is nil for both `.manual`
    /// (no timer at all — heuristics correctly get nil here too) and `.adaptive` (no *fixed*
    /// interval, but ticks are still happening on a real, computable cadence). For `.adaptive`, this
    /// resolves to what `AdaptiveRefreshPolicy` would decide right now from live signals, so those
    /// heuristics stay active and roughly proportionate instead of silently behaving like manual.
    func normalRefreshIntervalForHeuristics() -> TimeInterval? {
        let requested: TimeInterval? = switch self.settings.refreshFrequency {
        case .manual:
            nil
        case .adaptive, .adaptiveAgentAware:
            TimeInterval(Self.liveAdaptiveDecision(for: self, now: Date()).decision.delay.components.seconds)
        default:
            self.settings.refreshFrequency.seconds
        }
        return Self.effectiveAutomaticRefreshInterval(
            requested,
            lowPowerModeEnabled: self.settings.backgroundWorkLowPowerModeEnabled)
    }
}
