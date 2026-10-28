import AppKit
import CodexBarCore
import SwiftUI

/// Development only (`--native-preview --preview-scene`): the combined window under its menu bar item, for README
/// artwork; `--preview-scene-services` fans out one popover per service instead. Both sit on a plain backdrop, or the
/// image at `CODEXBAR_PREVIEW_BACKDROP`. Every popup is the production view fed a month of generated, internally
/// consistent usage for fictitious accounts; nothing is drawn to imitate it.
@MainActor
enum NativeOrbitShowcaseScene {
    struct Lane {
        /// Nil when the provider reports a pool without a window length, as Codebuff's credits.
        let minutes: Int?
        let used: Double
        let resetsIn: TimeInterval
        /// An additional window's own identity and title, as Claude's model-scoped weekly or Kimi's monthly pool.
        var extra: (id: String, title: String)?

        /// The span the generated history renews over; a pool without a length renews monthly.
        var cycleMinutes: Int {
            self.minutes ?? 43200
        }

        /// What a whole window comes to at this window's pace: earlier windows' share when this one is too quiet to
        /// calibrate them.
        var typical: Double {
            let elapsed = 1 - self.resetsIn / (Double(self.cycleMinutes) * 60)
            return min(96, max(20, self.used / max(0.05, elapsed)))
        }

        /// A window `lead` points from its pace: on pace lights no lamp, as most accounts run.
        static func paced(
            _ minutes: Int,
            resetsIn: TimeInterval,
            lead: Double = -1,
            extra: (id: String, title: String)? = nil) -> Lane
        {
            let elapsed = 1 - resetsIn / (Double(minutes) * 60)
            return Lane(minutes: minutes, used: max(1, elapsed * 100 + lead), resetsIn: resetsIn, extra: extra)
        }
    }

    struct Account {
        let label: String
        let badge: String
        var plan: String?
        var active = true
        /// How long ago an account not in use was last used; its quota stays where that left it.
        var idleFor: TimeInterval?
        /// How long ago an account in use last spent quota; the combined window orders its pages by it.
        var lastUsed: TimeInterval = 0
        var lanes: [Lane]
        var tokensPerDay: Double
        var dollarsPerMillion: Double
        var bankedResets: Int?
        var usedResets = 0
        var extra: (used: Double, limit: Double)?
        /// A monthly budget whose use is the account's own month-to-date spend.
        var budgetLimit: Double?
        /// A prepaid balance, as an API platform's credit.
        var balance: Double?
        /// Conditions the generated usage can't show by itself, such as a provider's status page or a saved reset.
        var warnings: [NativeOrbitWarningLight] = []
        var seed: UInt64
    }

    struct Card {
        let provider: UsageProvider
        let accounts: [Account]
        var days = 1
    }

    private static var window: NSWindow?
    /// Where the front popover's arrow points, for the menu bar's open item.
    fileprivate static var openItemX: CGFloat = 0

