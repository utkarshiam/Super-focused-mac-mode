import AppKit
import Combine
import Foundation

// MARK: - Suggestions

/// A Slack message or email that may deserve a task, shown in Messages.
struct Suggestion: Identifiable, Codable, Hashable {
    var id: String { source.externalID }
    var source: TaskSource
    var from: String
    var subject: String?
    var snippet: String
    var receivedAt: Date
    var draft: TaskDraft?
    /// What picked it up: a 📌 reaction, a mention, a star, an email waiting for a reply.
    var trigger: SuggestionTrigger?
    /// The user's own notes on the message (what to do, what to say back). They go into the task's notes
    /// when the message becomes a task.
    var note = ""
    /// The reply being written, typed or drafted with AI. Cleared once it's sent.
    var replyDraft = ""
    /// When a reply went out from Docket.
    var repliedAt: Date?
    /// The complete message. Slack: filled at refresh from the message itself; email: filled when first opened.
    var content: MessageContent?
    /// Slack: the parent message's ts when this one is a reply in a thread.
    var threadTS: String?
    /// Email: what a reply needs from the original (Message-ID, subject, sender, recipients), kept with the
    /// complete message so sending doesn't fetch it again.
    var replyHeaders: MailReplyHeaders?
    /// Starred in Docket: shown first in its tab and in the tab's Starred filter. Starring an email stars it in
    /// Gmail too, and a Slack message is saved for later in Slack when Slack allows it (`Integrations.setStarred`).
    var isStarred = false
    /// Other messages of its thread or conversation that Docket shows starred on its own: Slack messages (by
    /// ts; Slack doesn't say which ones are saved for later), and emails Gmail couldn't star (by message id).
    /// The item's own message is `isStarred`; other emails are starred in Gmail.
    var starredInThread: Set<String> = []

    enum CodingKeys: String, CodingKey {
        case source, from, subject, snippet, receivedAt, draft, trigger
        case note, replyDraft, repliedAt, content, threadTS, replyHeaders, isStarred, starredInThread
    }
}

extension Suggestion {
    // In an extension so the memberwise initializer stays available. Missing keys fall back to defaults,
    // so files from before the inbox (no notes, replies or content) or before stars load as they are.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decode(TaskSource.self, forKey: .source)
        from = c.value(.from, default: "")
        subject = c.value(.subject, default: nil)
        snippet = c.value(.snippet, default: "")
        receivedAt = c.value(.receivedAt, default: Date())
        draft = c.value(.draft, default: nil)
        trigger = c.value(.trigger, default: nil)
        note = c.value(.note, default: "")
        replyDraft = c.value(.replyDraft, default: "")
        repliedAt = c.value(.repliedAt, default: nil)
        content = c.value(.content, default: nil)
        threadTS = c.value(.threadTS, default: nil)
        replyHeaders = c.value(.replyHeaders, default: nil)
        // Saved before stars: an email that came in because it's starred in Gmail is starred.
        isStarred = c.value(.isStarred, default: source.kind == .gmail && trigger == .starred)
        starredInThread = c.value(.starredInThread, default: [])
    }

    /// Nothing of the user's on it yet: no note, reply, or star.
    var isUntouched: Bool {
        note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && replyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && repliedAt == nil && !isStarred && starredInThread.isEmpty
    }
}

/// Why a message became a suggestion.
enum SuggestionTrigger: String, Codable, Hashable {
    case reaction, mention, starred, needsReply
    /// Someone wrote to the user in a Slack DM or group DM.
    case directMessage

    /// The user flagged it on purpose (a reaction, a star): it's suggested even when AI sees nothing to do.
    var isExplicit: Bool { self == .reaction || self == .starred }

    /// Reads the name as saved. One this version doesn't know (saved by a newer Docket) throws, so the
    /// suggestion it's on loads without a trigger (`Suggestion.init(from:)`) instead of being lost.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let known = Self(rawValue: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown trigger \(raw)"))
        }
        self = known
    }
}

// MARK: - Settings

extension Prefs.Key {
    static let slackSaveEmoji = "slackSaveEmoji"
    static let slackMentions = "slackMentions"
    static let slackDirectMessages = "slackDirectMessages"
    static let slackFocusStatus = "slackFocusStatus"
    static let gmailNeedsReply = "gmailNeedsReply"
    static let slackShareChannel = "slackShareChannel"
}

/// The switches on Settings → Connections, read at the start of each refresh.
struct IntegrationSettings: Equatable {
    var saveEmoji = SlackSaveEmoji.standard
    var mentions = true
    /// Messages people send you in Slack DMs and group DMs.
    var directMessages = true
    var focusStatus = true
    var needsReply = true

    static var current: IntegrationSettings {
        let d = UserDefaults.standard
        return IntegrationSettings(
            saveEmoji: SlackSaveEmoji.normalized(d.string(forKey: Prefs.Key.slackSaveEmoji)),
            mentions: d.object(forKey: Prefs.Key.slackMentions) as? Bool ?? true,
            directMessages: d.object(forKey: Prefs.Key.slackDirectMessages) as? Bool ?? true,
            focusStatus: d.object(forKey: Prefs.Key.slackFocusStatus) as? Bool ?? true,
            needsReply: d.object(forKey: Prefs.Key.gmailNeedsReply) as? Bool ?? true)
    }
}

/// The reaction that saves a Slack message to Docket.
enum SlackSaveEmoji {
    static let standard = "pushpin"
    /// Offered in Settings, by Slack's names for them.
    static let choices: [(name: String, glyph: String)] = [
        ("pushpin", "📌"), ("bookmark", "🔖"), ("memo", "📝"), ("inbox_tray", "📥"), ("star", "⭐️"), ("eyes", "👀"),
    ]

    static func glyph(_ name: String) -> String {
        choices.first { $0.name == name }?.glyph ?? ":\(name):"
    }

    /// "  :Pushpin: " → "pushpin"; empty means the default.
    static func normalized(_ raw: String?) -> String {
        let name = (raw ?? "").trimmingCharacters(in: CharacterSet(charactersIn: ":").union(.whitespacesAndNewlines)).lowercased()
        return name.isEmpty ? standard : name
    }
}

// MARK: - Errors

/// What went wrong talking to Slack or Google, in words the user can act on.
enum IntegrationError: LocalizedError, Equatable {
    enum Service: String { case slack = "Slack", gmail = "Gmail", google = "Google" }

    case notConnected(Service)
    /// The token was revoked or expired: connect again.
    case signedOut(Service)
    case missingPermission(Service, String)
    case rateLimited(Service, retryAfter: TimeInterval)
    case offline(Service, String)
    case unexpected(Service, String)
    /// Already in plain words.
    case api(Service, String)
    case signInCancelled, signInTimedOut, signInDenied
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notConnected(let s):
            "\(s.rawValue) isn't connected."
        case .signedOut(.slack):
            "Slack no longer accepts Docket's token. Paste a new one in Settings → Connections."
        case .signedOut:
            "Google signed Docket out of Gmail. While your Google app is in Testing, Google does this every 7 days: click Publish app on its Audience page once to stop it, then connect again in Settings → Connections."
        case .missingPermission(.slack, let scope) where Self.isStarScope(scope):
            "Docket needs one more Slack permission to save messages for later in Slack. Update the Docket app in Settings → Connections."
        case .missingPermission(.slack, let scope) where Self.isDirectMessageScope(scope):
            "Docket needs more Slack permissions to read your direct messages. Update the Docket app in Settings → Connections."
        case .missingPermission(.slack, let scope) where Self.isContentScope(scope):
            "Docket needs more Slack permissions to show files and threads. Update the Docket app in Settings → Connections."
        case .missingPermission(.slack, let scope):
            "The Docket app in Slack is missing the \(scope) permission. Create the app again from step 1 in Settings → Connections."
        case .missingPermission(_, let what):
            "Docket needs permission to \(what). Connect Gmail again and allow it."
        case .rateLimited(let s, let after):
            "\(s.rawValue) asked Docket to slow down. It will try again in \(Fmt.duration(minutes: Self.minutes(after)))."
        case .offline(let s, let detail):
            "Couldn't reach \(s.rawValue). \(detail)"
        case .unexpected(let s, let detail):
            "\(s.rawValue) sent back something unexpected (\(detail))."
        case .api(_, let message):
            message
        case .signInCancelled:
            "Sign-in was cancelled."
        case .signInTimedOut:
            "Sign-in timed out. Try again."
        case .signInDenied:
            "Gmail wasn't connected: access was declined in the browser."
        case .cancelled:
            "Cancelled."
        }
    }

    /// Slack's "needed" names only permissions the complete message needs (files, thread history, stars).
    private static func isContentScope(_ needed: String) -> Bool {
        let names = needed.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
        return !names.isEmpty && names.allSatisfy(SlackManifest.contentScopes.contains)
    }

    /// Slack's "needed" names only the permissions for reading DMs and group DMs.
    private static func isDirectMessageScope(_ needed: String) -> Bool {
        let names = needed.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
        return !names.isEmpty && names.allSatisfy(SlackManifest.directMessageScopes.contains)
    }

    /// Slack's "needed" names only the permissions for saving messages for later (stars:read, stars:write).
    private static func isStarScope(_ needed: String) -> Bool {
        let names = needed.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
        return !names.isEmpty && names.allSatisfy(InboxStarRules.slackScopes.contains)
    }

    /// Whole minutes to wait, at least one (a bad value never traps).
    private static func minutes(_ seconds: TimeInterval) -> Int {
        guard seconds.isFinite, seconds > 0 else { return 1 }
        return max(1, Int((min(seconds, 86_400) / 60).rounded(.up)))
    }

    /// Any error as an IntegrationError for `service` (network errors become `.offline`).
    static func wrap(_ error: Error, _ service: Service) -> IntegrationError {
        if let e = error as? IntegrationError { return e }
        if error is CancellationError { return .cancelled }
        if let url = error as? URLError {
            switch url.code {
            case .cancelled: return .cancelled
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
                return .offline(service, "You seem to be offline.")
            case .timedOut: return .offline(service, "It took too long to answer.")
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return .offline(service, "Check your internet connection.")
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid:
                return .offline(service, "The secure connection failed.")
            default: return .offline(service, "Check your internet connection.")
            }
        }
        return .unexpected(service, (error as NSError).domain)
    }
}

