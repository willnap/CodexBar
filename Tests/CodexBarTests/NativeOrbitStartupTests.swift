import Foundation
import Testing
@testable import CodexBar

@MainActor
struct NativeOrbitStartupTests {
    @Test func `cancelled preparation leaves the first shown startup available`() {
        let launch = NativeOrbitStartupLaunch()
        let cancelled = UUID(), next = UUID()
        #expect(launch.reserve(cancelled))
        #expect(!launch.hasShown)
        launch.cancel(cancelled)
        #expect(!launch.hasShown)
        #expect(!launch.shown(cancelled))
        #expect(launch.reserve(next))
        #expect(launch.shown(next))
        #expect(launch.hasShown)
    }

    @Test func `a shown startup is consumed once across all owners`() {
        let launch = NativeOrbitStartupLaunch()
        let first = UUID(), second = UUID()
        #expect(launch.reserve(first))
        #expect(launch.shown(first))
        #expect(!launch.shown(first))
        #expect(!launch.reserve(first))
        #expect(!launch.reserve(second))
        #expect(!launch.shown(second))
        launch.cancel(first)
        #expect(launch.hasShown)
        #expect(!launch.reserve(second))
    }

    @Test func `another owner cannot reserve consume or cancel the current reservation`() {
        let launch = NativeOrbitStartupLaunch()
        let owner = UUID(), other = UUID()
        #expect(!launch.shown(owner))
        #expect(launch.reserve(owner))
        #expect(launch.reserve(owner), "Repeated preparation by the same owner is idempotent")
        #expect(!launch.reserve(other))
        #expect(!launch.shown(other))
        launch.cancel(other)
        #expect(!launch.reserve(other))
        #expect(!launch.hasShown)
        #expect(launch.shown(owner))
    }

    @Test func `only the live phase ends startup and only full motion phases test lamps`() {
        #expect(!NativeOrbitStartupPhase.live.isActive)
        #expect(!NativeOrbitStartupPhase.live.testsLamps)
        for phase: NativeOrbitStartupPhase in [.armed, .sweeping, .settling] {
            #expect(phase.isActive)
            #expect(phase.testsLamps)
        }
        #expect(NativeOrbitStartupPhase.reduced.isActive)
        #expect(!NativeOrbitStartupPhase.reduced.testsLamps)
    }

    @Test func `the gauge sweep has deterministic empty and full endpoints`() {
        let readings: [Double?] = [nil, 0, 0.34, 1, -1, 2, .nan, .infinity, -.infinity]
        for reading in readings {
            #expect(NativeOrbitStartupPhase.armed.fraction(reading) == 0)
            #expect(NativeOrbitStartupPhase.sweeping.fraction(reading) == 1)
        }
    }

    @Test func `settled live and reduced gauges preserve actual fractions with safe bounds`() {
        for phase: NativeOrbitStartupPhase in [.settling, .live, .reduced] {
            #expect(phase.fraction(0) == 0)
            #expect(phase.fraction(0.34) == 0.34)
            #expect(phase.fraction(1) == 1)
            #expect(phase.fraction(-0.2) == 0)
            #expect(phase.fraction(1.2) == 1)
            #expect(phase.fraction(nil) == 0)
            #expect(phase.fraction(.nan) == 0)
            #expect(phase.fraction(.infinity) == 0)
            #expect(phase.fraction(-.infinity) == 0)
        }
    }

    @Test func `numbers and graphs reveal after arming while reduced motion can fade actual content`() {
        #expect(NativeOrbitStartupPhase.armed.readingsReveal == 0)
        #expect(NativeOrbitStartupPhase.armed.graphReveal == 0)
        #expect(NativeOrbitStartupPhase.reduced.readingsReveal == 0)
        #expect(NativeOrbitStartupPhase.reduced.graphReveal == 0)
        for phase: NativeOrbitStartupPhase in [.sweeping, .settling, .live] {
            #expect(phase.readingsReveal == 1)
            #expect(phase.graphReveal == 1)
        }
    }
}
