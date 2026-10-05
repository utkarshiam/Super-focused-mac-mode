import Foundation

// MARK: - Models

struct GmailRef: Hashable, Sendable {
    var id: String
    var threadID: String
}

/// As much of an email as Docket reads: who, subject, Gmail's snippet, when. Never the body.
struct GmailMessage: Hashable, Sendable {
    var id: String
    var threadID: String
    var sender: MailSender
    var subject: String?
    var snippet: String
    var date: Date
    var labels: Set<String>

    /// One suggestion per conversation: "gmail:<threadId>".
    var externalID: String { Self.externalID(thread: threadID) }
    static func externalID(thread: String) -> String { "gmail:\(thread)" }
}

/// A From header: "Sam Lee <sam@example.com>".
struct MailSender: Hashable, Sendable {
    var name: String?
    var address: String?

    init(name: String?, address: String?) {
        self.name = name
        self.address = address
    }

    init(header raw: String) {
        let header = MailText.decodeEncodedWords(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        var name: String?
        var address: String?
        if let open = header.lastIndex(of: "<"), let close = header[open...].firstIndex(of: ">") {
            address = String(header[header.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
            name = String(header[..<open])
        } else if header.contains("@") {
            // "sam@example.com (Sam Lee)"
            if let open = header.firstIndex(of: "("), let close = header.lastIndex(of: ")"), open < close {
                name = String(header[header.index(after: open)..<close])
                address = String(header[..<open]).trimmingCharacters(in: .whitespaces)
            } else {
                address = header
            }
        } else {
            name = header
        }
        let cleanName = name?.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ").union(.whitespacesAndNewlines))
            .replacingOccurrences(of: "\\\"", with: "\"")
        self.name = cleanName?.isEmpty == false ? cleanName : nil
        self.address = address?.isEmpty == false ? address : nil
    }

    var displayName: String { name ?? address ?? "Someone" }

    /// "Sam Lee <sam@example.com>", for AI.
    var full: String {
        switch (name, address) {
        case let (name?, address?): "\(name) <\(address)>"
        default: displayName
        }
    }

    /// "Sam" from "Sam Lee", "Lee, Sam" or "sam.lee@example.com".
    var firstName: String {
        if let name {
            let parts = name.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let given = parts.count == 2 && !parts[1].isEmpty ? parts[1] : name
            if let word = given.split(separator: " ").first, !word.contains("@") { return String(word) }
        }
        if let local = address?.split(separator: "@").first,
           let word = local.split(whereSeparator: { ".-_+".contains($0) }).first, !word.isEmpty {
            return word.allSatisfy(\.isLetter) ? word.prefix(1).uppercased() + word.dropFirst().lowercased() : String(word)
        }
        return "them"
    }
}

// MARK: - Client

/// Gmail's REST API with read-only access (the gmail.readonly scope). Retries once with a fresh
/// access token on 401.
struct GmailClient: Sendable {
    let session: GoogleSession
    var transport: IntegrationHTTP.Transport = IntegrationHTTP.live

    static let api = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/")!
    /// Starred in the last 30 days.
    static let starredQuery = "is:starred newer_than:30d"
    /// Unread, important mail from the last two days that isn't a promotion, social or update.
    static let needsReplyQuery = "is:inbox is:unread is:important newer_than:2d -category:promotions -category:social -category:updates"

    /// The conversation in Gmail on the web: https://mail.google.com/mail/u/<email>/#all/<threadId>.
    static func threadLink(account: String, threadID: String) -> URL? {
        guard threadID.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        let user = account.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? account
        return URL(string: "https://mail.google.com/mail/u/\(user)/#all/\(threadID)")
    }

    func get<Reply: Decodable>(_ path: String, query: [(String, String)] = [], as type: Reply.Type) async throws -> Reply {
        guard var components = URLComponents(url: Self.api.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw IntegrationError.unexpected(.gmail, "a bad address")
        }
        components.percentEncodedQuery = query.isEmpty ? nil : IntegrationHTTP.encode(query)
        guard let url = components.url else { throw IntegrationError.unexpected(.gmail, "a bad address") }
        var refreshed = false
        while true {
            let token = refreshed ? try await session.refreshAccessToken() : try await session.accessToken()
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await IntegrationHTTP.send(request, via: transport, service: .gmail)
            if response.statusCode == 401, !refreshed {
                refreshed = true
                continue
            }
            guard (200..<300).contains(response.statusCode) else { throw Self.error(status: response.statusCode, data: data) }
            do {
                return try JSONDecoder().decode(Reply.self, from: data)
            } catch {
                throw IntegrationError.unexpected(.gmail, "an unreadable reply")
            }
        }
    }

    func profileEmail() async throws -> String {
        let reply = try await get("profile", as: ProfileReply.self)
        guard let email = reply.emailAddress, !email.isEmpty else { throw IntegrationError.unexpected(.gmail, "no address") }
        return email
    }

    /// Ids of messages matching a Gmail search, newest first.
    func messageRefs(matching query: String, max: Int) async throws -> [GmailRef] {
        let reply = try await get("messages", query: [("q", query), ("maxResults", "\(max)")], as: ListReply.self)
        return (reply.messages ?? []).compactMap { ref in
            guard let id = ref.id, let thread = ref.threadId, !id.isEmpty, !thread.isEmpty else { return nil }
            return GmailRef(id: id, threadID: thread)
        }
    }

    /// From, Subject, Date and the snippet; never the body.
    func message(_ id: String) async throws -> GmailMessage {
        guard !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber }) else { throw IntegrationError.unexpected(.gmail, "a bad message id") }
        let reply = try await get("messages/\(id)", query: [("format", "metadata"), ("metadataHeaders", "From"),
                                                          ("metadataHeaders", "Subject"), ("metadataHeaders", "Date")],
                                  as: MessageReply.self)
        guard let message = GmailMessage(reply) else { throw IntegrationError.unexpected(.gmail, "a message without an id") }
        return message
    }

    /// Several messages, a few at a time. Ones that vanished since they were listed are skipped.
    func messages(_ refs: [GmailRef], concurrency: Int = 5) async throws -> [GmailMessage] {
        let results = await IntegrationHTTP.concurrentMap(refs, limit: concurrency) { ref -> Result<GmailMessage, IntegrationError> in
            do {
                return .success(try await message(ref.id))
            } catch {
                return .failure(IntegrationError.wrap(error, .gmail))
            }
        }
        var messages: [GmailMessage] = []
        for result in results {
            switch result {
            case .success(let m): messages.append(m)
            case .failure(.unexpected): continue
            case .failure(let error): throw error
            }
        }
        return messages
    }

    /// Google's error replies in plain words.
    static func error(status: Int, data: Data) -> IntegrationError {
        let body = try? JSONDecoder().decode(ErrorReply.self, from: data)
        let reasons = Set((body?.error?.errors ?? []).compactMap(\.reason) + (body?.error?.details ?? []).compactMap(\.reason))
        let message = (body?.error?.message ?? "").lowercased()
        if status == 429 || reasons.contains("rateLimitExceeded") || reasons.contains("userRateLimitExceeded") || reasons.contains("RATE_LIMIT_EXCEEDED") {
            return .rateLimited(.gmail, retryAfter: 60)
        }
        if status == 401 { return .signedOut(.gmail) }
        if reasons.contains("accessNotConfigured") || reasons.contains("SERVICE_DISABLED") || message.contains("has not been used") || message.contains("is disabled") {
            return .api(.gmail, "The Gmail API is turned off in your Google Cloud project. Turn it on (step 2 in Settings → Connections), then try again.")
        }
        if reasons.contains("insufficientPermissions") || reasons.contains("ACCESS_TOKEN_SCOPE_INSUFFICIENT") || message.contains("insufficient") {
            return .missingPermission(.gmail, "read your email")
        }
        return .unexpected(.gmail, "HTTP \(status)")
    }
}

// MARK: - Replies

private struct ProfileReply: Decodable {
    let emailAddress: String?
}

private struct ListReply: Decodable {
    struct Ref: Decodable {
        let id: String?
        let threadId: String?
    }
    let messages: [Ref]?
}

private struct MessageReply: Decodable {
    struct Payload: Decodable { let headers: [Header]? }
    struct Header: Decodable {
        let name: String?
        let value: String?
    }
    let id: String?
    let threadId: String?
    let snippet: String?
    let internalDate: String?
    let labelIds: [String]?
    let payload: Payload?
}

private struct ErrorReply: Decodable {
    struct Body: Decodable {
        struct Item: Decodable { let reason: String? }
        let code: Int?
        let message: String?
        let status: String?
        let errors: [Item]?
        let details: [Item]?
    }
    let error: Body?
}

private extension GmailMessage {
    init?(_ r: MessageReply) {
        guard let id = r.id, let thread = r.threadId, !id.isEmpty, !thread.isEmpty else { return nil }
        var headers: [String: String] = [:]
        for h in r.payload?.headers ?? [] {
            guard let name = h.name?.lowercased(), let value = h.value, headers[name] == nil else { continue }
            headers[name] = value
        }
        let subject = headers["subject"].map { SlackText.collapsed(MailText.decodeEncodedWords($0)) }
        let date = r.internalDate.flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) }
            ?? headers["date"].flatMap(MailText.date(fromHeader:)) ?? Date()
        self.init(id: id, threadID: thread, sender: MailSender(header: headers["from"] ?? ""),
                  subject: subject?.isEmpty == false ? subject : nil,
                  snippet: SlackText.collapsed(MailText.decodeEntities(r.snippet ?? "")), date: date, labels: Set(r.labelIds ?? []))
    }
}

