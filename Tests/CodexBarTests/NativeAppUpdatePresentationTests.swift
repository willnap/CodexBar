import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct NativeAppUpdatePresentationTests {
    @Test
    func `a helper format mismatch names its target rather than claiming an available app release`() throws {
        let light = try #require(NativeOrbitFetchFault.light(
            for: ClaudeSwapListParserError.unsupportedSchemaVersion(999),
            provider: .claude))
        #expect(light.tooltip(account: nil) == "claude-swap format is unsupported. Update CodexBar.")
        #expect(light.action == .settings)
    }

    @Test
    func `a disabled updater cannot advertise a stale available version`() {
        let updater = RecordingUpdater(available: false)
        updater.updateStatus.availableVersion = "9.0"
        updater.updateStatus.isUpdateReady = true
        #expect(NativeAppUpdatePresentation.warning(updater: updater) == nil)
    }

    @Test
    func `an app update tooltip identifies CodexBar and its version`() throws {
        let updater = RecordingUpdater()
        updater.updateStatus.availableVersion = "9.0"
        let light = try #require(NativeAppUpdatePresentation.warning(updater: updater))
        #expect(light.tooltip(account: "Claude") == L("CodexBar %@ is available", "9.0"))
        #expect(light.action == .checkForUpdates)
    }

    @Test
    func `a staged update without a version does not invent a version called update`() throws {
        let updater = RecordingUpdater()
        updater.updateStatus.isUpdateReady = true
        let light = try #require(NativeAppUpdatePresentation.warning(updater: updater))
        #expect(light.tooltip(account: nil) == L("native_app_update_ready"))
    }

    @Test(arguments: [nil, "", "   "])
    func `an empty version does not light a dial without a staged update`(version: String?) {
        let updater = RecordingUpdater()
        updater.updateStatus.availableVersion = version
        #expect(NativeAppUpdatePresentation.warning(updater: updater) == nil)
    }

    @Test(arguments: [false, true])
    func `an update click opens visible context before checking`(available: Bool) {
        let updater = RecordingUpdater(available: available)
        var events: [String] = []
        updater.onCheck = { events.append("check") }
        NativeAppUpdatePresentation.open(updater: updater, showAbout: { events.append("about") })
        #expect(events == (available ? ["about", "check"] : ["about"]))
    }

    @Test
    func `Homebrew can advertise an update despite not supporting automatic Sparkle installation`() throws {
        let updater = HomebrewUpdaterController(savedAutoCheck: false, startScheduledChecks: false)
        updater.updateStatus.availableVersion = "9.0"
        #expect(!updater.isAvailable)
        let light = try #require(NativeAppUpdatePresentation.warning(updater: updater))
        #expect(light.tooltip(account: nil) == L("CodexBar %@ is available", "9.0"))
    }

    private final class RecordingUpdater: UpdaterProviding {
        var automaticallyChecksForUpdates = false
        var automaticallyDownloadsUpdates = false
        let isAvailable: Bool
        let unavailableReason: String? = nil
        let updateStatus = UpdateStatus()
        var onCheck: () -> Void = {}

        init(available: Bool = true) { self.isAvailable = available }
        func checkForUpdates(_: Any?) { self.onCheck() }
        func installUpdate() { Issue.record("An update light must not install an update implicitly") }
    }
}
