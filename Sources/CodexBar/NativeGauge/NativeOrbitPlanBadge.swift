import SwiftUI

/// The plan's differentiator in white type on a small rounded square of the service's colour, the way
/// `20.square.fill` carries its number: "20×", "5×", "Pro", "Plus". The colour darkens only as far as the type needs to
/// read, so the badge belongs to its page's ring and capsule.
struct NativeOrbitPlanBadge: View {
    @Environment(\.colorScheme) private var colorScheme
    let text: String
    let plan: String
    let accent: Color

    /// Words that name the plan's kind rather than which plan it is.
    private nonisolated static let generic: Set<String> = ["plan", "subscription", "tier", "membership"]
    private nonisolated static let longest = 10

    /// A usage multiplier says the most ("Claude Max 20x" → "20×"); otherwise the plan's name without the service's
    /// own words ("Claude Pro" → "Pro"), or its last word when the name is long ("Claude Team Premium" → "Premium").
    nonisolated static func text(plan: String?, service: String) -> String? {
        guard let plan = plan?.trimmingCharacters(in: .whitespacesAndNewlines), !plan.isEmpty else { return nil }
        if let match = plan.firstMatch(of: /(\d+(?:\.\d+)?)\s*[xX×](?![A-Za-z])/) {
            return "\(match.1)×"
        }
        let service = Set(service.lowercased().split(whereSeparator: \.isWhitespace).map(String.init))
        let words = plan.split(whereSeparator: \.isWhitespace).map(String.init).filter {
            let word = $0.lowercased()
            return !service.contains(word) && !Self.generic.contains(word)
        }
        let name = words.joined(separator: " ")
        if !name.isEmpty, name.count <= Self.longest { return name }
        return words.last.flatMap { $0.count <= Self.longest ? $0 : nil }
    }

    var body: some View {
        // About 4 pt of colour around the ink on every side: the figures' cap height sits centred in the line.
        Text(verbatim: self.text)
            .font(.system(size: 9.5, weight: .bold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 4)
            .padding(.vertical, 1.5)
            .frame(minWidth: 15)
            // The badge keeps its size in a crowded footer; the name beside it shortens instead.
            .fixedSize()
            .background(
                NativeOrbitContrast.fill(underWhiteText: self.accent, for: self.colorScheme),
                in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .help(self.plan)
            .accessibilityElement()
            .accessibilityLabel(self.plan)
    }
}