    /// Provider-specific by design: the services people code with today, each with the quota windows it actually
    /// reports and its own brand accent. Most run with room to spare; a few lamps tell the rest of the story: one
    /// running ahead of pace, a saved reset, room to spare before a reset, and a provider incident.
    /// Left to right when fanned out, the middle card in front.
    static var cards: [Card] {
        let hour: TimeInterval = 3600
        let day: TimeInterval = 86400
        // Gemini Code Assist: the day's Pro allowance, while Google reports elevated errors.
        let gemini = Account(
            label: "rin@kestrel.dev",
            badge: "sparkle",
            lastUsed: 8 * 60,
            lanes: [.paced(1440, resetsIn: 15 * hour, lead: -4)],
            tokensPerDay: 7_800_000,
            dollarsPerMillion: 0.9,
            warnings: [.init(.degraded, .caution, "Gemini Code Assist: elevated error rates.")],
            seed: 81)
        // Kimi Code: a busy week on course, its monthly pool and five-hour session roomy.
        let kimi = Account(
            label: "wei.zhang@lattice.cn",
            badge: "moon.fill",
            lastUsed: 6 * 60,
            lanes: [
                .paced(10080, resetsIn: 1.6 * day, lead: 0),
                Lane(minutes: 300, used: 30, resetsIn: 3.4 * hour),
                .paced(43200, resetsIn: 21 * day, lead: -4, extra: ("kimi-monthly", "Monthly")),
            ],
            tokensPerDay: 11_500_000,
            dollarsPerMillion: 0.6,
            seed: 91)
        let devonLab = Account(
            label: "devon@lumenlabs.io",
            badge: "flask.fill",
            plan: "Pro",
            lastUsed: 3 * 60,
            lanes: [Lane(minutes: 300, used: 24, resetsIn: 3.6 * hour), .paced(10080, resetsIn: 5.6 * day, lead: -3)],
            tokensPerDay: 14_200_000,
            dollarsPerMillion: 1.4,
            bankedResets: 3,
            warnings: [.init(.newSavedReset, .opportunity, "Saved reset added; 3 available.")],
            seed: 21)
        // A heavy Max week running a little ahead of pace, Sonnet's own allowance and extra usage beside it.
        let mayaStudio = Account(
            label: "maya@northwind.dev",
            badge: "paintpalette.fill",
            plan: "Claude Max 20x",
            lastUsed: 60,
            lanes: [
                Lane(minutes: 300, used: 46, resetsIn: 2.6 * hour),
                .paced(10080, resetsIn: 4.8 * day, lead: 5),
                .paced(10080, resetsIn: 4.8 * day, lead: -5, extra: ("claude-weekly-scoped-sonnet", "Sonnet only")),
            ],
            tokensPerDay: 26_000_000,
            dollarsPerMillion: 3.1,
            bankedResets: 2,
            usedResets: 1,
            extra: (18, 50),
            seed: 11)
        // GLM Coding Plan: half the week unused with under a day to go, so there's room to lean on it.
        let glm = Account(
            label: "li.na@harbor.cn",
            badge: "water.waves",
            lastUsed: 7 * 60,
            lanes: [
                Lane(minutes: 300, used: 17, resetsIn: 3.9 * hour),
                Lane(minutes: 10080, used: 47, resetsIn: 0.8 * day),
            ],
            tokensPerDay: 12_800_000,
            dollarsPerMillion: 0.5,
            seed: 51)
        // DeepSeek's platform: pay as you go against a prepaid balance.
        let deepseek = Account(
            label: "omar@quillstack.dev",
            badge: "fish.fill",
            lastUsed: 30 * 60,
            lanes: [],
            tokensPerDay: 38_000_000,
            dollarsPerMillion: 0.35,
            balance: 84.60,
            seed: 61)
        // Provider-specific by design: This offline showcase deliberately samples these distinct quota layouts.
        return [
            Card(provider: .gemini, accounts: [gemini]),
            Card(provider: .kimi, accounts: [kimi], days: 7),
            Card(provider: .codex, accounts: [devonLab], days: 7),
            Card(provider: .claude, accounts: [mayaStudio]),
            Card(provider: .zai, accounts: [glm], days: 7),
            Card(provider: .deepseek, accounts: [deepseek], days: 30),
        ]
    }

    static func show() {
        if CommandLine.arguments.contains("--preview-scene-services") {
            self.showServices()
        } else {
            self.showCombined()
        }
    }

