import Foundation

/// One cache decode or transcript scan owns each pool.
final class CostUsageRowStringPool: @unchecked Sendable {
    static let key = CodingUserInfoKey(rawValue: "costUsageRowStringPool")!
    private let lock = NSLock()
    private var strings: [Data: String] = [:]

    func intern(_ value: String) -> String {
        // Small strings store their bytes inline; pooling them only grows the temporary index.
        guard value.utf8.count > 15 else { return value }
        return self.lock.withLock {
            // String equality folds NFC/NFD spellings; artifact bytes must remain exact.
            let key = Data(value.utf8)
            if let existing = self.strings[key] { return existing }
            var shared = value
            shared.makeContiguousUTF8()
            self.strings[key] = shared
            return shared
        }
    }
}

extension CostUsageScanner.ClaudeUsageRow {
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let pool = decoder.userInfo[CostUsageRowStringPool.key] as? CostUsageRowStringPool
        self.dayKey = try values.decode(String.self, forKey: .dayKey)
        let model = try values.decode(String.self, forKey: .model)
        self.model = pool?.intern(model) ?? model
        self.sessionId = try values.decodeIfPresent(String.self, forKey: .sessionId).map { pool?.intern($0) ?? $0 }
        self.messageId = try values.decodeIfPresent(String.self, forKey: .messageId)
        self.requestId = try values.decodeIfPresent(String.self, forKey: .requestId)
        self.timestampUnixMs = try values.decodeIfPresent(Int64.self, forKey: .timestampUnixMs)
        self.isSidechain = try values.decode(Bool.self, forKey: .isSidechain)
        self.pathRole = try values.decode(CostUsageScanner.ClaudePathRole.self, forKey: .pathRole)
        self.input = try values.decode(Int.self, forKey: .input)
        self.cacheRead = try values.decode(Int.self, forKey: .cacheRead)
        self.cacheCreate = try values.decode(Int.self, forKey: .cacheCreate)
        self.cacheCreate1h = try values.decodeIfPresent(Int.self, forKey: .cacheCreate1h)
        self.output = try values.decode(Int.self, forKey: .output)
        self.costNanos = try values.decode(Int.self, forKey: .costNanos)
        self.costPriced = try values.decodeIfPresent(Bool.self, forKey: .costPriced)
        self.isIncomplete = try values.decodeIfPresent(Bool.self, forKey: .isIncomplete)
        self.organizationID = try values.decodeIfPresent(String.self, forKey: .organizationID)
            .map { pool?.intern($0) ?? $0 }
    }
}

extension KeyedDecodingContainer {
    /// Synthesis selects this overload for retained Claude rows; keep optional-key semantics unchanged.
    func decodeIfPresent(
        _ type: [CostUsageScanner.ClaudeUsageRow].Type,
        forKey key: Key) throws -> [CostUsageScanner.ClaudeUsageRow]?
    {
        guard self.contains(key), try !self.decodeNil(forKey: key) else { return nil }
        var values = try self.nestedUnkeyedContainer(forKey: key)
        var rows: [CostUsageScanner.ClaudeUsageRow] = []
        rows.reserveCapacity(values.count ?? 0)
        while !values.isAtEnd {
            try rows.append(values.decode(CostUsageScanner.ClaudeUsageRow.self))
        }
        return rows
    }
}

/// The same transcripts are kept in two artifacts, one for each report window, and each row carries two request
/// ids of about thirty bytes that no string can hold inline. Decoded separately those ids alone came to more than
/// a hundred megabytes twice over. The second artifact decoded takes its strings from the first.
final class CostUsageClaudeRowDonors: @unchecked Sendable {
    static let key = CodingUserInfoKey(rawValue: "costUsageClaudeRowDonors")!
    private let files: [[String: CostUsageClaudeCache.File]]

    init(_ files: [[String: CostUsageClaudeCache.File]]) {
        self.files = files
    }

    /// `rows` with every long string replaced by the byte-identical one the donor transcript at `path` holds.
    func sharing(_ rows: [CostUsageScanner.ClaudeUsageRow], path: String) -> [CostUsageScanner.ClaudeUsageRow] {
        guard !rows.isEmpty,
              let donor = self.files.lazy.compactMap({ $0[path]?.usage?.claudeRows }).first(where: { !$0.isEmpty })
        else { return rows }
        var known: [String: String] = [:]
        known.reserveCapacity(donor.count * 2 + 8)
        func offer(_ value: String?) {
            // Small strings store their bytes inline; there is nothing to share.
            if let value, value.utf8.count > 15 { known[value] = value }
        }
        for row in donor {
            offer(row.messageId)
            offer(row.requestId)
            offer(row.sessionId)
            offer(row.organizationID)
            offer(row.model)
        }
        func shared(_ value: String?) -> String? {
            // String equality folds NFC/NFD spellings; artifact bytes must remain exact.
            guard let value, value.utf8.count > 15, let donated = known[value],
                  donated.utf8.elementsEqual(value.utf8) else { return value }
            return donated
        }
        return rows.map { row in
            CostUsageScanner.ClaudeUsageRow(
                dayKey: row.dayKey,
                model: shared(row.model) ?? row.model,
                sessionId: shared(row.sessionId),
                messageId: shared(row.messageId),
                requestId: shared(row.requestId),
                timestampUnixMs: row.timestampUnixMs,
                isSidechain: row.isSidechain,
                pathRole: row.pathRole,
                input: row.input,
                cacheRead: row.cacheRead,
                cacheCreate: row.cacheCreate,
                cacheCreate1h: row.cacheCreate1h,
                output: row.output,
                costNanos: row.costNanos,
                costPriced: row.costPriced,
                isIncomplete: row.isIncomplete,
                organizationID: shared(row.organizationID))
        }
    }
}
