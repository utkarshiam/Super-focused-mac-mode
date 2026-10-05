import Foundation

// MARK: - Models

struct GmailRef: Hashable, Sendable {
    var id: String
    var threadID: String

    var externalID: String { GmailMessage.externalID(thread: threadID, message: id) }
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

    /// "gmail:<threadId>/<messageId>": one message, filed under its conversation.
    var externalID: String { Self.externalID(thread: threadID, message: id) }

    static func externalID(thread: String, message: String) -> String { "gmail:\(thread)/\(message)" }

    /// The conversation an id from `externalID` belongs to; nil for anything else.
    static func threadID(fromExternalID id: String) -> String? {
        guard id.hasPrefix("gmail:"), let slash = id.firstIndex(of: "/") else { return nil }
        let thread = id[id.index(id.startIndex, offsetBy: "gmail:".count)..<slash]
        return thread.isEmpty ? nil : String(thread)
    }
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
            // "sam@example.com (Sam Lee)": a comment after the address names it. One in front of it
            // ("(Ops desk) desk@example.com") is only a comment.
            if let open = header.firstIndex(of: "("), let close = header.lastIndex(of: ")"), open < close {
                let before = header[..<open].trimmingCharacters(in: .whitespaces)
                if before.contains("@") {
                    name = String(header[header.index(after: open)..<close])
                    address = before
                } else {
                    address = header[header.index(after: close)...].trimmingCharacters(in: .whitespaces)
                }
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

/// Gmail's REST API, with the gmail.modify scope (sign-ins from before stars: gmail.readonly and
/// gmail.compose): reading mail; replying, only when the user clicks Send or Save draft; and starring or
/// unstarring a message when they click its star. It never deletes, archives or changes any other label.
/// Retries once with a fresh access token on 401.
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
        let data = try await perform(path, query: query)
        do {
            return try JSONDecoder().decode(Reply.self, from: data)
        } catch {
            throw IntegrationError.unexpected(.gmail, "an unreadable reply")
        }
    }

    /// One call as the user: a GET, or a POST with a JSON body. Retries once with a fresh access token on
    /// 401 (Gmail did nothing then); anything else that isn't 2xx becomes an `IntegrationError`.
    /// `permission` and `action` word the errors for what the call was for. `repeatable`: doing it twice
    /// does no harm (a star), so a connection lost on the way is only a network problem.
    private func perform(_ path: String, query: [(String, String)] = [], json: Data? = nil,
                         permission: String = GmailClient.readPermission, action: String? = nil,
                         repeatable: Bool = false) async throws -> Data {
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
            if let json {
                request.httpMethod = "POST"
                request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
                request.httpBody = json
            }
            let (data, response): (Data, HTTPURLResponse)
            do {
                (data, response) = try await transport(request)
            } catch {
                // A send that timed out or lost its connection may have gone through all the same: say so,
                // rather than invite a second copy.
                if let action, !repeatable, IntegrationHTTP.mayHaveArrived(error) {
                    throw IntegrationError.api(.gmail, "Gmail didn't answer in time, so Docket can't tell if it managed to \(action). Check Gmail before trying again.")
                }
                throw IntegrationError.wrap(error, .gmail)
            }
            if response.statusCode == 401, !refreshed {
                refreshed = true
                continue
            }
            guard (200..<300).contains(response.statusCode) else {
                throw Self.error(status: response.statusCode, data: data, permission: permission, action: action)
            }
            return data
        }
    }

    /// What Docket asks Google for, in the words of "Docket needs permission to …".
    static let readPermission = "read your email"
    static let composePermission = "send replies and save drafts"
    static let starPermission = "star emails"

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

    /// Google's error replies in plain words. `permission` is what a missing scope would have allowed;
    /// `action` ("send the reply") is set for sending and saving drafts, which are never retried by
    /// themselves, so their errors say what happened instead of promising another try.
    static func error(status: Int, data: Data, permission: String = GmailClient.readPermission, action: String? = nil) -> IntegrationError {
        let body = try? JSONDecoder().decode(ErrorReply.self, from: data)
        let reasons = Set((body?.error?.errors ?? []).compactMap(\.reason) + (body?.error?.details ?? []).compactMap(\.reason))
        let detail = body?.error?.message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let message = detail.lowercased()
        if status == 429 || reasons.contains("rateLimitExceeded") || reasons.contains("userRateLimitExceeded") || reasons.contains("RATE_LIMIT_EXCEEDED") {
            if let action { return .api(.gmail, "Gmail asked Docket to slow down, so it couldn't \(action). Try again in a minute.") }
            return .rateLimited(.gmail, retryAfter: 60)
        }
        if status == 401 { return .signedOut(.gmail) }
        if reasons.contains("accessNotConfigured") || reasons.contains("SERVICE_DISABLED") || message.contains("has not been used") || message.contains("is disabled") {
            return .api(.gmail, "The Gmail API is turned off in your Google Cloud project. Turn it on (step 2 in Settings → Connections), then try again.")
        }
        if reasons.contains("insufficientPermissions") || reasons.contains("ACCESS_TOKEN_SCOPE_INSUFFICIENT") || message.contains("insufficient") {
            return .missingPermission(.gmail, permission)
        }
        if let action, (400..<500).contains(status), !detail.isEmpty {
            // Gmail turned the message down ("Invalid To header"): say what it said.
            return .api(.gmail, "Gmail couldn't \(action) (\(detail.prefix(160))).")
        }
        return .unexpected(.gmail, "HTTP \(status)")
    }
}