    /// The combined window as it opens on the All page, six columns wide: All and the five most recently used
    /// accounts, in the production order. Any further page is still counted on the All page.
    private static func showCombined() {
        let now = Date()
        let cards = self.cards
        let sources = cards.map { card in
            NativeCombinedAccountSource(provider: card.provider, state: self.state(for: card, now: now))
        }
        let model = NativeCombinedAccounts(
            connections: sources.map { .init(provider: $0.provider, accounts: $0.state.accounts) },
            now: now)
        let toolbar = NativeOrbitPopupState()
        toolbar.now = now
        toolbar.days = ProcessInfo.processInfo.environment["CODEXBAR_PREVIEW_DAYS"].flatMap(Int.init) ?? 1
        toolbar.accounts = model.pages.map(\.account)
        toolbar.isReady = true
        toolbar.startup = .live
        let width = NativeCombinedPopupView.clampedWidth(
            6 * NativeCombinedPopupView.pitch - 1,
            pageCount: model.pages.count + 1)
        toolbar.layoutColumns = NativeCombinedPopupView.layoutColumns(width: width)
        let showing = NativeCombinedShowing()
        showing.begin(openingID: NativeCombinedAccounts.overviewID, pageOrder: model.pages.map(\.id), width: width)
        let arrow: CGFloat = 11
        let menuBar: CGFloat = 30
        let margin: CGFloat = 64
        let full = NSSize(width: width, height: NativeCombinedPopupView.stripHeight + arrow)
        let size = NSSize(width: full.width + 2 * margin, height: menuBar + 2 + full.height + margin)
        let scene = self.scene(size: size)
        self.addPopup(
            NativeCombinedPopupView(sources: sources, toolbar: toolbar, showing: showing),
            at: NSPoint(x: margin, y: margin),
            full: full,
            scale: 1,
            to: scene)
        self.openItemX = margin + width / 2
        // The combined item carries the gauges of the two most recently used accounts.
        let bar = NSHostingView(rootView: NativeOrbitShowcaseMenuBar(
            items: [model.recentAccounts.prefix(2).map(\.account.gauge)],
            open: 0,
            now: now))
        bar.frame = NSRect(x: 0, y: size.height - menuBar, width: size.width, height: menuBar)
        scene.addSubview(bar)
        self.present(scene, title: "CodexBar Native Showcase")
    }

    /// Nothing behind the window, so the capture keeps transparency and sits on whatever page shows it;
    /// `CODEXBAR_PREVIEW_BACKDROP` names an image instead.
    private static func scene(size: NSSize) -> NSView {
        let scene = NSView(frame: NSRect(origin: .zero, size: size))
        scene.wantsLayer = true
        if let path = ProcessInfo.processInfo.environment["CODEXBAR_PREVIEW_BACKDROP"],
           let image = NSImage(contentsOfFile: path)
        {
            scene.layer?.contents = image
            scene.layer?.contentsGravity = .resizeAspectFill
        }
        return scene
    }

    private static var isDark: Bool {
        CommandLine.arguments.contains("--preview-dark")
    }

