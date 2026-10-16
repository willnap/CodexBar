import Darwin
import Foundation
import Testing
@testable import CodexBar

struct NativeOrbitWebsiteIconDiscoveryTests {
    private typealias Discovery = NativeOrbitWebsiteIconDiscovery
    private actor Site {
        var pages: [String: Discovery.Response]
        var requests: [URL] = []

        init(_ pages: [String: Discovery.Response]) { self.pages = pages }

        func fetch(_ url: URL, limit: Int) throws -> Discovery.Response {
            self.requests.append(url)
            guard let response = self.pages[url.absoluteString] else { throw URLError(.fileDoesNotExist) }
            return response
        }
    }

    private static func response(_ text: String, _ url: String, _ mime: String = "image/svg+xml") -> Discovery
    .Response {
        .init(data: Data(text.utf8), url: URL(string: url)!, mimeType: mime)
    }

    @Test func `Safari mask precedes monochrome manifest SVG and raster icons`() async {
        let site = Site([
            "https://company.com/": Self.response(
                """
                <link href='/raster.png' rel='apple-touch-icon'>
                <link href='/ordinary.svg' REL='shortcut ICON'>
                <link rel=manifest href='/app/site.webmanifest'>
                <link color='#000' HREF='/mask.svg' ReL='MASK-ICON'>
                """,
                "https://company.com/",
                "text/html"),
            "https://company.com/app/site.webmanifest": Self.response(
                """
                {"icons":[{"src":"../mono.svg","purpose":"any monochrome","type":"image/svg+xml"}]}
                """,
                "https://company.com/app/site.webmanifest",
                "application/manifest+json"),
            "https://company.com/mask.svg": Self.response("mask", "https://company.com/mask.svg"),
            "https://company.com/mono.svg": Self.response("mono", "https://company.com/mono.svg"),
            "https://company.com/ordinary.svg": Self.response("svg", "https://company.com/ordinary.svg"),
            "https://company.com/raster.png": Self.response("raster", "https://company.com/raster.png", "image/png"),
        ])
        let result = await Discovery.discover(domain: "company.com", fetch: { try await site.fetch($0, limit: $1) })
        #expect(result.map(\.url.lastPathComponent) == ["mask.svg", "mono.svg", "ordinary.svg", "raster.png"])
        #expect(result.map(\.prefersAlpha) == [true, true, false, false])
    }

    @Test func `base and entities resolve against final page and duplicate links fetch once`() async {
        let site = Site([
            "https://company.com/": Self.response(
                """
                <!-- <link rel=mask-icon href='/comment.svg'> -->
                <script>const text = "<link rel=mask-icon href='/script.svg'>";</script>
                <base href='../assets/'>
                <link href='mark.svg?a=1&amp;b=2' rel=icon>
                <link rel='shortcut icon' href='mark.svg?a=1&#38;b=2'>
                """,
                "https://company.com/welcome/index.html",
                "text/html"),
            "https://company.com/assets/mark.svg?a=1&b=2": Self.response(
                "svg", "https://company.com/assets/mark.svg?a=1&b=2"),
        ])
        let result = await Discovery.discover(domain: "company.com", fetch: { try await site.fetch($0, limit: $1) })
        #expect(result.map(\.url.absoluteString) == ["https://company.com/assets/mark.svg?a=1&b=2"])
        let requests = await site.requests
        #expect(requests.filter { $0.path == "/assets/mark.svg" }.count == 1)
        #expect(!requests.contains { $0.path == "/comment.svg" || $0.path == "/script.svg" })
    }

    @Test func `malformed manifest and failed landing still permit conventional icons`() async {
        let site = Site([
            "https://company.com/": Self.response(
                "<link rel=manifest href='/broken.json'>",
                "https://company.com/",
                "text/html"),
            "https://company.com/broken.json": Self.response(
                "{bad",
                "https://company.com/broken.json",
                "application/json"),
            "https://company.com/favicon.svg": Self.response("svg", "https://company.com/favicon.svg"),
        ])
        let result = await Discovery.discover(domain: "company.com", fetch: { try await site.fetch($0, limit: $1) })
        #expect(result.map(\.url.lastPathComponent) == ["favicon.svg"])
        let failedSite = Site([
            "https://company.com/favicon.ico": Self.response("ico", "https://company.com/favicon.ico", "image/x-icon"),
        ])
        let fallback = await Discovery.discover(
            domain: "company.com",
            fetch: { try await failedSite.fetch($0, limit: $1) })
        #expect(fallback.map(\.url.lastPathComponent) == ["favicon.ico"])
    }

