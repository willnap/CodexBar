import CodexBarCore
import Foundation

/// Offline search catalog; never constructs live provider settings or reads credentials.
struct SettingsSearchIndex: Sendable {
    static let shared = SettingsSearchIndex()

    private struct Catalog: Decodable, Sendable {
        let panes: [String: [String]]
        let providers: [String: [String]]
    }

    private let catalog: Catalog

    private static let nativeMenuBarOnlyKeys: Set = [
        "Combine into one icon", "With 4 or more services", "Always", "Manage services in the sidebar.",
    ]

    private init() {
        let bundle = codexBarLocalizationResourceBundle()
        if let url = bundle.url(forResource: "SettingsSearchIndex", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let catalog = try? JSONDecoder().decode(Catalog.self, from: data)
        {
            self.catalog = catalog
        } else {
            self.catalog = Catalog(panes: [:], providers: [:])
        }
    }

    /// All query words may match across a destination title, labels, help, and active account text.
    static func matches(query: String, text: String) -> Bool {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        let words = self.words(query)
        guard !words.isEmpty else { return false }
        let normalizedText = self.words(text).joined(separator: " ")
        return words.allSatisfy { normalizedText.contains($0) }
    }

    /// Returns a localized label/help snippet explaining why the destination matched.
    /// Localization is resolved per query, so changing the app language never leaves stale results.
    func match(
        pane: SettingsPane,
        query: String,
        usesNativeGauges: Bool = false,
        nativeDesignEnabled: Bool = false) -> String?
    {
        let words = Self.words(query)
        guard !words.isEmpty else { return nil }
        let title = pane.title
        if Self.matches(query: query, text: title) { return title }

        let keys: [String] = switch pane {
        case let .provider(instanceID):
            self.catalog.providers[instanceID.rawValue] ?? []
        default:
            self.catalog.panes[pane.persistenceToken] ?? []
        }
        let visibleKeys = keys.filter { key in
            if pane == .menu, usesNativeGauges || nativeDesignEnabled,
               key.hasPrefix("account_widgets_") || key == "section_widgets" { return false }
            guard usesNativeGauges else {
                if pane == .menu {
                    return !["Local usage totals", "Local agents", "Keep Mac awake while agents run"].contains(key)
                        && !key.hasPrefix("Prevents idle system sleep")
                }
                if pane == .menuBar { return !Self.nativeMenuBarOnlyKeys.contains(key) }
                return true
            }
            switch pane {
            case .menuBar:
                return ["Style", "Custom gauges", "Legacy icons"].contains(key)
                    || Self.nativeMenuBarOnlyKeys.contains(key)
            case .menu:
                let legacyPrefixes = [
                    "usage_bars_fill_", "reset_times_", "show_quota_warning_markers_",
                    "workday_tick_appearance_", "overview_layout_", "multi_account_layout_",
                    "agent_sessions_", "agent_session_", "cost_status_", "cost_summary_style_",
                    "cost_comparison_periods_", "Prevent idle system sleep while a local agent process",
                ]
                let legacyKeys = [
                    "weekly_progress_work_days_title", "show_provider_changelog_links_title",
                    "section_agent_sessions", "cost_data_explanation", "Stay Awake", "Automatic",
                    "%d days", "4 days", "5 days", "cost_summary_off", "cost_summary_title",
                    "show_cost_summary_subtitle", "section_cost_summary", "today",
                ]
                return !legacyPrefixes.contains(where: key.hasPrefix) && !legacyKeys.contains(key)
            default:
                return true
            }
        }
        var labels = visibleKeys.map { L($0) }
        if pane == .general {
            // The language picker displays each option in its native language.
            labels += AppLanguage.allCases.map(\.label)
        }
        guard Self.matches(query: query, text: ([title] + labels).joined(separator: " ")) else { return nil }

        // Prefer the label covering the most query words. Short labels beat their longer help text
        // when both explain the same match; help remains searchable and can itself be the snippet.
        var bestLabel: String?
        var bestWordCount = 0
        for label in labels {
            let normalized = Self.words(label).joined(separator: " ")
            let wordCount = words.count { normalized.contains($0) }
            if wordCount > bestWordCount ||
                (wordCount == bestWordCount && wordCount > 0 && label.count < (bestLabel?.count ?? .max))
            {
                bestLabel = label
                bestWordCount = wordCount
            }
        }
        return bestLabel ?? title
    }

    func providerSearchText(for provider: UsageProvider) -> String {
        (self.catalog.providers[provider.rawValue] ?? []).map { L($0) }.joined(separator: "\n")
    }

    private static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
