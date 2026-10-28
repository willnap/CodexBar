import CodexBarCore
import Foundation

/// One lit warning light in an account's dial, in the manner of a car's dashboard: each has its own spot, it is
/// unlit (absent) while all is well, amber for a caution and red when the account cannot be read or used. Each symbol
/// shows its problem plainly; only the quota borrows the dashboard's fuel light, which already means "running out".
struct NativeOrbitWarningLight: Identifiable, Equatable {
    /// Stable catalogue order gives each signal its own physical light.
    enum Kind: Int, CaseIterable, Comparable, Sendable {
        case outage
        case degraded
        case modelTrouble
        case overloaded
        case usageFailing
        case rateLimited
        case maintenance
        case statusUnknown
        case apiChanged
        case botCheck
        case macOffline
        case unreachable
        case insecure
        case signIn
        case keychain
        case wrongAccount
        case permission
        case browserSession
        case plan
        case billing
        case spend
        case credits
        case limit
        case notReported
        case limitsChanged
        case behindPace
        case aheadOfPace
        case farAheadPace
        case spike
        case idle
        case resetLate
        case earlyReset
        case newSavedReset
        case switching
        case allExhausted
        case usedElsewhere
        case oldReading
        case partialReading
        case unpriced
        case unattributed
        case timeZone
        case unknownError
        case helper
        case update
        case localLogs
        case folderAccess
        case storage
        case notifications
        case autoRefreshOff
        case refreshStuck
        case unavailableHere

        static let quota = Self.limit
        static let providerIncident = Self.outage
        static let offline = Self.unreachable
        static let spendCap = Self.spend
        static let readFailed = Self.unknownError

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

        var catalogueKey: String {
            switch self {
            case .outage: "outage"
            case .degraded: "degraded"
            case .modelTrouble: "modelTrouble"
            case .overloaded: "overloaded"
            case .usageFailing: "usageFailing"
            case .rateLimited: "rateLimited"
            case .maintenance: "maintenance"
            case .statusUnknown: "statusUnknown"
            case .apiChanged: "apiChanged"
            case .botCheck: "botCheck"
            case .macOffline: "macOffline"
            case .unreachable: "unreachable"
            case .insecure: "insecure"
            case .signIn: "signIn"
            case .keychain: "keychain"
            case .wrongAccount: "wrongAccount"
            case .permission: "permission"
            case .browserSession: "browserSession"
            case .plan: "plan"
            case .billing: "billing"
            case .spend: "spend"
            case .credits: "credits"
            case .limit: "limit"
            case .notReported: "notReported"
            case .limitsChanged: "limitsChanged"
            case .behindPace: "behindPace"
            case .aheadOfPace: "aheadOfPace"
            case .farAheadPace: "farAheadPace"
            case .spike: "spike"
            case .idle: "idle"
            case .resetLate: "resetLate"
            case .earlyReset: "earlyReset"
            case .newSavedReset: "newSavedReset"
            case .switching: "switching"
            case .allExhausted: "allExhausted"
            case .usedElsewhere: "usedElsewhere"
            case .oldReading: "oldReading"
            case .partialReading: "partialReading"
            case .unpriced: "unpriced"
            case .unattributed: "unattributed"
            case .timeZone: "timeZone"
            case .unknownError: "unknownError"
            case .helper: "helper"
            case .update: "update"
            case .localLogs: "localLogs"
            case .folderAccess: "folderAccess"
            case .storage: "storage"
            case .notifications: "notifications"
            case .autoRefreshOff: "autoRefreshOff"
            case .refreshStuck: "refreshStuck"
            case .unavailableHere: "unavailableHere"
            }
        }

