import Foundation

extension UsageStore {
    static func resolvedPlanHistoryStore(
        _ store: PlanUtilizationHistoryStore?,
        startup: StartupBehavior) -> PlanUtilizationHistoryStore
    {
        store ?? (startup.automaticallyStartsBackgroundWork
            ? .defaultAppSupport()
            : PlanUtilizationHistoryStore(directoryURL: nil))
    }

    func startPlanUtilizationHistoryLoad(gate: PlanUtilizationHistoryLoadGate?, enabled: Bool) {
        guard enabled || gate != nil else {
            self.planUtilizationHistoryLoaded = true
            return
        }
        let historyStore = self.planUtilizationHistoryStore
        self.planUtilizationHistoryLoadTask = Task { @MainActor [weak self] in
            // In-memory starts empty; mutation paths and sync menu accessors gate on
            // `planUtilizationHistoryLoaded` until the background decode publishes once.
            if let gate {
                let shouldLoad = await withTaskCancellationHandler {
                    await gate.wait()
                } onCancel: {
                    gate.cancel()
                }
                guard shouldLoad, !Task.isCancelled else { return }
            }
            // Each provider's history shows as soon as its own file is decoded; writes still wait for all of them
            // (`planUtilizationHistoryLoaded`), so nothing is recorded against a partial history.
            let loaded = await historyStore.loadAsync { [weak self] instanceID, buckets in
                await MainActor.run {
                    guard let self, !self.planUtilizationHistoryLoaded else { return }
                    self.planUtilizationHistory[instanceID] = buckets
                    self.planUtilizationHistoryLoadedProviders.insert(instanceID)
                }
            }
            guard !Task.isCancelled, let self, !self.planUtilizationHistoryLoaded else { return }
            self.planUtilizationHistory = loaded
            self.planUtilizationHistoryLoaded = true
            self.planUtilizationHistoryRevision &+= 1
            _ = self.restoreClaudeHistorySnapshotIfNeeded()
            self.scheduleNativeClaudeDesktopHistoryRecovery()
        }
    }
}
