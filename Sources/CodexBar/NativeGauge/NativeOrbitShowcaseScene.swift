import AppKit
import CodexBarCore
import SwiftUI

/// Development only (`--native-preview --preview-scene`): one window composing popups and their menu bar gauges over
/// the image at `CODEXBAR_PREVIEW_BACKDROP`, for README artwork. Every popup is the production view fed a month of
/// generated, internally consistent usage for fictitious accounts; nothing is drawn to imitate it.
@MainActor
enum NativeOrbitShowcaseScene {
    struct Lane {
        /// Nil when the provider reports a pool without a window length, as Codebuff's credits.
        let minutes: Int?
        let used: Double
        let resetsIn: TimeInterval

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
        static func paced(_ minutes: Int, resetsIn: TimeInterval, lead: Double = -1) -> Lane {
            let elapsed = 1 - resetsIn / (Double(minutes) * 60)
            return Lane(minutes: minutes, used: max(1, elapsed * 100 + lead), resetsIn: resetsIn)
        }
    }

    struct Account {
        let label: String
        let badge: String
        var active = true
        /// How long ago an account not in use was last used; its quota stays where that left it.
        var idleFor: TimeInterval?
        var lanes: [Lane]
        var tokensPerDay: Double
        var dollarsPerMillion: Double
        var bankedResets: Int?
        var usedResets = 0
        var extra: (used: Double, limit: Double)?
        /// A monthly budget whose use is the account's own month-to-date spend.
        var budgetLimit: Double?
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

    /// Provider-specific by design: distinct providers, each with the quota windows it actually reports and its own
    /// brand accent, in situations a reader can tell apart at a glance. Left to right; the middle card is in front.
    static var cards: [Card] {
        let hour: TimeInterval = 3600
        let day: TimeInterval = 86400
        // Amp Free: a daily meter, no spend, and a heavy day that will use it up before it renews.
        let amp = Account(
            label: "ines@fieldnotes.app",
            badge: "leaf.fill",
            lanes: [.paced(1440, resetsIn: 7 * hour, lead: 1.5)],
            tokensPerDay: 3_300_000,
            dollarsPerMillion: 0,
            seed: 41)
        let codebuff = Account(
            label: "jo@pinecrest.io",
            badge: "tree.fill",
            lanes: [Lane(minutes: nil, used: 37, resetsIn: 19 * day), .paced(10080, resetsIn: 3.6 * day)],
            tokensPerDay: 5_600_000,
            dollarsPerMillion: 1.1,
            seed: 31)
        let devonLab = Account(
            label: "devon@lumenlabs.io",
            badge: "flask.fill",
            lanes: [.paced(10080, resetsIn: 4.9 * day)],
            tokensPerDay: 9_400_000,
            dollarsPerMillion: 1.4,
            bankedResets: 3,
            seed: 21)
        let devonPersonal = Account(
            label: "devon.park@gmail.com",
            badge: "person.fill",
            active: false,
            idleFor: 1.2 * day,
            lanes: [Lane(minutes: 10080, used: 46, resetsIn: 3.4 * day)],
            tokensPerDay: 3_100_000,
            dollarsPerMillion: 1.4,
            bankedResets: 0,
            seed: 22)
        let mayaStudio = Account(
            label: "maya@northwind.studio",
            badge: "paintpalette.fill",
            // A light session: well under pace, so it has room to spare.
            lanes: [Lane(minutes: 300, used: 29, resetsIn: 1.7 * hour), .paced(10080, resetsIn: 5.3 * day)],
            tokensPerDay: 5_200_000,
            dollarsPerMillion: 3.1,
            bankedResets: 2,
            usedResets: 1,
            extra: (18, 50),
            seed: 11)
        let mayaHome = Account(
            label: "maya.okafor@icloud.com",
            badge: "house.fill",
            active: false,
            idleFor: 6 * hour,
            // Its last session ran out its five hours unused since, so none is running.
            lanes: [
                Lane(minutes: 300, used: 0, resetsIn: 5 * hour),
                Lane(minutes: 10080, used: 66, resetsIn: 2.1 * day),
            ],
            tokensPerDay: 2_600_000,
            dollarsPerMillion: 3.1,
            bankedResets: 1,
            seed: 12)
        let stepfun = Account(
            label: "an.li@tidewater.cn",
            badge: "water.waves",
            lanes: [.paced(300, resetsIn: 2.2 * hour), .paced(10080, resetsIn: 4.2 * day)],
            tokensPerDay: 6_100_000,
            dollarsPerMillion: 0.8,
            seed: 51)
        let bedrock = Account(
            label: "ops@meridian.dev",
            badge: "server.rack",
            lanes: [],
            tokensPerDay: 6_400_000,
            dollarsPerMillion: 0.9,
            budgetLimit: 400,
            seed: 71)
        // Exhausted: this month's credits are gone until the plan renews, with a second account to switch to.
        let kiro = Account(
            label: "theo@brightline.co",
            badge: "bolt.fill",
            lanes: [Lane(minutes: 43200, used: 100, resetsIn: 9 * day)],
            tokensPerDay: 2_900_000,
            dollarsPerMillion: 1.8,
            seed: 61)
        let kiroPersonal = Account(
            label: "theo.reyes@fastmail.com",
            badge: "sailboat.fill",
            active: false,
            idleFor: 2 * day,
            lanes: [Lane(minutes: 43200, used: 38, resetsIn: 17 * day)],
            tokensPerDay: 1_400_000,
            dollarsPerMillion: 1.8,
            seed: 62)
        // Provider-specific by design: This offline showcase deliberately samples these distinct quota layouts.
        return [
            Card(provider: .amp, accounts: [amp]),
            Card(provider: .codebuff, accounts: [codebuff], days: 7),
            Card(provider: .codex, accounts: [devonLab, devonPersonal], days: 7),
            Card(provider: .claude, accounts: [mayaStudio, mayaHome]),
            Card(provider: .stepfun, accounts: [stepfun]),
            Card(provider: .bedrock, accounts: [bedrock], days: 30),
            Card(provider: .kiro, accounts: [kiro, kiroPersonal], days: 30),
        ]
    }

