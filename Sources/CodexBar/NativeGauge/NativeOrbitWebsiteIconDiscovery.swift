import Darwin
import Foundation

/// Fetches only public website metadata and artwork; never receives an account address or credentials.
struct NativeOrbitWebsiteIconDiscovery {
    struct Response: Sendable {
        let data: Data
        let url: URL
        let mimeType: String?
    }

    struct Candidate: Sendable {
        let data: Data
        let url: URL
        let prefersAlpha: Bool
        let method: String
        let siteName: String?

        init(data: Data, url: URL, prefersAlpha: Bool, method: String, siteName: String? = nil) {
            self.data = data
            self.url = url
            self.prefersAlpha = prefersAlpha
            self.method = method
            self.siteName = siteName
        }
    }

    typealias Fetch = @Sendable (URL, Int) async throws -> Response

    /// Complete assets reject overflow; landing documents retain only a bounded metadata prefix.
    struct ResponseBody {
        let limit: Int
        let acceptsPrefix: Bool
        private(set) var data = Data()

        init?(limit: Int, expectedLength: Int64, mimeType: String?, allowsHTMLPrefix: Bool = false) {
            self.limit = limit
            self.acceptsPrefix = allowsHTMLPrefix && NativeOrbitWebsiteIconDiscovery.isHTMLMIME(mimeType)
            guard limit > 0, self.acceptsPrefix || expectedLength <= limit else { return nil }
        }

        mutating func append(_ chunk: Data) throws -> Bool {
            let remaining = self.limit - self.data.count
            guard self.acceptsPrefix || chunk.count <= remaining else {
                throw URLError(.dataLengthExceedsMaximum)
            }
            self.data.append(contentsOf: chunk.prefix(remaining))
            return self.acceptsPrefix && self.data.count == self.limit
        }
    }

    private struct Link {
        let url: URL
        let rank: Int
        let prefersAlpha: Bool
        let method: String
        var rasterSizePriority: Int = 0
    }

