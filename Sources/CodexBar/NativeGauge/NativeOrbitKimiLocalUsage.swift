import CodexBarCore
import Foundation

struct NativeKimiLocalUsageConfiguration: Equatable, Sendable {
    let provider: UsageProvider
    let sessionsRootPath: String
    let bucketTimeZoneIdentifier: String
    let sourceMode: ProviderSourceMode
    let region: KimiRegion
    let selectedAccountID: UUID?

    init(
        provider: UsageProvider,
        sessionsRootPath: String,
        bucketTimeZoneIdentifier: String,
        sourceMode: ProviderSourceMode,
        region: KimiRegion,
        selectedAccountID: UUID?)
    {
        self.provider = provider
        self.sessionsRootPath = URL(fileURLWithPath: sessionsRootPath).standardizedFileURL.path
        self.bucketTimeZoneIdentifier = CostUsageBucketTimeZone.timeZone(
            identifier: bucketTimeZoneIdentifier).identifier
        self.sourceMode = sourceMode
        self.region = region
        self.selectedAccountID = selectedAccountID
    }
}

struct NativeKimiLocalUsagePublication: Sendable {
    let configuration: NativeKimiLocalUsageConfiguration
    let snapshot: CostUsageTokenSnapshot
}

extension UsageStore {
    func scheduleNativeKimiLocalUsageRefresh(
        generation: UInt64? = nil)
    {
        // Local wire evidence refreshes independently of the quota fetch; rendering consumes the cached report.
        guard self.nativeKimiLocalUsageConfiguration() != nil,
              !Task.isCancelled,
              self.isCurrentProviderRefreshGeneration(
                  // Provider-specific by design: Kimi wire scanning follows its own refresh generation.
                  .kimi,
                  generation: generation)
        else { return }
        #if DEBUG
        if let override = self._test_nativeLocalUsageRefreshScheduledOverride {
            override(.kimi)
            return
        }
        #endif
        guard !TestProcessSafety.isRunning else { return }
        self.nativeKimiLocalUsageTask?.cancel()
        let token = UUID()
        self.nativeKimiLocalUsageTaskToken = token
        self.nativeKimiLocalUsageTask = Task(priority: .utility) { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.nativeKimiLocalUsageTaskToken == token {
                    self.nativeKimiLocalUsageTask = nil
                    self.nativeKimiLocalUsageTaskToken = nil
                }
            }
            // One-time and idempotent: once folded, no legacy per-token Kimi bucket remains to qualify.
            await self.foldLegacyNativeKimiHistoryIfNeeded()
            await self.refreshNativeKimiLocalUsage(
                generation: generation)
        }
    }

    func refreshNativeKimiLocalUsage(
        generation: UInt64? = nil,
        sessionsRoot: URL? = nil,
        now fixedNow: Date? = nil) async
    {
        // Tests must provide an explicit synthetic root;
        // never discover the user's session directory.
        guard !TestProcessSafety.isRunning || sessionsRoot != nil,
              let configuration = self.nativeKimiLocalUsageConfiguration(
                  sessionsRoot: sessionsRoot)
        else { return }
        repeat {
            guard !Task.isCancelled,
                  self.isCurrentProviderRefreshGeneration(
                      // Provider-specific by design: only a current Kimi refresh may read its local wire history.
                      .kimi,
                      generation: generation)
            else { return }
            // Each pass reports at its own clock, so records written during a long first scan are not hidden.
            let snapshot = await self.nativeKimiLocalUsageScanner.scan(
                sessionsRoot: URL(
                    fileURLWithPath: configuration.sessionsRootPath,
                    isDirectory: true),
                now: fixedNow ?? Date(),
                bucketTimeZoneIdentifier: configuration.bucketTimeZoneIdentifier)
            guard !Task.isCancelled,
                  self.isCurrentProviderRefreshGeneration(
                      .kimi,
                      generation: generation),
                  self.nativeKimiLocalUsageConfiguration(
                      sessionsRoot: sessionsRoot) == configuration,
                  let snapshot else { return }
            // Wire records contain no authenticated
            // principal. Keep the publication machine
            // scoped.
            self.nativeKimiLocalUsageReport = .init(
                configuration: configuration,
                snapshot: snapshot)
            await Task.yield()
        } while await self.nativeKimiLocalUsageScanner.hasPendingWork
    }

    func nativeOrbitKimiLocalUsage() -> NativeOrbitLocalUsage? {
        guard let configuration = self.nativeKimiLocalUsageConfiguration()
        else { return nil }
        return Self.nativeOrbitKimiLocalUsage(
            publication: self.nativeKimiLocalUsageReport,
            configuration: configuration)
    }

    func nativeOrbitAmbientLocalUsage(
        for provider: UsageProvider) -> NativeOrbitLocalUsage?
    {
        // Provider-specific by design: an ambient local
        // report is never forwarded to another provider or
        // saved row.
        switch provider {
        case .claude: self.nativeOrbitClaudeLocalUsage()
        case .kimi: self.nativeOrbitKimiLocalUsage()
        default: nil
        }
    }

    nonisolated static func nativeOrbitKimiLocalUsage(
        publication: NativeKimiLocalUsagePublication?,
        configuration: NativeKimiLocalUsageConfiguration) -> NativeOrbitLocalUsage?
    {
        guard configuration.provider == .kimi,
              configuration.selectedAccountID == nil,
              let publication,
              publication.configuration == configuration
        else { return nil }
        return NativeOrbitLocalUsage(
            snapshot: publication.snapshot,
            scope: .localMachine,
            bucketTimeZoneIdentifier: configuration.bucketTimeZoneIdentifier)
    }

    private func nativeKimiLocalUsageConfiguration(
        sessionsRoot: URL? = nil) -> NativeKimiLocalUsageConfiguration?
    {
        guard self.settings.nativeDesignEnabled,
              // Provider-specific by design: local Kimi wires require enablement without authentication.
              self.settings.isProviderEnabledCached(provider: .kimi, metadataByProvider: self.providerMetadata),
              self.settings.effectiveSelectedTokenAccount(
                  for: .kimi) == nil else { return nil }
        let home = self.environmentBase["HOME"].flatMap { path -> URL? in
            let path = path.trimmingCharacters(
                in: .whitespacesAndNewlines)
            return path.hasPrefix("/") ? URL(
                fileURLWithPath: path,
                isDirectory: true) : nil
        } ?? FileManager.default.homeDirectoryForCurrentUser
        return NativeKimiLocalUsageConfiguration(
            provider: .kimi,
            sessionsRootPath: sessionsRoot?.path ?? home.appendingPathComponent(
                ".kimi-code/sessions").path,
            bucketTimeZoneIdentifier: self.settings.costUsageBucketTimeZoneIdentifier,
            sourceMode: self.settings.kimiUsageDataSource,
            region: self.settings.kimiRegion,
            selectedAccountID: nil)
    }
}
