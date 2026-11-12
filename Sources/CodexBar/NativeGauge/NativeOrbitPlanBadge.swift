import CodexBarCore
import SwiftUI

/// What the plan costs a month cut out of a small rounded square, the way `20.square.fill` carries its number:
/// "$200", "£200". Plans are renamed and their allowances restated; the price is the figure that stays comparable.
/// Without a reported price it is the plan's differentiator as before: "20×", "Pro", "Plus". The square is the grey of
/// the account name beside it, as that name looks: a solid shape in
/// the name's own colour reads darker than its thin strokes, whose rendered ink averages about three quarters of
/// that colour's contrast, so the square is that much lighter.
struct NativeOrbitPlanBadge: View {
    let text: String
    let plan: String

    /// The account name's colour (`secondary` at 0.85) scaled to how its glyphs render.
    static let fill = Color.secondary.opacity(0.85 * 0.74)

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

    /// "$200", "£16.67": the narrow symbol of the currency the account is billed in, and no decimals unless the
    /// price has them.
    nonisolated static func text(price: ProviderPlanPrice) -> String {
        let whole = price.monthlyAmount.rounded() == price.monthlyAmount
        return price.monthlyAmount.formatted(
            .currency(code: price.currencyCode)
                .presentation(.narrow)
                .precision(.fractionLength(whole ? 0 : 2))
                .locale(Locale(identifier: "en_US")))
    }

    /// Who sells the plan and what it is called, with its price; then the names it used to go by.
    /// "OpenAI ChatGPT Pro, £200 a month" / "Previously Pro 20x".
    nonisolated static func help(_ details: ProviderPlanDetails?, plan: String?, service: String) -> String {
        guard let details else { return plan ?? service }
        var title = [details.company, details.name ?? plan].compactMap(\.self).joined(separator: " ")
        if title.isEmpty { title = service }
        if let price = details.price {
            title += ", \(Self.text(price: price)) a month"
            if price.billedEvery == .year { title += " billed yearly" }
            if price.includesTax == false { title += " before tax" }
        }
        guard !details.formerNames.isEmpty else { return title }
        return title + "\nPreviously " + details.formerNames.formatted(.list(type: .or))
    }

    var body: some View {
        // About 4 pt of grey around the figures on every side: their cap height sits centred in the line. The
        // figures are cut out, so they show the page behind and read in either appearance.
        Text(verbatim: self.text)
            .font(.system(size: 9.5, weight: .bold))
            .foregroundStyle(.black)
            .blendMode(.destinationOut)
            .lineLimit(1)
            .padding(.horizontal, 4)
            .padding(.vertical, 1.5)
            .frame(minWidth: 15)
            // The badge keeps its size in a crowded footer; the name beside it shortens instead.
            .fixedSize()
            .background(Self.fill, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .compositingGroup()
            .help(self.plan)
            .accessibilityElement()
            .accessibilityLabel(self.plan)
    }
}