// MARK: - The whole message, the conversation, replying

extension IntegrationHTTP {
    /// Whether a request that failed this way may have reached the server anyway (it timed out, or the
    /// connection dropped): a reply it carried may have gone out.
    static func mayHaveArrived(_ error: Error) -> Bool {
        guard let url = error as? URLError else { return false }
        return url.code == .timedOut || url.code == .networkConnectionLost
    }
}

extension GmailClient {
    /// The whole email (format=full): text and HTML bodies, To/Cc, attachments, and what a reply needs.
    func fullMessage(_ id: String) async throws -> GmailFullMessage {
        guard Self.isGmailID(id) else { throw IntegrationError.unexpected(.gmail, "a bad message id") }
        let reply = try await get("messages/\(id)", query: [("format", "full")], as: FullMessageReply.self)
        guard let messageID = reply.id, let threadID = reply.threadId, !messageID.isEmpty, !threadID.isEmpty, let payload = reply.payload else {
            throw IntegrationError.unexpected(.gmail, "a message without an id")
        }
        var root = MIMEPart(gmail: payload)
        // A very long body comes apart from the message, like an attachment.
        for path in Self.detachedBodies(in: root).prefix(Self.detachedBodiesPerMessage) {
            guard let attachmentID = root[path: path].attachmentID else { continue }
            root[path: path].body = try await attachment(messageID: messageID, attachmentID: attachmentID)
        }
        return Self.fullMessage(id: messageID, threadID: threadID, root: root, fetchedAt: Date())
    }

    /// A message's parts as what the inbox shows and a reply needs.
    static func fullMessage(id: String, threadID: String, root: MIMEPart, fetchedAt: Date) -> GmailFullMessage {
        GmailFullMessage(id: id, threadID: threadID, content: messageContent(root, body: MailBody(root), messageID: id, fetchedAt: fetchedAt),
                         replyHeaders: MailReplyHeaders(original: root.headers))
    }

    /// What a message says and carries: its text and HTML bodies, To and Cc, and its files.
    private static func messageContent(_ root: MIMEPart, body: MailBody, messageID id: String, fetchedAt: Date) -> MessageContent {
        MessageContent(text: body.readableText, markup: nil, html: body.html,
                       to: MailSender.list(root.header("To") ?? "").map(\.full),
                       cc: MailSender.list(root.header("Cc") ?? "").map(\.full),
                       attachments: body.files.compactMap { $0.attachment(messageID: id) },
                       fetchedAt: fetchedAt)
    }

    /// The bodies of a message that Gmail sent apart (`detachedBodies`) and Docket fetches: at most this many.
    static let detachedBodiesPerMessage = 4

    /// Where the text and HTML bodies Gmail sent apart are (an attachment id instead of the bytes).
    static func detachedBodies(in root: MIMEPart) -> [[Int]] {
        var paths: [[Int]] = []
        func visit(_ part: MIMEPart, _ path: [Int]) {
            guard part.parts.isEmpty else {
                for (index, child) in part.parts.enumerated() { visit(child, path + [index]) }
                return
            }
            if part.body == nil, part.attachmentID != nil, part.mimeType == "text/plain" || part.mimeType == "text/html",
               part.filename == nil, part.disposition?.value != "attachment" {
                paths.append(path)
            }
        }
        visit(root, [])
        return paths
    }

    /// Earlier messages in the conversation, oldest first, without `excluding`, at most `limit`; quoted history trimmed.
    func conversation(threadID: String, excluding messageID: String?, limit: Int, myAddress: String) async throws -> [ThreadMessage] {
        guard Self.isGmailID(threadID) else { throw IntegrationError.unexpected(.gmail, "a bad conversation id") }
        guard limit > 0 else { return [] }
        let reply = try await get("threads/\(threadID)", query: [("format", "full")], as: ThreadReply.self)
        return Self.conversation(reply.messages ?? [], excluding: messageID, limit: limit, myAddress: myAddress)
    }

    /// The messages before `excluding` (all of them when it isn't there), oldest first: the latest `limit`.
    fileprivate static func conversation(_ messages: [FullMessageReply], excluding: String?, limit: Int, myAddress: String) -> [ThreadMessage] {
        let ordered = readable(messages)
        var earlier = ordered[...]
        if let excluding, let index = ordered.firstIndex(where: { $0.message.id == excluding }) {
            earlier = ordered[..<index]
        }
        return earlier.suffix(limit).compactMap { threadMessage($0.message, date: $0.date, myAddress: myAddress) }
    }