        var symbol: String {
            switch self {
            case .outage: "bolt.horizontal.fill"
            case .degraded: "hourglass"
            case .modelTrouble: "cpu.fill"
            case .overloaded: "person.3.fill"
            case .usageFailing: "chart.bar.xaxis"
            case .rateLimited: "hand.raised.fill"
            case .maintenance: "wrench.and.screwdriver.fill"
            case .statusUnknown: "icloud.dashed"
            case .apiChanged: "curlybraces"
            case .botCheck: "shield.fill"
            case .macOffline: "wifi.slash"
            case .unreachable: "network.slash"
            case .insecure: "lock.open.fill"
            case .signIn: "key.fill"
            case .keychain: "key.2.on.ring.fill"
            case .wrongAccount: "person.text.rectangle.fill"
            case .permission: "nosign"
            case .browserSession: "safari.fill"
            case .plan: "calendar"
            case .billing: "creditcard.fill"
            case .spend: "banknote.fill"
            case .credits: "creditcard.rewards.fill"
            case .limit: "fuelpump.fill"
            case .notReported: "questionmark"
            case .limitsChanged: "slider.horizontal.3"
            case .behindPace: "tortoise.fill"
            case .aheadOfPace: "hare.fill"
            case .farAheadPace: "flame.fill"
            case .spike: "waveform.path.ecg"
            case .idle: "zzz"
            case .resetLate: "alarm.fill"
            case .earlyReset: "clock.arrow.circlepath"
            case .newSavedReset: "gift.fill"
            case .switching: "arrow.left.arrow.right"
            case .allExhausted: "xmark.octagon.fill"
            case .usedElsewhere: "desktopcomputer.and.macbook"
            case .oldReading: "clock.fill"
            case .partialReading: "circle.lefthalf.filled"
            case .unpriced: "tag.slash.fill"
            case .unattributed: "person.slash.fill"
            case .timeZone: "globe.fill"
            case .unknownError: "exclamationmark.triangle.fill"
            case .helper: "terminal.fill"
            case .update: "arrow.down.to.line"
            case .localLogs: "doc.text.fill"
            case .folderAccess: "folder.fill"
            case .storage: "externaldrive.fill"
            case .notifications: "bell.slash.fill"
            case .autoRefreshOff: "autostartstop.slash"
            case .refreshStuck: "arrow.clockwise"
            case .unavailableHere: "app.slash.fill"
            }
        }

        var name: String {
            switch self {
            case .outage: "Outage"
            case .degraded: "Degraded"
            case .modelTrouble: "Model trouble"
            case .overloaded: "Overloaded"
            case .usageFailing: "Usage figures failing"
            case .rateLimited: "Rate limited"
            case .maintenance: "Maintenance"
            case .statusUnknown: "Status unknown"
            case .apiChanged: "Provider changed its data"
            case .botCheck: "Blocked by a bot check"
            case .macOffline: "This Mac is offline"
            case .unreachable: "Can’t reach the provider"
            case .insecure: "Secure connection failed"
            case .signIn: "Sign in again"
            case .keychain: "Keychain access blocked"
            case .wrongAccount: "Signed in as someone else"
            case .permission: "This login can’t read usage"
            case .browserSession: "Browser session unavailable"
            case .plan: "Plan ending or changed"
            case .billing: "Billing problem"
            case .spend: "Extra-usage spend"
            case .credits: "Credits low"
            case .limit: "Limit"
            case .notReported: "Not reported"
            case .limitsChanged: "Limits changed"
            case .behindPace: "Behind pace"
            case .aheadOfPace: "Ahead of pace"
            case .farAheadPace: "Far ahead of pace"
            case .spike: "Unusual usage"
            case .idle: "Account idle"
            case .resetLate: "Reset overdue"
            case .earlyReset: "Limits reset early"
            case .newSavedReset: "New saved reset"
            case .switching: "Switching"
            case .allExhausted: "No account has room"
            case .usedElsewhere: "Used on another device"
            case .oldReading: "Old reading"
            case .partialReading: "Partial reading"
            case .unpriced: "Some usage isn’t priced"
            case .unattributed: "History not tied to this account"
            case .timeZone: "Time zone changed"
            case .unknownError: "Something else went wrong"
            case .helper: "Helper not working"
            case .update: "Update needed"
            case .localLogs: "Local logs incomplete"
            case .folderAccess: "Log folder access lost"
            case .storage: "Can’t save history"
            case .notifications: "Notifications off"
            case .autoRefreshOff: "Auto refresh off"
            case .refreshStuck: "Refresh taking too long"
            case .unavailableHere: "Not available here"
            }
        }

