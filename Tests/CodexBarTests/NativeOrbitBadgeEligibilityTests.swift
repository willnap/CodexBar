import Testing
@testable import CodexBar

@MainActor
struct NativeOrbitBadgeEligibilityTests {
    @Test func ordinaryBoundedAccountsRemainEligible() {
        #expect(NativeOrbitBadgeResolver.modelEligible([
            Self.account("a", label: "Reading"),
            Self.account("b", label: "Gardening"),
        ]))
    }

    @Test(arguments: [String(repeating: "界", count: 2000), "a" + String(repeating: "\u{301}", count: 5000)])
    func oversizedUTF8LabelsNeverStartModelInference(_ label: String) {
        #expect(!NativeOrbitBadgeResolver.modelEligible([
            Self.account("a", label: label),
            Self.account("b", label: "Reading"),
        ]))
    }

    @Test func oversizedMailboxNeverStartsModelInference() {
        #expect(!NativeOrbitBadgeResolver.modelEligible([
            Self.account("a", label: "Main", email: String(repeating: "x", count: 2048) + "@gmail.com"),
            Self.account("b", label: "Reading"),
        ]))
    }

    @Test func countIdentityAndPrivacyBoundariesRemainIntact() {
        #expect(!NativeOrbitBadgeResolver.modelEligible((1...25).map { Self.account("a\($0)", label: "Reading") }))
        #expect(!NativeOrbitBadgeResolver.modelEligible([
            Self.account("a", label: "Reading"),
            Self.account("a", label: "Gardening"),
        ]))
        #expect(!NativeOrbitBadgeResolver.modelEligible([
            Self.account("a", label: "Account 1"),
            Self.account("b", label: "Account 2"),
        ]))
        #expect(NativeOrbitBadgeResolver.modelEligible([
            Self.account("a", label: "Account 1"),
            Self.account("b", label: "Reading"),
        ]))
    }

    private static func account(_ id: String, label: String, email: String = "") -> NativeOrbitAccountPresentation {
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