    private static func present(_ scene: NSView, title: String) {
        let panel = NativeOrbitShowcasePanel(
            contentRect: scene.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.title = title
        panel.hidesOnDeactivate = false
        panel.isOpaque = scene.layer?.contents != nil
        panel.backgroundColor = panel.isOpaque ? .black : .clear
        panel.contentView = scene
        panel.appearance = NSAppearance(named: self.isDark ? .darkAqua : .aqua)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        self.window = panel
    }

    private static func showServices() {
        let now = Date()
        let cards = self.cards
        let hero = cards.count / 2
        let arrow: CGFloat = 11
        let menuBar: CGFloat = 30
        let margin: CGFloat = 64
        let full = cards.map { card in
            NSSize(
                width: CGFloat(card.accounts.count * 240 + card.accounts.count - 1),
                height: NativeOrbitPopupView.contentHeight(showsFooter: card.accounts.count > 1) + arrow)
        }
        // Each step away from the front recedes; every popover tucks slightly behind its neighbour nearer the front.
        let scales = cards.indices.map { [1, 0.86, 0.74, 0.64][min(3, abs($0 - hero))] as CGFloat }
        let widths = zip(full, scales).map { $0.width * $1 }
        var centers = Array(repeating: CGFloat(0), count: cards.count)
        for index in stride(from: hero + 1, to: cards.count, by: 1) {
            let tuck = 0.11 * min(widths[index], widths[index - 1])
            centers[index] = centers[index - 1] + widths[index - 1] / 2 + widths[index] / 2 - tuck
        }
        for index in stride(from: hero - 1, through: 0, by: -1) {
            let tuck = 0.11 * min(widths[index], widths[index + 1])
            centers[index] = centers[index + 1] - widths[index + 1] / 2 - widths[index] / 2 + tuck
        }
        // The front popover stays in the middle of the picture, however wide each flank is.
        let reach = max(
            -(zip(centers, widths).map { $0 - $1 / 2 }.min() ?? 0),
            zip(centers, widths).map { $0 + $1 / 2 }.max() ?? 0)
        let left = -reach
        let width = 2 * reach + 2 * margin
        let height = menuBar + 2 + full[hero].height + margin
        let middle = margin + full[hero].height / 2
        let scene = self.scene(size: NSSize(width: width, height: height))
        let states = cards.map { self.state(for: $0, now: now) }
        // Back to front.
        for index in cards.indices.sorted(by: { abs($0 - hero) > abs($1 - hero) }) {
            let size = NSSize(width: widths[index], height: full[index].height * scales[index])
            let origin = NSPoint(x: centers[index] - left + margin - size.width / 2, y: middle - size.height / 2)
            let popup = NativeOrbitPopupView(
                state: states[index],
                activate: { _ in },
                signIn: nil,
                acceptsHoverInspection: false)
            self.addPopup(popup, at: origin, full: full[index], scale: scales[index], to: scene)
        }
        self.openItemX = centers[hero] - left + margin
        let gauges = states
            .compactMap { state in (state.accounts.first(where: \.isActive) ?? state.accounts.first)?.gauge }
        let bar = NSHostingView(rootView: NativeOrbitShowcaseMenuBar(items: gauges.map { [$0] }, open: hero, now: now))
        bar.frame = NSRect(x: 0, y: height - menuBar, width: width, height: menuBar)
        scene.addSubview(bar)
        self.present(scene, title: "CodexBar Native Showcase")
    }

    /// A popover's outline: its rounded body and the callout arrow pointing up at its status item.
    static func popoverPath(body: CGRect, arrow: CGFloat, radius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let tipX = body.midX
        let half: CGFloat = 13
        path.move(to: CGPoint(x: body.minX + radius, y: body.maxY))
        path.addLine(to: CGPoint(x: tipX - half - 4, y: body.maxY))
        path.addQuadCurve(
            to: CGPoint(x: tipX - half + 4, y: body.maxY + 3), control: CGPoint(x: tipX - half, y: body.maxY))
        path.addLine(to: CGPoint(x: tipX - 2.5, y: body.maxY + arrow - 1.5))
        path.addQuadCurve(
            to: CGPoint(x: tipX + 2.5, y: body.maxY + arrow - 1.5), control: CGPoint(x: tipX, y: body.maxY + arrow))
        path.addLine(to: CGPoint(x: tipX + half - 4, y: body.maxY + 3))
        path.addQuadCurve(
            to: CGPoint(x: tipX + half + 4, y: body.maxY), control: CGPoint(x: tipX + half, y: body.maxY))
        path.addArc(
            tangent1End: CGPoint(x: body.maxX, y: body.maxY),
            tangent2End: CGPoint(x: body.maxX, y: body.minY),
            radius: radius)
        path.addArc(
            tangent1End: CGPoint(x: body.maxX, y: body.minY),
            tangent2End: CGPoint(x: body.minX, y: body.minY),
            radius: radius)
        path.addArc(
            tangent1End: CGPoint(x: body.minX, y: body.minY),
            tangent2End: CGPoint(x: body.minX, y: body.maxY),
            radius: radius)
        path.addArc(
            tangent1End: CGPoint(x: body.minX, y: body.maxY),
            tangent2End: CGPoint(x: tipX, y: body.maxY),
            radius: radius)
        path.closeSubpath()
        return path
    }

    private static func addPopup(
        _ content: some View,
        at origin: NSPoint,
        full: NSSize,
        scale: CGFloat,
        to scene: NSView)
    {
        let radius: CGFloat = 18
        let arrow: CGFloat = 11
        let body = CGRect(x: 0, y: 0, width: full.width, height: full.height - arrow)
        let path = self.popoverPath(body: body, arrow: arrow, radius: radius)
        // The whole popover, arrow and shadow included, recedes as one: drawn at its real size, then scaled.
        let container = NSView(frame: NSRect(origin: origin, size: full))
        container.wantsLayer = true
        container.layer?.sublayerTransform = CATransform3DMakeScale(scale, scale, 1)
        let shadow = NSView(frame: NSRect(origin: .zero, size: full))
        shadow.wantsLayer = true
        shadow.layer?.shadowPath = path
        shadow.layer?.shadowColor = NSColor.black.cgColor
        shadow.layer?.shadowOpacity = 0.24
        shadow.layer?.shadowRadius = 28
        shadow.layer?.shadowOffset = CGSize(width: 0, height: -14)
        container.addSubview(shadow)
        let material = NSVisualEffectView(frame: NSRect(origin: .zero, size: full))
        material.material = .popover
        material.blendingMode = .withinWindow
        material.state = .active
        material.maskImage = NSImage(size: full, flipped: false) { _ in
            NSColor.black.setFill()
            NSBezierPath(cgPath: path).fill()
            return true
        }
        let host = NSHostingView(rootView: content)
        host.frame = body
        host.wantsLayer = true
        host.layer?.cornerRadius = radius
        host.layer?.cornerCurve = .continuous
        host.layer?.masksToBounds = true
        material.addSubview(host)
        container.addSubview(material)
        scene.addSubview(container)
    }

    private static func state(for card: Card, now: Date) -> NativeOrbitPopupState {
        let state = NativeOrbitPopupState()
        state.now = now
        state.days = card.days
        let color = ProviderDescriptorRegistry.descriptor(for: card.provider).branding.color
        state.accent = Color(red: color.red, green: color.green, blue: color.blue)
        state.accounts = card.accounts.enumerated().map { index, account in
            self.presentation(provider: card.provider, account: account, index: index, now: now)
        }
        state.badges = Dictionary(uniqueKeysWithValues: state.accounts.enumerated().map { index, row in
            (row.id, card.accounts[index].badge)
        })
        state.layoutColumns = card.accounts.count
        state.isReady = true
        state.startup = .live
        return state
    }

    private static func presentation(
        provider: UsageProvider,
        account: Account,
        index: Int,
        now: Date) -> NativeOrbitAccountPresentation
    {
        var random = SplitMix(seed: account.seed)
        let activity = Activity(
            now: now,
            quietAfter: now.addingTimeInterval(-(account.idleFor ?? account.lastUsed)),
            random: &random)
        let windows = account.lanes.map { lane in
            RateWindow(
                usedPercent: lane.used,
                windowMinutes: lane.minutes,
                resetsAt: now.addingTimeInterval(lane.resetsIn),
                resetDescription: nil)
        }
        // A third lane is an additional window under its own identity, as Kimi's monthly quota is.
        let extraLanes = zip(account.lanes, windows).dropFirst(2).map { lane, window in
            NamedRateWindow(
                id: lane.extra?.id ?? "showcase-monthly",
                title: lane.extra?.title ?? "Monthly",
                window: window)
        }
        // The gauge names the first two lanes primary and secondary, the rest by their own identity.
        let laneIDs = account.lanes.enumerated().map { index, lane in
            index == 0 ? "primary" : index == 1 ? "secondary" : lane.extra?.id ?? "showcase-monthly"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        // Requests in quarter-hour slices, as a local log scan reports them, so a range that starts mid-day can split
        // that day's total; each day's total is the sum of its slices.
        let firstDay = Calendar.current.startOfDay(for: now.addingTimeInterval(-30 * 86400))
        let slices = stride(from: firstDay, to: now, by: 900).compactMap { start -> CostUsageTimedEntry? in
            let tokens = Int(account.tokensPerDay * activity.share(from: start, to: min(now, start + 900)))
            guard tokens > 0 else { return nil }
            return .init(
                timestamp: start,
                totalTokens: tokens,
                costUSD: Double(tokens) / 1_000_000 * account.dollarsPerMillion)
        }
        let daily = (0..<31).map { back -> CostUsageDailyReport.Entry in
            let start = Calendar.current.startOfDay(for: now.addingTimeInterval(-Double(back) * 86400))
            let end = start.addingTimeInterval(86400)
            let day = slices.filter { $0.timestamp >= start && $0.timestamp < end }
            return .init(
                date: formatter.string(from: start),
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: day.compactMap(\.totalTokens).reduce(0, +),
                costUSD: day.compactMap(\.costUSD).reduce(0, +),
                modelsUsed: nil,
                modelBreakdowns: nil)
        }
        let monthStart = Calendar.current.dateInterval(of: .month, for: now)?.start ?? now
        let monthToDate = daily.filter {
            (formatter.date(from: $0.date) ?? .distantPast) >= monthStart
        }.compactMap(\.costUSD).reduce(0, +)
        let cost = account.budgetLimit.map {
            ProviderCostSnapshot(used: monthToDate, limit: $0, currencyCode: "USD", period: "Monthly", updatedAt: now)
        }
        let snapshot = UsageSnapshot(
            primary: windows.first,
            secondary: windows.count > 1 ? windows[1] : nil,
            extraRateWindows: extraLanes.isEmpty ? nil : Array(extraLanes),
            providerCost: cost,
            updatedAt: now.addingTimeInterval(-90))
        let gauge = NativeUsageGaugeProjection.state(provider: provider, snapshot: snapshot)
        // The dial orders lanes longest first; each recorded series belongs to the lane with its period.
        let history = gauge.resolvedWindows.compactMap { window -> PlanUtilizationSeriesHistory? in
            guard let index = laneIDs.firstIndex(of: window.id) else { return nil }
            let lane = account.lanes[index]
            return PlanUtilizationSeriesHistory(
                name: .init(rawValue: "nativeQuota:" + window.id),
                windowMinutes: lane.minutes ?? 0,
                entries: activity.quotaEntries(lane: lane, now: now, random: &random))
        }
        let usage = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: nil,
            last30DaysCostUSD: nil,
            historyDays: 31,
            daily: daily.reversed(),
            quotaSlices: slices,
            updatedAt: now)
        var metrics = NativeOrbitAccountMetrics(usage: usage)
        metrics.bankedResets = account.bankedResets
        metrics.usedResets = account.usedResets
        if let extra = account.extra {
            metrics.reportedSpend = ProviderCostSnapshot(
                used: extra.used, limit: extra.limit, currencyCode: "USD", period: "Monthly", updatedAt: now)
        }
        if let budget = cost { metrics.reportedSpend = budget }
        if let balance = account.balance {
            metrics.reportedBalance = .init(value: balance, unit: "USD", isWorkspace: false, updatedAt: now)
        }
        var presentation = NativeOrbitAccountPresentation(
            id: "showcase-\(provider.rawValue)-\(index)",
            label: account.label,
            email: account.label,
            plan: account.plan,
            symbol: "person.crop.circle",
            isActive: account.active,
            canActivate: !account.active,
            gauge: gauge,
            updatedAt: now.addingTimeInterval(-90),
            history: history,
            odometer: nil,
            odometerHelp: nil,
            statusText: nil,
            selection: .none,
            metrics: metrics,
            quotaLabels: UsageStore.nativeOrbitQuotaLabels(provider: provider, snapshot: snapshot),
            quotaWindows: UsageStore.nativeOrbitQuotaWindowMap(provider: provider, snapshot: snapshot))
        presentation.metrics.quotaConsumption = [now.addingTimeInterval(-(account.idleFor ?? account.lastUsed))]
        // As the provider reported them, so they hold for as long as the reading is current.
        presentation.warnings = account.warnings.map { light in
            var light = light
            light.evidence = .providerState
            return light
        }
        return presentation
    }
}

/// Glass draws its tint only in the key window. The scene stays key in appearance while someone works in another
/// app, which can refuse it focus, so a capture never depends on what is frontmost.
private final class NativeOrbitShowcasePanel: NSPanel {
    override var canBecomeKey: Bool {
        true
    }