// MARK: - HTTP

/// Plain HTTPS for Slack and Google. The transport is swapped in tests, so they never touch the network.
enum IntegrationHTTP {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    /// Ephemeral: no cookies, cache or credentials on disk.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        // A request that stalls gives up after 30 s; a whole transfer may take longer, so an attachment of
        // up to 100 MB (`InboxCache.largestFile`) still arrives on a slow connection.
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 10 * 60
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.httpAdditionalHeaders = ["User-Agent": "Docket (macOS)"]
        return URLSession(configuration: config)
    }()

    /// HTTPS only.
    static let live: Transport = { request in
        guard request.url?.scheme == "https" else { throw URLError(.appTransportSecurityRequiresSecureConnection) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    static let sleep: @Sendable (TimeInterval) async throws -> Void = { seconds in
        let wait = seconds.isFinite ? min(max(0, seconds), 3600) : 0
        try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
    }

    /// Characters that never need escaping (RFC 3986 "unreserved").
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func escape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    /// "a=1&b=two%20words": a query string or an application/x-www-form-urlencoded body.
    /// Everything except unreserved characters is escaped, so "+", "&", "=" and "#" in values stay intact.
    static func encode(_ items: [(String, String)]) -> String {
        items.map { "\(escape($0.0))=\(escape($0.1))" }.joined(separator: "&")
    }

    static func formPost(_ url: URL, _ items: [(String, String)], bearer: String? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        request.httpBody = Data(encode(items).utf8)
        return request
    }

    /// Sends through `transport`, turning network failures into `IntegrationError`s for `service`.
    static func send(_ request: URLRequest, via transport: Transport, service: IntegrationError.Service) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await transport(request)
        } catch {
            throw IntegrationError.wrap(error, service)
        }
    }

    /// Seconds from a Retry-After header, when there is a sensible one (capped at an hour).
    static func retryAfter(_ response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespaces),
              let seconds = Double(raw), seconds.isFinite, seconds >= 0 else { return nil }
        return min(seconds, 3600)
    }

    /// Runs `work` for every item, at most `limit` at a time; results keep the input order.
    static func concurrentMap<T: Sendable, R: Sendable>(_ items: [T], limit: Int, _ work: @escaping @Sendable (T) async -> R) async -> [R] {
        guard !items.isEmpty else { return [] }
        return await withTaskGroup(of: (Int, R).self) { group in
            var results = [(Int, R)]()
            var next = 0
            while next < min(max(1, limit), items.count) {
                let index = next, item = items[index]
                group.addTask { (index, await work(item)) }
                next += 1
            }
            while let finished = await group.next() {
                results.append(finished)
                if next < items.count {
                    let index = next, item = items[index]
                    group.addTask { (index, await work(item)) }
                    next += 1
                }
            }
            return results.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
    }
}

// MARK: - Saved state

/// What Integrations remembers between launches, in integrations.json in the data folder.
/// No tokens: those stay in the secrets file.
struct IntegrationsFile: Codable {
    /// 2 added the inbox: notes, replies, complete messages, granted permissions. 3 added stars (on items and
    /// on messages of their threads). 4 added thread summaries. Older files load as they are (the new fields
    /// start empty).
    static let currentVersion = 5

    var version = currentVersion
    var suggestions: [Suggestion] = []
    /// Message ids (`TaskSource.externalID`) that were added or dismissed, and when. Never suggested again.
    var handled: [String: Date] = [:]
    /// Message ids AI looked at and found nothing to do for. Not suggested.
    var skipped: [String: Date] = [:]
    var lastRefresh: Date?
    var slack: SlackAccount?
    var gmailAddress: String?
    /// Set while Docket's "Heads down" status is on Slack, so it can be undone even after a crash.
    var focusStatus: SlackFocusRecord?
    /// The permissions the Slack token has, as Slack last listed them (nil: not known).
    var slackScopes: [String]?
    /// The Gmail permissions Google granted at sign-in (nil: not known, as for sign-ins from version 1).
    var gmailScopes: [String]?
    /// Names of the people and channels the waiting Slack messages mention ("U0…" → "Priya Shah"), so
    /// their markup reads right after a relaunch.
    var slackNames: [String: String] = [:]
    /// Slack turned saving messages for later down (an app made after Slack retired it, a workspace that
    /// doesn't allow it, or an app without stars:write): stars stay in Docket until Slack is connected again.
    var slackStarsStayInDocket = false
    /// Summaries of important threads, by item id (`ThreadSummaries.swift`).
    var summaries: [String: ThreadSummary] = [:]

    init() {}

    enum CodingKeys: String, CodingKey {
        case version, suggestions, handled, skipped, lastRefresh, slack, gmailAddress, focusStatus
        case slackScopes, gmailScopes, slackNames, slackStarsStayInDocket, summaries
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = c.value(.version, default: 1)
        // One unreadable suggestion (say, from a newer version) doesn't cost the rest.
        suggestions = c.value(.suggestions, default: [LenientSuggestion]()).compactMap(\.value)
        handled = c.value(.handled, default: [:])
        skipped = c.value(.skipped, default: [:])
        // Before version 5, DMs were only found as @mentions and often skipped: give them a fresh look.
        if version < 5 { skipped = skipped.filter { !$0.key.hasPrefix("slack:D") } }
        lastRefresh = c.value(.lastRefresh, default: nil)
        slack = c.value(.slack, default: nil)
        gmailAddress = c.value(.gmailAddress, default: nil)
        focusStatus = c.value(.focusStatus, default: nil)
        slackScopes = c.value(.slackScopes, default: nil)
        gmailScopes = c.value(.gmailScopes, default: nil)
        slackNames = c.value(.slackNames, default: [:])
        slackStarsStayInDocket = c.value(.slackStarsStayInDocket, default: false)
        summaries = c.value(.summaries, default: [:])
    }

    static func load(from url: URL) -> IntegrationsFile {
        guard let data = try? Data(contentsOf: url), let file = try? Persistence.decoder.decode(IntegrationsFile.self, from: data) else {
            return IntegrationsFile()
        }
        return file
    }

    func encoded() throws -> Data { try Persistence.encoder.encode(self) }
}

private struct LenientSuggestion: Decodable {
    let value: Suggestion?
    init(from decoder: Decoder) throws { value = try? Suggestion(from: decoder) }
}

/// De-duplication rules for suggestions. Pure, so they're easy to test.
enum SuggestionInbox {
    /// At most this many wait in Messages (the oldest go first).
    static let limit = 100
    /// Handled and skipped ids are kept this long: longer than any source looks back (30 days).
    static let memory: TimeInterval = 120 * 86_400

    /// Ids that are never suggested (again): added or dismissed, already waiting, or already on a task.
    static func blockedIDs(pending: [Suggestion], handled: [String: Date], taskSourceIDs: Set<String>) -> Set<String> {
        Set(handled.keys).union(pending.map(\.id)).union(taskSourceIDs)
    }

    /// Whether a message found now may become a suggestion. One that AI passed over comes back only when
    /// the user flags it on purpose afterwards (a reaction, a star).
    static func isNew(_ id: String, trigger: SuggestionTrigger, blocked: Set<String>, skipped: [String: Date]) -> Bool {
        !blocked.contains(id) && (trigger.isExplicit || skipped[id] == nil)
    }

    /// Adds what's new to what's waiting, newest first, without duplicates or blocked ids.
    static func merge(_ incoming: [Suggestion], into pending: [Suggestion], blocked: Set<String>) -> [Suggestion] {
        var seen = Set(pending.map(\.id))
        var result = pending
        for s in incoming where !blocked.contains(s.id) && seen.insert(s.id).inserted {
            result.append(s)
        }
        return Array(result.sorted { $0.receivedAt > $1.receivedAt }.prefix(limit))
    }

