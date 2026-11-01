import Foundation

enum ProviderPluginSnapshotMapper {
    private static let maximumStringBytes = 256
    private static let maximumJavaScriptSafeInteger = 9_007_199_254_740_991.0

    static func map(
        _ value: any ProviderPluginValue,
        provider: ProviderInstanceID,
        now: Date = Date(),
        percentPolicy: ProviderPluginPercentPolicy = .clamp) throws -> UsageSnapshot
    {
        guard value.isObject, !value.isArray, !value.isNull else {
            throw ProviderPluginError.invalidSnapshot("fetchUsage must resolve to an object")
        }

        try self.object(
            value,
            allowed: [
                "primary", "secondary", "tertiary", "extraWindows", "cost", "balance", "costUsage", "details",
                "identity", "iconProvider", "menuBarItems",
                "subscriptionRenewsAt", "subscriptionExpiresAt", "subscriptionStatus", "subscriptionIsActive",
                "dataConfidence", "empty",
            ],
            path: "usage")

        let primary = try self.window(value, property: "primary", percentPolicy: percentPolicy)
        let secondary = try self.window(value, property: "secondary", percentPolicy: percentPolicy)
        let tertiary = try self.window(value, property: "tertiary", percentPolicy: percentPolicy)
        let extraRateWindows = try self.extraWindows(value, percentPolicy: percentPolicy)
        let cost = try self.cost(value, now: now)
        let balance = try self.balance(value, now: now)
        let queriedBalance = value.property("balance").map { !$0.isUndefined } ?? false
        guard cost == nil || !queriedBalance else {
            throw ProviderPluginError.invalidSnapshot("balance and cost cannot describe separate pools in one snapshot")
        }
        let providerCost = cost ?? balance
        let costUsage = try self.costUsage(value, now: now)
        let details = try self.details(value)
        let identity = try self.identity(value, provider: provider)
        let iconProvider = try self.iconProvider(value)
        let menuBarItems = try self.menuBarItems(value)
        let subscriptionRenewsAt = try self.optionalDate(value, property: "subscriptionRenewsAt")
        let subscriptionStatus = try self.optionalString(value, property: "subscriptionStatus", path: "usage")
        let subscriptionIsActive = try self.optionalBoolean(value, property: "subscriptionIsActive", path: "usage")
        let subscriptionExpiresAt = try self.optionalDate(value, property: "subscriptionExpiresAt")
        let dataConfidence = try self.dataConfidence(value)
        let empty = value.property("empty")
        if let empty, !empty.isUndefined, !empty.isBoolean {
            throw ProviderPluginError.invalidSnapshot("empty must be a boolean")
        }

        guard empty?.boolValue() == true
            || primary != nil || secondary != nil || tertiary != nil || !(extraRateWindows?.isEmpty ?? true)
            || providerCost != nil
            || costUsage != nil
            || !details.isEmpty
            || self.hasMeaningfulIdentity(identity)
        else {
            throw ProviderPluginError.invalidSnapshot(
                "snapshot must contain a rate window, cost, detail section, or identity field, or declare empty: true")
        }

        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            tertiary: tertiary,
            extraRateWindows: extraRateWindows,
            providerCost: providerCost,
            costUsage: costUsage,
            details: details,
            iconProvider: iconProvider,
            menuBarItems: menuBarItems,
            subscriptionStatus: subscriptionStatus,
            subscriptionIsActive: subscriptionIsActive,
            subscriptionExpiresAt: subscriptionExpiresAt,
            subscriptionRenewsAt: subscriptionRenewsAt,
            updatedAt: now,
            identity: identity,
            dataConfidence: dataConfidence)
    }

    private static func iconProvider(_ root: any ProviderPluginValue) throws -> UsageProvider? {
        guard let value = root.property("iconProvider"), !value.isUndefined, !value.isNull else { return nil }
        guard value.isString, let provider = UsageProvider(rawValue: value.stringValue()) else {
            throw ProviderPluginError.invalidSnapshot("iconProvider must be a built-in provider ID")
        }
        return provider
    }

    private static func menuBarItems(_ root: any ProviderPluginValue) throws -> [ProviderMenuBarItem] {
        guard let value = root.property("menuBarItems"), !value.isUndefined, !value.isNull else { return [] }
        guard value.isArray else { throw ProviderPluginError.invalidSnapshot("menuBarItems must be an array") }
        let count = try self.boundedArrayCount(value, maximum: ProviderMenuBarItem.maximumItems, path: "menuBarItems")
        return try (0..<count).map { index in
            let path = "menuBarItems[\(index)]"
            guard let item = value.element(at: index), item.isObject, !item.isArray else {
                throw ProviderPluginError.invalidSnapshot("\(path) must be an object")
            }
            try self.object(item, allowed: ["title", "iconProvider", "windowID"], path: path)
            return try ProviderMenuBarItem(
                title: self.requiredDetailString(item, property: "title", path: path),
                iconProvider: self.iconProvider(item),
                windowID: self.optionalDetailString(item, property: "windowID", path: path))
        }
    }

    private static func hasMeaningfulIdentity(_ identity: ProviderIdentitySnapshot?) -> Bool {
        guard let identity else { return false }
        return identity.accountEmail != nil || identity.accountOrganization != nil || identity.loginMethod != nil
            || identity.accountID != nil
    }

    private static func dataConfidence(_ root: any ProviderPluginValue) throws -> UsageDataConfidence {
        guard let value = root.property("dataConfidence"), !value.isUndefined, !value.isNull else {
            return .unknown
        }
        guard value.isString, let confidence = UsageDataConfidence(rawValue: value.stringValue()) else {
            throw ProviderPluginError.invalidSnapshot(
                "dataConfidence must be 'exact', 'estimated', 'percentOnly', or 'unknown'")
        }
        return confidence
    }

    private static func details(_ root: any ProviderPluginValue) throws -> [ProviderDetailSection] {
        guard let value = root.property("details"), !value.isUndefined, !value.isNull else { return [] }
        guard value.isArray else {
            throw ProviderPluginError.invalidSnapshot("details must be an array")
        }
        let count = try self.boundedArrayCount(
            value,
            maximum: ProviderDetailSection.maximumSectionsPerSnapshot,
            path: "details")
        return try (0..<count).map { index in
            guard let section = value.element(at: index), section.isObject, !section.isArray else {
                throw ProviderPluginError.invalidSnapshot("details[\(index)] must be an object")
            }
            let path = "details[\(index)]"
            let title = try self.optionalDetailString(section, property: "title", path: path)
            guard let rowsValue = section.property("rows"), rowsValue.isArray else {
                throw ProviderPluginError.invalidSnapshot("\(path).rows must be an array")
            }
            let rowCount = try self.boundedArrayCount(
                rowsValue,
                maximum: ProviderDetailSection.maximumRowsPerSection,
                path: "\(path).rows")
            let rows = try (0..<rowCount).map { rowIndex in
                guard let row = rowsValue.element(at: rowIndex), row.isObject, !row.isArray else {
                    throw ProviderPluginError.invalidSnapshot("\(path).rows[\(rowIndex)] must be an object")
                }
                let rowPath = "\(path).rows[\(rowIndex)]"
                return try ProviderDetailSection.Row(
                    label: self.requiredDetailString(row, property: "label", path: rowPath),
                    value: self.requiredDetailString(row, property: "value", path: rowPath),
                    secondaryValue: self.optionalDetailString(row, property: "secondaryValue", path: rowPath),
                    progress: self.detailProgress(row, path: rowPath),
                    severity: self.detailSeverity(row, path: rowPath),
                    usageValue: self.optionalFiniteNumber(row, property: "usageValue", path: rowPath))
            }
            let chart = try self.detailChart(section, path: path)
            return try ProviderDetailSection(title: title, rows: rows, chart: chart)
        }
    }

    private static func detailSeverity(
        _ row: any ProviderPluginValue,
        path: String) throws -> ProviderDetailSection.Row.Severity?
    {
        guard let value = row.property("severity"), !value.isUndefined, !value.isNull else { return nil }
        guard value.isString, let severity = ProviderDetailSection.Row.Severity(rawValue: value.stringValue()) else {
            throw ProviderPluginError.invalidSnapshot("\(path).severity must be normal, warning, or critical")
        }
        return severity
    }

    private static func detailProgress(
        _ row: any ProviderPluginValue,
        path: String) throws -> ProviderDetailSection.Row.Progress?
    {
        // Pace is validated even without progress so a malformed field never passes silently;
        // without progress there is no bar to mark, so it is then dropped.
        let pace = try self.optionalFiniteNumber(row, property: "pace", path: path)
        if let pace, !(0...1).contains(pace) {
            throw ProviderPluginError.invalidSnapshot("\(path).pace must be between 0 and 1")
        }
        guard let fraction = try self.optionalFiniteNumber(row, property: "progress", path: path) else { return nil }
        guard (0...1).contains(fraction) else {
            throw ProviderPluginError.invalidSnapshot("\(path).progress must be between 0 and 1")
        }
        return try ProviderDetailSection.Row.Progress(used: fraction, total: 1, expectedUsed: pace)
    }

    private static func detailChart(
        _ section: any ProviderPluginValue,
        path: String) throws -> ProviderDetailSection.Chart?
    {
        guard let chart = section.property("chart"), !chart.isUndefined, !chart.isNull else { return nil }
        guard chart.isObject, !chart.isArray else {
            throw ProviderPluginError.invalidSnapshot("\(path).chart must be an object")
        }
        let chartPath = "\(path).chart"
        let rawKind = try self.requiredDetailString(chart, property: "kind", path: chartPath)
        guard let kind = ProviderDetailSection.Chart.Kind(rawValue: rawKind) else {
            throw ProviderPluginError.invalidSnapshot("\(chartPath).kind must be 'bars' or 'line'")
        }
        let title = try self.optionalDetailString(chart, property: "title", path: chartPath)
        let unit = try self.optionalDetailString(chart, property: "unit", path: chartPath)
        guard let pointsValue = chart.property("points"), pointsValue.isArray else {
            throw ProviderPluginError.invalidSnapshot("\(chartPath).points must be an array")
        }
        let pointCount = try self.boundedArrayCount(
            pointsValue,
            maximum: ProviderDetailSection.maximumPointsPerChart,
            path: "\(chartPath).points")
        let points = try (0..<pointCount).map { pointIndex in
            guard let point = pointsValue.element(at: pointIndex), point.isObject, !point.isArray else {
                throw ProviderPluginError.invalidSnapshot("\(chartPath).points[\(pointIndex)] must be an object")
            }
            let pointPath = "\(chartPath).points[\(pointIndex)]"
            return try ProviderDetailSection.Chart.Point(
                label: self.requiredDetailString(point, property: "label", path: pointPath),
                value: self.requiredFiniteNumber(point, property: "value", path: pointPath))
        }
        return try ProviderDetailSection.Chart(kind: kind, title: title, unit: unit, points: points)
    }

    private static func requiredDetailString(
        _ value: any ProviderPluginValue,
        property: String,
        path: String) throws -> String
    {
        guard let string = try self.optionalDetailString(value, property: property, path: path) else {
            throw ProviderPluginError.invalidSnapshot("\(path).\(property) is required")
        }
        return string
    }

    private static func optionalDetailString(
        _ value: any ProviderPluginValue,
        property: String,
        path: String) throws -> String?
    {
        guard let propertyValue = value.property(property),
              !propertyValue.isUndefined,
              !propertyValue.isNull
        else { return nil }
        guard propertyValue.isString else {
            throw ProviderPluginError.invalidSnapshot("\(path).\(property) must be a string")
        }
        let string = propertyValue.stringValue().trimmingCharacters(in: .whitespacesAndNewlines)
        guard string.count <= ProviderDetailSection.maximumStringLength else {
            throw ProviderPluginError.invalidSnapshot(
                "\(path).\(property) exceeds \(ProviderDetailSection.maximumStringLength) characters")
        }
        return string.isEmpty ? nil : string
    }

    private static func window(
        _ root: any ProviderPluginValue,
        property: String,
        percentPolicy: ProviderPluginPercentPolicy) throws -> RateWindow?
    {
        guard let value = root.property(property), !value.isUndefined, !value.isNull else { return nil }
        return try self.window(value, path: property, percentPolicy: percentPolicy)
    }

    private static func window(
        _ value: any ProviderPluginValue,
        path: String,
        percentPolicy: ProviderPluginPercentPolicy) throws -> RateWindow
    {
        guard value.isObject, !value.isArray else {
            throw ProviderPluginError.invalidSnapshot("\(path) must be an object")
        }
        let rawPercent = try self.requiredFiniteNumber(value, property: "usedPercent", path: path)
        let usedPercent = percentPolicy.map(rawPercent)
        let windowMinutes = try self.optionalPositiveInteger(value, property: "windowMinutes", path: path)
        let resetsAt = try self.optionalDate(value, property: "resetsAt", path: path)
        let resetDescription = try self.optionalString(value, property: "resetDescription", path: path)
        let nextRegenPercent = try self.optionalFiniteNumber(value, property: "nextRegenPercent", path: path)
        let quotaLimit = try self.optionalFiniteNumber(value, property: "quotaLimit", path: path)
        if let quotaLimit, quotaLimit <= 0 {
            throw ProviderPluginError.invalidSnapshot("\(path).quotaLimit must be positive")
        }
        return try RateWindow(
            usedPercent: usedPercent,
            windowMinutes: windowMinutes,
            resetsAt: resetsAt,
            resetDescription: resetDescription,
            quotaLimit: quotaLimit,
            quotaUnit: self.optionalString(value, property: "quotaUnit", path: path),
            nextRegenPercent: nextRegenPercent.map { min(100, max(0, $0)) },
            title: self.optionalString(value, property: "title", path: path))
    }

    private static func extraWindows(
        _ root: any ProviderPluginValue, percentPolicy: ProviderPluginPercentPolicy) throws -> [NamedRateWindow]?
    {
        guard let value = root.property("extraWindows"), !value.isUndefined, !value.isNull else { return nil }
        guard value.isArray else {
            throw ProviderPluginError.invalidSnapshot("extraWindows must be an array")
        }
        let count = try self.boundedArrayCount(value, maximum: 64, path: "extraWindows")
        return try (0..<count).map { index in
            guard let item = value.element(at: index), item.isObject, !item.isArray else {
                throw ProviderPluginError.invalidSnapshot("extraWindows[\(index)] must be an object")
            }
            let path = "extraWindows[\(index)]"
            let id = try self.requiredString(item, property: "id", path: path)
            let title = try self.requiredString(item, property: "title", path: path)
            let windowValue = item.property("window")
            let window = try self.window(
                windowValue?.isObject == true && windowValue?.isNull == false ? windowValue! : item,
                path: "\(path).window",
                percentPolicy: percentPolicy)
            var usageKnown = true
            if let value = item.property("usageKnown"), !value.isUndefined {
                guard value.isBoolean else {
                    throw ProviderPluginError.invalidSnapshot("\(path).usageKnown must be a boolean")
                }
                usageKnown = value.boolValue()
            }
            return NamedRateWindow(id: id, title: title, window: window, usageKnown: usageKnown)
        }
    }

    private static func cost(_ root: any ProviderPluginValue, now: Date) throws -> ProviderCostSnapshot? {
        guard let value = root.property("cost"), !value.isUndefined, !value.isNull else { return nil }
        guard value.isObject, !value.isArray else {
            throw ProviderPluginError.invalidSnapshot("cost must be an object")
        }
        let used = try self.requiredFiniteNumber(value, property: "used", path: "cost")
        let limit = try self.optionalFiniteNumber(value, property: "limit", path: "cost") ?? 0
        let currency = try self.requiredString(value, property: "currency", path: "cost")
        guard currency.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil else {
            throw ProviderPluginError.invalidSnapshot("cost.currency must be a three-letter uppercase currency literal")
        }
        let period = try self.optionalString(value, property: "period", path: "cost")
        let resetsAt = try self.optionalDate(value, property: "resetsAt", path: "cost")
        let nextRegenAmount = try self.optionalFiniteNumber(value, property: "nextRegenAmount", path: "cost")
        let balance = try self.optionalFiniteNumber(value, property: "balance", path: "cost")
        let balanceUpdatedAt = try self.optionalDate(value, property: "balanceUpdatedAt", path: "cost")
        let unavailable = value.property("usageIsUnavailable")
        if let unavailable, !unavailable.isUndefined, !unavailable.isNull, !unavailable.isBoolean {
            throw ProviderPluginError.invalidSnapshot("cost.usageIsUnavailable must be a boolean")
        }
        return ProviderCostSnapshot(
            used: used,
            limit: limit,
            currencyCode: currency,
            period: period,
            resetsAt: resetsAt,
            nextRegenAmount: nextRegenAmount,
            balance: balance,
            balanceUpdatedAt: balanceUpdatedAt ?? (balance == nil ? nil : now),
            usageIsUnavailable: unavailable?.isBoolean == true ? unavailable?.boolValue() : nil,
            updatedAt: now)
    }

    private static func costUsage(
        _ root: any ProviderPluginValue, now: Date) throws -> CostUsageTokenSnapshot?
    {
        guard let value = root.property("costUsage"), !value.isUndefined, !value.isNull else { return nil }
        guard value.isObject, !value.isArray else {
            throw ProviderPluginError.invalidSnapshot("costUsage must be an object")
        }
        let currency = try self.requiredString(value, property: "currency", path: "costUsage")
        guard currency.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil else {
            throw ProviderPluginError.invalidSnapshot(
                "costUsage.currency must be a three-letter uppercase currency literal")
        }
        let historyDays = try self.requiredPositiveInteger(
            value,
            property: "historyDays",
            path: "costUsage")
        guard historyDays <= 366 else {
            throw ProviderPluginError.invalidSnapshot("costUsage.historyDays exceeds 366")
        }
        let historyLabel = try self.optionalString(value, property: "historyLabel", path: "costUsage")
        let windowEnd = try self.requiredString(value, property: "windowEnd", path: "costUsage")
        guard windowEnd.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil,
              let windowEndDate = CostUsageDateParser.parse("\(windowEnd)T12:00:00Z")
        else {
            throw ProviderPluginError.invalidSnapshot("costUsage.windowEnd must be a valid YYYY-MM-DD date")
        }
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let windowStartDate = utcCalendar.date(
            byAdding: .day,
            value: -(historyDays - 1),
            to: windowEndDate) ?? windowEndDate
        guard let entriesValue = value.property("entries"), entriesValue.isArray else {
            throw ProviderPluginError.invalidSnapshot("costUsage.entries must be an array")
        }
        let count = try self.boundedArrayCount(entriesValue, maximum: 10000, path: "costUsage.entries")

        let parsedEntries = try self.costUsageEntries(
            entriesValue,
            count: count,
            windowStartDate: windowStartDate,
            windowEndDate: windowEndDate)
        let aggregation = try self.aggregateCostUsageEntries(parsedEntries)
        let totals = try self.costUsageTotals(value)
        var metrics = value.property("metrics")
        if metrics?.isNull == true || metrics?.isUndefined == true { metrics = nil }
        if let metrics, !metrics.isUndefined, !metrics.isNull {
            guard metrics.isObject, !metrics.isArray else {
                throw ProviderPluginError.invalidSnapshot("costUsage.metrics must be an object")
            }
        }
        let emptyTokens = try metrics.flatMap {
            try self.optionalBoolean($0, property: "totalTokens", path: "costUsage.metrics")
        } == true ? 0 : nil
        let emptyRequests = try metrics.flatMap {
            try self.optionalBoolean($0, property: "requests", path: "costUsage.metrics")
        } == true ? 0 : nil
        let emptyCost: Double? = try metrics.flatMap {
            try self.optionalBoolean($0, property: "cost", path: "costUsage.metrics")
        } == true ? 0 : nil
        let tokens = totals.flatMap(\.totalTokens) ?? (count > 0 ? aggregation.totalTokens : emptyTokens)
        let requests = totals.flatMap(\.requests) ?? (count > 0 ? aggregation.totalRequests : emptyRequests)
        let cost = totals.flatMap(\.cost) ?? (count > 0 ? aggregation.totalCost : emptyCost)
        let pricingEntries = totals.flatMap { $0.cost == nil ? nil : [$0] } ?? parsedEntries
        let hasEstimated = pricingEntries.contains { $0.hasEstimatedCost }
        let hasMetered = pricingEntries.contains { ($0.cost ?? 0) > $0.estimatedCost }
        let meteredCost = try pricingEntries.reduce(0.0) { total, entry in
            try self.optionalMoneySum(total, max(0, (entry.cost ?? 0) - entry.estimatedCost))!
        }
        let provenance: CostProvenance = if hasEstimated {
            hasMetered ? .mixed : .listPriceEstimate
        } else {
            cost != nil || pricingEntries.contains(where: { $0.cost != nil }) ? .vendorMetered : .unknown
        }
        let observedAt = try self.optionalDate(value, property: "updatedAt", path: "costUsage") ?? now
        let bucketZoneIdentifier = try self.optionalString(
            value,
            property: "bucketTimeZoneIdentifier",
            path: "costUsage") ?? "UTC"
        guard let bucketZone = TimeZone(identifier: bucketZoneIdentifier) else {
            throw ProviderPluginError.invalidSnapshot("costUsage.bucketTimeZoneIdentifier must be a valid time zone")
        }
        let bucketDateFormatter = DateFormatter()
        bucketDateFormatter.locale = Locale(identifier: "en_US_POSIX")
        bucketDateFormatter.timeZone = bucketZone
        bucketDateFormatter.dateFormat = "yyyy-MM-dd"
        let explicitCoverage = try self.optionalBoolean(
            value,
            property: "historyCoverageIsEstablished",
            path: "costUsage")
        // Explicit complete reports may end before the observation day (e.g. completed UTC days).
        // Keep the source end separate so callers cannot zero-fill days beyond that window.
        let observedDay = bucketDateFormatter.string(from: observedAt)
        let coverageEstablished = (explicitCoverage ?? true) && windowEnd <= observedDay
            && (windowEnd == observedDay || explicitCoverage == true)
        return CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            sessionRequests: nil,
            last30DaysTokens: tokens,
            last30DaysCostUSD: cost,
            last30DaysRequests: requests,
            currencyCode: currency,
            historyDays: historyDays,
            historyCoverageIsEstablished: coverageEstablished,
            historyLabel: historyLabel,
            bucketTimeZoneIdentifier: bucketZoneIdentifier,
            coverageThrough: bucketDateFormatter.date(from: windowEnd),
            meteredCostUSD: hasEstimated && hasMetered ? meteredCost : nil,
            costProvenance: provenance,
            daily: aggregation.daily,
            updatedAt: observedAt)
    }

    private static func costUsageTotals(_ value: any ProviderPluginValue) throws -> CostUsageParsedEntry? {
        guard let totals = value.property("totals"), !totals.isNull, !totals.isUndefined else { return nil }
        guard totals.isObject, !totals.isArray else {
            throw ProviderPluginError.invalidSnapshot("costUsage.totals must be an object")
        }
        return try self.costUsageMeasurement(totals, date: "", path: "costUsage.totals")
    }

    private static func costUsageEntries(
        _ entriesValue: any ProviderPluginValue,
        count: Int,
        windowStartDate: Date,
        windowEndDate: Date) throws -> [CostUsageParsedEntry]
    {
        try (0..<count).map { index in
            guard let entry = entriesValue.element(at: index), entry.isObject, !entry.isArray else {
                throw ProviderPluginError.invalidSnapshot("costUsage.entries[\(index)] must be an object")
            }
            let path = "costUsage.entries[\(index)]"
            let date = try self.requiredString(entry, property: "date", path: path)
            guard date.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil,
                  let entryDate = CostUsageDateParser.parse("\(date)T12:00:00Z")
            else {
                throw ProviderPluginError.invalidSnapshot("\(path).date must be a valid YYYY-MM-DD date")
            }
            guard entryDate >= windowStartDate, entryDate <= windowEndDate else {
                throw ProviderPluginError.invalidSnapshot("\(path).date falls outside the declared history window")
            }
            return try self.costUsageMeasurement(entry, date: date, path: path)
        }
    }

    private static func costUsageMeasurement(
        _ entry: any ProviderPluginValue,
        date: String,
        path: String) throws -> CostUsageParsedEntry
    {
        let inputTokens = try self.optionalNonnegativeInteger(entry, property: "inputTokens", path: path)
        let outputTokens = try self.optionalNonnegativeInteger(entry, property: "outputTokens", path: path)
        let reasoningTokens = try self.optionalNonnegativeInteger(
            entry,
            property: "reasoningTokens",
            path: path)
        let requests = try self.optionalNonnegativeInteger(entry, property: "requests", path: path)
        let cost = try self.optionalFiniteNumber(entry, property: "cost", path: path)
        guard cost.map({ $0 >= 0 }) ?? true else {
            throw ProviderPluginError.invalidSnapshot("\(path).cost must be nonnegative")
        }
        let reportedEstimate = try self.optionalFiniteNumber(
            entry,
            property: "estimatedCost",
            path: path)
        let estimatedCost = reportedEstimate ?? 0
        if reportedEstimate != nil, cost == nil {
            throw ProviderPluginError.invalidSnapshot("\(path).estimatedCost requires cost")
        }
        guard estimatedCost >= 0, estimatedCost <= (cost ?? 0) else {
            throw ProviderPluginError.invalidSnapshot(
                "\(path).estimatedCost must be nonnegative and no greater than cost")
        }
        let derivedTotal = try self.optionalCountSum(inputTokens, outputTokens, path: "\(path) token total")
        let reportedTotal = try self.optionalNonnegativeInteger(entry, property: "totalTokens", path: path)
        if let reportedTotal, let derivedTotal, reportedTotal < derivedTotal {
            throw ProviderPluginError.invalidSnapshot("\(path).totalTokens is below its reported breakdown")
        }
        return try CostUsageParsedEntry(
            date: date,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            reasoningTokens: reasoningTokens,
            totalTokens: reportedTotal ?? derivedTotal,
            requests: requests,
            cost: cost,
            estimatedCost: estimatedCost,
            hasEstimatedCost: reportedEstimate != nil,
            model: self.optionalString(entry, property: "model", path: path))
    }

    private static func addCostUsage(_ entry: CostUsageAccumulator, to total: inout CostUsageAccumulator) throws {
        total.inputTokens = try self.optionalCountSum(
            total.inputTokens,
            entry.inputTokens,
            path: "costUsage input tokens")
        total.outputTokens = try self.optionalCountSum(
            total.outputTokens,
            entry.outputTokens,
            path: "costUsage output tokens")
        total.totalTokens = try self.optionalCountSum(
            total.totalTokens,
            entry.totalTokens,
            path: "costUsage total tokens")
        total.requests = try self.optionalCountSum(total.requests, entry.requests, path: "costUsage requests")
        total.reasoningTokens = try self.checkedSum(
            total.reasoningTokens,
            entry.reasoningTokens,
            path: "costUsage reasoning tokens")
        total.hasReasoningTokens = total.hasReasoningTokens || entry.hasReasoningTokens
        total.estimatedRequests = try self.optionalCountSum(
            total.estimatedRequests,
            entry.estimatedRequests,
            path: "costUsage estimated requests")
        total.cost = try self.optionalMoneySum(total.cost, entry.cost)
        total.knownCost = try self.optionalMoneySum(total.knownCost, entry.knownCost)!
        total.hasCost = total.hasCost || entry.hasCost
        total.hasMissingCost = total.hasMissingCost || entry.hasMissingCost
        total.estimatedCost += entry.estimatedCost
        guard total.estimatedCost.isFinite else {
            throw ProviderPluginError.invalidSnapshot("costUsage estimated cost overflowed")
        }
    }

    private static func aggregateCostUsageEntries(
        _ entries: [CostUsageParsedEntry]) throws -> CostUsageAggregation
    {
        var grouped: [String: CostUsageAccumulator] = [:]
        for entry in entries {
            let key = "\(entry.date)\u{1F}\(entry.model ?? "")"
            var total = grouped[key] ?? CostUsageAccumulator()
            let row = CostUsageAccumulator(
                inputTokens: entry.inputTokens,
                outputTokens: entry.outputTokens,
                reasoningTokens: entry.reasoningTokens ?? 0,
                hasReasoningTokens: entry.reasoningTokens != nil,
                totalTokens: entry.totalTokens,
                requests: entry.requests,
                cost: entry.cost,
                estimatedCost: entry.estimatedCost,
                estimatedRequests: entry.hasEstimatedCost ? entry.requests : 0,
                knownCost: entry.cost ?? 0,
                hasCost: entry.cost != nil,
                hasMissingCost: entry.cost == nil)
            try self.addCostUsage(row, to: &total)
            grouped[key] = total
        }
        var dailyGrouped: [String: CostUsageAccumulator] = [:]
        var breakdowns: [String: [CostUsageDailyReport.ModelBreakdown]] = [:]
        for key in grouped.keys.sorted() {
            let parts = key.split(separator: "\u{1F}", maxSplits: 1, omittingEmptySubsequences: false)
            let date = String(parts[0])
            let row = grouped[key]!
            if parts.count > 1, !parts[1].isEmpty {
                breakdowns[date, default: []].append(.init(
                    modelName: String(parts[1]),
                    costUSD: row.cost,
                    totalTokens: row.totalTokens,
                    requestCount: row.requests,
                    inputTokens: row.inputTokens,
                    outputTokens: row.outputTokens,
                    reasoningTokens: row.hasReasoningTokens ? row.reasoningTokens : nil))
            }
            var total = dailyGrouped[date] ?? CostUsageAccumulator()
            try self.addCostUsage(row, to: &total)
            dailyGrouped[date] = total
        }
        var all = CostUsageAccumulator()
        var daily: [CostUsageDailyReport.Entry] = []
        for date in dailyGrouped.keys.sorted() {
            let row = dailyGrouped[date]!
            try self.addCostUsage(row, to: &all)
            daily.append(.init(
                date: date,
                inputTokens: row.inputTokens,
                outputTokens: row.outputTokens,
                reasoningTokens: row.hasReasoningTokens ? row.reasoningTokens : nil,
                totalTokens: row.totalTokens,
                requestCount: row.requests,
                costUSD: row.hasCost ? row.knownCost : nil,
                modelsUsed: breakdowns[date]?.map(\.modelName),
                modelBreakdowns: breakdowns[date],
                estimatedRequestCount: (row.estimatedRequests ?? 0) > 0 ? row.estimatedRequests : nil,
                costIsPartial: row.hasCost && row.hasMissingCost ? true : nil))
        }
        return CostUsageAggregation(
            daily: daily,
            totalTokens: all.totalTokens,
            totalRequests: all.requests,
            totalCost: all.cost)
    }

    private static func optionalCountSum(_ lhs: Int?, _ rhs: Int?, path: String) throws -> Int? {
        guard let lhs, let rhs else { return nil }
        return try self.checkedSum(lhs, rhs, path: path)
    }

    private static func optionalMoneySum(_ lhs: Double?, _ rhs: Double?) throws -> Double? {
        guard let lhs, let rhs else { return nil }
        let sum = lhs + rhs
        guard sum.isFinite else { throw ProviderPluginError.invalidSnapshot("costUsage cost total overflowed") }
        return sum
    }

    private static func checkedSum(_ lhs: Int, _ rhs: Int, path: String) throws -> Int {
        let sum = lhs.addingReportingOverflow(rhs)
        guard !sum.overflow, Double(sum.partialValue) <= self.maximumJavaScriptSafeInteger else {
            throw ProviderPluginError.invalidSnapshot("\(path) overflowed")
        }
        return sum.partialValue
    }

    private static func identity(
        _ root: any ProviderPluginValue,
        provider: ProviderInstanceID) throws -> ProviderIdentitySnapshot?
    {
        guard let value = root.property("identity"), !value.isUndefined, !value.isNull else { return nil }
        guard value.isObject, !value.isArray else {
            throw ProviderPluginError.invalidSnapshot("identity must be an object")
        }
        return try ProviderIdentitySnapshot(
            providerID: provider,
            accountEmail: self.optionalString(value, property: "email", path: "identity"),
            accountOrganization: self.optionalString(value, property: "organization", path: "identity"),
            loginMethod: self.optionalString(value, property: "loginMethod", path: "identity"),
            accountID: self.optionalString(value, property: "accountID", path: "identity"))
    }

    private static func requiredFiniteNumber(
        _ value: any ProviderPluginValue,
        property: String,
        path: String) throws -> Double
    {
        guard let result = try self.optionalFiniteNumber(value, property: property, path: path) else {
            throw ProviderPluginError.invalidSnapshot("\(path).\(property) is required")
        }
        return result
    }

    private static func optionalFiniteNumber(
        _ value: any ProviderPluginValue,
        property: String,
        path: String) throws -> Double?
    {
        guard let propertyValue = value.property(property),
              !propertyValue.isUndefined,
              !propertyValue.isNull
        else { return nil }
        guard propertyValue.isNumber else {
            throw ProviderPluginError.invalidSnapshot("\(path).\(property) must be a number")
        }
        let number = propertyValue.doubleValue()
        guard number.isFinite else {
            throw ProviderPluginError.invalidSnapshot("\(path).\(property) must be finite")
        }
        return number
    }

    private static func optionalBoolean(
        _ value: any ProviderPluginValue,
        property: String,
        path: String) throws -> Bool?
    {
        guard let field = value.property(property), !field.isNull, !field.isUndefined else { return nil }
        guard field.isBoolean else {
            throw ProviderPluginError.invalidSnapshot("\(path).\(property) must be a boolean")
        }
        return field.boolValue()
    }

    private static func optionalPositiveInteger(
        _ value: any ProviderPluginValue,
        property: String,
        path: String) throws -> Int?
    {
        guard let number = try self.optionalFiniteNumber(value, property: property, path: path) else { return nil }
        guard number.rounded() == number, number > 0, number <= self.maximumJavaScriptSafeInteger else {
            throw ProviderPluginError.invalidSnapshot("\(path).\(property) must be a positive integer")
        }
        return Int(number)
    }

    private static func requiredPositiveInteger(
        _ value: any ProviderPluginValue,
        property: String,
        path: String) throws -> Int
    {
        guard let result = try self.optionalPositiveInteger(value, property: property, path: path) else {
            throw ProviderPluginError.invalidSnapshot("\(path).\(property) is required")
        }
        return result
    }

    private static func requiredNonnegativeInteger(
        _ value: any ProviderPluginValue,
        property: String,
        path: String) throws -> Int
    {
        guard let result = try self.optionalNonnegativeInteger(value, property: property, path: path) else {
            throw ProviderPluginError.invalidSnapshot("\(path).\(property) is required")
        }
        return result
    }

    private static func optionalNonnegativeInteger(
        _ value: any ProviderPluginValue,
        property: String,
        path: String) throws -> Int?
    {
        guard let number = try self.optionalFiniteNumber(value, property: property, path: path) else { return nil }
        guard number.rounded() == number, number >= 0, number <= self.maximumJavaScriptSafeInteger else {
            throw ProviderPluginError.invalidSnapshot("\(path).\(property) must be a nonnegative integer")
        }
        return Int(number)
    }

    private static func requiredString(
        _ value: any ProviderPluginValue,
        property: String,
        path: String) throws -> String
    {
        guard let string = try self.optionalString(value, property: property, path: path) else {
            throw ProviderPluginError.invalidSnapshot("\(path).\(property) is required")
        }
        return string
    }

    private static func optionalString(
        _ value: any ProviderPluginValue,
        property: String,
        path: String) throws -> String?
    {
        guard let propertyValue = value.property(property),
              !propertyValue.isUndefined,
              !propertyValue.isNull
        else { return nil }
        guard propertyValue.isString else {
            throw ProviderPluginError.invalidSnapshot("\(path).\(property) must be a string")
        }
        let string = propertyValue.stringValue().trimmingCharacters(in: .whitespacesAndNewlines)
        guard string.utf8.count <= self.maximumStringBytes else {
            throw ProviderPluginError.invalidSnapshot(
                "\(path).\(property) exceeds \(self.maximumStringBytes) UTF-8 bytes")
        }
        return string.isEmpty ? nil : string
    }

    private static func optionalDate(
        _ value: any ProviderPluginValue,
        property: String,
        path: String = "snapshot") throws -> Date?
    {
        guard let propertyValue = value.property(property),
              !propertyValue.isUndefined,
              !propertyValue.isNull
        else { return nil }
        if propertyValue.isDate, let date = propertyValue.dateValue() {
            return date
        }
        guard propertyValue.isString else {
            throw ProviderPluginError.invalidSnapshot("\(path).\(property) must be a Date or ISO-8601 string")
        }
        let text = propertyValue.stringValue()
        guard let date = ISO8601DateParser.parse(text) else {
            throw ProviderPluginError.invalidSnapshot("\(path).\(property) is not a valid ISO-8601 date")
        }
        return date
    }
}

