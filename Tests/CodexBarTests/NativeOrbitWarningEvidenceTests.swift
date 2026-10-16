import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct NativeOrbitWarningEvidenceTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func `quota continuity excludes the current receipt and skips aggregate rows`() {
        let reset = self.now.addingTimeInterval(3600)
        let history = self.lane(minutes: 300, entries: [
            .init(capturedAt: self.now.addingTimeInterval(-120), usedPercent: 20, resetsAt: reset),
            .init(
                capturedAt: self.now.addingTimeInterval(-60),
                usedPercent: 0,
                resetsAt: nil,
                historicalPeriod: .init(
                    startsAt: self.now.addingTimeInterval(-3600), approximate: false, accountingComplete: true)),
            .init(capturedAt: self.now, usedPercent: 30, resetsAt: nil),
        ])
        let lights = self.lights([history])
        #expect(lights.map(\.kind) == [.notReported])
        #expect(lights.first?.validUntil
            == self.now.addingTimeInterval(NativeOrbitWarningSignals.maximumQuotaAge - 120))
        // A real newer zero terminates continuity; searching backward must not borrow an older active window.
        let ended = self.lane(minutes: 300, entries: history.entries + [
            .init(capturedAt: self.now.addingTimeInterval(-30), usedPercent: 0, resetsAt: nil),
        ])
        #expect(self.lights([ended]).isEmpty)
    }

    @Test func `equal time quota receipts preserve first source cadence and expired evidence stays absent`() {
        let receipt = PlanUtilizationHistoryEntry(
            capturedAt: self.now.addingTimeInterval(-60),
            usedPercent: 20,
            resetsAt: self.now.addingTimeInterval(3600))
        let session = self.lane(minutes: 300, entries: [receipt])
        let weekly = self.lane(minutes: 10080, entries: [receipt])
        #expect(self.lights([session, weekly]).map(\.kind) == [.notReported])
        #expect(self.lights([weekly, session]).isEmpty)
        let expired = self.lane(minutes: 300, entries: [.init(
            capturedAt: self.now.addingTimeInterval(-120),
            usedPercent: 20,
            resetsAt: self.now)])
        #expect(self.lights([expired]).isEmpty)
    }

    private func lane(minutes: Int, entries: [PlanUtilizationHistoryEntry]) -> PlanUtilizationSeriesHistory {
        .init(name: "nativeQuota:primary", windowMinutes: minutes, entries: entries)
    }

    private func lights(_ history: [PlanUtilizationSeriesHistory]) -> [NativeOrbitWarningLight] {
        NativeOrbitWarningEvidence.quotaLights(
            provider: .claude,
            snapshot: .init(
                primary: .init(usedPercent: 30, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: self.now),
            history: history,
            now: self.now)
    }
}