    /// A conversation as it reads: oldest first, each message with when it was sent. Drafts aren't part of it,
    /// and neither are messages in Trash or Spam, unless the whole conversation is there (then it reads as
    /// it is, as Gmail shows it from the Trash).
    fileprivate static func readable(_ messages: [FullMessageReply], now: Date = Date()) -> [(message: FullMessageReply, date: Date)] {
        let written = messages.filter { m in
            guard let id = m.id, !id.isEmpty, m.payload != nil else { return false }
            return !(m.labelIds ?? []).contains("DRAFT")
        }
        let binned = { (m: FullMessageReply) in !Set(m.labelIds ?? []).isDisjoint(with: ["TRASH", "SPAM"]) }
        let shown = written.allSatisfy(binned) ? written : written.filter { !binned($0) }
        // Gmail lists a conversation oldest first; sorted by date to be sure, keeping its order for ties. A
        // message without a date keeps its place, with the date of the one before it.
        let known = shown.map(date(of:))
        var previous = known.lazy.compactMap { $0 }.first ?? now
        let dated = zip(shown, known).map { message, date -> (message: FullMessageReply, date: Date) in
            previous = date ?? previous
            return (message, previous)
        }
        return dated.enumerated().sorted { ($0.element.date, $0.offset) < ($1.element.date, $1.offset) }.map { $0.element }
    }

    /// A long message in a conversation is cut here, so the view and the AI prompt stay manageable.
    static let longestThreadText = 20_000

    private static func threadMessage(_ m: FullMessageReply, date: Date, myAddress: String) -> ThreadMessage? {
        guard let id = m.id, let payload = m.payload else { return nil }
        let root = MIMEPart(gmail: payload)
        let sender = MailSender(header: root.header("From") ?? "")
        let body = MailBody(root)
        var text = newText(of: body)
        // Nothing readable: Gmail's snippet, or what was attached.
        if text.isEmpty { text = MailText.snippet(m.snippet ?? "") }
        if text.isEmpty { text = attachedLine(body) }
        if text.count > longestThreadText { text = String(text.prefix(longestThreadText)) + "…" }
        return ThreadMessage(id: id, from: sender.displayName, date: date, text: text,
                             isMine: isMine(labels: m.labelIds ?? [], sender: sender, myAddress: myAddress))
    }

    /// What a message adds to its conversation: its text without the quoted history (an HTML body without its
    /// quote blocks); or the quotes, when that's all it is.
    private static func newText(of body: MailBody) -> String {
        let full = body.text ?? body.html.map { MailText.plainText(fromHTML: $0, droppingQuotes: true) } ?? ""
        let text = MailQuote.trimmed(full)
        return text.isEmpty ? MailText.tidied(MailText.normalizedNewlines(full).components(separatedBy: "\n")) : text
    }

    /// "Attached: Q3 numbers.pdf, chart.png" (images shown in the body aside), or nothing.
    private static func attachedLine(_ body: MailBody) -> String {
        let files = body.files.filter { $0.contentID == nil }.map(\.name)
        return files.isEmpty ? "" : "Attached: " + files.joined(separator: ", ")
    }

    /// Sent by the user: Gmail filed it as sent, or it's from their address, however that's written.
    private static func isMine(labels: [String], sender: MailSender, myAddress: String) -> Bool {
        let me = MailReplyBuilder.mailbox(myAddress)
        return labels.contains("SENT") || (!me.isEmpty && sender.address.map(MailReplyBuilder.mailbox) == me)
    }

    /// When Gmail got the message, if it says (see `messageDate`).
    private static func date(of m: FullMessageReply) -> Date? {
        let header = m.payload?.headers?.first { $0.name?.caseInsensitiveCompare("Date") == .orderedSame }?.value
        return messageDate(internalDate: m.internalDate, header: header)
    }

    /// When Gmail got the message: `internalDate` (milliseconds since 1970), or else its Date header.
    static func messageDate(internalDate: String?, header: String?) -> Date? {
        internalDate.flatMap(Double.init).flatMap { $0.isFinite && $0 > 0 && $0 < 1e14 ? $0 : nil }
            .map { Date(timeIntervalSince1970: $0 / 1000) }
            ?? header.flatMap(MailText.date(fromHeader:))
    }

