import Foundation
import NaturalLanguage

/// Retrieves small, concrete choices without requiring the model to read the entire symbol inventory.
@MainActor
enum NativeOrbitBadgeSearch {
    struct Candidate {
        let entry: NativeOrbitBadgeCatalog.Entry
        let evidence: String
    }

    private struct ScoredCandidate {
        let index: Int
        let score: Double
        let coverage: Double
        let distinct: Bool
        let ownedContext: Bool
    }

    private static var tokenCache: [String: Set<String>] = [:]
    private static var canonicalCache: [String: String] = [:]
    private static var semanticWordCache: [String: Set<String>] = [:]
    private static var numberWordCache: [String: Bool] = [:]
    private static let identityModifiers: Set<String> = [
        "account", "mailbox", "email", "inbox", "login", "primary", "secondary", "main", "spare", "default",
        "alternative", "alternate", "alt", "other",
    ]
    private static let numberFormatters: [NumberFormatter] = [NumberFormatter.Style.spellOut, .ordinal].map { style in
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en")
        formatter.numberStyle = style
        return formatter
    }

    private static let purposeContext: Set<String> = [
        "account", "current", "purpose", "work", "personal", "family", "household", "research", "client",
        "project", "school", "club", "team", "group", "association", "admin", "administration", "storage",
        "document", "log", "lesson", "class", "studio", "weekend", "evening",
    ]

