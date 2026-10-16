import Testing
@testable import CodexBar

struct NativeOrbitPeerWarningTests {
    @Test func `one exhausted account does not add a redundant fleet warning`() {
        let account = NativeOrbitPeerWarningSignals.Account(
            id: "a", provider: "claude", label: "A", isActive: true, limits: ["weekly": 1])
        #expect(NativeOrbitPeerWarningSignals.lights(for: account, peers: [account]).isEmpty)
    }

    @Test func `all exhausted requires every account of that provider to have a known exhausted quota`() {
        let a = NativeOrbitPeerWarningSignals.Account(
            id: "a", provider: "claude", label: "A", isActive: true, limits: ["weekly": 1])
        let b = NativeOrbitPeerWarningSignals.Account(
            id: "b", provider: "claude", label: "B", isActive: false, limits: ["weekly": 1])
        #expect(NativeOrbitPeerWarningSignals.lights(for: a, peers: [a, b]).contains { $0.kind == .allExhausted })
        let unknown = NativeOrbitPeerWarningSignals.Account(
            id: "b", provider: "claude", label: "B", isActive: false, limits: [:])
        #expect(!NativeOrbitPeerWarningSignals.lights(for: a, peers: [a, unknown])
            .contains { $0.kind == .allExhausted })
    }

    @Test func `switching advice requires room in the same limit and never another provider`() {
        let a = NativeOrbitPeerWarningSignals.Account(
            id: "a", provider: "claude", label: "A", isActive: true, limits: ["weekly": 0.95])
        let otherProvider = NativeOrbitPeerWarningSignals.Account(
            id: "b", provider: "codex", label: "B", isActive: false, limits: ["weekly": 0.1])
        #expect(NativeOrbitPeerWarningSignals.lights(for: a, peers: [a, otherProvider]).isEmpty)
        let wrongLimit = NativeOrbitPeerWarningSignals.Account(
            id: "b", provider: "claude", label: "B", isActive: false, limits: ["session": 0.1])
        #expect(NativeOrbitPeerWarningSignals.lights(for: a, peers: [a, wrongLimit]).isEmpty)
        let room = NativeOrbitPeerWarningSignals.Account(
            id: "b", provider: "claude", label: "B", isActive: false, limits: ["weekly": 0.1])
        #expect(NativeOrbitPeerWarningSignals.lights(for: a, peers: [a, room]).map(\.kind) == [.switching])
        let blocked = NativeOrbitPeerWarningSignals.Account(
            id: "b", provider: "claude", label: "B", isActive: false, limits: ["weekly": 0.1, "session": 1])
        #expect(NativeOrbitPeerWarningSignals.lights(for: a, peers: [a, blocked]).isEmpty)
    }
}
