import CodexBarCore
import Foundation

struct NativeClaudeAmbientUsageConfiguration: Equatable, Sendable {
    let homePath: String
    let profileRootPath: String
    let bucketTimeZoneIdentifier: String
    let sourceMode: ClaudeUsageDataSource
    let selectedAccountID: UUID?
}

struct NativeClaudeAmbientUsagePublication: Sendable {
    let configuration: NativeClaudeAmbientUsageConfiguration
    let snapshot: CostUsageTokenSnapshot
}

extension UsageStore {
    /// One local transcript projection feeds the ambient Claude row and every claude-swap organization owner.
    /// It reads the incremental transcript cache shared with Claude cost reporting, so a refresh parses only
    /// appended bytes. Provider and adapter refreshes request it; they never cancel a projection in flight.
    func scheduleNativeClaudeLocalUsageRefresh() {
        guard !Task.isCancelled else { return }
        guard self.nativeClaudeAmbientUsageConfiguration() != nil || !self.nativeClaudeLocalUsageOwners().isEmpty
        else {
            self.nativeClaudeAmbientUsagePublication = nil
            return
        }
        #if DEBUG
        if let override = self._test_nativeLocalUsageRefreshScheduledOverride {
            // Provider-specific by design: this scheduler only refreshes Claude transcript usage.
            override(.claude)
            return
        }
        #endif
        guard !TestProcessSafety.isRunning else { return }
        guard self.nativeClaudeAmbientUsageTask == nil else {
            // Coalesce: the running projection publishes, then one more pass picks up the newest owners and bytes.
            self.claudeSwapTransientState.localUsageRerunRequested = true
            return
        }
        let token = UUID()
        self.nativeClaudeAmbientUsageTaskToken = token
        self.nativeClaudeAmbientUsageTask = Task(priority: .utility) { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshNativeClaudeLocalUsage()
            guard self.nativeClaudeAmbientUsageTaskToken == token else { return }
            self.nativeClaudeAmbientUsageTask = nil
            self.nativeClaudeAmbientUsageTaskToken = nil
            if self.claudeSwapTransientState.localUsageRerunRequested {
                self.claudeSwapTransientState.localUsageRerunRequested = false
                self.scheduleNativeClaudeLocalUsageRefresh()
            }
        }
    }

    func refreshNativeClaudeLocalUsage(
        fetcher: CostUsageFetcher? = nil,
        archiveRoot: URL? = nil,
        now: Date = Date()) async
    {
        let configuration = self.nativeClaudeAmbientUsageConfiguration()
        let owners = self.nativeClaudeLocalUsageOwners()
        guard configuration != nil || !owners.isEmpty else { return }
        let calendar = self.settings.costUsageBucketCalendar
        let timeZone = calendar.timeZone.identifier
        do {
            let result = try await self.claudeOrganizationUsageReader.read(
                organizationIDs: Array(Set(owners.values)),
                fetcher: fetcher ?? self.costUsageFetcher,
                now: now,
                historyDays: SpendDashboardSource.scanDays,
                calendar: calendar,
                archiveRoot: archiveRoot)
            guard !Task.isCancelled,
                  self.settings.costUsageBucketCalendar.timeZone.identifier == timeZone else { return }
            if let configuration, self.nativeClaudeAmbientUsageConfiguration() == configuration,
               let machine = result.machine
            {
                self.nativeClaudeAmbientUsagePublication = .init(configuration: configuration, snapshot: machine)
            }
            // Ownership is the only publication guard: a newer provider refresh generation describes the same
            // transcripts. Changed owners were already queued for another pass by the adapter refresh.
            if !owners.isEmpty, self.nativeClaudeLocalUsageOwners() == owners {
                self.claudeOrganizationUsagePublication = ClaudeOrganizationUsagePublication(
                    owners: owners,
                    bucketTimeZoneIdentifier: timeZone,
                    reports: result.organizations)
                self.claudeSwapRevision &+= 1
            }
        } catch {
            // Local transcript retention is optional and cannot replace an accepted provider measurement.
        }
    }

    /// Kept for the ambient-only call sites and tests; the projection always serves every current owner.
    func refreshNativeClaudeAmbientUsage(
        fetcher: CostUsageFetcher? = nil,
        now: Date = Date()) async
    {
        await self.refreshNativeClaudeLocalUsage(fetcher: fetcher, now: now)
    }

    func nativeClaudeLocalUsageOwners() -> [ProviderAccountIdentity: String] {
        guard self.shouldFetchClaudeSwapAccounts() else { return [:] }
        return ClaudeOrganizationUsagePublication.owners(for: self.claudeSwapAccountSnapshots)
    }

    func nativeOrbitClaudeAmbientUsage() -> NativeOrbitLocalUsage? {
        guard let configuration = self.nativeClaudeAmbientUsageConfiguration(),
              let publication = self.nativeClaudeAmbientUsagePublication,
              publication.configuration == configuration else { return nil }
        return NativeOrbitLocalUsage(
            snapshot: publication.snapshot,
            scope: .localMachine,
            bucketTimeZoneIdentifier: configuration.bucketTimeZoneIdentifier)
    }

    /// Owner digest of the ambient transcript report: Claude home, profile root, bucket zone and source mode.
    func nativeClaudeAmbientLastKnownOwner() -> String? {
        guard let configuration = self.nativeClaudeAmbientUsageConfiguration(),
              configuration.selectedAccountID == nil else { return nil }
        return NativeOrbitLastKnownUsageStore.ownerDigest([
            "claude-ambient", configuration.homePath, configuration.profileRootPath,
            configuration.bucketTimeZoneIdentifier, configuration.sourceMode.rawValue,
        ])
    }

    private func nativeClaudeAmbientUsageConfiguration() -> NativeClaudeAmbientUsageConfiguration? {
        guard self.settings.nativeDesignEnabled,
              // Provider-specific by design: local Claude transcripts require enablement without authentication.
              self.settings.isProviderEnabledCached(provider: .claude, metadataByProvider: self.providerMetadata),
              self.settings.effectiveSelectedTokenAccount(for: .claude) == nil else { return nil }
        return NativeClaudeAmbientUsageConfiguration(
            homePath: ClaudeConfigPaths.homeDirectory(environment: self.environmentBase).path,
            profileRootPath: ClaudeConfigPaths.configRoot(environment: self.environmentBase).path,
            bucketTimeZoneIdentifier: self.settings.costUsageBucketCalendar.timeZone.identifier,
            sourceMode: self.settings.claudeUsageDataSource,
            selectedAccountID: nil)
    }
}
