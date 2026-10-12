#if os(macOS)
import Foundation
import LocalAuthentication
import Security
import Testing
@testable import CodexBarCore

struct KeychainLegacyInteractionTests {
    @Test(arguments: [KeychainSecurity.Mutation.add, .update, .delete])
    func `background cache mutations suppress legacy UI and restore its prior state`(
        mutation: KeychainSecurity.Mutation)
    {
        let allowed = LockIsolated(true)
        let transitions = LockIsolated<[Bool]>([])
        let driver = KeychainLegacyInteraction.Driver(
            read: { (errSecSuccess, allowed.value) },
            set: { value in
                transitions.setValue(transitions.value + [value])
                allowed.setValue(value)
                return errSecSuccess
            })
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword]
        KeychainNoUIQuery.apply(to: &query)
        KeychainLegacyInteraction.$driverOverrideForTesting.withValue(driver) {
            let override: @Sendable (KeychainSecurity.Mutation, [String: Any]) -> OSStatus = { actualMutation, _ in
                #expect(actualMutation == mutation)
                #expect(!allowed.value, "Legacy Keychain UI must be disabled during background cache access")
                return errSecSuccess
            }
            KeychainSecurity.$mutationOverrideForTesting.withValue(override) {
                let status = switch mutation {
                case .add: KeychainSecurity.add(query as CFDictionary, nil)
                case .update: KeychainSecurity.update(query as CFDictionary, [:] as CFDictionary)
                case .delete: KeychainSecurity.delete(query as CFDictionary)
                }
                #expect(status == errSecSuccess)
            }
        }
        #expect(allowed.value)
        #expect(transitions.value == [false, true])
    }

    @Test(arguments: [true, false], [errSecSuccess, errSecAuthFailed])
    func `no UI reads preserve previous interaction state on success and failure`(
        initiallyAllowed: Bool, operationStatus: OSStatus)
    {
        let allowed = LockIsolated(initiallyAllowed)
        let changes = LockIsolated<[Bool]>([])
        let driver = KeychainLegacyInteraction.Driver(
            read: { (errSecSuccess, allowed.value) },
            set: { value in
                changes.setValue(changes.value + [value])
                allowed.setValue(value)
                return errSecSuccess
            })
        var query: [String: Any] = [:]
        KeychainNoUIQuery.apply(to: &query)
        let status = KeychainLegacyInteraction.$driverOverrideForTesting.withValue(driver) {
            let override: @Sendable ([String: Any]) -> OSStatus = { _ in
                #expect(!allowed.value)
                return operationStatus
            }
            return KeychainSecurity.$copyMatchingOverrideForTesting.withValue(override) {
                KeychainSecurity.copyMatching(query as CFDictionary, nil)
            }
        }
        #expect(status == operationStatus)
        #expect(allowed.value == initiallyAllowed)
        #expect(changes.value == (initiallyAllowed ? [false, true] : []))
    }

    @Test(arguments: [true, false])
    func `unknown or unchangeable legacy UI state skips the secret operation`(getterFails: Bool) {
        let calls = LockIsolated(0)
        let driver = KeychainLegacyInteraction.Driver(
            read: { (getterFails ? errSecAuthFailed : errSecSuccess, true) },
            set: { _ in errSecAuthFailed })
        var query: [String: Any] = [:]
        KeychainNoUIQuery.apply(to: &query)
        let status = KeychainLegacyInteraction.$driverOverrideForTesting.withValue(driver) {
            let override: @Sendable ([String: Any]) -> OSStatus = { _ in
                calls.setValue(calls.value + 1)
                return errSecSuccess
            }
            return KeychainSecurity.$copyMatchingOverrideForTesting.withValue(override) {
                KeychainSecurity.copyMatching(query as CFDictionary, nil)
            }
        }
        #expect(status == errSecInteractionNotAllowed)
        #expect(calls.value == 0)
    }

    @Test(arguments: [true, false])
    func `explicit user actions do not change the legacy UI policy`(initiallyAllowed: Bool) {
        let changes = LockIsolated(0)
        let driver = KeychainLegacyInteraction.Driver(
            read: { Issue.record("Interactive queries must not read or change the UI policy"); return (0, true) },
            set: { _ in changes.setValue(changes.value + 1); return errSecSuccess })
        let status = KeychainLegacyInteraction.$driverOverrideForTesting.withValue(driver) {
            let override: @Sendable ([String: Any]) -> OSStatus = { _ in
                initiallyAllowed ? errSecSuccess : errSecInteractionNotAllowed
            }
            return KeychainSecurity.$copyMatchingOverrideForTesting.withValue(override) {
                KeychainSecurity.copyMatching([:] as CFDictionary, nil)
            }
        }
        #expect(status == (initiallyAllowed ? errSecSuccess : errSecInteractionNotAllowed))
        #expect(changes.value == 0)
    }

    @Test
    func `nested permanent suppression is never undone by scoped restoration`() {
        let allowed = LockIsolated(true)
        let changes = LockIsolated<[Bool]>([])
        let driver = KeychainLegacyInteraction.Driver(
            read: { (errSecSuccess, allowed.value) },
            set: { value in
                allowed.setValue(value)
                changes.setValue(changes.value + [value])
                return errSecSuccess
            })
        var query: [String: Any] = [:]
        KeychainNoUIQuery.apply(to: &query)
        KeychainLegacyInteraction.$driverOverrideForTesting.withValue(driver) {
            _ = KeychainLegacyInteraction.performItemOperation(query: query as CFDictionary) {
                KeychainLegacyInteraction.disableProcessWideInteraction(driver: driver)
                return errSecSuccess
            }
        }
        #expect(!allowed.value)
        #expect(!changes.value.contains(true))
    }

    @Test
    func `restore failure preserves mutation result and fails closed afterwards`() {
        let allowed = LockIsolated(true)
        let driver = KeychainLegacyInteraction.Driver(
            read: { (errSecSuccess, allowed.value) },
            set: { value in
                guard !value else { return errSecAuthFailed }
                allowed.setValue(false)
                return errSecSuccess
            })
        var query: [String: Any] = [:]
        KeychainNoUIQuery.apply(to: &query)
        let status = KeychainLegacyInteraction.$driverOverrideForTesting.withValue(driver) {
            KeychainLegacyInteraction.performItemOperation(query: query as CFDictionary) { errSecSuccess }
        }
        #expect(status == errSecSuccess)
        #expect(!allowed.value)
        #expect(driver.permanentlyDisabled)
        let subsequentOperationCalled = LockIsolated(false)
        let subsequentStatus = KeychainLegacyInteraction.$driverOverrideForTesting.withValue(driver) {
            KeychainLegacyInteraction.performItemOperation(query: [:] as CFDictionary) {
                subsequentOperationCalled.setValue(true)
                return errSecSuccess
            }
        }
        #expect(subsequentStatus == errSecInteractionNotAllowed)
        #expect(!subsequentOperationCalled.value)
    }

    @Test
    func `interactive calls wait until the background operation restores its policy`() {
        let allowed = LockIsolated(true)
        let driver = KeychainLegacyInteraction.Driver(
            read: { (errSecSuccess, allowed.value) },
            set: { value in allowed.setValue(value); return errSecSuccess })
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)
        let waiting = DispatchSemaphore(value: 0)
        let interactiveCompleted = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            KeychainLegacyInteraction.$driverOverrideForTesting.withValue(driver) {
                let query: [String: Any] = [
                    kSecUseAuthenticationUI as String: KeychainNoUIQuery.uiFailPolicyForTesting(),
                ]
                _ = KeychainLegacyInteraction.performItemOperation(query: query as CFDictionary) {
                    #expect(!allowed.value)
                    entered.signal()
                    #expect(release.wait(timeout: .now() + 5) == .success)
                    return errSecSuccess
                }
            }
            completed.signal()
        }
        #expect(entered.wait(timeout: .now() + 5) == .success)
        DispatchQueue.global().async {
            KeychainLegacyInteraction.$driverOverrideForTesting.withValue(driver) {
                waiting.signal()
                _ = KeychainLegacyInteraction.performItemOperation(query: [:] as CFDictionary) {
                    #expect(allowed.value)
                    return errSecSuccess
                }
            }
            interactiveCompleted.signal()
        }
        #expect(waiting.wait(timeout: .now() + 5) == .success)
        #expect(interactiveCompleted.wait(timeout: .now() + 0.02) == .timedOut)
        release.signal()
        #expect(completed.wait(timeout: .now() + 5) == .success)
        #expect(interactiveCompleted.wait(timeout: .now() + 5) == .success)
    }
}
#endif