    /// An attachment's bytes. `attachmentID` is Gmail's attachment id, or a `partReference` for a file
    /// Gmail sent inside the message itself.
    func attachment(messageID: String, attachmentID: String) async throws -> Data {
        guard Self.isGmailID(messageID) else { throw IntegrationError.unexpected(.gmail, "a bad message id") }
        if let partID = Self.partID(fromReference: attachmentID) {
            let reply = try await get("messages/\(messageID)", query: [("format", "full")], as: FullMessageReply.self)
            guard let part = reply.payload?.part(withID: partID) else { throw IntegrationError.unexpected(.gmail, "a missing attachment") }
            if let data = part.body?.data, let bytes = MailBase64.decodeURLSafe(data) { return bytes }
            if let id = part.body?.attachmentId, !id.isEmpty, Self.partID(fromReference: id) == nil {
                return try await attachment(messageID: messageID, attachmentID: id)
            }
            throw IntegrationError.unexpected(.gmail, "a missing attachment")
        }
        // Gmail's attachment ids are base64url; anything else never goes into an address.
        guard !attachmentID.isEmpty, attachmentID.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_") }) else {
            throw IntegrationError.unexpected(.gmail, "a bad attachment id")
        }
        let reply = try await get("messages/\(messageID)/attachments/\(attachmentID)", as: AttachmentReply.self)
        guard let data = reply.data.flatMap(MailBase64.decodeURLSafe) else { throw IntegrationError.unexpected(.gmail, "an unreadable attachment") }
        return data
    }

    /// The attachment id for a file Gmail sent inside the message (no attachment id of its own): its part
    /// id, so `attachment(messageID:attachmentID:)` finds it in the message again.
    static func partReference(_ partID: String) -> String { "part:\(partID)" }

    static func partID(fromReference reference: String) -> String? {
        guard reference.hasPrefix("part:") else { return nil }
        let id = reference.dropFirst("part:".count)
        return !id.isEmpty && id.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }) ? String(id) : nil
    }

    /// Gmail's message and thread ids are hex; anything else never goes into an address.
    static func isGmailID(_ id: String) -> Bool {
        !id.isEmpty && id.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.alphanumerics.contains($0) }
    }

    /// Sends the reply in the original's conversation (needs the gmail.compose scope). Never retried by
    /// itself: when it fails, the user decides whether to try again.
    func sendReply(_ reply: MailReply) async throws {
        let message = try await outgoing(reply)
        _ = try await perform("messages/send", json: JSONEncoder().encode(message), permission: Self.composePermission,
                              action: "send the reply")
    }

    /// Saves the reply as a Gmail draft in the original's conversation (needs the gmail.compose scope).
    func saveDraft(_ reply: MailReply) async throws {
        let message = try await outgoing(reply)
        _ = try await perform("drafts", json: JSONEncoder().encode(DraftRequest(message: message)), permission: Self.composePermission,
                              action: "save the draft")
    }

    /// The reply as Gmail takes it: from the right one of your addresses, to the right people.
    private func outgoing(_ reply: MailReply) async throws -> OutgoingMessage {
        guard Self.isGmailID(reply.threadID) else { throw IntegrationError.unexpected(.gmail, "a bad conversation id") }
        guard !reply.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IntegrationError.api(.gmail, "The reply is empty.")
        }
        // Which of your addresses it goes from, and with what name, as Gmail would pick them. Best effort:
        // without them it goes from the connected address.
        var identities: [MailIdentity] = []
        do {
            identities = try await sendAsIdentities()
        } catch {
            if IntegrationError.wrap(error, .gmail) == .cancelled { throw IntegrationError.cancelled }
        }
        let identity = MailReplyBuilder.identity(for: reply, among: identities)
        let own = Set(identities.map(\.address)).union([identity.address])
        guard !MailReplyBuilder.recipients(for: reply, ownAddresses: own).to.isEmpty else {
            throw IntegrationError.api(.gmail, "This email has no address to reply to.")
        }
        let raw = MailReplyBuilder.message(for: reply, from: identity, ownAddresses: own)
        return OutgoingMessage(raw: MailBase64.urlSafe(raw), threadId: reply.threadID)
    }

    /// Your addresses in Gmail ("Send mail as"), with the name each one sends with.
    func sendAsIdentities() async throws -> [MailIdentity] {
        let reply = try await get("settings/sendAs", as: SendAsReply.self)
        return (reply.sendAs ?? []).compactMap { alias in
            guard let address = alias.sendAsEmail?.trimmingCharacters(in: .whitespacesAndNewlines), MailSender.isValidAddress(address) else {
                return nil
            }
            // An address still waiting to be verified can't send yet.
            if let status = alias.verificationStatus, status != "accepted" { return nil }
            let name = alias.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            return MailIdentity(address: address, name: name?.isEmpty == false ? name : nil, isDefault: alias.isDefault ?? false)
        }
    }
}

// MARK: - The whole conversation, stars

