import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@Suite(.serialized, CodexCredentialFixtures())
@MainActor
struct NativeCodexProfileImportTests {
    @Test func `profile import and promotion preserve source and displaced live login`() async throws {
        let fixture = try CodexAccountPromotionTestContainer(suiteName: "native-profile-promotion")
        defer { fixture.tearDown() }
        let profile = try self.profile(fixture)
        let source = try CodexAuthFingerprint.authFileURL(homePath: self.path(profile))
        let original = try Data(contentsOf: source)
        let displaced = try fixture.writeLiveOAuthAuthFile(email: "live@example.com", accountID: "live-workspace")
        let imported = try self.importer(fixture).importProfile(profile)
        #expect(try imported.managedHomePath != self.path(profile))
        #expect(try fixture.managedAuthData(for: imported) == original)
        let saved = try #require(fixture.settings.codexVisibleAccountProjection.visibleAccounts.first {
            $0.storedAccountID == imported.id
        })
        let result = await CodexAccountPromotionCoordinator(service: fixture.makeService())
            .promote(managedAccountID: imported.id)
        guard case .success = result else {
            Issue.record("Expected imported profile promotion to succeed")
            return
        }
        #expect(try Data(contentsOf: source) == original)
        #expect(try fixture.liveAuthData() == original)
        let preserved = try #require(fixture.loadAccounts().accounts.first { $0.id != imported.id })
        #expect(try fixture.managedAuthData(for: preserved) == displaced)
        #expect(NativeAccountActivationVerification.codexOwnsLogin(
            saved, projection: fixture.settings.codexVisibleAccountProjection))
        let attributes = try FileManager.default.attributesOfItem(atPath: CodexAuthFingerprint.authFileURL(
            homePath: imported.managedHomePath).path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func `repeat profile import reuses exact saved owner without duplicating accounts`() throws {
        let fixture = try CodexAccountPromotionTestContainer(suiteName: "native-profile-repeat")
        defer { fixture.tearDown() }
        let profile = try self.profile(fixture)
        let first = try self.importer(fixture).importProfile(profile)
        let repeated = try self.importer(fixture).importProfile(profile)
        #expect(first.id == repeated.id)
        #expect(try fixture.loadAccounts().accounts.count == 1)
    }

    @Test func `changed profile selection never imports stale ownership`() throws {
        let fixture = try CodexAccountPromotionTestContainer(suiteName: "native-profile-stale")
        defer { fixture.tearDown() }
        let profile = try self.profile(fixture)
        try Data("changed-fixture".utf8).write(to: CodexAuthFingerprint.authFileURL(homePath: self.path(profile)))
        #expect(throws: NativeCodexProfileImportError.self) {
            try self.importer(fixture).importProfile(profile)
        }
        #expect(try fixture.loadAccounts().accounts.isEmpty)
    }

    @Test func `profile changed during copy leaves no committed managed account`() throws {
        let fixture = try CodexAccountPromotionTestContainer(suiteName: "native-profile-copy-race")
        defer { fixture.tearDown() }
        let profile = try self.profile(fixture)
        let source = try CodexAuthFingerprint.authFileURL(homePath: self.path(profile))
        let mutateProfile: @Sendable (URL) throws -> Void = { destination in
            if destination.lastPathComponent == "auth.json" {
                try Data("changed-fixture".utf8).write(to: source)
            }
        }
        CredentialFileWriter.$beforePublishForTesting.withValue(mutateProfile) {
            #expect(throws: NativeCodexProfileImportError.self) {
                try self.importer(fixture).importProfile(profile)
            }
        }
        #expect(try fixture.loadAccounts().accounts.isEmpty)
    }

    @Test func `import refresh exposes durable account even with production reconciliation caching`() throws {
        let fixture = try CodexAccountPromotionTestContainer(suiteName: "native-profile-cached")
        defer { fixture.tearDown() }
        SettingsStore.codexAccountReconciliationSnapshotCacheIntervalOverrideForTesting = 60
        defer { SettingsStore.codexAccountReconciliationSnapshotCacheIntervalOverrideForTesting = nil }
        let profile = try self.profile(fixture)
        _ = fixture.settings.codexVisibleAccountProjection
        let imported = try self.importer(fixture).importProfile(profile)
        _ = fixture.settings.refreshCodexAccountReconciliationAfterManagedAccountsDidChange()
        #expect(fixture.settings.codexVisibleAccountProjection.visibleAccounts.contains {
            $0.storedAccountID == imported.id
        })
    }

    private func importer(_ fixture: CodexAccountPromotionTestContainer) -> NativeCodexProfileImporter {
        NativeCodexProfileImporter(store: fixture.fileStore, homeFactory: fixture.homeFactory)
    }

    private func profile(_ fixture: CodexAccountPromotionTestContainer) throws -> CodexVisibleAccount {
        let auth = try fixture.createManagedAccount(
            persistedEmail: "profile@example.com", authAccountID: "profile-workspace")
        return CodexVisibleAccount(
            id: "profile:\(auth.managedHomePath)",
            email: auth.email,
            workspaceAccountID: auth.effectiveWorkspaceAccountID,
            authFingerprint: auth.authFingerprint,
            storedAccountID: nil,
            selectionSource: .profileHome(path: auth.managedHomePath),
            isActive: false,
            isLive: false,
            canReauthenticate: false,
            canRemove: false)
    }

    private func path(_ profile: CodexVisibleAccount) throws -> String {
        guard case let .profileHome(path) = profile.selectionSource else {
            throw NativeCodexProfileImportError.unsupportedLogin
        }
        return path
    }
}
