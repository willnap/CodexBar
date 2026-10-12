import AppKit
import CodexBarCore
import SwiftUI

/// System Settings-style sidebar: fixed app panes on top, one row per provider below.
@MainActor
struct SettingsSidebarView: View {
    @Bindable var settings: SettingsStore
    @Bindable var store: UsageStore
    @Binding var selection: SettingsPane
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            SettingsSidebarSearchField(searchText: self.$searchText)
                .padding(.horizontal, 8)
                .padding(.top, 16)
                .padding(.bottom, 8)

            List(selection: self.selectionBinding) {
                if !self.matchingAppPanes.isEmpty { self.appPanesSection }
                self.providersSection
                if self.isSearching, self.matchingAppPanes.isEmpty, self.filteredProviders.isEmpty {
                    Text(L("No matching settings"))
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .padding(.horizontal, 8)
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
                        nativeDesignEnabled: self.settings.nativeDesignEnabled) : nil)
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
                self.providerSection(providers, title: L("Providers"), showsOrderControl: true)
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
                self.settings.setProviderOrder(ProviderSettingsOrdering.reordered(
                    self.settings.orderedProviders(),
                    visible: providers.map(\.instanceID),
                    fromOffsets: fromOffsets,
                    toOffset: toOffset))
            }
        } header: {
            if showsOrderControl {
                HStack {
                    Text(L("Providers"))
                    Spacer(minLength: 4)
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

    private var selectionBinding: Binding<SettingsPane?> {
        Binding(
            get: { self.selection },
            set: { newValue in
                if let newValue {
                    self.selection = newValue
                }
            })
    }

    private var orderedProviders: [UsageProvider] {
        ProviderSettingsOrdering.prioritized(
            self.settings.orderedProviders().compactMap(\.firstPartyProvider),
            enabled: self.isEnabled,
            configured: self.isConfigured,
            usedFirst: self.settings.settingsProvidersUsedFirst)
    }

    private var filteredProviders: [UsageProvider] {
        guard self.isSearching else { return self.orderedProviders }
        if SettingsSearchIndex.matches(
            query: self.searchText,
            text: "\(L("Providers")) \(L("Used providers first"))")
        {
            return self.orderedProviders
        }
        return self.orderedProviders.filter { provider in
            let name = self.store.metadata(for: provider).displayName
            let account = self.store.settingsAccountLabel(for: provider) ?? ""
            return SettingsSearchIndex.matches(
                query: self.searchText,
                text: [name, provider.rawValue, account, SettingsSearchIndex.shared.providerSearchText(for: provider)]
                    .joined(separator: " "))
        }
    }

    private func isEnabled(_ provider: UsageProvider) -> Bool {
        self.settings.isProviderEnabled(provider: provider, metadata: self.store.metadata(for: provider))
    }

    private func isConfigured(_ provider: UsageProvider) -> Bool {
        !self.settings.tokenAccounts(for: provider).isEmpty || self.store.snapshot(for: provider.instanceID) != nil
    }

    private var canReorderProviders: Bool {
        !self.isSearching
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
