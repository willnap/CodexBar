import AppKit
import Charts
import CodexBarCore
import SwiftUI

/// Recorded totals in trailing windows, all accounts sharing the selected absolute unit and scale.
struct NativeCombinedTokenHistory {
    struct Point: Identifiable, Equatable {
        let date: Date
        let value: Double
        let segment: Int
        let sampleIndex: Int
        var id: Int {
            self.sampleIndex
        }
    }

    struct Series: Identifiable, Equatable {
        let id: String
        let points: [Point]
    }

    /// Both units are prepared together so selecting a unit never empties the plot or starts new work.
    struct Prepared {
        let tokenSeries: [Series]
        let moneySeries: [Series]
        let moneyCurrency: String?

        func series(for metric: NativeCombinedMetric) -> [Series] {
            switch metric {
            case .tokens: self.tokenSeries
            case let .money(currency): currency == self.moneyCurrency ? self.moneySeries : []
            }
        }
    }

    private struct Builder {
        var points: [String: [Point]] = [:]
        var segments: [String: Int] = [:]
        var gaps = Set<String>()

        mutating func append(
            id: String, reading: NativeOrbitMetricSummary, date: Date, sampleIndex: Int, metric: NativeCombinedMetric)
        {
            if let value = metric.value(reading) {
                self.gaps.remove(id)
                self.points[id, default: []].append(.init(
                    date: date, value: value, segment: self.segments[id, default: 0], sampleIndex: sampleIndex))
            } else if self.points[id] != nil, self.gaps.insert(id).inserted {
                self.segments[id, default: 0] += 1
            }
        }

        func finish(model: NativeCombinedAccounts) -> [Series] {
            model.pages.compactMap { page in self.points[page.id].map { Series(id: page.id, points: $0) } }
        }
    }

    private struct Preparation {
        var tokens = Builder()
        var money = Builder()
        let moneyCurrency: String?

        mutating func append(model: NativeCombinedAccounts, days: Int, date: Date, sampleIndex: Int) {
            // Reading a sample can scan account history. Share that scan between the two unit builders.
            for (page, reading) in model.readings(days: days, now: date) {
                self.tokens.append(id: page.id, reading: reading, date: date, sampleIndex: sampleIndex, metric: .tokens)
                if let currency = self.moneyCurrency {
                    self.money.append(
                        id: page.id,
                        reading: reading,
                        date: date,
                        sampleIndex: sampleIndex,
                        metric: .money(currency: currency))
                }
            }
        }

        func finish(model: NativeCombinedAccounts) -> Prepared {
            Prepared(
                tokenSeries: self.tokens.finish(model: model),
                moneySeries: self.money.finish(model: model),
                moneyCurrency: self.moneyCurrency)
        }
    }

    private static func dates(days: Int, now: Date) -> [Date] {
        let start = NativeOrbitChartAxis.start(now: now, days: days)
        let span = now.timeIntervalSince(start)
        return (0...48).map { start.addingTimeInterval(span * Double($0) / 48) }
    }

    static func make(
        model: NativeCombinedAccounts, days: Int, now: Date, metric: NativeCombinedMetric = .tokens) -> [Series]
    {
        let currency: String? = if case let .money(currency) = metric {
            currency
        } else { nil }
        var preparation = Preparation(moneyCurrency: currency)
        for (sampleIndex, date) in self.dates(days: days, now: now).enumerated() {
            preparation.append(model: model, days: days, date: date, sampleIndex: sampleIndex)
        }
        return preparation.finish(model: model).series(for: metric)
    }

    /// Opening, scrolling and account refreshes can interrupt preparation between plotted instants.
    @MainActor static func prepare(
        model: NativeCombinedAccounts, days: Int, now: Date, moneyCurrency: String?) async -> Prepared?
    {
        var preparation = Preparation(moneyCurrency: moneyCurrency)
        for (sampleIndex, date) in self.dates(days: days, now: now).enumerated() {
            await Task.yield()
            guard !Task.isCancelled else { return nil }
            preparation.append(model: model, days: days, date: date, sampleIndex: sampleIndex)
        }
        return preparation.finish(model: model)
    }
}