    @Test func `private local IP credential and HTTP URLs are rejected`() throws {
        for raw in [
            "http://company.com/icon.svg",
            "https://127.0.0.1/",
            "https://[::1]/",
            "https://localhost/",
            "https://server.local/",
            "https://office.internal/",
            "https://192.168.1.1/",
            "https://127.1/",
            "https://2130706433/",
            "https://user:secret@company.com/icon",
            "https://company.com:8443/",
        ] {
            #expect(try !Discovery.isPublicURL(#require(URL(string: raw))))
        }
        #expect(try Discovery.isPublicURL(#require(URL(string: "https://cdn.company.com/icon.svg"))))
        #expect(Discovery.normalizedDomain(" Team.Company.COM ") == "team.company.com")
        #expect(Discovery.normalizedDomain("person@company.com") == nil)
        #expect(Discovery.normalizedDomain("https://company.com") == nil)
    }

    @Test func `unsafe declared links and HTTP redirected responses never become candidates`() async {
        let site = Site([
            "https://company.com/": Self.response(
                """
                <link rel=mask-icon href='https://127.0.0.1/secret.svg'>
                <link rel=icon href='/redirect.svg'>
                """,
                "https://company.com/",
                "text/html"),
            "https://company.com/redirect.svg": Self.response("svg", "http://company.com/redirect.svg"),
        ])
        let result = await Discovery.discover(domain: "company.com", fetch: { try await site.fetch($0, limit: $1) })
        #expect(result.isEmpty)
        let requests = await site.requests
        #expect(!requests.contains { $0.host == "127.0.0.1" })
    }

    @Test func `oversized icons HTML masquerading as icons and excessive requests are bounded`() async throws {
        var pages: [String: Discovery.Response] = try [
            "https://company.com/": Self.response(
                (0..<30).map { "<link rel=icon href='/\($0).svg'>" }.joined(), "https://company.com/", "text/html"),
            "https://company.com/0.svg": .init(
                data: Data(repeating: 65, count: 1_048_577),
                url: #require(URL(string: "https://company.com/0.svg")),
                mimeType: "image/svg+xml"),
            "https://company.com/1.svg": Self.response(
                "<html>sign in</html>",
                "https://company.com/1.svg",
                "image/svg+xml"),
            "https://company.com/2.svg": Self.response("svg", "https://company.com/2.svg", "text/html"),
        ]
        for index in 3..<30 {
            pages["https://company.com/\(index).svg"] = Self.response("svg", "https://company.com/\(index).svg")
        }
        let site = Site(pages)
        let result = await Discovery.discover(domain: "company.com", fetch: { try await site.fetch($0, limit: $1) })
        #expect(result.map(\.url.lastPathComponent) == ["3.svg", "4.svg", "5.svg", "6.svg"])
        let requests = await site.requests
        #expect(requests.count <= 8)
    }

    @Test func `invalid first artwork remains available alongside later valid candidates`() async {
        let site = Site([
            "https://company.com/": Self.response(
                "<link rel=mask-icon href='/bad.svg'><link rel=icon href='/good.svg'>",
                "https://company.com/",
                "text/html"),
            "https://company.com/bad.svg": Self.response("broken svg", "https://company.com/bad.svg"),
            "https://company.com/good.svg": Self.response("<svg></svg>", "https://company.com/good.svg"),
        ])
        let result = await Discovery.discover(domain: "company.com", fetch: { try await site.fetch($0, limit: $1) })
        #expect(result.map(\.url.lastPathComponent) == ["bad.svg", "good.svg"])
    }

