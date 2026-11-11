import Foundation

/// One shared beat for everything that rebuilds account rows when the store changes.
///
/// A refresh publishes dozens of changes over half a minute. The menu bar gauges, the account switcher and each
/// service's popup page all reacted to every one of them separately, so the rows were rebuilt and the popup
/// re-rendered several times a second for the whole sweep, with the main thread saturated. Waiting for the next
/// shared beat turns a burst of changes into one rebuild, and makes every listener land on the same turn so the
/// popup renders once for all of them.
@MainActor
enum NativeStoreChangePacer {
    /// The beat. Zero under test, where each change is observed at once.
    static var interval: Duration = SettingsStore.isRunningTests ? .zero : .seconds(1)

    private static let epoch = ContinuousClock.now

    /// How long until the next beat, never less than `minimum`.
    static func delayToNextBeat(minimum: Duration = .milliseconds(100)) -> Duration {
        guard self.interval > .zero else { return .zero }
        let elapsed = self.epoch.duration(to: .now)
        let beat = Self.seconds(self.interval)
        let into = Self.seconds(elapsed).truncatingRemainder(dividingBy: beat)
        var wait = beat - into
        if wait < Self.seconds(minimum) { wait += beat }
        return .milliseconds(Int((wait * 1000).rounded()))
    }

    /// The longest a rebuild waits for the pointer to come to rest in one of the app's windows.
    static let longestInteractionDeferral: Duration = .seconds(8)

    /// Sleeps until the next beat, and then until the person has stopped moving the pointer in the popup: a row
    /// rebuild on the main thread is a dropped frame under a scroll or a pan. Returns at once under test.
    static func waitForNextBeat() async {
        let delay = self.delayToNextBeat()
        guard delay > .zero else { return }
        try? await Task.sleep(for: delay)
        let deadline = ContinuousClock.now + self.longestInteractionDeferral
        while !Task.isCancelled, NativePopupInteraction.isActive, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
