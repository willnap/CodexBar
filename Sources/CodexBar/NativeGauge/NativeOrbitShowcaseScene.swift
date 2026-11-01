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
        /// How much of each earlier window was used, when it differs from what this window's pace suggests.
        var pastPeak: Double?
        /// The last reset came this long before it was scheduled, as when a provider resets limits early.
        var earlyBy: TimeInterval?

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
            extra: (id: String, title: String)? = nil,
            pastPeak: Double? = nil) -> Lane
        {
            let elapsed = 1 - resetsIn / (Double(minutes) * 60)
            return Lane(
                minutes: minutes,
                used: max(1, (elapsed * 100 + lead).rounded()),
                resetsIn: resetsIn,
                extra: extra,
                pastPeak: pastPeak)
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
        /// How many hours ahead of the viewer the account holder's day runs, so people elsewhere work at other times.
        var hoursAhead = 0.0
        /// Token use rising (+) or falling (−) through the month, by up to this share either side of `tokensPerDay`,
        /// as one tool takes over from another; quota use keeps its own windows.
        var trend = 0.0
        var seed: UInt64
    }

    struct Card {
        let provider: UsageProvider
        let accounts: [Account]
        var days = 1
    }

    private static var window: NSWindow?
    /// The popups a recording script drives (`CODEXBAR_PREVIEW_PLAY`).
    private static var playStates: [NativeOrbitPopupState] = []
    /// The drawn pointer a `motion` recording moves.
    private static var pointer: NSImageView?
    /// Recording geometry from the scene's top-left: the popup's content origin and width, and its menu bar item.
    private static var playContent = CGRect.zero
    private static var playItem = CGPoint.zero

    /// The combined window's cards with Claude's second login still in use, so both Claude pages sit side by side,
    /// and Codex next, its spare login just reset by OpenAI.
    static var motionCards: [Card] {
        self.cards.map { card in
            var accounts = card.accounts
            // Provider-specific by design: the recording's story is Claude's two logins, then Codex's reset spare.
            switch card.provider {
            case .claude where accounts.count > 1:
                accounts[1].idleFor = 3 * 3600
                accounts[1].lanes = [
                    Lane(minutes: 300, used: 0, resetsIn: 5 * 3600, pastPeak: 86),
                    Lane(minutes: 10080, used: 41, resetsIn: 3.1 * 86400, pastPeak: 90),
                ]
            case .codex where accounts.count > 1:
                // Here OpenAI reset only the spare login, two hours ago, while the Pro login runs mid-week.
                accounts[0].lanes = [
                    Lane(minutes: 300, used: 36, resetsIn: 3 * 3600, pastPeak: 84),
                    .paced(10080, resetsIn: 3.4 * 86400, lead: -2, pastPeak: 89),
                ]
                accounts[1].lanes = [
                    Lane(minutes: 300, used: 0, resetsIn: 5 * 3600, pastPeak: 95),
                    Lane(minutes: 10080, used: 0, resetsIn: 7 * 86400 - 2 * 3600, pastPeak: 97, earlyBy: 2.6 * 86400),
                ]
                accounts[1].bankedResets = 1
            case .claude, .codex:
                break
            default:
                // Quiet for a couple of hours, so Codex follows the two Claude logins into view.
                for index in accounts.indices {
                    accounts[index].idleFor = max(accounts[index].idleFor ?? 0, 2 * 3600)
                }
            }
            return Card(provider: card.provider, accounts: accounts, days: card.days)
        }
    }

    /// Where the front popover's arrow points, for the menu bar's open item.
    fileprivate static var openItemX: CGFloat = 0

    /// Provider-specific by design: the services people code with today, each with the quota windows it actually
    /// reports and its own brand accent. The accounts in use sit early in their windows with plenty left, after
    /// earlier windows drained deep. Lamps light only where something happened: Claude running ahead of its week with a
    /// saved reset in hand, and Codex just reset early by OpenAI. Each service's second login is nearly spent, so it
    /// sorts to the back of the combined window, and its icon tells the two apart.
    static var cards: [Card] {
        let hour: TimeInterval = 3600
        let day: TimeInterval = 86400
        let claude = [
            Account(
                label: "maya@northwind.dev",
                badge: "paintpalette.fill",
                plan: "Claude Max 20x",
                lastUsed: 60,
                lanes: [
                    .paced(300, resetsIn: 4.1 * hour, lead: -3, pastPeak: 88),
                    .paced(10080, resetsIn: 5.7 * day, lead: 8, pastPeak: 94),
                    .paced(
                        10080,
                        resetsIn: 5.7 * day,
                        lead: -3,
                        extra: ("claude-weekly-scoped-fable", "Fable only"),
                        pastPeak: 71),
                ],
                tokensPerDay: 1_300_000_000,
                dollarsPerMillion: 0.52,
                bankedResets: 2,
                usedResets: 1,
                extra: (14, 50),
                warnings: [.init(.newSavedReset, .opportunity, "Saved reset added; 2 available.")],
                trend: 0.1,
                seed: 19),
            Account(
                label: "maya.okafor@icloud.com",
                badge: "house.fill",
                plan: "Claude Max 5x",
                active: false,
                idleFor: 5 * hour,
                lanes: [
                    Lane(minutes: 300, used: 0, resetsIn: 5 * hour, pastPeak: 92),
                    Lane(minutes: 10080, used: 91, resetsIn: 1.4 * day, pastPeak: 96),
                ],
                tokensPerDay: 600_000_000,
                dollarsPerMillion: 0.52,
                bankedResets: 0,
                hoursAhead: 6,
                trend: -0.15,
                seed: 12),
        ]
        let codex = [
            // OpenAI reset everyone's limits two hours ago, two days before the week was due to end.
            Account(
                label: "devon@lumenlabs.io",
                badge: "flask.fill",
                plan: "Pro",
                lastUsed: 3 * 60,
                lanes: [
                    Lane(minutes: 300, used: 36, resetsIn: 3 * hour, pastPeak: 84, earlyBy: 2.5 * hour),
                    Lane(minutes: 10080, used: 3, resetsIn: 7 * day - 2 * hour, pastPeak: 89, earlyBy: 2 * day),
                ],
                tokensPerDay: 1_400_000_000,
                dollarsPerMillion: 0.36,
                bankedResets: 3,
                hoursAhead: -5,
                trend: -0.1,
                seed: 21),
            Account(
                label: "devon.park@gmail.com",
                badge: "person.fill",
                plan: "Plus",
                active: false,
                idleFor: 1.1 * day,
                lanes: [
                    Lane(minutes: 300, used: 0, resetsIn: 5 * hour, pastPeak: 95),
                    Lane(minutes: 10080, used: 93, resetsIn: 2.6 * day, pastPeak: 97),
                ],
                tokensPerDay: 300_000_000,
                dollarsPerMillion: 0.36,
                bankedResets: 0,
                hoursAhead: -8,
                seed: 22),
        ]
        let kimi = [
            Account(
                label: "wei@lattice.cn",
                badge: "briefcase.fill",
                plan: "Moderato",
                lastUsed: 6 * 60,
                lanes: [
                    .paced(10080, resetsIn: 6.1 * day, lead: -2, pastPeak: 90),
                    .paced(300, resetsIn: 4 * hour, lead: -2, pastPeak: 80),
                    .paced(43200, resetsIn: 24 * day, lead: -2, extra: ("kimi-monthly", "Monthly")),
                ],
                tokensPerDay: 900_000_000,
                dollarsPerMillion: 0.30,
                hoursAhead: 8,
                trend: 0.35,
                seed: 91),
            Account(
                label: "zhang.wei@tidepool.cn",
                badge: "house.fill",
                active: false,
                idleFor: 2 * day,
                lanes: [
                    Lane(minutes: 10080, used: 94, resetsIn: 3.3 * day, pastPeak: 95),
                    Lane(minutes: 300, used: 0, resetsIn: 5 * hour, pastPeak: 85),
                    Lane(minutes: 43200, used: 71, resetsIn: 13 * day, extra: ("kimi-monthly", "Monthly")),
                ],
                tokensPerDay: 150_000_000,
                dollarsPerMillion: 0.30,
                hoursAhead: 8,
                seed: 92),
        ]
        let glm = Account(
            label: "li.na@harbor.cn",
            badge: "water.waves",
            lastUsed: 9 * 60,
            lanes: [
                .paced(300, resetsIn: 3.5 * hour, lead: -2, pastPeak: 82),
                .paced(10080, resetsIn: 4.8 * day, lead: -2),
            ],
            tokensPerDay: 700_000_000,
            dollarsPerMillion: 0.24,
            hoursAhead: 7,
            trend: -0.3,
            seed: 51)
        let opencode = Account(
            label: "sam@orbitalworks.ai",
            badge: "chevron.left.forwardslash.chevron.right",
            lastUsed: 12 * 60,
            lanes: [
                .paced(300, resetsIn: 2.8 * hour, lead: -3, pastPeak: 75),
                .paced(10080, resetsIn: 3.9 * day, lead: -2),
                .paced(43200, resetsIn: 17 * day, lead: -2, extra: ("monthly", "Monthly")),
            ],
            tokensPerDay: 500_000_000,
            dollarsPerMillion: 0.42,
            hoursAhead: -4,
            seed: 41)
        // Provider-specific by design: This offline showcase deliberately samples these distinct quota layouts.
        return [
            Card(provider: .kimi, accounts: kimi),
            Card(provider: .codex, accounts: codex),
            Card(provider: .claude, accounts: claude),
            Card(provider: .zai, accounts: [glm]),
            Card(provider: .opencodego, accounts: [opencode]),
        ]
    }

    static func show() {
        if CommandLine.arguments.contains("--preview-scene-services") {
            self.showServices()
        } else if CommandLine.arguments.contains("--preview-scene-accounts") {
            self.showAccounts()
        } else if CommandLine.arguments.contains("--preview-scene-api") {
            self.showAPI()
        } else if CommandLine.arguments.contains("--preview-scene-trouble") {
            self.showTrouble()
        } else if CommandLine.arguments.contains("--preview-scene-motion") {
            self.showCombined(cards: self.motionCards, onDesktop: false)
        } else {
            self.showCombined(cards: self.cards, onDesktop: true)
        }
    }

    /// The combined window as it opens on the All page, three and three-quarter columns wide, so the cut-off page says
    /// there is more to scroll. Pages take the production order; every account still counts on the All page.
    private static func showCombined(cards: [Card], onDesktop: Bool) {
        let now = Date()
        let sources = cards.map { card in
            let state = self.state(for: card, now: now)
            return NativeCombinedAccountSource(provider: card.provider, state: state, activate: { id in
                // Switching logins happens in memory only: the chosen one is active a moment after the click.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(300))
                    state.accounts = card.accounts.enumerated().map { index, account in
                        var account = account
                        account.active = state.accounts.indices.contains(index) && state.accounts[index].id == id
                        return self.presentation(provider: card.provider, account: account, index: index, now: now)
                    }
                }
            })
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
        // The desktop shows three and three-quarter columns; a recording shows four whole ones.
        let width = NativeCombinedPopupView.clampedWidth(
            (onDesktop ? 3.75 : 4) * NativeCombinedPopupView.pitch - 1,
            pageCount: model.pages.count + 1)
        toolbar.layoutColumns = NativeCombinedPopupView.layoutColumns(width: width)
        let showing = NativeCombinedShowing()
        showing.begin(openingID: NativeCombinedAccounts.overviewID, pageOrder: model.pages.map(\.id), width: width)
        self.playStates = sources.map(\.state)
        let popup = NativeCombinedPopupView(sources: sources, toolbar: toolbar, showing: showing)
        let arrow: CGFloat = 11
        let gauges = model.recentAccounts.prefix(2).map { self.menuBarGauge($0.account.gauge) }
        let full = NSSize(width: width, height: NativeCombinedPopupView.stripHeight + arrow)
        guard onDesktop else {
            // For recordings: the window under its item, nothing else.
            let menuBar: CGFloat = 30
            let margin: CGFloat = 40
            let size = NSSize(width: full.width + 2 * margin, height: menuBar + 2 + full.height + margin)
            let scene = self.scene(size: size)
            self.addPopup(popup, at: NSPoint(x: margin, y: margin), full: full, scale: 1, to: scene)
            self.openItemX = margin + full.width / 2
            let bar = NSHostingView(rootView: NativeOrbitShowcaseMenuBar(items: [gauges], open: 0, now: now))
            bar.frame = NSRect(x: 0, y: size.height - menuBar, width: size.width, height: menuBar)
            scene.addSubview(bar)
            self.playContent = CGRect(x: margin, y: menuBar + 2 + arrow, width: full.width, height: full.height - arrow)
            self.playItem = CGPoint(x: margin + full.width / 2, y: menuBar / 2 + 4)
            if ProcessInfo.processInfo.environment["CODEXBAR_PREVIEW_PLAY"] != nil {
                let image = NSCursor.arrow.image
                let pointer = NativeOrbitShowcasePointer(image: image)
                pointer.frame = NSRect(origin: .zero, size: image.size)
                scene.addSubview(pointer)
                self.pointer = pointer
            }
            self.present(scene, title: "CodexBar Native Motion")
            return
        }
        self.presentOnDesktop(popup, full: full, gauges: gauges, now: now, title: "CodexBar Native Showcase")
    }

    /// On the desktop: the popup hangs from its item among the other status items, near the screen's edge, as a
    /// popover does. The picture is cropped to the window with an even margin, so only the menu bar's right end, drawn
    /// at a full screen's width, shows above it.
    private static func presentOnDesktop(
        _ popup: some View,
        full: NSSize,
        gauges: [ComputeGauge.State],
        now: Date,
        title: String)
    {
        let bar = NativeOrbitShowcaseDesktopMenuBar(gauges: gauges, now: now)
        let margin: CGFloat = 32
        let screenWidth: CGFloat = 1512
        // `CODEXBAR_PREVIEW_SCENE_HEIGHT` makes the picture taller, the popup still hanging under the menu bar.
        let height = ProcessInfo.processInfo.environment["CODEXBAR_PREVIEW_SCENE_HEIGHT"].flatMap(Double.init)
            .map { CGFloat($0) } ?? bar.height + 6 + full.height + margin
        let size = NSSize(width: (full.width + 2 * margin).rounded(), height: height)
        let scene = self.scene(size: size, wallpaper: true)
        let origin = NSPoint(x: margin, y: height - bar.height - 6 - full.height)
        let barX = size.width - screenWidth
        self.addPopup(
            popup,
            at: origin,
            full: full,
            scale: 1,
            arrowX: bar.itemCenterX(width: screenWidth) + barX - origin.x,
            to: scene)
        let host = NSHostingView(rootView: bar)
        host.frame = NSRect(x: barX, y: size.height - bar.height, width: screenWidth, height: bar.height)
        scene.addSubview(host)
        self.present(scene, title: title)
    }

    /// The menu bar's gauge leaves out model-specific allowances, which the popup's dial shows.
    private static func menuBarGauge(_ gauge: ComputeGauge.State) -> ComputeGauge.State {
        var gauge = gauge
        if let windows = gauge.windows {
            gauge.windows = windows.filter { !$0.id.hasPrefix("claude-weekly-scoped-") }
        }
        return gauge
    }

    /// One service with several logins in its own popup: the active one marked, the others a click from use.
    private static func showAccounts() {
        let now = Date()
        let hour: TimeInterval = 3600
        let day: TimeInterval = 86400
        // Provider-specific by design: this scene shows Claude's several logins.
        let card = Card(provider: .claude, accounts: [
            Account(
                label: "maya@northwind.dev",
                badge: "paintpalette.fill",
                plan: "Claude Max 20x",
                lastUsed: 60,
                lanes: [
                    // The README's before and after shows the original menu with these same readings.
                    Lane(minutes: 300, used: 31, resetsIn: 4.1 * hour, pastPeak: 88),
                    Lane(minutes: 10080, used: 52, resetsIn: 5.7 * day, pastPeak: 94),
                ],
                tokensPerDay: 1_300_000_000,
                dollarsPerMillion: 0.52,
                bankedResets: 2,
                usedResets: 1,
                extra: (14, 50),
                trend: 0.25,
                seed: 11),
            Account(
                label: "maya.okafor@icloud.com",
                badge: "house.fill",
                plan: "Claude Max 5x",
                active: false,
                idleFor: 9 * hour,
                lanes: [
                    Lane(minutes: 300, used: 0, resetsIn: 5 * hour, pastPeak: 78),
                    Lane(minutes: 10080, used: 24, resetsIn: 4.6 * day, pastPeak: 81),
                ],
                tokensPerDay: 600_000_000,
                dollarsPerMillion: 0.52,
                bankedResets: 1,
                hoursAhead: 6,
                trend: -0.15,
                seed: 12),
            Account(
                label: "maya@studio-ops.dev",
                badge: "building.2.fill",
                plan: "Claude Team",
                active: false,
                idleFor: 6 * hour,
                lanes: [
                    Lane(minutes: 300, used: 0, resetsIn: 5 * hour, pastPeak: 70),
                    Lane(minutes: 10080, used: 12, resetsIn: 5.9 * day, pastPeak: 74),
                ],
                tokensPerDay: 300_000_000,
                dollarsPerMillion: 0.52,
                hoursAhead: -3,
                seed: 13),
        ])
        self.showService(card, now: now, title: "CodexBar Native Accounts")
    }

    /// Pay-as-you-go OpenAI API projects measured against monthly budgets, with no quota windows.
    private static func showAPI() {
        // Provider-specific by design: this scene shows OpenAI API projects on monthly budgets.
        let card = Card(
            provider: .openai,
            accounts: [
                Account(
                    label: "Lumen production",
                    badge: "server.rack",
                    lastUsed: 2 * 60,
                    lanes: [],
                    tokensPerDay: 26_000_000,
                    dollarsPerMillion: 2.1,
                    budgetLimit: 2000,
                    seed: 71),
                Account(
                    label: "Personal projects",
                    badge: "person.fill",
                    active: false,
                    idleFor: 7 * 3600,
                    lanes: [],
                    tokensPerDay: 4_500_000,
                    dollarsPerMillion: 1.3,
                    budgetLimit: 300,
                    seed: 72),
            ],
            days: 30)
        self.showService(card, now: Date(), title: "CodexBar Native API")
    }

    /// A bad hour on one service: an incident, its session spent and its week nearly so, a stale reading and a failed
    /// refresh, with another login a click away.
    private static func showTrouble() {
        let hour: TimeInterval = 3600
        let day: TimeInterval = 86400
        // Provider-specific by design: this scene shows Codex during an incident.
        let card = Card(provider: .codex, accounts: [
            Account(
                label: "devon@lumenlabs.io",
                badge: "flask.fill",
                plan: "Pro",
                lastUsed: 40 * 60,
                lanes: [
                    Lane(minutes: 300, used: 100, resetsIn: 1.6 * hour, pastPeak: 92),
                    Lane(minutes: 10080, used: 83, resetsIn: 2.2 * day, pastPeak: 95),
                ],
                tokensPerDay: 1_400_000_000,
                dollarsPerMillion: 0.36,
                bankedResets: 0,
                usedResets: 2,
                warnings: [
                    .init(.outage, .critical, "OpenAI status: Codex responses are failing for some users."),
                    .init(.usageFailing, .caution, "Usage reads are failing; showing the last good reading."),
                ],
                seed: 31),
            Account(
                label: "devon.park@gmail.com",
                badge: "person.fill",
                plan: "Plus",
                active: false,
                idleFor: 8 * hour,
                lanes: [
                    Lane(minutes: 300, used: 0, resetsIn: 5 * hour, pastPeak: 80),
                    Lane(minutes: 10080, used: 27, resetsIn: 3.8 * day, pastPeak: 76),
                ],
                tokensPerDay: 300_000_000,
                dollarsPerMillion: 0.36,
                bankedResets: 1,
                seed: 32),
        ])
        self.showService(card, now: Date(), title: "CodexBar Native Trouble") { state in
            state.refreshIssue = .init(kind: .failed, detail: "Codex: the service returned 503 Service Unavailable.")
        }
    }

    /// One service's own popup under its menu bar gauge.
    private static func showService(
        _ card: Card,
        now: Date,
        title: String,
        configure: (NativeOrbitPopupState) -> Void = { _ in })
    {
        let state = self.state(for: card, now: now)
        configure(state)
        // `CODEXBAR_PREVIEW_INSPECT_HOURS` holds the charts on a moment that many hours from now, as a still pointer
        // would.
        if let hours = ProcessInfo.processInfo.environment["CODEXBAR_PREVIEW_INSPECT_HOURS"].flatMap(Double.init) {
            state.inspect(now.addingTimeInterval(hours * 3600))
        }
        self.playStates = [state]
        let arrow: CGFloat = 11
        let menuBar: CGFloat = 30
        let margin: CGFloat = 64
        let count = CGFloat(card.accounts.count)
        let full = NSSize(
            width: count * 240 + count - 1,
            height: NativeOrbitPopupView.contentHeight(
                showsFooter: NativeAccountUsePresentation.showsFooter(accounts: state.accounts)) + arrow)
        // `CODEXBAR_PREVIEW_SCENE_HEIGHT` sets the scene's height in points, the popup still hanging under its item, so
        // it can sit level beside another picture.
        let height = ProcessInfo.processInfo.environment["CODEXBAR_PREVIEW_SCENE_HEIGHT"].flatMap(Double.init)
            .map { CGFloat($0) } ?? menuBar + 2 + full.height + margin
        let size = NSSize(width: full.width + 2 * margin, height: height)
        let scene = self.scene(size: size)
        let popup = NativeOrbitPopupView(state: state, activate: { _ in }, signIn: nil, acceptsHoverInspection: false)
        let gauge = (state.accounts.first(where: \.isActive) ?? state.accounts[0]).gauge
        // `CODEXBAR_PREVIEW_DESKTOP` frames it like the hero, under a full menu bar over the wallpaper.
        if ProcessInfo.processInfo.environment["CODEXBAR_PREVIEW_DESKTOP"] != nil {
            self.presentOnDesktop(popup, full: full, gauges: [gauge], now: now, title: title)
            return
        }
        self.addPopup(
            popup,
            at: NSPoint(x: margin, y: height - menuBar - 2 - full.height),
            full: full,
            scale: 1,
            to: scene)
        self.openItemX = margin + full.width / 2
        let bar = NSHostingView(rootView: NativeOrbitShowcaseMenuBar(items: [[gauge]], open: 0, now: now))
        bar.frame = NSRect(x: 0, y: size.height - menuBar, width: size.width, height: menuBar)
        scene.addSubview(bar)
        self.present(scene, title: title)
    }

    /// Nothing behind the window, so the capture keeps transparency and sits on whatever page shows it;
    /// `CODEXBAR_PREVIEW_BACKDROP` names an image instead.
    private static func scene(size: NSSize, wallpaper: Bool = false) -> NSView {
        let scene = NSView(frame: NSRect(origin: .zero, size: size))
        scene.wantsLayer = true
        if let path = ProcessInfo.processInfo.environment["CODEXBAR_PREVIEW_BACKDROP"],
           let image = NSImage(contentsOfFile: path)
        {
            scene.layer?.contents = image
            scene.layer?.contentsGravity = .resizeAspectFill
        } else if wallpaper, let image = self.systemWallpaper() {
            scene.layer?.contents = image
            scene.layer?.contentsGravity = .resizeAspectFill
        }
        return scene
    }

    /// The Solar Gradients wallpaper at midday or after dark to match the appearance, once macOS has downloaded it;
    /// otherwise Sonoma's light or dark variant.
    private static func systemWallpaper() -> CGImage? {
        let solar = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.mobileAssetDesktop/Solar Gradients.heic")
        if let source = CGImageSourceCreateWithURL(solar as CFURL, nil), CGImageSourceGetCount(source) >= 16 {
            // `CODEXBAR_PREVIEW_WALLPAPER_FRAME` picks another time of day, to match a real screenshot beside it.
            let frame = ProcessInfo.processInfo.environment["CODEXBAR_PREVIEW_WALLPAPER_FRAME"].flatMap(Int.init)
                .map { min(max(0, $0), 15) } ?? (self.isDark ? 14 : 7)
            return CGImageSourceCreateImageAtIndex(source, frame, nil)
        }
        let url = URL(fileURLWithPath: "/System/Library/Desktop Pictures/Sonoma.heic")
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let index = self.isDark ? min(1, CGImageSourceGetCount(source) - 1) : 0
        return CGImageSourceCreateImageAtIndex(source, index, nil)
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
        if ProcessInfo.processInfo.environment["CODEXBAR_PREVIEW_PLAY"] != nil {
            // AppKit tells tracking areas where the real pointer is as the window appears, whatever it ignores, so a
            // recording opens in a corner clear of it.
            let mouse = NSEvent.mouseLocation
            if panel.frame.contains(mouse), let visible = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
                let corners = [
                    NSPoint(x: visible.minX, y: visible.maxY - panel.frame.height),
                    NSPoint(x: visible.maxX - panel.frame.width, y: visible.maxY - panel.frame.height),
                    NSPoint(x: visible.minX, y: visible.minY),
                    NSPoint(x: visible.maxX - panel.frame.width, y: visible.minY),
                ]
                if let clear = corners.first(where: { !NSRect(origin: $0, size: panel.frame.size).contains(mouse) }) {
                    panel.setFrameOrigin(clear)
                }
            }
            panel.ignoresMouseEvents = true
        }
        panel.makeKeyAndOrderFront(nil)
        self.window = panel
        self.play(in: panel)
    }

    /// A popover's outline: its rounded body and the callout arrow pointing up at its status item.
    static func popoverPath(body: CGRect, arrow: CGFloat, radius: CGFloat, tipX: CGFloat? = nil) -> CGPath {
        let path = CGMutablePath()
        let tipX = tipX ?? body.midX
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
        arrowX: CGFloat? = nil,
        to scene: NSView)
    {
        let radius: CGFloat = 18
        let arrow: CGFloat = 11
        let body = CGRect(x: 0, y: 0, width: full.width, height: full.height - arrow)
        let path = self.popoverPath(body: body, arrow: arrow, radius: radius, tipX: arrowX)
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
            hoursAhead: account.hoursAhead,
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
        let span = now.timeIntervalSince(firstDay)
        let slices = stride(from: firstDay, to: now, by: 900).compactMap { start -> CostUsageTimedEntry? in
            let trend = 1 + account.trend * (2 * start.timeIntervalSince(firstDay) / span - 1)
            let tokens = Int(account.tokensPerDay * trend * activity.share(from: start, to: min(now, start + 900)))
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
        // The banked-reset inventory, read every hour and unchanged, so an early reset is known to be the provider's.
        let inventory = account.bankedResets.map { banked in
            PlanUtilizationSeriesHistory(
                name: .init(rawValue: "nativeMetric:resets"),
                windowMinutes: 0,
                entries: stride(from: now.addingTimeInterval(-2 * 86400), through: now, by: 3600).map { date in
                    .init(
                        capturedAt: date,
                        usedPercent: 0,
                        resetsAt: nil,
                        nativeMetrics: NativeOrbitMetricObservation(resets: NativeOrbitResetObservation(
                            availableExpirations: Array(repeating: nil, count: banked))))
                })
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
            history: history + (inventory.map { [$0] } ?? []),
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

    override var isMainWindow: Bool {
        true
    }
}

/// A working person's month: blocks of work in the morning and afternoon and some evenings, gaps between them, nothing
/// overnight, light weekends and the odd day off, with heavier and lighter days and bursts within each block. The
/// clock is set so now is always a weekday afternoon for the viewer, whenever the picture is taken, and runs
/// `hoursAhead` for someone elsewhere; nothing after `quietAfter`.
private struct Activity {
    private let start: Date
    private let step: TimeInterval = 900
    private let cumulative: [Double]

    init(now: Date, quietAfter: Date?, hoursAhead: Double = 0, random: inout SplitMix) {
        self.start = now.addingTimeInterval(-40 * 86400)
        let calendar = Calendar.current
        let afternoon = calendar.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 15, minute: 40)) ?? now
        var total = 0.0
        var values = [0.0]
        var burst = 1.0
        var day = -1
        var dayFactor = 1.0
        var blocks: [ClosedRange<Double>] = []
        let count = Int(now.timeIntervalSince(self.start) / self.step) + 2
        for index in 0..<count {
            let date = self.start.addingTimeInterval(Double(index) * self.step)
            let clock = afternoon.addingTimeInterval(date.timeIntervalSince(now) + hoursAhead * 3600)
            let ordinal = calendar.ordinality(of: .day, in: .era, for: clock) ?? 0
            if ordinal != day {
                day = ordinal
                let weekend = calendar.isDateInWeekend(clock)
                // A day off now and then; weekends mostly quiet.
                dayFactor = weekend
                    ? (random.unit() < 0.55 ? 0 : 0.2 + 0.4 * random.unit())
                    : (random.unit() < 0.08 ? 0 : 0.45 + 1.1 * random.unit())
                let morning = 8.5 + 2 * random.unit()
                let lunch = 12.5 + 1.5 * random.unit()
                let evening = 19.5 + 2.5 * random.unit()
                blocks = [
                    morning...min(lunch - 0.4, morning + 2 + 1.5 * random.unit()),
                    lunch...lunch + 2.5 + 2.5 * random.unit(),
                ]
                if random.unit() < 0.35 { blocks.append(evening...evening + 0.8 + 1.8 * random.unit()) }
            }
            let parts = calendar.dateComponents([.hour, .minute], from: clock)
            let hour = Double(parts.hour ?? 0) + Double(parts.minute ?? 0) / 60
            if index.isMultiple(of: 2 + Int(3 * random.unit())) { burst = 0.15 + 1.6 * random.unit() }
            let working = blocks.contains { $0.contains(hour) } && random.unit() > 0.1
            let quiet = quietAfter.map { date >= $0 } ?? false
            total += quiet || !working ? 0 : dayFactor * burst * (0.5 + random.unit())
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

    /// The first moment of activity at or after `date` and before `limit`.
    private func nextActive(from date: Date, before limit: Date) -> Date? {
        var index = max(0, Int((date.timeIntervalSince(self.start) / self.step).rounded(.up)))
        while index < self.cumulative.count - 1 {
            let moment = self.start.addingTimeInterval(Double(index) * self.step)
            if moment >= limit { return nil }
            if self.cumulative[index + 1] > self.cumulative[index] { return moment }
            index += 1
        }
        return nil
    }

    /// Quota use climbing with activity through each window and dropping at its reset, in whole percentages. A
    /// session window (five hours or less) starts at the first request after the last one ran out, as Claude's and
    /// Codex's do, so nights read full; longer windows keep their schedule. Each earlier window costs what its own
    /// activity did, scaled so a busy one reaches `pastPeak`; the current window ends at the account's reading.
    func quotaEntries(
        lane: NativeOrbitShowcaseScene.Lane,
        now: Date,
        random: inout SplitMix) -> [PlanUtilizationHistoryEntry]
    {
        let minutes = lane.cycleMinutes
        let period = Double(minutes) * 60
        let reset = now.addingTimeInterval(lane.resetsIn)
        let spacing: TimeInterval = minutes <= 300 ? 300 : 900
        let first = now.addingTimeInterval(-31 * 86400)
        let currentStart = reset.addingTimeInterval(-period)
        // An exhausted window ran out partway through and has stayed at its limit since.
        let reached = lane.used >= 100
            ? currentStart.addingTimeInterval(0.7 * now.timeIntervalSince(currentStart)) : now
        let currentActivity = self.level(at: reached) - self.level(at: currentStart)
        let currentScale = lane.used / max(0.0001, currentActivity)

        // Earlier windows: (start, end of use, scheduled reset).
        var windows: [(start: Date, end: Date, scheduled: Date)] = []
        // A window cut short by an early reset ends where the current one starts, short of its schedule.
        let early = lane.earlyBy.map { by in
            (start: currentStart.addingTimeInterval(by - period), end: currentStart, scheduled: currentStart + by)
        }
        let limit = early?.start ?? currentStart
        if minutes <= 300 {
            var cursor = first.addingTimeInterval(-period)
            while let start = self.nextActive(from: cursor, before: limit) {
                let end = start.addingTimeInterval(period)
                guard end <= limit else { break }
                windows.append((start, end, end))
                cursor = end
            }
        } else {
            var end = limit
            while end > first {
                windows.insert((end.addingTimeInterval(-period), end, end), at: 0)
                end = end.addingTimeInterval(-period)
            }
        }
        if let early { windows.append(early) }
        let spends = windows.map { self.level(at: $0.end) - self.level(at: $0.start) }.filter { $0 > 0 }.sorted()
        let busy = spends.isEmpty ? 1 : spends[min(spends.count - 1, Int(Double(spends.count) * 0.75))]
        let target = lane.pastPeak ?? lane.typical
        let scales = windows.map { _ in target / max(0.0001, busy) * (0.9 + 0.2 * random.unit()) }

        var entries: [PlanUtilizationHistoryEntry] = []
        var windowIndex = 0
        var date = first
        while date < now {
            while windowIndex < windows.count, windows[windowIndex].end <= date {
                windowIndex += 1
            }
            if date >= currentStart {
                let used = min(
                    100,
                    (currentScale * (self.level(at: min(date, reached)) - self.level(at: currentStart)))
                        .rounded())
                entries.append(.init(capturedAt: date, usedPercent: used, resetsAt: reset))
            } else if windowIndex < windows.count, windows[windowIndex].start <= date {
                let window = windows[windowIndex]
                let used = min(
                    100,
                    (scales[windowIndex] * (self.level(at: date) - self.level(at: window.start)))
                        .rounded())
                entries.append(.init(capturedAt: date, usedPercent: used, resetsAt: window.scheduled))
            } else {
                // Between sessions: nothing running, the whole allowance free.
                entries.append(.init(capturedAt: date, usedPercent: 0, resetsAt: nil))
            }
            date = date.addingTimeInterval(spacing)
        }
        entries.append(.init(capturedAt: now, usedPercent: lane.used, resetsAt: reset))
        return entries
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

/// A desktop's menu bar: the frontmost app's menus on the left, the status items packed to the right edge with the
/// clock last, and the combined item open above its popup.
private struct NativeOrbitShowcaseDesktopMenuBar: View {
    let gauges: [ComputeGauge.State]
    let now: Date

    /// `CODEXBAR_PREVIEW_NOTCH` draws the menu bar of a MacBook with a notch: taller, with larger white items over a
    /// dark
    /// wallpaper, to sit beside a real screenshot from one.
    private static let notch = ProcessInfo.processInfo.environment["CODEXBAR_PREVIEW_NOTCH"] != nil
    let height: CGFloat = notch ? 34 : 26

    private static let font = NSFont.menuBarFont(ofSize: notch ? 15 : 0)
    private static let edge: CGFloat = 12
    private static let spacing: CGFloat = notch ? 22 : 16
    private static let gaugeSpacing: CGFloat = 6
    private static let symbols = ["battery.75percent", "wifi", "magnifyingglass", "switch.2"]
    private static let symbolWidth: CGFloat = notch ? 24 : 20
    private static let gaugeSize: CGFloat = notch ? 24 : 20
    private static let capsuleHeight: CGFloat = notch ? 24 : 22

    private var clock: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "EEE d MMM  HH:mm"
        return formatter.string(from: self.now)
    }

    private func width(_ gauge: ComputeGauge.State) -> CGFloat {
        LaurelGauge.layoutWidth(for: Self.gaugeSize, windowCount: gauge.resolvedWindows.count)
    }

    private var itemWidth: CGFloat {
        self.gauges.map { self.width($0) }.reduce(0, +)
            + Self.gaugeSpacing * CGFloat(max(0, self.gauges.count - 1)) + 12
    }

    private var clockWidth: CGFloat {
        ceil((self.clock as NSString).size(withAttributes: [.font: Self.font]).width)
    }

    /// The combined item's centre, for the popover's arrow.
    func itemCenterX(width: CGFloat) -> CGFloat {
        let symbols = CGFloat(Self.symbols.count) * (Self.symbolWidth + Self.spacing)
        return width - Self.edge - self.clockWidth - Self.spacing - symbols - self.itemWidth / 2
    }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 20) {
                Image(systemName: "applelogo").font(.system(size: 15, weight: .medium))
                Text(verbatim: "Finder").fontWeight(.semibold)
                ForEach(["File", "Edit", "View", "Go", "Window", "Help"], id: \.self) { Text(verbatim: $0) }
            }
            Spacer(minLength: 0)
            HStack(spacing: Self.spacing) {
                HStack(spacing: Self.gaugeSpacing) {
                    ForEach(Array(self.gauges.enumerated()), id: \.offset) { _, gauge in
                        ComputeGauge(state: gauge, size: Self.gaugeSize, now: self.now)
                            .environment(\.computeGaugeLayout, .laurel)
                            .frame(
                                width: self.width(gauge),
                                height: LaurelGauge.layoutHeight(
                                    for: Self.gaugeSize,
                                    windowCount: gauge.resolvedWindows.count))
                    }
                }
                .padding(.horizontal, 6)
                .frame(width: self.itemWidth, height: Self.capsuleHeight)
                .background(Capsule().fill((Self.notch ? Color.white : Color.primary).opacity(0.14)))
                ForEach(Self.symbols, id: \.self) { symbol in
                    Image(systemName: symbol)
                        .font(.system(size: Self.notch ? 17 : 13, weight: Self.notch ? .medium : .regular))
                        .frame(width: Self.symbolWidth)
                }
                Text(verbatim: self.clock).frame(width: self.clockWidth, alignment: .trailing)
            }
        }
        .font(Font(Self.font))
        .foregroundStyle(Self.notch ? Color.white : Color(nsColor: .labelColor))
        .padding(.horizontal, Self.edge)
        .frame(height: self.height)
    }
}

