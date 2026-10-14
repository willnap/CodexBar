import AppKit
import Foundation
import SwiftUI
import Testing
@testable import CodexBar
@testable import CodexBarCore

/// Opt-in visual proof: renders the popup from a read-only copy of real quota history. Set
/// `CODEXBAR_PROJECTION_RENDER_DIR` to a folder holding `history/*.json`; PNGs are written beside it.
@MainActor
struct NativeOrbitProjectionRenderProof {
    private nonisolated static let directory = ProcessInfo.processInfo.environment["CODEXBAR_PROJECTION_RENDER_DIR"]

    @Test(.enabled(if: Self.directory != nil))
    func `projected quota lines are the same in every range`() throws {
        guard let directory = Self.directory else { return }
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        let buckets = PlanUtilizationHistoryStore(directoryURL: root.appendingPathComponent("history")).load()
        var report: [String] = []
        for provider in [UsageProvider.claude, .codex, .kimi] {
            guard let bucket = buckets[provider.instanceID] else { continue }
            let accounts = Self.accounts(provider: provider, bucket: bucket)
            let latest = accounts.flatMap(\.history).filter(\.name.isNativeQuotaObservation)
                .flatMap(\.entries).map(\.capturedAt).max() ?? Date()
            for account in accounts {
                var lines: [Int: [String: [String]]] = [:]
                for days in [1, 7] {
                    let state = NativeOrbitPopupState()
                    state.now = latest.addingTimeInterval(60)
                    state.accounts = accounts
                    state.days = days
                    let projection = state.projection(for: account)
                    let end = state.now.addingTimeInterval(31 * 86400)
                    lines[days] = Dictionary(uniqueKeysWithValues: projection.lanes.map { lane in
                        (lane.id, lane.points(through: end).prefix(8).map {
                            "\(Int($0.date.timeIntervalSince(state.now) / 60))m:\(Int($0.available))"
                        })
                    })
                    report.append("\(provider.rawValue) \(account.id.prefix(10)) d\(days) "
                        + projection.lanes
                        .map { "\($0.id.dropFirst(12)) rate=\($0.rate * 3600) origin=\($0.originUsed)" }
                        .joined(separator: " "))
                }
                for id in lines[1]?.keys.sorted() ?? [] where lines[1]?[id] != lines[7]?[id] {
                    report.append("  DIFF \(id): d1 \(lines[1]?[id] ?? []) | d7 \(lines[7]?[id] ?? [])")
                }
            }
        }
        try report.joined(separator: "\n").write(
            to: root.appendingPathComponent("projection-by-range.txt"), atomically: true, encoding: .utf8)
    }

    @Test(.enabled(if: Self.directory != nil))
    func `render projected popups from copied history`() throws {
        guard let directory = Self.directory else { return }
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        let buckets = PlanUtilizationHistoryStore(directoryURL: root.appendingPathComponent("history")).load()
        var report: [String] = []
        for provider in [UsageProvider.claude, .codex, .kimi] {
            guard let bucket = buckets[provider.instanceID] else { continue }
            let accounts = Self.accounts(provider: provider, bucket: bucket)
            guard !accounts.isEmpty else { continue }
            let latest = accounts.flatMap(\.history).filter(\.name.isNativeQuotaObservation)
                .flatMap(\.entries).map(\.capturedAt).max() ?? Date()
            let now = latest.addingTimeInterval(60)
            for columns in Set([1, min(2, accounts.count)]).sorted() {
                let state = NativeOrbitPopupState()
                state.now = now
                state.accent = Self.accent(provider)
                state.accounts = Array(accounts.prefix(columns))
                state.badges = Dictionary(uniqueKeysWithValues: state.accounts.map { ($0.id, "star") })
                for days in [1, 7] {
                    state.days = days
                    let span = state.chartEnd.timeIntervalSince(state.now)
                    report.append("\(provider.rawValue) cols=\(columns) days=\(days) projecting=\(state.isProjecting) "
                        + state.accounts.map { account in
                            let projection = state.projection(for: account)
                            return "[\(account.id.prefix(18)) active=\(projection.isActive) "
                                + "last=\(projection.lastActivity.map { "\(Int(now.timeIntervalSince($0)))s" } ?? "-") "
                                + projection.lanes.map {
                                    "\($0.id.dropFirst(12)):\(String(format: "%.1f", $0.originUsed))%"
                                        + "@\(String(format: "%.2f", $0.rate * 3600))/h(\($0.rateSource.rawValue))"
                                }.joined(separator: ",") + " events=\(projection.events.count)]"
                        }.joined(separator: " "))
                    let lastReset = state.accounts.first.flatMap { account in
                        NativeOrbitHistoryWidget.resetEvents(state.renderLanes(for: account))
                            .last { $0.date <= state.now && $0.date >= state.chartStart }?.date
                    }
                    let moments: [(String, Date?)] = [
                        ("rest", nil),
                        ("reset", lastReset),
                        ("future", span > 0 ? state.now.addingTimeInterval(span * 0.45) : nil),
                        (
                            "past",
                            state.now.addingTimeInterval(-max(
                                1800,
                                state.now.timeIntervalSince(state.chartStart) * 0.3))),
                    ]
                    for (moment, date) in moments where moment == "rest" || date != nil {
                        state.inspectionDate = date
                        for scheme in [ColorScheme.light, .dark] {
                            let appearance = scheme == .dark ? "dark" : "light"
                            let name = "\(provider.rawValue)-\(columns)col-\(days)d-\(moment)-\(appearance).png"
                            try Self.render(state: state, scheme: scheme, to: root.appendingPathComponent(name))
                        }
                    }
                    state.inspectionDate = nil
                }
            }
        }
        try report.joined(separator: "\n").write(
            to: root.appendingPathComponent("render-report.txt"), atomically: true, encoding: .utf8)
    }