// MARK: - Text

/// Email header and snippet clean-up.
enum MailText {
    private static let entity = try! NSRegularExpression(pattern: #"&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[a-zA-Z]{2,8});"#)
    private static let named: [String: String] = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "#39": "'"]

    /// Gmail snippets are HTML-escaped: "Friday&#39;s" → "Friday's".
    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in entity.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let body = ns.substring(with: m.range(at: 1))
            out += character(for: body) ?? ns.substring(with: m.range)
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }

    private static func character(for body: String) -> String? {
        if let known = named[body.lowercased()] { return known }
        guard body.hasPrefix("#") else { return nil }
        let digits = body.dropFirst()
        let value = digits.first == "x" || digits.first == "X" ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
        return value.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
    }

    private static let encodedWord = try! NSRegularExpression(pattern: #"=\?([^?\s]+)\?([bBqQ])\?([^?\s]*)\?="#)

    /// RFC 2047 encoded words in headers: "=?UTF-8?B?U2FtIExlZQ==?=" → "Sam Lee".
    static func decodeEncodedWords(_ s: String) -> String {
        guard s.contains("=?") else { return s }
        let ns = s as NSString
        var out = ""
        var last = 0
        var previousWasWord = false
        for m in encodedWord.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            let gap = ns.substring(with: NSRange(location: last, length: m.range.location - last))
            // Whitespace between two encoded words isn't part of the text.
            if !(previousWasWord && gap.allSatisfy(\.isWhitespace)) { out += gap }
            if let word = decodeWord(charset: ns.substring(with: m.range(at: 1)), encoding: ns.substring(with: m.range(at: 2)),
                                     text: ns.substring(with: m.range(at: 3))) {
                out += word
                previousWasWord = true
            } else {
                out += ns.substring(with: m.range)
                previousWasWord = false
            }
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }

    private static func decodeWord(charset: String, encoding: String, text: String) -> String? {
        let bytes: Data?
        if encoding.uppercased() == "B" {
            var b64 = text
            while b64.count % 4 != 0 { b64 += "=" }
            bytes = Data(base64Encoded: b64)
        } else {
            var data = Data()
            var chars = Array(text.utf8)[...]
            while let c = chars.popFirst() {
                if c == UInt8(ascii: "_") {
                    data.append(0x20)
                } else if c == UInt8(ascii: "="), chars.count >= 2,
                          let byte = UInt8(String(decoding: chars.prefix(2), as: UTF8.self), radix: 16) {
                    data.append(byte)
                    chars = chars.dropFirst(2)
                } else {
                    data.append(c)
                }
            }
            bytes = data
        }
        guard let bytes else { return nil }
        // "UTF-8*en" (RFC 2231 language) → "UTF-8".
        let name = charset.split(separator: "*").first.map(String.init) ?? charset
        let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        let encoding = cf == kCFStringEncodingInvalidId ? String.Encoding.utf8 : String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
        return String(data: bytes, encoding: encoding) ?? String(data: bytes, encoding: .isoLatin1)
    }

    private static let replyPrefix = try! NSRegularExpression(pattern: #"^\s*((re|fwd?|aw|wg|sv|vs|tr)(\[\d+\])?\s*:\s*)+"#, options: [.caseInsensitive])

    /// "Re: Fwd: Q3 numbers" → "Q3 numbers".
    static func cleanSubject(_ subject: String) -> String {
        let ns = subject as NSString
        let stripped = replyPrefix.stringByReplacingMatches(in: subject, range: NSRange(location: 0, length: ns.length), withTemplate: "")
        return SlackText.collapsed(stripped)
    }

    private static let dateFormatters: [DateFormatter] = ["EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z"].map {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = $0
        return f
    }

    /// An RFC 2822 Date header ("Mon, 5 Oct 2026 10:42:00 -0700", with or without "(PDT)").
    static func date(fromHeader header: String) -> Date? {
        var text = header.trimmingCharacters(in: .whitespaces)
        if let paren = text.firstIndex(of: "(") { text = String(text[..<paren]).trimmingCharacters(in: .whitespaces) }
        return dateFormatters.lazy.compactMap { $0.date(from: text) }.first
    }
}