    /// One card per DM conversation. Of the cards just accepted from a DM or group DM (mentions and direct
    /// messages, not replies in a thread, not ones flagged on purpose), only each conversation's newest stays,
    /// and it takes the place of that conversation's older cards still waiting that the user hasn't touched
    /// (no note, reply or star). Returns the cards to add, the ones left waiting, and the ids replaced.
    static func collapseConversations(_ incoming: [Suggestion], pending: [Suggestion])
        -> (incoming: [Suggestion], pending: [Suggestion], superseded: [String]) {
        func conversation(_ s: Suggestion) -> String? {
            guard s.source.kind == .slack, s.trigger == .mention || s.trigger == .directMessage, s.threadTS == nil,
                  InboxText.isConversation(InboxText.place(of: s)) else { return nil }
            return InboxIDs.slack(s.id)?.channel
        }
        var newest: [String: Suggestion] = [:]
        for s in incoming {
            guard let c = conversation(s) else { continue }
            if let top = newest[c], top.receivedAt >= s.receivedAt { continue }
            newest[c] = s
        }
        guard !newest.isEmpty else { return (incoming, pending, []) }
        var superseded: [String] = []
        let kept = incoming.filter { s in
            guard let c = conversation(s), let top = newest[c], top.id != s.id else { return true }
            superseded.append(s.id)
            return false
        }
        let left = pending.filter { s in
            guard let c = conversation(s), let top = newest[c], top.id != s.id, s.receivedAt < top.receivedAt, s.isUntouched else { return true }
            superseded.append(s.id)
            return false
        }
        return (kept, left, superseded)
    }

    /// Drops ids older than `memory`.
    static func pruned(_ ids: [String: Date], now: Date) -> [String: Date] {
        ids.filter { now.timeIntervalSince($0.value) < memory }
    }
}

/// Task drafts for suggestions when AI isn't there to write them.
enum SuggestionDrafts {
    static func fallback(for s: Suggestion) -> TaskDraft {
        var draft = TaskDraft(title: title(for: s))
        draft.notes = context(for: s)
        draft.source = s.source
        return draft
    }

    /// "Reply to Sam: Q3 numbers" for an email, "Slack: <first line>" for a Slack message.
    static func title(for s: Suggestion) -> String {
        switch s.source.kind {
        case .gmail:
            return emailTitle(from: s.from, subject: s.subject, snippet: s.snippet)
        case .slack:
            let line = SlackText.firstLine(s.snippet)
            return line.isEmpty ? "Slack: message from \(s.from)" : "Slack: \(line)"
        case .ai:
            let line = SlackText.firstLine(s.snippet)
            return line.isEmpty ? "Follow up with \(s.from)" : line
        }
    }

    static func emailTitle(from: String, subject: String?, snippet: String) -> String {
        let name = MailSender(header: from).firstName
        var topic = MailText.cleanSubject(subject ?? "")
        if topic.isEmpty { topic = SlackText.firstLine(snippet, limit: 50) }
        topic = SlackText.firstLine(topic, limit: 60)
        return topic.isEmpty ? "Reply to \(name)" : "Reply to \(name): \(topic)"
    }

    /// The message, for the task's notes: who, where, and what they wrote.
    static func context(for s: Suggestion) -> String {
        let header: String
        switch s.source.kind {
        case .gmail:
            header = [s.from, s.subject].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
        case .slack, .ai:
            header = s.source.label.isEmpty ? s.from : s.source.label
        }
        let body = s.snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? header : "\(header):\n\(body)"
    }

    /// An AI draft made ready to add: linked to the message, with the message as notes when it has none.
    static func prepared(_ draft: TaskDraft, for s: Suggestion) -> TaskDraft {
        var d = draft
        d.source = s.source
        if d.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { d.title = title(for: s) }
        if d.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { d.notes = context(for: s) }
        return d
    }

    /// The draft a suggestion would be added with: AI's when there is one, else the plain fallback, with the
    /// user's notes on the message above a link back to it (`withNote`).
    static func draft(for s: Suggestion) -> TaskDraft {
        withNote(prepared(s.draft ?? fallback(for: s), for: s), for: s)
    }
}

/// The AI step that decides which mentions and emails need a task. Tests swap in a fake.
struct SuggestionTriage {
    var isAvailable: @MainActor () -> Bool
    var run: @MainActor ([IncomingMessage], Store, Date) async throws -> [String: TaskDraft]

    static var gemini: SuggestionTriage {
        SuggestionTriage(isAvailable: { AIService.shared.isConfigured },
                         run: { messages, store, now in try await AIService.shared.triage(messages, store: store, now: now) })
    }

    /// No AI: every mention and email waiting for a reply gets a plain draft.
    static var none: SuggestionTriage {
        SuggestionTriage(isAvailable: { false }, run: { _, _, _ in [:] })
    }
}

/// A message found during a refresh, before AI has looked at it.
struct SuggestionCandidate {
    var suggestion: Suggestion
    var message: IncomingMessage
}

/// What a refresh already knows when it starts, so the messages it has seen don't come back.
struct SeenMessages {
    var blocked: Set<String>
    var skipped: [String: Date]
    /// Email conversations with a card waiting: one card per conversation at a time.
    var waitingThreads: Set<String>
    /// Email conversations with an open task: unread mail in them isn't suggested again until it's done
    /// (a newly starred message still is).
    var openTaskThreads: Set<String>

    init(blocked: Set<String>, skipped: [String: Date], pending: [Suggestion], tasks: [TaskItem]) {
        self.blocked = blocked
        self.skipped = skipped
        waitingThreads = Set(pending.compactMap { GmailMessage.threadID(fromExternalID: $0.id) })
        openTaskThreads = Set(tasks.lazy.filter { !$0.isCompleted }
            .compactMap { $0.source?.externalID }.compactMap(GmailMessage.threadID(fromExternalID:)))
    }

    func isNew(_ id: String, _ trigger: SuggestionTrigger) -> Bool {
        SuggestionInbox.isNew(id, trigger: trigger, blocked: blocked, skipped: skipped)
    }

    /// An email worth fetching: new, in a conversation without a card, and (unless flagged on purpose)
    /// without an open task.
    func isNewEmail(_ ref: GmailRef, _ trigger: SuggestionTrigger) -> Bool {
        isNew(ref.externalID, trigger) && !waitingThreads.contains(ref.threadID)
            && (trigger.isExplicit || !openTaskThreads.contains(ref.threadID))
    }
}

// MARK: - Integrations

/// Slack and Gmail: suggestions to turn into tasks, the Slack and Email tabs (InboxStore.swift: the complete
/// message, its thread and attachments, notes, replies), sharing a plan, and the Slack focus status.
///
/// Network calls run in the background and never block the UI; problems become a status line
/// (`slackProblem`, `gmailProblem`, `aiProblem`). Tokens live in the secrets file only and are never logged.
/// Adding or dismissing a suggestion is part of the window's undo, like any task change.
@MainActor
final class Integrations: ObservableObject {
    static let shared = Integrations()

    @Published var suggestions: [Suggestion] = []
    var pendingCount: Int { suggestions.count }
    @Published var isSlackConnected = false
    @Published var isGmailConnected = false
    var isAnyConnected: Bool { isSlackConnected || isGmailConnected }

    /// Who Slack says we are ("@maya in Acme").
    @Published private(set) var slackAccount: SlackAccount?
    /// The connected Gmail address.
    @Published private(set) var gmailAddress: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefresh: Date?
    /// The last problem with each service, in plain words (nil when all is well).
    @Published private(set) var slackProblem: String?
    @Published private(set) var gmailProblem: String?
    /// AI couldn't sort the newest messages (they're tried again next time).
    @Published private(set) var aiProblem: String?

    /// The Docket app in Slack lacks permissions some features need. Stays until Slack is connected again.
    /// The ones only the complete message needs (files, threads) have their own banner: `missingSlackScopes`.
    var slackScopeWarning: String? {
        let missing = (slackAccount?.missingScopes ?? []).filter { !SlackManifest.contentScopes.contains($0) }
        guard isSlackConnected, !missing.isEmpty else { return nil }
        return "The Docket app in Slack is missing \(missing.joined(separator: ", ")). Create it again from step 1 in Settings → Connections and paste the new token."
    }
    /// Waiting for the user to finish signing in to Google in the browser.
    @Published private(set) var isSigningInToGmail = false
    /// Bumped when the Google OAuth client changes, so Settings re-reads it.
    @Published private(set) var googleClientRevision = 0

    // The Slack and Email tabs (InboxStore.swift).
    /// The permissions the Slack token has, as Slack last listed them (nil: not known yet).
    @Published var grantedSlackScopes: Set<String>?
    /// Permissions Slack turned a request down for since then (not saved: the next launch asks Slack again).
    @Published var refusedSlackScopes: Set<String> = []
    /// The Gmail permissions Google granted at sign-in (nil: not known, as for sign-ins from before the inbox).
    @Published var grantedGmailScopes: Set<String>?
    /// Threads, and the loads and sends under way. Kept while Docket runs, never saved.
    var inbox = InboxMemory()
    /// The whole Slack threads and email conversations opened this session, by item id, with the replies sent
    /// from Docket and the stars changed since (`fullThread(for:reload:)`). Never saved.
    @Published var wholeThreads: [String: InboxThread] = [:]
    /// Stars that didn't take in Gmail or Slack (and went back), by `StarTarget.key`: why, in plain words, for
    /// a moment or until the next try (`starProblem(for:message:)`).
    @Published var starProblems: [String: String] = [:]
    /// Slack turned saving messages for later down: stars stay in Docket (saved; cleared when Slack is
    /// connected again).
    var slackStarsStayInDocket = false
    /// Names from the last launch of the people and channels the waiting Slack messages mention.
    var savedSlackNames: [String: String] = [:]
    /// Summaries of important threads, by item id (saved; see ThreadSummaries.swift).
    @Published var threadSummaries: [String: ThreadSummary] = [:]
    /// Items whose summary is being written.
    @Published var summarizing: Set<String> = []
    /// Why the last summary of an item couldn't be written, in plain words.
    @Published var summaryProblems: [String: String] = [:]