    static func normalizedDomain(_ raw: String) -> String? {
        var input = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !input.isEmpty, !input.contains(where: { "/\\@:%?#[]".contains($0) || $0.isWhitespace }),
              !input.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        if input.hasSuffix(".") { input.removeLast() }
        guard let value = URL(string: "https://\(input)/")?.host?.lowercased(), value.count <= 253,
              value.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-.")
                      .contains($0) }) else { return nil }
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2,
              labels.allSatisfy({ !$0.isEmpty && $0.count <= 63 && $0.first != "-" && $0.last != "-" }),
              let suffix = labels.last, suffix.contains(where: \.isLetter),
              ![
                  "local",
                  "localhost",
                  "localdomain",
                  "internal",
                  "lan",
                  "home",
                  "test",
                  "invalid",
                  "example",
                  "onion",
                  "arpa",
              ].contains(String(suffix)) else { return nil }
        var address = in_addr()
        guard inet_aton(value, &address) == 0 else { return nil }
        return value
    }

    static func isPublicIPv4Address(_ address: in_addr) -> Bool {
        let ip = address.s_addr.bigEndian
        let first = (ip >> 24) & 255
        let second = (ip >> 16) & 255
        let third = (ip >> 8) & 255
        let fourth = ip & 255
        guard first != 0, first != 10, first != 127, first < 224,
              !(first == 100 && (64...127).contains(second)),
              !(first == 169 && second == 254), !(first == 172 && (16...31).contains(second)),
              !(first == 192 && second == 168),
              !(first == 192 && second == 0 && third == 0 && ![9, 10].contains(fourth)),
              !(first == 192 && second == 0 && third == 2),
              !(first == 192 && second == 88 && third == 99),
              !(first == 198 && [18, 19].contains(second)),
              !(first == 198 && second == 51 && third == 100),
              !(first == 203 && second == 0 && third == 113) else { return false }
        return true
    }

    static func isPublicURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host,
              self.normalizedDomain(host) != nil else { return false }
        return true
    }

    static func discover(domain: String, fetch: Fetch? = nil) async -> [Candidate] {
        guard let domain = self.normalizedDomain(domain),
              let root = URL(string: "https://\(domain)/") else { return [] }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(16))
        let budget = RequestBudget()
        var requested: Set<URL> = []
        func request(_ url: URL, limit: Int, allowsHTMLPrefix: Bool = false) async -> Response? {
            guard self.isPublicURL(url), !Task.isCancelled, clock.now < deadline,
                  !requested.contains(url), budget.consume() else { return nil }
            requested.insert(url)
            let result: Response?
            if let fetch {
                result = try? await fetch(url, limit)
            } else {
                let remaining = clock.now.duration(to: deadline)
                let seconds = Double(remaining.components.seconds) + Double(remaining.components.attoseconds) / 1e18
                result = try? await PublicTransport.fetch(
                    url, limit: limit, timeout: min(4, seconds), budget: budget, allowsHTMLPrefix: allowsHTMLPrefix)
            }
            guard let result, self.isPublicURL(result.url), clock.now < deadline,
                  var body = ResponseBody(
                      limit: limit,
                      expectedLength: Int64(result.data.count),
                      mimeType: result.mimeType,
                      allowsHTMLPrefix: allowsHTMLPrefix),
                  (try? body.append(result.data)) != nil else { return nil }
            return Response(data: body.data, url: result.url, mimeType: result.mimeType)
        }

        var landing = await request(root, limit: 524_288, allowsHTMLPrefix: true)
        if landing == nil, !domain.hasPrefix("www."), let www = URL(string: "https://www.\(domain)/") {
            landing = await request(www, limit: 524_288, allowsHTMLPrefix: true)
        }
        var links: [Link] = []
        var siteName: String?
        if let landing, self.isHTML(landing) {
            // A bounded UTF-8 prefix may end within a code point; preserve all earlier metadata.
            // swiftlint:disable:next optional_data_string_conversion
            let html = String(decoding: landing.data, as: UTF8.self)
            let tags = self.metadataTags(html)
            siteName = self.siteName(html: html, tags: tags)
            let base = tags.first(where: { $0.name == "base" }).flatMap { $0.attributes["href"] }
                .flatMap { self.resolve($0, base: landing.url) } ?? landing.url
            var manifest: URL?
            for tag in tags where tag.name == "link" {
                guard let href = tag.attributes["href"], let url = self.resolve(href, base: base) else { continue }
                let rel = Set((tag.attributes["rel"] ?? "").lowercased().split(whereSeparator: \.isWhitespace))
                if rel.contains("manifest"), manifest == nil { manifest = url }
                if rel.contains("mask-icon") {
                    links.append(Link(url: url, rank: 0, prefersAlpha: true, method: "safari-mask-icon"))
                } else if rel.contains("icon") || rel.contains("apple-touch-icon") || rel
                    .contains("apple-touch-icon-precomposed")
                {
                    let svg = url.pathExtension.lowercased() == "svg"
                        || tag.attributes["type"]?.lowercased() == "image/svg+xml"
                    links.append(Link(
                        url: url,
                        rank: svg ? 2 : 3,
                        prefersAlpha: false,
                        method: "html-icon",
                        rasterSizePriority: svg ? 0 : self.rasterSizePriority(tag.attributes["sizes"])))
                }
            }
            if let manifest, let response = await request(manifest, limit: 131_072), self.isManifest(response),
               let object = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
               let icons = object["icons"] as? [[String: Any]]
            {
                for icon in icons.prefix(32) {
                    guard let source = icon["src"] as? String,
                          let url = self.resolve(source, base: response.url) else { continue }
                    let purpose = (icon["purpose"] as? String ?? "any").lowercased()
                        .split(whereSeparator: \.isWhitespace)
                    let monochrome = purpose.contains("monochrome")
                    let svg = url.pathExtension.lowercased() == "svg"
                        || (icon["type"] as? String)?.lowercased() == "image/svg+xml"
                    links.append(Link(
                        url: url,
                        rank: monochrome ? 1 : svg ? 2 : 3,
                        prefersAlpha: monochrome,
                        method: monochrome ? "manifest-monochrome" : "manifest-icon",
                        rasterSizePriority: monochrome || svg ? 0 : self.rasterSizePriority(icon["sizes"] as? String)))
                }
            }
        }
        // Declared artwork outranks guessed filenames, even when the guess is an SVG.
        let fallbackRoot = landing?.url ?? root
        for (path, alpha) in [("/safari-pinned-tab.svg", true), ("/favicon.svg", false), ("/favicon.ico", false)] {
            if let url = self.resolve(path, base: fallbackRoot) {
                links.append(Link(url: url, rank: 4, prefersAlpha: alpha, method: "conventional-icon"))
            }
        }
        let sorted = links.enumerated().sorted {
            if $0.element.rank != $1.element.rank { return $0.element.rank < $1.element.rank }
            if $0.element.rasterSizePriority != $1.element.rasterSizePriority {
                return $0.element.rasterSizePriority > $1.element.rasterSizePriority
            }
            return $0.offset < $1.offset
        }
        var candidates: [Candidate] = []
        var returned: Set<URL> = []
        for (_, link) in sorted {
            guard candidates.count < 5, budget.hasRemaining, clock.now < deadline else { break }
            guard let response = await request(link.url, limit: 1_048_576), self.isImage(response),
                  returned.insert(response.url).inserted else { continue }
            candidates.append(Candidate(
                data: response.data,
                url: response.url,
                prefersAlpha: link.prefersAlpha,
                method: link.method,
                siteName: siteName))
        }
        return candidates
    }

    private static func rasterSizePriority(_ raw: String?) -> Int {
        (raw ?? "").lowercased().split(whereSeparator: \.isWhitespace).compactMap { token -> Int? in
            let dimensions = token.split(separator: "x")
            guard dimensions.count == 2, let width = Int(dimensions[0]), let height = Int(dimensions[1]),
                  width > 0, height > 0 else { return nil }
            let smaller = min(width, height)
            // Prefer enough source detail without choosing unnecessarily large decoded images.
            if smaller >= 128, max(width, height) <= 512 { return 3000 + smaller }
            if smaller > 512 { return 1000 }
            return min(smaller, 127)
        }.max() ?? 0
    }

    private static func resolve(_ raw: String, base: URL) -> URL? {
        guard !raw.isEmpty, let resolved = URL(string: raw, relativeTo: base)?.absoluteURL,
              var parts = URLComponents(url: resolved, resolvingAgainstBaseURL: true) else { return nil }
        parts.fragment = nil
        guard let url = parts.url, self.isPublicURL(url) else { return nil }
        return url
    }

    private static func isHTML(_ response: Response) -> Bool {
        self.isHTMLMIME(response.mimeType)
    }

    private static func isHTMLMIME(_ mimeType: String?) -> Bool {
        let mime = mimeType?.lowercased().split(separator: ";").first.map(String.init)
        return mime == nil || mime == "text/html" || mime == "application/xhtml+xml"
    }

    private static func isManifest(_ response: Response) -> Bool {
        let mime = response.mimeType?.lowercased().split(separator: ";").first.map(String.init)
        return mime == nil || ["application/json", "application/manifest+json", "text/json", "application/octet-stream"]
            .contains(mime ?? "")
    }

    private static func isImage(_ response: Response) -> Bool {
        guard !response.data.isEmpty else { return false }
        let prefix = (String(data: response.data.prefix(512), encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !prefix.contains("<html"), !prefix.contains("<!doctype html") else { return false }
        let mime = response.mimeType?.lowercased().split(separator: ";").first.map(String.init)
        if let mime, mime.hasPrefix("image/") { return true }
        let ext = response.url.pathExtension.lowercased()
        if mime == nil || mime == "application/octet-stream" {
            return ["svg", "png", "ico", "jpg", "jpeg", "webp", "gif", "avif"].contains(ext)
        }
        return ext == "svg" && ["application/xml", "text/xml", "text/plain"].contains(mime ?? "") && prefix
            .contains("<svg")
    }

    private struct Tag {
        let name: String
        let attributes: [String: String]
    }

    /// Tokenizes tags rather than evaluating markup, scripts, or embedded page resources.
    private static func metadataTags(_ html: String) -> [Tag] {
        let pattern = #"<!--[\s\S]*?(?:-->|$)|<(script|style|textarea|title)\b[^>]*>[\s\S]*?(?:</\1\s*>|$)"#
            + #"|<(link|base|meta)\b((?:[^>"']|"[^"]*"|'[^']*')*)>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let source = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: source.length))
        var tags: [Tag] = []
        for match in matches {
            guard match.range(at: 2).location != NSNotFound else { continue }
            tags.append(Tag(
                name: source.substring(with: match.range(at: 2)).lowercased(),
                attributes: self.attributes(source.substring(with: match.range(at: 3)))))
            if tags.count >= 128 { break }
        }
        return tags
    }

    private static func siteName(html: String, tags: [Tag]) -> String? {
        for key in ["og:site_name", "application-name"] {
            for tag in tags where tag.name == "meta" {
                let name = (tag.attributes["property"] ?? tag.attributes["name"])?.lowercased()
                if name == key, let content = tag.attributes["content"], let name = self.cleanSiteName(content) {
                    return name
                }
            }
        }
        let pattern = #"<!--[\s\S]*?(?:-->|$)|<(script|style|textarea)\b[^>]*>[\s\S]*?(?:</\1\s*>|$)"#
            + #"|<title\b[^>]*>([\s\S]*?)</title\s*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let source = html as NSString
        for match in regex.matches(in: html, range: NSRange(location: 0, length: source.length))
            where match.range(at: 2).location != NSNotFound
        {
            return self.cleanSiteName(source.substring(with: match.range(at: 2)))
        }
        return nil
    }

    private static func cleanSiteName(_ raw: String) -> String? {
        let text = self.entities(raw).replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression)
        let scalars = text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let clean = String(String.UnicodeScalarView(scalars)).split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return clean.isEmpty ? nil : String(clean.prefix(120))
    }

    private static func attributes(_ raw: String) -> [String: String] {
        let pattern = #"([^\s=/'"<>`]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+)))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [:] }
        let source = raw as NSString
        var values: [String: String] = [:]
        for match in regex.matches(in: raw, range: NSRange(location: 0, length: source.length)) {
            let name = source.substring(with: match.range(at: 1)).lowercased()
            guard values[name] == nil else { continue }
            let range = (2...4).map { match.range(at: $0) }.first { $0.location != NSNotFound }
            values[name] = range.map { self.entities(source.substring(with: $0)) } ?? ""
        }
        return values
    }

    private static func entities(_ raw: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"&(#x[0-9a-fA-F]+|#[0-9]+|amp|quot|apos|lt|gt);"#) else {
            return raw
        }
        let source = raw as NSString
        var result = raw
        for match in regex.matches(in: raw, range: NSRange(location: 0, length: source.length)).reversed() {
            let entity = source.substring(with: match.range(at: 1))
            // Provider-specific by design: amp is an HTML entity name decoded from icon links, unrelated to a provider.
            let named = ["amp": "&", "quot": "\"", "apos": "'", "lt": "<", "gt": ">"]
            let number: UInt32? = entity.hasPrefix("#x") ? UInt32(entity.dropFirst(2), radix: 16)
                : entity.hasPrefix("#") ? UInt32(entity.dropFirst()) : nil
            let replacement = named[entity] ?? number.flatMap(UnicodeScalar.init).map(String.init)
            if let replacement, let range = Range(match.range, in: result) {
                result.replaceSubrange(range, with: replacement)
            }
        }
        return result
    }
}

