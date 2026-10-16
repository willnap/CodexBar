import Foundation

extension NativeOrbitWarningLight.Kind {
    /// Short fallbacks also describe the synthetic bulb check.
    var explanation: String {
        switch self {
        case .outage: "Service outage."
        case .degraded: "Service is slow or unreliable."
        case .modelTrouble: "A model you use has an incident."
        case .overloaded: "Servers are overloaded."
        case .usageFailing: "Usage service failed."
        case .rateLimited: "Usage checks are rate limited."
        case .maintenance: "Service maintenance."
        case .statusUnknown: "Service status unavailable."
        case .apiChanged: "Cannot read usage response."
        case .botCheck: "Browser verification required."
        case .macOffline: "This Mac is offline."
        case .unreachable: "Cannot reach the provider."
        case .insecure: "Secure connection failed."
        case .signIn: "Sign in again."
        case .keychain: "Cannot open saved credentials."
        case .wrongAccount: "Login belongs to another account."
        case .permission: "Login cannot read usage."
        case .browserSession: "Browser session expired or missing."
        case .plan: "Plan ending or expired."
        case .billing: "Payment problem."
        case .spend: "Extra usage may incur charges."
        case .credits: "Prepaid credits running low."
        case .limit: "Allowance running out."
        case .notReported: "Limit or reset time missing."
        case .limitsChanged: "Quota period changed."
        case .behindPace: "Usage below even pace."
        case .aheadOfPace: "Usage above even pace."
        case .farAheadPace: "Usage far above even pace."
        case .spike: "Today’s usage is at least 3× the daily average."
        case .idle: "No usage for 7 days."
        case .resetLate: "Allowance still exhausted after reset."
        case .earlyReset: "Allowance reset early."
        case .newSavedReset: "Saved reset added."
        case .switching: "Account switch needs attention."
        case .allExhausted: "Every account has an exhausted allowance."
        case .usedElsewhere: "Usage rose without matching local requests."
        case .oldReading: "Usage reading is stale."
        case .partialReading: "Usage reading incomplete."
        case .unpriced: "Missing prices make spend incomplete."
        case .unattributed: "Some requests have no account identity."
        case .timeZone: "Time zone changed."
        case .unknownError: "Usage refresh failed."
        case .helper: "Required helper unavailable."
        case .update: "Update available."
        case .localLogs: "Unreadable logs make totals incomplete."
        case .folderAccess: "Cannot open usage-log folder."
        case .storage: "Cannot save usage history."
        case .notifications: "CodexBar notifications blocked."
        case .autoRefreshOff: "Automatic refresh off."
        case .refreshStuck: "Refresh taking over 2 minutes."
        case .unavailableHere: "Usage source unsupported here."
        }
    }

    var defaultAction: NativeOrbitWarningLight.Action {
        switch self {
        case .outage, .degraded, .modelTrouble, .overloaded, .usageFailing, .maintenance, .statusUnknown:
            .statusPage
        case .signIn: .signIn
        case .keychain, .wrongAccount, .permission, .browserSession, .helper, .folderAccess, .autoRefreshOff:
            .settings
        case .apiChanged, .unreachable, .oldReading, .unknownError, .refreshStuck: .refresh
        case .botCheck, .plan, .billing, .spend, .credits: .dashboard
        case .macOffline: .networkSettings
        case .notifications: .notificationSettings
        case .timeZone: .timeZoneSettings
        case .update: .checkForUpdates
        default: .details
        }
    }
}

extension NativeOrbitWarningLight {
    func resolvingAction(hasStatusPage: Bool, hasDashboard: Bool, canSignIn: Bool) -> Self {
        var light = self
        if light.action == .statusPage, !hasStatusPage { light.action = .dashboard }
        if light.action == .dashboard, !hasDashboard { light.action = .settings }
        if light.action == .signIn, !canSignIn { light.action = .settings }
        return light
    }

    var explanation: String {
        // Only concise copy supplied by our warning evaluators may replace catalogue wording.
        // Provider errors and status-page titles remain diagnostic detail, never hover text.
        let text = self.tooltipDetail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let condition = text.flatMap { $0.isEmpty ? nil : $0 } ?? self.kind.explanation
        return self.detail.hasPrefix("Projected:") ? "Projected: " + condition : condition
    }

    var actionTitle: String {
        switch self.action ?? self.kind.defaultAction {
        case .signIn: "Sign in again"
        case .statusPage: "Open service status"
        case .refresh: "Refresh usage"
        case .settings: "Open provider settings"
        case .dashboard: "Open dashboard"
        case .networkSettings: "Open Network settings"
        case .notificationSettings: "Open Notification settings"
        case .timeZoneSettings: "Open Date & Time settings"
        case .checkForUpdates: "Check for updates"
        case .details:
            switch self.kind {
            case .limit, .allExhausted: "Show allowance details"
            case .behindPace, .aheadOfPace, .farAheadPace, .spike, .idle: "Explain this usage pattern"
            case .earlyReset, .resetLate, .newSavedReset: "Show reset details"
            case .switching: "Show account switching details"
            case .usedElsewhere: "Explain the activity evidence"
            case .unpriced: "Explain the missing cost"
            case .unattributed: "Explain the missing account attribution"
            case .rateLimited: "Show retry details"
            case .insecure: "Explain the connection failure"
            case .storage, .localLogs: "Show history details"
            default: "Explain this reading"
            }
        }
    }

    func tooltip(account _: String?, includesAction _: Bool = true) -> String {
        self.explanation
    }
}
