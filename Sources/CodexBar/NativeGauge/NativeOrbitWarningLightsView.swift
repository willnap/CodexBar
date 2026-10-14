import AppKit
import SwiftUI

/// The dial's warning lights, set around the marks in its middle as a car's dashboard sets them around its centre
/// display: each has its own spot, six down each side, and nothing shows there while it is off.
struct NativeOrbitWarningLightsView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let lights: [NativeOrbitWarningLight]
    /// The dial's ring count, which sets how much room its middle has.
    let lanes: Int
    let isBulbCheck: Bool
    let action: (NativeOrbitWarningLight.Action) -> Void

    static let perSide = 6

    /// A dashboard's amber, yellower than the system orange so it stays distinct from an orange provider accent.
    static let amber = Color(nsColor: NSColor(name: "NativeOrbitWarningAmber") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 1.0, green: 0.76, blue: 0.16, alpha: 1)
            : NSColor(srgbRed: 0.91, green: 0.62, blue: 0.0, alpha: 1)
    })

    /// A light's spot from the dial's centre: down the left of the marks for the first six kinds, down the right for
    /// the rest, on an arc clear of the marks and inside the innermost ring.
    static func spot(_ kind: NativeOrbitWarningLight.Kind, lanes: Int) -> CGPoint {
        let radius: CGFloat = switch lanes {
        case 3: 29.5
        case 2: 42
        default: 52
        }
        let row = kind.rawValue % Self.perSide
        // From 36° to 144° off vertical: the ends stay clear of the parent mark above and the account badge below.
        let angle = (36 + 21.6 * Double(row)) * .pi / 180
        let side: CGFloat = kind.rawValue < Self.perSide ? -1 : 1
        return CGPoint(x: side * radius * CGFloat(sin(angle)), y: -radius * CGFloat(cos(angle)))
    }

    static func size(lanes: Int) -> CGFloat {
        switch lanes {
        case 3: 9
        case 2: 12
        default: 13
        }
    }

    /// Every light at once: the bulb check after launch shows each lamp works.
    static var bulbCheck: [NativeOrbitWarningLight] {
        NativeOrbitWarningLight.Kind.allCases.map { .init($0, $0.canBeCritical ? .critical : .caution, $0.name) }
    }

    var body: some View {
        let shown = self.isBulbCheck ? Self.bulbCheck : self.lights
        ZStack {
            ForEach(shown) { light in
                let spot = Self.spot(light.kind, lanes: self.lanes)
                self.lamp(light, interactive: !self.isBulbCheck)
                    .offset(x: spot.x, y: spot.y)
                    // The system's symbol appear; without an animation (bulb check, Reduce Motion) lamps just switch.
                    .transition(.symbolEffect(.appear.byLayer, options: .nonRepeating))
            }
        }
        .animation(self.reduceMotion || self.isBulbCheck ? nil : .smooth(duration: 0.3), value: shown.map(\.kind))
        .animation(self.reduceMotion || self.isBulbCheck ? nil : .smooth(duration: 0.3), value: shown.map(\.severity))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func lamp(_ light: NativeOrbitWarningLight, interactive: Bool) -> some View {
        let color = light.severity == .critical ? Color.red : Self.amber
        let size = Self.size(lanes: self.lanes)
        let face = Image(systemName: light.kind.symbol)
            .font(.system(size: size, weight: .semibold))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(color)
            // A lit lamp's glow.
            .shadow(color: color.opacity(0.55), radius: 2.5)
            .frame(width: size + 8, height: size + 8)
            .contentShape(Rectangle())
        Group {
            if interactive, let action = light.action {
                Button { self.action(action) } label: { face }
                    .buttonStyle(.plain)
            } else {
                face
            }
        }
        .help(light.detail)
        .allowsHitTesting(interactive)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(light.kind.name)
        .accessibilityValue(light.detail)
        .accessibilityAddTraits(light.action == nil ? [] : .isButton)
    }
}

extension NativeOrbitPopupState {
    /// Lights every warning light for a moment, then hands the dials back to their own lights.
    func runBulbCheck() async {
        self.isBulbCheck = true
        try? await Task.sleep(for: .milliseconds(1100))
        self.isBulbCheck = false
    }
}