extension GmailClient {
    /// The whole conversation (threads/<id>?format=full): every message, oldest first, each with its own body,
    /// attachments and reply headers, as `fullMessage` reads them. The user's own are `isMine`, starred ones
    /// `isStarred`. Drafts aren't part of it, and neither are messages in Trash or Spam unless the whole
    /// conversation is there. Empty when nothing in it is left to show.
    func conversationMessages(threadID: String, myAddress: String) async throws -> [ThreadEmail] {
        guard Self.isGmailID(threadID) else { throw IntegrationError.unexpected(.gmail, "a bad conversation id") }
        let reply = try await get("threads/\(threadID)", query: [("format", "full")], as: ThreadReply.self)
        var messages = Self.readable(reply.messages ?? []).compactMap { entry -> ConversationEntry? in
            guard let id = entry.message.id, let payload = entry.message.payload else { return nil }
            return ConversationEntry(id: id, reply: entry.message, root: MIMEPart(gmail: payload), date: entry.date)
        }
        // Bodies too long to come with the conversation are fetched like attachments, a few at a time.
        let detached = Array(messages.indices.flatMap { index in
            Self.detachedBodies(in: messages[index].root).prefix(Self.detachedBodiesPerMessage).compactMap { path in
                messages[index].root[path: path].attachmentID.map {
                    DetachedBody(entry: index, messageID: messages[index].id, path: path, attachmentID: $0)
                }
            }
        }.prefix(Self.detachedBodiesPerConversation))
        let bodies = await IntegrationHTTP.concurrentMap(detached, limit: 4) { body -> Result<Data, IntegrationError> in
            do {
                return .success(try await attachment(messageID: body.messageID, attachmentID: body.attachmentID))
            } catch {
                return .failure(IntegrationError.wrap(error, .gmail))
            }
        }
        for (body, result) in zip(detached, bodies) {
            switch result {
            case .success(let data): messages[body.entry].root[path: body.path].body = data
            // Gone since it was listed: the message shows what came with it.
            case .failure(.unexpected): continue
            case .failure(let error): throw error
            }
        }
        let fetchedAt = Date()
        return messages.map { Self.threadEmail($0, myAddress: myAddress, fetchedAt: fetchedAt) }
    }

    /// At most this many bodies Gmail sent apart are fetched for a whole conversation.
    static let detachedBodiesPerConversation = 24
    /// A collapsed message's line is cut here (at a word).
    static let longestSnippet = 200

    /// One message of the conversation, as the conversation view shows it.
    private static func threadEmail(_ entry: ConversationEntry, myAddress: String, fetchedAt: Date) -> ThreadEmail {
        let body = MailBody(entry.root)
        let sender = MailSender(header: entry.root.header("From") ?? "")
        let labels = entry.reply.labelIds ?? []
        let gmailSnippet = MailText.snippet(entry.reply.snippet ?? "")
        var content = messageContent(entry.root, body: body, messageID: entry.id, fetchedAt: fetchedAt)
        // Nothing readable came (its body is gone): Gmail's snippet stands in.
        if content.html == nil, content.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { content.text = gmailSnippet }
        // Collapsed, a message reads as the start of what it adds: no quoted history.
        let words = SlackText.collapsed(newText(of: body))
        let line = !words.isEmpty ? SlackText.firstLine(words, limit: longestSnippet) : !gmailSnippet.isEmpty ? gmailSnippet : attachedLine(body)
        return ThreadEmail(id: entry.id, from: sender.displayName, date: entry.date, content: content,
                           replyHeaders: MailReplyHeaders(original: entry.root.headers),
                           isMine: isMine(labels: labels, sender: sender, myAddress: myAddress),
                           isStarred: labels.contains(starredLabel), snippet: line)
    }

    /// Gmail's label for a starred message.
    static let starredLabel = "STARRED"

    /// Stars or unstars a message: Gmail's STARRED label (messages/<id>/modify; needs gmail.modify). No other
    /// label changes. Doing it twice does no harm, so it's safe to try again whatever happened.
    func setStarred(_ starred: Bool, messageID: String) async throws {
        guard Self.isGmailID(messageID) else { throw IntegrationError.unexpected(.gmail, "a bad message id") }
        let change = starred ? LabelChange(addLabelIds: [Self.starredLabel]) : LabelChange(removeLabelIds: [Self.starredLabel])
        _ = try await perform("messages/\(messageID)/modify", json: JSONEncoder().encode(change), permission: Self.starPermission,
                              action: starred ? "star the email" : "unstar the email", repeatable: true)
    }
}

/// A message of a conversation being read: its parts (with the bodies Gmail sent apart, once fetched) and
/// when it was sent.
private struct ConversationEntry {
    var id: String
    var reply: FullMessageReply
    var root: MIMEPart
    var date: Date
}

/// A body Gmail sent apart from a message of a conversation: which message, where in it, and its id.
private struct DetachedBody: Sendable {
    var entry: Int
    var messageID: String
    var path: [Int]
    var attachmentID: String
}

