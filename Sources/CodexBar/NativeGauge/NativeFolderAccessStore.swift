import Foundation

/// Grants come only from the user's folder picker. Restoring a grant never opens a permission dialog.
@MainActor
final class NativeFolderAccessStore {
    static let shared = NativeFolderAccessStore(defaults: .standard)
    private let defaults: UserDefaults
    private var accessURLs: [String: URL] = [:]
    private(set) var resolvedPaths: [String: String] = [:]
    private(set) var restoredPaths: Set<String> = []
    private(set) var unavailablePaths: Set<String> = []
    private static let defaultsKey = "nativeFolderBookmarks"

    init(defaults: UserDefaults) { self.defaults = defaults }

    func remember(_ url: URL) throws {
        let data = try url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil)
        var bookmarks = self.bookmarks
        bookmarks[url.standardizedFileURL.path] = data
        self.defaults.set(bookmarks, forKey: Self.defaultsKey)
        self.restoreAccess()
    }

    func restoreAccess() {
        self.releaseAccess()
        var bookmarks = self.bookmarks
        self.unavailablePaths.removeAll()
        for (path, data) in bookmarks {
            do {
                var stale = false
                let url = try URL(
                    resolvingBookmarkData: data,
                    options: [.withSecurityScope, .withoutUI],
                    relativeTo: nil,
                    bookmarkDataIsStale: &stale)
                let started = url.startAccessingSecurityScopedResource()
                if started { self.accessURLs[path] = url }
                var restoredData = data
                if stale {
                    restoredData = try url.bookmarkData(
                        options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil)
                }
                // Non-sandboxed apps can access a selected folder without consuming a sandbox extension.
                let resolvedPath = url.standardizedFileURL.path
                self.restoredPaths.insert(resolvedPath)
                self.resolvedPaths[path] = resolvedPath
                bookmarks.removeValue(forKey: path)
                bookmarks[resolvedPath] = restoredData
            } catch {
                self.unavailablePaths.insert(path)
            }
        }
        self.defaults.set(bookmarks, forKey: Self.defaultsKey)
    }

    func releaseAccess() {
        for url in self.accessURLs.values {
            url.stopAccessingSecurityScopedResource()
        }
        self.accessURLs.removeAll()
        self.restoredPaths.removeAll()
        self.resolvedPaths.removeAll()
    }

    func remapping(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.compactMap { path in
            let resolved = self.resolvedPaths[URL(fileURLWithPath: path).standardizedFileURL.path] ?? path
            return seen.insert(resolved).inserted ? resolved : nil
        }
    }

    private var bookmarks: [String: Data] {
        self.defaults.dictionary(forKey: Self.defaultsKey) as? [String: Data] ?? [:]
    }
}

/// Provider-specific by design: additional Antigravity profiles are the current folder-picker setting.
extension SettingsStore {
    func restoreNativeFolderAccess(using store: NativeFolderAccessStore = .shared) {
        store.restoreAccess()
        let paths = self.antigravityAdditionalProfileHomes
        let restored = store.remapping(paths)
        if restored != paths { self.antigravityAdditionalProfileHomes = restored }
    }
}
