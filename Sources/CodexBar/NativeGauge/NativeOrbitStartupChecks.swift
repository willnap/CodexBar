/// Availability of evidence already gathered by the popup. This never starts a provider or system probe.
struct NativeOrbitStartupReadiness: Equatable {
    let readingReady: Bool
    let historyReady: Bool
    let statusReady: Bool

    static let pending = Self(readingReady: false, historyReady: false, statusReady: false)
    static let ready = Self(readingReady: true, historyReady: true, statusReady: true)

    func isReady(for group: NativeOrbitStartupCheckGroup) -> Bool {
        switch group {
        case .prepared: true
        case .reading: self.readingReady
        case .history: self.historyReady
        case .status: self.statusReady
        }
    }
}

enum NativeOrbitStartupCheckGroup: Int, CaseIterable {
    case prepared = 1
    case reading
    case history
    case status

    var checkpoint: Int {
        self.rawValue
    }
}

/// A diagnostic lamp test: elapsed checkpoints alone never imply that provider evidence is valid.
enum NativeOrbitStartupChecks {
    typealias Kind = NativeOrbitWarningLight.Kind

    static func group(for kind: Kind) -> NativeOrbitStartupCheckGroup {
        switch kind {
        case .macOffline, .timeZone, .update, .folderAccess, .storage, .notifications, .autoRefreshOff,
             .unavailableHere:
            .prepared
        case .outage, .degraded, .modelTrouble, .overloaded, .maintenance, .statusUnknown:
            .status
        case .limitsChanged, .behindPace, .aheadOfPace, .farAheadPace, .spike, .idle, .resetLate,
             .earlyReset, .newSavedReset, .usedElsewhere, .unpriced, .unattributed, .localLogs:
            .history
        case .usageFailing, .rateLimited, .apiChanged, .botCheck, .unreachable, .insecure, .signIn,
             .keychain, .wrongAccount, .permission, .browserSession, .plan, .billing, .spend, .credits,
             .limit, .notReported, .switching, .allExhausted, .oldReading, .partialReading, .unknownError,
             .helper, .refreshStuck:
            .reading
        }
    }

    static var catalogue: [NativeOrbitWarningLight] {
        Kind.allCases.map { .init($0, $0.bulbCheckSeverity, $0.explanation) }
    }

    static func shown(
        realLights: [NativeOrbitWarningLight],
        phase: NativeOrbitStartupPhase,
        checkpoint: Int,
        readiness: NativeOrbitStartupReadiness) -> [NativeOrbitWarningLight]
    {
        let real = NativeOrbitWarningLight.reconciled(realLights)
        guard phase.testsLamps else { return real }
        let realKinds = Set(real.map(\.kind))
        let test = Self.catalogue.filter { light in
            guard !realKinds.contains(light.kind) else { return false }
            let group = Self.group(for: light.kind)
            return phase == .armed || checkpoint < group.checkpoint || !readiness.isReady(for: group)
        }
        // Reconciliation applies only to genuine evidence. A synthetic outage must not hide a real degradation.
        return NativeOrbitWarningLight.merged(real + test)
    }
}
