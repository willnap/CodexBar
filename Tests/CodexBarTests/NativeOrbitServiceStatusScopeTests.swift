import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct NativeOrbitServiceStatusScopeTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test(arguments: [UsageProvider.cursor, .factory, .augment, .huggingface])
    func `dedicated service feeds retain generically named API failures`(provider: UsageProvider) {
        let lights = self.lights(provider, components: [self.component("API", .critical)])
        #expect(lights.contains { $0.kind == .outage })
    }

    @Test func `dedicated service incidents need not repeat the company name`() {
        let incident = ProviderStatusIncident(
            id: "incident", title: "Elevated API errors", phase: "investigating", impact: "major")
        let lights = NativeOrbitStatusWarningSignals.lights(
            provider: .cursor,
            status: .init(indicator: .major, description: nil, updatedAt: self.now, incidents: [incident]),
            components: [self.component("API", .none)],
            now: self.now)
        #expect(lights.contains { $0.kind == .outage && $0.detail == incident.title })
    }

    @Test func `OpenAI API uses its component without borrowing ChatGPT or Codex incidents`() {
        let components = [
            self.component("APIs", .minor),
            self.component("ChatGPT", .critical),
            self.component("Codex", .critical),
        ]
        let lights = self.lights(.openai, components: components)
        #expect(lights.map(\.kind) == [.degraded])
        #expect(lights.first?.detail.hasPrefix("APIs:") == true)
    }

    @Test func `shared OpenAI aggregate cannot establish API impact`() {
        let lights = self.lights(.openai, components: [])
        #expect(!lights.contains { $0.kind == .outage || $0.kind == .degraded })
        #expect(lights.contains { $0.kind == .statusUnknown })
    }

    @Test func `Copilot ignores unrelated GitHub component incidents`() {
        let lights = self.lights(.copilot, components: [
            self.component("Copilot", .none), self.component("Actions", .critical),
        ])
        #expect(lights.isEmpty)
    }

    @Test func `ZoomMate honors its descriptor component allowlist`() {
        let lights = self.lights(.zoommate, components: [
            self.component("Zoom Meetings", .minor), self.component("Zoom Phone", .critical),
        ])
        #expect(lights.map(\.kind) == [.degraded])
        #expect(lights.first?.detail.hasPrefix("Zoom Meetings:") == true)
    }

    @Test func `component groups preserve child incident associations`() {
        let incident = ProviderStatusIncident(
            id: "child-incident",
            title: "Inference requests failing",
            phase: "investigating",
            impact: "major",
            componentIDs: ["inference"])
        let lights = NativeOrbitStatusWarningSignals.lights(
            provider: .huggingface,
            status: .init(indicator: .major, description: nil, updatedAt: self.now, incidents: [incident]),
            components: [.init(
                id: "api",
                name: "API",
                indicator: .none,
                status: "operational",
                children: [.init(id: "inference", name: "Inference", indicator: .none, status: "operational")])],
            now: self.now)
        #expect(lights.contains { $0.kind == .outage && $0.detail == incident.title })
    }

    @Test func `dedicated feed maintenance survives an absent component inventory`() {
        let incident = ProviderStatusIncident(
            id: "maintenance",
            title: "Database work",
            phase: "scheduled",
            impact: "maintenance",
            componentIDs: ["database"],
            scheduledFor: self.now.addingTimeInterval(3600),
            scheduledUntil: self.now.addingTimeInterval(7200))
        let lights = NativeOrbitStatusWarningSignals.lights(
            provider: .cursor,
            status: .init(indicator: .none, description: nil, updatedAt: self.now, incidents: [incident]),
            components: [],
            now: self.now)
        #expect(lights.contains { $0.kind == .maintenance && $0.severity == .opportunity })
    }

    private func lights(_ provider: UsageProvider, components: [ProviderStatusComponent])
        -> [NativeOrbitWarningLight]
    {
        NativeOrbitStatusWarningSignals.lights(
            provider: provider,
            status: .init(indicator: .critical, description: "Partial outage", updatedAt: self.now),
            components: components,
            now: self.now)
    }

    private func component(_ name: String, _ indicator: ProviderStatusIndicator) -> ProviderStatusComponent {
        .init(id: name, name: name, indicator: indicator, status: indicator.rawValue)
    }
}