    // Dependencies. Tests swap them, so nothing reaches the network, Gemini or a browser.
    var transport: IntegrationHTTP.Transport
    var triage: SuggestionTriage
    var sleep: @Sendable (TimeInterval) async throws -> Void
    var settings: () -> IntegrationSettings = { .current }
    var openURL: (URL) -> Void = { url in _ = NSWorkspace.shared.open(url) }
    /// Stand-ins for the inbox's Slack and Gmail clients; none means the real ones, through `transport`.
    var inboxClients = InboxClients()
    /// Writes replies with AI.
    var replyWriter: ReplyWriter = .gemini
    /// Summarizes important threads with AI.
    var summarizer: ThreadSummarizer = .gemini
    /// The user's name, to sign a reply ("Maya Chen"): the Mac account's full name.
    var fullName: () -> String = { NSFullUserName() }

    static let refreshInterval: TimeInterval = 15 * 60
    /// Coming back to Docket refreshes when the last check is older than this.
    static let staleAfter: TimeInterval = 5 * 60
    /// Messages saved with a reaction count when they're at most this old (like Gmail's 30 days of stars).
    static let savedWindow: TimeInterval = 30 * 86_400
    static let mentionsWindow: TimeInterval = 3 * 86_400
    /// Without AI to pick out the ones that matter, at most this many mentions or emails per source per refresh.
    static let unsortedLimit = 15

    private(set) weak var store: Store?
    /// For toasts.
    private(set) weak var app: AppState?
    private var fileURL: URL?
    private var handled: [String: Date] = [:]
    private var skipped: [String: Date] = [:]
    private var focusRecord: SlackFocusRecord?
    private var started = false
    private var refreshTask: Task<Void, Never>?
    private var signInTask: Task<Void, Never>?
    private var focusChain: Task<Void, Never>?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []
    private var slackPausedUntil: Date?
    private var gmailPausedUntil: Date?
    private var userNames: [String: String] = [:]
    private var conversations: [String: SlackChannel] = [:]
    /// Who's in each group DM (by id), for its label. Looked up once a session.
    private var groupMembers: [String: [String]] = [:]
    private var channelList: (channels: [SlackChannel], fetched: Date)?
    private var google: GoogleSession?
    private let saver = IntegrationsSaver()

    /// IntegrationCache/ in the data folder: attachments downloaded for Quick Look (see `InboxCache`).
    var cacheDirectory: URL? {
        fileURL?.deletingLastPathComponent().appendingPathComponent(InboxCache.folderName, isDirectory: true)
    }

    /// Whether saved state was loaded (`attach`): screenshot samples never replace it.
    var hasSavedState: Bool { fileURL != nil }

    init(transport: @escaping IntegrationHTTP.Transport = IntegrationHTTP.live,
         triage: SuggestionTriage = .gemini,
         sleep: @escaping @Sendable (TimeInterval) async throws -> Void = IntegrationHTTP.sleep) {
        self.transport = transport
        self.triage = triage
        self.sleep = sleep
    }

    // MARK: Lifecycle