struct NativeCombinedTokenChart: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    let model: NativeCombinedAccounts
    let state: NativeOrbitPopupState
    var metric = NativeCombinedMetric.tokens
    let accents: [String: Color]
    let labels: [String: String]
    @State private var presentation = NativeCombinedChartPresentation()
    @State private var plotFrame: CGRect = .zero

    private typealias Input = NativeCombinedChartPresentation.Request

    private var input: Input {
        Input(
            now: self.state.now,
            days: self.state.days,
            moneyCurrency: self.moneyCurrency,
            ids: self.model.pages.map(\.id),
            accounts: self.model.pages.map(\.account))
    }

    private var axis: NativeOrbitHistoryWidget {
        NativeOrbitHistoryWidget(
            histories: [],
            now: self.displayedRequest.now,
            days: self.displayedRequest.days,
            selectedDate: self.state.inspectionDate)
    }

    private var displayedSnapshot: NativeCombinedChartPresentation.Snapshot? {
        self.presentation.snapshot(days: self.state.days)
    }

    private var displayedRequest: Input {
        self.displayedSnapshot?.request ?? self.input
    }

    private var moneyCurrency: String? {
        let costs = self.model.summary(days: self.state.days, now: self.state.now).costs
        return costs.count == 1 ? costs.keys.first : nil
    }

    private var shownSeries: [NativeCombinedTokenHistory.Series] {
        self.displayedSnapshot?.history.series(for: self.metric) ?? []
    }

    private var maximum: Double {
        let peak = self.shownSeries.flatMap(\.points).map(\.value).max() ?? 0
        return peak > 0 ? peak : 1
    }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 12)
            NativeCombinedStaticChart(
                configuration: .init(
                    series: self.shownSeries,
                    start: self.axis.start,
                    now: self.displayedRequest.now,
                    metric: self.metric,
                    maximum: self.maximum,
                    accents: self.accents,
                    gridDates: self.axis.gridDates,
                    dark: self.colorScheme == .dark,
                    reduceMotion: self.reduceMotion,
                    hasPreparedData: self.displayedSnapshot != nil),
                onSelect: {
                    guard self.displayedRequest.days == self.state.days else { return }
                    self.state.inspect($0, source: "hover")
                },
                onFrame: { if self.plotFrame != $0 { self.plotFrame = $0 } })
                .overlay(alignment: .topLeading) { self.marker }
            NativeOrbitChartAxisRow(
                dates: self.axis.axisDates,
                now: self.displayedRequest.now,
                frame: self.plotFrame,
                accent: .primary,
                inspecting: self.state.inspectionDate != nil,
                label: self.axis.axisLabel)
        }
        .padding(.horizontal, 14).padding(.bottom, 6)
        .frame(width: 224, height: 224)
        .task(id: self.input.source) {
            let input = self.input
            let model = self.model
            let labels = self.labels
            self.presentation.begin(input)
            if let snapshots = await NativeCombinedChartPresentation.prepare(
                request: input, model: model, labels: labels),
                !Task.isCancelled, self.input.source == input.source
            {
                withAnimation(self.reduceMotion ? nil : NativeCombinedMetricTransition.animation) {
                    _ = self.presentation.publish(snapshots)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("combined-history")
        .accessibilityLabel(self.metric.title + ", " + NativeOrbitTooltip.range(days: self.displayedRequest.days))
        .accessibilityValue(self.readings.map {
            let label = self.displayedSnapshot?.labels[$0.id] ?? self.labels[$0.id] ?? $0.id
            return "\(label): \(self.metric.formatted($0.value))"
        }
        .joined(separator: ", "))
    }

    private struct Reading: Identifiable {
        let id: String
        let value: Double
    }

    private var readings: [Reading] {
        (self.displayedSnapshot?.model ?? self.model).readings(
            days: self.displayedRequest.days,
            now: self.state.inspectionDate ?? self.displayedRequest.now)
            .compactMap { page, reading in self.metric.value(reading).map { Reading(id: page.id, value: $0) } }
    }

    @ViewBuilder
    private var marker: some View {
        let frame = self.plotFrame
        if frame.width > 0, frame.height > 16 {
            let date = self.state.inspectionDate ?? self.displayedRequest.now
            let x = self.axis.plotX(date, in: frame)
            ZStack(alignment: .topLeading) {
                NativeOrbitChartMarkerLine(
                    accent: .primary,
                    inspecting: self.state.inspectionDate != nil,
                    height: frame.height)
                    .position(x: x, y: frame.midY)
                GlassEffectContainer(spacing: 3) {
                    ZStack(alignment: .topLeading) {
                        ForEach(self.readings) { reading in
                            self.axis.readingBead(self.accents[reading.id] ?? .primary, .recorded)
                                .position(
                                    x: x,
                                    y: frame.maxY - 3
                                        - CGFloat(min(1, reading.value / self.maximum)) * (frame.height - 6))
                        }
                    }
                }
            }
            .background(alignment: .topLeading) {
                Capsule().fill(Color.secondary.opacity(0.55)).frame(width: 1.5, height: frame.height)
                    .position(x: frame.maxX, y: frame.midY)
                    .opacity(self.state.inspectionDate == nil ? 0 : 1)
            }
            .animation(
                NativeOrbitChartCursorMotion.animation(
                    inspecting: self.state.inspectionDate != nil, reduceMotion: self.reduceMotion),
                value: self.state.inspectionDate)
            .animation(self.reduceMotion ? nil : NativeCombinedMetricTransition.animation, value: self.metric)
            .animation(self.reduceMotion ? nil : NativeCombinedMetricTransition.animation, value: self.accents)
            .animation(
                self.reduceMotion ? nil : NativeCombinedMetricTransition.animation,
                value: self.displayedSnapshot?.request)
            .transaction {
                $0 = NativeOrbitChartCursorMotion.transaction($0, inspecting: self.state.inspectionDate != nil)
            }
            .allowsHitTesting(false)
        }
    }
}

/// The chart's marks stay hosted independently while the shared marker, pie and readouts follow the pointer.
private struct NativeCombinedStaticChart: NSViewRepresentable {
    struct Configuration: Equatable {
        let series: [NativeCombinedTokenHistory.Series]
        let start: Date
        let now: Date
        let metric: NativeCombinedMetric
        let maximum: Double
        let accents: [String: Color]
        let gridDates: [Date]
        let dark: Bool
        let reduceMotion: Bool
        let hasPreparedData: Bool
    }

    let configuration: Configuration
    let onSelect: (Date?) -> Void
    let onFrame: (CGRect) -> Void

    final class Coordinator {
        var configuration: Configuration?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSHostingView<AnyView> {
        let host = NSHostingView(rootView: self.content)
        host.sizingOptions = []
        context.coordinator.configuration = self.configuration
        return host
    }

    func updateNSView(_ host: NSHostingView<AnyView>, context: Context) {
        guard context.coordinator.configuration != self.configuration else { return }
        context.coordinator.configuration = self.configuration
        host.rootView = self.content
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSHostingView<AnyView>, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 196, height: 187))
    }

    private var content: AnyView {
        AnyView(NativeCombinedRecordedPlot(configuration: self.configuration, onSelect: self.onSelect)
            .environment(\.colorScheme, self.configuration.dark ? .dark : .light)
            .onPreferenceChange(NativeCombinedPlotFrameKey.self, perform: self.onFrame))
    }
}

