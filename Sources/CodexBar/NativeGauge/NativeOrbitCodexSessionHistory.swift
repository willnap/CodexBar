import CodexBarCore
import Foundation

private struct NativeCodexQuotaHistoryLane: Hashable, Sendable {
    let name: PlanUtilizationSeriesName
    let windowMinutes: Int
}

extension UsageStore {
    func scheduleNativeCodexSessionHistoryBackfill(
        projection: CodexVisibleAccountProjection,
        generation: UInt64? = nil)
    {
        // Provider-specific by design: only Codex session logs contain the anonymous quota events recovered here.
        guard self.settings.nativeDesignEnabled, self.isEnabled(.codex), !Task.isCancelled,
              self.isCurrentProviderRefreshGeneration(.codex, generation: generation) else { return }
        self.nativeCodexSessionHistoryBackfillTask?.cancel()
        let token = UUID()
        self.nativeCodexSessionHistoryBackfillToken = token
        self.nativeCodexSessionHistoryBackfillTask = Task(priority: .utility) { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.nativeCodexSessionHistoryBackfillToken == token {
                    self.nativeCodexSessionHistoryBackfillTask = nil
                    self.nativeCodexSessionHistoryBackfillToken = nil
                }
            }
            await self.backfillNativeCodexSessionHistory(projection: projection, generation: generation)
        }
    }

    func backfillNativeCodexSessionHistory(
        projection: CodexVisibleAccountProjection,
        generation: UInt64? = nil,
        now: Date = Date()) async
    {
        // Provider-specific by design: cancel this Codex archive job when its provider or refresh generation changes.
        guard self.settings.nativeDesignEnabled, self.isEnabled(.codex), !Task.isCancelled,
              self.isCurrentProviderRefreshGeneration(.codex, generation: generation) else { return }
        if !self.planUtilizationHistoryLoaded { _ = await self.planUtilizationHistoryLoadTask?.result }
        let roots = self.nativeCodexSessionHistoryRoots(projection: projection)
        var observations: [NativeCodexQuotaSessionObservation] = []
        repeat {
            observations = await self.nativeCodexSessionHistoryScanner.scan(homeRoots: roots, now: now)
            await self.publishNativeCodexSessionHistory(
                observations, projection: projection, generation: generation, now: now)
            // Provider-specific by design: stop draining Codex logs after a settings or generation change.
            guard self.settings.nativeDesignEnabled, self.isEnabled(.codex), !Task.isCancelled,
                  self.isCurrentProviderRefreshGeneration(.codex, generation: generation) else { return }
            await Task.yield()
        } while await self.nativeCodexSessionHistoryScanner.hasPendingWork
        // Every rollout is drained: the event windows now cover all scanned homes for attribution.
        await self.publishNativeCodexSessionWindowTimeline(observations, now: now)
    }

    private func publishNativeCodexSessionHistory(
        _ observations: [NativeCodexQuotaSessionObservation],
        projection: CodexVisibleAccountProjection,
        generation: UInt64?,
        now: Date) async
    {
        while !Task.isCancelled {
            // Provider-specific by design: the anonymous archive and exact repair affect Codex history only.
            guard self.settings.nativeDesignEnabled, self.isEnabled(.codex),
                  self.isCurrentProviderRefreshGeneration(.codex, generation: generation) else { return }
            let original = self.planUtilizationHistory[.codex] ?? PlanUtilizationHistoryBuckets()
            let protected = self.nativeCodexPublishedHistory(projection: projection)
            // Repairing re-sorts every recovered series. Off the main actor it no longer stalls the popup's
            // startup animation, which plays just after launch while this backfill drains.
            let repaired = await Task.detached(priority: .utility) {
                Self.nativeCodexRepairedHistory(original, observations: observations, protected: protected, now: now)
            }.value
            guard !Task.isCancelled else { return }
            // Provider-specific by design: an accepted Codex refresh may have changed history while repairing.
            guard self.settings.nativeDesignEnabled, self.isEnabled(.codex),
                  self.isCurrentProviderRefreshGeneration(.codex, generation: generation) else { return }
            if (self.planUtilizationHistory[.codex] ?? PlanUtilizationHistoryBuckets()) != original
                || self.nativeCodexPublishedHistory(projection: projection) != protected { continue }
            guard repaired != original else { return }
            if repaired.accounts != original.accounts {
                let directory = self.planUtilizationHistoryStore.directoryURL
                let backedUp = await Task.detached(priority: .utility) {
                    Self.backupNativeCodexHistory(original, directory: directory)
                }.value
                guard backedUp, !Task.isCancelled else { return }
                // Provider-specific by design: an accepted Codex refresh may have changed history during backup.
                guard self.settings.nativeDesignEnabled, self.isEnabled(.codex),
                      self.isCurrentProviderRefreshGeneration(.codex, generation: generation) else { return }
                // A newly published independent reading must remain protected: repair again from the start.
                if self.planUtilizationHistory[.codex] != original
                    || self.nativeCodexPublishedHistory(projection: projection) != protected { continue }
            }
            // Provider-specific by design: event owners are absent, so recovered Codex records stay unscoped.
            self.planUtilizationHistory[.codex] = repaired
            self.planUtilizationHistoryRevision &+= 1
            await self.planUtilizationPersistenceCoordinator.enqueue(self.planUtilizationHistory)
            return
        }
    }

    private func nativeCodexPublishedHistory(
        projection: CodexVisibleAccountProjection)
        -> [String: [NativeCodexQuotaHistoryLane: Set<PlanUtilizationHistoryEntry>]]
    {
        var protected: [String: [NativeCodexQuotaHistoryLane: Set<PlanUtilizationHistoryEntry>]] = [:]
        let grouped = Dictionary(grouping: self.codexAccountSnapshots, by: \.id)
        for records in grouped.values {
            guard records.count == 1, let record = records.first, record.error == nil,
                  let snapshot = record.snapshot,
                  let account = Self.currentCodexVisibleAccount(
                      matching: record.account,
                      projection: projection,
                      allowProviderAccountAuthFingerprintMismatch: false),
                  case let .providerAccount(id) = Self.codexScopedRefreshGuard(for: account).identity,
                  let key = CodexHistoryOwnership.canonicalKey(for: .providerAccount(id: id)) else { continue }
            // Provider-specific by design: independently accepted Codex readings retain their verified owner.
            if let measured = snapshot.accountEmail(for: .codex),
               CodexIdentityResolver.normalizeEmail(measured) != CodexIdentityResolver.normalizeEmail(account.email)
            { continue }
            for sample in Self.nativeOrbitQuotaSamples(provider: .codex, snapshot: snapshot) {
                let lane = NativeCodexQuotaHistoryLane(name: sample.name, windowMinutes: sample.windowMinutes)
                protected[key, default: [:]][lane, default: []].insert(sample.entry)
            }
        }
        return protected
    }

    private nonisolated static func nativeCodexRepairedHistory(
        _ original: PlanUtilizationHistoryBuckets,
        observations: [NativeCodexQuotaSessionObservation],
        protected: [String: [NativeCodexQuotaHistoryLane: Set<PlanUtilizationHistoryEntry>]],
        now: Date) -> PlanUtilizationHistoryBuckets
    {
        var buckets = original
        var archive: [NativeCodexQuotaHistoryLane: Set<PlanUtilizationHistoryEntry>] = [:]
        var imported: [String: [NativeCodexQuotaHistoryLane: Set<PlanUtilizationHistoryEntry>]] = [:]
        for observation in observations {
            // Provider-specific by design: parse Codex quota fields without assigning session creator ownership.
            for sample in Self.nativeOrbitQuotaSamples(provider: .codex, snapshot: observation.snapshot) {
                let lane = NativeCodexQuotaHistoryLane(name: sample.name, windowMinutes: sample.windowMinutes)
                archive[lane, default: []].insert(sample.entry)
                if let creator = observation.legacyCreatorAccountID,
                   let key = CodexHistoryOwnership.canonicalKey(for: .providerAccount(id: creator))
                {
                    imported[key, default: [:]][lane, default: []].insert(sample.entry)
                    // The previous creator importer clipped overage to 100. Undo only that proven old tuple.
                    if sample.entry.usedPercent > 100 {
                        imported[key, default: [:]][lane, default: []].insert(.init(
                            capturedAt: sample.entry.capturedAt, usedPercent: 100, resetsAt: sample.entry.resetsAt))
                    }
                }
            }
        }
        for (owner, lanes) in imported {
            guard let histories = buckets.accounts[owner] else { continue }
            let repaired = histories.compactMap { history -> PlanUtilizationSeriesHistory? in
                let lane = NativeCodexQuotaHistoryLane(name: history.name, windowMinutes: history.windowMinutes)
                guard history.name.isNativeQuotaObservation, let source = lanes[lane] else { return history }
                let entries = history.entries.filter {
                    !source.contains($0) || protected[owner]?[lane]?.contains($0) == true
                }
                return entries.isEmpty ? nil : PlanUtilizationSeriesHistory(
                    name: history.name, windowMinutes: history.windowMinutes, entries: entries)
            }
            if repaired != histories { buckets.setHistories(repaired, for: owner) }
        }
        var histories = buckets.unscoped
        for (lane, source) in archive {
            let index = histories.firstIndex { $0.name == lane.name && $0.windowMinutes == lane.windowMinutes }
            let existing = index.map { histories[$0].entries } ?? []
            let entries = Set(existing).union(source).filter {
                $0.capturedAt >= now.addingTimeInterval(-32 * 86400) && $0.capturedAt <= now
            }
            let history = PlanUtilizationSeriesHistory(
                name: lane.name, windowMinutes: lane.windowMinutes, entries: Array(entries))
            if let index { histories[index] = history } else { histories.append(history) }
        }
        buckets.setHistories(histories, for: nil)
        return buckets
    }

    private nonisolated static func backupNativeCodexHistory(
        _ original: PlanUtilizationHistoryBuckets, directory: URL?) -> Bool
    {
        guard let directory else { return false }
        let root = directory.appendingPathComponent("recovery-backups", isDirectory: true)
        do {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: root.path),
               attributes[.type] as? FileAttributeType != .typeDirectory { return false }
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let destination = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(
                at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let backup = PlanUtilizationHistoryStore(directoryURL: destination)
            // Provider-specific by design: preserve the complete pre-repair Codex document, including legacy series.
            guard backup.save([.codex: original]).isEmpty, backup.load()[.codex] == original else { return false }
            return true
        } catch {
            return false
        }
    }

    private func nativeCodexSessionHistoryRoots(projection: CodexVisibleAccountProjection) -> [URL] {
        var roots = [
            CodexHomeScope.ambientHomeURL(env: self.environmentBase),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
                ".codex",
                isDirectory: true),
        ]
        for account in projection.visibleAccounts {
            if case let .profileHome(path) = account.selectionSource,
               let path = CodexHomeScope.normalizedHomePath(path)
            {
                roots.append(URL(fileURLWithPath: path, isDirectory: true))
            }
        }
        let visibleStoredIDs = Set(projection.visibleAccounts.compactMap(\.storedAccountID))
        for stored in self.settings.cachedCodexAccountReconciliationSnapshot?.snapshot.storedAccounts ?? []
            where visibleStoredIDs.contains(stored.id)
        {
            if let path = CodexHomeScope.normalizedHomePath(stored.managedHomePath) {
                roots.append(URL(fileURLWithPath: path, isDirectory: true))
            }
        }
        // Existing native folder grants are already restored without UI; denied roots simply contribute no data.
        return Array(Set(roots.map(\.standardizedFileURL)))
    }
}
