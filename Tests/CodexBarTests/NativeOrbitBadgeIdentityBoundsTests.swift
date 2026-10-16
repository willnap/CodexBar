import Testing
@testable import CodexBar

@Suite(.serialized)
@MainActor
struct NativeOrbitBadgeIdentityBoundsTests {
    @Test("literal fallback labels are bounded before email stripping")
    func literalFallbackLabelIsBounded() {
        let value = NativeOrbitBadgeIdentity(id: "long", label: String(repeating: "z", count: 2000), email: nil)
        #expect(value.literalLabel.count <= 96)
        #expect(value.literalLabel.utf8.count <= 256)
    }

    @Test("a large combining grapheme cannot enter fallback email matching")
    func combiningFallbackLabelIsBounded() {
        let value = NativeOrbitBadgeIdentity(
            id: "combining", label: "e" + String(repeating: "\u{0301}", count: 400), email: nil)
        #expect(value.literalLabel.utf8.count <= 256)
    }

    @Test("account identity uses the displayed label line rather than hidden trailing lines")
    func identityUsesFirstDisplayLine() {
        let value = NativeOrbitBadgeIdentity(
            id: "line", label: "Project Meridian\nUnexpected trailing metadata", email: nil)
        #expect(value.literalLabel == "Project Meridian")
    }

    @Test("mailbox locals are bounded before initials processing")
    func mailboxLocalIsBounded() {
        let value = NativeOrbitBadgeIdentity(
            id: "local", label: "Primary", email: String(repeating: "M", count: 2000) + "@sample.example")
        #expect(value.local.count <= 96)
        #expect(value.local.utf8.count <= 256)
        #expect(value.originalLocal.count <= 96)
        #expect(value.originalLocal.utf8.count <= 256)
    }

    @Test("an oversized mailbox grapheme cannot enter fallback normalization")
    func combiningMailboxLocalIsBounded() {
        let value = NativeOrbitBadgeIdentity(
            id: "local-combining",
            label: "Primary",
            email: "e" + String(repeating: "\u{0301}", count: 400) + "@sample.example")
        #expect(value.local.utf8.count <= 256)
        #expect(value.originalLocal.utf8.count <= 256)
    }

    @Test("bounded fallback labels still remove email domains")
    func fallbackLabelStripsEmailDomain() {
        let value = NativeOrbitBadgeIdentity(
            id: "mail",
            label: "Maya <maya@sample.example>",
            email: "maya@sample.example")
        #expect(value.literalLabel == "Maya <maya>")
    }
}
