import Foundation

enum KeychainTestSafety {
    static let suppressAccessEnvironmentKey = "CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS"
    static let allowAccessEnvironmentKey = "CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS"

    /// One-shot side effects when this process decides keychain access is blocked:
    /// export the suppression variable so spawned children (debug CLI binaries,
    /// PTY helpers) inherit the decision — name-based self-detection cannot cover
    /// arbitrary child process names — and turn off legacy-keychain interaction
    /// process-wide so no code path can raise the login-keychain ACL dialog.
    private nonisolated(unsafe) static var didApplyBlockedProcessSideEffects = false
    private static let blockedProcessSideEffectsLock = NSLock()

    private static func applyBlockedProcessSideEffectsOnce() {
        self.blockedProcessSideEffectsLock.lock()
        defer { self.blockedProcessSideEffectsLock.unlock() }
        guard !self.didApplyBlockedProcessSideEffects else { return }
        self.didApplyBlockedProcessSideEffects = true
        setenv(self.suppressAccessEnvironmentKey, "1", 1)
        #if os(macOS)
        KeychainLegacyInteraction.disableProcessWideInteraction()
        #endif
    }

    static func shouldBlockRealKeychainAccess(
        processName: String = ProcessInfo.processInfo.processName,
        environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool
    {
        let blocked = self.resolveShouldBlockRealKeychainAccess(
            processName: processName,
            environment: environment)
        if blocked {
            self.applyBlockedProcessSideEffectsOnce()
        }
        return blocked
    }

    /// Pure decision, side-effect free; kept separate for tests.
    static func resolveShouldBlockRealKeychainAccess(
        processName: String,
        environment: [String: String]) -> Bool
    {
        if environment[self.allowAccessEnvironmentKey] == "1" { return false }
        if environment[self.suppressAccessEnvironmentKey] == "1" { return true }
        if environment[KeychainAccessGate.disableAccessEnvironmentKey] == "1" { return true }
        return self.isRunningUnderTests(processName: processName, environment: environment)
    }

    static func shouldIsolateUserStateUnderTests(
        processName: String = ProcessInfo.processInfo.processName,
        environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool
    {
        guard environment[self.allowAccessEnvironmentKey] != "1" else { return false }
        return self.isRunningUnderTests(processName: processName, environment: environment)
    }

    static func isRunningUnderTests(
        processName: String,
        environment: [String: String]) -> Bool
    {
        TestProcessSafety.isRunningUnderTests(
            processName: processName,
            environment: environment)
    }
}

#if os(macOS)
import LocalAuthentication
import Security

/// Process-wide legacy-keychain interaction switch. `KeychainNoUIQuery` marks
/// individual queries non-interactive, but the repo has observed legacy ACL
/// dialogs surfacing regardless (see KeychainAccessPreflight); for processes
/// that must never prompt — test runners and suppressed children — flipping the
/// documented process-wide switch is the airtight variant. Resolved via dlsym
/// to avoid deprecation warnings, matching the existing pattern in
/// KeychainNoUIQuery/KeychainCacheStore.
enum KeychainLegacyInteraction {
    private typealias SetUserInteractionAllowedFn = @convention(c) (DarwinBoolean) -> OSStatus
    private typealias GetUserInteractionAllowedFn = @convention(c) (UnsafeMutablePointer<DarwinBoolean>) -> OSStatus
    private static let interactionLock = NSRecursiveLock()
    private static let log = CodexBarLog.logger(LogCategories.keychainCache)

    final class Driver: @unchecked Sendable {
        let read: @Sendable () -> (OSStatus, Bool)
        let set: @Sendable (Bool) -> OSStatus
        // Protected by interactionLock, including permanent test suppression.
        var permanentlyDisabled = false
        var restorationFailed = false

        init(
            read: @escaping @Sendable () -> (OSStatus, Bool),
            set: @escaping @Sendable (Bool) -> OSStatus)
        {
            self.read = read
            self.set = set
        }
    }

    private static let systemDriver = Driver(
        read: {
            guard let get = Self.securityFunction(
                named: "SecKeychainGetUserInteractionAllowed", as: GetUserInteractionAllowedFn.self)
            else { return (errSecInternalComponent, false) }
            var allowed = DarwinBoolean(false)
            let status = get(&allowed)
            return (status, allowed.boolValue)
        },
        set: { allowed in
            guard let set = Self.securityFunction(
                named: "SecKeychainSetUserInteractionAllowed", as: SetUserInteractionAllowedFn.self)
            else { return errSecInternalComponent }
            return set(DarwinBoolean(allowed))
        })

    #if DEBUG
    @TaskLocal static var driverOverrideForTesting: Driver?
    #endif

    static func disableProcessWideInteraction(driver: Driver? = nil) {
        self.interactionLock.lock()
        defer { self.interactionLock.unlock() }
        let driver = driver ?? self.systemDriver
        driver.permanentlyDisabled = true
        _ = driver.set(false)
    }

    /// File-based Keychains can ignore SecItem's per-query no-UI flags (FB16959400).
    /// Serialize all first-party item operations, including interactive ones, while a no-UI
    /// operation temporarily suppresses legacy UI. Never enable UI for an interactive query.
    static func performItemOperation(query: CFDictionary, operation: () -> OSStatus) -> OSStatus {
        self.interactionLock.lock()
        defer { self.interactionLock.unlock() }
        #if DEBUG
        let driver = self.driverOverrideForTesting ?? self.systemDriver
        #else
        let driver = self.systemDriver
        #endif
        guard self.requiresNoUI(query: query) else {
            guard !driver.restorationFailed else { return errSecInteractionNotAllowed }
            return operation()
        }
        let (readStatus, wasAllowed) = driver.read()
        guard readStatus == errSecSuccess else { return errSecInteractionNotAllowed }
        guard !wasAllowed || driver.set(false) == errSecSuccess else { return errSecInteractionNotAllowed }
        defer {
            if wasAllowed {
                let status = driver.set(driver.permanentlyDisabled ? false : wasAllowed)
                if status != errSecSuccess {
                    // A completed mutation cannot be rolled back. Keep subsequent operations
                    // non-interactive rather than claiming the original UI state was restored.
                    driver.permanentlyDisabled = true
                    driver.restorationFailed = true
                    _ = driver.set(false)
                    self.log.error("Failed to restore legacy Keychain interaction state: \(status)")
                }
            }
        }
        return operation()
    }

    private static func requiresNoUI(query: CFDictionary) -> Bool {
        guard let query = query as? [String: Any] else { return false }
        if (query[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed == true {
            return true
        }
        return query[kSecUseAuthenticationUI as String] as? String == KeychainNoUIQuery.uiFailPolicyForTesting()
    }

    private static func securityFunction<T>(named name: String, as _: T.Type) -> T? {
        guard let handle = dlopen(
            "/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY | RTLD_NOLOAD)
        else { return nil }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, name) else { return nil }
        return unsafeBitCast(symbol, to: T.self)
    }
}

/// Records whether a Keychain read in the current fetch failed the way a locked keychain does. The CLI binds one per
/// provider fetch (task-local, so concurrent fetches stay apart) to tell a locked-keychain failure from any other.
public final class KeychainLockWitness: @unchecked Sendable {
    @TaskLocal public static var current: KeychainLockWitness?

    private let lock = NSLock()
    private var observed = false

    public init() {}

    public var didObserveLockedKeychain: Bool {
        self.lock.withLock { self.observed }
    }

    static func note(_ status: OSStatus) {
        guard status == errSecInteractionNotAllowed || status == errSecAuthFailed,
              let witness = self.current
        else { return }
        witness.lock.withLock { witness.observed = true }
    }
}

/// The only first-party entry point for Security.framework item operations.
/// Test processes fail closed before touching the user's Keychain, even when a test enables
/// higher-level Keychain logic with `KeychainAccessGate.withTaskOverrideForTesting(false)`.
public enum KeychainSecurity {
    #if DEBUG
    enum Mutation: Equatable, Sendable {
        case add, delete, update
    }

    @TaskLocal static var copyMatchingOverrideForTesting: (@Sendable ([String: Any]) -> OSStatus)?
    @TaskLocal static var mutationOverrideForTesting: (@Sendable (Mutation, [String: Any]) -> OSStatus)?
    #endif

    enum ItemOperationBlockReason: Equatable {
        case keychainAccessDisabled
        case testSafetySuppressed
    }

    static func itemOperationBlockReason(
        keychainAccessDisabled: Bool,
        testSafetyBlocked: Bool) -> ItemOperationBlockReason?
    {
        if keychainAccessDisabled { return .keychainAccessDisabled }
        if testSafetyBlocked { return .testSafetySuppressed }
        return nil
    }

    private static func currentItemOperationBlockReason() -> ItemOperationBlockReason? {
        self.itemOperationBlockReason(
            keychainAccessDisabled: KeychainAccessGate.isDisabled,
            testSafetyBlocked: KeychainTestSafety.shouldBlockRealKeychainAccess())
    }

    public static func copyMatching(
        _ query: CFDictionary,
        _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    {
        #if DEBUG
        if let override = self.copyMatchingOverrideForTesting {
            return KeychainLegacyInteraction.performItemOperation(query: query) {
                override(query as? [String: Any] ?? [:])
            }
        }
        #endif
        guard self.currentItemOperationBlockReason() == nil else {
            return errSecInteractionNotAllowed
        }
        let status = KeychainLegacyInteraction.performItemOperation(query: query) {
            SecItemCopyMatching(query, result)
        }
        KeychainLockWitness.note(status)
        return status
    }

    public static func update(_ query: CFDictionary, _ attributesToUpdate: CFDictionary) -> OSStatus {
        #if DEBUG
        if let override = self.mutationOverrideForTesting {
            return KeychainLegacyInteraction.performItemOperation(query: query) {
                override(.update, query as? [String: Any] ?? [:])
            }
        }
        #endif
        guard self.currentItemOperationBlockReason() == nil else {
            return errSecInteractionNotAllowed
        }
        return KeychainLegacyInteraction.performItemOperation(query: query) {
            SecItemUpdate(query, attributesToUpdate)
        }
    }

    public static func add(
        _ attributes: CFDictionary,
        _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    {
        #if DEBUG
        if let override = self.mutationOverrideForTesting {
            return KeychainLegacyInteraction.performItemOperation(query: attributes) {
                override(.add, attributes as? [String: Any] ?? [:])
            }
        }
        #endif
        guard self.currentItemOperationBlockReason() == nil else {
            return errSecInteractionNotAllowed
        }
        return KeychainLegacyInteraction.performItemOperation(query: attributes) {
            SecItemAdd(attributes, result)
        }
    }

    public static func delete(_ query: CFDictionary) -> OSStatus {
        #if DEBUG
        if let override = self.mutationOverrideForTesting {
            return KeychainLegacyInteraction.performItemOperation(query: query) {
                override(.delete, query as? [String: Any] ?? [:])
            }
        }
        #endif
        guard self.currentItemOperationBlockReason() == nil else {
            return errSecInteractionNotAllowed
        }
        return KeychainLegacyInteraction.performItemOperation(query: query) {
            SecItemDelete(query)
        }
    }
}
#endif
