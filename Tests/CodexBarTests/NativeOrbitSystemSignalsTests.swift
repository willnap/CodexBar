import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct NativeOrbitSystemSignalsTests {
    @Test func `network status remains unknown until a path arrives and clears immediately on reconnection`() {
        let signals = NativeOrbitSystemSignals(timeZoneIdentifier: "Europe/London")
        #expect(signals.isOffline == nil)
        signals.recordNetworkPath(isSatisfied: false)
        #expect(signals.isOffline == true)
        signals.recordNetworkPath(isSatisfied: true)
        #expect(signals.isOffline == false)
    }

    @Test func `timezone events preserve the actual old and new zones and ignore duplicate notices`() {
        let signals = NativeOrbitSystemSignals(timeZoneIdentifier: "Europe/London")
        let changedAt = Date(timeIntervalSince1970: 1_800_000_000)
        signals.recordTimeZone(identifier: "America/New_York", at: changedAt)
        #expect(signals.timeZoneChange?.oldIdentifier == "Europe/London")
        #expect(signals.timeZoneChange?.newIdentifier == "America/New_York")
        #expect(signals.timeZoneChange?.changedAt == changedAt)
        signals.recordTimeZone(identifier: "America/New_York", at: changedAt.addingTimeInterval(60))
        #expect(signals.timeZoneChange?.changedAt == changedAt)
    }

    @Test func `history storage failures stay provider scoped and clear after an accepted write`() {
        let signals = NativeOrbitSystemSignals(timeZoneIdentifier: "Europe/London")
        signals.recordHistoryWriteFailures([UsageProvider.claude.instanceID])
        #expect(signals.historyWriteFailures == [UsageProvider.claude.instanceID])
        #expect(!signals.historyWriteFailures.contains(UsageProvider.codex.instanceID))
        signals.recordHistoryWriteFailures([])
        #expect(signals.historyWriteFailures.isEmpty)
    }

    @Test func `notification authorization is unknown until observed and tracks permission changes`() {
        let signals = NativeOrbitSystemSignals(timeZoneIdentifier: "Europe/London")
        #expect(signals.notificationsDenied == nil)
        signals.recordNotificationAuthorization(isDenied: true)
        #expect(signals.notificationsDenied == true)
        signals.recordNotificationAuthorization(isDenied: false)
        #expect(signals.notificationsDenied == false)
    }

    @Test func `starting telemetry under tests never starts live observers`() {
        let signals = NativeOrbitSystemSignals(timeZoneIdentifier: "Europe/London")
        signals.start()
        #expect(!signals.isMonitoring)
        #expect(signals.isOffline == nil)
        #expect(signals.notificationsDenied == nil)
        signals.stop()
    }
}
