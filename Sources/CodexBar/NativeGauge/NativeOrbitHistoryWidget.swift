import Charts
import CodexBarCore
import SwiftUI

struct NativeOrbitHistoryWidget: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale
    let histories: [PlanUtilizationSeriesHistory]
    let now: Date
    var days = 1
    var accent = Color.primary
    var quotaLabels: [String: String] = [:]
    var quotaWindows: [String: RateWindow] = [:]
    var calendar = Calendar.current
    var provider: UsageProvider?
    var preserveSourceConflicts = false
    var preparedLanes: [Lane]?
    var preparedObservationDates: [Date]?
    /// Quota histories of the provider's other accounts: an early reset seen on several accounts at once, with
    /// nothing redeemed, was the provider's.
    var peerHistories: [[PlanUtilizationSeriesHistory]] = []
    var selectedDate: Date?
    var onSelect: (Date?) -> Void = { _ in }
    @State private var plotFrame: CGRect = .zero

    var start: Date {
        CostReportingPeriod.rolling(days: self.days).bounds(now: self.now, calendar: self.calendar).lowerBound
    }

    private var sourceHistories: [PlanUtilizationSeriesHistory] {
        self.provider.map {
            UsageStore.nativeOrbitCanonicalQuotaHistories(provider: $0, histories: self.histories)
        } ?? self.histories
    }

    private func nativeID(for history: PlanUtilizationSeriesHistory) -> String? {
        // Provider-specific by design: Kimi orders weekly before session and keeps monthly in a separate quota;
        // its legacy archive names therefore need different native quota identities.
        switch history.name {
        case .session where history.windowMinutes == 300:
            self.provider == .kimi ? "nativeQuota:secondary" : "nativeQuota:primary"
        case .weekly where history.windowMinutes == 10080:
            self.provider == .kimi ? "nativeQuota:primary" : "nativeQuota:secondary"
        case .monthly where self.provider == .kimi: "nativeQuota:kimi-monthly"
        case .opus where self.quotaLabels["nativeQuota:tertiary"]?.lowercased().contains("opus") == true:
            "nativeQuota:tertiary"
        default: nil
        }
    }

    var series: [PlanUtilizationSeriesHistory] {
        let canonical = self.sourceHistories.filter { !$0.name.isNativeMetricObservation }
        let raw = canonical.filter(\.name.isNativeQuotaObservation)
        var native = self.preserveSourceConflicts ? Self.coalescedSourceHistories(raw)
            : UsageStore.nativeOrbitCoalescedQuotaHistories(raw)
        var unmatched: [PlanUtilizationSeriesHistory] = []
        for legacy in canonical where !legacy.name.isNativeQuotaObservation {
            let target = self.nativeID(for: legacy)
            let candidates = native.indices.filter {
                native[$0].name.rawValue == target
            }
            guard candidates.count == 1, let index = candidates.first,
                  !native[index].entries.isEmpty
            else {
                unmatched.append(legacy)
                continue
            }
            // Both stores contain measured observations. Native recording can have gaps after its first sample;
            // keep the legacy readings in those gaps, with raw observations authoritative at identical timestamps.
            native[index] = PlanUtilizationSeriesHistory(
                name: native[index].name,
                windowMinutes: native[index].windowMinutes,
                entries: self.preserveSourceConflicts ? Array(Set(legacy.entries + native[index].entries))
                    : UsageStore.nativeOrbitMergedRawEntries(legacy.entries, native[index].entries))
        }
        return (native + unmatched).sorted {
            if $0.windowMinutes != $1.windowMinutes { return $0.windowMinutes > $1.windowMinutes }
            return $0.name.rawValue < $1.name.rawValue
        }
    }

    var metricObservationDates: [Date] {
        if let preparedObservationDates { return preparedObservationDates }
        return Array(Set(self.histories.filter(\.name.isNativeMetricObservation).flatMap(\.entries)
                .map(\.capturedAt).filter { $0 >= self.start && $0 <= self.now })).sorted()
    }

    private static func coalescedSourceHistories(
        _ histories: [PlanUtilizationSeriesHistory]) -> [PlanUtilizationSeriesHistory]
    {
        Dictionary(grouping: histories, by: \.name).map { name, fragments in
            let latest = fragments.filter { $0.windowMinutes > 0 }
                .max { ($0.latestCapturedAt ?? .distantPast) < ($1.latestCapturedAt ?? .distantPast) }
                ?? fragments.last
            // Independent archives can disagree at the same timestamp. Only exact source copies are duplicates.
            return .init(
                name: name,
                windowMinutes: latest?.windowMinutes ?? 0,
                entries: Array(Set(fragments.flatMap(\.entries))))
        }
    }

    struct Lane: Identifiable {
        let history: PlanUtilizationSeriesHistory
        let samples: [Sample]
        /// Typed resets in the visible range that started this lane over (redemptions without a recorded quota drop
        /// ride on the first lane).
        let resetEvents: [NativeOrbitResetEvent]
        let start: Date
        let now: Date
        let styleIndex: Int

        var renderSamples: [Sample] {
            // Draw only measured instants. Missing boundaries and stale tails remain empty.
            let visible = self.samples.filter { $0.id.historicalPeriod == nil && $0.date >= self.start }
            guard visible.count > 2 else { return visible }
            // Thin flat runs only inside one observed segment, retaining both ends of every gap.
            return visible.enumerated().compactMap { index, sample in
                guard index > 0, index < visible.count - 1 else { return sample }
                let previous = visible[index - 1]
                let next = visible[index + 1]
                return previous.segment == sample.segment && next.segment == sample.segment
                    && previous.available == sample.available && next.available == sample.available ? nil : sample
            }
        }

        var isolatedSamples: [Sample] {
            Dictionary(grouping: self.samples.filter {
                $0.id.historicalPeriod == nil && $0.date >= self.start
            }, by: \.segment).values.compactMap { $0.count == 1 && $0.first?.isResetEdge == false ? $0.first : nil }
        }

        var periodSamples: [Sample] {
            self.samples.filter { $0.id.historicalPeriod != nil && $0.date >= self.start }
        }

        var latestMeasuredSample: Sample? {
            self.samples.last { $0.id.historicalPeriod == nil && !$0.isResetEdge }
        }

        var id: String {
            self.history.name.isNativeQuotaObservation ? self.history.name.rawValue
                : "\(self.history.name.rawValue):\(self.history.windowMinutes)"
        }

        func segmentID(_ segment: Int) -> String { "\(self.id):\(segment)" }
    }

    struct ObservationCoverage {
        let observationCount: Int
        let observedDayCount: Int
        let firstObservedAt: Date?
        let lastObservedAt: Date?
        let priorObservedAt: Date?
    }

    func coverage(_ lane: Lane) -> ObservationCoverage {
        // Count source observations, never thinned drawing points or the reset edges drawn between them.
        let observations = lane.samples.filter { !$0.isResetEdge }.map(\.id)
            .filter { $0.capturedAt >= self.start && $0.capturedAt <= self.now }
        return .init(
            observationCount: observations.count,
            observedDayCount: Set(observations.map { self.calendar.startOfDay(for: $0.capturedAt) }).count,
            firstObservedAt: observations.first?.capturedAt,
            lastObservedAt: observations.last?.capturedAt,
            priorObservedAt: lane.samples.last(where: { $0.id.capturedAt < self.start })?.id.capturedAt)
    }

    var legendLabels: [String] {
        self.lanes.map { self.label($0.history) }
    }

    private func coverageSummary(_ coverage: ObservationCoverage) -> String {
        L("%d observations · %d/%d days", coverage.observationCount, coverage.observedDayCount, self.days)
    }

    private func coverageHelp(_ coverage: ObservationCoverage) -> String {
        var lines = [self.coverageSummary(coverage)]
        if let first = coverage.firstObservedAt, let last = coverage.lastObservedAt {
            lines += [
                L("First observed %@", first.formatted(date: .complete, time: .standard)),
                L("Last observed %@", last.formatted(date: .complete, time: .standard)),
            ]
        } else {
            lines.append(L("No observations in this period"))
            if let prior = coverage.priorObservedAt {
                lines.append(L("Last observed %@", prior.formatted(date: .complete, time: .standard)))
            }
        }
        lines.append(L("Lines connect nearby observations. Gaps have no recorded data."))
        return lines.joined(separator: "\n")
    }

    var lanes: [Lane] {
        if let preparedLanes { return preparedLanes }
        let ordered = self.series.sorted {
            let first = Self.linePriority($0.name.rawValue)
            let second = Self.linePriority($1.name.rawValue)
            if first != second { return first < second }
            return $0.name.rawValue < $1.name.rawValue
        }
        // Every recorded reset, also those before the range: a reset between the reading preceding the range and
        // the first one inside it still joins them.
        let recorded = self.resetEvents(ordered)
        let observed = ordered.map { (history: $0, samples: self.points($0, resetEvents: recorded)) }
            .filter { !$0.samples.isEmpty }
        let events = recorded.filter { $0.date >= self.start && $0.date <= self.now }
        return observed.enumerated().map { index, record in Lane(
            history: record.history,
            samples: record.samples,
            resetEvents: events.filter {
                $0.laneIDs.contains(record.history.name.rawValue) || (index == 0 && $0.laneIDs.isEmpty)
            },
            start: self.start,
            now: self.now,
            styleIndex: index) }
    }

    private func resetEvents(_ quotaHistories: [PlanUtilizationSeriesHistory]) -> [NativeOrbitResetEvent] {
        NativeOrbitResetEvent.events(
            quotaHistories: quotaHistories,
            metricHistories: self.histories.filter(\.name.isNativeMetricObservation),
            provider: self.provider,
            peerHistories: self.peerHistories,
            now: self.now)
    }

    /// Each reset once, however many lanes it started over.
    static func resetEvents(_ lanes: [Lane]) -> [NativeOrbitResetEvent] {
        var seen = Set<String>()
        return lanes.flatMap(\.resetEvents).filter { seen.insert($0.id).inserted }.sorted { $0.date < $1.date }
    }

    private static func linePriority(_ name: String) -> Int {
        switch name {
        case "nativeQuota:primary", "weekly": 0
        case "nativeQuota:secondary", "session": 1
        case "nativeQuota:tertiary", "opus": 2
        default: 3
        }
    }

    var body: some View {
        let lanes = self.lanes
        Group {
            if !lanes.isEmpty || !self.metricObservationDates.isEmpty || !self.visibleEvents.isEmpty {
                VStack(spacing: 0) {
                    Text(self.selectedDate.map { self.hoverLine($0, lanes: lanes) } ?? "")
                        .font(.system(size: 10, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .frame(height: 12)
                        .accessibilityHidden(self.selectedDate == nil)
                        .allowsHitTesting(false)
                    self.plot(lanes)
                }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "chart.xyaxis.line").font(.system(size: 22, weight: .medium))
                    Text(L("No observations")).font(.callout)
                }
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, 12)
                .help(L("History begins with recorded usage."))
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .frame(width: 224, height: 224)
        .onChange(of: self.days) { self.select(nil) }
    }

    private func chart(_ lanes: [Lane]) -> some View {
        Chart {
            ForEach(lanes) { lane in
                ForEach(lane.periodSamples, id: \.renderIdentity) { point in
                    PointMark(x: .value("Time", point.date), y: .value("Available", point.available))
                        .symbol(.diamond)
                        .symbolSize(24)
                        .foregroundStyle(self.color(lane.history))
                }
                ForEach(lane.renderSamples, id: \.renderIdentity) { point in
                    AreaMark(
                        x: .value("Time", point.date),
                        yStart: .value("Empty", 0),
                        yEnd: .value("Available", point.available),
                        series: .value("Window", lane.segmentID(point.segment)))
                        .interpolationMethod(.linear)
                        .foregroundStyle(LinearGradient(
                            colors: [
                                self.color(lane.history).opacity(0.10),
                                self.color(lane.history).opacity(0.005),
                            ],
                            startPoint: .top,
                            endPoint: .bottom))
                    LineMark(
                        x: .value("Time", point.date),
                        y: .value("Available", point.available),
                        series: .value("Window", lane.segmentID(point.segment)))
                        .interpolationMethod(.linear)
                        .lineStyle(self.stroke(lane))
                        .foregroundStyle(self.color(lane.history))
                    if point.date == point.id.capturedAt, point.id == lane.latestMeasuredSample?.id {
                        PointMark(x: .value("Time", point.date), y: .value("Available", point.available))
                            .symbolSize(14)
                            .foregroundStyle(self.color(lane.history))
                    }
                }
                ForEach(lane.isolatedSamples, id: \.renderIdentity) { point in
                    PointMark(x: .value("Time", point.date), y: .value("Available", point.available))
                        .symbolSize(14)
                        .foregroundStyle(self.color(lane.history))
                }
            }
            ForEach(Self.resetEvents(lanes)) { event in
                let color = self.resetColor(event, lanes: lanes)
                if let symbol = Self.resetSymbol(event.kind) {
                    // The glyph sits in a band above 100 %, clear of the curves, naming who reset the window.
                    RuleMark(
                        x: .value("Reset", event.date),
                        yStart: .value("Empty", 0),
                        yEnd: .value("Available", 100))
                        .lineStyle(Self.resetStroke(event.kind))
                        .foregroundStyle(color.opacity(Self.resetOpacity(event.kind)))
                        .annotation(position: .top, alignment: .center, spacing: 1) {
                            Image(systemName: symbol)
                                .font(.system(size: 9, weight: .semibold))
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(color)
                        }
                } else {
                    RuleMark(x: .value("Reset", event.date))
                        .lineStyle(Self.resetStroke(event.kind))
                        .foregroundStyle(color.opacity(Self.resetOpacity(event.kind)))
                }
            }
        }
        .chartXScale(domain: self.start...self.chartEnd)
        .chartYScale(
            domain: 0...100,
            range: .plotDimension(startPadding: 3, endPadding: Self.topPadding(lanes)))
        .chartLegend(.hidden)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Color.clear.contentShape(Rectangle()).onContinuousHover { phase in
                    switch phase {
                    case let .active(location):
                        guard let plot = proxy.plotFrame, geometry[plot].contains(location) else {
                            self.select(nil)
                            return
                        }
                        let frame = geometry[plot]
                        let date: Date? = proxy.value(atX: location.x - frame.minX)
                        self.select(date.map { self.inspectionDate(at: $0, plotWidth: frame.width) })
                    case .ended: self.select(nil)
                    }
                }
                .preference(key: NativeOrbitPlotFrameKey.self, value: proxy.plotFrame.map { geometry[$0] } ?? .zero)
            }
        }
        .animation(self.reduceMotion ? nil : .smooth(duration: 0.3), value: self.days)
        .animation(self.reduceMotion ? nil : .smooth(duration: 0.3), value: lanes.map(\.samples.count))
        .chartXAxis {
            AxisMarks(values: self.axisDates) { value in
                AxisValueLabel(anchor: self.axisAnchor(value.as(Date.self))) {
                    if let date = value.as(Date.self) {
                        Text(self.axisLabel(date))
                            .font(.system(size: 10))
                            .monospacedDigit()
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 50, 100]) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Color(nsColor: .separatorColor).opacity(0.4))
            }
        }
        .accessibilityLabel(L("Recorded available usage"))
    }

    /// Hovering changes only the selection. The marks live in an equatable plot that rebuilds when its data
    /// changes; the selection rule and highlighted readings are drawn on top in plot coordinates.
    private func plot(_ lanes: [Lane]) -> some View {
        var marks = self
        marks.selectedDate = nil
        marks.preparedObservationDates = self.metricObservationDates
        return NativeOrbitStaticPlot(widget: marks, lanes: lanes, key: self.plotKey(lanes))
            .equatable()
            .overlay(alignment: .topLeading) { self.selectionOverlay(lanes) }
            .onPreferenceChange(NativeOrbitPlotFrameKey.self) { self.plotFrame = $0 }
            .help(lanes
                .map { self.seriesHelp($0, selectedDate: self.selectedDate ?? $0.samples.last?.date ?? self.now) }
                .joined(separator: "\n") + "\n" + lanes.map { self.coverageHelp(self.coverage($0)) }
                .joined(separator: "\n") + "\n" + self.events.map(\.help).joined(separator: "\n")
                + self.resetHelp(lanes))
    }

    /// One line per reset in the period, so the marks' types are spelled out.
    func resetHelp(_ lanes: [Lane]) -> String {
        Self.resetEvents(lanes).map { event in
            "\n" + event.help(provider: self.provider, laneLabels: event.laneIDs.compactMap { id in
                lanes.first { $0.history.name.rawValue == id }.map { self.label($0.history) }
            })
        }.joined()
    }

    /// Natural resets keep the quiet dashed rule; early resets are solid, with a glyph naming who reset them.
    static func resetStroke(_ kind: NativeOrbitResetEvent.Kind) -> StrokeStyle {
        switch kind {
        case .natural: StrokeStyle(lineWidth: 0.5, dash: [2, 3])
        case .manual: StrokeStyle(lineWidth: 1, lineCap: .round)
        case .provider: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [4, 2])
        case .early: StrokeStyle(lineWidth: 0.75, lineCap: .round, dash: [1, 2])
        }
    }

    static func resetOpacity(_ kind: NativeOrbitResetEvent.Kind) -> Double {
        switch kind {
        case .natural: 0.2
        case .manual: 0.6
        case .provider: 0.45
        case .early: 0.35
        }
    }

    /// The plot's padding above 100 %: room for reset glyphs when the period has any, else the usual 3 pt.
    static func topPadding(_ lanes: [Lane]) -> CGFloat {
        self.resetEvents(lanes).contains { self.resetSymbol($0.kind) != nil } ? 13 : 3
    }

    static func resetSymbol(_ kind: NativeOrbitResetEvent.Kind) -> String? {
        switch kind {
        case .natural: nil
        // The banked-reset glyph of the dial's bottom-leading corner.
        case .manual: "arrow.uturn.backward.circle.fill"
        case .provider: "building.2.crop.circle.fill"
        case .early: "questionmark.circle.fill"
        }
    }

    private func resetColor(_ event: NativeOrbitResetEvent, lanes: [Lane]) -> Color {
        guard event.laneIDs.count == 1, let lane = lanes.first(where: { $0.history.name.rawValue == event.laneIDs[0] })
        else { return self.accent }
        return self.color(lane.history)
    }

    /// The pointer's time, plus the reset under it when the pointer is within a few points of one.
    private func hoverLine(_ date: Date, lanes: [Lane]) -> String {
        let tolerance = self.now.timeIntervalSince(self.start) / max(1, Double(self.plotFrame.width)) * 4
        let event = Self.resetEvents(lanes).filter { abs($0.date.timeIntervalSince(date)) <= tolerance }
            .min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
        return self.hoverTime(date) + (event.map { " · " + $0.shortTitle(provider: self.provider) } ?? "")
    }

    fileprivate func renderedChart(_ lanes: [Lane]) -> some View {
        self.chart(lanes)
    }

    func plotKey(_ lanes: [Lane]) -> NativeOrbitPlotKey {
        NativeOrbitPlotKey(
            days: self.days,
            start: self.start,
            end: self.chartEnd,
            accent: self.accent,
            lanes: lanes.map {
                "\($0.id)|\($0.styleIndex)|\($0.samples.count)|\($0.samples.last?.date.timeIntervalSince1970 ?? 0)"
                    + "|\($0.samples.last?.available ?? -1)"
            },
            resetEvents: Self.resetEvents(lanes).map(\.id))
    }

    /// Mirrors the chart scales: a linear time axis over `start...chartEnd` and 0...100 with 3 pt padding below and
    /// `topPadding` above.
    @ViewBuilder
    private func selectionOverlay(_ lanes: [Lane]) -> some View {
        if let date = self.selectedDate, self.plotFrame.width > 0, self.plotFrame.height > 16 {
            let frame = self.plotFrame
            let topPadding = Self.topPadding(lanes)
            let span = max(1, self.chartEnd.timeIntervalSince(self.start))
            let x = { (date: Date) in frame.minX + CGFloat(date.timeIntervalSince(self.start) / span) * frame.width }
            let y = { (available: Double) in
                frame.maxY - 3 - CGFloat(min(100, max(0, available)) / 100) * (frame.height - 3 - topPadding)
            }
            ZStack(alignment: .topLeading) {
                Path { path in
                    path.move(to: CGPoint(x: x(date), y: frame.minY))
                    path.addLine(to: CGPoint(x: x(date), y: frame.maxY))
                }
                .stroke(self.accent.opacity(0.75), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                ForEach(lanes) { lane in
                    if let point = self.nearest(lane, to: date), point.date >= self.start {
                        Circle()
                            .fill(self.color(lane.history))
                            .frame(width: 6, height: 6)
                            .position(x: x(point.date), y: y(point.available))
                    }
                }
            }
            .allowsHitTesting(false)
        }
    }

    func stroke(_ lane: Lane) -> StrokeStyle {
        let dash: [CGFloat] = switch lane.styleIndex {
        case 0: []
        case 1: [5, 2]
        case 2: [1, 2]
        default: [CGFloat(4 + (lane.styleIndex - 3) * 2), 2, 1, 2]
        }
        return StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round, dash: dash)
    }

    func legendSample(_ lane: Lane, selectedDate: Date?) -> Sample? {
        if let selectedDate { return self.nearest(lane, to: selectedDate) }
        return lane.latestMeasuredSample
    }

    var events: [NativeOrbitScheduledEvent] {
        self.quotaWindows.compactMap { key, window in
            guard let date = window.resetsAt, date > self.now else { return nil }
            return NativeOrbitScheduledEvent(
                id: key,
                date: date,
                label: self.quotaLabels[key] ?? "Usage",
                recoveryPercent: window.nextRegenPercent.flatMap { $0.isFinite && $0 > 0 ? $0 : nil })
        }.sorted { $0.date < $1.date }
    }

    var visibleEvents: [NativeOrbitScheduledEvent] {
        self.events.filter { $0.date <= self.chartEnd }
    }

    var chartEnd: Date {
        self.now
    }

    struct Sample: Identifiable {
        struct RenderIdentity: Hashable {
            let observation: PlanUtilizationHistoryEntry
            let date: Date
        }

        let id: PlanUtilizationHistoryEntry
        let date: Date
        let available: Double
        let segment: Int
        let period: TimeInterval?
        /// Drawn at a reset's instant, not observed: the last reading held until the reset (`id` is that reading),
        /// or the full window right after it (`id` is the first reading after it).
        var isResetEdge = false

        var renderIdentity: RenderIdentity {
            .init(observation: self.id, date: self.date)
        }
    }

    /// The lane's drawn points. A reset is part of the line: the last reading holds until the reset's instant, the
    /// line rises there to the full window and continues to the next reading. That needs readings on both sides
    /// within the lane's recording-gap limit of the instant; otherwise the line stays broken, as at any gap.
    func points(_ history: PlanUtilizationSeriesHistory, resetEvents: [NativeOrbitResetEvent] = []) -> [Sample] {
        let start = self.start
        let valid = history.entries
            .filter { $0.usedPercent.isFinite && $0.usedPercent >= 0 && $0.capturedAt <= self.now }
        let preceding = valid.last { $0.capturedAt < start && $0.historicalPeriod == nil }
        let visible = valid.filter { $0.capturedAt >= start }
        let entries = (preceding.map { [$0] } ?? []) + visible
        let gapLimit = Self.recordingGapLimit(valid)
        var cadences: [PlanUtilizationHistoryEntry: Set<Int>] = [:]
        for source in self.sourceHistories where source.name == history.name
            || self.nativeID(for: source) == history.name.rawValue
        {
            for entry in source.entries {
                cadences[entry, default: []].insert(source.windowMinutes)
            }
        }
        let resetDates = resetEvents.filter { $0.laneIDs.contains(history.name.rawValue) }.map(\.date)
        var samples: [Sample] = []
        var segment = 0
        var previous: PlanUtilizationHistoryEntry?
        var previousPeriod: TimeInterval?
        for entry in entries {
            let period = Self.sourcePeriod(cadences[entry] ?? [], fallback: history.windowMinutes)
            if let previous {
                let crossedReset = previous.resetsAt.map {
                    $0 > previous.capturedAt && $0 <= entry.capturedAt
                } ?? false
                let unknownReset = previous.resetsAt == nil && entry.usedPercent < previous.usedPercent
                let comparable = previousPeriod == period
                    && previous.historicalPeriod == nil && entry.historicalPeriod == nil
                let instant = comparable
                    ? Self.resetInstant(from: previous, to: entry, crossed: crossedReset, events: resetDates) : nil
                if let instant, instant.timeIntervalSince(previous.capturedAt) <= gapLimit,
                   entry.capturedAt.timeIntervalSince(instant) <= gapLimit
                {
                    if instant > previous.capturedAt {
                        samples.append(Sample(
                            id: previous,
                            date: instant,
                            available: max(0, 100 - previous.usedPercent),
                            segment: segment,
                            period: previousPeriod,
                            isResetEdge: true))
                    }
                    if instant < entry.capturedAt {
                        samples.append(Sample(
                            id: entry,
                            date: instant,
                            available: 100,
                            segment: segment,
                            period: period,
                            isResetEdge: true))
                    }
                } else if instant != nil || crossedReset || unknownReset || !comparable
                    || entry.capturedAt.timeIntervalSince(previous.capturedAt) > gapLimit
                {
                    segment += 1
                }
            }
            previous = entry
            previousPeriod = period
            samples.append(Sample(
                id: entry,
                date: entry.capturedAt,
                available: max(0, 100 - entry.usedPercent),
                segment: segment,
                period: period))
        }
        return samples
    }

    /// When the window reset between two readings: its typed reset event (the scheduled reset, a redemption, or the
    /// detected early reset), else the schedule the earlier reading crossed. A drop without a known schedule has no
    /// instant to draw and stays a break in the line.
    static func resetInstant(
        from previous: PlanUtilizationHistoryEntry,
        to entry: PlanUtilizationHistoryEntry,
        crossed: Bool,
        events: [Date]) -> Date?
    {
        let scheduled = previous.resetsAt.map { $0 > previous.capturedAt } ?? false
        let dropped = scheduled
            && NativeOrbitResetEvent.isResetDrop(from: previous.usedPercent, to: entry.usedPercent)
        guard crossed || dropped else { return nil }
        let lower = previous.capturedAt
        let upper = entry.capturedAt
        let skew = NativeOrbitResetEvent.sameInstant
        /// Events inside the bracket first; one refresh's skew can put the event just outside it.
        func outside(_ date: Date) -> TimeInterval {
            max(0, lower.timeIntervalSince(date), date.timeIntervalSince(upper))
        }
        let event = events.filter { $0 > lower.addingTimeInterval(-skew) && $0 <= upper.addingTimeInterval(skew) }
            .min { outside($0) < outside($1) }
        let instant = event ?? (crossed ? previous.resetsAt : nil) ?? upper
        return min(upper, max(lower, instant))
    }

    private static func sourcePeriod(_ cadences: Set<Int>, fallback: Int) -> TimeInterval? {
        let minutes = cadences.isEmpty ? fallback : cadences.count == 1 ? cadences.first ?? 0 : 0
        return minutes > 0 ? Double(minutes) * 60 : nil
    }

    private static func recordingGapLimit(_ entries: [PlanUtilizationHistoryEntry]) -> TimeInterval {
        let measured = entries.filter { $0.historicalPeriod == nil }
        let intervals = zip(measured, measured.dropFirst()).map {
            $1.capturedAt.timeIntervalSince($0.capturedAt)
        }.filter { $0 > 0 && $0 <= 5400 }.sorted()
        // Accommodate hourly legacy polling, but never bridge a long outage. Dense native polling
        // gets a narrower threshold so missing hours do not become a continuous quota curve.
        let cadence = intervals.isEmpty ? 1800 : intervals[(intervals.count - 1) / 2]
        return min(5400, max(900, cadence * 3))
    }

    func nearest(_ lane: Lane, to date: Date) -> Sample? {
        guard date >= self.start, date <= self.now else { return nil }
        var lower = 0
        var upper = lane.samples.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if lane.samples[middle].date < date { lower = middle + 1 } else { upper = middle }
        }
        // Exact observations win ties. Between readings, match the same linear curve that Charts draws;
        // never interpolate across a reset, an aggregate period marker, or an unrecorded gap.
        if lane.samples.indices.contains(lower), lane.samples[lower].date == date {
            // At a reset's instant without a reading there, the window has already started over.
            var index = lower
            var edge: Sample?
            while index < lane.samples.count, lane.samples[index].date == date {
                let sample = lane.samples[index]
                if sample.id.historicalPeriod == nil {
                    if !sample.isResetEdge { return sample }
                    edge = sample
                }
                index += 1
            }
            return edge ?? lane.samples[lower]
        }
        guard lower > 0, lower < lane.samples.count else { return nil }
        let previous = lane.samples[lower - 1]
        let next = lane.samples[lower]
        guard previous.segment == next.segment,
              previous.date >= self.start,
              previous.id.historicalPeriod == nil, next.id.historicalPeriod == nil else { return nil }
        let progress = date.timeIntervalSince(previous.date) / next.date.timeIntervalSince(previous.date)
        return Sample(
            id: previous.id,
            date: date,
            available: previous.available + (next.available - previous.available) * progress,
            segment: previous.segment,
            period: previous.period)
    }

    func seriesHelp(_ lane: Lane, selectedDate: Date) -> String {
        guard let sample = self.nearest(lane, to: selectedDate) else {
            return "\(self.label(lane.history)) · No observation at this time"
        }
        let amount = sample.available.formatted(.number.precision(.significantDigits(1...15)))
        if let period = sample.id.historicalPeriod {
            let start = period.startsAt.formatted(date: .abbreviated, time: .standard)
            let end = sample.date.formatted(date: .abbreviated, time: .standard)
            var text = "\(self.label(lane.history)) · \(amount)% available · Server period total · \(start)–\(end)"
            if period.approximate { text += " · Approximate" }
            if !period.accountingComplete { text += " · Accounting incomplete" }
            if let tolerance = period.boundaryToleranceSeconds { text += " · Boundary tolerance ±\(tolerance)s" }
            return text
        }
        let reset = sample.id.resetsAt.map { " · Resets \($0.formatted(date: .abbreviated, time: .standard))" } ?? ""
        let detail = sample.date == sample.id.capturedAt
            ? " · Observed \(sample.date.formatted(date: .abbreviated, time: .standard))"
            : " · Interpolated at \(sample.date.formatted(date: .abbreviated, time: .standard))"
            + " between nearby observations"
        return "\(self.label(lane.history)) · \(amount)% available" + detail + reset
    }

    func inspectionDate(at date: Date, plotWidth: CGFloat) -> Date {
        // Snapshot complications are valid only at their measured instant. Give every recorded metric point
        // the same small hit target as isolated quota points, including when a quota curve crosses that time.
        // Snapping selects the actual source timestamp; it never turns interpolated quota into an observation.
        let tolerance = self.now.timeIntervalSince(self.start) / max(1, Double(plotWidth)) * 3
        func nearest(_ dates: [Date]) -> Date? {
            dates.filter { abs($0.timeIntervalSince(date)) <= tolerance }
                .min { abs($0.timeIntervalSince(date)) < abs($1.timeIntervalSince(date)) }
        }
        // Complication observations carry the readings the dials restore, so inside one hit target they win over
        // quota-only points (a quota sample stamped a second after its refresh's metrics, for example).
        if let metric = nearest(self.metricObservationDates) { return metric }
        return nearest(self.lanes.flatMap { lane in
            (lane.isolatedSamples + lane.periodSamples).map(\.date)
        }) ?? date
    }

    private func select(_ date: Date?) {
        self.onSelect(date.map { min(self.now, max(self.start, $0)) })
    }

    private var timeLocale: Locale {
        codexBarLocalizationSignature().isEmpty ? self.locale : codexBarLocalizedResourceLocale()
    }

    private func hoverTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = self.timeLocale
        formatter.timeZone = self.calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(self.days == 1 ? "jmmss" : "MMMdjmm")
        return formatter.string(from: date)
    }

    var axisDates: [Date] {
        let interval = self.now.timeIntervalSince(self.start)
        guard interval > 1 else { return [self.now] }
        let middle = self.start.addingTimeInterval(interval / 2)
        let aligned = self.days == 1 ? self.calendar.dateInterval(of: .hour, for: middle)?.start
            : self.calendar.startOfDay(for: middle)
        guard let aligned, aligned > self.start, aligned < self.now else { return [self.start, self.now] }
        return [self.start, aligned, self.now]
    }

    private func axisAnchor(_ date: Date?) -> UnitPoint {
        date == self.start ? .topLeading : date == self.now ? .topTrailing : .top
    }

    func axisLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = self.timeLocale
        formatter.timeZone = self.calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(self.days == 1 ? "jmm" : "MMMd")
        return formatter.string(from: date)
    }

    private func color(_ history: PlanUtilizationSeriesHistory) -> Color {
        NativeOrbitPalette.color(
            accent: self.accent, id: history.name.rawValue, period: Double(history.windowMinutes) * 60)
    }

    private func color(id: String) -> Color {
        NativeOrbitPalette.color(
            accent: self.accent, id: id, period: Double(self.quotaWindows[id]?.windowMinutes ?? 0) * 60)
    }

    private func label(_ history: PlanUtilizationSeriesHistory) -> String {
        if !history.name.isNativeQuotaObservation {
            return history.name == .session && history.windowMinutes == 300 ? "Session (5h)"
                : history.name.rawValue.capitalized
        }
        if let label = self.quotaLabels[history.name.rawValue],
           self.preserveSourceConflicts
           || self.quotaWindows[history.name.rawValue]?.windowMinutes == history.windowMinutes
           || (history.name.rawValue != "nativeQuota:primary" && history.name.rawValue != "nativeQuota:secondary")
        { return label }
        let id = String(history.name.rawValue.dropFirst("nativeQuota:".count))
        if id.hasPrefix("claude-weekly-scoped-") {
            return String(id.dropFirst("claude-weekly-scoped-".count))
                .replacingOccurrences(of: "-", with: " ").capitalized + " only"
        }
        if id == "codex-spark" { return "Spark (5h)" }
        if id == "codex-spark-weekly" { return "Spark weekly" }
        if id == "kimi-monthly" { return "Total usage" }
        if !["primary", "secondary", "tertiary", "monthly"].contains(id) {
            return id.replacingOccurrences(of: "-", with: " ").capitalized
        }
        return switch history.windowMinutes {
        case 300: "Session"
        case 1440: "Daily"
        case 10080: "Weekly"
        case 40320...44640: "Monthly"
        default: self
            .quotaLabels[history.name.rawValue] ?? String(history.name.rawValue.dropFirst("nativeQuota:".count))
            .replacingOccurrences(of: "-", with: " ").capitalized
        }
    }
}

struct NativeOrbitPlotKey: Equatable, Sendable {
    let days: Int
    let start: Date
    let end: Date
    let accent: Color
    let lanes: [String]
    /// The chart's reset marks; a reclassified reset redraws even when no sample changed.
    let resetEvents: [String]
}

private struct NativeOrbitStaticPlot: View, Equatable {
    let widget: NativeOrbitHistoryWidget
    let lanes: [NativeOrbitHistoryWidget.Lane]
    nonisolated let key: NativeOrbitPlotKey

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.key == rhs.key
    }

    var body: some View {
        self.widget.renderedChart(self.lanes)
    }
}

private struct NativeOrbitPlotFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}