extension ProviderPluginSnapshotMapper {
    /// A standalone wallet has an explicit unit but no measured spending or allowance. Do not parse display text,
    /// assume credits are dollars, or turn its available balance into a fabricated used/limit pair.
    fileprivate static func balance(_ root: any ProviderPluginValue, now: Date) throws -> ProviderCostSnapshot? {
        guard let value = root.property("balance"), !value.isUndefined else { return nil }
        if value.isNull {
            // A successful unavailable wallet observation breaks continuity without asserting any denomination.
            return ProviderCostSnapshot(
                used: 0,
                limit: 0,
                currencyCode: "XXX",
                balanceUpdatedAt: now,
                usageIsUnavailable: true,
                updatedAt: now)
        }
        guard value.isObject, !value.isArray else {
            throw ProviderPluginError.invalidSnapshot("balance must be an object")
        }
        try self.object(value, allowed: ["value", "unit", "updatedAt", "isWorkspace"], path: "balance")
        let amount = try self.requiredFiniteNumber(value, property: "value", path: "balance")
        let unit = try self.requiredString(value, property: "unit", path: "balance")
        guard !unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              unit.utf8.count <= 64,
              unit.rangeOfCharacter(from: .controlCharacters) == nil
        else {
            throw ProviderPluginError.invalidSnapshot("balance.unit must be a nonempty unit without control characters")
        }
        let observedAt = try self.optionalDate(value, property: "updatedAt", path: "balance") ?? now
        guard observedAt <= now else {
            throw ProviderPluginError.invalidSnapshot("balance.updatedAt cannot be in the future")
        }
        let workspace = try self.optionalBoolean(value, property: "isWorkspace", path: "balance")
        return ProviderCostSnapshot(
            used: 0,
            limit: 0,
            currencyCode: unit,
            balance: amount,
            balanceUpdatedAt: observedAt,
            balanceIsWorkspace: workspace,
            usageIsUnavailable: true,
            updatedAt: now)
    }
}

extension ProviderPluginSnapshotMapper {
    private struct CostUsageParsedEntry {
        let date: String
        let inputTokens: Int?
        let outputTokens: Int?
        let reasoningTokens: Int?
        let totalTokens: Int?
        let requests: Int?
        let cost: Double?
        let estimatedCost: Double
        let hasEstimatedCost: Bool
        let model: String?
    }

    private struct CostUsageAccumulator {
        var inputTokens: Int? = 0
        var outputTokens: Int? = 0
        var reasoningTokens = 0
        var hasReasoningTokens = false
        var totalTokens: Int? = 0
        var requests: Int? = 0
        var cost: Double? = 0
        var estimatedCost = 0.0
        var estimatedRequests: Int? = 0
        var knownCost = 0.0
        var hasCost = false
        var hasMissingCost = false
    }

    private struct CostUsageAggregation {
        let daily: [CostUsageDailyReport.Entry]
        let totalTokens: Int?
        let totalRequests: Int?
        let totalCost: Double?
    }
}
