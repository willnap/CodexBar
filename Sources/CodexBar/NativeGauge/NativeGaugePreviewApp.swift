import AppKit
import CodexBarCore
import QuartzCore
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
    private var startupTask: Task<Void, Never>?
    private var accountIndices: [UsageProvider: Int] = [:]
    private let now = Date()

    func applicationDidFinishLaunching(_: Notification) {
        if CommandLine.arguments.contains("--preview-scene") {
            NativeOrbitShowcaseScene.show()
            return
        }
        if CommandLine.arguments.contains("--preview-combined") {
            self.showCombinedPreview()
            return
        }
        print("Native fixture: creating three independent status items")
        // Provider-specific by design: Fixture services cover the two-window and three-window gauge layouts.
        for provider in CommandLine.arguments.contains("--preview-monetary")
            ? [UsageProvider.openrouter] : [UsageProvider.codex, .claude, .kimi]
        {
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
        } ?? (CommandLine.arguments.contains("--preview-monetary") ? .openrouter : .codex)
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
            // The offline probe drives inspection itself; a real pointer must not change its workload.
            window.ignoresMouseEvents = CommandLine.arguments.contains("--preview-performance")
            window.center()
            window.makeKeyAndOrderFront(nil)
            self.previewWindow = window
        }
        popover.contentViewController?.view.window?.makeKey()
        self.recordPreview(popover)
    }

    /// Production popup with deterministic account data, before any real credential or usage stores initialize.
    private func showOrbit(_ provider: UsageProvider, button: NSStatusBarButton) {
        let preparationStart = CACurrentMediaTime()
        let state = NativeOrbitPopupState()
        state.now = .now
        // Provider-specific by design: Offline fixtures use the same accent families as their production providers.
        let color = ProviderDescriptorRegistry.descriptor(for: provider).branding.color
        state.accent = Color(red: color.red, green: color.green, blue: color.blue)
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let count = CommandLine.arguments.contains("--preview-single") ? 1 : 2
        let makeAccount = { (index: Int, active: Bool) in
            self.orbitAccount(provider, index: index, active: active, dayFormatter: dayFormatter)
        }
        state.accounts = (0..<count).map { makeAccount($0, $0 == 0) }
        state.armStartup(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        state.prepareStartupArtwork(
            screen: button.window?.screen,
            appearance: self.previewWindow?.contentView?.effectiveAppearance)
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
                state.armStartup(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
                state.prepareStartupArtwork(
                    screen: button.window?.screen,
                    appearance: self.previewWindow?.contentView?.effectiveAppearance)
                if let view = self.previewWindow?.contentView ?? self.popover?.contentViewController?.view {
                    self.startStartup(state: state, view: view)
                }
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
        let content = NativeOrbitPopupView(
            state: state,
            activate: activate,
            signIn: nil,
            refresh: {
                state.isRefreshing = true
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(5))
                    state.isRefreshing = false
                }
            },
            acceptsHoverInspection: !CommandLine.arguments.contains("--preview-performance"))
        let hosting = NSHostingController(rootView: content)
        hosting.sizingOptions = []
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = hosting
        popover.contentSize = NSSize(
            width: CGFloat(state.accounts.count * 240 + max(0, state.accounts.count - 1)),
            height: NativeOrbitPopupView.contentHeight(showsFooter: state.accounts.count > 1))
        self.popover = popover
        if CommandLine.arguments.contains("--preview-window") {
            let window = CommandLine.arguments.contains("--preview-performance")
                ? NSWindow(contentViewController: hosting) : Self.glassWindow(hosting, size: popover.contentSize)
            window.title = "CodexBar Native · \(provider.rawValue) Orbit Preview"
            if !CommandLine.arguments.contains("--preview-showcase") { window.setContentSize(popover.contentSize) }
            window.isReleasedWhenClosed = false
            window.center()
            if CommandLine.arguments.contains("--preview-performance") {
                window.level = .floating
                window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
                window.ignoresMouseEvents = true
                window.orderFrontRegardless()
            } else {
                window.makeKeyAndOrderFront(nil)
            }
            self.previewWindow = window
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        if CommandLine.arguments.contains("--preview-performance") {
            let preparationMilliseconds = (CACurrentMediaTime() - preparationStart) * 1000
            Task { @MainActor in
                await NativeOrbitPerformanceProbe.startIfRequested(
                    state: state,
                    view: hosting.view,
                    preparationMilliseconds: preparationMilliseconds,
                    switchAccount: {
                        if let other = state.accounts.first(where: { !$0.isActive }) { activate(other.id) }
                    })
                self.startStartup(state: state, view: hosting.view)
                self.recordPreview(popover)
            }
        } else {
            self.startStartup(state: state, view: hosting.view)
            self.recordPreview(popover)
        }
    }

    /// The popup's content on the popover's own material, in a panel that takes key so its glass renders active.
    /// `--preview-showcase` instead draws the popup as a rounded card over the image at
    /// `CODEXBAR_PREVIEW_BACKDROP`, all inside one borderless panel: its material blends within the window, so a
    /// window capture shows only that image behind the glass, never the screen.
    private static func glassWindow(_ hosting: NSHostingController<some View>, size: NSSize) -> NSWindow {
        let showcase = CommandLine.arguments.contains("--preview-showcase")
        let margin: CGFloat = showcase ? 64 : 0
        let panel = NativeOrbitPreviewPanel(
            contentRect: NSRect(x: 0, y: 0, width: size.width + 2 * margin, height: size.height + 2 * margin),
            styleMask: showcase ? [.borderless, .nonactivatingPanel] : [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        let material = NSVisualEffectView(frame: NSRect(origin: NSPoint(x: margin, y: margin), size: size))
        material.material = .popover
        material.blendingMode = showcase ? .withinWindow : .behindWindow
        material.state = .active
        hosting.view.frame = material.bounds
        hosting.view.autoresizingMask = [.width, .height]
        material.addSubview(hosting.view)
        guard showcase else {
            material.autoresizingMask = [.width, .height]
            panel.contentView = material
            return panel
        }
        let radius: CGFloat = 18
        let mask = NSImage(size: NSSize(width: 2 * radius + 1, height: 2 * radius + 1), flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        mask.resizingMode = .stretch
        material.maskImage = mask
        // The toolbar's glass draws outside the material's mask; round the content itself as the popover does.
        hosting.view.wantsLayer = true
        hosting.view.layer?.cornerRadius = radius
        hosting.view.layer?.cornerCurve = .continuous
        hosting.view.layer?.masksToBounds = true
        let backdrop = NSImageView(frame: NSRect(origin: .zero, size: panel.frame.size))
        backdrop.imageScaling = .scaleAxesIndependently
        backdrop.image = ProcessInfo.processInfo.environment["CODEXBAR_PREVIEW_BACKDROP"]
            .flatMap { NSImage(contentsOfFile: $0) }
        // The popover's own lift off whatever lies beneath it.
        let shadow = NSView(frame: material.frame)
        shadow.wantsLayer = true
        shadow.layer?.shadowPath = CGPath(
            roundedRect: shadow.bounds,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil)
        shadow.layer?.shadowColor = NSColor.black.cgColor
        shadow.layer?.shadowOpacity = 0.28
        shadow.layer?.shadowRadius = 22
        shadow.layer?.shadowOffset = CGSize(width: 0, height: -10)
        backdrop.addSubview(shadow)
        backdrop.addSubview(material)
        panel.contentView = backdrop
        return panel
    }

    /// Uses the production pager with synthetic accounts; never initializes a credential store.
    private func showCombinedPreview() {
        NativePageControlMotionTrace.enabled = CommandLine.arguments.contains("--preview-control-check")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        // Provider-specific by design: These fixtures cover paired, scoped, monthly, and single-provider quotas.
        let providers: [UsageProvider] = [.codex, .claude, .kimi, .gemini]
        let sources = providers.enumerated().map { providerIndex, provider in
            let state = NativeOrbitPopupState()
            state.accounts = (0..<(providerIndex < 2 ? 3 : 1)).map { index in
                var account = self.orbitAccount(provider, index: index, active: index == 0, dayFormatter: formatter)
                account.symbol = ["house", "briefcase", "leaf"][index]
                account.metrics
                    .quotaConsumption = [self.now.addingTimeInterval(-Double(providerIndex * 600 + index * 60))]
                return account
            }
            state.badges = Dictionary(uniqueKeysWithValues: state.accounts.map { ($0.id, $0.symbol) })
            return NativeCombinedAccountSource(provider: provider, state: state)
        }
        let toolbar = NativeOrbitPopupState()
        toolbar.accounts = sources.flatMap(\.state.accounts)
        let model = NativeCombinedAccounts(connections: sources.map {
            .init(provider: $0.provider, accounts: $0.state.accounts)
        }, now: self.now)
        self.exportCombinedIndicatorArtwork(model)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NativeCombinedStatusImage.make(model.recentAccounts)
        item.button?.setAccessibilityLabel("All accounts · Preview")
        // Provider-specific by design: The fixture inventory retains its sole combined status item in Codex’s slot.
        self.items[.codex] = item
        let initialID = CommandLine.arguments.contains("--preview-overview") ? NativeCombinedAccounts.overviewID : nil
        let host = NSHostingController(rootView: NativeCombinedPopupView(
            sources: sources,
            toolbar: toolbar,
            initialID: initialID))
        let popover = NSPopover()
        popover.contentViewController = host
        popover.contentSize = NativeCombinedPopupView.contentSize
        self.popover = popover
        let window = Self.glassWindow(host, size: popover.contentSize)
        self.previewWindow = window
        window.center()
        window.orderFrontRegardless()
        NSApp.activate()
        window.makeKey()
        self.recordPreview(popover)
        if CommandLine.arguments.contains("--preview-control-check"),
           let argument = CommandLine.arguments.firstIndex(of: "--preview-output"),
           CommandLine.arguments.indices.contains(argument + 1)
        {
            let directory = URL(fileURLWithPath: CommandLine.arguments[argument + 1], isDirectory: true)
            Task { await NativePageControlPreviewCheck.run(view: host.view, model: model, directory: directory) }
        }
    }

    /// Render only synthetic symbol controls, without sampling a window or the user's screen.
    private func exportCombinedIndicatorArtwork(_ model: NativeCombinedAccounts) {
        guard let argument = CommandLine.arguments.firstIndex(of: "--preview-output"),
              CommandLine.arguments.indices.contains(argument + 1) else { return }
        let directory = URL(fileURLWithPath: CommandLine.arguments[argument + 1], isDirectory: true)
        let ids = [NativeCombinedAccounts.overviewID] + model.pages.map(\.id)
        let artwork = VStack(alignment: .leading, spacing: 8) {
            ForEach(ids, id: \.self) { id in
                VStack(alignment: .leading, spacing: 0) {
                    Text(id).font(.system(size: 10)).foregroundStyle(.secondary)
                    let indicators = model.indicators(selectedID: id)
                    NativePageControlArtwork(
                        indicators: indicators,
                        layout: NativePageControlLayout(
                            count: indicators.count,
                            selection: indicators.firstIndex(where: \.selected) ?? 0,
                            availableLength: 240,
                            pitch: 22,
                            symbolWidths: indicators.map {
                                NativePageControlSymbol($0, configuration: .init()).size.width
                            }))
                }
            }
        }
        .padding(16)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, CommandLine.arguments.contains("--preview-dark") ? .dark : .light)
        let renderer = ImageRenderer(content: artwork)
        renderer.scale = 3
        guard let image = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent("indicator-symbols.png"))
            self.exportPageControlComparison(directory: directory)
        } catch {
            print("Native symbol fixture output failed: \(error.localizedDescription)")
        }
    }

    private func exportPageControlComparison(directory: URL) {
        let symbols = [
            "square.stack.3d.up",
            "circle.hexagongrid.fill",
            "house.fill",
            "briefcase.fill",
            "leaf.fill",
            "sparkles",
            "moon.fill",
            "sun.max.fill",
        ]
        let indicators = symbols.enumerated().map { index, symbol in
            NativeCombinedAccounts.Indicator(
                id: String(index),
                targetID: String(index),
                provider: nil,
                symbol: symbol,
                label: symbol,
                selected: index == 2)
        }
        let artwork = NativePageControlArtwork(
            indicators: indicators,
            layout: NativePageControlLayout(
                count: indicators.count,
                selection: 2,
                availableLength: 240,
                pitch: 22,
                symbolWidths: indicators.map { NativePageControlSymbol($0, configuration: .init()).size.width }),
            configuration: NativePageControlConfiguration(
                indicatorTint: .black.opacity(0.3),
                currentIndicatorTint: .black))
            .background(Color(white: 0.94))
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: artwork)
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        try? data.write(to: directory.appendingPathComponent("page-control-port-reference.png"))
    }

    private func orbitAccount(
        _ provider: UsageProvider,
        index: Int,
        active: Bool,
        dayFormatter: DateFormatter) -> NativeOrbitAccountPresentation
    {
        let snapshot = self.orbitSnapshot(provider: provider, index: index)
        let gauge = NativeUsageGaugeProjection.state(
            provider: provider,
            snapshot: snapshot)
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
        let metrics = self.orbitMetrics(usage: usage, snapshot: snapshot, index: index)
        var presentation = NativeOrbitAccountPresentation(
            id: "fixture-\(index)",
            label: index == 0 ? "Personal · Preview" : "Work · Preview",
            email: nil,
            symbol: "person.crop.circle",
            isActive: active,
            canActivate: !active,
            gauge: gauge,
            updatedAt: self.now,
            history: gauge.resolvedWindows.filter { $0.usedFraction != nil }.enumerated().map { lane, window in
                PlanUtilizationSeriesHistory(
                    name: .init(rawValue: "nativeQuota:" + window.id),
                    windowMinutes: Int(window.period / 60),
                    entries: (0...(CommandLine.arguments.contains("--preview-dense") ? 2400 : 120)).map { step in
                        .init(
                            capturedAt: self.now
                                .addingTimeInterval(Double(step -
                                        (CommandLine.arguments.contains("--preview-dense") ? 2400 : 120))
                                    * (CommandLine.arguments.contains("--preview-dense") ? 1080 : 21600)),
                            usedPercent: CommandLine.arguments.contains("--preview-monetary")
                                ? Double(step) / 120 * 42.70
                                : Double((step * (lane + 1) * 3 + index * 11) % 85),
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

    private func startStartup(state: NativeOrbitPopupState, view: NSView) {
        self.startupTask?.cancel()
        self.startupTask = Task { @MainActor in
            view.layoutSubtreeIfNeeded()
            view.window?.displayIfNeeded()
            CATransaction.flush()
            await Task.yield()
            guard !Task.isCancelled else { return }
            await state.runStartup()
        }
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
            // A lazy pager applies its initial native scroll position on the first display pass.
            // Export after that pass, so the fixture records the visible page rather than its empty first layout.
            if CommandLine.arguments.contains("--preview-combined") {
                try? await Task.sleep(for: .seconds(1))
            }
            guard let view = popover.contentViewController?.view else { return }
            view.layoutSubtreeIfNeeded()
            view.window?.displayIfNeeded()
            CATransaction.flush()
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

    private func orbitMetrics(
        usage: CostUsageTokenSnapshot,
        snapshot: UsageSnapshot,
        index: Int) -> NativeOrbitAccountMetrics
    {
        var metrics = NativeOrbitAccountMetrics(usage: usage)
        metrics.reportedSpend = ProviderCostSnapshot(
            used: CommandLine.arguments.contains("--preview-empty-spend") ? 0 : 12.50,
            limit: 50,
            currencyCode: "USD",
            period: "Monthly",
            updatedAt: self.now)
        if CommandLine.arguments.contains("--preview-monetary") {
            metrics.reportedSpend = snapshot.providerCost
            if index == 0 {
                metrics.reportedBalance = .init(
                    value: 48.30,
                    unit: "USD",
                    isWorkspace: false,
                    updatedAt: self.now)
            }
        }
        metrics.bankedResets = 2
        metrics.usedResets = 1
        return metrics
    }

    private func orbitSnapshot(provider: UsageProvider, index: Int) -> UsageSnapshot {
        guard CommandLine.arguments.contains("--preview-monetary") else { return self.snapshot(for: provider) }
        return UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: ProviderCostSnapshot(
                used: 42.70,
                limit: index == 0 ? 0 : 100,
                currencyCode: "USD",
                period: "Monthly",
                updatedAt: self.now),
            updatedAt: self.now)
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
