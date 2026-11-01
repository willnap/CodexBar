import CodexBarCore
import Foundation

/// One decision drives the button, its disabled appearance, hover help and accessibility hint.
@MainActor
struct NativeAccountUsePresentation {
    enum UnavailableReason: Equatable {
        case noSavedLogin
        case unrecognizedStatus
        case readOnlySource
        case monitorOnly
        case busy
        case notReady
        case unverifiedLogin
        case configuration(String)
    }

    let showsUse: Bool
    let isEnabled: Bool
    let isSwitching: Bool
    let unavailableReason: UnavailableReason?

    static func showsFooter(accounts: [NativeOrbitAccountPresentation], canSignIn: Bool = false) -> Bool {
        accounts.contains {
            self.showsAccountFooter(account: $0, isIndividualColumn: false, accountCount: accounts.count)
                || ($0.updatedAt == nil && canSignIn)
        }
    }

    static func showsAccountFooter(
        account: NativeOrbitAccountPresentation,
        isIndividualColumn: Bool,
        accountCount: Int) -> Bool
    {
        isIndividualColumn || accountCount > 1 || !account.isActive
    }

    static func resolve(
        account: NativeOrbitAccountPresentation,
        inFlightID: String? = nil,
        switchingUnavailable: String? = nil,
        controllerAvailable: Bool = true) -> Self
    {
        if account.isActive {
            return Self(showsUse: false, isEnabled: false, isSwitching: false, unavailableReason: nil)
        }
        // Monitoring sources do not represent machine logins that this popup can switch.
        switch account.selection {
        case .none, .token:
            return Self(showsUse: false, isEnabled: false, isSwitching: false, unavailableReason: nil)
        // Provider-specific by design: only Codex and ClaudeSwap expose machine-login switch targets.
        case .codex, .claudeSwap:
            break
        }
        if inFlightID == account.id {
            return Self(showsUse: true, isEnabled: false, isSwitching: true, unavailableReason: nil)
        }
        let reason: UnavailableReason? = if !account.canActivate {
            self.reason(for: account.selection)
        } else if let restriction = switchingUnavailable?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !restriction.isEmpty
        {
            .configuration(restriction)
        } else if inFlightID != nil {
            .busy
        } else if !controllerAvailable {
            .notReady
        } else {
            nil
        }
        return Self(showsUse: true, isEnabled: reason == nil, isSwitching: false, unavailableReason: reason)
    }

    func help(loginTarget: String) -> String {
        if !self.showsUse { return L("Active %@ account", loginTarget) }
        if self.isSwitching { return L("Switching account…") }
        return switch self.unavailableReason {
        case .noSavedLogin: L("native_account_use_missing_login")
        case .unrecognizedStatus: L("native_account_use_unknown_status")
        case .readOnlySource: L("native_account_use_read_only")
        case .monitorOnly: L("native_account_use_monitor_only")
        case .busy: L("native_account_use_busy")
        case .notReady: L("native_account_use_not_ready")
        case .unverifiedLogin: L("native_account_use_unverified_login")
        case let .configuration(reason): reason
        case nil: L("Use in %@", loginTarget)
        }
    }

    private static func reason(for selection: NativeOrbitAccountSelection) -> UnavailableReason {
        switch selection {
        case let .claudeSwap(account):
            switch account.activationUnavailableReason {
            case .readOnlySource: .readOnlySource
            case .missingCredentials: .noSavedLogin
            case .unrecognizedStatus: .unrecognizedStatus
            case nil: .notReady
            }
        // Provider-specific by design: Codex distinguishes missing credentials from an unverified live login.
        case let .codex(account):
            if account.authFingerprint == nil || account.authenticationHealthLabel != nil {
                .noSavedLogin
            } else if account.isLive {
                .unverifiedLogin
            } else {
                .notReady
            }
        case .token, .none:
            .monitorOnly
        }
    }
}