    /// ImageRenderer cannot draw the popup's horizontal scroll view or the asset-catalog ring symbols in a test
    /// process, so each column is composed here from the popup's own widgets with the popup's own inputs: the real
    /// corner complications and history chart, over a plain sketch of the rings' values.
    private static func render(state: NativeOrbitPopupState, scheme: ColorScheme, to url: URL) throws {
        let view = HStack(alignment: .top, spacing: 0) {
            ForEach(Array(state.accounts.enumerated()), id: \.element.id) { index, account in
                if index > 0 { Divider().frame(height: 464).padding(.top, 12) }
                Self.column(account, state: state)
            }
        }
        .padding(.bottom, 8)
        .background(scheme == .dark ? Color(white: 0.16) : Color(white: 0.97))
        .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        // The first pass reports the plot frame (a preference); later passes draw the overlay that depends on it.
        for _ in 0..<4 {
            _ = renderer.cgImage
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        }
        let image = try #require(renderer.cgImage)
        let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try png.write(to: url)
    }

    private static func column(_ account: NativeOrbitAccountPresentation, state: NativeOrbitPopupState) -> some View {
        let live = state.accounts.count == 1 || account.isActive
            ? state.accent : Color.gray.mix(with: state.accent, by: 0.40)
        let accent = NativeOrbitPopupView.accent(
            live,
            inspecting: state.inspectionDate,
            now: state.now,
            start: state.chartStart,
            end: state.chartEnd)
        let projection = state.projection(for: account)
        let windows = NativeOrbitHistoricalInspection.windows(
            account: account,
            date: state.inspectionDate,
            now: state.now,
            days: state.days,
            preparedLanes: state.renderLanes(for: account),
            projection: projection,
            isProjecting: state.isProjecting)
        let blur = NativeOrbitPopupView.dialBlur(
            inspecting: state.inspectionDate, now: state.now, end: state.chartEnd, days: state.days)
        return VStack(spacing: 0) {
            ZStack {
                ForEach(Array(windows.prefix(3).enumerated()), id: \.offset) { lane, window in
                    let radius = NativeOrbitSymbol.radii[lane] * 216 / 256
                    let color = NativeOrbitPalette.color(accent: accent, id: window.id, period: window.period)
                    Circle().stroke(Color.primary.opacity(0.10), lineWidth: 14).frame(width: radius * 2)
                    Circle()
                        .trim(from: 0, to: 0.72 * (1 - (window.usedFraction ?? 1)))
                        .stroke(color.opacity(0.85), style: StrokeStyle(lineWidth: 14, lineCap: .round))
                        .rotationEffect(.degrees(-220))
                        .frame(width: radius * 2)
                    if let countdown = NativeOrbitCountdown(window: window)
                        .value(at: state.inspectionDate ?? state.now)
                    {
                        Circle()
                            .trim(from: 0, to: 0.2 * countdown)
                            .stroke(color.opacity(0.35), style: StrokeStyle(lineWidth: 14, dash: [3, 2]))
                            .rotationEffect(.degrees(50))
                            .frame(width: radius * 2)
                    }
                }
                .blur(radius: blur)
                NativeOrbitInstruments(
                    account: account,
                    days: state.days,
                    now: state.inspectionDate ?? state.now,
                    accent: accent,
                    inspectionDate: state.inspectionDate,
                    projection: projection,
                    liveNow: state.now)
                    .blur(radius: blur)
            }
            .frame(width: 224, height: 240)
            Rectangle().fill(Color(nsColor: .separatorColor).opacity(0.65)).frame(width: 166, height: 0.5)
            NativeOrbitHistoryWidget(
                histories: account.history,
                now: state.now,
                days: state.days,
                accent: accent,
                quotaLabels: account.quotaLabels,
                quotaWindows: account.quotaWindows,
                provider: UsageProvider(rawValue: account.gauge.provider),
                preparedLanes: state.lanes(for: account),
                preparedObservationDates: state.observationDates(for: account),
                selectedDate: state.inspectionDate,
                projection: state.isProjecting ? projection : nil,
                isProjecting: state.isProjecting)
            Text(windows.prefix(3).map { window in
                "\(window.id.prefix(9)) \(window.usedFraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")"
            }.joined(separator: " · "))
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .frame(width: 240)
    }

