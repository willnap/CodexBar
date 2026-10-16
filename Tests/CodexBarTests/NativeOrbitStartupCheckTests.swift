import Testing
@testable import CodexBar

struct NativeOrbitStartupCheckTests {
    @Test func `startup check groups partition the entire warning catalogue`() {
        let groups = NativeOrbitStartupCheckGroup.allCases.map { group in
            NativeOrbitWarningLight.Kind.allCases.filter { NativeOrbitStartupChecks.group(for: $0) == group }
        }
        #expect(groups.allSatisfy { !$0.isEmpty })
        #expect(groups.flatMap(\.self).count == NativeOrbitWarningLight.Kind.allCases.count)
        #expect(Set(groups.flatMap(\.self)) == Set(NativeOrbitWarningLight.Kind.allCases))
        #expect(NativeOrbitStartupChecks.group(for: .signIn) == .reading)
        #expect(NativeOrbitStartupChecks.group(for: .usedElsewhere) == .history)
        #expect(NativeOrbitStartupChecks.group(for: .outage) == .status)
        #expect(NativeOrbitStartupChecks.group(for: .notifications) == .prepared)
    }

    @Test func `armed phase illuminates every bulb even when evidence is already ready`() {
        let shown = NativeOrbitStartupChecks.shown(
            realLights: [], phase: .armed, checkpoint: 4, readiness: .ready)
        #expect(shown.map(\.kind) == NativeOrbitWarningLight.Kind.allCases)
    }

    @Test func `checkpoints clear each healthy group only after its evidence is ready`() {
        for checkpoint in 0...4 {
            let shown = NativeOrbitStartupChecks.shown(
                realLights: [], phase: .settling, checkpoint: checkpoint, readiness: .ready)
            let expected = NativeOrbitWarningLight.Kind.allCases.filter {
                NativeOrbitStartupChecks.group(for: $0).checkpoint > checkpoint
            }
            #expect(shown.map(\.kind) == expected)
        }
        let readingPending = NativeOrbitStartupChecks.shown(
            realLights: [],
            phase: .settling,
            checkpoint: 4,
            readiness: .init(readingReady: false, historyReady: true, statusReady: true))
        #expect(readingPending.map(\.kind) == NativeOrbitWarningLight.Kind.allCases.filter {
            NativeOrbitStartupChecks.group(for: $0) == .reading
        })
    }

    @Test func `pending evidence never claims its check has passed`() {
        let shown = NativeOrbitStartupChecks.shown(
            realLights: [], phase: .settling, checkpoint: 4, readiness: .pending)
        #expect(shown.map(\.kind) == NativeOrbitWarningLight.Kind.allCases.filter {
            NativeOrbitStartupChecks.group(for: $0) != .prepared
        })
        #expect(NativeOrbitStartupChecks.shown(
            realLights: [], phase: .sweeping, checkpoint: 0, readiness: .pending).count
            == NativeOrbitWarningLight.Kind.allCases.count)
    }

    @Test func `genuine warnings retain their evidence and severity throughout the test`() {
        let genuine = NativeOrbitWarningLight(.billing, .caution, "Fixture billing condition", action: .dashboard)
        for phase: NativeOrbitStartupPhase in [.armed, .sweeping, .settling] {
            for checkpoint in 0...4 {
                let shown = NativeOrbitStartupChecks.shown(
                    realLights: [genuine], phase: phase, checkpoint: checkpoint, readiness: .ready)
                #expect(shown.first(where: { $0.kind == .billing }) == genuine)
                #expect(shown.filter { $0.kind == .billing }.count == 1)
            }
        }
    }

    @Test func `synthetic contradictory warnings never suppress a genuine condition`() {
        let genuine: [NativeOrbitWarningLight] = [
            .init(.degraded, .caution, "Fixture degradation"),
            .init(.signIn, .critical, "Fixture sign in condition"),
            .init(.idle, .opportunity, "Fixture idle account"),
        ]
        let shown = NativeOrbitStartupChecks.shown(
            realLights: genuine, phase: .armed, checkpoint: 0, readiness: .pending)
        for light in genuine {
            #expect(shown.first(where: { $0.kind == light.kind }) == light)
        }
    }

    @Test func `finished and reduced phases show only reconciled real warnings regardless of pending checks`() {
        let faults: [NativeOrbitWarningLight] = [
            .init(.outage, .critical, "Fixture outage"),
            .init(.degraded, .caution, "Fixture degraded service"),
            .init(.billing, .critical, "Fixture billing condition"),
        ]
        for phase: NativeOrbitStartupPhase in [.live, .reduced] {
            #expect(NativeOrbitStartupChecks.shown(
                realLights: faults, phase: phase, checkpoint: 0, readiness: .pending)
                == NativeOrbitWarningLight.reconciled(faults))
        }
    }
}