    @Test func `manifest sources use final manifest URL and artwork count is bounded`() async {
        let site = Site([
            "https://company.com/": Self.response(
                "<link rel=manifest href='/site.json'>",
                "https://company.com/",
                "text/html"),
            "https://company.com/site.json": Self.response(
                """
                {"icons":[{"src":"mono.svg","purpose":"monochrome"},
                {"src":"1.png"},{"src":"2.png"},{"src":"3.png"},{"src":"4.png"},{"src":"5.png"}]}
                """,
                "https://cdn.company.com/assets/manifest.json",
                "application/json"),
            "https://cdn.company.com/assets/mono.svg": Self.response("svg", "https://cdn.company.com/assets/mono.svg"),
            "https://cdn.company.com/assets/1.png": Self.response(
                "png",
                "https://cdn.company.com/assets/1.png",
                "image/png"),
            "https://cdn.company.com/assets/2.png": Self.response(
                "png",
                "https://cdn.company.com/assets/2.png",
                "image/png"),
            "https://cdn.company.com/assets/3.png": Self.response(
                "png",
                "https://cdn.company.com/assets/3.png",
                "image/png"),
            "https://cdn.company.com/assets/4.png": Self.response(
                "png",
                "https://cdn.company.com/assets/4.png",
                "image/png"),
            "https://cdn.company.com/assets/5.png": Self.response(
                "png",
                "https://cdn.company.com/assets/5.png",
                "image/png"),
        ])
        let result = await Discovery.discover(domain: "company.com", fetch: { try await site.fetch($0, limit: $1) })
        #expect(result.map(\.url.lastPathComponent) == ["mono.svg", "1.png", "2.png", "3.png", "4.png"])
    }

    @Test func `www fallback preserves exact subdomain instead of guessing parent website`() async {
        let site = Site([
            "https://www.team.company.com/": Self.response(
                "<link rel=icon href='/mark.svg'>",
                "https://www.team.company.com/",
                "text/html"),
            "https://www.team.company.com/mark.svg": Self.response("svg", "https://www.team.company.com/mark.svg"),
        ])
        let result = await Discovery.discover(
            domain: "team.company.com",
            fetch: { try await site.fetch($0, limit: $1) })
        #expect(result.map(\.url.host) == ["www.team.company.com"])
        let requests = await site.requests
        #expect(!requests.contains { $0.host == "company.com" || $0.host == "www.company.com" })
    }

    @Test func `oversized metadata is ignored while favicon fallback stays available`() async throws {
        let site = try Site([
            "https://company.com/": Self.response(
                "<link rel=manifest href='/site.json'>",
                "https://company.com/",
                "text/html"),
            "https://company.com/site.json": .init(
                data: Data(repeating: 32, count: 131_073),
                url: #require(URL(string: "https://company.com/site.json")),
                mimeType: "application/json"),
            "https://company.com/favicon.svg": Self.response("svg", "https://company.com/favicon.svg"),
        ])
        let result = await Discovery.discover(domain: "company.com", fetch: { try await site.fetch($0, limit: $1) })
        #expect(result.map(\.url.lastPathComponent) == ["favicon.svg"])
        let oversized = try Site([
            "https://company.com/": .init(
                data: Data(repeating: 32, count: 524_289),
                url: #require(URL(string: "https://company.com/")),
                mimeType: "text/html"),
            "https://company.com/favicon.svg": Self.response("svg", "https://company.com/favicon.svg"),
        ])
        let fallback = await Discovery.discover(
            domain: "company.com",
            fetch: { try await oversized.fetch($0, limit: $1) })
        #expect(fallback.map(\.url.lastPathComponent) == ["favicon.svg"])
    }

    @Test func `international domains normalize to ASCII without accepting URL syntax`() {
        #expect(Discovery.normalizedDomain("BÜCHER.de") == "xn--bcher-kva.de")
        #expect(Discovery.normalizedDomain("bücher.de.") == "xn--bcher-kva.de")
        #expect(Discovery.normalizedDomain("team.company.com.") == "team.company.com")
        for domain in [
            "bücher.de/path",
            "person@bücher.de",
            "bücher.de:443",
            "bücher.de?x=1",
            "bücher.de#part",
            "bücher.de..",
            "bücher.de\\path",
            "b%75cher.de",
        ] {
            #expect(Discovery.normalizedDomain(domain) == nil)
        }
    }

