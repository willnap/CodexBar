import Foundation
import Testing
@testable import CodexBar

@MainActor
struct NativeOrbitBadgeAliasTests {
    /// The actual account adapter must retain word boundaries encoded by mailbox capitalization.
    @Test func actualModelAccountsPreserveCamelCaseMailboxAlias() throws {
        let contexts = NativeOrbitBadgeResolver.modelAccounts([
            Self.account("camel", label: "Main", email: "PotteryLessons@gmail.com"),
            Self.account("peer", label: "Reading", email: "books@icloud.com"),
        ])
        let account = try #require(contexts.first { $0.id == "camel" })
        #expect(account.alias == "PotteryLessons")
        #expect(account.text.contains("PotteryLessons"))
        #expect(NativeOrbitBadgeModel.selectedSource("alias", label: account.label, alias: account.alias)
            == "Pottery Lessons")
        #expect(!account.alias.contains("@"))
        #expect(!account.text.contains("gmail.com"))
    }

    /// Anonymous account slots cannot expose either the case-preserved alias or a provider clue.
    @Test func anonymousAccountsKeepOriginalCaseAliasesPrivate() throws {
        let contexts = NativeOrbitBadgeResolver.modelAccounts([
            Self.account("private", label: "Account 1", email: "SecretSwimming@gmail.com"),
            Self.account("peer", label: "Reading", email: "books@icloud.com"),
        ])
        let account = try #require(contexts.first { $0.id == "private" })
        #expect(account.alias.isEmpty)
        #expect(account.text.isEmpty)
        #expect(account.label.isEmpty)
        #expect(account.brand == nil)
    }

    /// Preserved case cannot evade the existing model-boundary character or byte budgets.
    @Test func originalCaseAliasRemainsBoundedWithoutAnEmailDomain() throws {
        let local = String(repeating: "PotteryLessons", count: 100)
        let account = try #require(NativeOrbitBadgeResolver.modelAccounts([
            Self.account("long", label: "Main", email: local + "@gmail.com"),
            Self.account("peer", label: "Reading", email: "books@icloud.com"),
        ]).first { $0.id == "long" })
        #expect(account.alias.hasPrefix("PotteryLessons"))
        #expect(account.alias.count <= 96)
        #expect(account.alias.utf8.count <= 256)
        #expect(account.text.count <= 193)
        #expect(account.text.utf8.count <= 513)
        #expect(!account.alias.contains("@"))
        #expect(!account.text.contains("gmail.com"))
    }

    @Test func fullDisplayLabelCannotTruncateIndependentlyBoundedAlias() throws {
        let label = "Workspace " + String(repeating: "9", count: 86)
        let account = try #require(NativeOrbitBadgeResolver.modelAccounts([
            Self.account("long-label", label: label, email: "CeramicsWorkshop@gmail.com"),
            Self.account("peer", label: "Reading", email: "books@icloud.com"),
        ]).first { $0.id == "long-label" })
        #expect(account.label == label)
        #expect(account.alias == "CeramicsWorkshop")
        #expect(account.text.contains("CeramicsWorkshop"))
    }

    private static func account(_ id: String, label: String, email: String) -> NativeOrbitAccountPresentation {
        .init(
            id: id,
            label: label,
            email: email,
            symbol: "gearshape",
            isActive: false,
            canActivate: false,
            gauge: ComputeGauge.State(),
            updatedAt: nil,
            history: [],
            odometer: nil,
            odometerHelp: nil,
            statusText: nil,
            selection: .none)
    }
}
