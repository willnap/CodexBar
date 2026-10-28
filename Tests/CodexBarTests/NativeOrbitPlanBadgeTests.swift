import Testing
@testable import CodexBar

struct NativeOrbitPlanBadgeTests {
    @Test func `a usage multiplier is the badge with a proper multiplication sign`() {
        #expect(NativeOrbitPlanBadge.text(plan: "Claude Max 20x", service: "Claude") == "20×")
        #expect(NativeOrbitPlanBadge.text(plan: "Pro 5x", service: "Codex") == "5×")
        #expect(NativeOrbitPlanBadge.text(plan: "Pro 20X", service: "Codex") == "20×")
        #expect(NativeOrbitPlanBadge.text(plan: "Max 1.5×", service: "Claude") == "1.5×")
    }

    @Test func `without a multiplier the badge is the plan name less the service's words`() {
        #expect(NativeOrbitPlanBadge.text(plan: "Claude Pro", service: "Claude") == "Pro")
        #expect(NativeOrbitPlanBadge.text(plan: "Plus", service: "Codex") == "Plus")
        #expect(NativeOrbitPlanBadge.text(plan: "Allegretto", service: "Kimi Code") == "Allegretto")
        #expect(NativeOrbitPlanBadge.text(plan: "Team Plan", service: "Cursor") == "Team")
        // A long name keeps its last, distinguishing word.
        #expect(NativeOrbitPlanBadge.text(plan: "Claude Team Premium", service: "Claude") == "Premium")
    }

    @Test func `no badge without a usable plan`() {
        #expect(NativeOrbitPlanBadge.text(plan: nil, service: "Codex") == nil)
        #expect(NativeOrbitPlanBadge.text(plan: "  ", service: "Codex") == nil)
        #expect(NativeOrbitPlanBadge.text(plan: "Claude", service: "Claude") == nil)
        #expect(NativeOrbitPlanBadge.text(plan: "Extraordinarily", service: "Codex") == nil)
        // "Max" is a word, not a multiplier.
        #expect(NativeOrbitPlanBadge.text(plan: "Claude Max", service: "Claude") == "Max")
    }
}
