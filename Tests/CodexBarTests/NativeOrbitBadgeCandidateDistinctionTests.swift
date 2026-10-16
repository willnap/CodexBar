import Testing
@testable import CodexBar

@MainActor
struct NativeOrbitBadgeCandidateDistinctionTests {
    @Test func aSharedProfessionalRoleIsRemovedBeforeTheModelChooses() {
        let account = NativeOrbitBadgeModel.Account(id: "a", text: "Photographer — ocean")
        let keys = NativeOrbitBadgeModel.candidateKeys(
            for: account,
            peers: ["Photographer — mountains"],
            source: account.text,
            query: "Photographer — ocean; photography; photographer; pictures; portraits")
        #expect(!keys.contains("photo"))
    }

    @Test func aUniqueSubjectStillOffersItsNaturalIcon() {
        let account = NativeOrbitBadgeModel.Account(id: "a", text: "Portrait photography")
        #expect(NativeOrbitBadgeModel.candidateKeys(
            for: account,
            peers: ["Bicycle repairs"],
            source: account.text,
            query: "portrait photography").contains("photo"))
    }
}