    @Test func `ordinary manifest SVG icons precede declared PNG while guessed paths remain fallbacks`() async {
        let site = Site([
            "https://company.com/": Self.response(
                "<link rel=icon href='/raster.png'><link rel=manifest href='/app.json'>",
                "https://company.com/",
                "text/html"),
            "https://company.com/app.json": Self.response(
                """
                {"icons":[{"src":"mark","type":"image/svg+xml"},{"src":"extension.svg"}]}
                """,
                "https://company.com/app.json",
                "application/json"),
            "https://company.com/mark": Self.response("svg", "https://company.com/mark"),
            "https://company.com/extension.svg": Self.response("svg", "https://company.com/extension.svg"),
            "https://company.com/raster.png": Self.response("png", "https://company.com/raster.png", "image/png"),
            "https://company.com/favicon.svg": Self.response("svg", "https://company.com/favicon.svg"),
        ])
        let result = await Discovery.discover(domain: "company.com", fetch: { try await site.fetch($0, limit: $1) })
        #expect(result.map(\.url.lastPathComponent) == ["mark", "extension.svg", "raster.png", "favicon.svg"])
        #expect(result.map(\.prefersAlpha) == [false, false, false, false])
    }

    @Test func `IPv4 classification preserves public neighbors of special purpose blocks`() {
        let publicAddresses = [
            "192.0.78.24",
            "198.51.32.10",
            "192.0.0.9",
            "192.0.0.10",
            "8.8.8.8",
            "100.63.255.255",
            "100.128.0.0",
            "172.15.255.255",
            "172.32.0.0",
        ]
        let blockedAddresses = [
            "0.1.2.3",
            "10.2.3.4",
            "100.64.0.0",
            "100.127.255.255",
            "127.0.0.1",
            "169.254.1.1",
            "172.16.0.0",
            "172.31.255.255",
            "192.0.0.8",
            "192.0.0.11",
            "192.0.2.24",
            "192.88.99.1",
            "192.168.1.1",
            "198.18.0.0",
            "198.19.255.255",
            "198.51.100.24",
            "203.0.113.24",
            "224.0.0.1",
            "240.0.0.1",
            "255.255.255.255",
        ]
        for raw in publicAddresses {
            var address = in_addr()
            #expect(inet_pton(AF_INET, raw, &address) == 1)
            #expect(Discovery.isPublicIPv4Address(address), "Expected public address: \(raw)")
        }
        for raw in blockedAddresses {
            var address = in_addr()
            #expect(inet_pton(AF_INET, raw, &address) == 1)
            #expect(!Discovery.isPublicIPv4Address(address), "Expected blocked address: \(raw)")
        }
    }

    @Test func `large HTML pages retain head artwork declarations but oversized images stay rejected`() async {
        let html = "<html><head><link rel=icon href='/declared.svg'></head><body>"
            + String(repeating: "x", count: 925_620) + "</body></html>"
        let site = Site([
            "https://company.com/": Self.response(html, "https://company.com/", "text/html"),
            "https://company.com/declared.svg": Self.response("svg", "https://company.com/declared.svg"),
            "https://company.com/favicon.svg": Self.response(
                String(repeating: "x", count: 1_048_577), "https://company.com/favicon.svg"),
        ])
        let result = await Discovery.discover(domain: "company.com", fetch: { try await site.fetch($0, limit: $1) })
        #expect(result.map(\.url.lastPathComponent) == ["declared.svg"])
    }

