import Foundation

/// Fetches a web page and pulls out what's worth keeping: title, readable text, preview image.
/// Offline under XCTest, like the Gemini transport; tests pass a fake.
public struct LinkFetcher: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// Pages bigger than this are cut (the readable part is near the top anyway).
    public static let maxBytes = 3 * 1024 * 1024
    /// Readable text kept per page.
    public static let maxTextCharacters = 20_000

    public var transport: Transport

    public init(transport: Transport? = nil) {
        self.transport = transport ?? (GeminiMemoryAI.isUnitTesting ? GeminiMemoryAI.offlineTransport : Self.liveTransport)
    }

    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 40
        config.urlCache = nil
        config.httpShouldSetCookies = false
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    public static let liveTransport: Transport = { request in try await session.data(for: request) }

    /// What a page gave.
    public struct Page: Equatable, Sendable {
        public var title: String
        public var text: String
        public var imageURL: String?
        public var siteName: String?
        public var description: String?
    }

    /// Fetches `address` (http/https only). Throws `MemoryAIError.network` for failures, so the
    /// processor treats them like any other offline moment.
    public func fetch(_ address: String) async throws -> Page {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw MemoryAIError.badResponse("That isn't a web address Docket can open.")
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml;q=0.9,*/*;q=0.5", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(request)
        } catch {
            let mapped = GeminiMemoryAI.transportError(error)
            if case MemoryAIError.network(let detail) = mapped {
                throw MemoryAIError.network(detail.replacingOccurrences(of: "Google's servers", with: "The page"))
            }
            throw mapped
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            if http.statusCode == 429 || http.statusCode >= 500 { throw MemoryAIError.network("The page didn't load (HTTP \(http.statusCode)).") }
            throw MemoryAIError.badResponse("The page couldn't be opened (HTTP \(http.statusCode)).")
        }
        let html = Self.decode(data.prefix(Self.maxBytes))
        return Self.extract(html: html, baseURL: url)
    }

    /// UTF-8 (lossy when the page was cut mid-character), else Windows-1252 for old Latin-1 pages.
    static func decode(_ data: Data) -> String {
        if data.count < maxBytes, String(data: data, encoding: .utf8) == nil, let latin = String(data: data, encoding: .windowsCP1252) {
            return latin
        }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: HTML

    /// Title (og:title, else <title>), readable text (<article> or <main> when present, else <body>;
    /// scripts, styles, navigation, headers, footers and forms removed), og:image made absolute.
    public static func extract(html: String, baseURL: URL? = nil) -> Page {
        let ogTitle = meta(html, "og:title") ?? meta(html, "twitter:title")
        let docTitle = firstMatch(html, #"<title[^>]*>([\s\S]*?)</title>"#).map(decodeEntities)
        let title = TextFold.tidy(ogTitle ?? docTitle ?? "").replacingOccurrences(of: "\n", with: " ")
        let description = (meta(html, "og:description") ?? meta(html, "description")).map { TextFold.tidy($0) }
        var image = meta(html, "og:image") ?? meta(html, "twitter:image")
        if let raw = image, let base = baseURL, let absolute = URL(string: raw, relativeTo: base)?.absoluteURL {
            image = absolute.absoluteString
        }

        var content = html
        for tag in ["script", "style", "noscript", "svg", "template", "iframe", "head"] {
            content = content.replacingOccurrences(of: "<\(tag)\\b[\\s\\S]*?</\(tag)>", with: " ", options: [.regularExpression, .caseInsensitive])
        }
        content = content.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: " ", options: .regularExpression)
        if let main = firstMatch(content, #"<article\b[^>]*>([\s\S]*?)</article>"#) ?? firstMatch(content, #"<main\b[^>]*>([\s\S]*?)</main>"#),
           main.count > 400 {
            content = main
        } else if let body = firstMatch(content, #"<body\b[^>]*>([\s\S]*)</body>"#) {
            content = body
        }
        for tag in ["nav", "header", "footer", "aside", "form", "button"] {
            content = content.replacingOccurrences(of: "<\(tag)\\b[\\s\\S]*?</\(tag)>", with: " ", options: [.regularExpression, .caseInsensitive])
        }
        // Block elements become line breaks so paragraphs survive.
        content = content.replacingOccurrences(of: "<(br|/p|/div|/li|/h[1-6]|/tr|/blockquote|/section)\\b[^>]*>", with: "\n",
                                               options: [.regularExpression, .caseInsensitive])
        content = content.replacingOccurrences(of: "<li\\b[^>]*>", with: "\n- ", options: [.regularExpression, .caseInsensitive])
        content = content.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        var text = TextFold.tidy(decodeEntities(content))
        if text.count > maxTextCharacters { text = String(text.prefix(maxTextCharacters)) }
        let site = meta(html, "og:site_name") ?? baseURL?.host
        return Page(title: title, text: text, imageURL: image, siteName: site, description: description)
    }

    /// `<meta property|name="key" content="…">` in either attribute order.
    static func meta(_ html: String, _ key: String) -> String? {
        let k = NSRegularExpression.escapedPattern(for: key)
        let patterns = [
            #"<meta[^>]+(?:property|name)\s*=\s*["']"# + k + #"["'][^>]*content\s*=\s*["']([^"']*)["']"#,
            #"<meta[^>]+content\s*=\s*["']([^"']*)["'][^>]*(?:property|name)\s*=\s*["']"# + k + #"["']"#,
        ]
        for p in patterns {
            if let value = firstMatch(html, p).map(decodeEntities)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    static func firstMatch(_ text: String, _ pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = s
        let named = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'",
                     "&rsquo;": "’", "&lsquo;": "‘", "&ldquo;": "“", "&rdquo;": "”", "&mdash;": "—", "&ndash;": "–",
                     "&hellip;": "…", "&copy;": "©"]
        for (entity, value) in named where entity != "&amp;" { out = out.replacingOccurrences(of: entity, with: value) }
        if let regex = try? NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);") {
            let ns = out as NSString
            var result = ""
            var last = 0
            for m in regex.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
                result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                let hex = ns.substring(with: m.range(at: 1)) == "x"
                let digits = ns.substring(with: m.range(at: 2))
                if let code = UInt32(digits, radix: hex ? 16 : 10), let scalar = Unicode.Scalar(code) {
                    result.unicodeScalars.append(scalar)
                } else {
                    result += ns.substring(with: m.range)
                }
                last = m.range.location + m.range.length
            }
            result += ns.substring(from: last)
            out = result
        }
        return out.replacingOccurrences(of: "&amp;", with: "&")
    }
}
