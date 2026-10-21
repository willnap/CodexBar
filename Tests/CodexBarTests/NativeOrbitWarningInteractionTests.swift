import AppKit
import Testing
@testable import CodexBar

@MainActor
struct NativeOrbitWarningInteractionTests {
    @Test func `detail tooltips explain the condition without a redundant explain action`() {
        let light = NativeOrbitWarningLight(.behindPace, .opportunity, "Weekly usage is below pace.")
        #expect(!light.tooltip(account: "Work").contains("Explain"))
        #expect(light.tooltip(account: "Work") == "On pace to have allowance left over.")
        #expect(light.tooltip(account: "Work", includesAction: false) == light.tooltip(account: nil))
    }

    @Test func `every catalogue light has a useful click destination`() {
        for kind in NativeOrbitWarningLight.Kind.allCases {
            let light = NativeOrbitWarningLight(kind, .caution, kind.name)
            #expect(light.action != nil, "Missing action: \(kind.catalogueKey)")
        }
    }

    @Test func `shared provider wording never makes different lights have the same tooltip`() {
        let tooltips = NativeOrbitWarningLight.Kind.allCases.map {
            NativeOrbitWarningLight($0, .caution, "The provider returned the same message.")
                .tooltip(account: "Demo account")
        }
        #expect(Set(tooltips).count == 51)
        #expect(tooltips.allSatisfy { !$0.contains("\n") && !$0.contains("—") && $0.count <= 60 })
        #expect(tooltips.allSatisfy { !$0.contains("Demo account") && !$0.contains("provider returned") })
    }

    @Test func `raw diagnostics cannot replace concise warning copy`() {
        let raw = String(repeating: "Backend detail — ", count: 30) + "\nInternal diagnostics."
        for kind in NativeOrbitWarningLight.Kind.allCases {
            let light = NativeOrbitWarningLight(kind, .critical, raw)
            #expect(light.tooltip(account: "Work") == kind.explanation)
            #expect(light.explanation == kind.explanation)
            #expect(light.detail == raw)
        }
    }

    @Test func `curated specifics survive projection without diagnostic text or a caption`() {
        let light = NativeOrbitWarningLight(
            .limit, .caution, "Projected: internal detail", tooltipDetail: "Weekly limit may run out in 2 hours.")
        #expect(light.tooltip(account: "Work") == "Weekly limit may run out in 2 hours.")
    }

    @Test func `the all light proof explains each condition rather than repeating its name`() {
        let lights = NativeOrbitWarningLightsView.bulbCheck
        #expect(Set(lights.map(\.detail)).count == 51)
        for light in lights {
            #expect(light.detail != light.kind.name, "Unexplained light: \(light.kind.catalogueKey)")
        }
    }

    @Test func `a current equally severe explanation replaces the stale one`() {
        let lights = NativeOrbitWarningLight.merged([
            .init(.oldReading, .caution, "Showing the 9 AM reading."),
            .init(.oldReading, .caution, "Showing the 10 AM reading."),
        ])
        #expect(lights.first?.detail == "Showing the 10 AM reading.")
    }