    /// Foundation's whole-string accent folding can reorder Indic marks; only Latin accents are expendable here.
    private static func foldedLatinDiacritics(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { $0.value > 127 }),
              let expression = try? NSRegularExpression(pattern: #"\p{Latin}\p{M}*"#) else { return text }
        var result = text
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in expression.matches(in: text, range: fullRange).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let folded = result[range].folding(
                options: .diacriticInsensitive,
                locale: Locale(identifier: "en_US_POSIX"))
            result.replaceSubrange(range, with: folded)
        }
        return result
    }

    /// Lemmatize each spelling independently, so sentence context and cache order cannot change its comparison form.
    private static func canonicalWord(_ word: String) -> String {
        if let cached = self.canonicalCache[word] { return cached }
        let tagger = NLTagger(tagSchemes: [.lemma])
        var current = word
        var visited = [word]
        for _ in 0..<8 {
            tagger.string = current
            tagger.setLanguage(.english, range: current.startIndex..<current.endIndex)
            let next = self.foldedLatinDiacritics(
                (tagger.tag(at: current.startIndex, unit: .word, scheme: .lemma).0?.rawValue ?? current).lowercased())
            guard next.count > 1, next.contains(where: \.isLetter), next != current else { break }
            if let cycle = visited.firstIndex(of: next) {
                current = visited[cycle...].min() ?? next
                break
            }
            visited.append(next)
            current = next
        }
        if self.canonicalCache.count >= 4096 { self.canonicalCache.removeAll(keepingCapacity: true) }
        self.canonicalCache[word] = current
        return current
    }

    /// A single Han/Hangul letter can be a complete subject, while ordinary initials and numeric glyphs are
    /// identifiers.
    nonisolated static func isSingleGlyphSubject(_ text: String) -> Bool {
        guard text.utf8.count <= 256, text.count == 1,
              let first = text.unicodeScalars.first,
              text.unicodeScalars.allSatisfy({ $0.properties.numericType == nil }) else { return false }
        switch first.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: break
        default: return false
        }
        return text.range(of: #"^[\p{Han}\p{Hangul}\p{M}]+$"#, options: .regularExpression) != nil
    }

    static func words(_ text: String) -> Set<String> {
        if let cached = tokenCache[text] {
            return cached
        }
        let normalized = self.foldedLatinDiacritics(text.replacingOccurrences(
            of: #"([a-z])([A-Z])"#, with: "$1 $2", options: .regularExpression).lowercased())
        let wordSource = normalized.replacingOccurrences(
            of: #"[^\p{L}\p{M}\p{N}]"#,
            with: " ",
            options: .regularExpression)
        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = wordSource
        tagger.setLanguage(.english, range: wordSource.startIndex..<wordSource.endIndex)
        var result = Set<String>()
        tagger.enumerateTags(
            in: wordSource.startIndex..<wordSource.endIndex,
            unit: .word,
            scheme: .lemma,
            options: [.omitWhitespace, .omitPunctuation])
        { _, range in
            let surface = String(wordSource[range])
            if surface.count > 1 || self.isSingleGlyphSubject(surface), surface.contains(where: \.isLetter) {
                result.insert(surface)
                result.insert(self.canonicalWord(surface))
            }
            return true
        }
        // Retain compound spellings as well as components (Wi-Fi/wifi, e-mail/email).
        if let expression = try? NSRegularExpression(pattern: #"\b\p{L}[\p{L}\p{M}]*(?:[-‐‑]\p{L}[\p{L}\p{M}]*)+\b"#) {
            let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
            for match in expression.matches(in: normalized, range: range) {
                guard let span = Range(match.range, in: normalized) else { continue }
                result.insert(normalized[span].filter(\.isLetter))
            }
        }
        if self.tokenCache.count > 4096 {
            self.tokenCache.removeAll(keepingCapacity: true)
        }
        self.tokenCache[text] = result
        return result
    }

    /// Use canonical forms for semantic equality; retrieval additionally retains exact surface spellings.
    static func comparisonWords(_ text: String) -> Set<String> {
        Set(self.words(text).map { self.canonicalWord($0) })
    }

    /// Semantic distinction ignores numeric/UI identity; retrieval retains every original word and compound.
    private static func semanticWords(_ text: String) -> Set<String> {
        if let cached = self.semanticWordCache[text] { return cached }
        var result = self.comparisonWords(text).subtracting(self.identityModifiers)
            .filter { !self.isNumberWord($0) }
        // words() also keeps collapsed hyphen compounds. Remove those only when the actual entire compound is numeric.
        let compounds = text.lowercased().split { !$0.isLetter && !$0.isNumber && !"-‐‑".contains($0) }
        for compound in compounds where compound.contains(where: { "-‐‑".contains($0) }) {
            let normalized = compound.map { "‐‑".contains($0) ? "-" : $0 }
            if self.isNumberWord(String(normalized)) {
                result.subtract(self.comparisonWords(String(compound)))
            }
        }
        if text.utf8.count <= 2048 {
            if self.semanticWordCache.count >= 4096 { self.semanticWordCache.removeAll(keepingCapacity: true) }
            self.semanticWordCache[text] = result
        }
        return result
    }

    private static func isNumberWord(_ word: String) -> Bool {
        if let cached = self.numberWordCache[word] { return cached }
        guard !word.isEmpty, word.utf8.count <= 64 else { return false }
        let fullRange = NSRange(location: 0, length: word.utf16.count)
        let numeric = self.numberFormatters.contains { formatter in
            var parsed: AnyObject?
            var range = fullRange
            do {
                try formatter.getObjectValue(&parsed, for: word, range: &range)
                guard let number = parsed as? NSNumber else { return false }
                let value = number.doubleValue
                return range == fullRange && value.isFinite && value >= 0 && value.rounded() == value
            } catch { return false }
        }
        if self.numberWordCache.count >= 2048 { self.numberWordCache.removeAll(keepingCapacity: true) }
        self.numberWordCache[word] = numeric
        return numeric
    }

    /// Pure cached wordsets allow the same shared-source guard before retrieval and per-candidate merger validation.
    private static func hasSemanticDifference(_ owned: Set<String>, peers: [String]) -> Bool {
        !owned.isEmpty && !peers.contains { owned.isSubset(of: self.semanticWords($0)) }
    }

    static func purposeWords(_ text: String) -> Set<String> {
        let all = self.comparisonWords(text)
        let concrete = all.subtracting(self.purposeContext)
        return concrete.isEmpty ? all : concrete
    }

    /// Only open-class words can request embedding recall; names and grammar are not purposes.
    private static func taggedWords(_ text: String)
        -> (content: Set<String>, names: Set<String>, personalNames: Set<String>)
    {
        let tagger = NLTagger(tagSchemes: [.lexicalClass, .nameType])
        tagger.string = text
        tagger.setLanguage(.english, range: text.startIndex..<text.endIndex)
        var result = (content: Set<String>(), names: Set<String>(), personalNames: Set<String>())
        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .word,
            scheme: .lexicalClass,
            options: [.omitWhitespace, .omitPunctuation])
        { tag, range in
            let name = tagger.tag(at: range.lowerBound, unit: .word, scheme: .nameType).0
            let words = self.words(String(text[range]))
            if [.personalName, .placeName, .organizationName].contains(name) {
                result.names.formUnion(words)
                if name == .personalName { result.personalNames.formUnion(words) }
            } else if [.noun, .verb, .adjective, .adverb].contains(tag) {
                result.content.formUnion(words)
            }
            return true
        }
        return result
    }

    /// These two installed symbols were visually verified to render the same indoor ergometer artwork.
    static func canonicalArtworkSymbol(_ symbol: String) -> String {
        symbol == "figure.indoor.rowing" ? "figure.rower" : symbol
    }

    private static func family(_ rawSymbol: String) -> String {
        let symbol = self.canonicalArtworkSymbol(rawSymbol)
        let parts = symbol.split(separator: ".")
        if parts.first == "figure" { return parts.prefix(2).joined(separator: ".") }
        if symbol.hasPrefix("account.") { return symbol }
        let decorations: Set<Substring> = ["fill", "circle", "square", "rectangle", "badge"]
        let end = parts.dropFirst().firstIndex(where: { decorations.contains($0) }) ?? parts.endIndex
        return parts[..<end].joined(separator: ".")
    }

    /// Prefer a direct glyph over an unmentioned subtype only when their lexical scores tie.
    private static func symbolCoverage(_ symbol: String, sourceWords: Set<String>) -> Double {
        let structural: Set = [
            "figure", "fill", "circle", "square", "rectangle", "badge", "crop", "inset", "outline", "and",
            "account", "project",
        ]
        let meaning = self.words(symbol.replacingOccurrences(of: ".", with: " ")).subtracting(structural)
        guard !meaning.isEmpty else { return 0 }
        return Double(meaning.intersection(sourceWords).count) / Double(meaning.count)
    }

    static func evidence(in text: String, peers: [String]) -> String? {
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let folded = peers.map { $0.lowercased() }
        if (1...80).contains(source.count), source.contains(where: \.isLetter),
           !folded.contains(where: { $0.contains(source.lowercased()) })
        {
            return source
        }
        for word in source.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let value = String(word)
            guard value.count <= 80 else { continue }
            if value.count > 1, value.contains(where: \.isLetter),
               !folded.contains(where: { $0.contains(value.lowercased()) })
            {
                return value
            }
        }
        return nil
    }

    /// Suppress ordinary personal-name-only sources and shared identities, while allowing named mnemonic concepts.
    static func hasDistinctMeaning(in text: String, peers: [String]) -> Bool {
        let label = String(text.split(separator: "\n", maxSplits: 1).first ?? "")
        let personal = Set(self.taggedWords(label).personalNames.map { self.canonicalWord($0) })
        let labelWords = self.semanticWords(label)
        let personalOnly = !personal.isEmpty && labelWords.isSubset(of: personal)
        let owned = self.semanticWords(text).subtracting(personalOnly ? personal : [])
        return self.hasSemanticDifference(owned, peers: peers)
    }

    /// An icon supported only by a shared role/clue cannot identify this account.
    static func isDistinctCandidate(_ entry: NativeOrbitBadgeCatalog.Entry, source: String, peers: [String]) -> Bool {
        guard self.hasSemanticDifference(self.semanticWords(source), peers: peers) else { return false }
        let clues = self.comparisonWords(entry.clues.joined(separator: " "))
        let target = clues.intersection(self.comparisonWords(source))
        let peerWords = peers.map { self.comparisonWords($0) }
        let genericRoles: Set = ["work", "personal", "school", "team", "business", "client", "shared", "friends"]
        if genericRoles.contains(entry.key), peerWords.contains(where: { !clues.isDisjoint(with: $0) }) {
            return false
        }
        return target.isEmpty || !target.allSatisfy { word in peerWords.contains(where: { $0.contains(word) }) }
    }

    static func candidates(
        text: String,
        peers: [String],
        query: String? = nil,
        entries: [NativeOrbitBadgeCatalog.Entry],
        limit: Int = 16) -> [Candidate]
    {
        guard self.hasDistinctMeaning(in: text, peers: peers),
              let evidence = evidence(in: text, peers: peers) else { return [] }
        let shared = Set(peers.flatMap { self.comparisonWords($0) })
        let all = self.words(query ?? text)
        let tokens = entries.map { self.words($0.title + " " + $0.clues.joined(separator: " ")) }
        let concrete = query.map { self.purposeWords($0) } ?? all
        let known = Set(tokens.flatMap(\.self))
        // Recover generic context only when the owned concrete subject cannot distinguish this account.
        let ownedWords = self.comparisonWords(text)
        let distinctSubject = ownedWords.subtracting(self.purposeContext).subtracting(shared)
        let ownedContext = distinctSubject.isEmpty
            ? ownedWords.intersection(self.purposeContext).subtracting(shared) : []
        let search = (concrete.isDisjoint(with: known) ? all : concrete).union(ownedContext)
        let unique = Set(search.filter { !shared.contains(self.canonicalWord($0)) })
        guard !search.isEmpty else { return [] }
        var frequency: [String: Int] = [:]
        for values in tokens {
            for word in values {
                frequency[word, default: 0] += 1
            }
        }
        var scores: [ScoredCandidate] = []
        for index in entries.indices {
            let hits = search.intersection(tokens[index])
            let score = hits.sorted().reduce(0.0) { value, word in
                let contrast = unique.contains(word) ? 1.0 : 0.2
                return value + contrast / log(Double(2 + frequency[word, default: 0]))
            }
            if score > 0 {
                scores.append(.init(
                    index: index,
                    score: score,
                    coverage: self.symbolCoverage(entries[index].symbol, sourceWords: all),
                    distinct: !hits.isDisjoint(with: unique),
                    ownedContext: !hits.isDisjoint(with: ownedContext)))
            }
        }
        scores.sort { lhs, rhs in
            // Shared subject words cannot consume the whole budget before an owned distinct clue.
            if lhs.distinct != rhs.distinct { return lhs.distinct }
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.coverage != rhs.coverage { return lhs.coverage > rhs.coverage }
            return entries[lhs.index].key < entries[rhs.index].key
        }
        let genericRoles: Set = ["work", "personal", "team", "business", "client", "shared", "friends"]
        if scores.contains(where: { !genericRoles.contains(entries[$0.index].key) && $0.score > 0.4 }) {
            scores.removeAll { genericRoles.contains(entries[$0.index].key) && !$0.ownedContext }
        }
        // Spend the candidate budget on visual families, retaining each family's strongest representative.
        var literalFamilies = Set<String>()
        scores.removeAll { !literalFamilies.insert(self.family(entries[$0.index].symbol)).inserted }
        if query == nil {
            if let best = scores.first?.score {
                scores.removeAll { $0.score < best * 0.55 && !$0.ownedContext }
            }
            return scores.prefix(max(0, limit)).map { Candidate(entry: entries[$0.index], evidence: evidence) }
        }
        if let best = scores.first?.score { scores.removeAll { $0.score < best * 0.55 && !$0.ownedContext } }
        let bound = max(0, limit)
        guard bound > 0 else { return [] }
        let lexical = scores.map(\.index)
        // A weak literal hit must not conceal an explicit subject absent from the vocabulary.
        // Already-installed assets are optional; never request a model download.
        let queryTags = self.taggedWords(query ?? text)
        let sourceNames = query == text ? queryTags.names : self.taggedWords(text).names
        let unmatched = Set(queryTags.content.subtracting(sourceNames).map { self.canonicalWord($0) })
            .intersection(search).subtracting(known).sorted()
        guard !unmatched.isEmpty, let embedding = NLEmbedding.wordEmbedding(for: .english) else {
            return lexical.prefix(bound).map { Candidate(entry: entries[$0], evidence: evidence) }
        }
        let lexicalFamilies = Set(lexical.map { self.family(entries[$0].symbol) })
        var recall: [Int: Double] = [:]
        let embeddedTokens = tokens.map { $0.filter { embedding.contains($0) }.sorted() }
        for word in unmatched where embedding.contains(word) {
            var nearest: [(index: Int, distance: Double)] = []
            for index in entries.indices where !lexicalFamilies.contains(self.family(entries[index].symbol)) {
                if let distance = embeddedTokens[index].map({ embedding.distance(between: word, and: $0) }).min(),
                   distance < 0.9
                {
                    nearest.append((index, distance))
                }
            }
            nearest.sort {
                $0.distance == $1.distance ? entries[$0.index].key < entries[$1.index].key : $0.distance < $1.distance
            }
            var families = Set<String>()
            for neighbour in nearest where families.insert(self.family(entries[neighbour.index].symbol)).inserted {
                recall[neighbour.index, default: 0] += 0.9 - neighbour.distance
                if families.count == 3 { break }
            }
        }
        let ranked = recall.keys.sorted {
            recall[$0] == recall[$1] ? entries[$0].key < entries[$1].key : recall[$0]! > recall[$1]!
        }
        var families = Set<String>()
        let neighbours = ranked.filter { families.insert(self.family(entries[$0].symbol)).inserted }
        // Reserve room for missing subjects without displacing the strongest literal choices.
        let recallSlots = lexical.isEmpty ? bound : min(neighbours.count, bound / 2)
        let selectedLexical = Array(lexical.prefix(bound - recallSlots))
        let selected = selectedLexical + neighbours.prefix(bound - selectedLexical.count)
        return selected.map { Candidate(entry: entries[$0], evidence: evidence) }
    }
}
