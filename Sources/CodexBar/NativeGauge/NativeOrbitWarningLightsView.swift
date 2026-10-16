import AppKit
import SwiftUI

/// Startup test lamps keep their catalogue positions as evidence settles; only genuine warnings have hit targets.
struct NativeOrbitWarningLightsView: View {
    let lights: [NativeOrbitWarningLight]
    let lanes: Int
    let isBulbCheck: Bool
    let action: (NativeOrbitWarningLight.Action) -> Void
    /// Center-relative bounds occupied by the monetary reading, when present.
    var reservedBounds: CGRect?
    var reservedRegions: [CGRect] = []
    var accountLabel: String?
    var isInteractive = true
    var startup: NativeOrbitStartupPhase = .live
    var startupCheckpoint = 0
    var startupReadiness: NativeOrbitStartupReadiness = .pending
    @State private var explainedKind: NativeOrbitWarningLight.Kind?
    @State private var keepsStartupPositions = false

    static let amber = Color(red: 1, green: 0.76, blue: 0.16)

    static func spot(_ kind: NativeOrbitWarningLight.Kind, lanes: Int) -> CGPoint {
        NativeOrbitWarningLayout.preferred(kind, lanes: lanes)
    }

    static func size(lanes: Int) -> CGFloat { 13 }

    static var bulbCheck: [NativeOrbitWarningLight] {
        NativeOrbitStartupChecks.catalogue
    }

    var body: some View {
        let phase: NativeOrbitStartupPhase = self.isBulbCheck ? .armed : self.startup
        let real = NativeOrbitWarningLight.reconciled(self.lights)
        let shown = NativeOrbitStartupChecks.shown(
            realLights: real, phase: phase, checkpoint: self.startupCheckpoint, readiness: self.startupReadiness)
        let positions = NativeOrbitWarningLayout.positions(
            for: phase.testsLamps || self.keepsStartupPositions
                ? NativeOrbitWarningLight.Kind.allCases : shown.map(\.kind),
            lanes: self.lanes,
            reservedBounds: self.reservedBounds,
            reservedRegions: self.reservedRegions)
        ZStack {
            if !shown.isEmpty {
                NativeOrbitWarningHDRView(items: shown.compactMap { light in
                    guard let position = positions[light.kind] else { return nil }
                    return NativeOrbitWarningHDRItem(light: light, position: position)
                })
                .frame(width: 216, height: 216)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                if !real.isEmpty {
                    NativeOrbitWarningHitView(
                        lights: real,
                        positions: positions,
                        account: self.accountLabel,
                        allowsActions: self.isInteractive,
                        activate: { light in
                            guard self.isInteractive else { return }
                            if light.action == .details {
                                self.explainedKind = light.kind
                            } else {
                                self.action(light.action ?? light.kind.defaultAction)
                            }
                        })
                        .frame(width: 216, height: 216)
                }
            }
        }
        .frame(width: 216, height: 216)
        .accessibilityElement(children: .contain)
        .popover(
            isPresented: Binding(
                get: { self.explainedKind != nil && self.isInteractive },
                set: { if !$0 { self.explainedKind = nil } }),
            attachmentAnchor: .rect(.rect(self.explainedKind.flatMap { kind in
                positions[kind].map { position in
                    NativeOrbitWarningLayout.inkBounds(kind).offsetBy(dx: 108 + position.x, dy: 108 + position.y)
                }
            } ?? .zero))) {
                if let kind = self.explainedKind, let light = real.first(where: { $0.kind == kind }) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(kind.name).font(.headline)
                        if let accountLabel { Text(accountLabel).font(.caption).foregroundStyle(.secondary) }
                        Text(light.explanation).font(.callout).fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button(L("Refresh")) { self.action(.refresh) }
                            Button(L("Settings")) { self.action(.settings) }
                        }.controlSize(.small)
                    }.padding(14).frame(width: 290, alignment: .leading)
                }
        }
        .onChange(of: real.map(\.kind)) {
            if let explainedKind, !real.contains(where: { $0.kind == explainedKind }) { self.explainedKind = nil }
        }
        .onChange(of: self.isInteractive) { if !self.isInteractive { self.explainedKind = nil } }
        .onAppear { if phase.testsLamps { self.keepsStartupPositions = true } }
        .onChange(of: phase) { if phase.testsLamps { self.keepsStartupPositions = true } }
    }
}

extension NativeOrbitPopupState {
    func runBulbCheck() async {
        self.isBulbCheck = true
        try? await Task.sleep(for: .milliseconds(1100))
        self.isBulbCheck = false
    }
}
