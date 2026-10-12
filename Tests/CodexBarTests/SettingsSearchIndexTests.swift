import CodexBarCore
import Testing
@testable import CodexBar

struct SettingsSearchIndexTests {
    @Test
    func `native Menu search omits legacy controls and retains pace`() {
        CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            for query in [
                "Usage bars fill", "Reset times", "Clock time", "Countdown", "Show quota warning markers",
                "Work days", "Show shorter comparison periods", "Inline only",
            ] {
                #expect(SettingsSearchIndex.shared.match(pane: .menu, query: query, usesNativeGauges: true) == nil)
                #expect(SettingsSearchIndex.shared.match(pane: .menu, query: query, usesNativeGauges: false) != nil)
            }
            #expect(SettingsSearchIndex.shared.match(pane: .menu, query: "Show pace", usesNativeGauges: true)
                == "Show pace")
            #expect(SettingsSearchIndex.shared.match(pane: .menu, query: "Local usage totals", usesNativeGauges: true)
                == "Local usage totals")
        }
    }

    @Test
    func `native Menu Bar search exposes its style selector and excludes legacy editors`() {
        CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            for query in ["Style", "Custom gauges", "Legacy icons"] {
                #expect(SettingsSearchIndex.shared.match(pane: .menuBar, query: query, usesNativeGauges: true) != nil)
            }
            for query in ["Color by provider", "Merge icons", "Pace sign"] {
                #expect(SettingsSearchIndex.shared.match(pane: .menuBar, query: query, usesNativeGauges: true) == nil)
                #expect(SettingsSearchIndex.shared.match(pane: .menuBar, query: query, usesNativeGauges: false) != nil)
            }
        }
    }

    @Test
    func `legacy Menu search never captions native only settings`() {
        CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            for label in ["Local usage totals", "Local agents", "Keep Mac awake while agents run"] {
                #expect(SettingsSearchIndex.shared.match(pane: .menu, query: label, usesNativeGauges: false) != label)
            }
            #expect(SettingsSearchIndex.shared.match(pane: .menu, query: "today", usesNativeGauges: true) == nil)
        }
    }

    @Test
    func `global search finds launch settings without a pane title match`() {
        #expect(SettingsSearchIndex.shared.match(pane: .general, query: "START at login") == "Start at login")
        #expect(SettingsSearchIndex.shared.match(pane: .notifications, query: "start at login") == nil)
    }

    @Test
    func `global search finds refresh on menu open and combines words`() {
        #expect(SettingsSearchIndex.shared.match(pane: .general, query: "menu refresh")
            == "Refresh when the menu opens")
        #expect(SettingsSearchIndex.shared.match(pane: .general, query: "refresh neverexistentword") == nil)
    }

    @Test
    func `provider search includes actual cookie and configuration labels`() {
        #expect(SettingsSearchIndex.shared.providerSearchText(for: .claude).contains("Cookie source"))
        #expect(SettingsSearchIndex.shared.match(pane: .provider(.claude), query: "cookie source") == "Cookie source")
        #expect(SettingsSearchIndex.shared.providerSearchText(for: .azureopenai).contains("API key"))
    }

    @Test
    func `provider search includes embedded account settings`() {
        #expect(SettingsSearchIndex.shared.match(pane: .provider(.codex), query: "Re-auth") == "Re-auth")
        #expect(SettingsSearchIndex.shared.match(pane: .provider(.codex), query: "Codex add account") == "Add Account")
    }

    @Test
    func `shared matcher combines provider labels configuration and active account words`() {
        let text = "Claude claude Cookie source Jade@example.test"
        #expect(SettingsSearchIndex.matches(query: "claude cookie jade example", text: text))
        #expect(SettingsSearchIndex.matches(query: "CLA coo jáde", text: text))
        #expect(!SettingsSearchIndex.matches(query: "claude cookie absent", text: text))
    }

    @Test
    func `shared matcher allows blank filters and rejects punctuation only`() {
        #expect(SettingsSearchIndex.matches(query: " \n", text: "Claude"))
        #expect(!SettingsSearchIndex.matches(query: "--", text: "Claude"))
    }

    @Test
    func `queries normalize punctuation whitespace case and diacritics`() {
        #expect(SettingsSearchIndex.shared.match(pane: .general, query: "  stárt-at LOGIN\n") == "Start at login")
        #expect(SettingsSearchIndex.shared.match(pane: .general, query: "") == nil)
        #expect(SettingsSearchIndex.shared.match(pane: .general, query: "  ---  ") == nil)
        #expect(SettingsSearchIndex.shared.match(pane: .general, query: "neverexistentword") == nil)
    }

    @Test
    func `queries follow the current language instead of cached English`() {
        CodexBarLocalizationOverride.$appLanguage.withValue("de") {
            #expect(SettingsSearchIndex.shared.match(pane: .general, query: "Beim Login starten")
                == L("start_at_login_title", language: "de"))
        }
        CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            #expect(SettingsSearchIndex.shared.match(pane: .general, query: "start at login") == "Start at login")
            #expect(SettingsSearchIndex.shared.match(pane: .general, query: "Beim") == nil)
        }
    }

    @Test
    func `German app search finds language options by their displayed native labels`() {
        CodexBarLocalizationOverride.$appLanguage.withValue("de") {
            #expect(SettingsSearchIndex.shared.match(pane: .general, query: "English") == "English")
            #expect(SettingsSearchIndex.shared.match(pane: .general, query: "日本語") == "日本語")
        }
    }
}