extension MIMEPart {
    /// A part of Gmail's format=full payload. Its body is base64url and already transfer-decoded (the
    /// Content-Transfer-Encoding header only says how it travelled), so base64url is all that's undone.
    init(gmail payload: GmailPayload, depth: Int = 0) {
        self.init()
        headers = (payload.headers ?? []).compactMap { h in
            guard let name = h.name, !name.isEmpty else { return nil }
            return MIMEHeader(name: name, value: h.value ?? "")
        }
        let declared = (payload.mimeType ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        let fromHeader = MIMEHeaderValue(header("Content-Type") ?? "").value
        mimeType = declared.contains("/") ? declared : fromHeader.contains("/") ? fromHeader : "text/plain"
        body = payload.body?.data.flatMap(MailBase64.decodeURLSafe)
        attachmentID = payload.body?.attachmentId.flatMap { $0.isEmpty ? nil : $0 }
        size = payload.body?.size ?? body?.count
        partID = payload.partId.flatMap { $0.isEmpty ? nil : $0 }
        gmailFilename = payload.filename.flatMap { $0.isEmpty ? nil : $0 }
        guard depth < MailMIME.maxDepth else { return }
        parts = (payload.parts ?? []).prefix(MailMIME.maxParts).map { MIMEPart(gmail: $0, depth: depth + 1) }
        // An email attached whole, its bytes right here: its parts too, for its text.
        if mimeType == "message/rfc822", parts.isEmpty, attachmentID == nil, let body, !body.isEmpty {
            parts = [MailMIME.parse(body)]
        }
    }
}

extension MailBody.File {
    /// As an inbox attachment of the Gmail message `messageID`: fetched later by its attachment id, or by
    /// its part id when Gmail sent the bytes inside the message.
    func attachment(messageID: String) -> MessageAttachment? {
        let reference: String
        if let attachmentID, !attachmentID.isEmpty {
            reference = attachmentID
        } else if let partID, !partID.isEmpty {
            reference = GmailClient.partReference(partID)
        } else {
            return nil
        }
        return MessageAttachment(id: "\(messageID)/\(reference)", name: name, mimeType: mimeType, size: size,
                                 remote: .gmail(messageID: messageID, attachmentID: reference), contentID: contentID)
    }
}

/// A part of a message in Gmail's format=full payload.
struct GmailPayload: Decodable, Sendable {
    struct Header: Decodable, Sendable {
        let name: String?
        let value: String?
    }

    struct Body: Decodable, Sendable {
        let attachmentId: String?
        let size: Int?
        let data: String?
    }

    let partId: String?
    let mimeType: String?
    let filename: String?
    let headers: [Header]?
    let body: Body?
    let parts: [GmailPayload]?

    /// The part with this id, here or further in.
    func part(withID id: String) -> GmailPayload? {
        if partId == id { return self }
        for child in parts ?? [] {
            if let found = child.part(withID: id) { return found }
        }
        return nil
    }
}

// MARK: - Addresses

extension MailSender {
    /// An address list ("Sam Lee <sam@…>, "Lee, Priya" <priya@…>, team: a@…, b@…;") as one sender per
    /// address. Commas in quotes, angle brackets or comments don't split; group names are dropped, and so
    /// is anything without a usable address.
    static func list(_ header: String) -> [MailSender] {
        var items: [String] = []
        var current = ""
        var quoted = false
        var escaped = false
        var angle = 0
        var comment = 0
        for c in header {
            if escaped {
                escaped = false
                current.append(c)
                continue
            }
            if c == "\\", quoted || comment > 0 {
                escaped = true
            } else if c == "\"", comment == 0 {
                quoted.toggle()
            } else if !quoted, c == "(" {
                comment += 1
            } else if !quoted, c == ")", comment > 0 {
                comment -= 1
            } else if !quoted, comment == 0 {
                if c == "<" {
                    angle += 1
                } else if c == ">", angle > 0 {
                    angle -= 1
                } else if angle == 0, c == "," || c == ";" {
                    items.append(current)
                    current = ""
                    continue
                } else if angle == 0, c == ":", !current.contains("@") {
                    // A group's name ("team: a@…, b@…;"): only its members count.
                    current = ""
                    continue
                }
            }
            current.append(c)
        }
        items.append(current)
        return items.compactMap { item in
            let text = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let sender = MailSender(header: text)
            guard let address = sender.address, isValidAddress(address) else { return nil }
            return sender
        }
    }

    /// Something@somewhere, with nothing in it that could break a header.
    static func isValidAddress(_ address: String) -> Bool {
        guard let at = address.lastIndex(of: "@"), at > address.startIndex, address.index(after: at) < address.endIndex else { return false }
        return !address.unicodeScalars.contains { $0.value <= 0x20 || $0.value == 0x7F || "<>(),;:\"[]\\".unicodeScalars.contains($0) }
    }

    /// "Sam Lee <sam@…>", a name that needs them in quotes ("\"Lee, Sam\" <sam@…>"), so it reads back as one
    /// address.
    var headerForm: String {
        guard let address else { return name ?? "" }
        guard let name, !name.isEmpty, name.lowercased() != address.lowercased() else { return address }
        return "\(Self.quotedIfNeeded(name)) <\(address)>"
    }

