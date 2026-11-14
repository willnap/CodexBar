import AppKit
import CodexBarCore
import SwiftUI

/// Claude's saved accounts, kept by claude-swap.
struct ClaudeAccountsSectionState: Equatable {
    struct Row: Equatable, Identifiable {
        let id: ProviderAccountIdentity
        let slot: Int
        let name: String
        /// The saved address, for signing in again; nil when Hide Personal Info is on.
        let email: String?
        let isActive: Bool
        let canActivate: Bool
        let needsSignIn: Bool
    }

    let rows: [Row]
    let isSwitching: Bool
    let claudeSwapInstalled: Bool
    let isIntegrationOn: Bool
    /// tcr pools accounts behind a proxy and has no saved logins to add, rename or remove.
    let canManageAccounts: Bool

    @MainActor
    static func make(store: UsageStore, settings: SettingsStore) -> ClaudeAccountsSectionState {
        _ = store.claudeSwapRevision
        let canManage = settings.claudeSwapSource == .claudeSwap
        let accounts = settings.claudeSwapEnabled && canManage
            ? store.claudeSwapAccountSnapshots.filter {
                $0.provider == .claude && $0.id.source == ClaudeSwapAccountProjection.sourceName
            }
            : []
        let rows = accounts.compactMap { account -> Row? in
            guard let slot = Int(account.id.opaqueID) else { return nil }
            let email = account.accountEmail
            let label = ClaudeSwapAccountMenuDisplay.label(for: account, hidePersonalInfo: settings.hidePersonalInfo)
            return Row(
                id: account.id,
                slot: slot,
                name: label,
                email: settings.hidePersonalInfo ? nil : email,
                isActive: account.isActive,
                canActivate: account.canActivate,
                needsSignIn: account.credentialIssue == .signIn)
        }
        return ClaudeAccountsSectionState(
            rows: rows,
            isSwitching: store.claudeSwapTransientState.switchingAccountID != nil,
            claudeSwapInstalled: ClaudeSwapSetup.executablePath(configured: settings.claudeSwapExecutablePath) != nil,
            isIntegrationOn: settings.claudeSwapEnabled,
            canManageAccounts: canManage)
    }
}

@MainActor
struct ClaudeAccountsSectionView: View {
    let state: ClaudeAccountsSectionState
    let store: UsageStore
    let settings: SettingsStore

    @State private var renaming: ClaudeAccountsSectionState.Row?
    @State private var newName = ""
    @State private var removing: ClaudeAccountsSectionState.Row?
    @State private var busySlot: Int?
    @State private var failure: String?