        var category: String {
            switch self {
            case .outage: "service"
            case .degraded: "service"
            case .modelTrouble: "service"
            case .overloaded: "service"
            case .usageFailing: "service"
            case .rateLimited: "service"
            case .maintenance: "service"
            case .statusUnknown: "service"
            case .apiChanged: "service"
            case .botCheck: "service"
            case .macOffline: "connection"
            case .unreachable: "connection"
            case .insecure: "connection"
            case .signIn: "access"
            case .keychain: "access"
            case .wrongAccount: "access"
            case .permission: "access"
            case .browserSession: "access"
            case .plan: "billing"
            case .billing: "billing"
            case .spend: "billing"
            case .credits: "billing"
            case .limit: "limits"
            case .notReported: "limits"
            case .limitsChanged: "limits"
            case .behindPace: "pace"
            case .aheadOfPace: "pace"
            case .farAheadPace: "pace"
            case .spike: "pace"
            case .idle: "pace"
            case .resetLate: "resets"
            case .earlyReset: "resets"
            case .newSavedReset: "resets"
            case .switching: "accounts"
            case .allExhausted: "accounts"
            case .usedElsewhere: "accounts"
            case .oldReading: "reading"
            case .partialReading: "reading"
            case .unpriced: "reading"
            case .unattributed: "reading"
            case .timeZone: "reading"
            case .unknownError: "reading"
            case .helper: "codexbar"
            case .update: "codexbar"
            case .localLogs: "codexbar"
            case .folderAccess: "codexbar"
            case .storage: "codexbar"
            case .notifications: "codexbar"
            case .autoRefreshOff: "codexbar"
            case .refreshStuck: "codexbar"
            case .unavailableHere: "codexbar"
            }
        }

        /// The bulb check demonstrates the catalogue's green opportunities as well as amber/red faults.
        var bulbCheckSeverity: Severity {
            switch self {
            case .behindPace, .idle, .earlyReset, .newSavedReset, .timeZone, .autoRefreshOff, .maintenance, .update:
                .opportunity
            default: self.canBeCritical ? .critical : .caution
            }
        }

        var canBeCritical: Bool {
            [.outage, .signIn, .plan, .billing, .spend, .credits, .limit, .helper, .allExhausted].contains(self)
        }
    }

    enum Severity: Int, Comparable {
        case opportunity
        case caution
        case critical

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// What clicking the light does, when it has a fix.
    enum Action: Equatable {
        case signIn
        case statusPage
        case refresh
        case settings
        case dashboard
        case details
        case networkSettings
        case notificationSettings
        case timeZoneSettings
        case checkForUpdates
    }

    /// Provider state is not reconstructed from quota percentages, such as an explicit billing failure.
    enum Evidence: Equatable { case current, measurement, providerState }

    let kind: Kind
    var evidence: Evidence = .current
    /// Evidence-dependent faults cease when their original observation or quota cycle ends.
    var validUntil: Date?
    var severity: Severity
    /// One plain line: what is wrong, and when it helps, what to do.
    var detail: String
    /// Curated hover copy. Raw provider diagnostics must not be passed here.
    var tooltipDetail: String?
    var action: Action?

    var id: Kind {
        self.kind
    }

    init(
        _ kind: Kind,
        _ severity: Severity = .caution,
        _ detail: String,
        action: Action? = nil,
        tooltipDetail: String? = nil)
    {
        self.kind = kind
        self.severity = severity
        self.detail = detail
        self.tooltipDetail = tooltipDetail
        self.action = action ?? kind.defaultAction
    }

