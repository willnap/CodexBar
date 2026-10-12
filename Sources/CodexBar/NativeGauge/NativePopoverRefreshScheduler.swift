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
/// enrichment to the background so the spinner reflects only that load. A load that outlives `timeout` stops the
/// spinner and reports itself; it still publishes when it completes.
@MainActor
final class NativePopoverManualRefresh {
    enum Outcome: Equatable {
        case finished
        case timedOut
    }

    private let timeout: Duration
    private var generation = 0
    private var loadTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var enrichmentTask: Task<Void, Never>?

    init(timeout: Duration = .seconds(30)) {
        self.timeout = timeout
    }

    private(set) var isLoading = false

    var isEnriching: Bool {
        self.enrichmentTask != nil
    }

    /// Ignored while a load is running, so repeated clicks never queue duplicate fetches.
    @discardableResult
    func start(
        load: @escaping @MainActor () async -> Void,
        enrich: @escaping @MainActor (_ loadStartedAt: Date) async -> Void,
        completion: @escaping @MainActor (Outcome) -> Void) -> Bool
    {
        guard !self.isLoading else { return false }
        self.generation += 1
        let generation = self.generation
        let startedAt = Date()
        self.isLoading = true
        self.loadTask = Task { @MainActor [weak self] in
            await load()
            guard let self else { return }
            self.finish(generation: generation, outcome: .finished, completion: completion)
            // One enrichment at a time: an enrichment already in flight covers this load as well.
            guard self.enrichmentTask == nil, !Task.isCancelled else { return }
            self.enrichmentTask = Task { @MainActor [weak self] in
                await enrich(startedAt)
                self?.enrichmentTask = nil
            }
        }
        self.timeoutTask = Task { @MainActor [weak self, timeout] in
            do { try await Task.sleep(for: timeout) } catch { return }
            self?.finish(generation: generation, outcome: .timedOut, completion: completion)
        }
        return true
    }

    func cancel() {
        self.generation += 1
        self.isLoading = false
        self.loadTask?.cancel()
        self.loadTask = nil
        self.timeoutTask?.cancel()
        self.timeoutTask = nil
        self.enrichmentTask?.cancel()
        self.enrichmentTask = nil
    }

    private func finish(
        generation: Int,
        outcome: Outcome,
        completion: @MainActor (Outcome) -> Void)
    {
        guard generation == self.generation, self.isLoading else { return }
        self.isLoading = false
        self.timeoutTask?.cancel()
        self.timeoutTask = nil
        completion(outcome)
    }
}
