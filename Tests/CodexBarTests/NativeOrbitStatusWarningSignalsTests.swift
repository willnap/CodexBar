import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct NativeOrbitStatusWarningSignalsTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func `unrelated ChatGPT and Sora outages do not light Codex`() {
        let components = [
            self.component("Codex", .none),
            self.component("ChatGPT", .critical),
            self.component("Sora", .critical),
        ]
        #expect(NativeOrbitStatusWarningSignals.lights(
            provider: .codex,
            status: self.status(.critical),
            components: components,
            now: self.now).isEmpty)
    }

    @Test func `Codex degradation and outage use different lights`() {
        for (indicator, kind) in [
            (ProviderStatusIndicator.minor, NativeOrbitWarningLight.Kind.degraded),
            (.critical, .outage),
        ] {
            let lights = NativeOrbitStatusWarningSignals.lights(
                provider: .codex,
                status: self.status(indicator),
                components: [self.component("Codex", indicator)],
                now: self.now)
            #expect(lights.map(\.kind) == [kind])
        }
    }

    @Test func `failed status fetch stays visible alongside last known service evidence`() {
        let lights = NativeOrbitStatusWarningSignals.lights(
            provider: .claude,
            status: self.status(.minor),
            components: [self.component("Claude Code", .minor)],
            fetchFailed: true,
            now: self.now)
        #expect(lights.contains { $0.kind == .statusUnknown })
        #expect(lights.contains { $0.kind == .degraded })
        #expect(lights.first { $0.kind == .statusUnknown }?.detail == "Service status could not be refreshed.")
        #expect(lights.first { $0.kind == .degraded }?.detail.contains("Claude Code") == true)
    }

    @Test func `backend component diagnostics never become warning hover copy`() {
        let component = self.component("Codex: " + String(repeating: "verbose backend detail — ", count: 20), .critical)
        let lights = NativeOrbitStatusWarningSignals.lights(
            provider: .codex, status: self.status(.critical), components: [component], now: self.now)
        #expect(lights.first?.detail.contains("verbose backend") == true)
        #expect(lights.first?.tooltip(account: "Work") == "Service outage.")
    }

    @Test func `a failed shared status fetch does not turn an unscoped banner into product degradation`() {
        let lights = NativeOrbitStatusWarningSignals.lights(
            provider: .claude,
            status: self.status(.minor),
            components: [],
            fetchFailed: true,
            now: self.now)
        #expect(lights.contains { $0.kind == .statusUnknown })
        #expect(!lights.contains { $0.kind == .degraded || $0.kind == .outage })
    }

    @Test func `maintenance within 24 hours preserves source timing and is an opportunity`() {
        let incident = ProviderStatusIncident(
            id: "maintenance",
            title: "Codex capacity work",
            phase: "scheduled",
            impact: "maintenance",
            componentIDs: ["Codex"],
            updatedAt: self.now,
            scheduledFor: self.now.addingTimeInterval(3600),
            scheduledUntil: self.now.addingTimeInterval(7200))
        let status = ProviderStatus(
            indicator: .none,
            description: nil,
            updatedAt: nil,
            incidents: [incident])
        let lights = NativeOrbitStatusWarningSignals.lights(
            provider: .codex,
            status: status,
            components: [self.component("Codex", .none)],
            now: self.now)
        #expect(lights.map(\.kind) == [.maintenance])
        #expect(lights.first?.severity == .opportunity)
        #expect(lights.first?.detail.contains("Codex capacity work") == true)
        #expect(lights.first?.detail.contains("Starts ") == true)
        #expect(lights.first?.action == .statusPage)
        #expect(lights.first?.tooltip(account: "Work").hasPrefix("Maintenance starts ") == true)
        #expect(lights.first?.tooltip(account: "Work").contains(incident.title) == false)
    }

    @Test func `distant and completed maintenance stays off`() {
        for (phase, delay) in [("scheduled", 25.0 * 3600), ("completed", 3600)] {
            let incident = ProviderStatusIncident(
                id: "maintenance",
                title: "Codex work",
                phase: phase,
                impact: "maintenance",
                componentIDs: ["Codex"],
                scheduledFor: self.now.addingTimeInterval(delay))
            let status = ProviderStatus(
                indicator: .none,
                description: nil,
                updatedAt: nil,
                incidents: [incident])
            #expect(NativeOrbitStatusWarningSignals.lights(
                provider: .codex,
                status: status,
                components: [self.component("Codex", .none)],
                now: self.now).isEmpty)
        }
    }

    @Test func `maintenance already within its source time range remains lit`() {
        let incident = ProviderStatusIncident(
            id: "active",
            title: "Codex maintenance",
            phase: "scheduled",
            impact: "maintenance",
            componentIDs: ["Codex"],
            scheduledFor: self.now.addingTimeInterval(-3600),
            scheduledUntil: self.now.addingTimeInterval(3600))
        let status = ProviderStatus(
            indicator: .none,
            description: nil,
            updatedAt: nil,
            incidents: [incident])
        #expect(NativeOrbitStatusWarningSignals.lights(
            provider: .codex,
            status: status,
            components: [self.component("Codex", .none)],
            now: self.now)
            .contains { $0.kind == .maintenance && $0.severity == .caution })
    }

    @Test func `model component evidence uses only models known in recent history`() {
        let components = [ProviderStatusComponent(
            id: "Codex",
            name: "Codex",
            indicator: .minor,
            status: "degraded_performance",
            children: [self.component("example model 1.2", .minor)])]
        let lights = NativeOrbitStatusWarningSignals.lights(
            provider: .codex,
            status: self.status(.minor),
            components: components,
            recentModels: ["example-model-1-2-20261001"],
            now: self.now)
        #expect(lights.contains { $0.kind == .modelTrouble })
    }

    @Test func `model trouble requires a known recently used model and unresolved source evidence`() {
        let incident = ProviderStatusIncident(
            id: "model",
            title: "Higher errors for example-model",
            phase: "monitoring",
            impact: "minor",
            componentIDs: ["Codex"],
            updatedAt: self.now)
        let status = ProviderStatus(
            indicator: .minor,
            description: nil,
            updatedAt: nil,
            incidents: [incident])
        let noModels = NativeOrbitStatusWarningSignals.lights(
            provider: .codex,
            status: status,
            components: [self.component("Codex", .minor)],
            now: self.now)
        #expect(!noModels.contains { $0.kind == .modelTrouble })
        let known = NativeOrbitStatusWarningSignals.lights(
            provider: .codex,
            status: status,
            components: [self.component("Codex", .minor)],
            recentModels: ["example-model"],
            now: self.now)
        #expect(known.contains { $0.kind == .modelTrouble && $0.detail.contains("Higher errors for example-model") })
        let resolved = ProviderStatusIncident(
            id: "model",
            title: "Higher errors for example-model",
            phase: "resolved",
            impact: "minor",
            componentIDs: ["Codex"],
            updatedAt: self.now)
        #expect(!NativeOrbitStatusWarningSignals.lights(
            provider: .codex,
            status: .init(indicator: .none, description: nil, updatedAt: self.now, incidents: [resolved]),
            components: [self.component("Codex", .none)],
            recentModels: ["example-model"],
            now: self.now).contains { $0.kind == .modelTrouble })
    }

    private func component(_ name: String, _ indicator: ProviderStatusIndicator) -> ProviderStatusComponent {
        .init(
            id: name,
            name: name,
            indicator: indicator,
            status: indicator.rawValue)
    }

    private func status(_ indicator: ProviderStatusIndicator) -> ProviderStatus {
        .init(
            indicator: indicator,
            description: nil,
            updatedAt: self.now)
    }
}
