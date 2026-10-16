import SwiftUI

/// Complications retain their ordinary behavior unless a shared surface separates ink from native targets.
enum NativeOrbitInstrumentRole {
    case all, ink, targets
}

extension EnvironmentValues {
    @Entry var nativeOrbitInstrumentRole = NativeOrbitInstrumentRole.all
}

/// The target role never evaluates the ink closure, including text layout and symbol artwork construction.
struct NativeOrbitInstrumentElement<Ink: View>: View {
    @Environment(\.nativeOrbitInstrumentRole) private var role
    let corner: NativeOrbitComplication.Corner
    let help: String
    @ViewBuilder var ink: () -> Ink

    var body: some View {
        switch self.role {
        case .ink:
            self.ink()
        case .all:
            self.ink().modifier(NativeOrbitInstrumentTarget(corner: self.corner, help: self.help))
        case .targets:
            Color.clear.frame(width: 224, height: 224)
                .modifier(NativeOrbitInstrumentTarget(corner: self.corner, help: self.help))
        }
    }
}

private struct NativeOrbitInstrumentTarget: ViewModifier {
    let corner: NativeOrbitComplication.Corner
    let help: String

    func body(content: Content) -> some View {
        content
            .contentShape(NativeOrbitCornerRegion(corner: self.corner))
            .help(self.help)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(self.help)
    }
}

/// One asynchronously rendered symbol contains only instrument ink; native hover/accessibility stay outside it.
struct NativeOrbitInstrumentSurface<Content: View>: View {
    private let content: Content
    private let outset: CGFloat = 48

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ZStack {
            Canvas(rendersAsynchronously: true) { context, size in
                if let symbol = context.resolveSymbol(id: 0) {
                    context.draw(symbol, at: CGPoint(x: size.width / 2, y: size.height / 2))
                }
            } symbols: {
                self.content
                    .environment(\.nativeOrbitInstrumentRole, .ink)
                    .frame(width: 224, height: 224)
                    .padding(self.outset)
                    .tag(0)
            }
            .frame(width: 224 + 2 * self.outset, height: 224 + 2 * self.outset)
            .padding(-self.outset)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            self.content.environment(\.nativeOrbitInstrumentRole, .targets)
        }
        .frame(width: 224, height: 224)
    }
}