    private static func accent(_ provider: UsageProvider) -> Color {
        let color = ProviderDescriptorRegistry.descriptor(for: provider).branding.color
        return Color(red: color.red, green: color.green, blue: color.blue)
    }

    /// Account buckets with native quota lanes, newest first, each with a gauge rebuilt from its latest readings.
    private static func accounts(
        provider: UsageProvider,
        bucket: PlanUtilizationHistoryBuckets) -> [NativeOrbitAccountPresentation]
    {
        let rows = bucket.accounts.compactMap { key, histories -> (Date, NativeOrbitAccountPresentation)? in
            let quotas = histories.filter { $0.name.isNativeQuotaObservation && !$0.entries.isEmpty }
            guard let latest = quotas.compactMap(\.latestCapturedAt).max() else { return nil }
            let windows = quotas.compactMap { history -> UsageWindow? in
                guard let entry = history.entries.max(by: { $0.capturedAt < $1.capturedAt }),
                      latest.timeIntervalSince(entry.capturedAt) < 3600, history.windowMinutes > 0 else { return nil }
                let period = Double(history.windowMinutes) * 60
                let units = period >= 28 * 86400 ? 6 : period >= 86400 ? min(24, Int(period / 86400))
                    : min(24, max(1, Int((period / 3600).rounded(.up))))
                var id = String(history.name.rawValue.dropFirst("nativeQuota:".count))
                // Provider-specific by design: Codex's reconciled lane names its weekly quota "weekly".
                if provider == .codex, id == "secondary" { id = "weekly" }
                return UsageWindow(
                    id: id,
                    label: id,
                    period: period,
                    used: entry.usedPercent / 100,
                    countdown: ResetCountdown(
                        units: units,
                        secondsPerUnit: period / Double(units),
                        nextReset: entry.resetsAt,
                        isReliable: entry.resetsAt != nil))
            }
            guard !windows.isEmpty else { return nil }
            var gauge = ComputeGauge.State()
            gauge.provider = provider.rawValue
            gauge.windows = Array(windows.prefix(3))
            var metrics = NativeOrbitAccountMetrics()
            metrics = metrics.at(latest, observedAt: latest, history: histories)
            var row = NativeOrbitAccountPresentation(
                id: key,
                label: String(key.prefix(14)),
                email: nil,
                symbol: "person.crop.circle",
                isActive: false,
                canActivate: false,
                gauge: gauge,
                updatedAt: latest,
                history: histories,
                odometer: nil,
                odometerHelp: nil,
                statusText: nil,
                selection: .none)
            row.metrics = metrics
            return (latest, row)
        }
        let newest = rows.map(\.0).max() ?? .distantPast
        return rows.filter { $0.0 > newest.addingTimeInterval(-86400) }.sorted { $0.0 > $1.0 }.map(\.1)
    }
}
