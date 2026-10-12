import AppKit
import CodexBarCore

@MainActor
enum NativeServicePopoverContent {
    static func populate(_ stack: NSStackView, model: UsageMenuCardView.Model) {
        for metric in model.metrics {
            let title = UsageMenuCardView.popupMetricTitle(provider: model.provider, metric: metric)
            let presentation = metric.linePresentation(title: title)
            self.section(
                title: metric.statusText == nil ? presentation.titleText : title,
                percent: metric.statusText == nil ? metric.percent : nil,
                lines: [metric.statusText, presentation.resetText, presentation.metaText, metric.detailText],
                in: stack)
        }
        if let reset = model.limitResetCredits {
            self.section(title: L("Limit Reset Credits"), percent: nil, lines: [reset.text, reset.helpText], in: stack)
        }
        for note in model.usageNotes + model.subscriptionNotes {
            self.append(self.label(note), to: stack)
        }
        if model.metrics.isEmpty, let placeholder = model.placeholder {
            self.append(self.label(placeholder), to: stack)
        }
        if let credits = model.creditsText {
            self.section(
                title: credits,
                percent: model.creditsShowProgress ? model.creditsProgressPercent : nil,
                lines: [model.creditsScaleText, model.creditsHintText],
                in: stack)
        }
        for cost in [model.cloudCredits, model.providerCost].compactMap(\.self) {
            let percent = cost.percentUsed.map { cost.percentStyle == .left ? 100 - $0 : $0 }
            self.section(
                title: cost.title,
                percent: percent,
                lines: [cost.spendLine, cost.percentLine, cost.balanceLine, cost.personalSpendLine],
                in: stack)
        }
        if let tokens = model.tokenUsage {
            self.section(
                title: L("Token history"),
                percent: nil,
                lines: [tokens.sessionLine, tokens.monthLine, tokens.meteredLine]
                    + tokens.comparisonLines.map(Optional.some) + [tokens.hintLine, tokens.errorLine], in: stack)
        }
        if let dashboard = model.inlineUsageDashboard {
            for kpi in dashboard.kpis {
                self.append(self.label("\(kpi.title): \(kpi.value)"), to: stack)
            }
            if !dashboard.points.isEmpty {
                self.append(NativeUsageChartView(points: dashboard.points.map {
                    ($0.label, $0.value)
                }), to: stack)
            }
            for line in dashboard.detailLines {
                self.append(self.label(line), to: stack)
            }
            for window in dashboard.quotaWindows {
                self.section(
                    title: window.title,
                    percent: nil,
                    lines: [window.range, window.value, window.note],
                    in: stack)
            }
        }
        for section in model.providerDetails {
            if let title = section.title {
                self.append(self.label(title, emphasis: true), to: stack)
            }
            for row in section.rows {
                self.section(
                    title: "\(row.label): \(row.value)",
                    percent: row.progress?.usedPercent,
                    lines: [row.secondaryValue],
                    in: stack)
            }
            if let chart = section.chart {
                if let title = chart.title {
                    self.append(self.label(title), to: stack)
                }
                self.append(
                    NativeUsageChartView(
                        points: chart.points.map { ($0.label, Optional($0.value)) },
                        isLine: chart.kind == .line,
                        unit: chart.unit),
                    to: stack)
            }
        }
    }

    private static func section(title: String, percent: Double?, lines: [String?], in stack: NSStackView) {
        let section = NSStackView()
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 4
        self.append(self.label(title, emphasis: true), to: section)
        if let percent, percent.isFinite {
            let progress = NSProgressIndicator()
            progress.style = .bar
            progress.isIndeterminate = false
            progress.minValue = 0
            progress.maxValue = 100
            progress.doubleValue = min(100, max(0, percent))
            progress.controlSize = .small
            progress.setAccessibilityLabel(title)
            self.append(progress, to: section)
        }
        for line in lines.compactMap(\.self).filter({ !$0.isEmpty }) {
            self.append(self.label(line), to: section)
        }
        self.append(section, to: stack)
    }

    private static func label(_ text: String, emphasis: Bool = false) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: emphasis ? 13 : 11, weight: emphasis ? .medium : .regular)
        label.textColor = emphasis ? .labelColor : .secondaryLabelColor
        label.isSelectable = true
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        return label
    }

    private static func append(_ child: NSView, to stack: NSStackView) {
        stack.addArrangedSubview(child)
        child.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -stack.edgeInsets.right).isActive = true
    }
}

/// Native drawing keeps supplemental history charts outside the SwiftUI rendering graph too.
@MainActor
private final class NativeUsageChartView: NSView {
    private let points: [(String, Double?)]
    private let isLine: Bool

    init(points: [(String, Double?)], isLine: Bool = false, unit: String? = nil) {
        self.points = points
        self.isLine = isLine
        super.init(frame: .zero)
        self.heightAnchor.constraint(equalToConstant: 58).isActive = true
        self.setAccessibilityElement(true)
        self.setAccessibilityRole(.image)
        self.setAccessibilityLabel(points.map { label, value in
            "\(label): \(value.map(String.init(describing:)) ?? "—") \(unit ?? "")"
        }.joined(separator: ", "))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let values = self.points.compactMap(\.1).filter(\.isFinite)
        guard let maximum = values.max(), maximum > 0, !self.points.isEmpty else { return }
        NSColor.controlAccentColor.set()
        let path = NSBezierPath()
        var continuing = false
        let columnWidth = self.bounds.width / CGFloat(self.points.count)
        for (index, point) in self.points.enumerated() {
            guard let value = point.1, value.isFinite else {
                continuing = false
                continue
            }
            let height = self.bounds.height * CGFloat(max(0, value) / maximum)
            if self.isLine {
                let position = NSPoint(x: (CGFloat(index) + 0.5) * columnWidth, y: height)
                if continuing { path.line(to: position) } else { path.move(to: position) }
                continuing = true
            } else {
                NSBezierPath(
                    roundedRect: NSRect(
                        x: CGFloat(index) * columnWidth,
                        y: 0,
                        width: max(1, columnWidth - 2),
                        height: max(1, height)),
                    xRadius: 1.5,
                    yRadius: 1.5).fill()
            }
        }
        if self.isLine {
            path.lineWidth = 2
            path.stroke()
        }
    }
}

final class NativePopoverDocumentView: NSStackView {
    override var isFlipped: Bool {
        true
    }
}
