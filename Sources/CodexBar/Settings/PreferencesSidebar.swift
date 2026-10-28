import AppKit
import CodexBarCore
import SwiftUI

/// System Settings-style sidebar: fixed app panes on top, one row per provider below.
@MainActor
struct SettingsSidebarView: View {
    @Bindable var settings: SettingsStore
    @Bindable var store: UsageStore
    @Binding var selection: SettingsPane
    var onSelectAbout: () -> Void = {}
    @State private var searchText = ""
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        if #available(macOS 26.0, *) {
            self.content
                .searchable(text: self.$searchText, placement: .sidebar, prompt: L("Search settings"))
                .toolbar {
                    SettingsSidebarSortToolbar(
                        isOn: self.$settings.providersSortedAlphabetically,
                        enabledOnly: self.$settings.providersEnabledOnly,
                        canRestore: self.settings.canRestoreDefaultProviderOrder,
                        onRestore: self.restoreProviderOrder)
                }
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    SettingsSidebarSearchField(searchText: self.$searchText)
                    SettingsSidebarSortToggle(
                        isOn: self.$settings.providersSortedAlphabetically,
                        enabledOnly: self.$settings.providersEnabledOnly,
                        canRestore: self.settings.canRestoreDefaultProviderOrder,
                        onRestore: self.restoreProviderOrder)
                }
                .padding(.horizontal, 8)
                .padding(.top, 16)
                .padding(.bottom, 8)

                self.content
            }
            .padding(.horizontal, 8)
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            List(selection: Binding(self.$selection)) {
                if !self.matchingAppPanes.isEmpty { self.appPanesSection }
                self.providersSection
                if self.isSearching, self.matchingAppPanes.isEmpty, self.filteredProviders.isEmpty {
                    Text(L("No matching settings"))
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            if self.settings.canUndoProviderOrderChange, let undoID = self.settings.providerOrderUndo?.id {
                // A new reorder gets a fresh banner identity, so its fade timer restarts.
                SettingsSidebarProviderOrderBanner {
                    self.settings.undoProviderOrderChange()
                }
                .id(undoID)
            }
        }
    }

    private var appPanesSection: some View {
        Section {
            ForEach(self.matchingAppPanes, id: \.self) { pane in
                SettingsSidebarPaneRow(
                    pane: pane,
                    matchedSetting: self.isSearching ? SettingsSearchIndex.shared.match(
                        pane: pane,
                        query: self.searchText,
                        usesNativeGauges: self.settings.usesNativeGauges,
                        nativeDesignEnabled: self.settings.nativeDesignEnabled) : nil,
                    onSelect: pane == .about ? self.onSelectAbout : nil)
            }
        } header: {
            if self.isSearching { Text(L("Settings")) }
        }
    }

    private var matchingAppPanes: [SettingsPane] {
        let panes: [SettingsPane] = [
            .general, .iCloudSync, .usageSpend, .notifications, .menuBar, .menu, .advanced, .hooks, .plugins, .about,
        ] + (self.settings.debugMenuEnabled ? [.debug] : [])
        return panes.filter { !self.isSearching || SettingsSearchIndex.shared.match(
            pane: $0,
            query: self.searchText,
            usesNativeGauges: self.settings.usesNativeGauges,
            nativeDesignEnabled: self.settings.nativeDesignEnabled) != nil }
    }

    /// Used first groups enabled, then configured, then available services; otherwise one section in custom or
    /// alphabetical order.
    @ViewBuilder
    private var providersSection: some View {
        let providers = self.filteredProviders
        if !providers.isEmpty {
            if self.settings.settingsProvidersUsedFirst {
                let groups = [
                    (L("Enabled services"), providers.filter(self.isEnabled)),
                    (L("Configured services"), providers.filter { !self.isEnabled($0) && self.isConfigured($0) }),
                    (L("Available services"), providers.filter { !self.isEnabled($0) && !self.isConfigured($0) }),
                ].filter { !$0.1.isEmpty }
                ForEach(groups.indices, id: \.self) { index in
                    self.providerSection(groups[index].1, title: groups[index].0, showsOrderControl: index == 0)
                }
            } else {
                self.providerSection(providers, title: L("tab_providers"), showsOrderControl: true)
            }
        } else if !self.isSearching, self.settings.providersEnabledOnly {
            Section {
                Text(L("No matching providers"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(L("Clear filters")) {
                    self.searchText = ""
                    self.settings.providersEnabledOnly = false
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func providerSection(
        _ providers: [UsageProvider], title: String, showsOrderControl: Bool) -> some View
    {
        Section {
            ForEach(providers, id: \.self) { provider in
                SettingsSidebarProviderRow(
                    provider: provider,
                    store: self.store,
                    isEnabled: self.enabledBinding(for: provider),
                    matchedSetting: self.isSearching ? SettingsSearchIndex.shared.match(
                        pane: .provider(provider.instanceID), query: self.searchText) : nil)
                    .tag(SettingsPane.provider(provider.instanceID))
                    .moveDisabled(!self.canReorderProviders)
            }
            .onMove { fromOffsets, toOffset in
                guard self.canReorderProviders else { return }
                if self.settings.moveVisibleProviders(
                    providers.map(\.instanceID), fromOffsets: fromOffsets, toOffset: toOffset)
                {
                    self.settings.registerProviderOrderUndo(in: self.undoManager)
                }
            }
        } header: {
            if showsOrderControl {
                HStack(spacing: 4) {
                    Text(L("tab_providers"))
                    Spacer(minLength: 4)
                    Text(String(format: L("providers_on_count"), self.enabledProviderCount))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                    SettingsSidebarUsedFirstToggle(isOn: self.$settings.settingsProvidersUsedFirst)
                }
            } else {
                Text(title)
            }
        }
    }

    private var isSearching: Bool {
        !self.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func restoreProviderOrder() {
        if self.settings.restoreDefaultProviderOrder() { self.settings.registerProviderOrderUndo(in: self.undoManager) }
    }

    private var orderedProviders: [UsageProvider] {
        guard self.settings.providersSortedAlphabetically else {
            return ProviderSettingsOrdering.prioritized(
                self.settings.orderedProviders().compactMap(\.firstPartyProvider),
                enabled: self.isEnabled,
                configured: self.isConfigured,
                usedFirst: self.settings.settingsProvidersUsedFirst)
        }
        return CodexBarConfig.alphabeticalProviderOrder(enablement: self.isEnabled)
    }

    private var filteredProviders: [UsageProvider] {
        let providers = self.orderedProviders.filter { !self.settings.providersEnabledOnly || self.isEnabled($0) }
        guard self.isSearching else { return providers }
        if SettingsSearchIndex.matches(
            query: self.searchText,
            text: "\(L("Providers")) \(L("Used providers first"))")
        {
            return providers
        }
        return providers.filter { provider in
            let name = self.store.metadata(for: provider).displayName
            let account = self.store.settingsAccountLabel(for: provider) ?? ""
            return SettingsSearchIndex.matches(
                query: self.searchText,
                text: [name, provider.rawValue, account, SettingsSearchIndex.shared.providerSearchText(for: provider)]
                    .joined(separator: " "))
        }
    }

    private var enabledProviderCount: Int {
        self.orderedProviders.count(where: self.isEnabled)
    }

    private func isEnabled(_ provider: UsageProvider) -> Bool {
        self.settings.isProviderEnabled(provider: provider, metadata: self.store.metadata(for: provider))
    }

    private func isConfigured(_ provider: UsageProvider) -> Bool {
        !self.settings.tokenAccounts(for: provider).isEmpty || self.store.snapshot(for: provider.instanceID) != nil
    }

    private var canReorderProviders: Bool {
        !self.isSearching && !self.settings.providersSortedAlphabetically && !self.settings.providersEnabledOnly
    }

    private func enabledBinding(for provider: UsageProvider) -> Binding<Bool> {
        let meta = self.store.metadata(for: provider)
        return Binding(
            get: { self.settings.isProviderEnabled(provider: provider, metadata: meta) },
            set: { newValue in
                self.settings.setProviderEnabled(provider: provider, metadata: meta, enabled: newValue)
            })
    }
}

@MainActor
private struct SettingsSidebarPaneRow: View {
    let pane: SettingsPane
    let matchedSetting: String?
    /// The About row also answers a click while selected: list selection ignores it, and it returns a pushed
    /// subpage to About.
    var onSelect: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            if self.pane == .about, let icon = NSApplication.shared.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: SettingsIconChip.side, height: SettingsIconChip.side)
                    .accessibilityHidden(true)
            } else {
                SettingsIconChip(systemImage: self.icon.name, color: self.icon.color)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(self.pane.title)
                if let matchedSetting = self.matchedSetting, matchedSetting != self.pane.title {
                    Text(matchedSetting)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { self.onSelect?() })
        .tag(self.pane)
    }

    private var icon: (name: String, color: Color) {
        switch self.pane {
        case .general: ("gearshape.fill", .gray)
        case .iCloudSync: ("icloud.fill", .blue)
        case .usageSpend: ("chart.xyaxis.line", .green)
        case .notifications: ("bell.badge.fill", .red)
        case .menuBar: ("menubar.rectangle", .blue)
        case .menu: ("filemenu.and.selection", .teal)
        case .advanced: ("slider.horizontal.3", .purple)
        case .hooks: ("bolt.fill", .orange)
        case .plugins: ("puzzlepiece.extension.fill", .indigo)
        case .about: ("info.circle.fill", .green)
        case .debug: ("ladybug.fill", .red)
        case .provider: ("square.stack.fill", .gray)
        }
    }
}

@MainActor
struct SettingsSidebarProviderRow: View {
    let provider: UsageProvider
    @Bindable var store: UsageStore
    @Binding var isEnabled: Bool
    var matchedSetting: String?

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if NativeGaugeConfiguration.isEnabled {
                    NativeProviderSymbolView(provider: self.provider, size: 18)
                } else if let brand = ProviderBrandIcon.image(for: self.provider) {
                    Image(nsImage: brand)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: "circle.dotted")
                        .resizable()
                        .scaledToFit()
                }
            }
            .frame(width: 18, height: 18)
            .foregroundStyle(self.isEnabled ? .primary : .secondary)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(self.store.metadata(for: self.provider).displayName)
                    .foregroundStyle(self.isEnabled ? .primary : .secondary)
                if let matchedSetting = self.matchedSetting,
                   matchedSetting != self.store.metadata(for: self.provider).displayName
                {
                    Text(matchedSetting)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let account = self.accountLabel {
                    Text(account)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 4)

            if self.store.refreshingProviders.contains(self.provider.instanceID) {
                ProgressView()
                    .controlSize(.mini)
            }

            if self.isEnabled, self.store.statusChecksEnabled {
                Circle()
                    .fill(Self.statusColor(for: self.store.status(for: self.provider)?.indicator))
                    .frame(width: 6, height: 6)
                    .help(Self.statusDescription(for: self.store.status(for: self.provider)?.indicator))
                    .accessibilityHidden(true)
            }
        }
        .opacity(self.isEnabled ? 1 : 0.62)
        .contextMenu {
            Button(self.isEnabled ? L("Disable") : L("Enable")) {
                self.isEnabled.toggle()
            }
        }
        .accessibilityLabel(self.accessibilityLabel)
        .accessibilityValue(self.accountLabel ?? "")
    }

    private var accountLabel: String? {
        guard self.isEnabled, self.store.settings.usesNativeGauges,
              !self.store.settings.hidePersonalInfo else { return nil }
        return self.store.settingsAccountLabel(for: self.provider)
    }

    private var accessibilityLabel: String {
        Self.accessibilityLabel(
            name: self.store.metadata(for: self.provider).displayName,
            isEnabled: self.isEnabled,
            statusChecksEnabled: self.store.statusChecksEnabled,
            indicator: self.store.status(for: self.provider)?.indicator)
    }

    nonisolated static func accessibilityLabel(
        name: String,
        isEnabled: Bool,
        statusChecksEnabled: Bool,
        indicator: ProviderStatusIndicator?) -> String
    {
        guard isEnabled else { return "\(name) — \(L("Disabled"))" }
        guard statusChecksEnabled else { return name }
        return "\(name) — \(self.statusDescription(for: indicator))"
    }

    nonisolated static func statusDescription(for indicator: ProviderStatusIndicator?) -> String {
        L("Provider service status: %@", (indicator ?? .unknown).label)
    }

    nonisolated static func statusColor(for indicator: ProviderStatusIndicator?) -> Color {
        switch indicator ?? .unknown {
        case .none: .green
        case .minor: .yellow
        case .major: .orange
        case .critical: .red
        case .maintenance, .unknown: .gray
        }
    }
}

private struct SettingsSidebarProviderOrderBanner: View {
    private enum AccessibilityElement: Hashable {
        case banner
        case message
        case undo
    }

    static let visibleDuration: Duration = .seconds(4)

    let onUndo: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = true
    @State private var isHovering = false
    @FocusState private var isUndoFocused: Bool
    @AccessibilityFocusState private var accessibilityFocus: AccessibilityElement?

    private var isInteracting: Bool {
        self.isHovering || self.isUndoFocused || self.accessibilityFocus != nil
    }

    var body: some View {
        ZStack {
            if self.isVisible {
                HStack {
                    Text(L("Provider order updated"))
                        .accessibilityFocused(self.$accessibilityFocus, equals: .message)
                    Spacer(minLength: 4)
                    Button(L("Undo"), action: self.onUndo)
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        .focused(self.$isUndoFocused)
                        .accessibilityFocused(self.$accessibilityFocus, equals: .undo)
                }
                .font(.caption)
                .padding(8)
                .contentShape(Rectangle())
                .onHover { self.isHovering = $0 }
                .accessibilityElement(children: .contain)
                .accessibilityFocused(self.$accessibilityFocus, equals: .banner)
                .transition(.opacity)
            }
        }
        .task(id: self.isInteracting) {
            guard !self.isInteracting else { return }
            try? await Task.sleep(for: Self.visibleDuration)
            guard !Task.isCancelled, !self.isInteracting else { return }
            withAnimation(self.reduceMotion ? nil : .easeOut(duration: 0.4)) { self.isVisible = false }
        }
    }
}

private struct SettingsSidebarSearchField: View {
    @Binding var searchText: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField(L("Search settings"), text: self.$searchText)
                .textFieldStyle(.plain)
                .accessibilityLabel(L("Search settings"))
                .onExitCommand { self.searchText = "" }

            if !self.searchText.isEmpty {
                Button {
                    self.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(L("Clear"))
                }
                .buttonStyle(.plain)
            }
        }
        .font(.callout)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.6)))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1))
    }
}

private struct SettingsSidebarUsedFirstToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            self.isOn.toggle()
        } label: {
            Image(systemName: "arrow.up.to.line")
                .font(.callout)
                .foregroundStyle(self.isOn ? Color.accentColor : Color.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("Used providers first"))
        .accessibilityLabel(L("Used providers first"))
        .accessibilityValue(self.isOn ? L("On") : L("Off"))
        .accessibilityAddTraits(self.isOn ? .isSelected : [])
    }
}

/// macOS 26+ sidebar toolbar group: a standard toolbar toggle (which shows its own on state) and a
/// sorting menu, so the toolbar supplies their shared Liquid Glass.
private struct SettingsSidebarSortToolbar: ToolbarContent {
    @Binding var isOn: Bool
    @Binding var enabledOnly: Bool
    let canRestore: Bool
    let onRestore: () -> Void

    var body: some ToolbarContent {
        ToolbarItemGroup {
            Toggle(isOn: self.$isOn) {
                Label(L("Sort providers alphabetically"), systemImage: "arrow.up.arrow.down")
            }
            .help(self.isOn
                ? L("Sorted alphabetically (enabled first) — click to use your custom order")
                : L("Sort providers alphabetically (enabled first)"))

            Menu {
                Toggle(L("Only show enabled providers"), isOn: self.$enabledOnly)
                Divider()
                Button(L("Restore default order"), action: self.onRestore)
                    .disabled(!self.canRestore)
                    .help(L("Also restores the provider order in the menu bar. Can be undone."))
            } label: {
                Label(L("Provider sorting"), systemImage: "chevron.down")
            }
            .menuIndicator(.hidden)
            .help(L("Provider sorting"))
        }
    }
}

private struct SettingsSidebarSortToggle: View {
    @Binding var isOn: Bool
    @Binding var enabledOnly: Bool
    let canRestore: Bool
    let onRestore: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button {
                self.isOn.toggle()
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.callout)
                    .foregroundStyle(self.isOn ? Color.accentColor : Color.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(self.isOn
                ? L("Sorted alphabetically (enabled first) — click to use your custom order")
                : L("Sort providers alphabetically (enabled first)"))
            .accessibilityLabel(L("Sort providers alphabetically"))
            .accessibilityAddTraits(self.isOn ? .isSelected : [])

            Menu {
                Toggle(L("Only show enabled providers"), isOn: self.$enabledOnly)
                Divider()
                Button(L("Restore default order"), action: self.onRestore)
                    .disabled(!self.canRestore)
                    .help(L("Also restores the provider order in the menu bar. Can be undone."))
            } label: {
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(self.enabledOnly ? Color.accentColor : Color.secondary)
                    .frame(width: 14, height: 24)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L("Provider sorting"))
            .accessibilityLabel(L("Provider sorting"))
        }
    }
}