// MARK: - Every service

extension NativeOrbitShowcaseScene {
    private static func showServices() {
        let now = Date()
        let cards = self.cards
        let hero = cards.count / 2
        let arrow: CGFloat = 11
        let menuBar: CGFloat = 30
        let margin: CGFloat = 64
        let states = cards.map { self.state(for: $0, now: now) }
        let full = zip(cards, states).map { card, state in
            NSSize(
                width: CGFloat(card.accounts.count * 240 + card.accounts.count - 1),
                height: NativeOrbitPopupView.contentHeight(
                    showsFooter: NativeAccountUsePresentation.showsFooter(accounts: state.accounts)) + arrow)
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
}

// MARK: - Recordings

extension NativeOrbitShowcaseScene {
    /// For recordings: `CODEXBAR_PREVIEW_PLAY` runs one script two seconds after the scene appears, while it floats
    /// above other windows. `startup` runs the ignition check again. `motion`, on the combined recording scene, has a
    /// drawn pointer use the window as a person would: open it, switch All to money, look back along All's chart and
    /// Claude's, swipe out to the other services and back, step through Week and Month, and return to tokens and Day.
    /// The pointer's moves reach the window as real hover, click and scroll events; the real pointer is ignored, so
    /// wherever it rests over the window it changes nothing.
    private static func play(in panel: NSWindow) {
        guard let script = ProcessInfo.processInfo.environment["CODEXBAR_PREVIEW_PLAY"] else { return }
        panel.level = .floating
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if script == "motion", self.pointer != nil {
                await self.playMotion(in: panel)
            } else if script == "startup" {
                await self.playStartup(self.playStates, panel: panel)
            }
        }
    }

    private static func playMotion(in panel: NSWindow) async {
        let hand = NativeOrbitShowcaseHand(panel: panel, pointer: self.pointer!, seed: 7)
        let content = self.playContent
        let pitch = NativeCombinedPopupView.pitch
        /// Content points: All's money and token readouts, a column's Day chart (its plot about 252–437 points down),
        /// the range control's segments.
        func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: content.minX + x, y: content.minY + y)
        }
        func chart(column: Int, hours: Double, y: CGFloat) -> CGPoint {
            at(CGFloat(column) * pitch + 120 + CGFloat(hours / 24) * 98, y)
        }
        func range(_ index: Int) -> CGPoint {
            CGPoint(x: content.midX + CGFloat(index - 1) * 58, y: content.maxY - 24)
        }
        let start = CGPoint(x: self.playItem.x + 58, y: self.playItem.y + 30)

