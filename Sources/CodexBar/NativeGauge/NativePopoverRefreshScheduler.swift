import Foundation

@MainActor
final class NativePopoverRefreshScheduler {
    private var task: Task<Void, Never>?
    private let delay: Duration

    init(delay: Duration = .seconds(1.2)) { self.delay = delay }

    func schedule(
        enabled: Bool,
        isCurrent: @escaping @MainActor () -> Bool,
        refresh: @escaping @MainActor () async -> Void)
    {
        self.cancel()
        guard enabled else { return }
        self.task = Task { @MainActor [delay] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard !Task.isCancelled, isCurrent() else { return }
            await refresh()
        }
    }

    func cancel() {
        self.task?.cancel()
        self.task = nil
    }
}

/// One explicit refresh from the popup's toolbar. It loads what the columns show, then hands the slower
/// enrichment to the background so the spinner reflects only that load. Every press counts and none is ever
/// dropped: a press during a load joins it, and unless it arrives within `joinWindow` of that load's start (the same
/// click, or a double click), it queues exactly one more load to run once the current one finishes. Any number of
/// presses therefore ends on a reading requested after the last of them, with at most one load waiting. A load that
/// outlives `timeout` stops the spinner and reports itself; it still publishes when it completes.
@MainActor
final class NativePopoverManualRefresh {
    enum Outcome: Equatable {
        case finished
        case timedOut
    }

    /// What one press did. There is no "ignored".
    enum Press: Equatable {
        /// Started a load and its spinner.
        case started
        /// Joined the load its own click started a moment ago.
        case joined
        /// Joined the running load; one more load follows it before the spinner stops.
        case queued
    }

    private let timeout: Duration
    private let joinWindow: Duration
    private var generation = 0
    private var currentLoadStartedAt: ContinuousClock.Instant?
    private var followUpRequested = false
    private var loadTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var enrichmentTask: Task<Void, Never>?

    init(timeout: Duration = .seconds(30), joinWindow: Duration = .seconds(1)) {
        self.timeout = timeout
        self.joinWindow = joinWindow
    }

    private(set) var isLoading = false
    /// Every load presses have run, follow-ups included.
    private(set) var loadCount = 0

    var isEnriching: Bool {
        self.enrichmentTask != nil
    }

    var hasQueuedLoad: Bool {
        self.followUpRequested
    }

    @discardableResult
    func press(
        load: @escaping @MainActor () async -> Void,
        enrich: @escaping @MainActor (_ loadStartedAt: Date) async -> Void,
        completion: @escaping @MainActor (Outcome) -> Void) -> Press
    {
        if self.isLoading {
            if let started = self.currentLoadStartedAt, started.duration(to: .now) < self.joinWindow {
                return .joined
            }
            self.followUpRequested = true
            return .queued
        }
        self.generation += 1
        let generation = self.generation
        self.isLoading = true
        self.followUpRequested = false
        self.loadTask = Task { @MainActor [weak self] in
            var loadStartedAt = Date()
            // A press during a load queued one more: run it before the spinner stops, so the columns end on a
            // reading requested after that press. Presses during the follow-up queue the next one the same way.
            while let self, self.generation == generation, self.isLoading {
                self.followUpRequested = false
                self.currentLoadStartedAt = .now
                self.loadCount += 1
                self.armTimeout(generation: generation, completion: completion)
                loadStartedAt = Date()
                await load()
                guard !Task.isCancelled, self.followUpRequested else { break }
            }
            guard let self else { return }
            self.finish(generation: generation, outcome: .finished, completion: completion)
            // One enrichment at a time: an enrichment already in flight covers this load as well.
            guard self.enrichmentTask == nil, !Task.isCancelled else { return }
            self.enrichmentTask = Task { @MainActor [weak self] in
                await enrich(loadStartedAt)
                self?.enrichmentTask = nil
            }
        }
        return .started
    }

    func cancel() {
        self.generation += 1
        self.isLoading = false
        self.followUpRequested = false
        self.currentLoadStartedAt = nil
        self.loadTask?.cancel()
        self.loadTask = nil
        self.timeoutTask?.cancel()
        self.timeoutTask = nil
        self.enrichmentTask?.cancel()
        self.enrichmentTask = nil
    }

    /// Each load gets the full timeout, so a queued follow-up never inherits an almost spent one.
    private func armTimeout(generation: Int, completion: @escaping @MainActor (Outcome) -> Void) {
        self.timeoutTask?.cancel()
        self.timeoutTask = Task { @MainActor [weak self, timeout] in
            do { try await Task.sleep(for: timeout) } catch { return }
            self?.finish(generation: generation, outcome: .timedOut, completion: completion)
        }
    }

    private func finish(
        generation: Int,
        outcome: Outcome,
        completion: @MainActor (Outcome) -> Void)
    {
        guard generation == self.generation, self.isLoading else { return }
        self.isLoading = false
        self.followUpRequested = false
        self.currentLoadStartedAt = nil
        self.timeoutTask?.cancel()
        self.timeoutTask = nil
        completion(outcome)
    }
}