extension NativeOrbitWebsiteIconDiscovery {
    fileprivate final class RequestBudget: @unchecked Sendable {
        private let lock = NSLock()
        private var remaining = 8

        var hasRemaining: Bool {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.remaining > 0
        }

        func consume() -> Bool {
            self.lock.lock()
            defer { self.lock.unlock() }
            guard self.remaining > 0 else { return false }
            self.remaining -= 1
            return true
        }
    }

    /// Each operation owns an ephemeral, credential-free session and a bounded data accumulator.
    fileprivate final class PublicTransport: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let limit: Int
        private let budget: RequestBudget
        private let deadline: ContinuousClock.Instant
        private let allowsHTMLPrefix: Bool
        private var body: ResponseBody?
        private var response: HTTPURLResponse?
        private var redirects = 0
        private var continuation: CheckedContinuation<Response, any Error>?
        private var session: URLSession?

        private init(limit: Int, timeout: Double, budget: RequestBudget, allowsHTMLPrefix: Bool) {
            self.limit = limit
            self.budget = budget
            self.allowsHTMLPrefix = allowsHTMLPrefix
            self.deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        }

        static func fetch(
            _ url: URL,
            limit: Int,
            timeout: Double,
            budget: RequestBudget,
            allowsHTMLPrefix: Bool) async throws -> Response
        {
            let start = ContinuousClock.now
            guard timeout > 0,
                  await self.resolvesPublicly(url, timeout: timeout) else { throw URLError(.cannotFindHost) }
            let elapsed = start.duration(to: .now)
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            let remaining = timeout - seconds
            guard remaining > 0, !Task.isCancelled else { throw URLError(.timedOut) }
            let delegate = PublicTransport(
                limit: limit,
                timeout: remaining,
                budget: budget,
                allowsHTMLPrefix: allowsHTMLPrefix)
            return try await withCheckedThrowingContinuation { continuation in
                delegate.continuation = continuation
                let configuration = URLSessionConfiguration.ephemeral
                configuration.httpCookieStorage = nil
                configuration.httpShouldSetCookies = false
                configuration.urlCredentialStorage = nil
                configuration.urlCache = nil
                configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                configuration.timeoutIntervalForRequest = remaining
                configuration.timeoutIntervalForResource = remaining
                // Explicitly avoid authenticated system proxy configurations for public artwork.
                configuration.connectionProxyDictionary = [:]
                let queue = OperationQueue()
                queue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
                delegate.session = session
                session.dataTask(with: self.request(url, timeout: remaining)).resume()
            }
        }

