import Foundation
import Testing
@testable import CodexBarCore

/// A month of session logs is hundreds of thousands of readings held between scans, so what one weighs matters,
/// and the compact form must give back exactly the windows it was made from.
struct NativeCodexQuotaSessionReadingTests {
    private let captured = Date(timeIntervalSince1970: 1_800_000_000.25)

    private func observation(
        primary: RateWindow?, secondary: RateWindow?, extra: [NamedRateWindow]? = nil)
        -> NativeCodexQuotaSessionObservation
    {
        NativeCodexQuotaSessionObservation(legacyCreatorAccountID: nil, snapshot: UsageSnapshot(
            primary: primary,
            secondary: secondary,
            extraRateWindows: extra,
            updatedAt: self.captured))
    }

    @Test
    func `a reading is small enough to hold by the hundred thousand`() {
        #expect(MemoryLayout<NativeCodexQuotaSessionReading>.stride <= 64)
        #expect(MemoryLayout<NativeCodexQuotaSessionObservation>.stride <= 80)
    }

    @Test
    func `the windows a log event reports come back exactly`() {
        let reset = Date(timeIntervalSince1970: 1_800_003_600.5)
        let session = RateWindow(usedPercent: 41.25, windowMinutes: 300, resetsAt: reset, resetDescription: nil)
        let weekly = RateWindow(usedPercent: 100.5, windowMinutes: 10080, resetsAt: nil, resetDescription: nil)
        let both = self.observation(primary: session, secondary: weekly)
        #expect(both.primary == session)
        #expect(both.secondary == weekly)
        #expect(both.capturedAt == self.captured)
        #expect(both.snapshot.extraRateWindows == nil)

        let none = self.observation(primary: nil, secondary: nil)
        #expect(none.primary == nil)
        #expect(none.secondary == nil)

        let undated = RateWindow(usedPercent: 0, windowMinutes: nil, resetsAt: nil, resetDescription: nil)
        #expect(self.observation(primary: undated, secondary: nil).primary == undated)
    }

    @Test
    func `a window with more than a log event carries is kept whole`() {
        let labelled = RateWindow(
            usedPercent: 12,
            windowMinutes: 300,
            resetsAt: nil,
            resetDescription: "resets soon",
            quotaLimit: 40,
            quotaUnit: "requests",
            title: "Session")
        let plain = RateWindow(usedPercent: 3, windowMinutes: 10080, resetsAt: nil, resetDescription: nil)
        let extra = [NamedRateWindow(id: "extra", title: "Extra", window: plain)]
        let reading = self.observation(primary: labelled, secondary: plain, extra: extra)
        #expect(reading.primary == labelled)
        #expect(reading.secondary == plain)
        #expect(reading.snapshot.extraRateWindows == extra)
        // Equal readings still compare and hash alike, however they are stored.
        let twin = self.observation(primary: labelled, secondary: plain, extra: extra)
        #expect(reading == twin)
        #expect(reading.hashValue == twin.hashValue)
        #expect(reading != self.observation(primary: plain, secondary: plain, extra: extra))
    }
}