    static func show() {
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
        let panel = NativeOrbitPreviewPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.title = "CodexBar Native Showcase"
        panel.hidesOnDeactivate = false
        panel.isOpaque = true
        let scene = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        scene.wantsLayer = true
        if let path = ProcessInfo.processInfo.environment["CODEXBAR_PREVIEW_BACKDROP"],
           let image = NSImage(contentsOfFile: path)
        {
            scene.layer?.contents = image
            scene.layer?.contentsGravity = .resizeAspectFill
        }
        let states = cards.map { self.state(for: $0, now: now) }
        // Back to front.
        for index in cards.indices.sorted(by: { abs($0 - hero) > abs($1 - hero) }) {
            let size = NSSize(width: widths[index], height: full[index].height * scales[index])
            let origin = NSPoint(x: centers[index] - left + margin - size.width / 2, y: middle - size.height / 2)
            self.addPopup(state: states[index], at: origin, full: full[index], scale: scales[index], to: scene)
        }
        self.openItemX = centers[hero] - left + margin
        let gauges = states
            .compactMap { state in (state.accounts.first(where: \.isActive) ?? state.accounts.first)?.gauge }
        let bar = NSHostingView(rootView: NativeOrbitShowcaseMenuBar(gauges: gauges, open: hero, now: now))
        bar.frame = NSRect(x: 0, y: height - menuBar, width: width, height: menuBar)
        scene.addSubview(bar)
        panel.contentView = scene
        panel.appearance = NSAppearance(named: .aqua)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        self.window = panel
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
        state: NativeOrbitPopupState,
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
        let host = NSHostingView(rootView: NativeOrbitPopupView(
            state: state,
            activate: { _ in },
            signIn: nil,
            acceptsHoverInspection: false))
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
            quietAfter: account.idleFor.map { now.addingTimeInterval(-$0) },
            random: &random)
        let windows = account.lanes.map { lane in
            RateWindow(
                usedPercent: lane.used,
                windowMinutes: lane.minutes,
                resetsAt: now.addingTimeInterval(lane.resetsIn),
                resetDescription: nil)
        }
        // A third lane is an additional window, as Kimi's monthly quota is; the dial titles it by its period.
        let extraLanes = windows.dropFirst(2).map { window in
            // Provider-specific by design: Kimi's monthly quota keeps its own lane identity.
            NamedRateWindow(
                id: provider == .kimi ? "kimi-monthly" : "showcase-monthly",
                title: "Monthly",
                window: window)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        let daily = (0..<31).map { back -> CostUsageDailyReport.Entry in
            let start = Calendar.current.startOfDay(for: now.addingTimeInterval(-Double(back) * 86400))
            let end = min(now, start.addingTimeInterval(86400))
            let tokens = Int(account.tokensPerDay * activity.share(from: start, to: end))
            return .init(
                date: formatter.string(from: start),
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: tokens,
                costUSD: Double(tokens) / 1_000_000 * account.dollarsPerMillion,
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
            // A pool without a length is laid out with a nominal one-second period, as the store records it.
            guard let lane = account.lanes.first(where: { lane in
                lane.minutes.map { Double($0) * 60 == window.period } ?? (window.period == 1)
            }) else { return nil }
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
            updatedAt: now)
        var metrics = NativeOrbitAccountMetrics(usage: usage)
        metrics.bankedResets = account.bankedResets
        metrics.usedResets = account.usedResets
        if let extra = account.extra {
            metrics.reportedSpend = ProviderCostSnapshot(
                used: extra.used, limit: extra.limit, currencyCode: "USD", period: "Monthly", updatedAt: now)
        }
        if let budget = cost { metrics.reportedSpend = budget }
        return NativeOrbitAccountPresentation(
            id: "showcase-\(provider.rawValue)-\(index)",
            label: account.label,
            email: account.label,
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

/// The menu bar's own gauges, clustered as status items sit, with the front popover's item open above its arrow.
private struct NativeOrbitShowcaseMenuBar: View {
    let gauges: [ComputeGauge.State]
    let open: Int
    let now: Date

    private func width(_ gauge: ComputeGauge.State) -> CGFloat {
        LaurelGauge.layoutWidth(for: 20, windowCount: gauge.resolvedWindows.count)
    }

    var body: some View {
        // Shift the cluster so the open item, not the cluster's middle, sits over the front popover.
        let widths = self.gauges.map { self.width($0) + 12 }
        let spacing: CGFloat = 2
        let total = widths.reduce(0, +) + spacing * CGFloat(max(0, widths.count - 1))
        let before = widths.prefix(self.open).reduce(0, +) + spacing * CGFloat(self.open)
        let shift = total / 2 - (before + widths[self.open] / 2)
        GeometryReader { geometry in
            HStack(spacing: spacing) {
                ForEach(Array(self.gauges.enumerated()), id: \.offset) { index, gauge in
                    ComputeGauge(state: gauge, size: 20, now: self.now)
                        .environment(\.computeGaugeLayout, .laurel)
                        .foregroundStyle(Color(nsColor: .labelColor))
                        .frame(
                            width: self.width(gauge),
                            height: LaurelGauge.layoutHeight(for: 20, windowCount: gauge.resolvedWindows.count))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.white.opacity(index == self.open ? 0.34 : 0)))
                }
            }
            .position(x: NativeOrbitShowcaseScene.openItemX + shift, y: geometry.size.height / 2)
        }
    }
}