    /// A display name in quotes when it has characters that mean something in an address header.
    static func quotedIfNeeded(_ name: String) -> String {
        guard name.contains(where: { "()<>[]:;@\\,.\"".contains($0) }) else { return name }
        return "\"" + name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
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

/// A message with format=full.
private struct FullMessageReply: Decodable {
    let id: String?
    let threadId: String?
    let labelIds: [String]?
    let snippet: String?
    let internalDate: String?
    let payload: GmailPayload?
}

private struct ThreadReply: Decodable {
    let id: String?
    let messages: [FullMessageReply]?
}

private struct AttachmentReply: Decodable {
    let size: Int?
    let data: String?
}

private struct SendAsReply: Decodable {
    struct Alias: Decodable {
        let sendAsEmail: String?
        let displayName: String?
        let isDefault: Bool?
        let verificationStatus: String?
    }
    let sendAs: [Alias]?
}

/// What messages/send takes, and what a draft holds.
private struct OutgoingMessage: Encodable {
    let raw: String
    let threadId: String
}

private struct DraftRequest: Encodable {
    let message: OutgoingMessage
}

/// What messages/<id>/modify takes: labels to add and to remove (only the lists given are sent).
private struct LabelChange: Encodable {
    var addLabelIds: [String]?
    var removeLabelIds: [String]?
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
        let date = GmailClient.messageDate(internalDate: r.internalDate, header: headers["date"]) ?? Date()
        self.init(id: id, threadID: thread, sender: MailSender(header: headers["from"] ?? ""),
                  subject: subject?.isEmpty == false ? subject : nil,
                  snippet: MailText.snippet(r.snippet ?? ""), date: date, labels: Set(r.labelIds ?? []))
    }
}

// MARK: - Text

/// Email text clean-up: headers, snippets and bodies.
enum MailText {
    private static let entity = try! NSRegularExpression(pattern: #"&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[a-zA-Z][a-zA-Z0-9]{1,31});"#)
    /// The named entities email actually uses. A non-breaking space reads as a plain one.
    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "ensp": "\u{2002}", "emsp": "\u{2003}", "thinsp": "\u{2009}", "zwnj": "\u{200C}", "zwj": "\u{200D}", "lrm": "\u{200E}",
        "rlm": "\u{200F}", "shy": "\u{00AD}",
        "ndash": "–", "mdash": "—", "lsquo": "‘", "rsquo": "’", "sbquo": "‚", "ldquo": "“", "rdquo": "”", "bdquo": "„",
        "laquo": "«", "raquo": "»", "lsaquo": "‹", "rsaquo": "›", "hellip": "…", "bull": "•", "middot": "·", "prime": "′",
        "Prime": "″", "dagger": "†", "Dagger": "‡", "permil": "‰", "trade": "™", "copy": "©", "reg": "®", "deg": "°",
        "plusmn": "±", "times": "×", "divide": "÷", "minus": "−", "micro": "µ", "para": "¶", "sect": "§", "cent": "¢",
        "pound": "£", "yen": "¥", "euro": "€", "curren": "¤", "brvbar": "¦", "uml": "¨", "ordf": "ª", "ordm": "º", "not": "¬",
        "macr": "¯", "acute": "´", "cedil": "¸", "sup1": "¹", "sup2": "²", "sup3": "³", "frac14": "¼", "frac12": "½",
        "frac34": "¾", "iexcl": "¡", "iquest": "¿", "larr": "←", "rarr": "→", "uarr": "↑", "darr": "↓", "harr": "↔",
        "lArr": "⇐", "rArr": "⇒", "hArr": "⇔", "le": "≤", "ge": "≥", "ne": "≠", "asymp": "≈", "infin": "∞", "check": "✓",
        "hearts": "♥", "star": "☆", "starf": "★", "circ": "ˆ", "tilde": "˜", "fnof": "ƒ",
        "Agrave": "À", "Aacute": "Á", "Acirc": "Â", "Atilde": "Ã", "Auml": "Ä", "Aring": "Å", "AElig": "Æ", "Ccedil": "Ç",
        "Egrave": "È", "Eacute": "É", "Ecirc": "Ê", "Euml": "Ë", "Igrave": "Ì", "Iacute": "Í", "Icirc": "Î", "Iuml": "Ï",
        "ETH": "Ð", "Ntilde": "Ñ", "Ograve": "Ò", "Oacute": "Ó", "Ocirc": "Ô", "Otilde": "Õ", "Ouml": "Ö", "Oslash": "Ø",
        "Ugrave": "Ù", "Uacute": "Ú", "Ucirc": "Û", "Uuml": "Ü", "Yacute": "Ý", "THORN": "Þ", "szlig": "ß",
        "agrave": "à", "aacute": "á", "acirc": "â", "atilde": "ã", "auml": "ä", "aring": "å", "aelig": "æ", "ccedil": "ç",
        "egrave": "è", "eacute": "é", "ecirc": "ê", "euml": "ë", "igrave": "ì", "iacute": "í", "icirc": "î", "iuml": "ï",
        "eth": "ð", "ntilde": "ñ", "ograve": "ò", "oacute": "ó", "ocirc": "ô", "otilde": "õ", "ouml": "ö", "oslash": "ø",
        "ugrave": "ù", "uacute": "ú", "ucirc": "û", "uuml": "ü", "yacute": "ý", "thorn": "þ", "yuml": "ÿ",
        "OElig": "Œ", "oelig": "œ", "Scaron": "Š", "scaron": "š", "Yuml": "Ÿ",
    ]
    /// Old pages write Windows-1252 code points as numbers ("&#146;" for ’), and browsers read them that way.
    private static let windows1252: [UInt32: String] = [
        0x80: "€", 0x82: "‚", 0x83: "ƒ", 0x84: "„", 0x85: "…", 0x86: "†", 0x87: "‡", 0x88: "ˆ", 0x89: "‰", 0x8A: "Š",
        0x8B: "‹", 0x8C: "Œ", 0x8E: "Ž", 0x91: "‘", 0x92: "’", 0x93: "“", 0x94: "”", 0x95: "•", 0x96: "–", 0x97: "—",
        0x98: "˜", 0x99: "™", 0x9A: "š", 0x9B: "›", 0x9C: "œ", 0x9E: "ž", 0x9F: "Ÿ",
    ]

