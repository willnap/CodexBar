import Foundation

/// App updates name their target and always open visible update controls before starting a check.
@MainActor
enum NativeAppUpdatePresentation {
    static func warning(updater: UpdaterProviding) -> NativeOrbitWarningLight? {
        guard self.canCheck(updater) else { return nil }
        let status = updater.updateStatus
        let version = status.availableVersion?.trimmingCharacters(in: .whitespacesAndNewlines)
        let namedVersion = version.flatMap { $0.isEmpty ? nil : $0 }
        guard namedVersion != nil || status.isUpdateReady else { return nil }
        let text = namedVersion.map { L("CodexBar %@ is available", $0) } ?? L("native_app_update_ready")
        return .init(.update, .opportunity, text, action: .checkForUpdates, tooltipDetail: text)
    }

    static func open(updater: UpdaterProviding, showAbout: () -> Void) {
        showAbout()
        if self.canCheck(updater) { updater.checkForUpdates(nil) }
    }

    private static func canCheck(_ updater: UpdaterProviding) -> Bool {
        // Homebrew deliberately reports isAvailable=false because Sparkle cannot own its installs.
        updater.isAvailable || updater is HomebrewUpdaterController
    }
}
