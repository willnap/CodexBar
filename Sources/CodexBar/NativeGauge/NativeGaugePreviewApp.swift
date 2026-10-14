import AppKit
import CodexBarCore
import SwiftUI

/// Runs the production gauge host and popover content with fixtures, before any credential stores are initialized.
@MainActor
enum NativeGaugePreviewApp {
    private static var controller: NativeGaugePreviewController?

    static func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        if CommandLine.arguments.contains("--preview-dark") {
            app.appearance = NSAppearance(named: .darkAqua)
        } else if CommandLine.arguments.contains("--preview-light") {
            app.appearance = NSAppearance(named: .aqua)
        }
        let controller = NativeGaugePreviewController()
        self.controller = controller
        app.delegate = controller
        print("Native fixture run: \(Bundle.main.bundleIdentifier ?? "unknown")")
        app.run()
    }
}

@MainActor
private final class NativeGaugePreviewController: NSObject, NSApplicationDelegate {
    private var items: [UsageProvider: NSStatusItem] = [:]
    private var hosts: [UsageProvider: NativeGaugeHostingView] = [:]
    private var route = NativeServicePresentationRoute()
    private var popover: NSPopover?
    private var previewWindow: NSWindow?
    private var accountIndices: [UsageProvider: Int] = [:]
    private let now = Date()

    func applicationDidFinishLaunching(_: Notification) {
        print("Native fixture: creating three independent status items")
        // Provider-specific by design: Fixture services cover the two-window and three-window gauge layouts.
        for provider in [UsageProvider.codex, .claude, .kimi] {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.autosaveName = "native-preview-\(provider.rawValue)"
            guard let button = item.button else { continue }
            let host = NativeGaugeHostingView(rootView: AnyView(EmptyView()))
            button.addSubview(host)
            button.target = self
            button.action = #selector(self.clicked(_:))
            button.setAccessibilityIdentifier("CodexBar.NativePreview.\(provider.rawValue)")
            button.setAccessibilityLabel("\(provider.rawValue) usage · preview")
            button.toolTip = "\(provider.rawValue) · Preview data"
            self.items[provider] = item
            self.hosts[provider] = host
            host.update(state: self.gauge(for: provider), button: button, item: item)
        }
        // Provider-specific by design: Fixture auto-open consistently selects Codex; normal launches do not use this
        // entry.
        let providerArgument = CommandLine.arguments.firstIndex(of: "--preview-provider")
        let previewProvider = providerArgument.flatMap { index in
            CommandLine.arguments.indices.contains(index + 1)
                ? UsageProvider(rawValue: CommandLine.arguments[index + 1]) : nil
        } ?? .codex
        if CommandLine.arguments.contains("--preview-open"), let button = self.items[previewProvider]?.button {
            Task { @MainActor in self.clicked(button) }
        }
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        guard let provider = self.items.first(where: { $0.value.button === sender })?.key else { return }
        if self.popover?.isShown != true, self.previewWindow?.isVisible != true { self.route.dismiss() }
        self.route.toggle(provider)
        self.popover?.close()
        self.previewWindow?.close()
        guard self.route.provider != nil else { return }
        self.show(provider, button: sender)
    }