    override var isKeyWindow: Bool {
        true
    }
}

/// A working person's day: quiet nights, busy afternoons, lighter weekends, with its own texture per account.
/// Its clock is set so now is always a weekday afternoon, whenever the picture is taken; nothing after `quietAfter`.
private struct Activity {
    private let start: Date
    private let step: TimeInterval = 900
    private let cumulative: [Double]

    init(now: Date, quietAfter: Date?, random: inout SplitMix) {
        self.start = now.addingTimeInterval(-40 * 86400)
        let calendar = Calendar.current
        let afternoon = calendar.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 15, minute: 40)) ?? now
        let profile: [Double] = [
            0.02, 0.01, 0.01, 0.01, 0.01, 0.02, 0.05, 0.15, 0.45, 0.8, 1, 1,
            0.7, 0.85, 1, 1, 0.95, 0.8, 0.55, 0.4, 0.45, 0.4, 0.2, 0.06,
        ]
        var total = 0.0
        var values = [0.0]
        var burst = 1.0
        let count = Int(now.timeIntervalSince(self.start) / self.step) + 2
        for index in 0..<count {
            let date = self.start.addingTimeInterval(Double(index) * self.step)
            let clock = afternoon.addingTimeInterval(date.timeIntervalSince(now))
            let hour = calendar.component(.hour, from: clock)
            let weekend = calendar.isDateInWeekend(clock) ? 0.35 : 1
            if index.isMultiple(of: 8) { burst = 0.4 + 1.4 * random.unit() }
            let quiet = quietAfter.map { date >= $0 } ?? false
            total += quiet ? 0 : profile[hour] * weekend * burst * (0.6 + 0.8 * random.unit())
            values.append(total)
        }
        self.cumulative = values
    }

    func level(at date: Date) -> Double {
        let position = max(0, date.timeIntervalSince(self.start) / self.step)
        let index = min(self.cumulative.count - 2, Int(position))
        let fraction = position - Double(index)
        return self.cumulative[index] + (self.cumulative[index + 1] - self.cumulative[index]) * fraction
    }

    /// The share of an average day's activity between two instants.
    func share(from: Date, to: Date) -> Double {
        let days = Double(self.cumulative.count) * self.step / 86400
        let average = (self.cumulative.last ?? 1) / days
        return max(0, self.level(at: to) - self.level(at: from)) / max(0.0001, average)
    }

    /// Quota use climbing with activity through each window and dropping at its reset. Earlier windows use what that
    /// stretch of the month actually did, so quiet nights stay flat; the current window ends at the account's reading.
    func quotaEntries(
        lane: NativeOrbitShowcaseScene.Lane,
        now: Date,
        random: inout SplitMix) -> [PlanUtilizationHistoryEntry]
    {
        let minutes = lane.cycleMinutes
        let period = Double(minutes) * 60
        let reset = now.addingTimeInterval(lane.resetsIn)
        let spacing: TimeInterval = minutes <= 300 ? 600 : 1800
        let first = now.addingTimeInterval(-31 * 86400)
        let span = Double(self.cumulative.count - 1) * self.step
        let perWindow = (self.cumulative.last ?? 1) / max(1, span / period)
        let currentStart = reset.addingTimeInterval(-period)
        // An exhausted window ran out partway through and has stayed at its limit since.
        let reached = lane.used >= 100
            ? currentStart.addingTimeInterval(0.7 * now.timeIntervalSince(currentStart)) : now
        let currentActivity = self.level(at: reached) - self.level(at: currentStart)
        let currentScale = lane.used / max(0.0001, currentActivity)
        // Earlier windows cost what this one does for the same work, unless this one has seen too little to say.
        let elapsed = now.timeIntervalSince(currentStart) / period
        let pastScale = lane.used > 0 && currentActivity >= 0.25 * perWindow * elapsed
            ? currentScale : lane.typical / max(0.0001, perWindow)
        var entries: [PlanUtilizationHistoryEntry] = []
        var cycleEnd = reset
        while cycleEnd > first {
            let cycleStart = cycleEnd.addingTimeInterval(-period)
            let current = cycleEnd == reset
            let stop = current ? now : cycleEnd
            let base = self.level(at: cycleStart)
            let scale = current ? currentScale : pastScale * (0.8 + 0.4 * random.unit())
            var date = max(first, cycleStart.addingTimeInterval(spacing))
            while date <= stop {
                let used = min(100, scale * (self.level(at: date) - base))
                entries.append(.init(capturedAt: date, usedPercent: used, resetsAt: cycleEnd))
                date = date.addingTimeInterval(spacing)
            }
            if current {
                entries.append(.init(capturedAt: now, usedPercent: lane.used, resetsAt: cycleEnd))
            }
            cycleEnd = cycleStart
        }
        return entries.sorted { $0.capturedAt < $1.capturedAt }
    }
}

