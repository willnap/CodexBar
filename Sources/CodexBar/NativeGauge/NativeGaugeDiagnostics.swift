import AppKit
import CodexBarCore
import Foundation

/// Opt-in inspection of the production data path. Contains usage and geometry, never credentials or account labels.
@MainActor
enum NativeGaugeDiagnostics {
    private static var services: [String: [String: Any]] = [:]

    static func record(
        provider: UsageProvider,
        presentation: NativeServicePresentation,
        item: NSStatusItem,
        host: NativeGaugeHostingView)
    {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_NATIVE_DIAGNOSTICS_PATH"] else { return }
        self.services[provider.rawValue] = [
            "updatedAt": ISO8601DateFormatter().string(from: Date()),
            "health": presentation.gauge.health.rawValue,
            "hasSelectedAccount": presentation.accountID != nil,
            "length": item.length,
            "buttonBounds": NSStringFromRect(item.button?.bounds ?? .zero),
            "statusWindowFrame": NSStringFromRect(item.button?.window?.frame ?? .zero),
            "hostFrame": NSStringFromRect(host.frame),
            "windows": presentation.gauge.resolvedWindows.map { window in
                [
                    "id": window.id,
                    "label": window.label,
                    "usedFraction": window.usedFraction.map { $0 as Any } ?? NSNull(),
                    "period": window.period,
                ] as [String: Any]
            },
            "cardMetrics": presentation.model.metrics.map { metric in
                [
                    "id": metric.id,
                    "title": metric.title,
                    "percent": metric.percent,
                    "percentStyle": String(describing: metric.percentStyle),
                ] as [String: Any]
            },
        ]
        do {
            try JSONSerialization.data(withJSONObject: self.services, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            CodexBarLog.logger("native-gauges").error("Could not write native gauge diagnostics")
        }
    }
}
