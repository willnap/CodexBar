import CodexBarCore
import Foundation

enum NativeGaugeConfiguration {
    static var isEnabled: Bool {
        Bundle.main.object(forInfoDictionaryKey: "CodexBarNativeGauges") as? Bool == true
    }

    /// The development app imports a private copy; subsequent changes never edit the installed app's config.
    static func configStore() -> CodexBarConfigStore {
        guard self.isEnabled else { return CodexBarConfigStore() }
        let source = CodexBarConfigStore.defaultURL()
        if ProcessInfo.processInfo.environment[CodexBarConfigStore.pathEnvironmentKey] != nil {
            return CodexBarConfigStore(fileURL: source)
        }
        let manager = FileManager.default
        let directory = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodexBar Native", isDirectory: true)
        let destination = directory.appendingPathComponent("config.json")
        do {
            try manager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            if !manager.fileExists(atPath: destination.path), manager.fileExists(atPath: source.path) {
                try manager.copyItem(at: source, to: destination)
                try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            }
        } catch {
            CodexBarLog.logger("native-gauges").error("Could not prepare native app configuration")
        }
        return CodexBarConfigStore(fileURL: destination)
    }
}