        private static func request(_ url: URL, timeout: Double) -> URLRequest {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
            request.httpShouldHandleCookies = false
            request.setValue(
                "image/*,text/html,application/manifest+json,application/json;q=0.9",
                forHTTPHeaderField: "Accept")
            return request
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void)
        {
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let url = http.url, NativeOrbitWebsiteIconDiscovery.isPublicURL(url),
                  let body = ResponseBody(
                      limit: self.limit,
                      expectedLength: response.expectedContentLength,
                      mimeType: response.mimeType,
                      allowsHTMLPrefix: self.allowsHTMLPrefix)
            else {
                completionHandler(.cancel)
                return
            }
            self.response = http
            self.body = body
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard self.continuation != nil else { return }
            do {
                if try self.body?.append(data) == true { self.completeResponse() }
            } catch {
                self.finish(.failure(error))
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            if let error {
                self.finish(.failure(error))
            } else { self.completeResponse() }
        }

        private func completeResponse() {
            guard let response = self.response, let url = response.url, let body = self.body else {
                self.finish(.failure(URLError(.badServerResponse)))
                return
            }
            self.finish(.success(Response(data: body.data, url: url, mimeType: response.mimeType)))
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void)
        {
            self.redirects += 1
            guard self.redirects <= 3, let url = request.url, NativeOrbitWebsiteIconDiscovery.isPublicURL(url),
                  self.budget.consume()
            else {
                completionHandler(nil)
                return
            }
            let remaining = ContinuousClock.now.duration(to: self.deadline)
            let seconds = Double(remaining.components.seconds) + Double(remaining.components.attoseconds) / 1e18
            Task {
                guard seconds > 0, await Self.resolvesPublicly(url, timeout: seconds) else {
                    completionHandler(nil)
                    return
                }
                completionHandler(Self.request(url, timeout: seconds))
            }
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?)
                -> Void)
        {
            // Default handling is needed only for server TLS trust; HTTP/proxy/client authentication is forbidden.
            completionHandler(
                challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
                    ? .performDefaultHandling : .cancelAuthenticationChallenge,
                nil)
        }