private struct SplitMix {
    var state: UInt64

    init(seed: UInt64) {
        self.state = seed &* 0x9E37_79B9_7F4A_7C15
    }

    mutating func unit() -> Double {
        self.state &+= 0x9E37_79B9_7F4A_7C15
        var value = self.state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        value ^= value >> 31
        return Double(value >> 11) / Double(1 << 53)
    }
}

/// The menu bar's own gauges, clustered as status items sit, with the open item above the popover's arrow. An item
/// holds one gauge per service, or the combined item's gauges side by side.
private struct NativeOrbitShowcaseMenuBar: View {
    let items: [[ComputeGauge.State]]
    let open: Int
    let now: Date

    private static let gaugeSpacing: CGFloat = 6

    private func width(_ gauge: ComputeGauge.State) -> CGFloat {
        LaurelGauge.layoutWidth(for: 20, windowCount: gauge.resolvedWindows.count)
    }

    private func width(_ item: [ComputeGauge.State]) -> CGFloat {
        item.map { self.width($0) }.reduce(0, +) + Self.gaugeSpacing * CGFloat(max(0, item.count - 1))
    }

    var body: some View {
        // Shift the cluster so the open item, not the cluster's middle, sits over the front popover.
        let widths = self.items.map { self.width($0) + 12 }
        let spacing: CGFloat = 2
        let total = widths.reduce(0, +) + spacing * CGFloat(max(0, widths.count - 1))
        let before = widths.prefix(self.open).reduce(0, +) + spacing * CGFloat(self.open)
        let shift = total / 2 - (before + widths[self.open] / 2)
        GeometryReader { geometry in
            HStack(spacing: spacing) {
                ForEach(Array(self.items.enumerated()), id: \.offset) { index, item in
                    HStack(spacing: Self.gaugeSpacing) {
                        ForEach(Array(item.enumerated()), id: \.offset) { _, gauge in
                            ComputeGauge(state: gauge, size: 20, now: self.now)
                                .environment(\.computeGaugeLayout, .laurel)
                                .foregroundStyle(Color(nsColor: .labelColor))
                                .frame(
                                    width: self.width(gauge),
                                    height: LaurelGauge.layoutHeight(for: 20, windowCount: gauge.resolvedWindows.count))
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.primary.opacity(index == self.open ? 0.14 : 0)))
                }
            }
            .position(x: NativeOrbitShowcaseScene.openItemX + shift, y: geometry.size.height / 2)
        }
    }
}
