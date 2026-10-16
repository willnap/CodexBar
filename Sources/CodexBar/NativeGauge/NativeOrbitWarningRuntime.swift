import CodexBarCore
import Foundation

/// Transient provider telemetry shares UsageStore's observation lifetime; credentials never enter this state.
struct NativeOrbitWarningRuntime {
    var authenticationFailures: Set<CredentialNotificationKey> = []
    var fetchFaults: [CredentialNotificationKey: NativeOrbitWarningLight] = [:]
    var statusFetchFailures: Set<ProviderInstanceID> = []
    var refreshStartedAt: [ProviderInstanceID: Date] = [:]
    var slowRefreshProviders: Set<ProviderInstanceID> = []
    var claudeSwapFault: NativeOrbitWarningLight?
}

extension UsageStore {
    var nativeAuthenticationFailures: Set<CredentialNotificationKey> {
        get { self.nativeWarningRuntime.authenticationFailures }
        set { self.nativeWarningRuntime.authenticationFailures = newValue }
    }

    var nativeFetchFaults: [CredentialNotificationKey: NativeOrbitWarningLight] {
        get { self.nativeWarningRuntime.fetchFaults }
        set { self.nativeWarningRuntime.fetchFaults = newValue }
    }

    var nativeStatusFetchFailures: Set<ProviderInstanceID> {
        get { self.nativeWarningRuntime.statusFetchFailures }
        set { self.nativeWarningRuntime.statusFetchFailures = newValue }
    }

    var nativeWarningRefreshStartedAt: [ProviderInstanceID: Date] {
        get { self.nativeWarningRuntime.refreshStartedAt }
        set { self.nativeWarningRuntime.refreshStartedAt = newValue }
    }

    var nativeWarningSlowRefreshProviders: Set<ProviderInstanceID> {
        get { self.nativeWarningRuntime.slowRefreshProviders }
        set { self.nativeWarningRuntime.slowRefreshProviders = newValue }
    }

    var nativeClaudeSwapFault: NativeOrbitWarningLight? {
        get { self.nativeWarningRuntime.claudeSwapFault }
        set { self.nativeWarningRuntime.claudeSwapFault = newValue }
    }
}
