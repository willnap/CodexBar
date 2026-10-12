import Foundation

/// API list-price estimates for Kimi Code wire records.
///
/// Kimi Code reports route models (`kimi-code/k3`) whose plan entries on models.dev are priced at zero. A route
/// model is priced only when models.dev identifies exactly one Moonshot API model behind it, by model ID or by
/// the plan entry's display name, with a nonzero rate. Ambiguous or unpublished routes stay unpriced.
struct NativeKimiListPricing: Sendable {
    static let apiProviderID = "moonshotai"
    static let planProviderIDs = ["kimi-code-plan-global", "kimi-code-plan-cn"]

    private let rates: [String: ModelsDevPricingInfo]

    init(catalog: ModelsDevCatalog?, models: Set<String>) {
        guard let catalog else {
            self.rates = [:]
            return
        }
        var rates: [String: ModelsDevPricingInfo] = [:]
        for model in models {
            if let pricing = Self.listPrice(model: model, catalog: catalog) { rates[model] = pricing }
        }
        self.rates = rates
    }

    func costUSD(model: String?, input: Int, output: Int, cacheRead: Int, cacheCreation: Int) -> Double? {
        guard let model, let pricing = self.rates[model] else { return nil }
        let tokens = CostUsagePricing.ClaudeCostTokens(
            input: input,
            cacheRead: cacheRead,
            cacheCreation: cacheCreation,
            cacheCreation1h: 0,
            output: output)
        let cost = CostUsagePricing.claudeCostUSD(pricing: pricing, tokens: tokens)
        return cost.isFinite && cost >= 0 ? cost : nil
    }

    static func listPrice(model rawModel: String, catalog: ModelsDevCatalog) -> ModelsDevPricingInfo? {
        let trimmed = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "/", maxSplits: 1).map(String.init)
        guard let routeModel = parts.last?.lowercased(), !routeModel.isEmpty else { return nil }
        if parts.count == 2 {
            let route = parts[0].lowercased()
            // Provider-specific by design: only Kimi/Moonshot routes can name a Moonshot API model.
            guard route.hasPrefix("kimi") || route.hasPrefix("moonshot") else { return nil }
        }
        guard let api = catalog.providers[Self.apiProviderID] else { return nil }
        let planNames = Set(Self.planProviderIDs.compactMap { catalog.providers[$0]?.models[routeModel]?.name }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty })
        let ids: Set<String> = [routeModel, "kimi-" + routeModel]
        let matches = api.models.values.filter { model in
            let name = model.name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return ids.contains(model.id.lowercased()) || name.map(planNames.contains) == true
        }
        guard Set(matches.map { $0.id.lowercased() }).count == 1, let model = matches.first,
              let pricing = model.pricing(providerID: Self.apiProviderID, providerName: api.name),
              pricing.inputCostPerToken.isFinite, pricing.outputCostPerToken.isFinite,
              pricing.inputCostPerToken >= 0, pricing.outputCostPerToken >= 0,
              pricing.inputCostPerToken > 0 || pricing.outputCostPerToken > 0
        else { return nil }
        return pricing
    }
}