    @Test func `missing external destinations fall back to a real account action`() {
        let service = NativeOrbitWarningLight(.overloaded, .caution, "Servers are busy.")
        #expect(service.resolvingAction(hasStatusPage: false, hasDashboard: true, canSignIn: true).action == .dashboard)
        #expect(service.resolvingAction(hasStatusPage: false, hasDashboard: false, canSignIn: true).action == .settings)
        #expect(service.resolvingAction(hasStatusPage: true, hasDashboard: true, canSignIn: true).action == .statusPage)
        let login = NativeOrbitWarningLight(.signIn, .critical, "This login expired.")
        let accountSettings = login.resolvingAction(hasStatusPage: true, hasDashboard: true, canSignIn: false)
        #expect(accountSettings.action == .settings)
        #expect(accountSettings.tooltip(account: "Second account") == "Sign in again.")
        let helperUpdate = NativeOrbitWarningLight(.update, .caution, "Update the CLI.", action: .settings)
        #expect(helperUpdate.resolvingAction(hasStatusPage: true, hasDashboard: true, canSignIn: true)
            .action == .settings)
    }

    @Test func `every native target has its own tooltip and click at all three sizes`() throws {
        let lights = NativeOrbitWarningLightsView.bulbCheck
        for lanes in 1...3 {
            var pressed: [NativeOrbitWarningLight.Kind] = []
            let surface = NativeOrbitWarningHitSurface(frame: .init(x: 0, y: 0, width: 216, height: 216))
            surface.update(
                lights: lights,
                positions: NativeOrbitWarningLayout.positions(for: lights.map(\.kind), lanes: lanes),
                account: "Demo account") { pressed.append($0.kind) }
            #expect(surface.buttons.count == 51)
            for light in lights {
                let button = try #require(surface.buttons[light.kind])
                #expect(button.accessibilityRole() == .button)
                let centre = CGPoint(x: button.frame.midX, y: button.frame.midY)
                #expect(button.toolTip == nil)
                #expect(surface.tooltip(at: centre) == light.tooltip(account: "Demo account"))
                #expect(surface.view(surface, stringForToolTip: 0, point: centre, userData: nil)
                    == light.tooltip(account: "Demo account"))
                #expect(
                    surface.button(at: CGPoint(x: button.frame.midX, y: button.frame.midY)) === button,
                    "Wrong target: \(light.kind.catalogueKey), \(lanes) rings")
                button.performClick(nil)
            }
            #expect(Set(pressed) == Set(lights.map(\.kind)))
        }
    }

    @Test func `native hover and click read the updated condition without repeating account names`() throws {
        let surface = NativeOrbitWarningHitSurface(frame: .init(x: 0, y: 0, width: 216, height: 216))
        var pressed: NativeOrbitWarningLight?
        surface.update(
            lights: [.init(.spend, .caution, "$9 of $10 spent.", tooltipDetail: "$9 of $10 spent.")],
            positions: [.spend: .zero],
            account: "First account") { pressed = $0 }
        let original = try #require(surface.buttons[.spend])
        surface.update(
            lights: [.init(.spend, .critical, "$10 of $10 spent.", tooltipDetail: "$10 of $10 spent.")],
            positions: [.spend: CGPoint(x: 12, y: -8)],
            account: "Second account") { pressed = $0 }
        #expect(surface.buttons[.spend] === original)
        let updatedTooltip = surface.tooltip(at: CGPoint(x: original.frame.midX, y: original.frame.midY))
        #expect(updatedTooltip == "$10 of $10 spent.")
        #expect(updatedTooltip?.contains("$10 of $10 spent.") == true)
        #expect(updatedTooltip?.contains("First account") == false)
        original.performClick(nil)
        #expect(pressed?.severity == .critical)
        #expect(pressed?.detail == "$10 of $10 spent.")
        surface.update(lights: [], positions: [:], account: nil) { pressed = $0 }
        #expect(surface.buttons.isEmpty)
        pressed = nil
        original.performClick(nil)
        #expect(pressed == nil)
        surface.update(
            lights: [.init(.spend, .caution, "New episode.")],
            positions: [.spend: .zero],
            account: "Third account") { pressed = $0 }
        original.performClick(nil)
        #expect(pressed == nil)
        let current = try #require(surface.buttons[.spend])
        surface.update(
            lights: [.init(.spend, .caution, "No position.")],
            positions: [:],
            account: "Third account") { pressed = $0 }
        current.performClick(nil)
        #expect(pressed == nil)
    }

    @Test func `inspection keeps current tooltips while disabling real account actions`() throws {
        let surface = NativeOrbitWarningHitSurface(frame: .init(x: 0, y: 0, width: 216, height: 216))
        var pressed = false
        surface.update(
            lights: [.init(.credits, .critical, "Historical zero balance.", tooltipDetail: "Historical zero balance.")],
            positions: [.credits: .zero],
            account: "Work",
            allowsActions: false) { _ in pressed = true }
        let button = try #require(surface.buttons[.credits])
        #expect(surface.tooltip(at: CGPoint(x: button.frame.midX, y: button.frame.midY))?
            .contains("Historical zero balance.") == true)
        button.performClick(nil)
        #expect(!pressed)
    }

    @Test func `dismantling a native surface retires every retained control and callback`() throws {
        let surface = NativeOrbitWarningHitSurface(frame: .init(x: 0, y: 0, width: 216, height: 216))
        var pressed = false
        surface.update(
            lights: [.init(.limit, .critical, "Used up.")],
            positions: [.limit: .zero],
            account: "Old account") { _ in pressed = true }
        let retained = try #require(surface.buttons[.limit])
        NativeOrbitWarningHitView.dismantleNSView(surface, coordinator: ())
        retained.performClick(nil)
        #expect(!pressed)
        #expect(surface.buttons.isEmpty)
        #expect(surface.tooltip(at: CGPoint(x: 108, y: 108)) == nil)
    }

    @Test func `native hit areas follow their parent coordinate system and leave empty space alone`() throws {
        let parent = NSView(frame: .init(x: 0, y: 0, width: 300, height: 300))
        let surface = NativeOrbitWarningHitSurface(frame: .init(x: 30, y: 40, width: 216, height: 216))
        parent.addSubview(surface)
        surface.update(
            lights: [.init(.credits, .critical, "No credits remain.")],
            positions: [.credits: .zero],
            account: "Demo") { _ in }
        let button = try #require(surface.buttons[.credits])
        let centre = surface.convert(CGPoint(x: button.frame.midX, y: button.frame.midY), to: parent)
        #expect(surface.hitTest(centre) === button)
        #expect(surface.hitTest(surface.convert(CGPoint(x: 4, y: 4), to: parent)) == nil)
    }
}