        hand.place(at: start)
        await hand.rest(0.25)
        await hand.move(to: self.playItem)
        await hand.click()
        Task { @MainActor in await self.playStartup(self.playStates, panel: panel) }
        await hand.rest(0.5)
        // While the dials light, over to All's money readout.
        await hand.glide(through: [at(150, 6), at(52, 30)], seconds: 1.1)
        await hand.rest(0.6)
        await hand.move(to: at(38, 40))
        await hand.click()
        await hand.rest(0.35)

        // Back along All's chart and forward again, then on to Claude's page: into yesterday and ahead to tomorrow.
        await hand.move(to: at(204, 330))
        await hand.glide(through: [at(160, 342), at(70, 352), at(96, 346), at(176, 338)], seconds: 1.15)
        await hand.glide(
            through: [
                chart(column: 1, hours: -2, y: 334),
                chart(column: 1, hours: -14, y: 350),
                chart(column: 1, hours: -10, y: 346),
                chart(column: 1, hours: 8, y: 332),
                chart(column: 1, hours: 15, y: 338),
            ],
            seconds: 1.8)
        // One column along to Codex's spare login: OpenAI reset it two hours ago, so it is worth switching to.
        await hand.move(to: at(2.3 * pitch, 160))
        await hand.swipe(by: -pitch)
        await hand.rest(0.35)
        await hand.move(to: chart(column: 3, hours: 3, y: 330))
        await hand.glide(through: [chart(column: 3, hours: -2, y: 336)], seconds: 0.5)
        await hand.rest(1.1)
        await hand.move(to: at(3 * pitch + 201, 482))
        await hand.rest(0.15)
        await hand.click()
        await hand.rest(1.0)
        await hand.move(to: at(1.6 * pitch, 170))
        await hand.swipe(by: pitch)
        await hand.rest(0.3)