    private func show(_ provider: UsageProvider, button: NSStatusBarButton) {
        if CommandLine.arguments.contains("--preview-orbit") {
            self.showOrbit(provider, button: button)
            return
        }
        guard let metadata = ProviderDefaults.metadata[provider] else { return }
        self.previewWindow?.close()
        let snapshot = self.snapshot(for: provider)
        let accountIndex = self.accountIndices[provider, default: 0]
        // Provider-specific by design: Codex cards require the same consumer projection as production.
        let projection = provider == .codex ? CodexConsumerProjection.make(
            surface: .liveCard,
            context: .init(
                snapshot: snapshot,
                rawUsageError: nil,
                liveCredits: nil,
                rawCreditsError: nil,
                liveDashboard: nil,
                rawDashboardError: nil,
                dashboardAttachmentAuthorized: false,
                dashboardRequiresLogin: false,
                now: .now)) : nil
        let model = UsageMenuCardView.Model.make(.init(
            provider: provider,
            metadata: metadata,
            snapshot: snapshot,
            codexProjection: projection,
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: accountIndex == 0 ? "Personal · Preview" : "Work · Preview", plan: "Pro"),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: .now))
        let content = NativeUsagePopoverContent(
            model: model,
            gauge: self.gauge(for: provider),
            accounts: [
                NativeAccountOption(id: "0", title: "Personal · Preview"),
                NativeAccountOption(id: "1", title: "Work · Preview"),
            ],
            selectedAccountID: String(accountIndex),
            canSignIn: false,
            hasDashboard: false,
            onSelectAccount: { [weak self, weak button] id in
                guard let self, let button, let index = Int(id) else { return }
                self.accountIndices[provider] = index
                if let item = self.items[provider] {
                    self.hosts[provider]?.update(state: self.gauge(for: provider), button: button, item: item)
                }
                self.popover?.close()
                self.show(provider, button: button)
            },
            onRefresh: { [weak self, weak button] in
                guard let self, let button else { return }
                self.popover?.close()
                self.show(provider, button: button)
            },
            onQuit: { NSApp.terminate(nil) })
        let popover = NSPopover()
        popover.behavior = .transient
        let hosting = NSHostingController(rootView: content)
        hosting.sizingOptions = []
        popover.contentViewController = hosting
        popover.contentSize = hosting.sizeThatFits(in: NSSize(width: 360, height: 640))
        self.popover = popover
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // A persistent fixture window is opt-in. Failed popover anchoring must never silently open a window.
        if CommandLine.arguments.contains("--preview-window") {
            popover.close()
            let window = NSWindow(contentViewController: hosting)
            window.title = "CodexBar Native · Preview"
            window.setContentSize(popover.contentSize)
            window.isReleasedWhenClosed = false
            window.center()
            window.makeKeyAndOrderFront(nil)
            self.previewWindow = window
        }
        popover.contentViewController?.view.window?.makeKey()
        self.recordPreview(popover)
    }

    /// Production popup with deterministic account data, before any real credential or usage stores initialize.
    private func showOrbit(_ provider: UsageProvider, button: NSStatusBarButton) {
        let state = NativeOrbitPopupState()
        state.now = .now
        // Provider-specific by design: Offline fixtures use the same accent families as their production providers.
        state.accent = provider == .claude ? .orange : provider == .kimi ? .purple : .blue
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let count = CommandLine.arguments.contains("--preview-single") ? 1 : 2
        let makeAccount = { (index: Int, active: Bool) -> NativeOrbitAccountPresentation in
            let snapshot = self.snapshot(for: provider)
            let gauge = NativeUsageGaugeProjection.state(
                provider: provider, snapshot: snapshot, includeModelScopedWeeklyUsage: true)
            let entry = CostUsageDailyReport.Entry(
                date: dayFormatter.string(from: self.now),
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: index == 0 ? 1_700_000 : 925_000,
                costUSD: index == 0 ? 13.45 : 7.20,
                modelsUsed: nil,
                modelBreakdowns: nil)
            let usage = CostUsageTokenSnapshot(
                sessionTokens: nil,
                sessionCostUSD: nil,
                last30DaysTokens: nil,
                last30DaysCostUSD: nil,
                historyDays: 30,
                daily: [
                    entry,
                    .init(
                        date: dayFormatter.string(from: self.now.addingTimeInterval(-3 * 86400)),
                        inputTokens: nil,
                        outputTokens: nil,
                        totalTokens: 2_400_000,
                        costUSD: 19.60,
                        modelsUsed: nil,
                        modelBreakdowns: nil),
                    .init(
                        date: dayFormatter.string(from: self.now.addingTimeInterval(-15 * 86400)),
                        inputTokens: nil,
                        outputTokens: nil,
                        totalTokens: 3_800_000,
                        costUSD: 28.40,
                        modelsUsed: nil,
                        modelBreakdowns: nil),
                ],
                updatedAt: self.now)
            var metrics = NativeOrbitAccountMetrics(usage: usage)
            metrics.reportedSpend = ProviderCostSnapshot(
                used: CommandLine.arguments.contains("--preview-empty-spend") ? 0 : 12.50,
                limit: 50,
                currencyCode: "USD",
                period: "Monthly",
                updatedAt: self.now)
            metrics.bankedResets = 2
            metrics.usedResets = 1
            var presentation = NativeOrbitAccountPresentation(
                id: "fixture-\(index)",
                label: index == 0 ? "Personal · Preview" : "Work · Preview",
                email: nil,
                symbol: "person.crop.circle",
                isActive: active,
                canActivate: !active,
                gauge: gauge,
                updatedAt: self.now,
                history: gauge.resolvedWindows.enumerated().map { lane, window in
                    PlanUtilizationSeriesHistory(
                        name: .init(rawValue: "nativeQuota:" + window.id),
                        windowMinutes: Int(window.period / 60),
                        entries: (0...120).map { step in
                            .init(
                                capturedAt: self.now.addingTimeInterval(Double(step - 120) * 21600),
                                usedPercent: Double((step * (lane + 1) * 3 + index * 11) % 85),
                                resetsAt: nil)
                        })
                },
                odometer: nil,
                odometerHelp: nil,
                statusText: nil,
                selection: .none,
                metrics: metrics,
                quotaLabels: UsageStore.nativeOrbitQuotaLabels(provider: provider, snapshot: snapshot),
                quotaWindows: UsageStore.nativeOrbitQuotaWindowMap(provider: provider, snapshot: snapshot))
            presentation.warnings = Self.fixtureLights(column: index)
            return presentation
        }
        state.accounts = (0..<count).map { makeAccount($0, $0 == 0) }
        // Every launch's first popup checks its bulbs, as the live one does.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            await state.runBulbCheck()
        }
        // A fixture switch: a short wait, then the target becomes active, or with `CODEXBAR_PREVIEW_SWITCH_FAILS`
        // the failure a real switch reports. `CODEXBAR_PREVIEW_SWITCH_AFTER` (seconds) starts one unattended.
        var target: String?
        let switching = NativeAccountSwitchController(
            provider: provider,
            store: nil,
            defaults: UserDefaults(suiteName: "codexbar-native-preview") ?? .standard,
            activate: { _ in
                try? await Task.sleep(for: .seconds(1.5 * NativeOrbitProjectionStyle.previewAnimationScale))
                if ProcessInfo.processInfo.environment["CODEXBAR_PREVIEW_SWITCH_FAILS"] != nil {
                    return .failed("ChatGPT didn’t quit. If it asked to confirm, answer it, then try again. "
                        + "No account was changed.")
                }
                state.accounts = (0..<count).map { makeAccount($0, target == "fixture-\($0)") }
                    .sorted { $0.isActive && !$1.isActive }
                return .activated
            },
            refresh: {},
            allowed: { true },
            accounts: { state.accounts })
        state.accountSwitch = switching
        let activate = { (id: String) in
            guard let account = state.accounts.first(where: { $0.id == id }) else { return }
            target = id
            switching.activate(account)
        }
        if let delay = ProcessInfo.processInfo.environment["CODEXBAR_PREVIEW_SWITCH_AFTER"].flatMap(Double.init) {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                if let other = state.accounts.first(where: { !$0.isActive }) { activate(other.id) }
            }
        }
        let content = NativeOrbitPopupView(state: state, activate: activate, signIn: nil, refresh: {
            state.isRefreshing = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                state.isRefreshing = false
            }
        })
        let hosting = NSHostingController(rootView: content)
        hosting.sizingOptions = []
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = hosting
        popover.contentSize = NSSize(
            width: state.accounts.count == 1 ? 240 : 480,
            height: state.accounts.count == 1 ? 513 : 541)
        self.popover = popover
        if CommandLine.arguments.contains("--preview-window") {
            let window = NSWindow(contentViewController: hosting)
            window.title = "CodexBar Native · \(provider.rawValue) Orbit Preview"
            window.setContentSize(popover.contentSize)
            window.isReleasedWhenClosed = false
            window.center()
            window.makeKeyAndOrderFront(nil)
            self.previewWindow = window
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        self.recordPreview(popover)
    }

    /// `CODEXBAR_PREVIEW_LIGHTS`: "all" lights every kind in every dial (red where a kind can be), otherwise a comma
    /// list of kind names (`signIn,quota`) lights those, amber.
    private static func fixtureLights(column: Int) -> [NativeOrbitWarningLight] {
        guard let value = ProcessInfo.processInfo.environment["CODEXBAR_PREVIEW_LIGHTS"] else { return [] }
        let all = NativeOrbitWarningLight.Kind.allCases
        let kinds: [NativeOrbitWarningLight.Kind] = value == "all"
            ? all : value.split(separator: ",").compactMap { name in all.first { name == "\($0)" } }
        return kinds.map { kind in
            .init(
                kind,
                value == "all" && kind.canBeCritical && column == 0 ? .critical : .caution,
                "Fixture: \(kind.name)",
                action: .refresh)
        }
    }

    private func recordPreview(_ popover: NSPopover) {
        guard let argument = CommandLine.arguments.firstIndex(of: "--preview-output"),
              CommandLine.arguments.indices.contains(argument + 1) else { return }
        let directory = URL(fileURLWithPath: CommandLine.arguments[argument + 1], isDirectory: true)
        Task { @MainActor in
            guard let view = popover.contentViewController?.view else { return }
            view.layoutSubtreeIfNeeded()
            let report: [String: Any] = [
                "popoverShown": popover.isShown,
                "previewWindowShown": self.previewWindow?.isVisible == true,
                "width": view.bounds.width,
                "height": view.bounds.height,
                "popoverFrame": NSStringFromRect(popover.contentViewController?.view.window?.frame ?? .zero),
                "services": self.items.map { provider, item in
                    [
                        "id": provider.rawValue,
                        "visible": item.isVisible,
                        "frame": NSStringFromRect(item.button?.window?.frame ?? .zero),
                        "length": item.length,
                        "buttonBounds": NSStringFromRect(item.button?.bounds ?? .zero),
                        "hostFrame": NSStringFromRect(self.hosts[provider]?.frame ?? .zero),
                    ] as [String: Any]
                },
            ]
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: directory.appendingPathComponent("preview.json"))
                if let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: image)
                    try image.representation(using: .png, properties: [:])?
                        .write(to: directory.appendingPathComponent("popover.png"))
                }
            } catch {
                print("Native fixture output failed: \(error.localizedDescription)")
            }
        }
    }

    private func gauge(for provider: UsageProvider) -> ComputeGauge.State {
        NativeUsageGaugeProjection.state(provider: provider, snapshot: self.snapshot(for: provider))
    }

    private func snapshot(for provider: UsageProvider) -> UsageSnapshot {
        let shift = self.accountIndices[provider, default: 0] == 0 ? 0.0 : 18.0
        let primary = RateWindow(
            usedPercent: 34 + shift,
            windowMinutes: 300,
            resetsAt: self.now.addingTimeInterval(3 * 3600),
            resetDescription: nil)
        let weekly = RateWindow(
            usedPercent: 62 - shift,
            windowMinutes: 10080,
            resetsAt: self.now.addingTimeInterval(4 * 86400),
            resetDescription: nil)
        // Provider-specific by design: The Kimi fixture includes a monthly quota to exercise three-window rendering.
        let monthly = provider == .kimi
            ? RateWindow(
                usedPercent: 42,
                windowMinutes: 43200,
                resetsAt: self.now.addingTimeInterval(18 * 86400),
                resetDescription: nil) : nil
        return UsageSnapshot(
            primary: provider == .kimi ? weekly : primary,
            secondary: provider == .kimi ? primary : weekly,
            extraRateWindows: monthly.map { [NamedRateWindow(id: "kimi-monthly", title: "Monthly", window: $0)] }
                ?? (provider == .claude ? [NamedRateWindow(
                    id: "claude-weekly-scoped-fable",
                    title: "Fable only",
                    window: RateWindow(
                        usedPercent: 23,
                        windowMinutes: 10080,
                        resetsAt: self.now.addingTimeInterval(4 * 86400),
                        resetDescription: nil))] : []),
            updatedAt: self.now,
            dataConfidence: .exact)
    }
}
