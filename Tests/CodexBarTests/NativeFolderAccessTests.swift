import Foundation
import Testing
@testable import CodexBar

@MainActor
struct NativeFolderAccessTests {
    @Test func `user selected folder grant survives store recreation`() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let defaults = InMemoryUserDefaults()
        let first = NativeFolderAccessStore(defaults: defaults)
        try first.remember(folder)
        first.releaseAccess()
        let restored = NativeFolderAccessStore(defaults: defaults)
        restored.restoreAccess()
        defer { restored.releaseAccess() }
        #expect(restored.restoredPaths == [folder.standardizedFileURL.path])
        #expect(restored.unavailablePaths.isEmpty)
    }

    @Test func `renamed folder updates scanner paths while unavailable paths are retained`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let old = root.appendingPathComponent("before")
        let moved = root.appendingPathComponent("after")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = InMemoryUserDefaults()
        let access = NativeFolderAccessStore(defaults: defaults)
        try access.remember(old)
        access.releaseAccess()
        try FileManager.default.moveItem(at: old, to: moved)
        let settings = testSettingsStore(suiteName: "NativeMovedFolder", userDefaults: InMemoryUserDefaults())
        settings.antigravityAdditionalProfileHomes = [old.path, moved.path, "/missing/profile"]
        settings.restoreNativeFolderAccess(using: access)
        defer { access.releaseAccess() }
        #expect(settings.antigravityAdditionalProfileHomes == [moved.path, "/missing/profile"])
        #expect(access.resolvedPaths[old.path] == moved.path)
        access.releaseAccess()
        let twiceMoved = root.appendingPathComponent("again")
        try FileManager.default.moveItem(at: moved, to: twiceMoved)
        let nextLaunch = NativeFolderAccessStore(defaults: defaults)
        settings.restoreNativeFolderAccess(using: nextLaunch)
        defer { nextLaunch.releaseAccess() }
        #expect(settings.antigravityAdditionalProfileHomes == [twiceMoved.path, "/missing/profile"])
    }

    @Test func `corrupt stored grants stay unavailable without prompting`() {
        let defaults = InMemoryUserDefaults(values: [
            "nativeFolderBookmarks": ["/fixture/corrupt": Data([0, 1, 2])],
        ])
        let store = NativeFolderAccessStore(defaults: defaults)
        store.restoreAccess()
        #expect(store.restoredPaths.isEmpty)
        #expect(store.unavailablePaths == ["/fixture/corrupt"])
    }
}
