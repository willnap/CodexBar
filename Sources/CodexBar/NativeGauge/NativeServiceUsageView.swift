import CodexBarCore
import SwiftUI

struct NativeAccountOption: Identifiable, Equatable {
    let id: String
    let title: String
}

/// Offline preview only; the production popup uses NativeServicePopoverController.
struct NativeUsagePopoverContent: View {
    let model: UsageMenuCardView.Model
    let gauge: ComputeGauge.State
    var accounts: [NativeAccountOption] = []
    var selectedAccountID: String = ""
    var isRefreshing = false
    var canSignIn = false
    var signInTitle = L("Sign In…")
    var hasDashboard = false
    var onSelectAccount: (String) -> Void = { _ in }
    var onRefresh: () -> Void = {}
    var onSignIn: () -> Void = {}
    var onDashboard: () -> Void = {}
    var onSettings: () -> Void = {}
    var onAdvanced: () -> Void = {}
    var onQuit: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TimelineView(.periodic(from: .now, by: 60)) { timeline in
                    ComputeGauge(state: self.gauge, size: 32, now: timeline.date)
                        .environment(\.computeGaugeLayout, .laurel)
                        .frame(
                            width: LaurelGauge.layoutWidth(for: 32, windowCount: self.gauge.resolvedWindows.count),
                            height: LaurelGauge.layoutHeight(for: 32, windowCount: self.gauge.resolvedWindows.count))
                }
                Spacer()
                if self.isRefreshing {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("Refreshing \(self.model.providerName)")
                }
                Button(action: self.onRefresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(self.isRefreshing)
                .help("Refresh \(self.model.providerName)")
                .keyboardShortcut("r", modifiers: .command)
                Menu {
                    Button(L("Settings..."), action: self.onSettings)
                    Button(L("Advanced"), action: self.onAdvanced)
                    Divider()
                    Button(L("Quit CodexBar"), action: self.onQuit)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .help(L("Options"))
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 8)

            if self.accounts.count > 1 {
                Picker(L("Account"), selection: Binding(
                    get: { self.selectedAccountID },
                    set: { self.onSelectAccount($0) }))
                {
                    ForEach(self.accounts) { account in
                        Text(account.title).tag(account.id)
                    }
                }
                .pickerStyle(.menu)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }

            ScrollView {
                UsageMenuCardView(model: self.model, width: 328)
                    .textSelection(.enabled)
                    .padding(.bottom, 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if self.canSignIn || self.hasDashboard {
                Divider()
                HStack {
                    if self.canSignIn {
                        Button(self.signInTitle, action: self.onSignIn)
                    }
                    Spacer()
                    if self.hasDashboard {
                        Button(L("Usage Dashboard"), systemImage: "arrow.up.right", action: self.onDashboard)
                    }
                }
                .controlSize(.small)
                .buttonStyle(.glass)
                .padding(16)
            }
        }
        .frame(width: 360, height: 500)
    }
}