    /// HTML entities: in Gmail's snippets ("Friday&#39;s" → "Friday's") and in HTML bodies. Unknown ones stay
    /// as they are.
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

    /// Gmail's snippet as one line: entities decoded, whitespace collapsed, and without the invisible
    /// characters newsletters pad their preview text with.
    static func snippet(_ raw: String) -> String {
        visible(decodeEntities(raw)).split(whereSeparator: \.isWhitespace)
            .filter { !$0.unicodeScalars.allSatisfy { invisible.contains($0.value) } }
            .joined(separator: " ")
    }

    private static func character(for body: String) -> String? {
        if let known = named[body] ?? named[body.lowercased()] { return known }
        guard body.hasPrefix("#") else { return nil }
        let digits = body.dropFirst()
        let parsed = digits.first == "x" || digits.first == "X" ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
        guard let value = parsed, value > 0 else { return nil }
        if let mapped = windows1252[value] { return mapped }
        return Unicode.Scalar(value).map { String(Character($0)) }
    }

    private static let encodedWord = try! NSRegularExpression(pattern: #"=\?([^?\s]+)\?([bBqQ])\?([^?\s]*)\?="#)

    /// RFC 2047 encoded words in headers: "=?UTF-8?B?U2FtIExlZQ==?=" → "Sam Lee". Words in a row in one
    /// charset are read together: some mailers split a character's bytes between two of them.
    static func decodeEncodedWords(_ s: String) -> String {
        guard s.contains("=?") else { return s }
        let ns = s as NSString
        var out = ""
        var last = 0
        // The encoded words in a row so far: their charset and bytes.
        var run: (charset: String, bytes: Data)?
        func endRun() {
            if let run { out += wordText(run.bytes, charset: run.charset) }
            run = nil
        }
        for m in encodedWord.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            let gap = ns.substring(with: NSRange(location: last, length: m.range.location - last))
            last = m.range.location + m.range.length
            let charset = ns.substring(with: m.range(at: 1))
            guard let bytes = wordBytes(encoding: ns.substring(with: m.range(at: 2)), text: ns.substring(with: m.range(at: 3))) else {
                endRun()
                out += gap + ns.substring(with: m.range)
                continue
            }
            // Whitespace between two encoded words isn't part of the text.
            let adjacent = run != nil && gap.allSatisfy(\.isWhitespace)
            if adjacent, let current = run, current.charset.caseInsensitiveCompare(charset) == .orderedSame {
                run?.bytes.append(bytes)
                continue
            }
            endRun()
            if !adjacent { out += gap }
            run = (charset, bytes)
        }
        endRun()
        return out + ns.substring(from: last)
    }

    /// An encoded word's bytes: base64 ("B") or its own quoted-printable ("Q", "_" for a space). Nil when
    /// they aren't base64.
    private static func wordBytes(encoding: String, text: String) -> Data? {
        if encoding.uppercased() == "B" {
            var b64 = text
            while b64.count % 4 != 0 { b64 += "=" }
            return Data(base64Encoded: b64)
        }
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
        return data
    }

    /// Encoded-word bytes as text in their charset ("UTF-8*en", with an RFC 2231 language, is UTF-8).
    private static func wordText(_ bytes: Data, charset: String) -> String {
        MailCharset.decode(bytes, charset: charset.split(separator: "*").first.map(String.init) ?? charset)
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
