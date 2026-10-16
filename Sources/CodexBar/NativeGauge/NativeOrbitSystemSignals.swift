import CodexBarCore
import Foundation
import Network
import Observation
@preconcurrency import UserNotifications

/// Facts observed on this Mac. Unknown state stays unknown until the corresponding system callback arrives.
/// This monitor never asks for notification permission or reads credentials.
@MainActor
@Observable
final class NativeOrbitSystemSignals {
    struct TimeZoneChange: Equatable {
        let oldIdentifier: String
        let newIdentifier: String
        let changedAt: Date
    }

    static let shared = NativeOrbitSystemSignals()

    private(set) var isOffline: Bool?
    private(set) var timeZoneChange: TimeZoneChange?
    private(set) var notificationsDenied: Bool?
    private(set) var historyWriteFailures: Set<ProviderInstanceID> = []
    private(set) var isMonitoring = false

    @ObservationIgnored private var timeZoneIdentifier: String
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var timeZoneObserver: NSObjectProtocol?
    @ObservationIgnored private var notificationTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    init(timeZoneIdentifier: String = TimeZone.autoupdatingCurrent.identifier) {
        self.timeZoneIdentifier = timeZoneIdentifier
    }

    func start() {
        guard !self.isMonitoring, !TestProcessSafety.isRunning,
              Bundle.main.bundleURL.pathExtension == "app" else { return }
        self.isMonitoring = true
        self.generation += 1
        let generation = self.generation
        self.timeZoneIdentifier = TimeZone.autoupdatingCurrent.identifier
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self, self.isMonitoring, self.generation == generation else { return }
                self.recordNetworkPath(isSatisfied: satisfied)
            }
        }
        self.pathMonitor = monitor
        monitor.start(queue: DispatchQueue(label: "com.codexbar.warning-network"))
        self.timeZoneObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.NSSystemTimeZoneDidChange, object: nil, queue: .main)
        { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isMonitoring, self.generation == generation else { return }
                self.recordTimeZone(identifier: TimeZone.autoupdatingCurrent.identifier, at: Date())
            }
        }
        self.refreshNotificationAuthorization()
    }

    func stop() {
        self.isMonitoring = false
        self.generation += 1
        self.pathMonitor?.cancel()
        self.pathMonitor = nil
        if let timeZoneObserver { NotificationCenter.default.removeObserver(timeZoneObserver) }
        self.timeZoneObserver = nil
        self.notificationTask?.cancel()
        self.notificationTask = nil
    }

    /// Rechecks while the app runs and immediately after returning from System Settings. Read-only throughout.
    func refreshNotificationAuthorization() {
        guard self.isMonitoring else { return }
        self.notificationTask?.cancel()
        let generation = self.generation
        self.notificationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let settings = await UNUserNotificationCenter.current().notificationSettings()
                guard !Task.isCancelled, let self, self.isMonitoring, self.generation == generation else { return }
                self.recordNotificationAuthorization(isDenied: settings.authorizationStatus == .denied)
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch { return }
            }
        }
    }

    func recordNetworkPath(isSatisfied: Bool) {
        self.isOffline = !isSatisfied
    }

    func recordTimeZone(identifier: String, at date: Date) {
        guard identifier != self.timeZoneIdentifier else { return }
        self.timeZoneChange = TimeZoneChange(
            oldIdentifier: self.timeZoneIdentifier, newIdentifier: identifier, changedAt: date)
        self.timeZoneIdentifier = identifier
    }

    func recordNotificationAuthorization(isDenied: Bool) {
        self.notificationsDenied = isDenied
    }

    /// The history store reports actual failed provider writes; a later successful save clears them.
    func recordHistoryWriteFailures(_ providers: Set<ProviderInstanceID>) {
        self.historyWriteFailures = providers
    }
}
