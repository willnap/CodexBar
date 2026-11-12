import Foundation

extension ProviderPluginSnapshotMapper {
    /// `resets`: the limit resets the account holds or has used. Each is `{ available, expiresAt?, usedAt?,
    /// grantedAt?, clears?, givesBackWiderUsage?, label? }`, where `clears` lists the ids of the windows it clears
    /// (`primary`, `secondary`, `tertiary` or an extra window's id) and is left out for a reset that clears
    /// everything.
    static func resets(_ root: any ProviderPluginValue, now: Date) throws -> ProviderResetInventory? {
        guard let value = root.property("resets"), !value.isUndefined, !value.isNull else { return nil }
        guard value.isArray else {
            throw ProviderPluginError.invalidSnapshot("resets must be an array")
        }
        let count = try self.boundedArrayCount(value, maximum: ProviderResetInventory.maximumResets, path: "resets")
        let resets = try (0..<count).map { index -> ProviderReset in
            let path = "resets[\(index)]"
            guard let item = value.element(at: index), item.isObject, !item.isArray else {
                throw ProviderPluginError.invalidSnapshot("\(path) must be an object")
            }
            try self.object(
                item,
                allowed: ["available", "expiresAt", "usedAt", "grantedAt", "clears", "givesBackWiderUsage", "label"],
                path: path)
            guard let available = item.property("available"), available.isBoolean else {
                throw ProviderPluginError.invalidSnapshot("\(path).available must be a boolean")
            }
            return try ProviderReset(
                isAvailable: available.boolValue(),
                expiresAt: self.resetDate(item, "expiresAt", path: path),
                usedAt: self.resetDate(item, "usedAt", path: path),
                grantedAt: self.resetDate(item, "grantedAt", path: path),
                scope: self.resetScope(item, path: path),
                givesBackWiderUsage: self.resetFlag(item, "givesBackWiderUsage", path: path),
                label: self.resetLabel(item, path: path))
        }
        return ProviderResetInventory(resets: resets, updatedAt: now)
    }

    private static func present(_ item: any ProviderPluginValue, _ property: String) -> (any ProviderPluginValue)? {
        guard let value = item.property(property), !value.isUndefined, !value.isNull else { return nil }
        return value
    }

    private static func resetScope(_ item: any ProviderPluginValue, path: String) throws -> ProviderReset.Scope {
        guard let clears = self.present(item, "clears") else { return .everything }
        guard clears.isArray else {
            throw ProviderPluginError.invalidSnapshot("\(path).clears must be an array of window ids")
        }
        let ids = try (0..<self.boundedArrayCount(clears, maximum: 16, path: "\(path).clears")).map { entry in
            guard let id = clears.element(at: entry), id.isString, !id.stringValue().isEmpty,
                  id.stringValue().utf8.count <= 128
            else { throw ProviderPluginError.invalidSnapshot("\(path).clears[\(entry)] must be a window id") }
            return id.stringValue()
        }
        return ids.isEmpty ? .everything : .windows(ids)
    }

    private static func resetDate(_ item: any ProviderPluginValue, _ property: String, path: String) throws -> Date? {
        guard let value = self.present(item, property) else { return nil }
        if value.isDate, let date = value.dateValue() { return date }
        guard value.isString, let date = ISO8601DateParser.parse(value.stringValue()) else {
            throw ProviderPluginError.invalidSnapshot("\(path).\(property) must be a Date or ISO-8601 string")
        }
        return date
    }

    private static func resetFlag(_ item: any ProviderPluginValue, _ property: String, path: String) throws -> Bool {
        guard let value = self.present(item, property) else { return false }
        guard value.isBoolean else {
            throw ProviderPluginError.invalidSnapshot("\(path).\(property) must be a boolean")
        }
        return value.boolValue()
    }

    private static func resetLabel(_ item: any ProviderPluginValue, path: String) throws -> String? {
        guard let value = self.present(item, "label") else { return nil }
        guard value.isString, value.stringValue().utf8.count <= 256 else {
            throw ProviderPluginError.invalidSnapshot("\(path).label must be a string of at most 256 bytes")
        }
        return value.stringValue()
    }
}
