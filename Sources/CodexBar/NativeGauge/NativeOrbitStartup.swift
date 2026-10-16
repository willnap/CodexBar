import Foundation
import SwiftUI

/// Presentation only: a sweep never replaces a provider reading, tooltip, or accessible value.
enum NativeOrbitStartupPhase: Equatable, Sendable {
    case live, armed, sweeping, settling, reduced

    var isActive: Bool {
        self != .live
    }

    var testsLamps: Bool {
        self == .armed || self == .sweeping || self == .settling
    }

    var readingsReveal: Double {
        self == .armed || self == .reduced ? 0 : 1
    }

    var graphReveal: Double {
        self.readingsReveal
    }

    func fraction(_ actual: Double?) -> Double {
        switch self {
        case .armed: return 0
        case .sweeping: return 1
        case .live, .settling, .reduced:
            guard let actual, actual.isFinite else { return 0 }
            return min(1, max(0, actual))
        }
    }
}

/// Reveal/layout can synthesize hover callbacks over a stationary cursor. Only a changed global pointer position
/// represents a new hover interaction that may interrupt an armed startup.
struct NativeOrbitStartupHoverPolicy {
    let armedPosition: CGPoint

    func acceptsHover(at actualPosition: CGPoint) -> Bool {
        actualPosition != self.armedPosition
    }
}

/// A missing owner during refresh is not an account change. Replay only after another owner is confirmed.
struct NativeOrbitStartupSelection {
    private var activeID: String?

    mutating func receive(activeID: String?) -> Bool {
        guard let activeID else { return false }
        let changed = self.activeID != nil && self.activeID != activeID
        self.activeID = activeID
        return changed
    }
}

/// Reserving an opening does not consume it; only an actually shown popup does.
@MainActor
final class NativeOrbitStartupLaunch {
    static let shared = NativeOrbitStartupLaunch()
    private(set) var hasShown = false
    private var reservedBy: UUID?

    func reserve(_ owner: UUID) -> Bool {
        guard !self.hasShown, self.reservedBy == nil || self.reservedBy == owner else { return false }
        self.reservedBy = owner
        return true
    }

    func shown(_ owner: UUID) -> Bool {
        guard !self.hasShown, self.reservedBy == owner else { return false }
        self.hasShown = true
        self.reservedBy = nil
        return true
    }

    func cancel(_ owner: UUID) {
        if self.reservedBy == owner { self.reservedBy = nil }
    }
}

/// Animate the already prepared artwork, not the data or the expensive chart render key.
struct NativeOrbitStartupReveal: ViewModifier {
    let progress: Double

    func body(content: Content) -> some View {
        content
            .opacity(self.progress)
            .offset(y: 3 * (1 - self.progress))
    }
}
