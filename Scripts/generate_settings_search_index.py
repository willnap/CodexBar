#!/usr/bin/env python3
"""Generate the offline localized settings catalog from shipped UI source.

No app code is executed. Keys (never user values) are bundled and localized at
query time. Run --check in CI to detect source/catalog drift.
"""
import argparse
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "Sources/CodexBar"
CORE = ROOT / "Sources/CodexBarCore"
OUTPUT = APP / "Resources/SettingsSearchIndex.json"
STRING = r'"(?:\\.|[^"\\])*"'
STRINGS = re.compile(STRING)
CONCAT = re.compile(STRING + r'(?:\s*\+\s*' + STRING + r')+')
LOCALIZED = re.compile(r'\b(?:L|localized)\(\s*(' + STRING + r')')

# Destinations and their embedded editors. Provider destinations are discovered
# below by source IDs; no hand-maintained provider/category list is involved.
PANE_FILES = {
    "general": ["PreferencesGeneralPane.swift", "PreferencesTransferSection.swift"],
    "iCloudSync": ["PreferencesICloudSyncPane.swift"],
    "usageSpend": ["PreferencesSpendDashboardPane.swift"],
    "notifications": ["PreferencesNotificationsPane.swift", "QuotaWarningSettingsViews.swift"],
    "menuBar": ["PreferencesMenuBarPane.swift", "MenuBarLayout*.swift", "NativeGauge/NativeGaugePreferences.swift"],
    "menu": ["PreferencesMenuPane.swift", "PreferencesMenuPicker.swift"],
    "advanced": ["PreferencesAdvancedPane.swift"],
    "hooks": ["PreferencesHooksPane.swift"],
    "plugins": ["PreferencesPluginsPane.swift"],
    "about": ["PreferencesAboutPane.swift", "UpdateChannel.swift"],
    "debug": ["PreferencesDebugPane.swift"],
}
PANE_ENUMS = {
    "general": ["RefreshFrequency"],
    "menuBar": ["MenuBarIconStyle", "SwitcherRowsOption", "MergedIconDisplayStyle", "MergedOverviewLayout"],
    "menu": ["UsageBarsFillOption", "ResetTimesOption", "CostSummaryOption", "AgentSessionLabelStyle",
             "MultiAccountMenuLayout", "WorkdayTickAppearance", "CostSummaryDisplayStyle"],
    "notifications": ["ConfettiCelebrationOption"],
}
COMMON_PROVIDER_FILES = [
    "ProviderAccentColorSettingsView.swift", "ProviderMenuBarPercentWindowSettingsView.swift",
    "PreferencesProviderSettingsMetrics.swift",
]


def decoded(literal):
    try:
        return json.loads(literal)
    except ValueError:
        # Swift interpolation and Swift-specific escapes aren't literal labels.
        return None


def extract(text, known):
    values = {value for match in STRINGS.finditer(text)
              if (value := decoded(match.group())) in known}
    for match in LOCALIZED.finditer(text):
        value = decoded(match.group(1))
        if value:
            values.add(value)
    for match in CONCAT.finditer(text):
        parts = [decoded(part.group()) for part in STRINGS.finditer(match.group())]
        if all(part is not None for part in parts):
            value = "".join(parts)
            if value in known:
                values.add(value)
    return values


def file_keys(paths, known):
    values = set()
    for path in sorted(set(paths)):
        values.update(extract(path.read_text(), known))
    return values


def enum_text(text, name):
    # Top-level enum blocks end at the next declaration. Nested helpers remain.
    match = re.search(r'^enum ' + re.escape(name) + r'\b.*?(?=^\S|\Z)', text, re.M | re.S)
    return match.group() if match else ""


