import Foundation
import Testing
@testable import CodexBar

@MainActor
struct NativeOrbitBadgeTests {
    @Test func `initial badges describe contrasting email domains`() {
        let accounts = [Self.account("a", email: "test@gmail.com"), Self.account("b", email: "test@icloud.com")]
        let badges = NativeOrbitBadgeResolver.initialBadges(accounts)
        #expect(badges["a"] == "envelope")
        #expect(badges["b"] == "icloud")
    }

    @Test func `numbered aliases get their actual number before inference`() {
        let accounts = [Self.account("a", email: "test+2@gmail.com"), Self.account("b", email: "test+1@gmail.com")]
        let badges = NativeOrbitBadgeResolver.initialBadges(accounts)
        #expect(badges["a"] == "2.square")
        #expect(badges["b"] == "1.square")
    }

    @Test func `account order does not change comparison identity or badges`() {
        let accounts = [Self.account("a", email: "a@example.com"), Self.account("b", email: "b@example.com")]
        #expect(NativeOrbitBadgeResolver.identityKey(accounts)
            == NativeOrbitBadgeResolver.identityKey(accounts.reversed()))
        #expect(NativeOrbitBadgeResolver.initialBadges(accounts)
            == NativeOrbitBadgeResolver.initialBadges(accounts.reversed()))
    }

    @Test func `reopening retains resolved badges instead of replacing them with a random symbol`() async {
        let state = NativeOrbitPopupState()
        state.accounts = [Self.account("a", email: "test@gmail.com"), Self.account("b", email: "test@icloud.com")]
        await NativeOrbitBadgeResolver.resolve(state)
        let resolved = state.badges
        state.accounts.reverse()
        #expect(NativeOrbitBadgeResolver.initialBadges(state.accounts) == resolved)
        await NativeOrbitBadgeResolver.resolve(state)
        #expect(state.badges == resolved)
    }

    @Test func `anonymous labels never expose email attributes through fallback badges`() {
        let accounts = [
            Self.account("a", email: "test@gmail.com", label: "Account 1"),
            Self.account("b", email: "test@icloud.com", label: "Account 2"),
        ]
        let badges = NativeOrbitBadgeResolver.initialBadges(accounts)
        #expect(badges["a"] == "1.square")
        #expect(badges["b"] == "2.square")
    }

    private static func account(_ id: String, email: String, label: String? = nil) -> NativeOrbitAccountPresentation {
        NativeOrbitAccountPresentation(
            id: id,
            label: label ?? email,
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
