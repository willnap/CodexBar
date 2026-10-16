import AppKit
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct NativeOrbitWebsiteIconStoreTests {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("website-icon-tests-\(UUID().uuidString)")
    }

    private nonisolated static let ring = Data("""
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
    <path fill-rule="evenodd" d="M32 4a28 28 0 1 0 0 56a28 28 0 1 0 0-56M32 18a14 14 0 1 1 0 28a14 14 0 1 1 0-28"/>
    </svg>
    """.utf8)

    @Test func `website icons persist as template images and path SVG with source provenance`() async throws {
        let root = self.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeOrbitWebsiteIconStore(directory: root) { domain in
            [.init(
                data: Self.ring,
                url: URL(string: "https://\(domain)/mark.svg")!,
                prefersAlpha: true,
                method: "mask-icon")]
        }
        #expect(await store.refresh(domains: ["alpha-brand.com"]))
        let entry = try #require(store.entries(for: ["alpha-brand.com"]).first)
        #expect(entry.kind == .mail)
        #expect(entry.domains == ["alpha-brand.com"])
        #expect(entry.symbol.hasPrefix("account.website."))
        #expect(store.image(for: entry.symbol) != nil)
        let export = try #require(store.svg(for: entry.symbol))
        let text = try #require(String(bytes: export, encoding: .utf8))
        #expect(text.contains("<path"))
        #expect(!text.contains("<image"))
        let reopened = NativeOrbitWebsiteIconStore(directory: root) { _ in [] }
        #expect(reopened.entries(for: ["alpha-brand.com"]).first?.symbol == entry.symbol)
        #expect(reopened.image(for: entry.symbol) != nil)
    }

    @Test func `local model contexts carry exact source identity and visible verified artwork`() async throws {
        let root = self.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeOrbitWebsiteIconStore(directory: root) { domain in
            [.init(
                data: Self.ring,
                url: URL(string: "https://cdn.\(domain)/mark.svg")!,
                prefersAlpha: true,
                method: "safari-mask-icon")]
        }
        _ = await store.refresh(domains: ["alpha-brand.com"])
        let entry = try #require(store.entries(for: ["alpha-brand.com"]).first)
        let context = try #require(store.modelContexts(for: ["alpha-brand.com"]).first)
        #expect(context.key == entry.key)
        #expect(context.domain == "alpha-brand.com")
        #expect(context.source.absoluteString == "https://cdn.alpha-brand.com/mark.svg")
        #expect(context.method == "safari-mask-icon")
        #expect(context.fingerprint.count == 64)
        #expect(context.cgImage.width == 128)
        #expect(context.cgImage.height == 128)
        let bitmap = NSBitmapImageRep(cgImage: context.cgImage)
        let background = try #require(bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB))
        #expect(background.alphaComponent == 1)
        #expect(background.redComponent > 0.99)
        let ink = try #require(bitmap.colorAt(x: 64, y: 16)?.usingColorSpace(.deviceRGB))
        #expect(ink.alphaComponent == 1)
        #expect(ink.redComponent < 0.01)
        let reopened = NativeOrbitWebsiteIconStore(directory: root) { _ in [] }
        #expect(reopened.modelContexts(for: ["alpha-brand.com"]).first?.fingerprint == context.fingerprint)
        #expect(reopened.modelContexts(for: ["alpha-brand.com", "alpha-brand.com"]).isEmpty)
    }

    @Test func `site names survive caching as bounded untrusted model context`() async {
        let root = self.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeOrbitWebsiteIconStore(directory: root) { domain in
            [.init(
                data: Self.ring,
                url: URL(string: "https://\(domain)/mark.svg")!,
                prefersAlpha: true,
                method: "safari-mask-icon",
                siteName: "Alpha & Company")]
        }
        _ = await store.refresh(domains: ["alpha-brand.com"])
        #expect(store.modelContexts(for: ["alpha-brand.com"]).first?.siteName == "Alpha & Company")
        let reopened = NativeOrbitWebsiteIconStore(directory: root) { _ in [] }
        #expect(reopened.modelContexts(for: ["alpha-brand.com"]).first?.siteName == "Alpha & Company")
    }

    @Test func `native role symbols remain selectable when a downloaded website mark is available`() async throws {
        let root = self.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeOrbitWebsiteIconStore(directory: root) { domain in
            [.init(
                data: Self.ring,
                url: URL(string: "https://\(domain)/mark.svg")!,
                prefersAlpha: true,
                method: "safari-mask-icon")]
        }
        _ = await store.refresh(domains: ["alpha-brand.com"])
        let original = NativeOrbitBadgeResolver.websiteIconsForTesting
        defer { NativeOrbitBadgeResolver.websiteIconsForTesting = original }
        NativeOrbitBadgeResolver.websiteIconsForTesting = store
        let accounts = [
            Self.account("a", "alex.work@alpha-brand.com", label: "Work"),
            Self.account("b", "alex.personal@gmail.com", label: "Personal"),
        ]
        let entry = try #require(store.entries(for: ["alpha-brand.com"]).first)
        #expect(NativeOrbitBadgeResolver.choiceKeys(accounts).contains(entry.key))
        let chosen = NativeOrbitBadgeResolver.validatedBadges([
            .init(badge: "work", evidence: "Work"), .init(badge: "personal", evidence: "Personal"),
        ], for: accounts)
        #expect(chosen?["a"] == "briefcase.fill")
        #expect(chosen?["b"] == "person.crop.square.fill")
    }

    @Test func `a website with no favicon automatically keeps distinct native account clues`() async {
        let root = self.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let counter = WebsiteIconCounter()
        let store = NativeOrbitWebsiteIconStore(directory: root) { _ in
            await counter.increment()
            return []
        }
        let original = NativeOrbitBadgeResolver.websiteIconsForTesting
        defer { NativeOrbitBadgeResolver.websiteIconsForTesting = original }
        NativeOrbitBadgeResolver.websiteIconsForTesting = store
        let state = NativeOrbitPopupState()
        state.accounts = [Self.account("a", "alice@example.com"), Self.account("b", "bob@gmail.com")]
        await NativeOrbitBadgeResolver.resolve(state)
        #expect(await counter.count == 1)
        #expect(store.entries(for: ["example.com"]).isEmpty)
        #expect(state.badges["a"] == "a.square.fill")
        #expect(state.badges["b"] == "account.mail.gmail")
    }

    @Test func `shared domains and duplicate silhouettes are excluded from comparison choices`() async {
        let root = self.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeOrbitWebsiteIconStore(directory: root) { domain in
            [.init(
                data: Self.ring,
                url: URL(string: "https://\(domain)/mark.svg")!,
                prefersAlpha: true,
                method: "mask-icon")]
        }
        _ = await store.refresh(domains: ["alpha-brand.com", "beta-brand.org"])
        #expect(store.entries(for: ["alpha-brand.com"]).count == 1)
        #expect(store.entries(for: ["alpha-brand.com", "alpha-brand.com"]).isEmpty)
        #expect(store.entries(for: ["alpha-brand.com", "beta-brand.org"]).isEmpty)
    }

    @Test func `positive and negative caches suppress repeated network attempts`() async {
        let root = self.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let counter = WebsiteIconCounter()
        let store = NativeOrbitWebsiteIconStore(directory: root) { _ in
            await counter.increment()
            return []
        }
        #expect(await !(store.refresh(domains: ["alpha-brand.com"])))
        #expect(await !(store.refresh(domains: ["alpha-brand.com"])))
        #expect(await counter.count == 1)
        let reopened = NativeOrbitWebsiteIconStore(directory: root) { _ in
            await counter.increment()
            return []
        }
        _ = await reopened.refresh(domains: ["alpha-brand.com"])
        #expect(await counter.count == 1)
    }

    @Test func `cached website marks enter the model schema and invalidate old fallback keys`() async throws {
        let root = self.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeOrbitWebsiteIconStore(directory: root) { domain in
            [.init(
                data: Self.ring,
                url: URL(string: "https://\(domain)/mark.svg")!,
                prefersAlpha: true,
                method: "mask-icon")]
        }
        let accounts = [Self.account("a", "alex@alpha-brand.com"), Self.account("b", "alex@gmail.com")]
        let original = NativeOrbitBadgeResolver.websiteIconsForTesting
        defer { NativeOrbitBadgeResolver.websiteIconsForTesting = original }
        NativeOrbitBadgeResolver.websiteIconsForTesting = store
        let before = NativeOrbitBadgeResolver.identityKey(accounts)
        NativeOrbitBadgeResolver.websiteIconsForTesting = original
        _ = await store.refresh(domains: ["alpha-brand.com"])
        NativeOrbitBadgeResolver.websiteIconsForTesting = store
        let entry = try #require(store.entries(for: ["alpha-brand.com"]).first)
        #expect(before != NativeOrbitBadgeResolver.identityKey(accounts))
        #expect(NativeOrbitBadgeResolver.choiceKeys(accounts).contains(entry.key))
        #expect(NativeOrbitBadgeResolver.initialBadges(accounts)["a"] == entry.symbol)
        let chosen = NativeOrbitBadgeResolver.validatedBadges([
            .init(badge: entry.key, evidence: "alpha-brand.com"),
            .init(badge: "gmail", evidence: "gmail.com"),
        ], for: accounts)
        #expect(chosen?["a"] == entry.symbol)
        #expect(chosen?["b"] == "account.mail.gmail")
    }

    @Test func `expired positive cache retains valid artwork through transient failure with backoff`() async {
        let root = self.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let counter = WebsiteIconCounter()
        let epoch = Date(timeIntervalSince1970: 1_000_000)
        let first = NativeOrbitWebsiteIconStore(directory: root, now: epoch) { domain in
            await counter.increment()
            return [.init(
                data: Self.ring,
                url: URL(string: "https://\(domain)/mask.svg")!,
                prefersAlpha: true,
                method: "mask-icon")]
        }
        _ = await first.refresh(domains: ["alpha-brand.com"])
        _ = await first.refresh(domains: ["alpha-brand.com"])
        #expect(await counter.count == 1)
        let stale = NativeOrbitWebsiteIconStore(directory: root, now: epoch.addingTimeInterval(31 * 86400)) { _ in
            await counter.increment()
            return []
        }
        _ = await stale.refresh(domains: ["alpha-brand.com"])
        #expect(stale.entries(for: ["alpha-brand.com"]).count == 1)
        #expect(await counter.count == 2)
        let retry = NativeOrbitWebsiteIconStore(
            directory: root,
            now: epoch.addingTimeInterval(31 * 86400 + 3600))
        { _ in
            await counter.increment()
            return []
        }
        _ = await retry.refresh(domains: ["alpha-brand.com"])
        #expect(retry.entries(for: ["alpha-brand.com"]).count == 1)
        #expect(await counter.count == 2)
    }

    @Test func `a rejected first candidate continues to the next usable icon`() async throws {
        let root = self.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeOrbitWebsiteIconStore(directory: root) { domain in
            let url = URL(string: "https://\(domain)/")!
            return [
                .init(
                    data: Data("not artwork".utf8),
                    url: url.appendingPathComponent("bad.svg"),
                    prefersAlpha: true,
                    method: "mask-icon"),
                .init(
                    data: Self.ring,
                    url: url.appendingPathComponent("good.svg"),
                    prefersAlpha: true,
                    method: "svg-favicon"),
            ]
        }
        _ = await store.refresh(domains: ["alpha-brand.com"])
        #expect(store.entries(for: ["alpha-brand.com"]).count == 1)
        let metadata = try #require(FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "json" })
        #expect(try String(contentsOf: metadata, encoding: .utf8).contains("good.svg"))
    }

    @Test func `a late website response cannot overwrite a changed account set`() async {
        let root = self.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = WebsiteIconGate()
        let store = NativeOrbitWebsiteIconStore(directory: root) { domain in
            await gate.fetch(domain: domain, data: Self.ring)
        }
        let original = NativeOrbitBadgeResolver.websiteIconsForTesting
        NativeOrbitBadgeResolver.websiteIconsForTesting = store
        defer { NativeOrbitBadgeResolver.websiteIconsForTesting = original }
        let state = NativeOrbitPopupState()
        state.accounts = [Self.account("old", "alex@alpha-brand.com")]
        let task = Task { await NativeOrbitBadgeResolver.resolve(state) }
        await gate.started()
        state.accounts = [Self.account("new", "alex@gmail.com")]
        state.badges = NativeOrbitBadgeResolver.initialBadges(state.accounts)
        await gate.finish()
        await task.value
        #expect(Set(state.badges.keys) == ["new"])
        #expect(state.badges["new"] == "account.mail.gmail")
    }

    @Test func `expired website backoff triggers resolution even when account identities do not change`() async {
        let root = self.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let epoch = Date(timeIntervalSince1970: 1_000_000)
        let first = NativeOrbitWebsiteIconStore(directory: root, now: epoch) { _ in [] }
        _ = await first.refresh(domains: ["alpha-brand.com"])
        let accounts = [Self.account("a", "alex@alpha-brand.com")]
        let original = NativeOrbitBadgeResolver.websiteIconsForTesting
        defer { NativeOrbitBadgeResolver.websiteIconsForTesting = original }
        NativeOrbitBadgeResolver.websiteIconsForTesting = first
        let key = NativeOrbitBadgeResolver.identityKey(accounts)
        #expect(!NativeOrbitBadgeResolver.shouldResolve(accounts, previousKey: key))
        let expired = NativeOrbitWebsiteIconStore(directory: root, now: epoch.addingTimeInterval(7 * 3600)) { _ in [] }
        NativeOrbitBadgeResolver.websiteIconsForTesting = expired
        #expect(NativeOrbitBadgeResolver.identityKey(accounts) == key)
        #expect(NativeOrbitBadgeResolver.shouldResolve(accounts, previousKey: key))
    }

    @Test func `cancelling a popup does not strand other icons in the completed download batch`() async {
        let root = self.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = WebsiteIconGate()
        let store = NativeOrbitWebsiteIconStore(directory: root) { domain in
            if domain == "alpha-brand.com" { return await gate.fetch(domain: domain, data: Self.ring) }
            return [.init(
                data: Self.ring,
                url: URL(string: "https://\(domain)/mask.svg")!,
                prefersAlpha: true,
                method: "mask-icon")]
        }
        let task = Task { await store.refresh(domains: ["alpha-brand.com", "beta-brand.org"]) }
        await gate.started()
        task.cancel()
        await gate.finish()
        _ = await task.value
        #expect(store.entries(for: ["beta-brand.org"]).count == 1)
    }

    private static func account(_ id: String, _ email: String, label: String? = nil) -> NativeOrbitAccountPresentation {
        .init(
            id: id,
            label: label ?? email,
            email: email,
            symbol: "gearshape",
            isActive: false,
            canActivate: false,
            gauge: ComputeGauge.State(),
            updatedAt: nil,
            history: [],
            odometer: nil,
            odometerHelp: nil,
            statusText: nil,
            selection: .none)
    }

    @Test func `corrupt cache artwork cannot become a model choice`() async throws {
        let root = self.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeOrbitWebsiteIconStore(directory: root) { domain in
            [.init(
                data: Self.ring,
                url: URL(string: "https://\(domain)/mark.svg")!,
                prefersAlpha: true,
                method: "mask-icon")]
        }
        _ = await store.refresh(domains: ["alpha-brand.com"])
        let png = try #require(FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "png" })
        try Data("not an image".utf8).write(to: png)
        let reopened = NativeOrbitWebsiteIconStore(directory: root) { _ in [] }
        #expect(reopened.entries(for: ["alpha-brand.com"]).isEmpty)
    }
}

private actor WebsiteIconCounter {
    var count = 0
    func increment() { self.count += 1 }
}

private actor WebsiteIconGate {
    private var hasStarted = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?

    func fetch(domain: String, data: Data) async -> [NativeOrbitWebsiteIconDiscovery.Candidate] {
        self.hasStarted = true
        self.startWaiter?.resume()
        self.startWaiter = nil
        await withCheckedContinuation { self.release = $0 }
        return [.init(
            data: data,
            url: URL(string: "https://\(domain)/mask.svg")!,
            prefersAlpha: true,
            method: "mask-icon")]
    }

    func started() async {
        if self.hasStarted { return }
        await withCheckedContinuation { self.startWaiter = $0 }
    }

    func finish() { self.release?.resume(); self.release = nil }
}
