import CodexBarCore
import Foundation

/// One lit warning light in an account's dial, in the manner of a car's dashboard: each has its own spot, it is
/// unlit (absent) while all is well, amber for a caution and red when the account cannot be read or used. Each symbol
/// shows its problem plainly; only the quota borrows the dashboard's fuel light, which already means "running out".
struct NativeOrbitWarningLight: Identifiable, Equatable {
    /// Each light has one meaning and its own spot. The order is the spots': down the left of the marks (the account's
    /// login and the provider's side), then down the right (the account's usage and our reading of it).
    enum Kind: Int, CaseIterable, Comparable {
        /// The account's login is expired, missing, rejected or belongs to someone else.
        case signIn
        /// The provider reports an incident, or its usage service is failing.
        case providerIncident
        /// The provider's scheduled maintenance.
        case maintenance
        /// The provider is rate limiting usage requests.
        case rateLimited
        /// The provider could not be reached.
        case offline
        /// Switching accounts failed, is waiting, or this setup cannot switch.
        case switching
        /// A limit runs out before it resets at the current pace (amber), or has run out (red).
        case quota
        /// The account's extra-usage spend is near (amber) or at (red) its cap.
        case spendCap
        /// A reading failed on our side: an unreadable response or a probe that did not finish.
        case readFailed
        /// A command-line helper CodexBar drives (claude-swap, a provider CLI) is missing or failing.
        case helper
        /// Token and spend totals are partial: reading this Mac's usage logs stopped short.
        case localLogs
        /// The reading shown is older than it should be.
        case oldReading

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        var symbol: String {
            switch self {
            case .signIn: "person.crop.circle.badge.exclamationmark.fill"
            case .providerIncident: "exclamationmark.icloud.fill"
            case .maintenance: "wrench.and.screwdriver.fill"
            case .rateLimited: "hand.raised.fill"
            case .offline: "wifi.exclamationmark"
            case .switching: "exclamationmark.arrow.triangle.2.circlepath"
            case .quota: "fuelpump.fill"
            case .spendCap: "creditcard.trianglebadge.exclamationmark.fill"
            case .readFailed: "exclamationmark.triangle.fill"
            case .helper: "terminal.fill"
            case .localLogs: "folder.fill.badge.questionmark"
            case .oldReading: "clock.badge.exclamationmark.fill"
            }
        }

        /// What the light is called, for VoiceOver.
        var name: String {
            switch self {
            case .signIn: "Sign-in problem"
            case .providerIncident: "Provider incident"
            case .maintenance: "Provider maintenance"
            case .rateLimited: "Rate limited"
            case .offline: "Can't reach provider"
            case .switching: "Switching problem"
            case .quota: "Limit"
            case .spendCap: "Spend cap"
            case .readFailed: "Reading failed"
            case .helper: "Helper problem"
            case .localLogs: "Partial totals"
            case .oldReading: "Old reading"
            }
        }

        /// Lights that can turn red: the account cannot be read or used.
        var canBeCritical: Bool {
            [.signIn, .providerIncident, .quota, .spendCap, .helper].contains(self)
        }
    }

    enum Severity: Int, Comparable {
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
    }

    let kind: Kind
    var severity: Severity
    /// One plain line: what is wrong, and when it helps, what to do.
    var detail: String
    var action: Action?

    var id: Kind {
        self.kind
    }

    init(_ kind: Kind, _ severity: Severity = .caution, _ detail: String, action: Action? = nil) {
        self.kind = kind
        self.severity = severity
        self.detail = detail
        self.action = action
    }

    /// One light per kind, the most severe reading of it, in spot order.
    static func merged(_ lights: [Self]) -> [Self] {
        var byKind: [Kind: Self] = [:]
        for light in lights {
            if let existing = byKind[light.kind], existing.severity >= light.severity { continue }
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
        if CodexRPCFailure.isStartFailure(error) {
            return .init(.helper, .critical, message, action: .settings)
        }
        switch error {
        case let error as ProviderFetchClassifiedError:
            return switch error.kind {
            case .authenticationExpired, .missingCredential, .permissionDenied:
                Self.signInLight(name)
            case .rateLimited:
                Self.rateLimited(name, retry: error.retryAfterSeconds.map { Date().addingTimeInterval($0) })
            case .providerUnavailable, .apiFailure:
                Self.providerIncident(name, message)
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
            case .apiError:
                return Self.providerIncident(name, message)
            case .parseFailed, .invalidRequest:
                return Self.readFailed(message)
            }
        case ClaudeUsageError.claudeNotInstalled, ProviderFetchError.noAvailableStrategy:
            return .init(.helper, .critical, message, action: .settings)
        case is DecodingError:
            return Self.readFailed(message)
        case let error as URLError:
            return Self.isNetwork(error.code) ? Self.offline(name, message) : Self.readFailed(message)
        default:
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain, Self.isNetwork(URLError.Code(rawValue: nsError.code)) {
                return Self.offline(name, message)
            }
            return Self.readFailed(message)
        }
    }

    static func signInLight(_ provider: String) -> NativeOrbitWarningLight {
        .init(.signIn, .critical, self.signInDetail(provider), action: .signIn)
    }

    static func signInDetail(_ provider: String) -> String {
        "\(provider) rejected this login. Sign in again to read its usage."
    }

    private static func http(_ code: Int, name: String, message: String) -> NativeOrbitWarningLight {
        switch code {
        case 401, 403: .init(.signIn, .critical, self.signInDetail(name), action: .signIn)
        case 429: self.rateLimited(name, retry: nil)
        case 500...599: self.providerIncident(name, message)
        default: self.readFailed(message)
        }
    }

    private static func rateLimited(_ name: String, retry: Date?) -> NativeOrbitWarningLight {
        let detail = retry
            .map { "\(name) is rate limiting usage checks until \(NativeOrbitTooltip.moment($0, now: Date()))." }
            ?? "\(name) is rate limiting usage checks. CodexBar retries on its next refresh."
        return .init(.rateLimited, .caution, detail)
    }

    private static func providerIncident(_ name: String, _ message: String) -> NativeOrbitWarningLight {
        .init(.providerIncident, .caution, "\(name)’s usage maintenance failed: \(message)", action: .statusPage)
    }

    private static func offline(_ name: String, _ message: String) -> NativeOrbitWarningLight {
        .init(.offline, .caution, "Couldn’t reach \(name): \(message)", action: .refresh)
    }

    private static func readFailed(_ message: String) -> NativeOrbitWarningLight {
        .init(.readFailed, .caution, "Couldn’t read usage: \(message)", action: .refresh)
    }

    private static func message(_ error: Error) -> String {
        let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return line.trimmingCharacters(in: .whitespacesAndNewlines)
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
