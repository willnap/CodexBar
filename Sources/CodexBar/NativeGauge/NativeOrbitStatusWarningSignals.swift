import CodexBarCore
import Foundation

enum NativeOrbitStatusWarningSignals {
    static func lights(
        provider: UsageProvider,
        status: ProviderStatus?,
        components: [ProviderStatusComponent],
        fetchFailed: Bool = false,
        recentModels: Set<String> = [],
        now: Date = Date()) -> [NativeOrbitWarningLight]
    {
        var lights: [NativeOrbitWarningLight] = []
        if fetchFailed {
            lights.append(.init(
                .statusUnknown,
                .caution,
                "Service status could not be refreshed.",
                action: .statusPage))
        }
        guard let status else { return lights }
        let relevant = Self.relevantComponents(components, provider: provider)
        let ids = Set(relevant.map(\.id))
        let incidents = (status.incidents ?? []).filter {
            !$0.isResolved && (!Self.requiresProductScope(provider) || !$0.componentIDs.isDisjoint(with: ids) ||
                ($0.componentIDs.isEmpty && (!Self.requiresProductScope(provider)
                        || Self.namesProduct($0.title, provider: provider))))
        }

        for incident in incidents {
            if incident.isMaintenance {
                guard Self.maintenanceIsNearOrActive(incident, now: now) else { continue }
                let scheduled = incident.phase == "scheduled" && (incident.scheduledFor ?? .distantPast) > now
                lights.append(.init(
                    .maintenance,
                    scheduled ? .opportunity : .caution,
                    Self.detail(incident),
                    action: .statusPage,
                    tooltipDetail: Self.maintenanceTooltip(incident, now: now)))
            } else {
                if let light = Self.serviceLight(
                    indicator: Self.incidentIndicator(incident.impact), detail: Self.detail(incident))
                {
                    lights.append(light)
                }
                // A model alert requires a name observed in this account's recent usage, not guessed from the page.
                if recentModels.contains(where: { Self.mentionsModel($0, in: incident.title) }) {
                    lights.append(.init(.modelTrouble, .caution, Self.detail(incident), action: .statusPage))
                }
            }
        }
        for component in relevant where component.children.isEmpty && component.indicator != .none {
            let detail = "\(component.name): \(component.status.replacingOccurrences(of: "_", with: " "))."
            if component.indicator == .maintenance {
                lights.append(.init(.maintenance, .caution, detail, action: .statusPage))
            } else if let light = Self.serviceLight(indicator: component.indicator, detail: detail) {
                lights.append(light)
                if recentModels.contains(where: { Self.mentionsModel($0, in: component.name) }) {
                    lights.append(.init(.modelTrouble, .caution, detail, action: .statusPage))
                }
            }
        }

        // A shared company's aggregate banner cannot establish which product is affected.
        if Self.requiresProductScope(provider), relevant.isEmpty, status.indicator.hasIssue, incidents.isEmpty {
            lights.append(.init(
                .statusUnknown,
                .caution,
                "The status feed does not identify whether this service is affected.",
                action: .statusPage))
        }
        if components.isEmpty, !Self.requiresProductScope(provider) {
            let detail = status.description ??
                "\(provider.rawValue.capitalized) reports \(status.indicator.rawValue)."
            if status.indicator == .maintenance {
                lights.append(.init(.maintenance, .caution, detail, action: .statusPage))
            } else if let light = Self.serviceLight(indicator: status.indicator, detail: detail) {
                lights.append(light)
            }
        }
        if status.indicator == .unknown, !fetchFailed {
            lights.append(.init(
                .statusUnknown,
                .caution,
                "Service status is unavailable.",
                action: .statusPage))
        }
        return NativeOrbitWarningLight.merged(lights)
    }

