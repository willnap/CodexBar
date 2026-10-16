import Foundation

package enum ProviderStatusIndicator: String, Encodable, Sendable {
    case none
    case minor
    case major
    case critical
    case maintenance
    case unknown

    package var hasIssue: Bool {
        self != .none
    }
}

package struct ProviderStatus: Sendable {
    package let indicator: ProviderStatusIndicator
    package let description: String?
    package let updatedAt: Date?
    /// nil means the feed did not supply incident data; an empty array means it supplied no incidents.
    package let incidents: [ProviderStatusIncident]?

    package init(
        indicator: ProviderStatusIndicator,
        description: String?,
        updatedAt: Date?,
        incidents: [ProviderStatusIncident]? = nil)
    {
        self.indicator = indicator
        self.description = description
        self.updatedAt = updatedAt
        self.incidents = incidents
    }
}

package struct ProviderStatusIncident: Equatable, Sendable {
    package let id: String
    package let title: String
    package let phase: String
    package let impact: String
    package let componentIDs: Set<String>
    package let updatedAt: Date?
    package let scheduledFor: Date?
    package let scheduledUntil: Date?

    package init(
        id: String,
        title: String,
        phase: String,
        impact: String,
        componentIDs: Set<String> = [],
        updatedAt: Date? = nil,
        scheduledFor: Date? = nil,
        scheduledUntil: Date? = nil)
    {
        self.id = id
        self.title = title
        self.phase = phase
        self.impact = impact
        self.componentIDs = componentIDs
        self.updatedAt = updatedAt
        self.scheduledFor = scheduledFor
        self.scheduledUntil = scheduledUntil
    }

    package var isResolved: Bool {
        ["resolved", "completed", "postmortem"].contains(self.phase)
    }

    package var isMaintenance: Bool {
        self.impact == "maintenance" || ["scheduled", "in_progress", "verifying"].contains(self.phase)
    }
}

/// A status service or a group of services. Raw statuses remain separate from localized display labels.
package struct ProviderStatusComponent: Identifiable, Equatable, Sendable {
    package let id: String
    package let name: String
    package let indicator: ProviderStatusIndicator
    package let status: String
    package var children: [ProviderStatusComponent]

    package init(
        id: String,
        name: String,
        indicator: ProviderStatusIndicator,
        status: String,
        children: [ProviderStatusComponent] = [])
    {
        self.id = id
        self.name = name
        self.indicator = indicator
        self.status = status
        self.children = children
    }

    package var isGroup: Bool {
        !self.children.isEmpty
    }

    package static func indicator(forStatuspageStatus status: String) -> ProviderStatusIndicator {
        switch status {
        case "operational": .none
        case "degraded_performance": .minor
        case "partial_outage": .major
        case "major_outage", "full_outage": .critical
        case "under_maintenance": .maintenance
        default: .unknown
        }
    }
}