    /// One light per kind, the most severe reading of it, in spot order.
    static func merged(_ lights: [Self]) -> [Self] {
        var byKind: [Kind: Self] = [:]
        for light in lights {
            if let existing = byKind[light.kind] {
                if existing.severity > light.severity { continue }
                if existing.severity == light.severity,
                   let existingExpiry = existing.validUntil, let expiry = light.validUntil,
                   existingExpiry > expiry { continue }
            }
            byKind[light.kind] = light
        }
        return byKind.values.sorted { $0.kind < $1.kind }
    }
}

// MARK: - Fetch failures

/// The light a failed fetch turns on, from the error's type, never from wording.
enum NativeOrbitFetchFault {
    // swiftlint:disable:next cyclomatic_complexity
    static func light(for error: Error, provider: UsageProvider) -> NativeOrbitWarningLight? {
        if self.isCancellation(error) { return nil }
        let name = ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName
        let message = Self.message(error)
        if ProviderCredentialFailure.isAuthenticationFailure(error) {
            return Self.signInLight(name)
        }
        if ClaudeUsageError.isClaudeOAuthUsageRateLimit(error) {
            let retry: Date? = if case let ClaudeOAuthFetchError.rateLimited(retryAfter) = error {
                retryAfter
            } else {
                nil
            }
            return Self.rateLimited(name, retry: retry)
        }
        if let status = CodexRPCFailure.httpStatus(of: error) {
            return Self.http(status, name: name, message: message)
        }
        if CodexRPCFailure.isMalformedReply(error) { return Self.readFailed(message) }
        if CodexRPCFailure
            .isTimeout(error) { return .init(.helper, .caution, Self.condition(.helper), action: .refresh) }
        if CodexRPCFailure.isStartFailure(error) {
            return .init(.helper, .critical, Self.condition(.helper), action: .settings)
        }
        switch error {
        case let error as ProviderFetchClassifiedError:
            return switch error.kind {
            case .authenticationExpired, .missingCredential:
                Self.signInLight(name)
            case .permissionDenied:
                .init(.permission, .caution, Self.condition(.permission), action: .settings)
            case .rateLimited:
                Self.rateLimited(name, retry: error.retryAfterSeconds.map { Date().addingTimeInterval($0) })
            case .providerUnavailable, .apiFailure:
                Self.usageFailing(name, message)
            case .networkFailure:
                Self.offline(name, message)
            case .parseFailure:
                Self.readFailed(message)
            }
        case let error as ClaudeOAuthFetchError:
            switch error {
            case .unauthorized:
                return Self.signInLight(name)
            case let .rateLimited(retryAfter):
                return Self.rateLimited(name, retry: retryAfter)
            case .invalidResponse:
                return Self.readFailed(message)
            case let .serverError(code, _):
                return Self.http(code, name: name, message: message)
            case let .networkError(underlying):
                return Self.light(for: underlying, provider: provider) ?? Self.offline(name, message)
            }
        case let error as CodexOAuthFetchError:
            switch error {
            case .unauthorized:
                return Self.signInLight(name)
            case .invalidResponse:
                return Self.readFailed(message)
            case let .serverError(code, _):
                return Self.http(code, name: name, message: message)
            case let .networkError(underlying):
                return Self.light(for: underlying, provider: provider) ?? Self.offline(name, message)
            }
        case let error as KimiAPIError:
            switch error {
            case .missingToken, .invalidToken, .missingAPIKey, .invalidAPIKey, .expiredCodeCredential,
                 .invalidCodeCredential:
                return Self.signInLight(name)
            case .networkError:
                return Self.offline(name, message)
            case let .httpError(statusCode):
                return Self.http(statusCode, name: name, message: message)
            case .apiError:
                return Self.usageFailing(name, message)
            case .parseFailed, .invalidRequest:
                return Self.readFailed(message)
            }
        case let error as ClaudeWebAPIFetcher.FetchError:
            switch error {
            case .cloudflareChallenge:
                return .init(.botCheck, .caution, Self.condition(.botCheck), action: .settings)
            case .noSessionKeyFound, .noDesktopSessionKeyFound, .invalidSessionKey:
                return .init(.browserSession, .caution, Self.condition(.browserSession), action: .settings)
            case .unauthorized:
                return Self.signInLight(name)
            case .noOrganization, .organizationNotFound:
                return .init(.permission, .caution, Self.condition(.permission), action: .settings)
            case .notSupportedOnThisPlatform:
                return .init(.unavailableHere, .caution, Self.condition(.unavailableHere), action: .settings)
            case .invalidResponse:
                return Self.readFailed(message)
            case let .serverError(statusCode):
                return Self.http(statusCode, name: name, message: message)
            case let .networkError(underlying):
                return Self.light(for: underlying, provider: provider)
            }
        case let error as ClaudeOAuthCredentialsError:
            switch error {
            case .keychainAccessRevoked, .keychainError:
                return .init(.keychain, .caution, Self.condition(.keychain), action: .settings)
            case .credentialsChanged:
                return .init(.signIn, .caution, Self.condition(.signIn), action: .refresh)
            case .decodeFailed, .readFailed:
                return .init(.signIn, .critical, Self.condition(.signIn), action: .signIn)
            default:
                return .init(.unknownError, .caution, Self.condition(.unknownError), action: .refresh)
            }
        case let error as ClaudeAdminAPIUsageError:
            switch error {
            case .missingCredentials: return Self.signInLight(name)
            case let .apiError(_, statusCode): return Self.http(statusCode, name: name, message: message)
            case .networkError: return Self.offline(name, message)
            case .parseFailed: return Self.readFailed(message)
            }
        case let error as ClaudeStatusProbeError:
            switch error {
            case .authenticationFailed: return Self.signInLight(name)
            case .claudeNotInstalled, .timedOut: return .init(
                    .helper,
                    .caution,
                    Self.condition(.helper),
                    action: .settings)
            case .parseFailed: return Self.readFailed(message)
            }
        case CodexOAuthCredentialsError.notFound, CodexOAuthCredentialsError.unreadable,
             CodexOAuthCredentialsError.decodeFailed, CodexOAuthCredentialsError.missingTokens:
            return Self.signInLight(name)
        case ClaudeSwapListParserError.unsupportedSchemaVersion:
            return .init(.update, .caution, message, action: .settings)
        case ClaudeUsageError.claudeNotInstalled, ProviderFetchError.noAvailableStrategy:
            return .init(.helper, .critical, Self.condition(.helper), action: .settings)
        case is DecodingError:
            return Self.readFailed(message)
        case let error as URLError:
            return Self.transport(error.code, name: name, message: message)
        default:
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain {
                return Self.transport(URLError.Code(rawValue: nsError.code), name: name, message: message)
            }
            return .init(.unknownError, .caution, Self.condition(.unknownError), action: .refresh)
        }
    }