    private static func relevantComponents(
        _ components: [ProviderStatusComponent],
        provider: UsageProvider,
        parentMatches: Bool = false) -> [ProviderStatusComponent]
    {
        components.flatMap { component in
            let matches = parentMatches || !Self.requiresProductScope(provider)
                || Self.namesProduct(component.name, provider: provider)
            if !component.children.isEmpty {
                let children = Self.relevantComponents(component.children, provider: provider, parentMatches: matches)
                return (matches ? [component] : []) + children
            }
            return matches ? [component] : []
        }
    }

    private static func namesProduct(_ name: String, provider: UsageProvider) -> Bool {
        let lower = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Provider-specific by design: shared OpenAI and Anthropic feeds need product-specific component names.
        if provider == .codex { return lower.contains("codex") }
        if provider == .openai {
            return lower == "api" || lower == "apis" || lower.contains("api.openai.com")
                || lower.contains("openai api") || lower.hasPrefix("api ")
        }
        if provider == .claude {
            return lower.contains("claude") || lower == "api" || lower == "api.anthropic.com" ||
                lower.contains("anthropic api") || lower.contains("console")
        }
        if let allowlist = ProviderDefaults.metadata[provider]?.statusComponentAllowlist {
            return allowlist.contains { $0.lowercased() == lower }
        }
        return lower.contains(provider.rawValue.lowercased())
    }

    private static func requiresProductScope(_ provider: UsageProvider) -> Bool {
        // Provider-specific by design: these feeds cover several products. Other configured feeds belong
        // to the service itself; their API/Database components need not repeat its brand name.
        [.codex, .openai, .claude, .copilot].contains(provider)
            || ProviderDefaults.metadata[provider]?.statusComponentAllowlist != nil
    }

    private static func mentionsModel(_ model: String, in title: String) -> Bool {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"-[0-9]{8}$"#, with: "", options: .regularExpression)
        guard model.count >= 3 else { return false }
        let tokens = model.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return false }
        let pattern = "(?<![a-z0-9])" + tokens.map(NSRegularExpression.escapedPattern(for:))
            .joined(separator: "[- ._]*") + "(?![a-z0-9])"
        return title.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func incidentIndicator(_ impact: String) -> ProviderStatusIndicator {
        switch impact {
        case "minor": .minor
        case "major": .major
        case "critical": .critical
        default: .unknown
        }
    }

    private static func serviceLight(
        indicator: ProviderStatusIndicator,
        detail: String) -> NativeOrbitWarningLight?
    {
        switch indicator {
        case .minor: .init(.degraded, .caution, detail, action: .statusPage)
        case .major, .critical: .init(.outage, .critical, detail, action: .statusPage)
        case .none, .unknown, .maintenance: nil
        }
    }

    private static func maintenanceIsNearOrActive(_ incident: ProviderStatusIncident, now: Date) -> Bool {
        if let end = incident.scheduledUntil, end <= now { return false }
        if ["in_progress", "verifying"].contains(incident.phase) { return true }
        guard let start = incident.scheduledFor else { return false }
        if start <= now, let end = incident.scheduledUntil, end > now { return true }
        return start >= now && start.timeIntervalSince(now) <= 24 * 3600
    }

    private static func maintenanceTooltip(_ incident: ProviderStatusIncident, now: Date) -> String {
        if incident.phase == "scheduled", let start = incident.scheduledFor {
            return "Maintenance starts \(NativeOrbitTooltip.at(start, now: now))."
        }
        if let end = incident.scheduledUntil {
            return "Maintenance until \(NativeOrbitTooltip.moment(end, now: now))."
        }
        return NativeOrbitWarningLight.Kind.maintenance.explanation
    }

    private static func detail(_ incident: ProviderStatusIncident) -> String {
        var parts = [incident.title.trimmingCharacters(in: .whitespacesAndNewlines)]
        if incident.isMaintenance {
            if incident.phase == "scheduled", let start = incident.scheduledFor {
                parts.append("Starts \(start.formatted(date: .abbreviated, time: .shortened)).")
            } else if let end = incident.scheduledUntil {
                parts.append("Until \(end.formatted(date: .abbreviated, time: .shortened)).")
            }
        }
        return parts.joined(separator: " ")
    }
}