    @Test func `HTML body streaming accepts large declarations and retains only bounded prefixes`() throws {
        var html = try #require(Discovery.ResponseBody(
            limit: 16, expectedLength: 925_620, mimeType: "text/html", allowsHTMLPrefix: true))
        #expect(try !html.append(Data("<head>".utf8)))
        #expect(try html.append(Data(repeating: 65, count: 200)))
        #expect(html.data.count == 16)
        #expect(String(data: html.data.prefix(6), encoding: .utf8) == "<head>")
        #expect(Discovery.ResponseBody(limit: 16, expectedLength: 17, mimeType: "image/png") == nil)
        #expect(Discovery.ResponseBody(
            limit: 16, expectedLength: 17, mimeType: "application/json", allowsHTMLPrefix: true) == nil)
        var image = try #require(Discovery.ResponseBody(limit: 16, expectedLength: -1, mimeType: "image/png"))
        #expect(throws: URLError.self) { try image.append(Data(repeating: 65, count: 17)) }
        #expect(image.data.isEmpty)
    }

    @Test func `website names prefer site metadata and survive final page URL resolution`() async {
        let fixtures = [
            (
                "<meta name=application-name content='Wrong'>"
                    + "<meta property=og:site_name content='Acme &amp; &lt;b&gt;Co&lt;/b&gt;'>",
                "Acme & Co"),
            ("<meta name=application-name content='Acme &amp; Co'><title>Wrong</title>", "Acme & Co"),
            ("<title> Acme &amp; &#67;o </title>", "Acme & Co"),
            (
                "<meta property=og:site_name content='Brand\u{0001}" + String(repeating: "A", count: 200) + "'>",
                "Brand" + String(repeating: "A", count: 115)),
        ]
        for (metadata, expected) in fixtures {
            let site = Site([
                "https://company.com/": Self.response(
                    metadata + "<link rel=icon href='mark.svg'>",
                    "https://company.com/welcome/",
                    "text/html"),
                "https://company.com/welcome/mark.svg": Self.response("svg", "https://company.com/welcome/mark.svg"),
            ])
            let result = await Discovery.discover(domain: "company.com", fetch: { try await site.fetch($0, limit: $1) })
            #expect(result.first?.url.absoluteString == "https://company.com/welcome/mark.svg")
            #expect(result.first?.siteName == expected)
        }
    }

    @Test func `adequate declared raster sizes outrank many tiny HTML and manifest icons`() async throws {
        for manifest in [false, true] {
            let sizes = [36, 48, 57, 60, 72, 96, 512, 256, 1024]
            let declarations = manifest
                ? "<link rel=manifest href='/app.json'>"
                : sizes.map { "<link rel=apple-touch-icon sizes='\($0)x\($0)' href='/\($0).png'>" }.joined()
            var pages = [
                "https://company.com/": Self.response(declarations, "https://company.com/", "text/html"),
            ]
            if manifest {
                let icons = sizes.map { ["src": "\($0).png", "sizes": "\($0)x\($0)"] }
                let data = try? JSONSerialization.data(withJSONObject: ["icons": icons])
                pages["https://company.com/app.json"] = try .init(
                    data: data ?? Data(),
                    url: #require(URL(string: "https://company.com/app.json")),
                    mimeType: "application/json")
            }
            for size in sizes {
                pages["https://company.com/\(size).png"] = Self.response(
                    "png", "https://company.com/\(size).png", "image/png")
            }
            let site = Site(pages)
            let result = await Discovery.discover(domain: "company.com", fetch: { try await site.fetch($0, limit: $1) })
            #expect(result.map(\.url.lastPathComponent) == ["512.png", "256.png", "1024.png", "96.png", "72.png"])
        }
    }

    @Test func `HTML prefixes cutting a multibyte character preserve earlier Unicode metadata`() async {
        let head = "<meta property=og:site_name content='Café &amp; Co'><link rel=icon href='/mark.svg'>"
        let html = head + String(repeating: "x", count: 524_287 - Data(head.utf8).count) + "🙂more body"
        let site = Site([
            "https://company.com/": Self.response(html, "https://company.com/", "text/html"),
            "https://company.com/mark.svg": Self.response("svg", "https://company.com/mark.svg"),
        ])
        let result = await Discovery.discover(domain: "company.com", fetch: { try await site.fetch($0, limit: $1) })
        #expect(result.first?.url.lastPathComponent == "mark.svg")
        #expect(result.first?.siteName == "Café & Co")
    }
}
