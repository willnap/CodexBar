import Foundation

extension ProviderPluginSnapshotMapper {
    /// `plan`: who sells the account's plan, what it is called, and what it costs. `{ company?, name?,
    /// formerNames?, price? }` with `price` as `{ monthlyAmount, currency, billedEvery?, includesTax? }`:
    /// the price of one month in the currency the account is billed in (ISO 4217), `billedEvery` "month" or "year".
    static func plan(_ root: any ProviderPluginValue, now: Date) throws -> ProviderPlanDetails? {
        guard let value = root.property("plan"), !value.isUndefined, !value.isNull else { return nil }
        try self.object(value, allowed: ["company", "name", "formerNames", "price"], path: "plan")
        let price = try self.planPrice(value)
        let details = try ProviderPlanDetails(
            company: self.planString(value, "company", path: "plan"),
            name: self.planString(value, "name", path: "plan"),
            formerNames: self.planFormerNames(value),
            price: price,
            updatedAt: now)
        guard details.company != nil || details.name != nil || details.price != nil else {
            throw ProviderPluginError.invalidSnapshot("plan must name a company, a plan or a price")
        }
        return details
    }

    private static func planField(_ item: any ProviderPluginValue, _ property: String) -> (any ProviderPluginValue)? {
        guard let value = item.property(property), !value.isUndefined, !value.isNull else { return nil }
        return value
    }

    private static func planString(
        _ item: any ProviderPluginValue,
        _ property: String,
        path: String) throws -> String?
    {
        guard let value = self.planField(item, property) else { return nil }
        guard value.isString, value.stringValue().count <= ProviderPlanDetails.maximumNameLength else {
            throw ProviderPluginError.invalidSnapshot(
                "\(path).\(property) must be a string of at most \(ProviderPlanDetails.maximumNameLength) characters")
        }
        return value.stringValue()
    }

    private static func planFormerNames(_ plan: any ProviderPluginValue) throws -> [String] {
        guard let names = self.planField(plan, "formerNames") else { return [] }
        guard names.isArray else {
            throw ProviderPluginError.invalidSnapshot("plan.formerNames must be an array of strings")
        }
        let count = try self.boundedArrayCount(
            names, maximum: ProviderPlanDetails.maximumFormerNames, path: "plan.formerNames")
        return try (0..<count).map { index in
            guard let name = names.element(at: index), name.isString,
                  name.stringValue().count <= ProviderPlanDetails.maximumNameLength
            else { throw ProviderPluginError.invalidSnapshot("plan.formerNames[\(index)] must be a short string") }
            return name.stringValue()
        }
    }

    private static func planPrice(_ plan: any ProviderPluginValue) throws -> ProviderPlanPrice? {
        guard let value = self.planField(plan, "price") else { return nil }
        try self.object(
            value, allowed: ["monthlyAmount", "currency", "billedEvery", "includesTax"], path: "plan.price")
        guard let amount = self.planField(value, "monthlyAmount"), amount.isNumber,
              let currency = self.planField(value, "currency"), currency.isString
        else {
            throw ProviderPluginError.invalidSnapshot("plan.price needs a monthlyAmount number and a currency code")
        }
        var period: ProviderPlanPrice.Period?
        if let every = self.planField(value, "billedEvery") {
            guard every.isString, let parsed = ProviderPlanPrice.Period(rawValue: every.stringValue()) else {
                throw ProviderPluginError.invalidSnapshot(#"plan.price.billedEvery must be "month" or "year""#)
            }
            period = parsed
        }
        var includesTax: Bool?
        if let tax = self.planField(value, "includesTax") {
            guard tax.isBoolean else {
                throw ProviderPluginError.invalidSnapshot("plan.price.includesTax must be a boolean")
            }
            includesTax = tax.boolValue()
        }
        guard let price = ProviderPlanPrice(
            monthlyAmount: amount.doubleValue(),
            currencyCode: currency.stringValue(),
            billedEvery: period,
            includesTax: includesTax)
        else {
            throw ProviderPluginError.invalidSnapshot(
                "plan.price.monthlyAmount must be a non-negative amount and currency a three-letter ISO 4217 code")
        }
        return price
    }
}