        for index in [1, 2, 0] {
            await hand.move(to: range(index))
            await hand.click()
            await hand.rest(index == 0 ? 0.3 : 0.7)
        }
        await hand.move(to: at(200, 34))
        await hand.click()
        await hand.rest(0.4)
        await hand.move(to: start)
        await hand.rest(0.5)
    }

    /// The ignition check again, with time for every dial to settle.
    private static func playStartup(_ states: [NativeOrbitPopupState], panel: NSWindow) async {
        for state in states {
            state.armStartup(reduceMotion: false)
            state.prepareStartupArtwork(screen: panel.screen, appearance: panel.effectiveAppearance)
        }
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        for state in states {
            Task { @MainActor in await state.runStartup() }
        }
        try? await Task.sleep(for: .seconds(3.2))
    }
}

/// The drawn pointer: seen, never hit, so presses reach whatever lies under its tip.
private final class NativeOrbitShowcasePointer: NSImageView {
    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }
}

/// A drawn pointer moved the way a hand moves a mouse, its moves sent to the window as the events they would make.
/// Moves curve slightly, take longer the further they go (Fitts's law), speed up and settle smoothly, and the longer
/// ones overshoot a little and correct. Hover reaches each view through its tracking areas, entering, moving and
/// exiting as AppKit would deliver it; presses go through the window; a swipe is a trackpad scroll with phases.
@MainActor
private final class NativeOrbitShowcaseHand {
    private let panel: NSWindow
    private let pointer: NSImageView
    private var random: SplitMix
    private var point = CGPoint.zero
    private var inside: Set<ObjectIdentifier> = []

