import AppKit
import CodexBarCore
import ServiceManagement

/// Validate the packaged catalog before account loading or provider requests.
@MainActor
enum NativeSymbolSmoke {
    static func run() -> Int32 {
        var missing: [String] = []
        var checked = Set<String>()
        for provider in UsageProvider.allCases {
            guard let service = ServiceIdentity.find(provider.rawValue) else {
                missing.append(provider.rawValue)
                continue
            }
            for size in [18.0, 20.0, 22.0] {
                let name = service.symbol(size)
                guard checked.insert(name).inserted else { continue }
                if NSImage(named: name) == nil, Bundle.main.image(forResource: name) == nil {
                    missing.append(name)
                }
            }
        }
        // Parent-company marks are supplementary assets, distinct from the provider catalog's compact products.
        for name in ["provider.openai", "provider.anthropic", "provider.codex", "provider.claudecode"] {
            checked.insert(name)
            if NSImage(named: name) == nil, Bundle.main.image(forResource: name) == nil {
                missing.append(name)
            }
        }
        for name in [
            "gearshape.fill", "icloud.fill", "chart.xyaxis.line", "bell.badge.fill", "menubar.rectangle",
            "filemenu.and.selection", "slider.horizontal.3", "bolt.fill", "puzzlepiece.extension.fill", "ladybug.fill",
            "arrow.up.to.line",
        ] where NSImage(systemSymbolName: name, accessibilityDescription: nil) == nil {
            missing.append(name)
        }
        if SettingsSearchIndex.shared.match(pane: .general, query: L("start_at_login_title")) == nil {
            missing.append("SettingsSearchIndex")
        }
        print("Native symbols: \(checked.count) custom assets; missing: \(missing.joined(separator: ", "))")
        print("Login item status: \(SMAppService.mainApp.status.rawValue)")
        return missing.isEmpty ? 0 : 1
    }
}
