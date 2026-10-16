import AppKit
import CryptoKit
import Foundation
import Observation

/// Public website artwork only; receives neither account local-parts nor credentials.
@MainActor
@Observable
final class NativeOrbitWebsiteIconStore {
    static let shared = NativeOrbitWebsiteIconStore(
        directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.will.codexbar.native/account-website-icons/v2", isDirectory: true))

    /// The model sees the same validated monochrome pixels used by the dial, plus acquisition provenance.
    struct ModelContext {
        let key: String
        let domain: String
        let siteName: String?
        let source: URL
        let method: String
        let fingerprint: String
        let cgImage: CGImage
    }

    private struct Record: Codable {
        let domain: String
        var source: URL?
        var sourceHash: String?
        var siteName: String?
        var method: String?
        var fingerprint: String?
        var pngHash: String?
        var svgHash: String?
        var fetchedAt: Date?
        var nextAttempt: Date
    }

    private struct Item {
        let record: Record
        let png: Data?
        let svg: Data?
        let image: NSImage?
    }

    private let directory: URL
    private let fixedNow: Date?
    private let discover: @Sendable (String) async -> [NativeOrbitWebsiteIconDiscovery.Candidate]
    private var loaded: [String: Item] = [:]
    private var inspected: Set<String> = []
    private var pending: [String: Task<[NativeOrbitWebsiteIconDiscovery.Candidate], Never>] = [:]
    private var now: Date {
        self.fixedNow ?? Date()
    }

    init(
        directory: URL,
        now: Date? = nil,
        discover: @escaping @Sendable (String) async -> [NativeOrbitWebsiteIconDiscovery.Candidate] = {
            await NativeOrbitWebsiteIconDiscovery.discover(domain: $0)
        })
    {
        self.directory = directory
        self.fixedNow = now
        self.discover = discover
    }

    /// Shared domains and identical normalized silhouettes cannot identify just one account.
    func entries(for domains: [String]) -> [NativeOrbitBadgeCatalog.Entry] {
        let counts = Dictionary(grouping: domains, by: { $0 }).mapValues(\.count)
        let items = counts.keys.sorted().compactMap { domain -> Item? in
            guard let item = self.item(domain), item.image != nil, item.record.fingerprint != nil else { return nil }
            return item
        }
        let repeats = Dictionary(grouping: items, by: { $0.record.fingerprint! }).mapValues(\.count)
        return items.compactMap { item in
            guard counts[item.record.domain] == 1, repeats[item.record.fingerprint!] == 1 else { return nil }
            return .init(
                key: "website_" + Self.key(item.record.domain),
                title: "Website: " + item.record.domain,
                symbol: Self.symbol(item.record.domain),
                kind: .mail,
                domains: [item.record.domain],
                clues: [])
        }
    }

    func modelContexts(for domains: [String]) -> [ModelContext] {
        self.entries(for: domains).compactMap { entry in
            guard let domain = entry.domains.first, let item = self.item(domain),
                  let source = item.record.source, NativeOrbitWebsiteIconDiscovery.isPublicURL(source),
                  let method = item.record.method, let fingerprint = item.record.fingerprint,
                  let image = item.image?.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let visible = Self.visiblePreview(image) else { return nil }
            return ModelContext(
                key: entry.key,
                domain: domain,
                siteName: Self.boundedName(item.record.siteName),
                source: source,
                method: method,
                fingerprint: fingerprint,
                cgImage: visible)
        }
    }

    /// Flatten transparency onto white so black template glyphs remain visible to image understanding.
    private static func visiblePreview(_ image: CGImage) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: 128,
            height: 128,
            bitsPerComponent: 8,
            bytesPerRow: 512,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 128, height: 128))
        return context.makeImage()
    }

    func image(for symbol: String) -> NSImage? {
        self.loaded.values.first { Self.symbol($0.record.domain) == symbol }?.image
    }

    /// Canonical, self-contained path SVG retained alongside the runtime template image.
    func svg(for symbol: String) -> Data? {
        self.loaded.values.first { Self.symbol($0.record.domain) == symbol }?.svg
    }

    func needsRefresh(domains: [String]) -> Bool {
        domains.compactMap(NativeOrbitWebsiteIconDiscovery.normalizedDomain).contains {
            self.pending[$0] == nil && (self.item($0)?.record.nextAttempt ?? .distantPast) <= self.now
        }
    }

    @discardableResult
    func refresh(domains: [String]) async -> Bool {
        let domains = Array(Set(domains.compactMap(NativeOrbitWebsiteIconDiscovery.normalizedDomain)).sorted()
            .prefix(24))
        let due = domains.filter { (self.item($0)?.record.nextAttempt ?? .distantPast) <= self.now }
        var changed = false
        for offset in stride(from: 0, to: due.count, by: 4) {
            let batch = Array(due[offset..<min(offset + 4, due.count)])
            for domain in batch where self.pending[domain] == nil {
                let discover = self.discover
                self.pending[domain] = Task { await discover(domain) }
            }
            for domain in batch {
                guard let task = self.pending[domain] else { continue }
                let candidates = await task.value
                self.pending[domain] = nil
                let previous = self.item(domain)
                if let accepted = self.accept(candidates, domain: domain) {
                    changed = changed || previous?.record.fingerprint != accepted.record.fingerprint
                    self.loaded[domain] = accepted
                } else {
                    var record = previous?.record ?? Record(domain: domain, nextAttempt: self.now)
                    record.nextAttempt = self.now.addingTimeInterval(6 * 3600)
                    self.loaded[domain] = Item(
                        record: record,
                        png: previous?.png,
                        svg: previous?.svg,
                        image: previous?.image)
                }
                self.inspected.insert(domain)
                if let item = self.loaded[domain] { self.persist(item) }
            }
            // Finish the in-flight batch so cancelled popups cannot strand another domain as pending.
            if Task.isCancelled { return changed }
        }
        return changed
    }

    private func accept(_ candidates: [NativeOrbitWebsiteIconDiscovery.Candidate], domain: String) -> Item? {
        for candidate in candidates {
            guard NativeOrbitWebsiteIconDiscovery.isPublicURL(candidate.url),
                  let output = try? NativeOrbitWebsiteIconArtwork.make(
                      data: candidate.data, prefersAlpha: candidate.prefersAlpha),
                  let image = NSImage(data: output.png) else { continue }
            image.isTemplate = true
            let record = Record(
                domain: domain,
                source: candidate.url,
                sourceHash: Self.digest(candidate.data),
                siteName: Self.boundedName(candidate.siteName),
                method: candidate.method,
                fingerprint: output.fingerprint,
                pngHash: Self.digest(output.png),
                svgHash: Self.digest(output.svg),
                fetchedAt: self.now,
                nextAttempt: self.now.addingTimeInterval(30 * 86400))
            return Item(record: record, png: output.png, svg: output.svg, image: image)
        }
        return nil
    }

    private func item(_ domain: String) -> Item? {
        guard NativeOrbitWebsiteIconDiscovery.normalizedDomain(domain) == domain else { return nil }
        if self.inspected.contains(domain) { return self.loaded[domain] }
        self.inspected.insert(domain)
        guard let data = self.read(self.url(domain, ext: "json"), limit: 16384),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.domain == domain else { return nil }
        if record.fingerprint == nil {
            let item = Item(record: record, png: nil, svg: nil, image: nil)
            self.loaded[domain] = item
            return item
        }
        guard let png = self.read(self.url(domain, ext: "png"), limit: 256 * 1024),
              let svg = self.read(self.url(domain, ext: "svg"), limit: 1024 * 1024),
              Self.digest(png) == record.pngHash, Self.digest(svg) == record.svgHash,
              png.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]), let image = NSImage(data: png),
              image.size.width <= 256, image.size.height <= 256 else { return nil }
        image.isTemplate = true
        let item = Item(record: record, png: png, svg: svg, image: image)
        self.loaded[domain] = item
        return item
    }

    private func persist(_ item: Item) {
        do {
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
            if let png = item.png, let svg = item.svg {
                try png.write(to: self.url(item.record.domain, ext: "png"), options: .atomic)
                try svg.write(to: self.url(item.record.domain, ext: "svg"), options: .atomic)
            }
            try JSONEncoder().encode(item.record).write(to: self.url(item.record.domain, ext: "json"), options: .atomic)
            try self.prune()
        } catch {
            // In-memory icons remain usable when disk caching is unavailable.
        }
    }

    private func prune() throws {
        let files = try FileManager.default.contentsOfDirectory(
            at: self.directory,
            includingPropertiesForKeys: [.contentModificationDateKey]).filter { $0.pathExtension == "json" }
        let dates = files.map { file in
            (
                file,
                (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ??
                    .distantPast)
        }
        for (file, _) in dates.sorted(by: { $0.1 > $1.1 }).dropFirst(128) {
            for ext in ["json", "png", "svg"] {
                try? FileManager.default.removeItem(at: file.deletingPathExtension().appendingPathExtension(ext))
            }
        }
    }

    private func read(_ url: URL, limit: Int) -> Data? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= limit,
              let data = try? Data(contentsOf: url), data.count <= limit else { return nil }
        return data
    }

    private func url(_ domain: String, ext: String) -> URL {
        self.directory.appendingPathComponent(Self.key(domain)).appendingPathExtension(ext)
    }

    private static func boundedName(_ value: String?) -> String? {
        guard let value else { return nil }
        let clean = String(String.UnicodeScalarView(value.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        })).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return clean.isEmpty ? nil : String(clean.prefix(120))
    }

    private static func symbol(_ domain: String) -> String { "account.website." + self.key(domain) }
    private static func key(_ domain: String) -> String { self.digest(Data(domain.utf8)) }
    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
