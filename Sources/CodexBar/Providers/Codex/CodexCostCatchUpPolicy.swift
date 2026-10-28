import CodexBarCore
import Foundation
import IOKit.ps

enum CodexCostCatchUpMode: String, Sendable {
    case automatic
    case accelerated

    func scanDurationPerRefresh(after activeDuration: TimeInterval? = nil) -> TimeInterval {
        switch self {
        case .automatic: max(0.001, CodexCostCatchUpPolicy.automaticBurstDuration - (activeDuration ?? 0))
        case .accelerated: 10
        }
    }
}

enum CodexCostCatchUpPowerSource: String, Sendable {
    case ac
    case battery
    case unknown

    static func current() -> Self {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        else {
            return .unknown
        }
        if source == kIOPSACPowerValue as String {
            return .ac
        }
        if source == kIOPSBatteryPowerValue as String {
            return .battery
        }
        return .unknown
    }
}

enum CodexCostCatchUpPauseReason: Sendable, Equatable {
    case lowPower
    case thermal
    case user
    case noProgress
    case error(String)
}

struct CodexCostCatchUpActivity: Sendable, Equatable {
    enum Phase: Sendable, Equatable {
        case indexing
        case paused
        case complete
    }

    var phase: Phase
    let mode: CodexCostCatchUpMode
    let processedBytes: Int64
    let totalBytes: Int64
    let completedFiles: Int
    let totalFiles: Int
    var pauseReason: CodexCostCatchUpPauseReason?
    let staleSnapshotUpdatedAt: Date?

    var requiresExplicitResume: Bool {
        guard self.phase == .paused else { return false }
        return switch self.pauseReason {
        case .user, .noProgress, .error: true
        case .lowPower, .thermal, .none: false
        }
    }

    var fractionCompleted: Double? {
        guard self.totalBytes > 0 else {
            guard self.totalFiles > 0 else { return nil }
            return min(1, max(0, Double(self.completedFiles) / Double(self.totalFiles)))
        }
        return min(1, max(0, Double(self.processedBytes) / Double(self.totalBytes)))
    }
}

struct CodexCostCatchUpPolicy: Sendable {
    struct Input: Sendable {
        let mode: CodexCostCatchUpMode
        let previousActiveDuration: TimeInterval?
        let powerSource: CodexCostCatchUpPowerSource
        let lowPowerModeEnabled: Bool
        let thermalState: ProcessInfo.ThermalState
        var completedPasses: Int = 0
    }

    struct Decision: Sendable, Equatable {
        enum Action: Sendable, Equatable {
            case runAfter(TimeInterval)
            case pause(TimeInterval, CodexCostCatchUpPauseReason)
        }

        let action: Action
        let targetDutyCycle: Double?
    }

    static let automaticBurstDuration: TimeInterval = 2
    static let constrainedRetryDelay: TimeInterval = 60

    func decision(for input: Input) -> Decision {
        if input.thermalState == .critical {
            return Decision(
                action: .pause(Self.constrainedRetryDelay, .thermal),
                targetDutyCycle: nil)
        }
        if input.mode == .automatic {
            // Report the stronger constraint when both pauses apply.
            if input.thermalState == .serious {
                return Decision(
                    action: .pause(Self.constrainedRetryDelay, .thermal),
                    targetDutyCycle: nil)
            }
            if input.lowPowerModeEnabled {
                return Decision(
                    action: .pause(Self.constrainedRetryDelay, .lowPower),
                    targetDutyCycle: nil)
            }
        }
        if input.mode == .accelerated {
            return Decision(action: .runAfter(0), targetDutyCycle: 1)
        }

        let dutyCycle = switch input.powerSource {
        case .ac: 0.001
        case .battery: 0.0002
        case .unknown: 0.0005
        }
        let activeDuration = max(0, input.previousActiveDuration ?? 0)
        // Cheap discovery pages share one burst; readiness is still checked after every page.
        if activeDuration < Self.automaticBurstDuration, input.completedPasses < 8 {
            return Decision(action: .runAfter(0), targetDutyCycle: dutyCycle)
        }
        let delay = activeDuration * (1 - dutyCycle) / dutyCycle
        return Decision(action: .runAfter(delay), targetDutyCycle: dutyCycle)
    }
}

extension CodexCostCatchUpPolicy {
    /// Remaining session files below which the automatic bursts finish a cold cache quickly anyway.
    static let minimumColdBacklogFiles = 16

    /// A large cache with no completed history yet: a parser-hash rebuild or a first scan of a session home.
    ///
    /// Warm caches retain their last complete report (`staleSnapshotUpdatedAt`) while new tail work is pending,
    /// so only a cold cache shows partial spend for the whole catch-up.
    static func isColdCache(_ status: CostUsageFetcher.CodexScanCatchUpStatus) -> Bool {
        status.pending && status.staleSnapshotUpdatedAt == nil
            && status.totalFiles - status.completedFiles >= self.minimumColdBacklogFiles
    }

    /// At the automatic 0.1% duty cycle a multi-gigabyte cold rescan leaves spend partial for days. Finish it once
    /// in accelerated mode, which keeps its existing safety (critical thermal pauses, bounded checkpointed
    /// passes), but only when the Mac is on AC power and neither low power nor thermal pressure applies.
    static func coldCacheMode(
        requested: CodexCostCatchUpMode,
        statuses: [CostUsageFetcher.CodexScanCatchUpStatus],
        powerSource: CodexCostCatchUpPowerSource,
        lowPowerModeEnabled: Bool,
        thermalState: ProcessInfo.ThermalState) -> CodexCostCatchUpMode
    {
        guard requested == .automatic, powerSource == .ac, !lowPowerModeEnabled,
              thermalState == .nominal || thermalState == .fair,
              statuses.contains(where: self.isColdCache) else { return requested }
        return .accelerated
    }
}

extension UsageStore {
    /// A rebuilt or never-completed account cache finishes once at the accelerated rate; warm tails stay automatic.
    func accelerateColdSpendDashboardCodexCostCatchUpIfNeeded(statuses: [CostUsageFetcher.CodexScanCatchUpStatus]) {
        guard self.spendDashboardCodexCostCatchUpMode == .automatic,
              !self.settings.backgroundWorkLowPowerModeEnabled else { return }
        let resources = self._test_spendDashboardCodexCostCatchUpResourceStateOverride?() ?? (
            powerSource: CodexCostCatchUpPowerSource.current(),
            lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermalState: ProcessInfo.processInfo.thermalState)
        let mode = CodexCostCatchUpPolicy.coldCacheMode(
            requested: .automatic,
            statuses: statuses,
            powerSource: resources.powerSource,
            lowPowerModeEnabled: resources.lowPowerModeEnabled,
            thermalState: resources.thermalState)
        guard mode == .accelerated else { return }
        self.spendDashboardCodexCostCatchUpMode = .accelerated
        CodexBarLog.logger(LogCategories.tokenCost).info(
            "Codex cost catch-up accelerated once: an account cache has no completed history yet")
    }
}