def generate():
    english = (APP / "Resources/en.lproj/Localizable.strings").read_text()
    known = {decoded(match.group(1)) for match in re.finditer('(' + STRING + r')\s*=', english)}
    panes = {}
    enum_sources = "\n".join(path.read_text() for path in [
        APP / "SettingsStore.swift", APP / "SettingsStore+MenuPreferences.swift"])
    for pane, patterns in PANE_FILES.items():
        keys = file_keys([path for pattern in patterns for path in APP.glob(pattern)], known)
        for name in PANE_ENUMS.get(pane, []):
            keys.update(extract(enum_text(enum_sources, name), known))
        panes[pane] = sorted(keys)

    common = file_keys([APP / name for name in COMMON_PROVIDER_FILES], known)
    quota_text = (APP / "QuotaWarningSettingsViews.swift").read_text()
    provider_quota = quota_text.split("struct ProviderQuotaWarningSettingsView", 1)[1].split(
        "enum ProviderQuotaWarningOverrideMode", 1)[0]
    common.update(extract(provider_quota, known))
    detail_text = (APP / "PreferencesProviderDetailView.swift").read_text()
    visibility_text = detail_text.split("struct ProviderUsageItemVisibilitySettingsView", 1)[1].split(
        "struct ProviderDetailInfoRows", 1)[0]
    common.update(extract(visibility_text, known))
    rows_text = (APP / "PreferencesProviderSettingsRows.swift").read_text()
    token_rows = re.search(r'struct ProviderSettingsTokenAccountsRowView\b.*?(?=^extension View)',
                           rows_text, re.S)
    token_keys = extract(token_rows.group(), known) if token_rows else set()
    providers = {}
    descriptors = {}
    for path in sorted((CORE / "Providers").glob("*/*ProviderDescriptor.swift")):
        source = path.read_text()
        match = re.search(r'\bid:\s*\.([A-Za-z0-9_]+)', source)
        if not match:
            continue
        provider = match.group(1)
        descriptors[provider] = (path, source)
        # Static settings labels also reside in credential/support specs.
        keys = common | file_keys(list(path.parent.glob("*ProviderDescriptor.swift"))
                                  + list(path.parent.glob("*ProviderSettings*.swift")), known)
        if "TokenAccountSupport(" in source:
            keys |= token_keys
        providers[provider] = keys

    for path in sorted((APP / "Providers").glob("*/*ProviderImplementation.swift")):
        source = path.read_text()
        match = re.search(r'let id:\s*UsageProvider\s*=\s*\.([A-Za-z0-9_]+)', source)
        if not match:
            continue
        provider = match.group(1)
        keys = providers.setdefault(provider, set(common))
        keys.update(file_keys(list(path.parent.glob("*.swift"))
                              + list(APP.glob(f"Preferences{path.parent.name}*.swift")), known))
        if "ProviderCookieSourceUI" in source:
            keys.update(file_keys([APP / "Providers/Shared/ProviderCookieSourceUI.swift"], known))
        if "supportsLoginFlow: Bool = true" in source:
            keys.update({"Login", "Account"} & known)

    manifest = (APP / "Providers/Shared/ProviderImplementationManifest.swift").read_text()
    for kind, descriptor in re.findall(r'Plugin(APIKey|Cookie)ProviderImplementation\(spec: (\w+)\.spec\)', manifest):
        for provider, (path, source) in descriptors.items():
            if re.search(r'\benum\s+' + re.escape(descriptor) + r'\b', source):
                keys = providers[provider]
                paths = [APP / f"Providers/Shared/Plugin{kind}ProviderImplementation.swift"]
                if kind == "Cookie":
                    paths.extend([APP / "Providers/Shared/ProviderCookieSourceUI.swift",
                                  APP / "Providers/Shared/PluginCookieProviderImplementation+Profile.swift"])
                keys.update(file_keys(paths, known))
                break

    return json.dumps({"panes": panes, "providers": {key: sorted(value) for key, value in sorted(providers.items())}},
                      ensure_ascii=False, indent=2, sort_keys=True) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    generated = generate()
    if args.check:
        if not OUTPUT.exists() or OUTPUT.read_text() != generated:
            print("Settings search catalog is stale; run Scripts/generate_settings_search_index.py", file=sys.stderr)
            return 1
    else:
        OUTPUT.write_text(generated)
    data = json.loads(generated)
    print(f"Settings search catalog: {len(data['panes'])} panes, {len(data['providers'])} providers")
    return 0


if __name__ == "__main__":
    sys.exit(main())