    /// Called once at launch (never in screenshot mode): loads what was saved, then refreshes at start,
    /// every 15 minutes, and when Docket becomes active after more than 5 minutes.
    func start(store: Store, app: AppState) {
        guard !started, !DebugSnapshot.isActive else { return }
        started = true
        attach(store: store, app: app)

        let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshIfStale() }
        })
        // Saves are written in the background (a note once typing pauses); write what's waiting before the app
        // exits, and whatever the views save as it quits.
        observers.append(center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [saver] _ in
            saver.quit()
        })

        // After launch, so reading secrets never holds up the first window.
        Task { @MainActor [weak self] in await self?.resumeAfterLaunch() }
    }

    /// Remembers the store and loads integrations.json from `directory` (default: the store's data folder).
    /// No network, no timers. `start` calls it; tests call it directly.
    func attach(store: Store, app: AppState?, directory: URL? = nil) {
        self.store = store
        self.app = app
        let url = (directory ?? store.persistence.directory).appendingPathComponent("integrations.json")
        fileURL = url
        let file = IntegrationsFile.load(from: url)
        suggestions = file.suggestions
        handled = file.handled
        skipped = file.skipped
        lastRefresh = file.lastRefresh
        slackAccount = file.slack
        gmailAddress = file.gmailAddress
        focusRecord = file.focusStatus
        isSlackConnected = file.slack != nil
        isGmailConnected = file.gmailAddress != nil
        grantedSlackScopes = file.slackScopes.map(Set.init)
        grantedGmailScopes = file.gmailScopes.map(Set.init)
        savedSlackNames = file.slackNames
        slackStarsStayInDocket = file.slackStarsStayInDocket
        threadSummaries = file.summaries
        // Attachments of messages that are gone, and a cache grown too big.
        pruneInboxCache()

        cancellables = []
        // A message that becomes a task (Add task here, Edit… in the planner, redo, an import) is done.
        // Watched as the change happens, so retiring it joins the undo step that made the task.
        store.$tasks
            .sink { [weak self] tasks in self?.retireSuggestions(onTasks: tasks) }
            .store(in: &cancellables)
    }

    private func resumeAfterLaunch() async {
        // Accounts whose state file went missing come back from this Mac by themselves.
        if slackAccount == nil, let token = Keychain.string(Keychain.Account.slackUserToken) {
            try? await connectSlack(token: token, refreshAfter: false)
        } else if isSlackConnected {
            // The app may have gained (or lost) permissions since: the Slack tab's banner follows.
            await checkSlackPermissions()
        }
        if gmailAddress == nil, Keychain.string(Keychain.Account.googleRefreshToken) != nil, let session = googleSession() {
            if let email = try? await GmailClient(session: session, transport: transport).profileEmail() {
                gmailAddress = email
                isGmailConnected = true
                await noteGmailGrants(session)
                save()
            }
        }
        // A "Heads down" status left over from a session that ended while Docket wasn't running.
        if focusRecord != nil { enqueueFocus { [weak self] in await self?.clearFocusStatus() } }
        refresh()
    }

    // MARK: Refresh

    /// Checks Slack and Gmail for new messages now, without blocking the UI. Does nothing while a check runs.
    func refresh() {
        guard store != nil, refreshTask == nil, isAnyConnected, !DebugSnapshot.isActive else { return }
        refreshTask = Task { @MainActor [weak self] in
            await self?.refreshNow()
            self?.refreshTask = nil
            // In the app only (tests attach without starting): the newest important threads get summaries.
            if self?.started == true { self?.summarizeImportantInBackground() }
        }
    }

    func refreshIfStale() {
        if let last = lastRefresh, Date().timeIntervalSince(last) < Self.staleAfter { return }
        refresh()
    }

    /// Waits for a refresh that's running (tests).
    func waitForRefresh() async {
        await refreshTask?.value
    }

    /// One full check: collect new messages, let AI pick out the ones that need a task, merge, save.
    func refreshNow(now: Date = Date()) async {
        guard let store else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let settings = settings()
        let seen = SeenMessages(blocked: blockedIDs(store), skipped: skipped, pending: suggestions, tasks: store.tasks)

        async let fromSlack = collectSlack(settings: settings, seen: seen, now: now)
        async let fromGmail = collectGmail(settings: settings, seen: seen, now: now)
        let (slack, gmail) = await (fromSlack, fromGmail)

        let sorted = await sort(slack.found + gmail.found, store: store, now: now)
        for id in sorted.skipped { skipped[id] = now }
        // Flagged on purpose after AI passed it over: it isn't "nothing to do" any more.
        for s in sorted.accepted { skipped[s.id] = nil }
        // A service disconnected while AI was reading keeps its cards cleared.
        let accepted = sorted.accepted.filter { s in
            switch s.source.kind {
            case .slack: isSlackConnected
            case .gmail: isGmailConnected
            case .ai: true
            }
        }
        // One card per DM conversation: the newest message replaces older untouched ones.
        let collapsed = SuggestionInbox.collapseConversations(accepted, pending: suggestions)
        for id in collapsed.superseded { skipped[id] = now }
        // Recomputed: tasks may have been added (or cards handled) while this check waited on the network.
        suggestions = SuggestionInbox.merge(collapsed.incoming, into: collapsed.pending, blocked: blockedIDs(store))
        fillIn(slack.wholeMessages)
        savedSlackNames = slackNamesToKeep()
        handled = SuggestionInbox.pruned(handled, now: now)
        skipped = SuggestionInbox.pruned(skipped, now: now)
        // "Updated 10:42 AM" only when something was actually checked; otherwise coming back retries.
        if slack.checked || gmail.checked { lastRefresh = now }
        save()
    }

    private func blockedIDs(_ store: Store) -> Set<String> {
        SuggestionInbox.blockedIDs(pending: suggestions, handled: handled,
                                   taskSourceIDs: Set(store.tasks.compactMap { $0.source?.externalID }))
    }

    /// Slack items saved before Docket kept whole messages get theirs (text, files, thread) when a check
    /// meets the message again.
    private func fillIn(_ found: [Suggestion]) {
        for s in found {
            guard let i = suggestions.firstIndex(where: { $0.id == s.id }), suggestions[i].content == nil else { continue }
            suggestions[i].content = s.content
            suggestions[i].threadTS = s.threadTS
        }
    }

    /// The names the waiting Slack messages' markup refers to (people, channels), to save with them.
    private func slackNamesToKeep() -> [String: String] {
        var ids = Set<String>()
        for s in suggestions where s.source.kind == .slack {
            if let markup = s.content?.markup { ids.formUnion(InboxText.slackIDs(in: markup)) }
            if let channel = InboxIDs.slack(s.id)?.channel { ids.insert(channel) }
        }
        return slackNames.filter { ids.contains($0.key) }
    }

    /// Splits new messages into suggestions (with drafts) and ones AI found nothing to do for.
    private func sort(_ found: [SuggestionCandidate], store: Store, now: Date) async -> (accepted: [Suggestion], skipped: [String]) {
        guard !found.isEmpty else {
            aiProblem = nil
            return ([], [])
        }
        let newestFirst = found.sorted { $0.suggestion.receivedAt > $1.suggestion.receivedAt }
        let aiAvailable = triage.isAvailable()
        var drafts: [String: TaskDraft] = [:]
        var looked = Set<String>()
        var failure: String?
        if aiAvailable {
            // Batches of 25: one failed batch doesn't lose what the others found.
            for start in stride(from: 0, to: newestFirst.count, by: 25) {
                let batch = Array(newestFirst[start..<min(start + 25, newestFirst.count)])
                do {
                    let result = try await triage.run(batch.map(\.message), store, now)
                    drafts.merge(result) { first, _ in first }
                    looked.formUnion(batch.map(\.suggestion.id))
                } catch {
                    if !(error is CancellationError) {
                        failure = "AI couldn't sort the newest messages, so they'll be checked again later. \(error.localizedDescription)"
                    }
                    break
                }
            }
        }
        aiProblem = failure

        var accepted: [Suggestion] = []
        var skipped: [String] = []
        var unsorted: [IntegrationError.Service: Int] = [:]
        for candidate in newestFirst {
            var s = candidate.suggestion
            let explicit = s.trigger?.isExplicit ?? true
            if let draft = drafts[s.id] {
                s.draft = SuggestionDrafts.prepared(draft, for: s)
                accepted.append(s)
            } else if explicit {
                s.draft = SuggestionDrafts.fallback(for: s)
                accepted.append(s)
            } else if looked.contains(s.id) {
                skipped.append(s.id) // AI read it and saw nothing to do.
            } else if !aiAvailable {
                let service: IntegrationError.Service = s.source.kind == .gmail ? .gmail : .slack
                guard unsorted[service, default: 0] < Self.unsortedLimit else { continue }
                unsorted[service, default: 0] += 1
                s.draft = SuggestionDrafts.fallback(for: s)
                accepted.append(s)
            }
            // Otherwise AI is set up but failed this time: the message is looked at again next refresh.
        }
        return (accepted, skipped)
    }

    // MARK: Slack

    func slackToken() -> String? {
        Keychain.string(Keychain.Account.slackUserToken)
    }

    private func slackClient(_ token: String) -> SlackClient {
        SlackClient(token: token, transport: transport, sleep: sleep)
    }

    /// New Slack messages to consider, the whole messages of waiting items saved without them, and whether
    /// Slack could be checked at all.
    private func collectSlack(settings: IntegrationSettings, seen: SeenMessages, now: Date) async
        -> (found: [SuggestionCandidate], wholeMessages: [Suggestion], checked: Bool) {
        guard isSlackConnected, let account = slackAccount else { return ([], [], false) }
        if let until = slackPausedUntil, until > now { return ([], [], false) }
        // Unreadable isn't gone: the secrets file may be locked, or access was refused this time. Only Slack
        // turning the token down disconnects.
        guard let token = slackToken() else {
            slackProblem = "Docket couldn't read the Slack token from this Mac. If it was removed, disconnect Slack and connect it again in Settings → Connections."
            return ([], [], false)
        }
        let unfilled = Set(suggestions.lazy.filter { $0.source.kind == .slack && $0.content == nil }.map(\.id))
        let client = slackClient(token)
        do {
            var found = try await client.savedMessages(by: account.userID, emoji: settings.saveEmoji,
                                                       since: now.addingTimeInterval(-Self.savedWindow))
                .map { ($0, SuggestionTrigger.reaction) }
            if settings.mentions {
                found += try await client.mentions(of: account.userID, since: now.addingTimeInterval(-Self.mentionsWindow))
                    .map { ($0, SuggestionTrigger.mention) }
            }
            var dmProblem: IntegrationError?
            if settings.directMessages {
                let dms = try await directMessages(client, account: account, now: now)
                found += dms.messages.map { ($0, SuggestionTrigger.directMessage) }
                dmProblem = dms.problem
            }
            // A saved message that also mentions you counts as saved, and a DM that mentions you as a mention
            // (they're listed first).
            var ids = Set<String>()
            let fresh = found.filter { seen.isNew($0.0.externalID, $0.1) && ids.insert($0.0.externalID).inserted }
            var filled = Set<String>()
            let old = found.filter { unfilled.contains($0.0.externalID) && filled.insert($0.0.externalID).inserted }
            await learnNames(for: (fresh + old).map { $0.0 }, client: client)
            // The check may have outlived the connection (Disconnect while it ran).
            guard isSlackConnected, slackAccount?.userID == account.userID else { return ([], [], false) }
            // DMs Slack wouldn't let Docket read: said like any missing permission, the rest still comes in.
            if case .missingPermission(.slack, let scopes)? = dmProblem { noteRefusedSlackScopes(scopes) }
            slackProblem = dmProblem?.errorDescription
            slackPausedUntil = nil
            return (fresh.map { slackCandidate($0.0, trigger: $0.1, account: account, now: now) },
                    old.map { slackCandidate($0.0, trigger: $0.1, account: account, now: now).suggestion }, true)
        } catch {
            handleSlack(error, now: now)
            return ([], [], false)
        }
    }

    /// The DMs and group DMs people sent the user lately (`SlackClient.directMessages`), best effort: Slack
    /// signing Docket out or asking it to slow down stops the check as usual; a permission Slack refused comes
    /// back as `problem`, with what could be read; anything else skips DMs this time.
    private func directMessages(_ client: SlackClient, account: SlackAccount, now: Date) async throws
        -> (messages: [SlackMessage], problem: IntegrationError?) {
        // The kinds the token can read, when Slack has said which permissions it has (Settings says what's missing).
        var kinds: Set<String> = ["im", "mpim"]
        if let granted = grantedSlackScopes {
            if !granted.isSuperset(of: ["im:read", "im:history"]) { kinds.remove("im") }
            if !granted.isSuperset(of: ["mpim:read", "mpim:history"]) { kinds.remove("mpim") }
        }
        guard !kinds.isEmpty else { return ([], nil) }
        do {
            let found = try await client.directMessages(of: account.userID, since: now.addingTimeInterval(-Self.mentionsWindow), kinds: kinds)
            let problem = found.missingScopes.isEmpty ? nil
                : IntegrationError.missingPermission(.slack, found.missingScopes.sorted().joined(separator: ","))
            return (found.messages, problem)
        } catch {
            let e = IntegrationError.wrap(error, .slack)
            switch e {
            case .signedOut, .rateLimited, .cancelled:
                throw e
            case .missingPermission:
                return ([], e)
            default:
                NSLog("Docket: couldn't read Slack direct messages this time (%@)", e.errorDescription ?? "")
                return ([], nil)
            }
        }
    }

    /// Looks up the people and channels new messages mention, and who's in their group DMs, a few at a time,
    /// remembering them for the session.
    private func learnNames(for messages: [SlackMessage], client: SlackClient) async {
        var channels = Set<String>()
        for m in messages where m.channelName == nil || m.isDirect {
            channels.insert(m.channelID)
        }
        let missingChannels = Array(channels.filter { conversations[$0] == nil }.prefix(20))
        let foundChannels = await IntegrationHTTP.concurrentMap(missingChannels, limit: 4) { id in try? await client.conversation(id) }
        for channel in foundChannels.compactMap({ $0 }) { conversations[channel.id] = channel }

        // Group DMs are named after the people in them.
        var groups = Set<String>()
        for m in messages where m.isGroupDM || conversations[m.channelID]?.isGroupDM == true {
            groups.insert(m.channelID)
        }
        let missingGroups = Array(groups.filter { groupMembers[$0] == nil }.sorted().prefix(10))
        let foundMembers = await IntegrationHTTP.concurrentMap(missingGroups, limit: 4) { id in (id, try? await client.members(of: id)) }
        for (id, members) in foundMembers { if let members { groupMembers[id] = members } }

        var users = Set<String>()
        for m in messages {
            if let id = m.userID { users.insert(id) }
            users.formUnion(SlackText.mentionedUserIDs(in: m.text))
            users.formUnion(groupMembers[m.channelID] ?? [])
        }
        let missingUsers = Array(users.filter { userNames[$0] == nil }.sorted().prefix(40))
        let foundUsers = await IntegrationHTTP.concurrentMap(missingUsers, limit: 6) { id in try? await client.user(id) }
        for user in foundUsers.compactMap({ $0 }) { userNames[user.id] = user.name }
    }

    /// Slack ids and the names they stand for, people ("U…" → "Priya Shah") and channels ("C…" → "leadership"),
    /// as learned while checking for messages (and saved for the messages waiting). For `SlackText.attributed(_:names:)`.
    var slackNames: [String: String] {
        let channels = conversations.compactMapValues { $0.isDirect || $0.isGroupDM ? nil : $0.name }
        let learned = userNames.merging(channels) { person, _ in person }
        return savedSlackNames.merging(learned) { _, fresh in fresh }
    }

    /// People looked up outside a check (the authors of a thread), remembered for the session like the others.
    func rememberSlackUsers(_ users: [SlackUser]) {
        for user in users { userNames[user.id] = user.name }
    }

    private func slackCandidate(_ m: SlackMessage, trigger: SuggestionTrigger, account: SlackAccount, now: Date) -> SuggestionCandidate {
        let sender = m.userID.flatMap { userNames[$0] } ?? m.userName ?? "Someone"
        let conversation = conversations[m.channelID]
        let label: String
        if m.isGroupDM || conversation?.isGroupDM == true {
            // "Group DM · Priya, Sam": the people in it, the sender first.
            let others = [m.userID].compactMap { $0 } + (groupMembers[m.channelID] ?? [])
            label = InboxText.groupLabel(people: others, me: account.userID, names: userNames, sender: sender)
        } else if m.isDirect || conversation?.isDirect == true {
            label = "\(InboxText.directPlace) · \(sender)"
        } else if let name = m.channelName ?? conversation?.name {
            label = "#\(name) · \(sender)"
        } else {
            label = "Slack · \(sender)"
        }
        let channelNames = conversations.compactMapValues { $0.isDirect || $0.isGroupDM ? nil : $0.name }
        let text = SlackText.plain(m.text, users: userNames, channels: channelNames)
        let link = m.permalink ?? account.permalink(channel: m.channelID, ts: m.ts)
        let source = TaskSource(kind: .slack, externalID: m.externalID, url: link, label: label)
        var suggestion = Suggestion(source: source, from: sender, subject: nil, snippet: String(SlackText.collapsed(text).prefix(500)),
                                    receivedAt: m.date, draft: nil, trigger: trigger)
        // The complete message comes with it: the markup as sent (for rich text), its files, its thread.
        suggestion.content = MessageContent(text: text, markup: m.text, attachments: m.files, fetchedAt: now)
        suggestion.threadTS = m.threadTS
        let message = IncomingMessage(source: source, from: sender, subject: nil, text: String(text.prefix(4000)), date: m.date)
        return SuggestionCandidate(suggestion: suggestion, message: message)
    }

    private func handleSlack(_ error: Error, now: Date) {
        let e = IntegrationError.wrap(error, .slack)
        switch e {
        case .cancelled:
            return
        case .signedOut:
            disconnectSlack(problem: e.errorDescription)
        case .rateLimited(_, let after):
            slackPausedUntil = now.addingTimeInterval(max(60, after))
            slackProblem = e.errorDescription
        default:
            slackProblem = e.errorDescription
        }
    }

    /// Checks the token with Slack (auth.test), then keeps it in the secrets file. Throws a readable error.
    func connectSlack(token raw: String) async throws {
        try await connectSlack(token: raw, refreshAfter: true)
    }

    private func connectSlack(token raw: String, refreshAfter: Bool) async throws {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.hasPrefix("xoxp-") else {
            throw IntegrationError.api(.slack, token.hasPrefix("xoxb-")
                ? "That's a bot token. Paste the User OAuth Token, which starts with xoxp-."
                : "That doesn't look like a Slack user token. It starts with xoxp-.")
        }
        guard !DebugSnapshot.isActive else { throw IntegrationError.notConnected(.slack) }
        var (account, scopes) = try await slackClient(token).identity()
        account.missingScopes = Self.missingCoreScopes(granted: scopes)
        Keychain.set(token, for: Keychain.Account.slackUserToken)
        slackAccount = account
        isSlackConnected = true
        slackPausedUntil = nil
        slackProblem = nil
        channelList = nil
        grantedSlackScopes = scopes
        refusedSlackScopes = []
        // A new app may read the threads the old one couldn't, and may be allowed to save messages for later.
        inbox.threads = [:]
        wholeThreads = wholeThreads.filter { !$0.key.hasPrefix("slack:") }
        slackStarsStayInDocket = false
        save()
        if refreshAfter { refresh() }
    }

    /// The permissions the token lacks, apart from the ones only the complete message needs (those have
    /// their own banner: `missingSlackScopes`). Slack lists a token's permissions with each reply; when it
    /// doesn't, none count as missing.
    static func missingCoreScopes(granted scopes: Set<String>?) -> [String]? {
        guard let scopes else { return nil }
        let missing = SlackManifest.userScopes.filter { !SlackManifest.contentScopes.contains($0) && !scopes.contains($0) }
        return missing.isEmpty ? nil : missing
    }

    /// Asks Slack which permissions the token has now (auth.test), for the warnings and `missingSlackScopes`.
    /// Quietly does nothing when Slack can't be reached.
    func checkSlackPermissions() async {
        guard isSlackConnected, let token = slackToken(), let identity = try? await slackClient(token).identity() else { return }
        noteSlackIdentity(identity.0, scopes: identity.scopes)
    }

    /// What auth.test just said about the token (the account it belongs to, its permissions), kept for the
    /// warnings and `missingSlackScopes`. Ignored when it's about another account than the one connected.
    func noteSlackIdentity(_ account: SlackAccount, scopes: Set<String>?) {
        guard isSlackConnected, var current = slackAccount, current.userID == account.userID else { return }
        current.missingScopes = Self.missingCoreScopes(granted: scopes)
        slackAccount = current
        // Allowed to save messages for later now: Slack is asked again.
        if scopes?.contains(InboxStarRules.slackWrite) == true, grantedSlackScopes?.contains(InboxStarRules.slackWrite) == false {
            slackStarsStayInDocket = false
        }
        grantedSlackScopes = scopes
        refusedSlackScopes = []
        save()
    }

    /// Forgets the Slack token. `problem` explains why when Docket did it by itself; a manual disconnect
    /// also clears the Slack suggestions still waiting.
    func disconnectSlack(problem: String? = nil) {
        Keychain.set(nil, for: Keychain.Account.slackUserToken)
        slackAccount = nil
        isSlackConnected = false
        slackProblem = problem
        slackPausedUntil = nil
        channelList = nil
        userNames = [:]
        conversations = [:]
        focusRecord = nil
        grantedSlackScopes = nil
        refusedSlackScopes = []
        slackStarsStayInDocket = false
        if problem == nil {
            // Their files and threads go with them.
            forgetInbox(suggestions.filter { $0.source.kind == .slack })
            suggestions.removeAll { $0.source.kind == .slack }
            savedSlackNames = [:]
        }
        save()
    }

    /// Channels you're in, for "Share to Slack" (cached for 10 minutes).
    func slackChannels(reload: Bool = false) async throws -> [SlackChannel] {
        if !reload, let cached = channelList, Date().timeIntervalSince(cached.fetched) < 600 { return cached.channels }
        guard isSlackConnected, let token = slackToken() else { throw IntegrationError.notConnected(.slack) }
        do {
            let channels = try await slackClient(token).channels()
            channelList = (channels, Date())
            return channels
        } catch {
            let e = IntegrationError.wrap(error, .slack)
            if case .signedOut = e { disconnectSlack(problem: e.errorDescription) }
            throw e
        }
    }

    /// Posts the tasks as a short plan, as you, to `channel`.
    func share(taskIDs: [UUID], to channel: SlackChannel, now: Date = Date()) async throws {
        guard let store else { throw IntegrationError.notConnected(.slack) }
        guard isSlackConnected, let token = slackToken() else { throw IntegrationError.notConnected(.slack) }
        let tasks = taskIDs.compactMap { store.task($0) }
        guard !tasks.isEmpty else { return }
        do {
            try await slackClient(token).post(SlackShare.message(for: tasks, now: now), to: channel.id)
        } catch {
            let e = IntegrationError.wrap(error, .slack)
            if case .signedOut = e { disconnectSlack(problem: e.errorDescription) }
            throw e
        }
    }

    // MARK: Gmail

    /// The Google OAuth client from Settings, the app bundle or the environment.
    var googleClient: GoogleOAuth.Client? {
        guard let id = Secrets.googleClientID, let secret = Secrets.googleClientSecret else { return nil }
        return GoogleOAuth.Client(id: id, secret: secret)
    }

    func saveGoogleClient(id: String, secret: String) {
        Keychain.set(id.trimmingCharacters(in: .whitespacesAndNewlines), for: Keychain.Account.googleClientID)
        Keychain.set(secret.trimmingCharacters(in: .whitespacesAndNewlines), for: Keychain.Account.googleClientSecret)
        google = nil
        googleClientRevision += 1
    }

    func googleSession() -> GoogleSession? {
        if let google { return google }
        guard let client = googleClient, let refreshToken = Keychain.string(Keychain.Account.googleRefreshToken) else { return nil }
        let session = GoogleSession(client: client, refreshToken: refreshToken, transport: transport)
        google = session
        return session
    }

    /// New emails to consider, and whether Gmail could be checked at all.
    private func collectGmail(settings: IntegrationSettings, seen: SeenMessages, now: Date) async -> (found: [SuggestionCandidate], checked: Bool) {
        guard isGmailConnected, let address = gmailAddress else { return ([], false) }
        if let until = gmailPausedUntil, until > now { return ([], false) }
        // As for Slack: an unreadable secret doesn't disconnect; Google refusing the sign-in does.
        guard let session = googleSession() else {
            gmailProblem = googleClient == nil
                ? "Docket couldn't find your Google OAuth client. Disconnect Gmail in Settings → Connections, add the client again, then connect."
                : "Docket couldn't read the Gmail sign-in from this Mac. If it was removed, disconnect Gmail and connect it again in Settings → Connections."
            return ([], false)
        }
        let client = GmailClient(session: session, transport: transport)
        do {
            var refs = try await client.messageRefs(matching: GmailClient.starredQuery, max: 25).map { ($0, SuggestionTrigger.starred) }
            if settings.needsReply {
                refs += try await client.messageRefs(matching: GmailClient.needsReplyQuery, max: 25).map { ($0, SuggestionTrigger.needsReply) }
            }
            // One card per conversation: the newest message (lists come newest first), a star first.
            var threads = Set<String>()
            let fresh = refs.filter { ref, trigger in
                seen.isNewEmail(ref, trigger) && threads.insert(ref.threadID).inserted
            }
            let messages = try await client.messages(fresh.map { $0.0 })
            guard isGmailConnected, gmailAddress == address else { return ([], false) }
            let triggers = Dictionary(fresh.map { ($0.0.id, $0.1) }, uniquingKeysWith: { first, _ in first })
            gmailProblem = nil
            gmailPausedUntil = nil
            await noteGmailGrants(session)
            return (messages.compactMap { m in triggers[m.id].map { gmailCandidate(m, trigger: $0, address: address) } }, true)
        } catch {
            handleGmail(error, now: now)
            return ([], false)
        }
    }

    private func gmailCandidate(_ m: GmailMessage, trigger: SuggestionTrigger, address: String) -> SuggestionCandidate {
        let sender = m.sender.displayName
        let subject = m.subject.flatMap { $0.isEmpty ? nil : $0 }
        let source = TaskSource(kind: .gmail, externalID: m.externalID, url: GmailClient.threadLink(account: address, threadID: m.threadID),
                                label: [sender, subject].compactMap { $0 }.joined(separator: " · "))
        var suggestion = Suggestion(source: source, from: sender, subject: subject, snippet: m.snippet,
                                    receivedAt: m.date, draft: nil, trigger: trigger)
        // Starred in Gmail: starred here too (unstarring it in Docket keeps it in the inbox until it's dismissed).
        suggestion.isStarred = trigger == .starred || m.labels.contains(InboxStarRules.gmailLabel)
        let message = IncomingMessage(source: source, from: m.sender.full, subject: subject, text: m.snippet, date: m.date)
        return SuggestionCandidate(suggestion: suggestion, message: message)
    }

    private func handleGmail(_ error: Error, now: Date) {
        let e = IntegrationError.wrap(error, .gmail)
        switch e {
        case .cancelled:
            return
        case .signedOut:
            disconnectGmail(problem: e.errorDescription)
        case .rateLimited(_, let after):
            gmailPausedUntil = now.addingTimeInterval(max(60, after))
            gmailProblem = e.errorDescription
        default:
            gmailProblem = e.errorDescription
        }
    }

    /// Signs in with Google in the default browser (loopback redirect + PKCE), then remembers the account.
    func connectGmail() {
        guard signInTask == nil, !DebugSnapshot.isActive else { return }
        guard let client = googleClient else {
            gmailProblem = "Add your Google OAuth client ID and secret first."
            return
        }
        isSigningInToGmail = true
        gmailProblem = nil
        signInTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let tokens = try await GoogleOAuth.signIn(client: client, transport: transport, open: openURL)
                // Reading takes gmail.readonly or gmail.modify (what Docket asks for now).
                guard Self.canReadMail(granted: tokens.scopes) else {
                    throw IntegrationError.missingPermission(.gmail, "read your email")
                }
                guard let refreshToken = tokens.refreshToken else {
                    throw IntegrationError.api(.google, "Google didn't send a lasting sign-in. Try connecting again.")
                }
                let session = GoogleSession(client: client, refreshToken: refreshToken, transport: transport, tokens: tokens)
                let email = try await GmailClient(session: session, transport: transport).profileEmail()
                Keychain.set(refreshToken, for: Keychain.Account.googleRefreshToken)
                google = session
                gmailAddress = email
                isGmailConnected = true
                gmailPausedUntil = nil
                // What was granted: starring needs gmail.modify, which the consent screen lets people leave out
                // (replying needs it or gmail.compose). When Google doesn't list them, what Docket asked for.
                grantedGmailScopes = tokens.scopes.isEmpty ? Set(GoogleOAuth.scopes) : tokens.scopes
                save()
                NSApplication.shared.activate(ignoringOtherApps: true) // back from the browser
                refresh()
            } catch {
                let e = IntegrationError.wrap(error, .gmail)
                if e != .cancelled && e != .signInCancelled { gmailProblem = e.errorDescription }
            }
            isSigningInToGmail = false
            signInTask = nil
        }
    }

    func cancelGmailSignIn() {
        signInTask?.cancel()
    }

    /// Forgets Gmail. A manual disconnect (no `problem`) also revokes the sign-in at Google and clears
    /// the Gmail suggestions still waiting.
    func disconnectGmail(problem: String? = nil) {
        let refreshToken = Keychain.string(Keychain.Account.googleRefreshToken)
        Keychain.set(nil, for: Keychain.Account.googleRefreshToken)
        if problem == nil, let refreshToken {
            let transport = transport
            Task.detached { await GoogleOAuth.revoke(refreshToken, transport: transport) }
        }
        google = nil
        gmailAddress = nil
        isGmailConnected = false
        gmailProblem = problem
        gmailPausedUntil = nil
        grantedGmailScopes = nil
        if problem == nil {
            // Their attachments and conversations go with them.
            forgetInbox(suggestions.filter { $0.source.kind == .gmail })
            suggestions.removeAll { $0.source.kind == .gmail }
        }
        save()
    }

    /// Google may have granted more than Docket knew (the session learns it with a token): sending (gmail.compose)
    /// and starring (gmail.modify, which covers sending too) then work from Docket.
    func noteGmailGrants(_ session: GoogleSession) async {
        guard let granted = await session.grantedScopes, isGmailConnected else { return }
        let gmail = granted.intersection([GoogleOAuth.gmailScope, GoogleOAuth.composeScope, GoogleOAuth.modifyScope])
        let known = grantedGmailScopes ?? []
        guard !gmail.isSubset(of: known) else { return }
        grantedGmailScopes = known.union(gmail)
        save()
    }

    // MARK: Acting on suggestions

    /// Adds the suggestion as a task (its draft, linked back to the message) and stops suggesting it.
    /// One undo step takes the task away and brings the card back.
    @discardableResult
    func add(_ suggestion: Suggestion, toast: Bool = true) -> TaskItem? {
        // Only a card that's still waiting: a second click as it animates away adds nothing more. As it is
        // now, not as the view last saw it: notes saved a moment before the click go into the task.
        guard let store, let current = self.suggestion(suggestion.id) else { return nil }
        let undo = store.undoManager
        undo?.beginUndoGrouping()
        let task = store.addTask(Self.task(for: current, lists: store.lists))
        retire([current.id]) // usually done already, as the task appeared
        undo?.setActionName("Add Task")
        undo?.endUndoGrouping()
        if toast { app?.showToast("Added “\(Self.shortTitle(task.title))”") }
        return task
    }

    /// Adds every waiting suggestion as a task, as one undo step.
    func addAll() {
        guard let store, !suggestions.isEmpty else { return }
        let all = suggestions
        let undo = store.undoManager
        undo?.beginUndoGrouping()
        let added = all.map { store.addTask(Self.task(for: $0, lists: store.lists)) }
        retire(Set(all.map(\.id)))
        undo?.setActionName("Add Tasks")
        undo?.endUndoGrouping()
        app?.showToast("Added \(Fmt.plural(added.count, "task"))")
    }

    /// Opens the draft in "Plan with AI" to adjust before adding. The draft carries its source, so the task
    /// it becomes links back, and the card goes once that task exists (in the same undo step). Like `add`,
    /// it reads the card as it is now, with the notes just saved.
    func edit(_ suggestion: Suggestion) {
        guard let app else { return }
        app.aiPlanner = AIPlannerRequest(drafts: [SuggestionDrafts.draft(for: self.suggestion(suggestion.id) ?? suggestion)])
    }

    /// Stops suggesting the message. Undoable.
    func dismiss(_ suggestion: Suggestion) {
        let undo = store?.undoManager
        undo?.beginUndoGrouping()
        retire([suggestion.id])
        undo?.setActionName("Dismiss Suggestion")
        undo?.endUndoGrouping()
    }

    /// Opens the message in Slack or Gmail (https links only).
    func open(_ suggestion: Suggestion) {
        guard let url = suggestion.source.url, url.scheme == "https" else { return }
        openURL(url)
    }

    static func task(for suggestion: Suggestion, lists: [TaskList]) -> TaskItem {
        SuggestionDrafts.draft(for: suggestion).makeTask(lists: lists, source: suggestion.source)
    }

    /// A title short enough for a toast.
    static func shortTitle(_ title: String, limit: Int = 48) -> String {
        guard title.count > limit else { return title }
        return String(title.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Takes the cards for these messages off the list and remembers them as handled. The window's undo
    /// brings them back (redo takes them away again); it joins whatever undo step is being recorded.
    private func retire(_ ids: Set<String>, at now: Date = Date()) {
        let retired = suggestions.filter { ids.contains($0.id) }
        guard !retired.isEmpty else { return }
        for s in retired { handled[s.id] = now }
        suggestions.removeAll { ids.contains($0.id) }
        save()
        store?.undoManager?.registerUndo(withTarget: self) { $0.bringBack(retired) }
    }

    private func bringBack(_ items: [Suggestion]) {
        // Never next to a task that still has the message (undo only runs after the task is gone).
        let onTasks = Set(store?.tasks.compactMap { $0.source?.externalID } ?? [])
        let waiting = Set(suggestions.map(\.id))
        let back = items.filter { !onTasks.contains($0.id) && !waiting.contains($0.id) }
        for s in back { handled[s.id] = nil }
        if !back.isEmpty {
            suggestions = (suggestions + back).sorted { $0.receivedAt > $1.receivedAt }
            save()
        }
        store?.undoManager?.registerUndo(withTarget: self) { $0.retire(Set(items.map(\.id))) }
    }

    /// Cards whose message is now on a task are done: added here, through Edit… in the planner, or by redo.
    private func retireSuggestions(onTasks tasks: [TaskItem]) {
        guard !suggestions.isEmpty else { return }
        let waiting = Set(suggestions.map(\.id))
        var done = Set<String>()
        for t in tasks {
            if let id = t.source?.externalID, waiting.contains(id) { done.insert(id) }
        }
        retire(done)
    }

    // MARK: Focus status (Slack)

    /// A focus session started; `until` is when it ends (nil for a stopwatch). The task title never goes to Slack.
    func focusStarted(until: Date?, taskTitle: String) {
        guard store != nil, isSlackConnected, settings().focusStatus else { return }
        enqueueFocus { [weak self] in await self?.applyFocusStatus(until: until) }
    }

    /// The focus session stopped.
    func focusEnded() {
        guard store != nil else { return }
        enqueueFocus { [weak self] in await self?.clearFocusStatus() }
    }

    /// Waits until queued status changes are done (tests).
    func waitForFocusUpdates() async {
        await focusChain?.value
    }

    /// Status changes run one after another, so "stop, then start again" can't interleave.
    private func enqueueFocus(_ work: @escaping @MainActor () async -> Void) {
        let previous = focusChain
        focusChain = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    private func applyFocusStatus(until: Date?) async {
        guard isSlackConnected, let account = slackAccount, let token = slackToken() else { return }
        let client = slackClient(token)
        let now = Date()
        // A stopwatch has no end; an hour keeps a forgotten status from lingering.
        let end = until ?? now.addingTimeInterval(3600)
        do {
            let current = try await client.status(of: account.userID)
            // Remember what was there, to put it back afterwards (never our own "Heads down").
            let previous = current.isFocus ? focusRecord?.previous : (current.isEmpty || current.hasExpired(at: now) ? nil : current)
            try await client.setStatus(.focus(until: end))
            var record = SlackFocusRecord(previous: previous, until: end, snoozeUntil: nil)
            focusRecord = record
            save()
            let minutes = max(1, Int((end.timeIntervalSince(now) / 60).rounded(.up)))
            if let snoozeEnd = try? await client.snooze(minutes: minutes) {
                record.snoozeUntil = snoozeEnd
                focusRecord = record
                save()
            }
        } catch {
            let e = IntegrationError.wrap(error, .slack)
            if case .signedOut = e { disconnectSlack(problem: e.errorDescription) } else if e != .cancelled {
                slackProblem = "Couldn't set your Slack status. \(e.errorDescription ?? "")"
            }
        }
    }

    private func clearFocusStatus() async {
        guard let record = focusRecord else { return }
        guard isSlackConnected, let account = slackAccount, let token = slackToken() else {
            focusRecord = nil
            save()
            return
        }
        let client = slackClient(token)
        let now = Date()
        do {
            // Only undo what's still ours: if the user set another status meanwhile, they've taken over
            // (status and notifications both).
            if try await client.status(of: account.userID).isFocus {
                if let previous = record.previous, !previous.hasExpired(at: now) {
                    try await client.setStatus(previous)
                } else {
                    try await client.setStatus(SlackStatus())
                }
                if let snooze = record.snoozeUntil, snooze > now { try? await client.endSnooze() }
            }
            focusRecord = nil
            save()
        } catch {
            let e = IntegrationError.wrap(error, .slack)
            if case .signedOut = e { disconnectSlack(problem: e.errorDescription) }
            // Offline: the record stays, so the next launch tries again (the status expires by itself anyway).
        }
    }

    // MARK: Screenshot mode

    /// Both services connected as made-up accounts with every permission, checked a few minutes ago. Nothing
    /// is read from this Mac or the network (see `debugSeed`).
    func showSampleAccounts(slack account: SlackAccount, gmail address: String, refreshedAt: Date) {
        slackAccount = account
        isSlackConnected = true
        grantedSlackScopes = Set(SlackManifest.userScopes).union(SlackManifest.contentScopes)
        refusedSlackScopes = []
        gmailAddress = address
        isGmailConnected = true
        grantedGmailScopes = Set(GoogleOAuth.scopes).union([GoogleOAuth.composeScope, GoogleOAuth.modifyScope])
        slackStarsStayInDocket = false
        lastRefresh = refreshedAt
        slackProblem = nil
        gmailProblem = nil
        aiProblem = nil
    }

    // MARK: Saving

    /// Writes integrations.json in the background. `soon`: the user is typing (a note, a reply), so the
    /// write waits for a pause; quitting writes whatever is waiting.
    func save(soon: Bool = false) {
        guard let fileURL else { return }
        var file = IntegrationsFile()
        file.suggestions = suggestions.map(\.forSaving)
        file.handled = handled
        file.skipped = skipped
        file.lastRefresh = lastRefresh
        file.slack = slackAccount
        file.gmailAddress = gmailAddress
        file.focusStatus = focusRecord
        file.slackScopes = grantedSlackScopes?.sorted()
        file.gmailScopes = grantedGmailScopes?.sorted()
        file.slackNames = savedSlackNames
        file.slackStarsStayInDocket = slackStarsStayInDocket
        file.summaries = summariesToKeep
        saver.save(file, to: fileURL, after: soon ? IntegrationsSaver.typingPause : 0)
    }

    /// Writes what's waiting and returns once it's on disk (quitting, tests). Blocks until then: not for
    /// everyday use on the main thread.
    func flushSaves() {
        saver.flush()
    }
}

/// Writes integrations.json on a background queue, so a big file (whole emails) never holds up typing.
/// The newest state wins. A write can wait for a pause in typing; `flush` writes what's waiting right away.
final class IntegrationsSaver: @unchecked Sendable {
    /// How long typing pauses before a note or a reply is written.
    static let typingPause: TimeInterval = 0.6

    private let queue = DispatchQueue(label: "docket.integrations.save", qos: .utility)
    private let lock = NSLock()
    private var pending: (file: IntegrationsFile, url: URL)?
    private var generation = 0
    /// Docket is quitting: there's no pause left to wait for.
    private var quitting = false

    func save(_ file: IntegrationsFile, to url: URL, after delay: TimeInterval = 0) {
        lock.lock()
        pending = (file, url)
        generation += 1
        let mine = generation
        let now = quitting
        lock.unlock()
        if now {
            // On disk before Docket exits (a note's last words, saved as the window closes).
            queue.sync { writePending() }
            return
        }
        guard delay > 0 else {
            queue.async { self.writePending() }
            return
        }
        queue.asyncAfter(deadline: .now() + delay) {
            // Typing went on: the newest change waits for its own pause (or was written with something else).
            self.lock.lock()
            let newest = self.generation == mine
            self.lock.unlock()
            if newest { self.writePending() }
        }
    }

    /// Writes what's waiting and returns once it's on disk (tests).
    func flush() {
        queue.sync { writePending() }
    }

    /// Docket is quitting: writes what's waiting, and from now on writes each save at once, so one made
    /// while Docket quits (the views save what was typed then too) still lands.
    func quit() {
        lock.lock()
        quitting = true
        lock.unlock()
        flush()
    }

    private func writePending() {
        lock.lock()
        let job = pending
        pending = nil
        lock.unlock()
        guard let job else { return }
        do {
            let data = try job.file.encoded()
            try FileManager.default.createDirectory(at: job.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: job.url, options: .atomic)
        } catch {
            NSLog("Docket: couldn't save integrations.json (%@)", (error as NSError).localizedDescription)
        }
    }
}