    init(panel: NSWindow, pointer: NSImageView, seed: UInt64) {
        self.panel = panel
        self.pointer = pointer
        self.random = SplitMix(seed: seed)
    }

    /// Puts the pointer at a point measured from the scene's top-left.
    func place(at point: CGPoint) {
        self.point = point
        let image = self.pointer.frame.size
        let scale = image.width / NSCursor.arrow.image.size.width
        let hotSpot = NSCursor.arrow.hotSpot
        self.pointer.setFrameOrigin(NSPoint(
            x: point.x - hotSpot.x * scale,
            y: self.panel.frame.height - point.y - image.height + hotSpot.y * scale))
        self.hover()
    }

    func rest(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    /// An aimed move: curved, Fitts-timed, fastest early, and on longer reaches a small overshoot then a correction.
    func move(to target: CGPoint) async {
        let distance = hypot(target.x - self.point.x, target.y - self.point.y)
        guard distance > 1 else { return }
        let duration = 0.1 + 0.075 * log2(1 + distance / 12)
        if distance > 140 {
            let along = CGPoint(x: (target.x - self.point.x) / distance, y: (target.y - self.point.y) / distance)
            let overshoot = CGFloat(3 + 5 * self.random.unit())
            let past = CGPoint(x: target.x + along.x * overshoot, y: target.y + along.y * overshoot)
            let bend = CGFloat(0.06 + 0.08 * self.random.unit()) * (self.random.unit() < 0.5 ? -1 : 1)
            let control = CGPoint(
                x: (self.point.x + past.x) / 2 - (past.y - self.point.y) * bend,
                y: (self.point.y + past.y) / 2 + (past.x - self.point.x) * bend)
            let origin = self.point
            await self.animate(duration) { s in
                let u = 1 - s
                return CGPoint(
                    x: u * u * origin.x + 2 * u * s * control.x + s * s * past.x,
                    y: u * u * origin.y + 2 * u * s * control.y + s * s * past.y)
            }
            let back = self.point
            await self.animate(0.09) { s in
                CGPoint(x: back.x + (target.x - back.x) * s, y: back.y + (target.y - back.y) * s)
            }
        } else {
            let origin = self.point
            let bend = CGFloat(0.05 * self.random.unit())
            let control = CGPoint(
                x: (origin.x + target.x) / 2 - (target.y - origin.y) * bend,
                y: (origin.y + target.y) / 2 + (target.x - origin.x) * bend)
            await self.animate(duration) { s in
                let u = 1 - s
                return CGPoint(
                    x: u * u * origin.x + 2 * u * s * control.x + s * s * target.x,
                    y: u * u * origin.y + 2 * u * s * control.y + s * s * target.y)
            }
        }
    }

    /// One unbroken sweep through several points, as when reading along a chart: a smooth curve through them, its
    /// speed uneven, sometimes easing back a little before going on.
    func glide(through points: [CGPoint], seconds: Double) async {
        let knots = [self.point, self.point] + points + [points.last ?? self.point]
        let segments = Double(knots.count - 3)
        let wobble = 0.035 + 0.03 * self.random.unit()
        let waves = 1.5 + self.random.unit()
        let phase = self.random.unit() * 2 * Double.pi
        await self.animate(seconds, eased: false) { s in
            let eased = Double(s * s * (3 - 2 * s))
            let progress = min(
                1,
                max(0, eased + wobble * sin(2 * Double.pi * waves * eased + phase) * eased * (1 - eased) * 4))
            let position = progress * segments
            let index = min(Int(position), knots.count - 4)
            let t = CGFloat(position - Double(index))
            let (p0, p1, p2, p3) = (knots[index], knots[index + 1], knots[index + 2], knots[index + 3])
            func spline(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) -> CGFloat {
                0.5 * (2 * b + (c - a) * t + (2 * a - 5 * b + 4 * c - d) * t * t + (3 * b - a - 3 * c + d) * t * t * t)
            }
            return CGPoint(x: spline(p0.x, p1.x, p2.x, p3.x), y: spline(p0.y, p1.y, p2.y, p3.y))
        }
    }

    /// Moves along a path by the clock rather than by frame, so a slow frame drops instead of stretching the move.
    /// Aimed moves peak early and settle long, as reaches do.
    private func animate(_ duration: Double, eased: Bool = true, path: (CGFloat) -> CGPoint) async {
        let clock = ContinuousClock()
        let start = clock.now
        while true {
            let elapsed = start.duration(to: clock.now)
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            let progress = CGFloat(min(1, seconds / duration))
            let shaped = eased ? Self.reach(progress) : progress
            self.place(at: path(shaped))
            if progress >= 1 { return }
            try? await Task.sleep(for: .milliseconds(16))
        }
    }

    /// Minimum-jerk timing, skewed so the hand is quickest in the first part of the move.
    private static func reach(_ t: CGFloat) -> CGFloat {
        let skewed = pow(t, 0.8)
        return skewed * skewed * skewed * (10 - 15 * skewed + 6 * skewed * skewed)
    }

    /// A press and release where the pointer rests; the pointer shrinks a little while the button is down.
    func click() async {
        let size = NSCursor.arrow.image.size
        self.pointer.imageScaling = .scaleProportionallyUpOrDown
        self.pointer.setFrameSize(NSSize(width: size.width * 0.86, height: size.height * 0.86))
        self.place(at: self.point)
        self.send(.leftMouseDown)
        await self.rest(0.11)
        self.send(.leftMouseUp)
        self.pointer.setFrameSize(size)
        self.place(at: self.point)
        await self.rest(0.12)
    }

    /// A two-finger swipe moving the content by about `distance` points, then letting go so the strip settles.
    func swipe(by distance: CGFloat) async {
        guard let scrollView = Self.views(in: self.panel.contentView).compactMap({ $0 as? NSScrollView }).first
        else { return }
        let screen = self.panel.convertPoint(toScreen: self.windowPoint)
        let global = CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.height ?? 0) - screen.y)
        let steps = 14
        var sent: CGFloat = 0
        for step in 0...steps + 1 {
            let delta: CGFloat
            if step == 0 || step > steps {
                delta = 0
            } else {
                // Fast at first, easing off as the fingers slow.
                let t = CGFloat(step) / CGFloat(steps)
                let reached = distance * (1 - pow(1 - t, 3))
                delta = (reached - sent).rounded()
                sent += delta
            }
            guard let event = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 2,
                wheel1: 0,
                wheel2: Int32(delta),
                wheel3: 0)
            else { continue }
            event.location = global
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: step == 0 ? 1 : step > steps ? 4 : 2)
            if let scroll = NSEvent(cgEvent: event) { scrollView.scrollWheel(with: scroll) }
            await self.rest(1.0 / 60)
        }
    }

    private var windowPoint: NSPoint {
        NSPoint(x: self.point.x, y: self.panel.frame.height - self.point.y)
    }

    private func event(_ type: NSEvent.EventType) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type,
            location: self.windowPoint,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: self.panel.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: type == .mouseMoved ? 0 : 1,
            pressure: type == .leftMouseDown ? 1 : 0)
    }

    private func send(_ type: NSEvent.EventType) {
        if let event = self.event(type) { self.panel.sendEvent(event) }
    }

    /// Enters, moves within and exits each view whose tracking area the pointer crosses.
    private func hover() {
        guard let moved = self.event(.mouseMoved) else { return }
        for view in Self.views(in: self.panel.contentView) where view !== self.pointer {
            let local = view.convert(self.windowPoint, from: nil)
            for area in view.trackingAreas {
                let rect = area.options.contains(.inVisibleRect) ? view.visibleRect : area.rect
                let id = ObjectIdentifier(area)
                if rect.contains(local) {
                    if self.inside.insert(id).inserted, area.options.contains(.mouseEnteredAndExited) {
                        view.mouseEntered(with: moved)
                    }
                    if area.options.contains(.mouseMoved) { view.mouseMoved(with: moved) }
                } else if self.inside.remove(id) != nil, area.options.contains(.mouseEnteredAndExited) {
                    view.mouseExited(with: moved)
                }
            }
        }
    }

    private static func views(in root: NSView?) -> [NSView] {
        guard let root else { return [] }
        return [root] + root.subviews.flatMap { self.views(in: $0) }
    }
}