        private func finish(_ result: Result<Response, any Error>) {
            guard let continuation = self.continuation else { return }
            self.continuation = nil
            self.session?.invalidateAndCancel()
            self.session = nil
            continuation.resume(with: result)
        }

        private final class DNSResult: @unchecked Sendable {
            let lock = NSLock()
            var continuation: CheckedContinuation<Bool, Never>?

            init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }

            func finish(_ result: Bool) {
                self.lock.lock()
                let continuation = self.continuation
                self.continuation = nil
                self.lock.unlock()
                continuation?.resume(returning: result)
            }
        }

        private static func resolvesPublicly(_ url: URL, timeout: Double) async -> Bool {
            guard NativeOrbitWebsiteIconDiscovery.isPublicURL(url), let host = url.host,
                  timeout > 0 else { return false }
            return await withCheckedContinuation { continuation in
                let result = DNSResult(continuation)
                DispatchQueue.global(qos: .utility).async {
                    var hints = addrinfo()
                    hints.ai_family = AF_UNSPEC
                    hints.ai_socktype = SOCK_STREAM
                    var addresses: UnsafeMutablePointer<addrinfo>?
                    guard getaddrinfo(host, "443", &hints, &addresses) == 0, let addresses else {
                        result.finish(false)
                        return
                    }
                    defer { freeaddrinfo(addresses) }
                    var current: UnsafeMutablePointer<addrinfo>? = addresses
                    var found = false
                    while let address = current {
                        guard let socket = address.pointee.ai_addr, self.isPublicAddress(socket) else {
                            result.finish(false)
                            return
                        }
                        found = true
                        current = address.pointee.ai_next
                    }
                    result.finish(found)
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { result.finish(false) }
            }
        }

        private static func isPublicAddress(_ address: UnsafePointer<sockaddr>) -> Bool {
            if Int32(address.pointee.sa_family) == AF_INET {
                let ip = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
                return NativeOrbitWebsiteIconDiscovery.isPublicIPv4Address(ip)
            }
            if Int32(address.pointee.sa_family) == AF_INET6 {
                let ip = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in6.self).pointee.sin6_addr
                return withUnsafeBytes(of: ip) { bytes in
                    // Only global unicast; excludes loopback, mapped IPv4, NAT64, ULA, multicast and link local.
                    guard bytes[0] & 0xE0 == 0x20 else { return false }
                    // Exclude protocol assignments, documentation and 6to4 (which can encode private IPv4).
                    if bytes[0] == 0x20, bytes[1] == 0x01,
                       bytes[2] < 2 || (bytes[2] == 0x0D && bytes[3] == 0xB8) { return false }
                    if bytes[0] == 0x20, bytes[1] == 0x02 { return false }
                    if bytes[0] == 0x3F, bytes[1] == 0xFF, bytes[2] & 0xF0 == 0 { return false }
                    return true
                }
            }
            return false
        }
    }
}