private struct NativeCombinedRecordedPlot: View {
    let configuration: NativeCombinedStaticChart.Configuration
    let onSelect: (Date?) -> Void

    private var gridInk: Color {
        Color.primary.opacity(self.configuration.dark ? 0.10 : 0.065)
    }

    var body: some View {
        Chart {
            ForEach(Array(self.configuration.gridDates.enumerated()), id: \.offset) { _, date in
                RuleMark(x: .value("Grid", date)).lineStyle(StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(self.gridInk)
            }
            ForEach(self.configuration.series) { series in
                let color = self.configuration.accents[series.id] ?? .primary
                ForEach(series.points) { point in
                    AreaMark(
                        x: .value("Time", point.date),
                        y: .value("Amount", point.value / self.configuration.maximum),
                        series: .value("Account", "\(series.id):\(point.segment)"),
                        stacking: .unstacked)
                        .interpolationMethod(.linear)
                        .foregroundStyle(LinearGradient(
                            colors: [color.opacity(self.configuration.dark ? 0.18 : 0.10), color.opacity(0.015)],
                            startPoint: .top,
                            endPoint: .bottom))
                        .alignsMarkStylesWithPlotArea()
                    LineMark(
                        x: .value("Time", point.date),
                        y: .value("Amount", point.value / self.configuration.maximum),
                        series: .value("Account", "\(series.id):\(point.segment)"))
                        .interpolationMethod(.linear)
                        .lineStyle(StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round))
                        .foregroundStyle(color)
                }
                if let latest = series.points.last {
                    PointMark(
                        x: .value("Time", latest.date),
                        y: .value("Amount", latest.value / self.configuration.maximum))
                        .symbolSize(14).foregroundStyle(color)
                }
            }
        }
        .chartXScale(
            domain: self.configuration.start...self.configuration.now,
            range: .plotDimension(startPadding: 0, endPadding: 0))
        .chartYScale(
            // Animate normalized mark heights against a fixed scale. Animating both the absolute values
            // and their domain makes Charts move the curves and the independently hosted beads differently.
            domain: 0...1,
            range: .plotDimension(startPadding: 3, endPadding: 3))
        .chartLegend(.hidden).chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 0.5, 1]) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(self.gridInk)
            }
        }
        .chartPlotStyle { $0.clipShape(Rectangle()) }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                let frame = proxy.plotFrame.map { geometry[$0] } ?? .zero
                Color.clear.contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case let .active(location):
                            self.onSelect(frame.contains(location)
                                ? proxy.value(atX: location.x - frame.minX, as: Date.self) : nil)
                        case .ended: self.onSelect(nil)
                        }
                    }
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        let x = min(frame.width, max(0, value.location.x - frame.minX))
                        self.onSelect(proxy.value(atX: x, as: Date.self))
                    }.onEnded { _ in self.onSelect(nil) })
                    .preference(key: NativeCombinedPlotFrameKey.self, value: frame)
            }
        }
        .overlay {
            if self.configuration.hasPreparedData, self.configuration.series.isEmpty {
                Text(L("No observations")).font(.callout).foregroundStyle(.tertiary)
                    .transition(.opacity)
            }
        }
        // Both AreaMark and LineMark retain their sample identities and receive this transaction inside the host.
        .animation(
            self.configuration.reduceMotion ? nil : NativeCombinedMetricTransition.animation,
            value: self.configuration)
    }
}

private struct NativeCombinedPlotFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}
