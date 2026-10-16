import AppKit
import CryptoKit
import Foundation
import FoundationModels

@Generable
struct NativeOrbitBadgeAssignment {
    var badge: String
    /// A literal distinguishing substring from this account's label or email; empty for an ordinal fallback.
    var evidence: String
}

@Generable
private struct NativeOrbitAccountBadgeSet {
    var badges: [NativeOrbitBadgeAssignment]
}

struct NativeOrbitBadgeIdentity: Hashable, Sendable {
    let id: String
    let label: String
    let email: String?

    var text: String {
        "\(self.label)\n\(self.email ?? "")".lowercased()
    }

    var local: String {
        NativeOrbitBadgeModel.bounded(self.originalLocal.lowercased(), characters: 96, bytes: 256)
    }

    /// Preserve mailbox word boundaries for model input without changing normalized identity matching.
    var originalLocal: String {
        let prefix = NativeOrbitBadgeModel.bounded(self.email ?? "", characters: 96, bytes: 256)
        return prefix.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? ""
    }

    var domain: String? {
        guard let email = self.email, email.utf8.count <= 1024 else { return nil }
        let parts = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return NativeOrbitWebsiteIconDiscovery.normalizedDomain(String(parts[1])) ?? String(parts[1])
    }

    var literalLabel: String {
        // Fallback runs before model eligibility; bound input before regex matching or tokenization.
        var value = NativeOrbitBadgeModel.bounded(self.label, characters: 96, bytes: 256)
        // Account rows display one line. Hidden trailing metadata cannot identify the visible account.
        value = String(value.prefix { !$0.isNewline })
        if let email, !email.isEmpty, email.utf8.count <= 1024 {
            value = value.replacingOccurrences(of: email, with: self.local, options: .caseInsensitive)
        }
        return value.replacingOccurrences(
            of: #"([^\s@<>(),;]+)@[\p{L}\p{N}](?:[\p{L}\p{N}.-]*[\p{L}\p{N}])?"#,
            with: "$1",
            options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var hasExplicitLabel: Bool {
        let value = NativeOrbitBadgeModel.bounded(self.label, characters: 96, bytes: 256)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let email = NativeOrbitBadgeModel.bounded(self.email ?? "", characters: 96, bytes: 256)
        return !value.isEmpty && value.caseInsensitiveCompare(email) != .orderedSame
    }

    var words: Set<String> {
        Set((self.literalLabel + " " + self.local).lowercased()
            .split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }

    var aliasKey: String? {
        guard let range = local.range(of: #"[+._-](\d{1,2})$"#, options: .regularExpression),
              let number = Int(local[range].dropFirst()), (1...50).contains(number) else { return nil }
        return "number\(number)"
    }
}

/// Compare the whole account set. A symbol must describe a distinguishing clue, not simply be different artwork.
@MainActor
enum NativeOrbitBadgeResolver {
    struct ModelRetrySchedule {
        private var nextAttempts: [String: Date] = [:]

        func isDue(_ key: String, now: Date) -> Bool {
            (self.nextAttempts[key] ?? .distantPast) <= now
        }

        mutating func recordFailure(_ key: String, now: Date) {
            if self.nextAttempts.count >= 32 {
                self.nextAttempts = self.nextAttempts.filter { $0.value > now }
            }
            if self.nextAttempts.count >= 32, self.nextAttempts[key] == nil,
               let oldest = nextAttempts.min(by: { $0.value < $1.value })?.key
            {
                self.nextAttempts.removeValue(forKey: oldest)
            }
            self.nextAttempts[key] = now.addingTimeInterval(300)
        }
    }

    struct WebsiteModelInput {
        let metadata: String
        let preview: CGImage?
    }

    private static func websiteModelMetadata(_ contexts: [NativeOrbitWebsiteIconStore.ModelContext]) throws -> String {
        let records = contexts.enumerated().map { index, context in
            [
                "key": String(context.key.prefix(96)),
                "previewLabel": "W\(index + 1)",
                "domain": String(context.domain.prefix(253)),
                "siteName": String((context.siteName ?? "").prefix(96)),
                "sourceHost": String((context.source.host ?? "").prefix(253)),
                "method": String(context.method.prefix(64)),
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: records, options: [.sortedKeys])
        guard let metadata = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadCorruptFile) }
        return metadata
    }

    static func websiteModelInput(_ contexts: [NativeOrbitWebsiteIconStore.ModelContext]) throws -> WebsiteModelInput {
        guard contexts.count <= 24 else { throw CocoaError(.fileReadCorruptFile) }
        let metadata = try websiteModelMetadata(contexts)
        guard !contexts.isEmpty else { return WebsiteModelInput(metadata: metadata, preview: nil) }
        let columns = min(4, contexts.count)
        let rows = (contexts.count + columns - 1) / columns
        let width = columns * 80
        let height = rows * 100
        guard let canvas = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw CocoaError(.fileReadCorruptFile) }
        canvas.setFillColor(CGColor(gray: 1, alpha: 1))
        canvas.fill(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: canvas, flipped: false)
        for (index, context) in contexts.enumerated() {
            let x = (index % columns) * 80
            let y = (rows - 1 - index / columns) * 100
            canvas.draw(context.cgImage, in: CGRect(x: x + 8, y: y + 28, width: 64, height: 64))
            ("W\(index + 1)" as NSString).draw(at: NSPoint(x: x + 26, y: y + 6), withAttributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.black,
            ])
        }
        guard let preview = canvas.makeImage() else { throw CocoaError(.fileReadCorruptFile) }
        return WebsiteModelInput(metadata: metadata, preview: preview)
    }

    static var websiteIconsForTesting: NativeOrbitWebsiteIconStore?
    static var websiteIcons: NativeOrbitWebsiteIconStore {
        websiteIconsForTesting ?? .shared
    }

    static func shouldResolve(_ accounts: [NativeOrbitAccountPresentation], previousKey: String?) -> Bool {
        let key = self.identityKey(accounts)
        if key != previousKey {
            return true
        }
        guard !SettingsStore.isRunningTests || self.websiteIconsForTesting != nil else { return false }
        if self.websiteIcons.needsRefresh(domains: self.websiteDomains(accounts)) {
            return true
        }
        return !SettingsStore.isRunningTests && self.modelEligible(accounts) && self.cache[key] == nil
            && self.pending[key] == nil && self.retrySchedule.isDue(key, now: Date())
    }

    static func websiteDomains(_ accounts: [NativeOrbitAccountPresentation]) -> [String] {
        let identities = self.identities(accounts)
        let known = Set(available.filter { $0.kind == .mail }.flatMap(\.domains))
        return identities.compactMap { identity in
            guard !self.isAnonymous(identity.label, accountCount: accounts.count), let domain = identity.domain,
                  NativeOrbitWebsiteIconDiscovery.normalizedDomain(domain) == domain,
                  !known.contains(domain), identities.filter({ $0.domain == domain }).count == 1 else { return nil }
            return domain
        }.sorted()
    }

    private static var cache: [String: [String: String]] = [:]
    private static var pending: [String: Task<Refinement?, Never>] = [:]
    private static var retrySchedule = ModelRetrySchedule()
    private static let defaultsKey = "nativeOrbitAccountBadges.v31"
    private static let available: [NativeOrbitBadgeCatalog.Entry] = {
        let original = Set(NativeOrbitBadgeCatalog.all.map(\.key))
        return (NativeOrbitBadgeCatalog.all + NativeOrbitBadgeVocabulary.entries.filter { !original.contains($0.key) })
            .filter { $0.isCustom || NSImage(systemSymbolName: $0.symbol, accessibilityDescription: nil) != nil }
    }()

    struct Refinement {
        let badges: [String: String]
        let complete: Bool
        var accepted: [String: String] = [:]
        var failed: Set<String> = []
    }

    private static var partialCache: [String: Refinement] = [:]

    static func identityKey(_ accounts: [NativeOrbitAccountPresentation]) -> String {
        let identities = self.identities(accounts)
        var records = identities.map { [$0.id, $0.label, $0.email ?? ""] }
        records += self.websiteEntries(identities).map { [$0.key, $0.symbol] }
        if !SettingsStore.isRunningTests || self.websiteIconsForTesting != nil {
            let contexts = self.websiteContexts(identities)
            records += contexts.map { [$0.key, $0.fingerprint] }
            records.append(["websiteMetadata", (try? self.websiteModelMetadata(contexts)) ?? ""])
        }
        records.append(["modelPolicy", self.supportsWebsitePreviews ? "v31-vision" : "v31-text"])
        records.append(["intentModel", NativeOrbitBadgeModel.intentPolicy])
        records.append(["modelOS", ProcessInfo.processInfo.operatingSystemVersionString])
        records.append(["vocabulary", NativeOrbitBadgeVocabulary.version])
        let data = (try? JSONSerialization.data(withJSONObject: records)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func initialBadges(_ accounts: [NativeOrbitAccountPresentation]) -> [String: String] {
        guard Set(accounts.map(\.id)).count == accounts.count else { return [:] }
        let key = self.identityKey(accounts)
        if let cached = cache[key] {
            return cached
        }
        if !SettingsStore.isRunningTests,
           let stored = UserDefaults.standard.dictionary(forKey: defaultsKey)?[key] as? [String: String],
           stored.count == accounts.count,
           Set(stored.values).count == stored.count,
           stored.values.allSatisfy({ self.validSymbols(accounts).contains($0) })
        {
            let resolved = Dictionary(uniqueKeysWithValues: accounts.compactMap { account -> (String, String)? in
                stored[self.digest(account.id)].map { (account.id, $0) }
            })
            if resolved.count == accounts.count {
                self.cache[key] = resolved
                return resolved
            }
        }
        if let partial = partialCache[key] {
            return partial.badges
        }
        return self.fallback(self.identities(accounts))
    }

    static func resolve(_ state: NativeOrbitPopupState) async {
        let accounts = state.accounts
        state.badges = Self.initialBadges(accounts)
        // The first frame stays immediate. Only public, distinguishing unknown domains are fetched.
        if !SettingsStore.isRunningTests || Self.websiteIconsForTesting != nil {
            await Self.websiteIcons.refresh(domains: Self.websiteDomains(accounts))
        }
        guard !Task.isCancelled, Self.identities(state.accounts) == Self.identities(accounts) else { return }
        let key = Self.identityKey(accounts)
        if let cached = Self.cache[key] {
            state.badges = cached
            return
        }
        state.badges = Self.initialBadges(accounts)
        // Anonymous labels deliberately suppress email-derived identity, including model inference.
        guard !SettingsStore.isRunningTests, Self.modelEligible(accounts) else { return }
        guard SystemLanguageModel.default.isAvailable else {
            Self.retrySchedule.recordFailure(key, now: Date())
            return
        }
        let task: Task<Refinement?, Never>
        if let existing = Self.pending[key] {
            task = existing
        } else {
            task = Task { await Self.refine(accounts) }
            Self.pending[key] = task
        }
        let attempt = await task.value
        Self.pending[key] = nil
        // A temporarily unavailable model must not permanently cache an ordinal fallback as a model choice.
        guard let attempt else {
            Self.retrySchedule.recordFailure(key, now: Date())
            return
        }
        let resolved = Self.retainingSuccesses(Self.partialCache[key], incoming: attempt, accounts: accounts)
        if resolved.complete {
            if Self.cache.count >= 32 {
                Self.cache.removeAll(keepingCapacity: true)
            }
            Self.cache[key] = resolved.badges
            Self.partialCache[key] = nil
            var persisted = UserDefaults.standard.dictionary(forKey: Self.defaultsKey) ?? [:]
            if persisted.count >= 32 {
                persisted.removeAll(keepingCapacity: true)
            }
            persisted[key] = Dictionary(uniqueKeysWithValues: resolved.badges.map { (Self.digest($0.key), $0.value) })
            UserDefaults.standard.set(persisted, forKey: Self.defaultsKey)
        } else {
            if Self.partialCache.count >= 32 {
                Self.partialCache.removeAll(keepingCapacity: true)
            }
            Self.partialCache[key] = resolved
            Self.retrySchedule.recordFailure(key, now: Date())
        }
        guard !Task.isCancelled, Self.identityKey(state.accounts) == key else { return }
        state.badges = resolved.badges
    }

    /// Runtime schema excludes mail brands and initials shared by this comparison set.
    static func choiceKeys(_ accounts: [NativeOrbitAccountPresentation]) -> Set<String> {
        guard Set(accounts.map(\.id)).count == accounts.count else { return [] }
        return Set(self.choices(self.identities(accounts)).map(\.key))
    }

    /// Validate model output against the actual comparison, before caching or displaying any of it.
    static func validatedBadges(
        _ assignments: [NativeOrbitBadgeAssignment],
        for accounts: [NativeOrbitAccountPresentation]) -> [String: String]?
    {
        let identities = self.identities(accounts)
        guard assignments.count == identities.count, Set(identities.map(\.id)).count == identities.count,
              !identities.contains(where: { self.isAnonymous($0.label, accountCount: identities.count) })
        else { return nil }
        let offered = Dictionary(uniqueKeysWithValues: choices(identities).map { ($0.key, $0) })
        let fallback = self.fallback(identities)
        var result: [String: String] = [:]
        var used = Set<String>()
        for (identity, assignment) in zip(identities, assignments) {
            guard let entry = offered[assignment.badge], used.insert(entry.symbol).inserted else { return nil }
            if entry.kind == .number {
                let uniqueAlias = entry.key == identity.aliasKey &&
                    identities.filter { $0.aliasKey == entry.key }.count == 1
                guard uniqueAlias || fallback[identity.id] == entry.symbol else { return nil }
            } else {
                let evidence = assignment.evidence.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard (1...80).contains(evidence.count), evidence.contains(where: { $0.isLetter || $0.isNumber }),
                      identity.text.contains(evidence),
                      !identities.contains(where: { $0.id != identity.id && $0.text.contains(evidence) })
                else { return nil }
                if entry.kind == .mail {
                    guard entry.domains.contains(identity.domain ?? "") else { return nil }
                } else if entry.kind == .letter {
                    guard entry.key == self.initialKeys(identities)[identity.id] else { return nil }
                } else {
                    // Require the cited evidence to actually suggest this icon. A unique username cannot
                    // justify an arbitrary animal, interest or personal trait.
                    let evidenceWords = Set(evidence.split { !$0.isLetter && !$0.isNumber }.map(String.init))
                    guard !Set(entry.clues).isDisjoint(with: evidenceWords),
                          !Set(entry.clues).isDisjoint(with: identity.words),
                          identities.filter({ !Set(entry.clues).isDisjoint(with: $0.words) }).count == 1
                    else { return nil }
                }
            }
            result[identity.id] = entry.symbol
        }
        return result
    }

    private static func initialKeys(_ identities: [NativeOrbitBadgeIdentity]) -> [String: String] {
        guard Set(identities.map(\.id)).count == identities.count else { return [:] }
        let visible = identities.filter { !self.isAnonymous($0.label, accountCount: identities.count) }
        func key(_ text: String) -> String? {
            let bounded = NativeOrbitBadgeModel.bounded(text, characters: 96, bytes: 256)
            guard let first = bounded.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().first,
                  ("a"..."z").contains(String(first)) else { return nil }
            return "letter" + String(first).uppercased()
        }
        let sources = Dictionary(uniqueKeysWithValues: visible.map {
            (
                $0.id,
                $0.hasExplicitLabel
                    ? $0.literalLabel : NativeOrbitBadgeModel.bounded($0.local, characters: 96, bytes: 256))
        })
        let primary = Dictionary(uniqueKeysWithValues: visible.compactMap { identity in
            key(sources[identity.id, default: ""]).map { (identity.id, $0) }
        })
        let counts = Dictionary(grouping: primary.values, by: { $0 }).mapValues(\.count)
        var result = primary.filter { counts[$0.value] == 1 }
        var used = Set(result.values)
        let words = sources.mapValues { $0.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init) }
        let wordCounts = Dictionary(grouping: words.values.flatMap { Set($0) }, by: { $0 }).mapValues(\.count)
        let options = words.mapValues { values in values.filter { wordCounts[$0] == 1 }.compactMap(key) }
        let letterCounts = Dictionary(grouping: options.values.flatMap { Set($0) }, by: { $0 }).mapValues(\.count)
        let localCounts = Dictionary(grouping: visible.compactMap { key($0.local) }, by: { $0 }).mapValues(\.count)
        for identity in visible where result[identity.id] == nil {
            if let selected = options[identity.id, default: []]
                .first(where: { letterCounts[$0] == 1 && !used.contains($0) })
            {
                result[identity.id] = selected
                used.insert(selected)
            } else if let selected = key(identity.local), localCounts[selected] == 1, !used.contains(selected) {
                result[identity.id] = selected
                used.insert(selected)
            }
        }
        return result
    }

    private static func choices(_ identities: [NativeOrbitBadgeIdentity]) -> [NativeOrbitBadgeCatalog.Entry] {
        let explicitNumbers = Set(identities.compactMap(\.aliasKey))
        let initials = self.initialKeys(identities)
        return (self.available + self.websiteEntries(identities)).filter { entry in
            switch entry.kind {
            case .mail:
                identities.filter { entry.domains.contains($0.domain ?? "") }.count == 1
            case .letter:
                initials.values.contains(entry.key)
            case .number:
                explicitNumbers.contains(entry.key) || (Int(entry.title) ?? 0) <= identities.count
            case .meaning:
                true
            }
        }
    }

    private static func websiteEntries(_ identities: [NativeOrbitBadgeIdentity]) -> [NativeOrbitBadgeCatalog.Entry] {
        guard !SettingsStore.isRunningTests || self.websiteIconsForTesting != nil else { return [] }
        let known = Set(available.filter { $0.kind == .mail }.flatMap(\.domains))
        return self.websiteIcons.entries(for: identities.compactMap(\.domain).filter { !known.contains($0) })
    }

    private static func websiteContexts(_ identities: [NativeOrbitBadgeIdentity])
        -> [NativeOrbitWebsiteIconStore.ModelContext]
    {
        self.websiteIcons.modelContexts(for: self.websiteEntries(identities).flatMap(\.domains))
    }

    private static var supportsWebsitePreviews: Bool {
        if #available(macOS 27.0, *) {
            return SystemLanguageModel.default.capabilities.contains(.vision)
        }
        return false
    }

    static func modelEligible(_ accounts: [NativeOrbitAccountPresentation]) -> Bool {
        (2...24).contains(accounts.count) && Set(accounts.map(\.id)).count == accounts.count
            && accounts.allSatisfy { $0.label.utf8.count <= 4096 && ($0.email?.utf8.count ?? 0) <= 1024 }
            && accounts.contains { !self.isAnonymous($0.label, accountCount: accounts.count) }
    }

    private static func validSymbols(_ accounts: [NativeOrbitAccountPresentation]) -> Set<String> {
        Set(self.available.map(\.symbol)).union(self.websiteEntries(self.identities(accounts)).map(\.symbol))
    }

    static func modelAccounts(_ accounts: [NativeOrbitAccountPresentation]) -> [NativeOrbitBadgeModel.Account] {
        guard Set(accounts.map(\.id)).count == accounts.count else { return [] }
        let identities = self.identities(accounts)
        let brands = self.choices(identities).filter { $0.kind == .mail }
        let contexts = self.websiteContexts(identities)
        return identities.map { identity in
            let anonymous = self.isAnonymous(identity.label, accountCount: identities.count)
            let label = identity.literalLabel
            let text = anonymous ? "" : label + "\n" + identity.originalLocal
            var brand: NativeOrbitBadgeModel.Brand?
            if !anonymous, let domain = identity.domain,
               let entry = brands.first(where: { $0.domains.contains(domain) })
            {
                let website = try? self.websiteModelInput(contexts.filter { $0.domain == domain })
                brand = .init(
                    entry: entry,
                    domain: domain,
                    metadata: website?.metadata ?? "Built-in mail provider symbol",
                    preview: website?.preview)
            }
            return .init(
                id: identity.id,
                text: text,
                label: anonymous ? "" : label,
                alias: anonymous ? "" : identity.originalLocal,
                brand: brand)
        }
    }

    /// Keep independently useful choices; one rejected or failed account must not discard its peers' answers.
    static func mergedBadges(
        _ proposals: [NativeOrbitBadgeModel.Proposal],
        for accounts: [NativeOrbitAccountPresentation],
        purposes: [String: String] = [:]) -> [String: String]
    {
        let identities = self.identities(accounts)
        guard Set(identities.map(\.id)).count == identities.count else { return [:] }
        let contexts = Dictionary(uniqueKeysWithValues: modelAccounts(accounts).map { ($0.id, $0) })
        let offered = Dictionary(uniqueKeysWithValues: choices(identities).map { ($0.key, $0) })
        let counts = Dictionary(grouping: proposals, by: \.accountID).mapValues(\.count)
        let valid = proposals.filter { proposal in
            guard counts[proposal.accountID] == 1, let context = contexts[proposal.accountID],
                  let entry = offered[proposal.key], entry.symbol == proposal.symbol,
                  !self.isAnonymous(context.text, accountCount: identities.count),
                  (1...80).contains(proposal.evidence.count),
                  proposal.evidence.contains(where: { $0.isLetter || $0.isNumber })
            else { return false }
            if entry.kind == .mail {
                return context.brand?.entry.key == entry.key && context.brand?.domain == proposal.evidence
            }
            let source = purposes.isEmpty ? context.text : (purposes[context.id] ?? "")
            let peers = contexts.values.filter { $0.id != context.id }.map {
                purposes.isEmpty ? $0.text : NativeOrbitBadgeModel.peerSource($0, selected: purposes[$0.id])
            }
            if let meaning = purposes[context.id], !meaning.isEmpty,
               peers.contains(where: {
                   NativeOrbitBadgeSearch.comparisonWords($0) == NativeOrbitBadgeSearch.comparisonWords(meaning)
               }) { return false }
            guard entry.kind == .meaning,
                  NativeOrbitBadgeModel.candidateKeys(
                      for: context,
                      peers: peers,
                      source: source,
                      query: proposal.searchQuery)
                      .contains(entry.key),
                      context.text.lowercased().contains(proposal.evidence.lowercased())
            else {
                return false
            }
            let meaning = NativeOrbitBadgeVocabulary.entries.first { $0.key == entry.key } ?? entry
            guard NativeOrbitBadgeSearch.isDistinctCandidate(meaning, source: source, peers: peers) else {
                return false
            }
            return !peers.contains { $0.lowercased().contains(proposal.evidence.lowercased()) }
        }
        let families = Dictionary(grouping: valid, by: { self.visualFamily($0.symbol) }).mapValues(\.count)
        let distinct = valid.filter { families[self.visualFamily($0.symbol)] == 1 }
        var result = Dictionary(uniqueKeysWithValues: distinct.map { ($0.accountID, $0.symbol) })
        let fallback = self.fallback(
            identities,
            reserving: Set(result.values),
            excluding: Set(result.keys),
            allowProviderMarks: false)
        result.merge(fallback) { current, _ in current }
        return result
    }

    private static func visualFamily(_ symbol: String) -> String {
        var value = NativeOrbitBadgeSearch.canonicalArtworkSymbol(symbol)
        for suffix in [".fill", ".circle", ".square"] where value.hasSuffix(suffix) {
            value.removeLast(suffix.count)
        }
        return value
    }

    private static func refine(_ accounts: [NativeOrbitAccountPresentation]) async -> Refinement? {
        guard self.modelEligible(accounts) else { return nil }
        let output = await NativeOrbitBadgeModel.select(self.modelAccounts(accounts))
        guard !output.cancelled, !Task.isCancelled else { return nil }
        let badges = self.mergedBadges(output.proposals, for: accounts, purposes: output.purposes)
        let accepted = Dictionary(uniqueKeysWithValues: output.proposals.compactMap { proposal -> (String, String)? in
            badges[proposal.accountID] == proposal.symbol ? (proposal.accountID, proposal.symbol) : nil
        })
        return Refinement(
            badges: badges,
            complete: output.complete,
            accepted: accepted,
            failed: Set(output.errors.keys))
    }

    static func retainingSuccesses(
        _ previous: Refinement?, incoming: Refinement, accounts: [NativeOrbitAccountPresentation]) -> Refinement
    {
        guard !incoming.complete, let previous else { return incoming }
        let ids = Set(accounts.map(\.id))
        var accepted = incoming.accepted
        for (id, symbol) in previous.accepted where incoming.failed.contains(id) && ids.contains(id) {
            accepted[id] = symbol
        }
        let families = Dictionary(grouping: accepted.values, by: self.visualFamily).mapValues(\.count)
        accepted = accepted.filter { families[self.visualFamily($0.value)] == 1 }
        var badges = self.fallback(
            self.identities(accounts),
            reserving: Set(accepted.values),
            excluding: Set(accepted.keys),
            allowProviderMarks: false)
        badges.merge(accepted) { _, selected in selected }
        return Refinement(badges: badges, complete: false, accepted: accepted, failed: incoming.failed)
    }

    private static func fallback(
        _ identities: [NativeOrbitBadgeIdentity],
        reserving symbols: Set<String> = [],
        excluding accountIDs: Set<String> = [],
        allowProviderMarks: Bool = true) -> [String: String]
    {
        let visible = identities.filter { !self.isAnonymous($0.label, accountCount: identities.count) }
        let choices = self.choices(identities)
        var result: [String: String] = [:]
        var used = symbols
        let anonymous = identities.filter { self.isAnonymous($0.label, accountCount: identities.count) }
        let explicit = anonymous.compactMap { identity -> (String, String)? in
            guard let range = identity.label.range(of: #"\d+"#, options: .regularExpression),
                  let number = Int(identity.label[range]), (1...50).contains(number) else { return nil }
            return (identity.id, "number\(number)")
        }
        let numberCounts = Dictionary(grouping: explicit, by: { $0.1 }).mapValues(\.count)
        for (id, key) in explicit where !accountIDs.contains(id) && numberCounts[key] == 1 {
            if let entry = NativeOrbitBadgeCatalog.byKey[key], !used.contains(entry.symbol) {
                result[id] = entry.symbol
                used.insert(entry.symbol)
            }
        }
        let initials = self.initialKeys(identities)
        for identity in visible where !accountIDs.contains(identity.id) {
            var candidates: [NativeOrbitBadgeCatalog.Entry] = []
            if let alias = identity.aliasKey, visible.filter({ $0.aliasKey == alias }).count == 1,
               let entry = NativeOrbitBadgeCatalog.byKey[alias]
            {
                candidates.append(entry)
            }
            candidates += choices
                .filter { allowProviderMarks && $0.kind == .mail && $0.domains.contains(identity.domain ?? "") }
            candidates += choices.filter { $0.kind == .letter && $0.key == initials[identity.id] }
            if let entry = candidates.first(where: { !used.contains($0.symbol) }) {
                result[identity.id] = entry.symbol
                used.insert(entry.symbol)
            }
        }
        let ordinals = self.available.filter { $0.kind == .number || $0.kind == .letter }
        for identity in identities where result[identity.id] == nil && !accountIDs.contains(identity.id) {
            if let entry = ordinals.first(where: { !used.contains($0.symbol) }) {
                result[identity.id] = entry.symbol
                used.insert(entry.symbol)
            }
        }
        return result
    }

    private static func identities(_ accounts: [NativeOrbitAccountPresentation]) -> [NativeOrbitBadgeIdentity] {
        accounts.map { NativeOrbitBadgeIdentity(id: $0.id, label: $0.label, email: $0.email) }.sorted { $0.id < $1.id }
    }

    private static func digest(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func isAnonymous(_ label: String, accountCount: Int) -> Bool {
        let normalized = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.range(
            of: #"^account\s*\d+(?:\s|$|[·•:—-])"#,
            options: .regularExpression) != nil
        {
            return true
        }
        return (1...accountCount).contains { ordinal in
            let anonymous = L("Account %@", String(ordinal)).lowercased()
            return normalized == anonymous || normalized.hasPrefix(anonymous + " ·")
        }
    }
}