    private static func condition(_ kind: NativeOrbitWarningLight.Kind) -> String { kind.explanation }

    static func signInLight(_ provider: String) -> NativeOrbitWarningLight {
        .init(.signIn, .critical, self.signInDetail(provider), action: .signIn)
    }

    static func signInDetail(_ provider: String) -> String {
        "\(provider) rejected this login."
    }

    private static func http(_ code: Int, name: String, message: String) -> NativeOrbitWarningLight {
        switch code {
        case 401: .init(.signIn, .critical, self.signInDetail(name), action: .signIn)
        case 403: .init(.permission, .caution, self.condition(.permission), action: .settings)
        case 429: self.rateLimited(name, retry: nil)
        case 529: .init(.overloaded, .caution, self.condition(.overloaded))
        case 503 where message.contains("overloaded") || message.contains("Overloaded"):
            .init(.overloaded, .caution, self.condition(.overloaded))
        case 500...599: self.usageFailing(name, message)
        default: self.readFailed(message)
        }
    }

    private static func rateLimited(_ name: String, retry: Date?) -> NativeOrbitWarningLight {
        let detail = retry
            .map { "Usage checks are rate limited until \(NativeOrbitTooltip.moment($0, now: Date()))." }
            ?? "Usage checks are temporarily rate limited."
        return .init(.rateLimited, .caution, detail, tooltipDetail: retry.map {
            "Usage checks limited until \(NativeOrbitTooltip.moment($0, now: Date()))."
        })
    }

    private static func usageFailing(_ name: String, _ message: String) -> NativeOrbitWarningLight {
        .init(.usageFailing, .caution, "The usage service failed.", action: .statusPage)
    }

    private static func offline(_ name: String, _ message: String) -> NativeOrbitWarningLight {
        .init(.offline, .caution, "The provider could not be reached.", action: .refresh)
    }

    private static func readFailed(_ message: String) -> NativeOrbitWarningLight {
        .init(.apiChanged, .caution, "The usage response could not be read.", action: .refresh)
    }

    private static func message(_ error: Error) -> String {
        let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return line.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func transport(_ code: URLError.Code, name: String, message: String) -> NativeOrbitWarningLight {
        switch code {
        case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
             .clientCertificateRejected, .clientCertificateRequired:
            .init(.insecure, .caution, self.condition(.insecure))
        case .cannotParseResponse, .badServerResponse, .redirectToNonExistentLocation, .httpTooManyRedirects:
            self.readFailed(message)
        default:
            if self.isNetwork(code) {
                self.offline(name, message)
            } else {
                .init(.unknownError, .caution, self.condition(.unknownError), action: .refresh)
            }
        }
    }

    private static func isNetwork(_ code: URLError.Code) -> Bool {
        [
            .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
            .dnsLookupFailed, .timedOut, .internationalRoamingOff, .dataNotAllowed, .callIsActive,
            .secureConnectionFailed,
        ].contains(code)
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let error = error as? URLError, error.code == .cancelled { return true }
        if case let ClaudeOAuthFetchError.networkError(underlying) = error { return self.isCancellation(underlying) }
        if case let CodexOAuthFetchError.networkError(underlying) = error { return self.isCancellation(underlying) }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }
}
