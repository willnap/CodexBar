import AppKit
import Charts
import CodexBarCore
import SwiftUI

struct NativeOrbitHistoryWidget: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme
    let histories: [PlanUtilizationSeriesHistory]
    let now: Date
    var days = 1
    var accent = Color.primary
    var quotaLabels: [String: String] = [:]
    var quotaWindows: [String: RateWindow] = [:]
    var calendar = Calendar.current
    var provider: UsageProvider?
    var preserveSourceConflicts = false
    /// Dated money observations in the same existing plot; nil keeps ordinary quota charts unchanged.
    var spending: NativeOrbitSpendingHistory?
    var preparedLanes: [Lane]?
    var preparedObservationDates: [Date]?
    /// Quota histories of the provider's other accounts: an early reset seen on several accounts at once, with
    /// nothing redeemed, was the provider's.
    var peerHistories: [[PlanUtilizationSeriesHistory]] = []
    var selectedDate: Date?
    var onSelect: (Date?) -> Void = { _ in }
    /// The account's predictions, drawn to the right of now while the popup projects.
    var projection: NativeOrbitAccountProjection?
    /// Some account in the popup is in use: now moves to the center of every chart and the future fills the right.
    var isProjecting = false
    /// Whether an empty chart says so; while the account's first reading is loading it stays blank instead.
    var showsEmptyState = true
    /// Every range draws this same prepared span. Stable vertices let Charts animate the domain between ranges
    /// without morphing unrelated samples into one another; marks outside the visible domain remain clipped.
    var dataDays: Int?
    var startup: NativeOrbitStartupPhase = .live
    @State private var plotFrame: CGRect = .zero

    /// The range start; while projecting, a full range span before now, mirrored by the projected end.
    var start: Date {
        if self.isProjecting {
            return NativeOrbitChartAxis.projectingBounds(now: self.now, days: self.days, calendar: self.calendar).start
        }
        return CostReportingPeriod.rolling(days: self.days).bounds(now: self.now, calendar: self.calendar).lowerBound
    }

    /// Where the drawn data begins: the range start, or `dataDays` before now when that reaches further back.
    var dataStart: Date {
        guard let dataDays else { return self.start }
        return min(self.start, self.now.addingTimeInterval(-Double(dataDays) * 86400))
    }

    /// Where the drawn projection ends: the chart's end, or `dataDays` after now while projecting.
    var dataEnd: Date {
        guard let dataDays, self.isProjecting else { return self.chartEnd }
        return max(self.chartEnd, self.now.addingTimeInterval(Double(dataDays) * 86400))
    }

    private var sourceHistories: [PlanUtilizationSeriesHistory] {
        let histories = self.provider.map {
            UsageStore.nativeOrbitCanonicalQuotaHistories(provider: $0, histories: self.histories)
        } ?? self.histories
        if !histories.contains(where: { !$0.name.isNativeMetricObservation && !$0.entries.isEmpty }),
           let budget = self.spending?.budgetHistory
        {
            return histories + [budget]
        }
        return histories
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

        /// The chart series a sample belongs to, named by its run's first reading so it is the same in every range.
        func seriesID(_ sample: Sample) -> String { "\(self.id):\(sample.seriesOrigin.timeIntervalSince1970)" }
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
        let events = recorded.filter { $0.date >= self.dataStart && $0.date <= self.now }
        return observed.enumerated().map { index, record in Lane(
            history: record.history,
            samples: record.samples,
            resetEvents: events.filter {
                $0.laneIDs.contains(record.history.name.rawValue) || (index == 0 && $0.laneIDs.isEmpty)
            },
            start: self.dataStart,
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

    private func chart(_ lanes: [Lane]) -> some View {
        let inspectionIndex = self.inspectionIndex(lanes)
        return Chart {
            self.futureBackdrop
            ForEach(self.gridDates, id: \.self) { date in
                RuleMark(x: .value("Grid", date))
                    .lineStyle(StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(self.gridInk)
            }
            if self.spending?.emphasizesQuota == true { self.spendingMarks }
            ForEach(lanes) { lane in
                let color = self.color(lane.history)
                let stroke = self.stroke(lane)
                let fill = LinearGradient(
                    colors: [color.opacity(self.colorScheme == .dark ? 0.18 : 0.10), color.opacity(0.015)],
                    startPoint: .top,
                    endPoint: .bottom)
                let points = self.quotaPlotPoints(lane)
                PointPlot(lane.periodSamples, x: .value("Time", \.date), y: .value("Available", \.available))
                    .symbol(.diamond)
                    .symbolSize(24)
                    .foregroundStyle(color)
                AreaPlot(
                    points,
                    x: .value("Time", \.date),
                    y: .value("Available", \.available),
                    series: .value("Window", \.seriesID),
                    stacking: .unstacked)
                    .interpolationMethod(.linear)
                    .foregroundStyle(fill)
                    .alignsMarkStylesWithPlotArea()
                LinePlot(
                    points,
                    x: .value("Time", \.date),
                    y: .value("Available", \.available),
                    series: .value("Window", \.seriesID))
                    .interpolationMethod(.linear)
                    .lineStyle(stroke)
                    .foregroundStyle(color)
                if let latest = lane.latestMeasuredSample, latest.date == latest.id.capturedAt,
                   latest.date >= lane.start
                {
                    PointMark(x: .value("Time", latest.date), y: .value("Available", latest.available))
                        .symbolSize(14)
                        .foregroundStyle(color)
                }
                PointPlot(lane.isolatedSamples, x: .value("Time", \.date), y: .value("Available", \.available))
                    .symbolSize(14)
                    .foregroundStyle(color)
            }
            if self.spending?.emphasizesQuota == false { self.spendingMarks }
            ForEach(Self.ruleBatches(Self.resetEvents(lanes))) { batch in
                let event = batch.prototype
                let color = self.resetColor(event, lanes: lanes)
                let rules = batch.events.map {
                    NativeOrbitHistoryRulePoint(date: $0.date, label: self.resetAccessibilityLabel($0, lanes: lanes))
                }
                RulePlot(rules, x: .value("Reset", \.date))
                    .accessibilityLabel(\.label)
                    .lineStyle(Self.resetStroke(event.kind))
                    .foregroundStyle(color.opacity(Self.resetOpacity(event.kind)))
                if let symbol = Self.resetSymbol(event.kind) {
                    // The glyph rides on its reset rule at the foot of the plot; the plot keeps its full height.
                    PointMark(x: .value("Reset", event.date), y: .value("Glyph", Self.glyphLevel))
                        .symbolSize(0)
                        .annotation(position: .overlay) { Self.glyph(symbol, color: color) }
                }
            }
        }
        .chartXScale(domain: self.start...self.chartEnd, range: .plotDimension(startPadding: 0, endPadding: 0))
        .chartYScale(
            domain: 0...100,
            range: .plotDimension(startPadding: 3, endPadding: self.plotTopPadding(lanes)))
        .chartLegend(.hidden)
        // Explicit zero horizontal padding makes marks, the overlay and endpoint labels share one time scale.
        // Clip at that boundary so older data cannot protrude past the first or last instant.
        .chartPlotStyle { $0.clipShape(Rectangle()) }
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
                        self.select(date.map { self.inspectionDate(
                            at: $0,
                            plotWidth: frame.width,
                            using: inspectionIndex) })
                    case .ended: self.select(nil)
                    }
                }
                .preference(key: NativeOrbitPlotFrameKey.self, value: proxy.plotFrame.map { geometry[$0] } ?? .zero)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 50, 100]) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(self.gridInk)
            }
        }
        .accessibilityLabel(Text(verbatim: self.spending == nil
                ? L("Recorded available usage") : "Recorded spend and usage"))
    }

    /// Hovering changes only the selection. The marks live in an equatable plot that rebuilds when its data
    /// changes; the selection rule and highlighted readings are drawn on top in plot coordinates.
    private func plot(_ lanes: [Lane]) -> some View {
        var marks = self
        marks.selectedDate = nil
        marks.preparedObservationDates = self.metricObservationDates
        return NativeOrbitStaticPlot(
            widget: marks,
            lanes: lanes,
            key: self.plotKey(lanes),
            onPlotFrame: { frame in if self.plotFrame != frame { self.plotFrame = frame } })
            .equatable()
            // Now is always marked, projecting or not: it is the reference every hovered moment is read against.
            // Ahead of now the marker and its dots blur with the projection they read.
            .overlay(alignment: .topLeading) {
                self.nowMarker(lanes)
            }
            .overlay(alignment: .topLeading) { self.spendingScale }
            // No tooltip: the pill names the inspected moment and the dial reads it. VoiceOver gets each lane's
            // reading there, and every reset rule carries its own label.
            .accessibilityValue(self.inspectionHelp(lanes))
    }

    private func inspectionHelp(_ lanes: [Lane]) -> String {
        var readings = lanes.map {
            self.seriesHelp($0, selectedDate: self.selectedDate ?? $0.samples.last?.date ?? self.now)
        }
        if let spending = self.spending {
            readings.append(self.selectedDate.map { spending.help(at: $0) }
                ?? spending.bars.last.map { spending.help($0) } ?? "Spend · No observations")
        }
        return readings.joined(separator: "\n")
    }

    /// What a reset rule says to VoiceOver: its type, then the lanes it started over.
    func resetAccessibilityLabel(_ event: NativeOrbitResetEvent, lanes: [Lane]) -> String {
        event.help(provider: self.provider, laneLabels: event.laneIDs.compactMap { id in
            lanes.first { $0.history.name.rawValue == id }.map { self.label($0.history) }
        })
    }

    private func resetColor(_ event: NativeOrbitResetEvent, lanes: [Lane]) -> Color {
        guard event.laneIDs.count == 1, let lane = lanes.first(where: { $0.history.name.rawValue == event.laneIDs[0] })
        else { return self.accent }
        return self.color(lane.history)
    }

    /// Every reset and scheduled event the chart marks, named the way the hover pill reads it: "Weekly reset",
    /// "Reset by Anthropic", "Banked reset expires".
    func markedEvents(_ lanes: [Lane]) -> [NativeOrbitMarkedEvent] {
        func lane(_ ids: [String]) -> String? {
            guard ids.count == 1 else { return nil }
            return lanes.first { $0.history.name.rawValue == ids[0] }.map { self.label($0.history) }
        }
        let recorded = Self.resetEvents(lanes).map { event in
            NativeOrbitMarkedEvent(
                date: event.date,
                symbol: Self.resetSymbol(event.kind),
                title: event.kind == .natural
                    ? lane(event.laneIDs).map { "\($0) reset" } ?? "Window reset"
                    : event.shortTitle(provider: self.provider),
                isScheduled: false)
        }
        let ahead = self.projectedEvents.map { event in
            NativeOrbitMarkedEvent(
                date: event.date,
                symbol: NativeOrbitProjectionStyle.eventSymbol(event.kind),
                title: event.kind == .windowReset
                    ? lane(event.laneIDs).map { "\($0) resets" } ?? "Window resets"
                    : NativeOrbitProjectionStyle.eventShortTitle(event.kind),
                isScheduled: true)
        }
        return (recorded + ahead).sorted { $0.date < $1.date }
    }

    /// Recorded and projected layers zoom the same stable vertices together when their visible domain changes.
    /// Readings and projecting-layout changes retain their existing animations.
    fileprivate func renderedChart(_ lanes: [Lane]) -> some View {
        self.chart(lanes)
            .overlay { self.futureLayer(lanes) }
            .animation(Self.rangeAnimation(reduceMotion: self.reduceMotion), value: self.days)
            .animation(Self.rangeAnimation(reduceMotion: self.reduceMotion), value: lanes.map(\.samples.count))
            .animation(self.reduceMotion ? nil : NativeOrbitProjectionStyle.axisAnimation, value: self.isProjecting)
    }

    static func rangeAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .smooth(duration: 0.3 * NativeOrbitProjectionStyle.previewAnimationScale)
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
            resetEvents: Self.resetEvents(lanes).map(\.id),
            projection: self.drawnProjection?.signature ?? [],
            spending: self.spending?.signature ?? [],
            darkAppearance: self.colorScheme == .dark,
            localeIdentifier: self.timeLocale.identifier,
            reduceMotion: self.reduceMotion,
            histories: lanes.map(\.history),
            observationDates: self.metricObservationDates,
            quotaLabels: self.quotaLabels,
            quotaWindows: self.quotaWindows,
            providerID: self.provider?.rawValue,
            calendar: self.calendar)
    }

    /// Recorded lines are always solid; dashed strokes belong only to the projection, so the two never read alike.
    /// Lanes are told apart by their palette color.
    func stroke(_ lane: Lane) -> StrokeStyle {
        StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round)
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
        self.isProjecting
            ? NativeOrbitChartAxis.projectingBounds(now: self.now, days: self.days, calendar: self.calendar).end
            : self.now
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
        /// The first reading of this sample's unbroken run across the whole history: the line's name in every range.
        var seriesOrigin = Date.distantPast

        var renderIdentity: RenderIdentity {
            .init(observation: self.id, date: self.date)
        }

        /// Where the chart draws the sample. A reset's two edges share an instant; the held edge (the old window's
        /// last level, `id` read before it) is drawn half a minute earlier, invisible at any range, so the pair can
        /// never swap order while Charts interpolates a range change (a swap draws the rise as a drop or a wedge).
        var renderDate: Date {
            guard self.isResetEdge, self.date > self.id.capturedAt else { return self.date }
            let lead = min(NativeOrbitHistoryWidget.edgeSeparation, self.date.timeIntervalSince(self.id.capturedAt) / 2)
            return self.date.addingTimeInterval(-lead)
        }
    }

    /// The draw-time gap between a reset's two edges, so their order is fixed whatever the scale.
    static let edgeSeparation: TimeInterval = 30

    /// The lane's drawn points. A reset is part of the line: the last reading holds until the reset's instant, the
    /// line rises there to the full window and continues to the next reading. That needs readings on both sides
    /// within the lane's recording-gap limit of the instant; otherwise the line stays broken, as at any gap.
    func points(_ history: PlanUtilizationSeriesHistory, resetEvents: [NativeOrbitResetEvent] = []) -> [Sample] {
        let start = self.dataStart
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
        func period(_ entry: PlanUtilizationHistoryEntry) -> TimeInterval? {
            Self.sourcePeriod(cadences[entry] ?? [], fallback: history.windowMinutes)
        }
        // How a reading continues the one before it: across a reset drawn at an instant, plainly, or not at all.
        enum Join { case reset(Date), plain, broken }
        func join(
            _ previous: PlanUtilizationHistoryEntry,
            _ previousPeriod: TimeInterval?,
            _ entry: PlanUtilizationHistoryEntry,
            _ period: TimeInterval?) -> Join
        {
            let crossedReset = previous.resetsAt.map { $0 > previous.capturedAt && $0 <= entry.capturedAt } ?? false
            let unknownReset = previous.resetsAt == nil && entry.usedPercent < previous.usedPercent
            let comparable = previousPeriod == period
                && previous.historicalPeriod == nil && entry.historicalPeriod == nil
            let instant = comparable
                ? Self.resetInstant(from: previous, to: entry, crossed: crossedReset, events: resetDates) : nil
            if let instant, instant.timeIntervalSince(previous.capturedAt) <= gapLimit,
               entry.capturedAt.timeIntervalSince(instant) <= gapLimit
            {
                return .reset(instant)
            }
            if instant != nil || crossedReset || unknownReset || !comparable
                || entry.capturedAt.timeIntervalSince(previous.capturedAt) > gapLimit
            {
                return .broken
            }
            return .plain
        }
        // A line is named by the first reading of its unbroken run across the whole history, which may lie before
        // the range: every range then gives the same stretch of data the same name, and Charts morphs each line into
        // itself when the range changes instead of into another stretch. Appended readings keep the name too.
        // The range leaves out any server period totals between `preceding` and its start, so it joins the readings
        // on either side of them while every wider range breaks the line there. Such a line takes its name from the
        // range's first reading, as the wider ranges name it, never from the run before the totals.
        let skipsReadings = preceding != nil && valid.last { $0.capturedAt < start } != preceding
        var origin = (skipsReadings ? visible.first?.capturedAt : entries.first?.capturedAt) ?? start
        if !skipsReadings, let first = entries.first {
            var next = first
            var nextPeriod = period(first)
            for earlier in valid.reversed() where earlier.capturedAt < first.capturedAt {
                let earlierPeriod = period(earlier)
                if case .broken = join(earlier, earlierPeriod, next, nextPeriod) { break }
                origin = earlier.capturedAt
                next = earlier
                nextPeriod = earlierPeriod
            }
        }
        var samples: [Sample] = []
        var segment = 0
        var previous: PlanUtilizationHistoryEntry?
        var previousPeriod: TimeInterval?
        for entry in entries {
            let period = period(entry)
            if let previous {
                switch join(previous, previousPeriod, entry, period) {
                case let .reset(instant):
                    if instant > previous.capturedAt {
                        samples.append(Sample(
                            id: previous,
                            date: instant,
                            available: max(0, 100 - previous.usedPercent),
                            segment: segment,
                            period: previousPeriod,
                            isResetEdge: true,
                            seriesOrigin: origin))
                    }
                    if instant < entry.capturedAt {
                        samples.append(Sample(
                            id: entry,
                            date: instant,
                            available: 100,
                            segment: segment,
                            period: period,
                            isResetEdge: true,
                            seriesOrigin: origin))
                    }
                case .plain:
                    break
                case .broken:
                    segment += 1
                    origin = entry.capturedAt
                }
            }
            previous = entry
            previousPeriod = period
            samples.append(Sample(
                id: entry,
                date: entry.capturedAt,
                available: max(0, 100 - entry.usedPercent),
                segment: segment,
                period: period,
                seriesOrigin: origin))
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
        // gets a narrower threshold so missing hours do not become a continuous quota curve. It still
        // spans the slowest regular refresh (30 min) with room for jitter: an idle stretch polled at that
        // pace stays one line instead of a run of lone readings, while a missed refresh still breaks it.
        let cadence = intervals.isEmpty ? 1800 : intervals[(intervals.count - 1) / 2]
        return min(5400, max(2700, cadence * 3))
    }

    func nearest(_ lane: Lane, to date: Date) -> Sample? {
        let start = self.start
        guard date >= start, date <= self.now else { return nil }
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
              previous.date >= start,
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

    private func select(_ date: Date?) {
        self.onSelect(date.map { min(self.chartEnd, max(self.start, $0)) })
    }

    private var timeLocale: Locale {
        codexBarLocalizationSignature().isEmpty ? self.locale : codexBarLocalizedResourceLocale()
    }

    /// Light vertical rules halfway between the labelled instants, so the span reads in even steps: while projecting,
    /// halfway to each edge; otherwise at the middle label.
    var gridDates: [Date] {
        if self.isProjecting {
            return [
                self.start.addingTimeInterval(self.now.timeIntervalSince(self.start) / 2),
                self.now.addingTimeInterval(self.chartEnd.timeIntervalSince(self.now) / 2),
            ]
        }
        let dates = self.axisDates
        return dates.count == 3 ? [dates[1]] : []
    }

    var axisDates: [Date] {
        let interval = self.now.timeIntervalSince(self.start)
        guard interval > 1 else { return [self.now] }
        // Projecting: the range start, now at the center, and the end of the projected span.
        if self.isProjecting { return [self.start, self.now, self.chartEnd] }
        let middle = self.start.addingTimeInterval(interval / 2)
        let aligned = self.days == 1 ? self.calendar.dateInterval(of: .hour, for: middle)?.start
            : self.calendar.startOfDay(for: middle)
        guard let aligned, aligned > self.start, aligned < self.now else { return [self.start, self.now] }
        return [self.start, aligned, self.now]
    }

    private func axisAnchor(_ date: Date?) -> UnitPoint {
        date == self.start ? .topLeading : date == self.chartEnd ? .topTrailing : .top
    }

    func axisLabel(_ date: Date) -> String {
        if date == self.now { return L("Now") }
        let formatter = DateFormatter()
        formatter.locale = self.timeLocale
        formatter.timeZone = self.calendar.timeZone
        // The projecting day spans this time yesterday to this time tomorrow: name the days, not the same hour twice.
        if self.isProjecting, self.days == 1, date == self.start || date == self.chartEnd {
            formatter.doesRelativeDateFormatting = true
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            return formatter.string(from: date)
        }
        let wholeHour = self.calendar.component(.minute, from: date) == 0
        formatter.setLocalizedDateFormatFromTemplate(self.days == 1 ? (wholeHour ? "j" : "jmm") : "MMMd")
        return formatter.string(from: date)
    }

    /// Time labels under the plot, aligned to its frame: the first starts at the plot's leading edge, the last ends
    /// at its trailing edge, and any other (now, while projecting) is centered on its instant. "Now" takes the now
    /// line's accent and weight, and greys out while the pointer inspects another instant.
    private var axisRow: some View {
        GeometryReader { geometry in
            let frame = self.plotFrame
            let dates = self.axisDates
            ZStack(alignment: .topLeading) {
                if frame.width > 0 {
                    ForEach(Array(dates.enumerated()), id: \.offset) { index, date in
                        let label = self.axisText(date)
                        if index == 0 {
                            label
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, frame.minX)
                        } else if index == dates.count - 1 {
                            label
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .padding(.trailing, max(0, geometry.size.width - frame.maxX))
                        } else {
                            label.position(x: self.plotX(date, in: frame), y: 7)
                        }
                    }
                }
            }
        }
        .frame(height: 16)
        .padding(.top, 3)
        .animation(self.reduceMotion ? nil : .smooth(duration: 0.22), value: self.selectedDate == nil)
        .accessibilityHidden(true)
    }

    private func axisText(_ date: Date) -> some View {
        let isNow = date == self.now
        let emphasized = isNow && self.selectedDate == nil
        let key = NativeOrbitAxisLabelKey(
            date: date,
            now: self.now,
            days: self.days,
            projecting: self.isProjecting,
            calendar: self.calendar,
            locale: self.timeLocale)
        return NativeOrbitStaticAxisLabel(widget: self, date: date, key: key)
            .equatable()
            .font(.system(size: 10, weight: emphasized ? .bold : isNow ? .medium : .regular))
            .monospacedDigit()
            .foregroundStyle(emphasized ? AnyShapeStyle(self.plotAccent) : AnyShapeStyle(Color.secondary))
            .lineLimit(1)
            .fixedSize()
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
        if id == "monetary-budget" { return "Budget" }
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

extension NativeOrbitHistoryWidget {
    private func color(_ history: PlanUtilizationSeriesHistory) -> Color {
        NativeOrbitContrast.foreground(
            NativeOrbitPalette.color(
                accent: self.accent, id: history.name.rawValue, period: Double(history.windowMinutes) * 60),
            for: self.colorScheme)
            .opacity(self.spending?.emphasizesQuota == false ? 0.35 : 1)
    }

    private func color(id: String) -> Color {
        NativeOrbitContrast.foreground(
            NativeOrbitPalette.color(
                accent: self.accent, id: id, period: Double(self.quotaWindows[id]?.windowMinutes ?? 0) * 60),
            for: self.colorScheme)
    }

    private var plotAccent: Color {
        NativeOrbitContrast.foreground(self.accent, for: self.colorScheme)
    }

    private var gridInk: Color {
        Color.primary.opacity(self.colorScheme == .dark ? 0.10 : 0.065)
    }

    @ViewBuilder
    private var spendingScale: some View {
        if let spending = self.spending, spending.maximumAmount > 0, self.plotFrame.width > 0 {
            let top = self.plotFrame.maxY - 3 - 0.9 * (self.plotFrame.height - 3)
            Text(
                spending.maximumAmount,
                format: .currency(code: spending.currencyCode).precision(.fractionLength(0...2)))
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(Color.secondary)
                .padding(.horizontal, 2)
                .background(Color(nsColor: .windowBackgroundColor).opacity(0.8), in: RoundedRectangle(cornerRadius: 2))
                .fixedSize()
                .position(x: self.plotFrame.minX + 22, y: max(7, top - 6))
                .allowsHitTesting(false)
        }
    }
}

// MARK: - Spending

extension NativeOrbitHistoryWidget {
    @ChartContentBuilder
    private var spendingMarks: some ChartContent {
        if let spending = self.spending {
            NativeOrbitSpendingMarks(
                history: spending, accent: self.plotAccent, now: self.now, selectedDate: self.selectedDate)
        }
    }
}

// MARK: - Projection

extension NativeOrbitHistoryWidget {
    /// The projection this chart draws; only while the popup projects.
    var drawnProjection: NativeOrbitAccountProjection? {
        self.isProjecting ? self.projection : nil
    }

    /// Scheduled events in the projected half of the chart.
    var projectedEvents: [NativeOrbitScheduledEvent] {
        (self.drawnProjection?.events ?? []).filter { $0.date > self.now && $0.date <= self.chartEnd }
    }

    /// Scheduled events drawn on the chart: through the data end, so every range draws the same marks.
    private var drawnEvents: [NativeOrbitScheduledEvent] {
        (self.drawnProjection?.events ?? []).filter { $0.date > self.now && $0.date <= self.dataEnd }
    }

    /// Room above 100 % for recorded reset glyphs and for the glyphs of scheduled events ahead.
    func plotTopPadding(_ lanes: [Lane]) -> CGFloat {
        Self.topPadding(lanes)
    }

    /// The projection is grey and light: a prediction, never mistaken for a recorded reading.
    var futureAccent: Color {
        Color.secondary.opacity(0.75)
    }

    func futureColor(_ history: PlanUtilizationSeriesHistory) -> Color {
        Color.secondary.opacity(0.6)
    }

    /// The future half: a light grey wash, strongest at now.
    @ChartContentBuilder
    var futureBackdrop: some ChartContent {
        if self.drawnProjection != nil {
            RectangleMark(
                xStart: .value("Now", self.now),
                xEnd: .value("Projected", self.chartEnd))
                .foregroundStyle(LinearGradient(
                    colors: [Color.secondary.opacity(0.09), Color.secondary.opacity(0.03)],
                    startPoint: .leading,
                    endPoint: .trailing))
        }
    }

    /// Each lane's projected availability as a dashed line in its vivid color, rising at every scheduled reset, and
    /// the scheduled events ahead as typed marks.
    @ChartContentBuilder
    func projectionMarks(_ lanes: [Lane]) -> some ChartContent {
        if let projection = self.drawnProjection {
            ForEach(lanes) { lane in
                if let projected = projection.lane(lane.history.name.rawValue) {
                    let color = self.futureColor(lane.history)
                    let stroke = NativeOrbitProjectionStyle.stroke(styleIndex: lane.styleIndex)
                    let points = self.projectionPlotPoints(projected, seriesID: "\(lane.id):projection")
                    LinePlot(
                        points,
                        x: .value("Time", \.date),
                        y: .value("Available", \.available),
                        series: .value("Window", \.seriesID))
                        .interpolationMethod(.linear)
                        .lineStyle(stroke)
                        .foregroundStyle(color)
                }
            }
            ForEach(Self.ruleBatches(self.drawnEvents)) { batch in
                let event = batch.prototype
                let color = self.futureEventColor(event, lanes: lanes)
                RulePlot(batch.events, x: .value("Scheduled", \.date))
                    .lineStyle(NativeOrbitProjectionStyle.eventStroke(event.kind))
                    .foregroundStyle(color.opacity(NativeOrbitProjectionStyle.eventOpacity(event.kind)))
                if let symbol = NativeOrbitProjectionStyle.eventSymbol(event.kind) {
                    PointMark(x: .value("Scheduled", event.date), y: .value("Glyph", Self.glyphLevel))
                        .symbolSize(0)
                        .annotation(position: .overlay) { Self.glyph(symbol, color: color) }
                }
            }
        }
    }

    /// Projected points keyed by their instant and their order at it (a reset draws two points at one instant), not by
    /// their place in the list: a longer or shorter span keeps every shared point's key, so Charts moves each point
    /// into itself instead of into a neighbour.
    /// A reset's first point is drawn half a minute early, like a recorded reset's held edge (`edgeSeparation`).
    static func keyedPoints(
        _ points: [NativeOrbitLaneProjection.Point])
        -> [(key: String, point: NativeOrbitLaneProjection.Point, renderDate: Date)]
    {
        var seen: [Date: Int] = [:]
        return points.enumerated().map { index, point in
            let order = seen[point.date, default: 0]
            seen[point.date] = order + 1
            let pairedAfter = index + 1 < points.count && points[index + 1].date == point.date
            let renderDate = point.isResetEdge && order == 0 && pairedAfter
                ? point.date.addingTimeInterval(-Self.edgeSeparation) : point.date
            return (key: "\(point.date.timeIntervalSinceReferenceDate)|\(order)", point: point, renderDate: renderDate)
        }
    }

    /// The projection on the chart's own scales, drawn over it and blurring progressively away from now: the further
    /// ahead a prediction reaches, the less sharp it is.
    @ViewBuilder
    func futureLayer(_ lanes: [Lane]) -> some View {
        if self.drawnProjection != nil {
            NativeOrbitProgressiveBlur(start: self.nowFraction, radii: self.futureBlurRadii) {
                Chart { self.projectionMarks(lanes) }
                    .chartXScale(
                        domain: self.start...self.chartEnd,
                        range: .plotDimension(startPadding: 0, endPadding: 0))
                    .chartYScale(
                        domain: 0...100,
                        range: .plotDimension(startPadding: 3, endPadding: self.plotTopPadding(lanes)))
                    .chartLegend(.hidden)
                    .chartPlotStyle { $0.clipShape(Rectangle()) }
                    .chartXAxis(.hidden)
                    .chartYAxis(.hidden)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// Blur at now, then at each third of the way to the end of the projected span: predictions soften with distance,
    /// and more over a week or a month than over a day.
    var futureBlurRadii: [CGFloat] {
        NativeOrbitProjectionStyle.chartBlurRadii(days: self.days)
    }

    /// Where now falls across the chart, as a fraction of its width.
    var nowFraction: CGFloat {
        CGFloat(self.now.timeIntervalSince(self.start) / max(1, self.chartEnd.timeIntervalSince(self.start)))
    }

    private func futureEventColor(_ event: NativeOrbitScheduledEvent, lanes: [Lane]) -> Color {
        guard event.laneIDs.count == 1,
              let lane = lanes.first(where: { $0.history.name.rawValue == event.laneIDs[0] })
        else { return self.futureAccent }
        return self.futureColor(lane.history)
    }

    /// The reading a marker dot shows: the hovered instant's, or at now each lane's current reading, which sits at
    /// now from its latest measurement (or the projection's start) when that measurement is recent.
    private func markerReading(_ lane: Lane, at date: Date) -> Sample? {
        if let point = self.nearest(lane, to: date), point.date >= self.start { return point }
        guard date == self.now, let latest = lane.latestMeasuredSample,
              self.now.timeIntervalSince(latest.date) <= NativeOrbitAccountProjection.maximumReadingAge
        else { return nil }
        let available = self.drawnProjection?.lane(lane.history.name.rawValue)?.available(at: self.now)
            ?? latest.available
        return Sample(
            id: latest.id,
            date: self.now,
            available: available,
            segment: latest.segment,
            period: latest.period)
    }

    /// Horizontal position of an instant in the plot, mirroring the chart's linear time scale.
    func plotX(_ date: Date, in frame: CGRect) -> CGFloat {
        let span = max(1, self.chartEnd.timeIntervalSince(self.start))
        return frame.minX + CGFloat(date.timeIntervalSince(self.start) / span) * frame.width
    }

    /// All active marker glyphs share one inspected x coordinate. Apply its uncertainty once, while the neutral
    /// reference at now stays outside this blur. The static projected curves retain their spatial blur separately.
    func markerBlurRadius(at date: Date) -> CGFloat {
        guard self.isProjecting, date > self.now, self.chartEnd > self.now else { return 0 }
        let fraction = date.timeIntervalSince(self.now) / self.chartEnd.timeIntervalSince(self.now)
        return NativeOrbitProjectionStyle.blurRadius(fraction: fraction, days: self.days)
    }

    /// Now is a thick accent line. Hovering springs it to the pointer and leaves a dim neutral line at now; when the
    /// pointer leaves, it springs back. Past instants mark the recorded readings, future ones the projected values
    /// (open dots).
    @ViewBuilder
    func nowMarker(_ lanes: [Lane]) -> some View {
        if self.plotFrame.width > 0, self.plotFrame.height > 16 {
            let frame = self.plotFrame
            let topPadding = self.plotTopPadding(lanes)
            let y = { (available: Double) in
                frame.maxY - 3 - CGFloat(min(100, max(0, available)) / 100) * (frame.height - 3 - topPadding)
            }
            let marker = self.selectedDate ?? self.now
            ZStack(alignment: .topLeading) {
                Capsule()
                    .fill(self.accent.gradient)
                    .overlay {
                        Capsule().strokeBorder(
                            Color.primary.opacity(self.colorScheme == .dark ? 0.5 : 0.18),
                            lineWidth: 0.65)
                    }
                    .shadow(color: .black.opacity(0.25), radius: 1, x: 0, y: 0.5)
                    .frame(width: self.selectedDate == nil ? 3.5 : 2.5, height: frame.height)
                    .position(x: self.plotX(marker, in: frame), y: frame.midY)
                // The hovered moment's readings, or at rest each lane's current one on the now line.
                let date = self.selectedDate ?? self.now
                ForEach(lanes) { lane in
                    if date > self.now, let projected = self.drawnProjection?.lane(lane.history.name.rawValue) {
                        Circle()
                            .strokeBorder(self.futureColor(lane.history), lineWidth: 1.5)
                            .background(Circle().fill(self.futureColor(lane.history).opacity(0.25)))
                            .frame(width: 7, height: 7)
                            .position(x: self.plotX(date, in: frame), y: y(projected.available(at: date)))
                    } else if date <= self.now, let point = self.markerReading(lane, at: date) {
                        // A halo in the window's colour keeps the dot clear of the line it sits on.
                        Circle()
                            .fill(self.color(lane.history))
                            .frame(width: 7, height: 7)
                            .background(Circle().fill(Color(nsColor: .windowBackgroundColor)).padding(-1.5))
                            .position(x: self.plotX(point.date, in: frame), y: y(point.available))
                    }
                }
                if date <= self.now, let spending = self.spending, let bar = spending.bar(at: date) {
                    if self.selectedDate != nil, bar.granularity != .event {
                        let start = max(self.start, bar.start)
                        let end = min(self.chartEnd, min(self.now, bar.end))
                        let left = self.plotX(start, in: frame)
                        let right = self.plotX(end, in: frame)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(self.plotAccent.opacity(0.10))
                            .overlay { RoundedRectangle(cornerRadius: 2).strokeBorder(self.plotAccent, lineWidth: 0.8) }
                            .frame(width: max(0, right - left), height: max(1, frame.maxY - y(spending.height(bar))))
                            .position(x: (left + right) / 2, y: (frame.maxY + y(spending.height(bar))) / 2)
                    }
                    Circle()
                        .fill(self.plotAccent.opacity(spending.emphasizesQuota ? 0.65 : 1))
                        .frame(width: 5, height: 5)
                        .position(x: self.plotX(date, in: frame), y: y(spending.height(bar)))
                }
            }
            .blur(radius: self.markerBlurRadius(at: marker))
            .background(alignment: .topLeading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.55))
                    .frame(width: 1.5, height: frame.height)
                    .position(x: self.plotX(self.now, in: frame), y: frame.midY)
                    .opacity(self.selectedDate == nil ? 0 : 1)
            }
            .animation(
                self.reduceMotion ? nil : NativeOrbitProjectionStyle.markerSpring,
                value: self.selectedDate)
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }
}

/// Reset marks: how each kind of reset is stroked, tinted and glyphed on the chart.
extension NativeOrbitHistoryWidget {
    /// Recorded resets are solid rules (dashes mean projected); weight and the glyph above tell the kinds apart.
    static func resetStroke(_ kind: NativeOrbitResetEvent.Kind) -> StrokeStyle {
        switch kind {
        case .natural: StrokeStyle(lineWidth: 0.5, lineCap: .round)
        case .manual, .provider: StrokeStyle(lineWidth: 1, lineCap: .round)
        case .early: StrokeStyle(lineWidth: 0.75, lineCap: .round)
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

    /// The plot's padding above 100 %. The plot keeps its height whatever it marks: reset glyphs ride on their
    /// rules inside the plot.
    static func topPadding(_ lanes: [Lane]) -> CGFloat {
        3
    }

    /// Glyphs sit just above the plot's floor, on their reset rule.
    static let glyphLevel = 7.0

    /// A reset glyph on a knockout disc, so it reads cleanly over the lines and the rule beneath it.
    static func glyph(_ symbol: String, color: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 9, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(color)
            .padding(1.5)
            .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
    }

    /// A reset that broke the window's schedule gets a glyph; a window whose countdown ran out was planned, so
    /// only its faint rule marks it.
    static func resetSymbol(_ kind: NativeOrbitResetEvent.Kind) -> String? {
        switch kind {
        case .natural: nil
        // The banked-reset glyph of the dial's bottom-leading corner.
        case .manual: "arrow.uturn.backward.circle.fill"
        case .provider: "building.2.crop.circle.fill"
        case .early: "questionmark.circle.fill"
        }
    }
}

extension NativeOrbitHistoryWidget {
    var body: some View {
        let lanes = self.lanes
        return NativeOrbitChartReveal(
            phase: self.startup,
            contentKey: NativeOrbitHistoryRevealKey(
                plot: self.plotKey(lanes),
                selectedDate: self.selectedDate,
                plotFrame: self.plotFrame,
                showsEmptyState: self.showsEmptyState))
        {
            self.content(lanes)
        }
        .frame(width: 224, height: 224)
    }

    private func content(_ lanes: [Lane]) -> some View {
        Group {
            if !lanes.isEmpty || !self.metricObservationDates.isEmpty || !self.visibleEvents.isEmpty
                || !(self.spending?.bars.isEmpty ?? true)
                || !(self.drawnProjection?.lanes.isEmpty ?? true)
            {
                VStack(spacing: 0) {
                    // Clear space under the separator, where the hover pill sits.
                    Color.clear.frame(height: 12)
                    self.plot(lanes)
                    self.axisRow
                }
            } else if self.showsEmptyState {
                VStack(spacing: 6) {
                    Image(systemName: "chart.xyaxis.line").font(.system(size: 22, weight: .medium))
                    Text(L("No observations")).font(.callout)
                }
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, 12)
            } else {
                Color.clear
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
        .frame(width: 224, height: 224)
        .onChange(of: self.days) { self.select(nil) }
    }
}

private struct NativeOrbitHistoryRevealKey: Equatable {
    let plot: NativeOrbitPlotKey
    let selectedDate: Date?
    let plotFrame: CGRect
    let showsEmptyState: Bool
}

/// A mark on the chart the hover pill can name.
struct NativeOrbitMarkedEvent: Equatable {
    let date: Date
    let symbol: String?
    let title: String
    /// Ahead of now: drawn in the projection's grey.
    let isScheduled: Bool
}

struct NativeOrbitPlotKey: Equatable, Sendable {
    let days: Int
    let start: Date
    let end: Date
    let accent: Color
    let lanes: [String]
    /// The chart's reset marks; a reclassified reset redraws even when no sample changed.
    let resetEvents: [String]
    /// The projected lines and scheduled marks; empty while not projecting.
    var projection: [String] = []
    var spending: [String] = []
    var darkAppearance = false
    var localeIdentifier = ""
    var reduceMotion = false
    /// Exact source equality detects corrected interior readings. Entry arrays share their storage while the
    /// pointer moves, so ordinary comparisons stay constant-time per lane without hashing the history again.
    var histories: [PlanUtilizationSeriesHistory] = []
    var observationDates: [Date] = []
    var quotaLabels: [String: String] = [:]
    var quotaWindows: [String: RateWindow] = [:]
    var providerID: String?
    var calendar = Calendar.current
}

/// A native hosting boundary keeps pointer-driven parent layout/transactions out of Charts' internal GeometryReaders.
/// EquatableView alone does not isolate those readers: an ancestor hover update can still rebuild all point marks.
private struct NativeOrbitStaticPlot: NSViewRepresentable, Equatable {
    let widget: NativeOrbitHistoryWidget
    let lanes: [NativeOrbitHistoryWidget.Lane]
    nonisolated let key: NativeOrbitPlotKey
    let onPlotFrame: (CGRect) -> Void

    final class Coordinator {
        var key: NativeOrbitPlotKey?
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.key == rhs.key }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSHostingView<AnyView> {
        let host = NSHostingView(rootView: self.content)
        // SwiftUI's parent owns the chart's proposed dimensions; intrinsic hosting constraints must not feed back
        // into layout or resize the plot when its hidden axes/mark annotations change.
        host.sizingOptions = []
        context.coordinator.key = self.key
        return host
    }

    func updateNSView(_ host: NSHostingView<AnyView>, context: Context) {
        guard context.coordinator.key != self.key else { return }
        context.coordinator.key = self.key
        host.rootView = self.content
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: NSHostingView<AnyView>,
        context: Context) -> CGSize?
    {
        // Ideal plot inside the 224-point widget: 14-point horizontal insets, 12-point headroom, 19-point axis row
        // and 6-point bottom inset. Every actual parent proposal takes precedence over these ideal dimensions.
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 196, height: 187))
    }

    private var content: AnyView {
        AnyView(self.widget.renderedChart(self.lanes)
            .onPreferenceChange(NativeOrbitPlotFrameKey.self, perform: self.onPlotFrame))
    }
}

/// Tick wording stays fixed while the pointer moves; emphasis remains outside this child and updates immediately.
private struct NativeOrbitAxisLabelKey: Equatable, Sendable {
    let date: Date
    let now: Date
    let days: Int
    let projecting: Bool
    let calendar: Calendar
    let locale: Locale
}

private struct NativeOrbitStaticAxisLabel: View, Equatable {
    let widget: NativeOrbitHistoryWidget
    let date: Date
    nonisolated let key: NativeOrbitAxisLabelKey

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.key == rhs.key }

    var body: some View {
        Text(self.widget.axisLabel(self.date))
    }
}

/// One resolved content symbol drawn at rising blur radii, cross-faded along x from `start` to the trailing edge.
/// Layers add (plus lighter) and their weights sum to one, retaining colour and weight wherever a line is sharp.
/// The outset leaves room for blur beyond the edges without constructing and laying out a Chart for each radius.
struct NativeOrbitProgressiveBlur<Content: View>: View {
    let start: CGFloat
    let radii: [CGFloat]
    @ViewBuilder let content: Content

    /// Room past every edge for the strongest blur to spread into.
    private var outset: CGFloat {
        max(4, (self.radii.max() ?? 0) * 3)
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let width = size.width + 2 * self.outset
            let height = size.height + 2 * self.outset
            // `start` and the trailing edge in the outset canvas.
            let from = (self.outset + self.start * size.width) / max(1, width)
            let to = (self.outset + size.width) / max(1, width)
            Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: false) { context, canvasSize in
                guard let symbol = context.resolveSymbol(id: 0) else { return }
                let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
                let bounds = Path(CGRect(origin: .zero, size: canvasSize))
                context.blendMode = .plusLighter
                for (index, radius) in self.radii.enumerated() {
                    context.drawLayer { layer in
                        layer.drawLayer { blurred in
                            blurred.addFilter(.blur(radius: radius))
                            blurred.draw(symbol, at: center)
                        }
                        layer.blendMode = .destinationIn
                        layer.fill(bounds, with: .linearGradient(
                            Gradient(stops: self.stops(for: index, from: from, to: to)),
                            startPoint: .zero,
                            endPoint: CGPoint(x: canvasSize.width, y: 0)))
                    }
                }
            } symbols: {
                self.content.frame(width: size.width, height: size.height).tag(0)
            }
            .frame(width: width, height: height)
            .padding(-self.outset)
        }
    }

    /// A hat over this copy's anchor between `from` and `to`; the last copy also covers the outset beyond `to`.
    private func stops(for index: Int, from: CGFloat, to: CGFloat) -> [Gradient.Stop] {
        let count = self.radii.count
        let anchors = (0..<count).map { from + (to - from) * CGFloat($0) / CGFloat(max(1, count - 1)) }
        var stops: [Gradient.Stop] = []
        if index == 0 {
            stops.append(.init(color: .white, location: 0))
        } else {
            stops.append(.init(color: .clear, location: 0))
            stops.append(.init(color: .clear, location: anchors[index - 1]))
        }
        stops.append(.init(color: .white, location: anchors[index]))
        if index == count - 1 {
            stops.append(.init(color: .white, location: 1))
        } else {
            stops.append(.init(color: .clear, location: anchors[index + 1]))
            stops.append(.init(color: .clear, location: 1))
        }
        return stops
    }
}

private struct NativeOrbitPlotFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}