    var body: some View {
        Section {
            if !self.state.canManageAccounts {
                EmptyView()
            } else if self.state.rows.isEmpty {
                if self.state.isIntegrationOn || !self.state.claudeSwapInstalled {
                    Text(self.state.claudeSwapInstalled
                        ? L("claude_accounts_empty")
                        : L("claude_add_account_needs_claude_swap"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(self.state.rows) { row in
                        self.rowView(row)
                    }
                }
            }

            if let failure {
                Text(failure)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if self.state.canManageAccounts {
                self.addAccountRow
            }
        } header: {
            Text(L("Accounts"))
        }
        .alert(
            L("claude_accounts_rename_title"),
            isPresented: Binding(get: { self.renaming != nil }, set: { if !$0 { self.renaming = nil } }),
            presenting: self.renaming)
        { row in
            TextField(L("claude_accounts_rename_placeholder"), text: self.$newName)
            Button(L("claude_accounts_rename_save")) { self.rename(row, to: self.newName) }
            Button(L("cancel"), role: .cancel) {}
        } message: { _ in
            Text(L("claude_accounts_rename_message"))
        }
        .alert(
                self.removing.map { L("claude_accounts_remove_title", $0.name) } ?? "",
                isPresented: Binding(get: { self.removing != nil }, set: { if !$0 { self.removing = nil } }),
                presenting: self.removing)
        { row in
            Button(L("claude_accounts_remove"), role: .destructive) { self.remove(row) }
            Button(L("cancel"), role: .cancel) {}
            } message: { _ in
                Text(L("claude_accounts_remove_message"))
            }
    }

    private func rowView(_ row: ClaudeAccountsSectionState.Row) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if row.needsSignIn {
                    Text(L("claude_accounts_needs_sign_in"))
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 8)
            if self.busySlot == row.slot {
                ProgressView().controlSize(.small)
            } else if row.isActive {
                Image(systemName: "checkmark")
                    .foregroundStyle(Color.accentColor)
                    .help(L("claude_accounts_in_use"))
                    .accessibilityLabel(L("claude_accounts_in_use"))
            } else if row.needsSignIn, let email = row.email {
                Button(L("claude_accounts_sign_in_again")) { self.signInAgain(email: email) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else {
                Button(L("claude_accounts_use")) {
                    self.failure = nil
                    self.store.switchClaudeSwapAccount(row.id)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!row.canActivate || self.state.isSwitching)
            }
            Menu {
                if let email = row.email {
                    Button(L("claude_accounts_sign_in_again")) { self.signInAgain(email: email) }
                }
                Button(L("claude_accounts_rename")) {
                    self.newName = ""
                    self.renaming = row
                }
                Divider()
                Button(L("claude_accounts_remove_menu"), role: .destructive) { self.removing = row }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(L("claude_accounts_more"))
            .disabled(self.busySlot != nil)
        }
    }

    // MARK: Adding

    private var flow: ClaudeAddAccountFlow {
        ClaudeAddAccountFlow.shared(store: self.store, settings: self.settings)
    }

    /// Add Account opens the browser at once; what happens next is reported here, in place of the button.
    @ViewBuilder
    private var addAccountRow: some View {
        let flow = self.flow
        switch flow.phase {
        case .signingIn:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L("claude_add_account_waiting"))
                    .font(.subheadline)
                Spacer(minLength: 8)
                if let link = flow.link {
                    Button(L("claude_add_account_copy_link")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(link, forType: .string)
                    }
                    .controlSize(.small)
                    .help(L("claude_add_account_other_browser"))
                }
                Button(L("cancel")) { flow.cancel() }
                    .controlSize(.small)
            }
        case .installing, .saving:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(flow.phase == .installing ? L("claude_add_account_installing") : L("claude_add_account_saving"))
                    .font(.subheadline)
            }
        case .ready, .added, .failed:
            if case let .added(result) = flow.phase {
                Text(result.wasAlreadyAdded
                    ? L("claude_add_account_renewed", result.email)
                    : L("claude_add_account_added", result.email))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if case let .failed(reason) = flow.phase {
                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if flow.claudeSwapPath == nil {
                self.installRow(flow)
            } else {
                Button(L("claude_accounts_add")) { flow.signIn() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private func installRow(_ flow: ClaudeAddAccountFlow) -> some View {
        if let installer = flow.installer {
            Button(L("claude_add_account_install")) { flow.install() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(installer.commandLine)
        } else {
            HStack(spacing: 8) {
                Text(L("claude_add_account_install_manually"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(L("claude_add_account_check_again")) { flow.checkForClaudeSwap() }
                    .controlSize(.small)
            }
        }
    }

    // MARK: Actions

    private func signInAgain(email: String) {
        self.flow.signIn(email: email)
    }

    private func rename(_ row: ClaudeAccountsSectionState.Row, to name: String) {
        self.perform(row) {
            try await ClaudeSwapAccountManager.setAlias(
                executablePath: self.settings.claudeSwapExecutablePath,
                slot: row.slot,
                alias: name)
        }
    }

    private func remove(_ row: ClaudeAccountsSectionState.Row) {
        self.perform(row) {
            try await ClaudeSwapAccountManager.removeAccount(
                executablePath: self.settings.claudeSwapExecutablePath,
                slot: row.slot)
        }
    }

    private func perform(_ row: ClaudeAccountsSectionState.Row, _ operation: @escaping () async throws -> Void) {
        self.failure = nil
        self.busySlot = row.slot
        Task { @MainActor in
            do {
                try await operation()
            } catch {
                self.failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            await self.store.refreshClaudeSwapAccounts()
            self.busySlot = nil
        }
    }
}
