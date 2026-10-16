import Foundation
import Testing
@testable import CodexBar

@MainActor
struct NativeOrbitBadgePolicyReviewTests {
    /// The first frame is also the lasting result when the model is unavailable.
    @Test
    func provisionalBadgesDoNotInferInterestsFromPersonalNames() {
        let accounts = [
            Self.account("review-robin", label: "Robin Avery", email: "review.robin@gmail.com"),
            Self.account("review-selene", label: "Selene Blake", email: "review.selene@gmail.com"),
        ]

        let badges = NativeOrbitBadgeResolver.initialBadges(accounts)

        #expect(badges["review-robin"] == "r.square.fill")
        #expect(badges["review-selene"] == "s.square.fill")
    }

    /// Account followed by a descriptive word is not the same as Account followed by an ID.
    @Test(arguments: ["Account security", "Account photography"])
    func descriptiveAccountLabelsKeepTheirPurpose(label: String) {
        #expect(NativeOrbitBadgeModel.purposeLabel(label) == label)
    }

    /// Common authentication subjects contain digits without being opaque identifiers.
    @Test(arguments: ["2FA", "OAuth2"])
    func meaningfulAlphanumericTechnologyLabelsSurvive(label: String) {
        #expect(NativeOrbitBadgeModel.purposeLabel(label) == label)
    }

    /// Narrowing the identifier parser must retain its actual anonymity boundary.
    @Test(arguments: ["Account Q", "014", "R9"])
    func opaqueIdentifierControlsStayEmpty(label: String) {
        #expect(NativeOrbitBadgeModel.purposeLabel(label).isEmpty)
    }

    /// Different source languages must not make one shared interpreted purpose distinctive.
    @Test
    func actualMergerRejectsSharedInterpretedPurpose() {
        let accounts = [
            Self.account("review-fr", label: "Frais de scolarité", email: "fees.first@gmail.com"),
            Self.account("review-en", label: "Tuition payments", email: "fees.second@gmail.com"),
        ]
        let badges = NativeOrbitBadgeResolver.mergedBadges(
            [
                .init(
                    accountID: "review-fr",
                    key: "wallet",
                    symbol: "wallet.bifold.fill",
                    evidence: "Frais de scolarité",
                    searchQuery: "payments"),
            ],
            for: accounts,
            purposes: ["review-fr": "tuition payments", "review-en": "tuition payments"])

        #expect(badges.count == 2)
        #expect(!badges.values.contains("wallet.bifold.fill"))
    }

    /// Duplicate assignments are local failures, not grounds to discard a valid peer.
    @Test
    func actualMergerPreservesPeerWhenAnotherAccountHasDuplicateProposals() {
        let accounts = [
            Self.account("review-orders", label: "Purchasing", email: "orders@gmail.com"),
            Self.account("review-photo", label: "Portrait photography", email: "portrait@gmail.com"),
        ]
        let duplicate = NativeOrbitBadgeModel.Proposal(
            accountID: "review-orders",
            key: "shopping",
            symbol: "cart.fill",
            evidence: "Purchasing",
            searchQuery: "purchases")
        let badges = NativeOrbitBadgeResolver.mergedBadges(
            [
                duplicate,
                duplicate,
                .init(
                    accountID: "review-photo",
                    key: "photo",
                    symbol: "camera.fill",
                    evidence: "Portrait photography",
                    searchQuery: "photography"),
            ],
            for: accounts,
            purposes: ["review-orders": "purchases", "review-photo": "photography"])

        #expect(badges.count == 2)
        #expect(badges["review-photo"] == "camera.fill")
        #expect(badges["review-orders"] != "cart.fill")
    }

    /// Exercise source ownership through the live merger, rather than the legacy validator.
    @Test
    func actualMergerRejectsEvidenceBorrowedFromPeer() {
        let accounts = [
            Self.account("review-photo", label: "Portrait photography", email: "portrait@gmail.com"),
            Self.account("review-bike", label: "Bicycle maintenance", email: "bicycle@gmail.com"),
        ]
        let badges = NativeOrbitBadgeResolver.mergedBadges(
            [
                .init(
                    accountID: "review-photo",
                    key: "photo",
                    symbol: "camera.fill",
                    evidence: "Bicycle maintenance",
                    searchQuery: "photography"),
                .init(
                    accountID: "review-bike",
                    key: "native:bicycle",
                    symbol: "bicycle",
                    evidence: "Bicycle maintenance",
                    searchQuery: "bicycle"),
            ],
            for: accounts,
            purposes: ["review-photo": "photography", "review-bike": "bicycle"])

        #expect(badges.count == 2)
        #expect(badges["review-photo"] != "camera.fill")
        #expect(badges["review-bike"] == "bicycle")
    }

    /// A valid logo key cannot borrow the provenance of a different account's domain.
    @Test
    func actualMergerRejectsProviderWithForeignDomainEvidence() {
        let accounts = [
            Self.account("review-mail", label: "Reading", email: "reading@gmail.com"),
            Self.account("review-run", label: "Running", email: "running@icloud.com"),
        ]
        let badges = NativeOrbitBadgeResolver.mergedBadges(
            [
                .init(
                    accountID: "review-mail",
                    key: "gmail",
                    symbol: "account.mail.gmail",
                    evidence: "icloud.com"),
                .init(
                    accountID: "review-run",
                    key: "native:figure.run",
                    symbol: "figure.run",
                    evidence: "Running",
                    searchQuery: "running"),
            ],
            for: accounts,
            purposes: ["review-mail": "reading", "review-run": "running"])

        #expect(badges.count == 2)
        #expect(badges["review-mail"] != "account.mail.gmail")
        #expect(badges["review-run"] == "figure.run")
    }

    @Test
    func actualMergerPreservesDistinctRolesWithinSharedSubject() {
        let accounts = [
            Self.account("role-work", label: "Work records", email: "work.records@gmail.com"),
            Self.account("role-personal", label: "Personal records", email: "personal.records@gmail.com"),
        ]
        let badges = NativeOrbitBadgeResolver.mergedBadges(
            [
                .init(
                    accountID: "role-work",
                    key: "work",
                    symbol: "briefcase.fill",
                    evidence: "Work records",
                    searchQuery: "Work records"),
            ],
            for: accounts,
            purposes: ["role-work": "Work records", "role-personal": "Personal records"])
        #expect(badges["role-work"] == "briefcase.fill")
    }

    private static func account(_ id: String, label: String, email: String) -> NativeOrbitAccountPresentation {
        NativeOrbitAccountPresentation(
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
