import Foundation
import Testing
@testable import CodexBarCore

struct NativeOrbitCodexSparkHistoryTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let label = "GPT-5.3-Codex-Spark"

    @Test func `recorded Spark session and weekly quotas keep exact independent measurements`() throws {
        let captured = self.now.addingTimeInterval(-120.375)
        let observation = try #require(self.parse(self.event(
            at: captured,
            primary: self.window(percent: 125.625, minutes: 300, reset: 1_800_001_234.25),
            secondary: self.window(percent: 75.875, minutes: 10080, reset: 1_800_604_800.5))).first)
        #expect(observation.workspaceAccountID == nil)
        #expect(observation.snapshot.updatedAt == captured)
        #expect(observation.snapshot.primary == nil)
        #expect(observation.snapshot.secondary == nil)
        let windows = try #require(observation.snapshot.extraRateWindows)
        #expect(windows.map(\.id) == ["codex-spark", "codex-spark-weekly"])
        #expect(windows.map(\.title) == [self.label, self.label])
        #expect(windows.map(\.window.usedPercent) == [125.625, 75.875])
        #expect(windows.map(\.window.windowMinutes) == [300, 10080])
        #expect(windows.map(\.window.resetsAt) == [
            Date(timeIntervalSince1970: 1_800_001_234.25), Date(timeIntervalSince1970: 1_800_604_800.5),
        ])
        // Evaluate outside the Testing macro: a key-path closure there is incorrectly treated as throwing.
        let allUsageKnown = windows.allSatisfy(\.usageKnown)
        #expect(allUsageKnown)
    }

    @Test func `weekly only Spark primary maps to its existing weekly gauge identity`() throws {
        let observation = try #require(self.parse(self.event(
            primary: self.window(percent: 37.5, minutes: 10080))).first)
        let window = try #require(observation.snapshot.extraRateWindows?.first)
        #expect(window.id == "codex-spark-weekly")
        #expect(window.window.windowMinutes == 10080)
        #expect(observation.snapshot.primary == nil)
        #expect(observation.snapshot.secondary == nil)
    }

    @Test func `Spark observation identity retains conflicting values resets and cadences`() {
        let first = self.event(primary: self.window(percent: 37.5, minutes: 300))
        let events = [
            first, first,
            self.event(primary: self.window(percent: 38.5, minutes: 300)),
            self.event(primary: self.window(percent: 37.5, minutes: 300, reset: 1_800_001_999.5)),
            self.event(primary: self.window(percent: 37.5, minutes: 10080)),
        ]
        let observations = self.parse(events.joined())
        #expect(observations.count == 5)
        #expect(Set(observations).count == 4)
    }

    @Test func `Spark history requires its recorded model identity and valid measured windows`() {
        let valid = self.event(primary: self.window(percent: 37.5, minutes: 300))
        let invalid = [
            valid.replacingOccurrences(of: "codex_bengalfox", with: "unrelated-limit"),
            valid.replacingOccurrences(of: self.label, with: "Unrelated model"),
            valid.replacingOccurrences(of: "\"limit_name\":\"\(self.label)\",", with: ""),
            valid.replacingOccurrences(of: "37.5", with: "-1"),
            valid.replacingOccurrences(of: "37.5", with: "true"),
            valid.replacingOccurrences(of: "\"resets_at\":1800007200.0", with: "\"resets_at\":null"),
            self.event(at: self.now.addingTimeInterval(1), primary: self.window(percent: 37.5, minutes: 300)),
            self.event(
                at: self.now.addingTimeInterval(-33 * 86400),
                primary: self.window(percent: 37.5, minutes: 300)),
        ]
        #expect(self.parse(invalid.joined()).isEmpty)
    }

    @Test func `creator metadata never owns a recovered Spark quota`() throws {
        let metadata = "{\"type\":\"session_meta\",\"payload\":{\"creator_account_id\":\"fixture-owner\"}}\n"
        let event = self.event(primary: self.window(percent: 37.5, minutes: 300))
        for prefix in ["", metadata, metadata + metadata.replacingOccurrences(of: "fixture-owner", with: "other")] {
            let observation = try #require(self.parse(prefix + event).first)
            #expect(observation.workspaceAccountID == nil)
            #expect(observation.snapshot.extraRateWindows?.count == 1)
        }
    }

    private func parse(_ text: String) -> [NativeCodexQuotaSessionObservation] {
        NativeCodexQuotaSessionHistoryParser.parse(Data(text.utf8), now: self.now)
    }

    private func window(percent: Double, minutes: Int, reset: Double = 1_800_007_200) -> String {
        "{\"used_percent\":\(percent),\"window_minutes\":\(minutes),\"resets_at\":\(reset)}"
    }

    private func event(at date: Date? = nil, primary: String, secondary: String = "null") -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return """
        {"type":"event_msg","timestamp":"\(formatter.string(from: date ?? self.now))",\
        "payload":{"type":"token_count","rate_limits":{"limit_id":"codex_bengalfox",\
        "limit_name":"\(self.label)","primary":\(primary),"secondary":\(secondary)}}}

        """
    }
}
