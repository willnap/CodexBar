import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct NativeAccountActivationTests {
    @Test func `Codex default and explicit file stores support activation`() {
        for config in [
            "",
            "model = 'gpt-5'",
            "cli_auth_credentials_store = \"file\" # local",
            "'cli_auth_credentials_store' = 'file'",
        ] {
            #expect(NativeCodexActivationCapability.unavailabilityReason(config: config, environment: [:]) == nil)
        }
    }

    @Test func `Codex nonfile and ambiguous stores fail closed`() {
        for config in [
            "cli_auth_credentials_store = 'keyring'",
            "cli_auth_credentials_store = 'auto'",
            "cli_auth_credentials_store = 'ephemeral'",
            "cli_auth_credentials_store = 'unknown'",
            "cli_auth_credentials_store = file",
            "cli_auth_credentials_store = 'file'\ncli_auth_credentials_store = 'keyring'",
            "\"cli_auth_credentia\\u006cs_store\" = 'keyring'",
            "cli_auth_credentials_store = '''file'''",
            "profile = 'work'",
            "model_provider = 'custom'",
            "[profiles.work]\ncli_auth_credentials_store = 'auto'",
        ] {
            #expect(NativeCodexActivationCapability.unavailabilityReason(config: config, environment: [:]) != nil)
        }
    }

    @Test func `unrelated multiline Codex configuration preserves file activation capability`() {
        let config = #"""
        developer_instructions = """
        Example instructions contain # comments and bracket [characters].
        cli_auth_credentials_store = 'keyring'
        """
        instructions = '''
        Literal text can mention cli_auth_credentials_store = "auto".
        '''
        cli_auth_credentials_store = "file"
        [mcp_servers.fixture]
        args = [
          "--first", # comment with unmatched [ quote '
          "value with # and ]",
        ]
        """#
        #expect(NativeCodexActivationCapability.unavailabilityReason(config: config, environment: [:]) == nil)
        #expect(NativeCodexActivationCapability.unavailabilityReason(
            config: config + "\ncli_auth_credentials_store = 'keyring'", environment: [:]) != nil)
    }

    @Test func `unterminated multiline Codex values cannot hide an auth override`() {
        for config in [
            "instructions = '''\nunterminated\ncli_auth_credentials_store = 'file'",
            "args = [\n'fixture'\ncli_auth_credentials_store = 'file'",
            "args = [}\ncli_auth_credentials_store = 'file'",
        ] {
            #expect(NativeCodexActivationCapability.unavailabilityReason(config: config, environment: [:]) != nil)
        }
    }

    @Test func `Codex auth environment overrides prevent misleading file activation`() {
        for key in ["OPENAI_API_KEY", "CODEX_API_KEY", "OPENAI_BASE_URL", "CODEX_PROFILE"] {
            #expect(NativeCodexActivationCapability.unavailabilityReason(
                config: "", environment: [key: "fixture"]) != nil)
        }
        #expect(NativeCodexActivationCapability.unavailabilityReason(
            config: "", environment: ["OPENAI_API_KEY": "  "]) == nil)
    }

    @Test func `injected config read failures do not become default file capability`() {
        let reason = NativeCodexActivationCapability.unavailabilityReason(environment: [:]) { _ in
            throw CocoaError(.fileReadNoPermission)
        }
        #expect(reason != nil)
        #expect(NativeCodexActivationCapability.unavailabilityReason(environment: [:]) { _ in nil } == nil)
    }

    @Test func `Codex verification requires one matching actual live owner`() {
        let storedID = UUID()
        let target = self.codexAccount(storedID: storedID, workspace: "workspace-a", live: false)
        let live = self.codexAccount(storedID: storedID, workspace: "workspace-a", live: true)
        let projection = { (accounts: [CodexVisibleAccount]) in
            CodexVisibleAccountProjection(
                visibleAccounts: accounts,
                activeVisibleAccountID: live.id,
                liveVisibleAccountID: live.id,
                hasUnreadableAddedAccountStore: false)
        }
        #expect(NativeAccountActivationVerification.codexOwnsLogin(target, projection: projection([live])))
        #expect(!NativeAccountActivationVerification.codexOwnsLogin(target, projection: projection([target])))
        #expect(!NativeAccountActivationVerification.codexOwnsLogin(target, projection: projection([live, live])))
        let foreign = self.codexAccount(storedID: storedID, workspace: "workspace-b", live: true)
        #expect(!NativeAccountActivationVerification.codexOwnsLogin(target, projection: projection([foreign])))
        let replacement = self.codexAccount(storedID: UUID(), workspace: "workspace-a", live: true)
        #expect(!NativeAccountActivationVerification.codexOwnsLogin(target, projection: projection([replacement])))
    }

    @Test func `Claude verification rejects stale duplicate foreign and repairing owners`() {
        let target = ProviderAccountIdentity(source: "claude-swap", opaqueID: "2")
        let active = self.snapshot(target, active: true)
        #expect(NativeAccountActivationVerification.claudeOwnsLogin(target, accounts: [active]))
        #expect(!NativeAccountActivationVerification.claudeOwnsLogin(target, accounts: [active, active]))
        #expect(!NativeAccountActivationVerification.claudeOwnsLogin(target, accounts: [
            active, self.snapshot(.init(source: "claude-swap", opaqueID: "1"), active: true),
        ]))
        #expect(!NativeAccountActivationVerification.claudeOwnsLogin(target, accounts: [
            self.snapshot(target, active: true, canActivate: true),
        ]))
        #expect(!NativeAccountActivationVerification.claudeOwnsLogin(target, accounts: [
            self.snapshot(target, active: true, provider: .codex),
        ]))
        #expect(!NativeAccountActivationVerification.claudeOwnsLogin(target, accounts: [
            self.snapshot(target, active: false),
        ]))
    }

    @Test func `Claude environment overrides cannot claim the saved login is active`() {
        #expect(NativeAccountActivationVerification.claudeEnvironmentAllowsActivation([:]))
        for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CONFIG_DIR"] {
            #expect(!NativeAccountActivationVerification.claudeEnvironmentAllowsActivation([key: "fixture"]))
        }
    }

    @Test func `automatic Claude candidates require stable owner IDs absent from schema v1`() {
        for status in [
            ClaudeSwapUsageStatus.ok,
            .foreignCredential,
            .apiKey,
            .unavailable,
            .tokenExpired,
            .noCredentials,
        ] {
            for disabled in [false, true] {
                let row = ClaudeSwapAccountRow(
                    number: 2,
                    email: "fixture@example.com",
                    isActive: false,
                    usageStatus: status,
                    fiveHour: nil,
                    sevenDay: nil,
                    isDisabled: disabled)
                let accounts = ClaudeSwapAccountProjection.accountSnapshots(from: .init(
                    activeAccountNumber: nil, accounts: [row]))
                #expect(accounts.first?.autoSwitchEligible == false)
                let readOnly = ClaudeSwapAccountProjection.accountSnapshots(from: .init(
                    activeAccountNumber: nil, accounts: [row], supportsAccountSwitching: false))
                #expect(readOnly.first?.autoSwitchEligible == false)
            }
        }
    }

    @Test func `manual Claude selection detects slot replacement even when its numeric ID stays unchanged`() {
        let slot = ProviderAccountIdentity(source: "claude-swap", opaqueID: "2")
        let requested = self.snapshot(slot, active: false)
        let activated = self.snapshot(slot, active: true)
        #expect(NativeAccountActivationVerification.claudeSelectionStillMatches(requested, accounts: [activated]))
        for replacement in [
            self.snapshot(slot, active: false, email: "replacement@example.com"),
            self.snapshot(slot, active: true, organization: "Different workspace"),
            self.snapshot(slot, active: true, label: "Replacement alias"),
            self.snapshot(slot, active: true, email: nil),
            self.snapshot(slot, active: true, organization: nil),
        ] {
            #expect(!NativeAccountActivationVerification.claudeSelectionStillMatches(
                requested, accounts: [replacement]))
        }
        #expect(!NativeAccountActivationVerification.claudeSelectionStillMatches(
            requested, accounts: [activated, activated]))
        #expect(!NativeAccountActivationVerification.claudeSelectionStillMatches(
            self.snapshot(slot, active: false, email: nil), accounts: [activated]))
    }

    private func snapshot(
        _ id: ProviderAccountIdentity,
        active: Bool,
        canActivate: Bool = false,
        provider: UsageProvider = .claude,
        email: String? = "fixture@example.com",
        organization: String? = "Fixture workspace",
        label: String = "Fixture") -> ProviderAccountUsageSnapshot
    {
        ProviderAccountUsageSnapshot(
            id: id,
            provider: provider,
            displayLabel: label,
            accountEmail: email,
            accountOrganizationName: organization,
            isActive: active,
            canActivate: canActivate,
            snapshot: nil,
            error: nil,
            sourceLabel: "fixture")
    }

    private func codexAccount(storedID: UUID, workspace: String, live: Bool) -> CodexVisibleAccount {
        CodexVisibleAccount(
            id: "fixture-account",
            email: "fixture@example.com",
            workspaceAccountID: workspace,
            storedAccountID: storedID,
            selectionSource: live ? .liveSystem : .managedAccount(id: storedID),
            isActive: live,
            isLive: live,
            canReauthenticate: true,
            canRemove: true)
    }
}
