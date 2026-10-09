import Foundation
import UniformTypeIdentifiers

// MARK: - Models

/// Who the Slack token belongs to (from auth.test).
struct SlackAccount: Codable, Hashable, Sendable {
    var userID: String
    /// The Slack handle, as in "@maya".
    var userName: String
    var teamID: String
    var teamName: String
    var teamURL: URL?
    /// Permissions the Docket app in Slack was made without (seen when connecting), so Settings can say so.
    var missingScopes: [String]?

    /// A link to a message, for the rare reply that comes without a permalink.
    func permalink(channel: String, ts: String) -> URL? {
        guard let teamURL else { return nil }
        return URL(string: "archives/\(channel)/p\(ts.replacingOccurrences(of: ".", with: ""))", relativeTo: teamURL)?.absoluteURL
    }
}

/// A Slack status (the emoji and text next to your name).
struct SlackStatus: Codable, Hashable, Sendable {
    var text = ""
    var emoji = ""
    /// Unix time when Slack clears it by itself; 0 = never.
    var expiration = 0

    static let focusText = "Heads down"
    static let focusEmoji = ":dart:"

    static func focus(until end: Date) -> SlackStatus {
        SlackStatus(text: focusText, emoji: focusEmoji, expiration: Int(end.timeIntervalSince1970.rounded(.up)))
    }

    /// Docket's own "Heads down" status.
    var isFocus: Bool { text == Self.focusText && emoji == Self.focusEmoji }
    var isEmpty: Bool { text.isEmpty && emoji.isEmpty }

    func hasExpired(at now: Date) -> Bool {
        expiration > 0 && TimeInterval(expiration) <= now.timeIntervalSince1970
    }
}

/// While a focus session runs: the status Docket replaced (to put it back) and when its own ends.
struct SlackFocusRecord: Codable, Hashable {
    var previous: SlackStatus?
    var until: Date
    var snoozeUntil: Date?
}

struct SlackChannel: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var isPrivate = false
    var isDirect = false
    var isGroupDM = false
    var isMember = true
    var isArchived = false
}

struct SlackUser: Hashable, Sendable {
    var id: String
    /// Real name when there is one ("Priya Shah"), else the display name or handle.
    var name: String
    var status: SlackStatus
}

/// A message from reactions.list or search.messages.
struct SlackMessage: Hashable, Sendable {
    var channelID: String
    /// Known for search results ("leadership"); nil when only the id came back.
    var channelName: String?
    var isDirect = false
    var isGroupDM = false
    var ts: String
    var userID: String?
    /// The handle or bot name Slack sent along, used when the person can't be looked up.
    var userName: String?
    /// Slack markup ("<@U123> can you…"); see `SlackText.plain`.
    var text: String
    var permalink: URL?
    /// Files shared in the message (deleted and hidden ones left out).
    var files: [MessageAttachment] = []
    /// The parent message's ts when this one is a reply in a thread.
    var threadTS: String?

    var date: Date { Date(timeIntervalSince1970: TimeInterval(ts) ?? 0) }
    /// "slack:C024BE91L/1712345678.000100"
    var externalID: String { "slack:\(channelID)/\(ts)" }

    /// Joins, topic changes and the like never need a task.
    static let ignoredSubtypes: Set<String> = [
        "channel_join", "channel_leave", "channel_topic", "channel_purpose", "channel_name", "channel_archive",
        "channel_unarchive", "group_join", "group_leave", "group_topic", "group_purpose", "group_name", "pinned_item", "unpinned_item",
    ]
}

// MARK: - Client

/// Slack's Web API with the user's own token (the User OAuth Token of the Docket app they created).
/// Waits out short rate limits (HTTP 429 + Retry-After); longer ones surface as `.rateLimited`.
struct SlackClient: Sendable {
    let token: String
    var transport: IntegrationHTTP.Transport = IntegrationHTTP.live
    var sleep: @Sendable (TimeInterval) async throws -> Void = IntegrationHTTP.sleep

    static let api = URL(string: "https://slack.com/api/")!
    /// The longest Retry-After worth waiting for inside a call; longer waits pause syncing instead.
    static let longestWait: TimeInterval = 30

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    /// Calls a Web API method as a form-encoded POST with the token in the Authorization header.
    func call<Reply: Decodable>(_ method: String, _ params: [(String, String)] = [], as type: Reply.Type) async throws -> (Reply, HTTPURLResponse) {
        do {
            return try await perform(method, params, as: type)
        } catch let refusal as Refusal {
            throw Self.error(code: refusal.code, needed: refusal.needed)
        }
    }

    /// One page of a paginated method. Slack sometimes refuses its own cursor for a later page
    /// ("invalid_cursor": it expired, or the list changed under it). That page returns nil so the caller
    /// keeps the pages it already has instead of failing the whole refresh. On the first page it's an error.
    func page<Reply: Decodable>(_ method: String, _ params: [(String, String)], cursor: String?, as type: Reply.Type) async throws -> Reply? {
        do {
            return try await perform(method, params, as: type).0
        } catch let refusal as Refusal {
            if refusal.code == "invalid_cursor", cursor != nil {
                NSLog("Docket: Slack refused the next page of %@ (invalid_cursor); keeping the pages so far", method)
                return nil
            }
            throw Self.error(code: refusal.code, needed: refusal.needed)
        }
    }

    /// Slack turned a call down (`"ok": false`): its error code, before it's put in plain words.
    struct Refusal: Error, Equatable {
        var code: String
        var needed: String?
    }

    /// `call`, except that a refusal comes back as a `Refusal`, for methods that read some codes their own way.
    /// `unsure` is the error for a post that timed out or lost its connection (see `send`).
    private func perform<Reply: Decodable>(_ method: String, _ params: [(String, String)], as type: Reply.Type,
                                           unsure: IntegrationError? = nil) async throws -> (Reply, HTTPURLResponse) {
        let (data, response) = try await send(IntegrationHTTP.formPost(Self.api.appendingPathComponent(method), params, bearer: token),
                                              unsure: unsure)
        guard (200..<300).contains(response.statusCode) else {
            throw IntegrationError.unexpected(.slack, "HTTP \(response.statusCode)")
        }
        guard let envelope = try? Self.decoder.decode(Envelope.self, from: data) else {
            throw IntegrationError.unexpected(.slack, "an unreadable reply")
        }
        guard envelope.ok else {
            throw Refusal(code: envelope.error ?? "unknown_error", needed: envelope.needed)
        }
        do {
            return (try Self.decoder.decode(Reply.self, from: data), response)
        } catch {
            throw IntegrationError.unexpected(.slack, "an unreadable reply to \(method)")
        }
    }

    /// Sends a request, waiting out short rate limits (HTTP 429 with a Retry-After of at most
    /// `longestWait`, twice at most); a longer one throws `.rateLimited`. A post that timed out or lost its
    /// connection may have gone through all the same: that throws `unsure`, when given, so the person checks
    /// Slack instead of posting twice.
    private func send(_ request: URLRequest, unsure: IntegrationError? = nil) async throws -> (Data, HTTPURLResponse) {
        var waits = 0
        while true {
            let (data, response): (Data, HTTPURLResponse)
            do {
                (data, response) = try await transport(request)
            } catch {
                if let unsure, IntegrationHTTP.mayHaveArrived(error) { throw unsure }
                throw IntegrationError.wrap(error, .slack)
            }
            guard response.statusCode == 429 else { return (data, response) }
            let after = IntegrationHTTP.retryAfter(response) ?? Self.longestWait
            guard waits < 2, after <= Self.longestWait else {
                throw IntegrationError.rateLimited(.slack, retryAfter: after)
            }
            waits += 1
            try await sleep(after)
        }
    }

    /// Slack's error codes in plain words.
    static func error(code: String, needed: String?) -> IntegrationError {
        switch code {
        case "invalid_auth", "not_authed", "token_revoked", "token_expired", "account_inactive", "user_removed_from_team":
            return .signedOut(.slack)
        case "missing_scope":
            // "…is missing the needed permission" when Slack doesn't say which.
            return .missingPermission(.slack, needed ?? "needed")
        case "ratelimited":
            return .rateLimited(.slack, retryAfter: 60)
        case "not_in_channel":
            return .api(.slack, "Join that channel in Slack first, then try again.")
        case "channel_not_found":
            return .api(.slack, "That channel isn't available any more.")
        case "is_archived":
            return .api(.slack, "That channel is archived.")
        case "msg_too_long":
            return .api(.slack, "That's too long for one Slack message. Share fewer tasks.")
        case "restricted_action", "restricted_action_read_only_channel", "restricted_action_non_threadable_channel", "ekm_access_denied", "team_access_not_granted":
            return .api(.slack, "Your Slack workspace doesn't allow this.")
        case "profile_set_failed", "too_many_frequent_profile_updates":
            return .api(.slack, "Slack didn't change your status. Try again in a minute.")
        default:
            return .api(.slack, "Slack said “\(code)”.")
        }
    }

    // MARK: Account

    /// Who the token belongs to, and which permissions it has (from the x-oauth-scopes header, when sent).
    func identity() async throws -> (SlackAccount, scopes: Set<String>?) {
        let (reply, response) = try await call("auth.test", as: AuthTestReply.self)
        guard let userID = reply.userId, let teamID = reply.teamId else {
            throw IntegrationError.unexpected(.slack, "no user in auth.test")
        }
        let account = SlackAccount(userID: userID, userName: reply.user ?? userID, teamID: teamID,
                                   teamName: reply.team ?? "your workspace", teamURL: reply.url.flatMap(URL.init(string:)))
        let scopes = response.value(forHTTPHeaderField: "x-oauth-scopes").map { header in
            Set(header.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        }
        return (account, scopes)
    }

    // MARK: Reading

    /// Messages `userID` reacted to with `emoji` (e.g. "pushpin"), posted since `since`.
    func savedMessages(by userID: String, emoji: String, since: Date, pages: Int = 2) async throws -> [SlackMessage] {
        var result: [SlackMessage] = []
        var cursor: String?
        for _ in 0..<pages {
            var params = [("user", userID), ("full", "true"), ("limit", "100")]
            if let cursor { params.append(("cursor", cursor)) }
            guard let reply = try await page("reactions.list", params, cursor: cursor, as: ReactionsReply.self) else { break }
            for item in (reply.items ?? []).compactMap(\.value) {
                guard item.type == "message", let channel = item.channel?.id, let raw = item.message,
                      raw.hasReaction(emoji, by: userID),
                      let message = SlackMessage(raw, channel: channel, info: nil), message.date >= since else { continue }
                result.append(message)
            }
            guard let next = reply.responseMetadata?.nextCursor, !next.isEmpty else { break }
            cursor = next
        }
        return result
    }

    /// Messages from others that @mention `userID`, newest first, posted since `since`.
    func mentions(of userID: String, since: Date) async throws -> [SlackMessage] {
        // "after:" is exclusive and by day; the exact cut-off is applied below.
        let day = Fmt.dayKey(since.addingTimeInterval(-86_400))
        let params = [("query", "<@\(userID)> after:\(day)"), ("sort", "timestamp"), ("sort_dir", "desc"), ("count", "50")]
        let (reply, _) = try await call("search.messages", params, as: SearchReply.self)
        return (reply.messages?.matches ?? []).compactMap(\.value).compactMap { raw -> SlackMessage? in
            guard let info = raw.channel, let id = info.id,
                  !SlackMessage.ignoredSubtypes.contains(raw.subtype ?? ""),
                  let message = SlackMessage(raw, channel: id, info: info),
                  message.date >= since, message.userID != userID else { return nil }
            return message
        }
    }

    /// Channels you're a member of (public and private), by name: the ones you can post a plan to.
    /// users.conversations lists only your own channels (conversations.list would page through every
    /// public channel in the workspace), with the same scopes.
    func channels(pages: Int = 5) async throws -> [SlackChannel] {
        var result: [SlackChannel] = []
        var cursor: String?
        for _ in 0..<pages {
            var params = [("types", "public_channel,private_channel"), ("exclude_archived", "true"), ("limit", "200")]
            if let cursor { params.append(("cursor", cursor)) }
            guard let reply = try await page("users.conversations", params, cursor: cursor, as: ConversationsReply.self) else { break }
            result += (reply.channels ?? []).compactMap(\.value).compactMap(\.channel)
                .filter { $0.isMember && !$0.isArchived && !$0.isDirect && !$0.isGroupDM }
            guard let next = reply.responseMetadata?.nextCursor, !next.isEmpty else { break }
            cursor = next
        }
        var seen = Set<String>()
        return result.filter { seen.insert($0.id).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func conversation(_ id: String) async throws -> SlackChannel {
        let (reply, _) = try await call("conversations.info", [("channel", id)], as: ConversationReply.self)
        guard let channel = reply.channel?.channel else { throw IntegrationError.unexpected(.slack, "no channel") }
        return channel
    }

    func user(_ id: String) async throws -> SlackUser {
        let (reply, _) = try await call("users.info", [("user", id)], as: UserReply.self)
        guard let raw = reply.user, let userID = raw.id else { throw IntegrationError.unexpected(.slack, "no user") }
        let profile = raw.profile
        let names = [profile?.realName, raw.realName, profile?.displayName, raw.name]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        let status = SlackStatus(text: profile?.statusText ?? "", emoji: profile?.statusEmoji ?? "", expiration: profile?.statusExpiration ?? 0)
        return SlackUser(id: userID, name: names.first { !$0.isEmpty } ?? userID, status: status)
    }

    func status(of userID: String) async throws -> SlackStatus {
        try await user(userID).status
    }

    // MARK: Writing

    func setStatus(_ status: SlackStatus) async throws {
        let profile: [String: Any] = ["status_text": status.text, "status_emoji": status.emoji, "status_expiration": status.expiration]
        let json = try JSONSerialization.data(withJSONObject: profile, options: [.sortedKeys])
        _ = try await call("users.profile.set", [("profile", String(decoding: json, as: UTF8.self))], as: Envelope.self)
    }

    /// Pauses notifications for `minutes`; returns when the pause ends.
    func snooze(minutes: Int) async throws -> Date? {
        let (reply, _) = try await call("dnd.setSnooze", [("num_minutes", "\(max(1, minutes))")], as: SnoozeReply.self)
        return reply.snoozeEndtime.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    func endSnooze() async throws {
        do {
            _ = try await call("dnd.endSnooze", as: Envelope.self)
        } catch IntegrationError.api(_, let message) where message.contains("snooze_not_active") {
            // Already over.
        }
    }

    /// Posts as the user (the token's chat:write scope), with link previews off.
    func post(_ text: String, to channel: String) async throws {
        _ = try await call("chat.postMessage", [("channel", channel), ("text", text), ("unfurl_links", "false"), ("unfurl_media", "false")],
                           as: Envelope.self)
    }
}

// MARK: - Threads, files, replying

extension SlackClient {
    /// Posts `text` under the message as the user (`chat.postMessage` with `thread_ts`).
    ///
    /// `text` is what the person wrote, Slack formatting like *bold* included; it's escaped for Slack here.
    /// The reply stays in the thread (never "also send to the channel"), and it only notifies the people
    /// it mentions.
    func reply(channel: String, threadTS: String, text: String) async throws {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw IntegrationError.api(.slack, "Write a reply first.") }
        guard !channel.isEmpty, Self.isTimestamp(threadTS) else { throw IntegrationError.unexpected(.slack, "no message to reply to") }
        do {
            _ = try await perform("chat.postMessage", [("channel", channel), ("thread_ts", threadTS), ("text", SlackText.outgoing(body))],
                                  as: Envelope.self,
                                  unsure: .api(.slack, "Slack didn't answer in time, so Docket can't tell if the reply was posted. Check the thread in Slack before trying again."))
        } catch let refusal as Refusal {
            switch refusal.code {
            case "msg_too_long":
                throw IntegrationError.api(.slack, "That reply is too long for one Slack message.")
            case "cannot_reply_to_message":
                throw IntegrationError.api(.slack, "Slack doesn't take replies to that message. Reply in Slack instead.")
            default:
                throw Self.error(code: refusal.code, needed: refusal.needed)
            }
        }
    }

    /// Earlier messages of the thread, oldest first, without the message itself, at most `limit` (`conversations.replies`).
    func thread(channel: String, threadTS: String, excluding ts: String, limit: Int, myUserID: String) async throws -> [ThreadMessage] {
        try await thread(channel: channel, threadTS: threadTS, excluding: ts, limit: limit, myUserID: myUserID, names: [:])
    }

    /// The same, with the names of people and channels already known (`Integrations.slackNames`), so only
    /// the others are looked up.
    ///
    /// The earlier messages are the thread's parent and the replies before this one; a parent has none.
    /// A thread longer than `limit` keeps its first message, which says what it's about, and the replies
    /// just before this one. Senders and mentions come by name: from `names`, from the replies themselves,
    /// else looked up with users.info. (Replies after this one are left out: `fullThread` has them all.)
    ///
    /// Needs the history permission for the kind of conversation (channels:history, groups:history,
    /// im:history or mpim:history); without it this throws `.missingPermission` naming the one needed.
    func thread(channel: String, threadTS: String, excluding ts: String, limit: Int, myUserID: String,
                names known: [String: String]) async throws -> [ThreadMessage] {
        guard limit > 0, !channel.isEmpty, Self.isTimestamp(threadTS) else { return [] }
        var fetched: [RawMessage] = []
        var cursor: String?
        for _ in 0..<Self.threadPages {
            var params = [("channel", channel), ("ts", threadTS), ("limit", "200")]
            if let cursor { params.append(("cursor", cursor)) }
            let page: RepliesReply
            do {
                page = try await perform("conversations.replies", params, as: RepliesReply.self).0
            } catch let refusal as Refusal {
                // A later page Slack won't continue: keep what came so far.
                if refusal.code == "invalid_cursor", cursor != nil { break }
                // The message, and with it the thread, was deleted.
                if refusal.code == "thread_not_found" { return [] }
                throw Self.error(code: refusal.code, needed: refusal.needed)
            }
            fetched += (page.messages ?? []).compactMap(\.value)
            // Replies come oldest first: once this message (or a later one) is in, the rest are later.
            let passed = fetched.contains { $0.ts.map { Self.compare($0, ts) >= 0 } ?? false }
            guard !passed, page.hasMore == true, let next = page.responseMetadata?.nextCursor, !next.isEmpty else { break }
            cursor = next
        }

        // What's worth showing: each earlier message once, without joins, deleted ones or empty ones.
        var byTS: [String: RawMessage] = [:]
        for m in fetched {
            guard let mts = m.ts, Self.isTimestamp(mts), Self.compare(mts, ts) < 0, byTS[mts] == nil, m.isShownInThread else { continue }
            byTS[mts] = m
        }
        let chosen = Self.threadWindow(Array(byTS.keys), around: ts, limit: limit).compactMap { byTS[$0] }
        let names = await names(for: chosen, known: known, lookups: 30)

        return chosen.compactMap { m in
            guard let mts = m.ts else { return nil }
            return ThreadMessage(id: "slack:\(channel)/\(mts)", from: Self.sender(of: m, names: names),
                                 date: Date(timeIntervalSince1970: TimeInterval(mts) ?? 0),
                                 text: SlackText.readable(m.displayText, names: names), isMine: m.user == myUserID)
        }
    }

    /// A file's bytes (`url_private_download` with `Authorization: Bearer`; needs files:read).
    ///
    /// The token only ever goes to Slack's own servers: any other address is refused before a request is
    /// made. Without files:read Slack sends its sign-in page instead of the file; that becomes
    /// `.missingPermission(.slack, "files:read")`.
    func download(_ url: URL) async throws -> Data {
        guard Self.isSlackFileURL(url) else {
            throw IntegrationError.api(.slack, "That file isn't stored in Slack, so Docket can't download it.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 60
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await send(request)
        switch response.statusCode {
        case 200..<300:
            break
        case 404, 410:
            throw IntegrationError.api(.slack, "That file isn't in Slack any more.")
        case 401, 403:
            throw IntegrationError.api(.slack, "Slack didn't let Docket open that file. Open it in Slack instead.")
        default:
            throw IntegrationError.unexpected(.slack, "HTTP \(response.statusCode)")
        }
        if Self.isSignInPage(response, for: url) { throw IntegrationError.missingPermission(.slack, "files:read") }
        return data
    }

    // MARK: Pieces (static, so they're easy to test)

    /// Pages of 200 read from one thread at most.
    static let threadPages = 5

    /// Kinds of message a thread never shows: joins and the like, and deleted messages.
    static let silentSubtypes = SlackMessage.ignoredSubtypes.union(["tombstone"])

    /// "1712345678.000100": a message's timestamp, which is also its id in the conversation.
    static func isTimestamp(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 2 && (1...12).contains(parts[0].count) && (1...9).contains(parts[1].count)
            && parts.allSatisfy { $0.allSatisfy { $0 >= "0" && $0 <= "9" } }
    }

    /// Orders two timestamps by time (-1, 0 or 1), exactly: whole numbers, no floating point.
    static func compare(_ a: String, _ b: String) -> Int {
        func key(_ ts: String) -> (Int64, Int64) {
            let parts = ts.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
            let fraction = parts.count > 1 ? String(parts[1].prefix(9)).padding(toLength: 9, withPad: "0", startingAt: 0) : "0"
            return (Int64(parts[0]) ?? 0, Int64(fraction) ?? 0)
        }
        let ka = key(a), kb = key(b)
        return ka == kb ? 0 : (ka < kb ? -1 : 1)
    }

    /// Which of a thread's messages (given by timestamp, in any order) go with the one at `ts`: all the
    /// others, oldest first. A thread longer than `limit` keeps its first message, which says what it's
    /// about, and the ones closest to `ts`, earlier ones first.
    static func threadWindow(_ timestamps: [String], around ts: String, limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        var seen = Set<String>()
        let others = timestamps.filter { compare($0, ts) != 0 && seen.insert($0).inserted }.sorted { compare($0, $1) < 0 }
        guard others.count > limit else { return others }
        var keep: Set<Int> = [0]
        let pivot = others.firstIndex { compare($0, ts) > 0 } ?? others.count
        var before = pivot - 1, after = pivot
        while keep.count < limit, before >= 0 || after < others.count {
            if before >= 0 {
                keep.insert(before)
                before -= 1
            }
            if keep.count < limit, after < others.count {
                keep.insert(after)
                after += 1
            }
        }
        return keep.sorted().map { others[$0] }
    }

    /// Slack's own servers, over https (slack.com, slack-gov.com and their subdomains): the only addresses
    /// a file request carries the token to.
    static func isSlackFileURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        return ["slack.com", "slack-gov.com"].contains { host == $0 || host.hasSuffix("." + $0) }
    }

    static func slackFileURL(_ raw: String) -> URL? {
        URL(string: raw).flatMap { isSlackFileURL($0) ? $0 : nil }
    }

    /// A web page where a file was expected: what Slack sends instead of the file when the token lacks
    /// files:read. (An uploaded .html file is still a file.)
    static func isSignInPage(_ response: HTTPURLResponse, for url: URL) -> Bool {
        let type = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        return type.hasPrefix("text/html") && !["html", "htm"].contains(url.pathExtension.lowercased())
    }

    /// Slack's MIME type for a file, else one from its name's extension.
    static func mimeType(_ given: String?, name: String) -> String {
        if let given = given?.trimmingCharacters(in: .whitespaces).lowercased(), given.contains("/") { return given }
        let ext = (name as NSString).pathExtension
        return (ext.isEmpty ? nil : UTType(filenameExtension: ext)?.preferredMIMEType) ?? "application/octet-stream"
    }

    /// The parent's timestamp when a message is a reply in a thread. Slack says so in thread_ts (a parent
    /// carries its own ts there); search results only have it in the permalink ("…?thread_ts=…").
    static func threadParent(threadTS: String?, permalink: String?, ts: String) -> String? {
        let fromLink = permalink.flatMap(URLComponents.init(string:))?.queryItems?.first { $0.name == "thread_ts" }?.value
        guard let parent = [threadTS, fromLink].compactMap({ $0 }).first(where: isTimestamp), parent != ts else { return nil }
        return parent
    }

    /// Who wrote a message: by name when known, else the name Slack sent along with it.
    fileprivate static func sender(of m: RawMessage, names: [String: String]) -> String {
        if let id = m.user, let name = names[id], !name.isEmpty { return name }
        return [m.userProfile?.name, m.botProfile?.name, m.username]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? "Someone"
    }
}

// MARK: - The whole thread, stars

extension SlackClient {
    /// The whole thread: the parent at `threadTS` and every reply, oldest first (conversations.replies, page by
    /// page, up to 500 messages), each with its own files.
    func fullThread(channel: String, threadTS: String, myUserID: String) async throws -> [ThreadSlackMessage] {
        try await fullThread(channel: channel, threadTS: threadTS, myUserID: myUserID, names: [:], around: nil)
    }

    /// The same, with the names of people and channels already known (`Integrations.slackNames`), so only
    /// the others are looked up, and the inbox message (`around`, its ts), which a long thread keeps.
    ///
    /// Asked for a message that has no replies, Slack sends just that message: a conversation of one.
    /// Asked for a reply rather than its parent, this reads the parent's thread, keeping the reply in it (as
    /// `around`, when that's nil).
    /// The parent always comes first, even deleted. Joins and the like, deleted, hidden and empty replies
    /// are left out (the inbox message never is).
    /// A thread is read 200 messages a page, at most 1,000 (`fullThreadPages`), and shows at most 500
    /// (`fullThreadLimit`): beyond that, its first message, which says what it's about, and the ones
    /// closest to the inbox message, or the newest ones when there's no `around`.
    ///
    /// Each message comes with its files and by name: the sender from `names`, from the message itself,
    /// else looked up with users.info (a few at a time, `fullThreadLookups` at most); the people and
    /// channels it mentions carry their names in its markup (<@U0…|Priya Shah>), so it reads right
    /// whatever names the reader has. Messages by `myUserID` are marked as yours.
    ///
    /// Needs the history permission for the kind of conversation (channels:history, groups:history,
    /// im:history or mpim:history); without it this throws `.missingPermission` naming the one needed.
    /// A thread that was deleted throws `messageGone`.
    func fullThread(channel: String, threadTS: String, myUserID: String, names known: [String: String],
                    around target: String?) async throws -> [ThreadSlackMessage] {
        guard !channel.isEmpty, Self.isTimestamp(threadTS) else { throw IntegrationError.unexpected(.slack, "no thread to read") }
        var byTS = try await wholeThread(channel: channel, threadTS: threadTS)
        // A reply comes back alone, its parent elsewhere: the thread is the parent's.
        if let asked = byTS.first(where: { Self.compare($0.key, threadTS) == 0 })?.value, let parent = asked.threadTs,
           Self.isTimestamp(parent), !byTS.keys.contains(where: { Self.compare($0, parent) == 0 }) {
            byTS = try await wholeThread(channel: channel, threadTS: parent)
        }

        // The parent always leads, as in Slack, even deleted ("This message was deleted.") or empty.
        let first = byTS.keys.min { Self.compare($0, $1) < 0 }
        // Asked by a reply rather than its parent (Slack sends the whole thread, or the reply alone): that reply
        // is the one being looked at, kept like `around`.
        let target = target.flatMap { Self.isTimestamp($0) ? $0 : nil }
            ?? first.flatMap { Self.compare($0, threadTS) == 0 ? nil : threadTS }
        let shown = byTS.filter { ts, m in m.isShownInThread || ts == first || target.map { Self.compare(ts, $0) == 0 } == true }
        let chosen = Self.fullThreadWindow(Array(shown.keys), around: target, limit: Self.fullThreadLimit).compactMap { shown[$0] }
        let names = await names(for: chosen, known: known, lookups: Self.fullThreadLookups)

        return chosen.compactMap { m in
            guard let mts = m.ts else { return nil }
            let markup = SlackText.naming(m.displayText, names: names)
            let userID = m.user.flatMap { $0.isEmpty ? nil : $0 }
            return ThreadSlackMessage(id: mts, from: Self.sender(of: m, names: names), userID: userID,
                                      date: Date(timeIntervalSince1970: TimeInterval(mts) ?? 0), markup: markup,
                                      text: SlackText.readable(markup, names: names), files: m.attachmentList,
                                      isMine: userID != nil && userID == myUserID)
        }
    }

    /// Saves the message for later in Slack, or takes it out again (stars.add / stars.remove with channel and
    /// timestamp; needs stars:write).
    ///
    /// Already saved (or already not) counts as done, and so does taking out a message that's gone.
    ///
    /// When Slack won't save messages for this app, the star stays in Docket only; `isStarRefusal` tells
    /// those errors apart from failures to put the star back for. An app made without stars:write throws
    /// `.missingPermission(.slack, "stars:write")` (updating the app fixes it); the methods retired or not
    /// allowed for this token or workspace throw `starsRefused(starring:)`. Anything else (offline, signed
    /// out, the message deleted) throws as usual.
    func setStarred(_ starred: Bool, channel: String, ts: String) async throws {
        guard !channel.isEmpty, Self.isTimestamp(ts) else { throw IntegrationError.unexpected(.slack, "no message to star") }
        do {
            _ = try await perform(starred ? "stars.add" : "stars.remove", [("channel", channel), ("timestamp", ts)], as: Envelope.self)
        } catch let refusal as Refusal {
            switch refusal.code {
            case "already_starred" where starred, "not_starred" where !starred:
                return
            case "message_not_found", "channel_not_found":
                // Nothing left in Slack to take out.
                if !starred { return }
                throw refusal.code == "message_not_found" ? Self.messageGone : Self.error(code: refusal.code, needed: refusal.needed)
            case "missing_scope":
                let needed = refusal.needed.flatMap { Self.namesStarScopes($0) ? $0 : nil } ?? "stars:write"
                throw IntegrationError.missingPermission(.slack, needed)
            case _ where Self.starRefusals.contains(refusal.code):
                throw Self.starsRefused(starring: starred)
            default:
                throw Self.error(code: refusal.code, needed: refusal.needed)
            }
        }
    }

    /// Every message of the thread at `threadTS` (conversations.replies, 200 a page, `fullThreadPages` pages at
    /// most), each once, by ts.
    private func wholeThread(channel: String, threadTS: String) async throws -> [String: RawMessage] {
        var byTS: [String: RawMessage] = [:]
        var cursor: String?
        for _ in 0..<Self.fullThreadPages {
            var params = [("channel", channel), ("ts", threadTS), ("limit", "200")]
            if let cursor { params.append(("cursor", cursor)) }
            let page: RepliesReply
            do {
                page = try await perform("conversations.replies", params, as: RepliesReply.self).0
            } catch let refusal as Refusal {
                if refusal.code == "invalid_cursor", cursor != nil { break }
                if ["thread_not_found", "message_not_found"].contains(refusal.code) { throw Self.messageGone }
                throw Self.error(code: refusal.code, needed: refusal.needed)
            }
            // Every page starts with the parent again: each message once.
            for m in (page.messages ?? []).compactMap(\.value) {
                guard let mts = m.ts, Self.isTimestamp(mts), byTS[mts] == nil else { continue }
                byTS[mts] = m
            }
            guard page.hasMore != false, let next = page.responseMetadata?.nextCursor, !next.isEmpty, next != cursor else { break }
            cursor = next
        }
        return byTS
    }

    // MARK: Pieces of whole threads and stars

    /// The most messages a whole thread shows: its first and 499 more.
    static let fullThreadLimit = 500
    /// Pages of 200 read from one thread at most (1,000 messages).
    static let fullThreadPages = 5
    /// People looked up by name for one thread at most, its writers first.
    static let fullThreadLookups = 40

    /// The message (or its whole thread) was deleted in Slack.
    static let messageGone = IntegrationError.api(.slack, "That message isn't in Slack any more.")

    /// What `setStarred` throws when Slack won't save messages for later for this app (the methods retired, or
    /// not allowed): the star is kept (or taken off) in Docket only, and the views say so once, quietly.
    static func starsRefused(starring: Bool) -> IntegrationError {
        .api(.slack, starring ? "Saved in Docket only (Slack didn't allow saving it there)"
                              : "Unstarred in Docket only (Slack didn't allow changing it there)")
    }

    /// Whether `error` is Slack not saving messages for later for this app (`starsRefused`, or the app
    /// without stars:write), so the star stays in Docket, rather than a failure to put the star back for.
    static func isStarRefusal(_ error: Error) -> Bool {
        switch error as? IntegrationError {
        case .missingPermission(.slack, let needed)?:
            return namesStarScopes(needed)
        case let e?:
            return e == starsRefused(starring: true) || e == starsRefused(starring: false)
        case nil:
            return false
        }
    }

    /// The permissions for saving messages for later (stars.add, stars.remove, stars.list).
    static let starScopes: Set<String> = ["stars:read", "stars:write"]

    /// Whether Slack's "needed" ("stars:write", or a list) names only the permissions for saving for later.
    static func namesStarScopes(_ needed: String) -> Bool {
        let names = needed.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
        return !names.isEmpty && names.allSatisfy(starScopes.contains)
    }

    /// Slack's answers to stars.add and stars.remove that mean it won't save messages for this app at all,
    /// whatever the app's permissions: the methods retired, or not allowed for this token or workspace.
    static let starRefusals: Set<String> = [
        "method_deprecated", "deprecated_endpoint", "unknown_method", "not_allowed", "not_allowed_token_type",
        "no_permission", "restricted_action", "access_denied", "ekm_access_denied", "team_access_not_granted",
        "enterprise_is_restricted", "feature_not_enabled",
    ]

    /// Which of a thread's messages (by timestamp, in any order) the whole thread shows, oldest first: all of
    /// them, up to `limit`. A longer thread keeps its first message, which says what it's about, and the
    /// ones closest to `ts` (the message being looked at, which stays in), else the newest ones.
    static func fullThreadWindow(_ timestamps: [String], around ts: String?, limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        var seen = Set<String>()
        let all = timestamps.filter { seen.insert($0).inserted }.sorted { compare($0, $1) < 0 }
        guard all.count > limit else { return all }
        if let ts, let at = all.first(where: { compare($0, ts) == 0 }) {
            return (threadWindow(all, around: at, limit: limit - 1) + [at]).sorted { compare($0, $1) < 0 }
        }
        return [all[0]] + all.suffix(limit - 1)
    }

    /// Where the message at `ts` is in a whole thread (by time, exactly), if it's there: the one to highlight.
    static func index(of ts: String, in thread: [ThreadSlackMessage]) -> Int? {
        guard isTimestamp(ts) else { return nil }
        return thread.firstIndex { compare($0.id, ts) == 0 }
    }

    /// Names for the people who wrote these messages or are mentioned in them: from `known`, from the
    /// messages themselves, else looked up with users.info, a few at a time and at most `lookups`, writers
    /// first. Those that can't be looked up are left out.
    private func names(for messages: [RawMessage], known: [String: String], lookups: Int) async -> [String: String] {
        var names = known
        var writers: [String] = []
        var mentioned = Set<String>()
        for m in messages {
            if let id = m.user, !id.isEmpty, names[id] == nil {
                if let name = m.userProfile?.name { names[id] = name } else { writers.append(id) }
            }
            mentioned.formUnion(SlackText.mentionedUserIDs(in: m.displayText))
        }
        var seen = Set<String>()
        let unknown = (writers + mentioned.sorted()).filter { names[$0] == nil && seen.insert($0).inserted }
        let found = await IntegrationHTTP.concurrentMap(Array(unknown.prefix(max(0, lookups))), limit: 6) { id in try? await self.user(id) }
        for person in found.compactMap({ $0 }) where !person.name.isEmpty { names[person.id] = person.name }
        return names
    }
}

// MARK: - Replies (only the fields Docket reads; everything optional, so odd items are skipped, not fatal)

/// Decodes one element, or nil when it doesn't fit, so a single odd item can't break a whole list.
private struct Lenient<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

private struct Envelope: Decodable {
    let ok: Bool
    let error: String?
    let needed: String?
}

private struct Cursor: Decodable {
    let nextCursor: String?
}

private struct AuthTestReply: Decodable {
    let url: String?
    let team: String?
    let user: String?
    let teamId: String?
    let userId: String?
}

private struct ReactionsReply: Decodable {
    struct Item: Decodable {
        let type: String?
        let channel: RawChannel?
        let message: RawMessage?
    }
    let items: [Lenient<Item>]?
    let responseMetadata: Cursor?
}

private struct SearchReply: Decodable {
    struct Messages: Decodable { let matches: [Lenient<RawMessage>]? }
    let messages: Messages?
}

private struct ConversationsReply: Decodable {
    let channels: [Lenient<RawChannel>]?
    let responseMetadata: Cursor?
}

private struct ConversationReply: Decodable {
    let channel: RawChannel?
}

private struct UserReply: Decodable {
    struct User: Decodable {
        struct Profile: Decodable {
            let displayName: String?
            let realName: String?
            let statusText: String?
            let statusEmoji: String?
            let statusExpiration: Int?
        }
        let id: String?
        let name: String?
        let realName: String?
        let profile: Profile?
    }
    let user: User?
}

private struct SnoozeReply: Decodable {
    let snoozeEndtime: Int?
}

/// conversations.replies: the parent first, then its replies, oldest first.
private struct RepliesReply: Decodable {
    let messages: [Lenient<RawMessage>]?
    let hasMore: Bool?
    let responseMetadata: Cursor?
}

/// A channel given either as an id ("C024BE91L", in reactions.list) or as an object (search results, conversations.*).
private struct RawChannel: Decodable {
    var id: String?
    var name: String?
    var isIm: Bool?
    var isMpim: Bool?
    var isPrivate: Bool?
    var isMember: Bool?
    var isArchived: Bool?

    private enum Keys: String, CodingKey { case id, name, isIm, isMpim, isPrivate, isMember, isArchived }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let id = try? single.decode(String.self) {
            self.id = id
            return
        }
        let c = try decoder.container(keyedBy: Keys.self)
        id = try? c.decode(String.self, forKey: .id)
        name = try? c.decode(String.self, forKey: .name)
        isIm = try? c.decode(Bool.self, forKey: .isIm)
        isMpim = try? c.decode(Bool.self, forKey: .isMpim)
        isPrivate = try? c.decode(Bool.self, forKey: .isPrivate)
        isMember = try? c.decode(Bool.self, forKey: .isMember)
        isArchived = try? c.decode(Bool.self, forKey: .isArchived)
    }

    var isDirect: Bool { isIm == true || id?.hasPrefix("D") == true }
    var isGroupDM: Bool { isMpim == true || name?.hasPrefix("mpdm-") == true }

    var channel: SlackChannel? {
        guard let id, !id.isEmpty else { return nil }
        // users.conversations only lists your own channels and may leave is_member out.
        return SlackChannel(id: id, name: name ?? id, isPrivate: isPrivate ?? false, isDirect: isDirect, isGroupDM: isGroupDM,
                            isMember: isMember ?? true, isArchived: isArchived ?? false)
    }
}

private struct RawMessage: Decodable {
    struct Reaction: Decodable {
        let name: String?
        let users: [String]?
        let count: Int?
    }
    struct File: Decodable {
        let id: String?
        let name: String?
        let title: String?
        let mimetype: String?
        let size: Int?
        /// "hosted", "snippet", "external", "tombstone" (deleted), "hidden_by_limit"…
        let mode: String?
        let isExternal: Bool?
        let urlPrivate: String?
        let urlPrivateDownload: String?
        let thumb480: String?
        let thumb360: String?
    }
    /// A card under the message: a shared message, an app's card, or a link preview.
    struct Attachment: Decodable {
        struct Field: Decodable {
            let title: String?
            let value: String?
        }
        let text: String?
        let fallback: String?
        let title: String?
        let titleLink: String?
        let pretext: String?
        let authorName: String?
        let fields: [Lenient<Field>]?
        /// A message shared from elsewhere in Slack.
        let isMsgUnfurl: Bool?
        let isShare: Bool?
        /// Set on link previews.
        let fromUrl: String?
        let originalUrl: String?
    }
    struct BotProfile: Decodable {
        let name: String?
    }
    struct UserProfile: Decodable {
        let realName: String?
        let displayName: String?

        var name: String? {
            [realName, displayName].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        }
    }

    let ts: String?
    let text: String?
    let user: String?
    let username: String?
    let subtype: String?
    let permalink: String?
    let reactions: [Lenient<Reaction>]?
    let files: [Lenient<File>]?
    let attachments: [Lenient<Attachment>]?
    let channel: RawChannel?
    /// The parent's ts for a reply in a thread; a parent with replies carries its own ts.
    let threadTs: String?
    let hidden: Bool?
    let botProfile: BotProfile?
    /// Sent with some messages, so the sender needn't be looked up.
    let userProfile: UserProfile?

    /// Whether `userID` reacted with `emoji` ("+1::skin-tone-2" counts as "+1").
    func hasReaction(_ emoji: String, by userID: String) -> Bool {
        (reactions ?? []).compactMap(\.value).contains { r in
            guard let name = r.name?.components(separatedBy: "::").first?.lowercased(), name == emoji.lowercased() else { return false }
            let users = r.users ?? []
            // Long lists can be cut short; reactions.list only lists messages the user reacted to.
            return users.contains(userID) || users.count < (r.count ?? 0)
        }
    }

    /// The whole message as Slack markup: its own words, then what it shares (someone's message, an app's
    /// card) quoted below them. With no words of its own: what it shares, else a link preview's words, else
    /// the names of its files.
    var displayText: String {
        let cards = (attachments ?? []).compactMap(\.value)
        let shared = cards.compactMap(\.shared)
        let own = text.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        if own != nil || !shared.isEmpty {
            // Someone else's words are always quoted; an app's card only under words of the message's own.
            let parts = (own.map { [$0] } ?? []) + shared.map { own != nil || $0.isMessage ? Self.quoted($0.markup) : $0.markup }
            return parts.joined(separator: "\n")
        }
        for a in cards {
            if let words = [a.text, a.fallback, a.title, a.pretext].compactMap({ $0 }).first(where: { !$0.isEmpty }) { return words }
        }
        let names = (files ?? []).compactMap(\.value).compactMap { f in [f.title, f.name].compactMap { $0 }.first { !$0.isEmpty } }
        switch names.count {
        case 0: return ""
        case 1: return "Shared a file: \(names[0])"
        default: return "Shared \(names.count) files: \(names.joined(separator: ", "))"
        }
    }

    /// Worth showing in a thread: not a join or the like, not deleted or hidden, and not empty.
    var isShownInThread: Bool {
        hidden != true && !SlackClient.silentSubtypes.contains(subtype ?? "")
            && !displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The files Docket can show: deleted, hidden and external ones left out, each once.
    var attachmentList: [MessageAttachment] {
        var seen = Set<String>()
        return (files ?? []).compactMap(\.value).compactMap(\.attachment).filter { seen.insert($0.id).inserted }
    }

    /// Markup quoted line by line, the way Slack sends a quote ("&gt; …").
    static func quoted(_ markup: String) -> String {
        markup.components(separatedBy: "\n").map { "&gt; " + $0 }.joined(separator: "\n")
    }
}

private extension RawMessage.Attachment {
    /// What the card shows, as markup: a shared message ("Sam Lee: …"), or an app's card (pretext, title,
    /// text and fields). Nil for link previews, whose link is in the message already.
    var shared: (markup: String, isMessage: Bool)? {
        func words(_ s: String?) -> String? {
            guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return s
        }
        if isMsgUnfurl == true || isShare == true {
            guard let body = words(text) ?? words(fallback) else { return nil }
            let author = authorName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (author.isEmpty ? body : "\(author): \(body)", true)
        }
        if fromUrl != nil || originalUrl != nil { return nil }
        var lines: [String] = []
        if let pretext = words(pretext) { lines.append(pretext) }
        if let title = words(title) {
            if let link = titleLink.flatMap(URL.init(string:)), ["http", "https"].contains(link.scheme?.lowercased() ?? "") {
                lines.append("<\(link.absoluteString)|\(title)>")
            } else {
                lines.append(title)
            }
        }
        if let text = words(text) { lines.append(text) }
        for field in (fields ?? []).compactMap(\.value) {
            let name = field.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let value = words(field.value) else { continue }
            lines.append(name.isEmpty ? value : "\(name): \(value)")
        }
        return lines.isEmpty ? nil : (lines.joined(separator: "\n"), false)
    }
}

private extension RawMessage.File {
    /// Files without bytes Docket can show: deleted, hidden by the workspace's plan, kept elsewhere (Google
    /// Drive and the like), and Slack's own documents (canvases, posts).
    static let unusableModes: Set<String> = ["tombstone", "hidden_by_limit", "external", "quip", "canvas", "space", "post"]

    /// The file as an attachment, fetched from Slack when opened; nil when there's nothing in Slack to fetch.
    var attachment: MessageAttachment? {
        guard let id, !id.isEmpty, isExternal != true, !Self.unusableModes.contains(mode ?? ""),
              let url = [urlPrivateDownload, urlPrivate].lazy.compactMap({ $0.flatMap(SlackClient.slackFileURL) }).first
        else { return nil }
        let shownName = [name, title].lazy.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? "File"
        let thumbnail = [thumb480, thumb360].lazy.compactMap { $0.flatMap(SlackClient.slackFileURL) }.first
        return MessageAttachment(id: id, name: shownName, mimeType: SlackClient.mimeType(mimetype, name: shownName),
                                 size: size.flatMap { $0 >= 0 ? $0 : nil }, remote: .slack(url: url, thumbnail: thumbnail))
    }
}

private extension SlackMessage {
    init?(_ raw: RawMessage, channel: String, info: RawChannel?) {
        // "1712345678.000100": seconds since 1970.
        guard let ts = raw.ts, let seconds = TimeInterval(ts), seconds.isFinite, seconds > 0, seconds < 1e11, !channel.isEmpty else { return nil }
        self.init(channelID: channel, channelName: info.flatMap { $0.isDirect || $0.isGroupDM ? nil : $0.name },
                  isDirect: info?.isDirect ?? channel.hasPrefix("D"), isGroupDM: info?.isGroupDM ?? false,
                  ts: ts, userID: raw.user, userName: raw.username, text: raw.displayText,
                  permalink: raw.permalink.flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil },
                  files: raw.attachmentList,
                  threadTS: SlackClient.threadParent(threadTS: raw.threadTs, permalink: raw.permalink, ts: ts))
    }
}

// MARK: - Text

/// Slack's markup as plain text.
enum SlackText {
    private static let token = try! NSRegularExpression(pattern: #"<([^<>\n]+)>"#)
    private static let userMention = try! NSRegularExpression(pattern: #"<@([UW][A-Z0-9]+)(?:\|[^>]*)?>"#)

    /// "<@U1|sam> see <#C1|general> &amp; <https://x.co|the doc>" → "@Sam see #general & the doc".
    /// `users` and `channels` map ids to names for markup that only carries an id.
    static func plain(_ text: String, users: [String: String] = [:], channels: [String: String] = [:]) -> String {
        let ns = text as NSString
        var out = ""
        var last = 0
        for m in token.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += replacement(for: ns.substring(with: m.range(at: 1)), users: users, channels: channels)
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return unescape(out)
    }

    private static func replacement(for inner: String, users: [String: String], channels: [String: String]) -> String {
        let parts = inner.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let target = parts[0]
        let label = parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil
        if target.hasPrefix("@") {
            let id = String(target.dropFirst())
            return "@" + (users[id] ?? label ?? "someone")
        }
        if target.hasPrefix("#") {
            let id = String(target.dropFirst())
            return "#" + (label ?? channels[id] ?? "channel")
        }
        if target.hasPrefix("!") {
            if target.hasPrefix("!subteam^") { return label ?? "@team" }
            if target.hasPrefix("!date^") { return label ?? "" }
            return label ?? "@" + target.dropFirst()
        }
        if let label { return label }
        return target.hasPrefix("mailto:") ? String(target.dropFirst("mailto:".count)) : target
    }

    /// Slack escapes only these three.
    static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&amp;", with: "&")
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Ids of the people a message @mentions.
    static func mentionedUserIDs(in text: String) -> Set<String> {
        let ns = text as NSString
        return Set(userMention.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) })
    }

    private static let reference = try! NSRegularExpression(pattern: #"<([@#])([A-Z0-9]+)(?:\|([^<>\n]*))?>"#)

    /// Markup whose people and channels carry their names ("<@U0SAM>" → "<@U0SAM|Sam Lee>"), so it reads
    /// the same with or without `names` at hand. Like the readers: a person goes by their name now, a
    /// channel by the name it was written with (it only gains one when it has none). Unknown ids stay as
    /// they are.
    static func naming(_ markup: String, names: [String: String]) -> String {
        let ns = markup as NSString
        var out = ""
        var last = 0
        for m in reference.matches(in: markup, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            last = m.range.location + m.range.length
            let kind = ns.substring(with: m.range(at: 1)), id = ns.substring(with: m.range(at: 2))
            let label = m.range(at: 3).location == NSNotFound ? "" : ns.substring(with: m.range(at: 3))
            let name = names[id].map { escape(collapsed($0)) } ?? ""
            if !name.isEmpty, kind == "@" || label.isEmpty {
                out += "<\(kind)\(id)|\(name)>"
            } else {
                out += ns.substring(with: m.range)
            }
        }
        return out + ns.substring(from: last)
    }

    /// Runs of whitespace (newlines too) as single spaces.
    static func collapsed(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    /// The first non-empty line, cut at a word boundary to at most `limit` characters ("…" when cut).
    static func firstLine(_ text: String, limit: Int = 70) -> String {
        let line = text.split(whereSeparator: \.isNewline).map { collapsed(String($0)) }.first { !$0.isEmpty } ?? ""
        guard line.count > limit else { return line }
        var cut = String(line.prefix(limit))
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > limit / 2 {
            cut = String(cut[..<space])
        }
        // Only the end: "(Draft) Board deck, budget…" keeps its opening bracket.
        while let last = cut.unicodeScalars.last, CharacterSet.whitespaces.union(.punctuationCharacters).contains(last) {
            cut.unicodeScalars.removeLast()
        }
        return cut + "…"
    }
}

extension SlackText {
    /// Slack mrkdwn as rich text: *bold*, _italic_, ~strike~, `code`, code blocks, links (<url|text>), and
    /// people and channels (<@U…>, <#C…|name>) by name. `names` maps Slack ids (people "U…", channels "C…")
    /// to names; see `Integrations.slackNames`.
    ///
    /// Made for SwiftUI's Text: emphasis and code are inline presentation intents, links are link
    /// attributes (http, https and mailto only), quoted lines start with a bar, and emoji names become
    /// emoji. See `SlackMarkup` for the rules.
    static func attributed(_ markup: String, names: [String: String]) -> AttributedString {
        SlackMarkup.attributed(SlackMarkup.runs(markup, names: names))
    }

    /// The same message as plain words, for AI and previews: formatting marks dropped, links by their
    /// labels, people and channels by name, emoji as emoji, quoted lines starting with "> ".
    static func readable(_ markup: String, names: [String: String] = [:]) -> String {
        SlackMarkup.readable(SlackMarkup.runs(markup, names: names))
    }

    /// What the person wrote, ready to post: &, < and > escaped as Slack asks, except that links and mentions
    /// already written Slack's way (<https://…|label>, <mailto:…>, <@U…>, <#C…>) stay links and mentions
    /// (an "&" in them escaped, as Slack does). Special mentions like <!channel> are escaped too, so a reply
    /// never pings a whole channel by accident.
    ///
    /// Escaping twice changes nothing: &amp; &lt; and &gt; are left as they are, so text a caller has
    /// already escaped goes out as it was.
    static func outgoing(_ text: String) -> String {
        let ns = text as NSString
        var out = ""
        var last = 0
        for m in keptToken.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += escapeOnce(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
            out += escapeOnce(ns.substring(with: m.range), ampersandsOnly: true)
            last = m.range.location + m.range.length
        }
        return out + escapeOnce(ns.substring(from: last))
    }

    private static let keptToken = try! NSRegularExpression(
        pattern: #"<(?:@[UW][A-Z0-9]+|#[CG][A-Z0-9]+|(?:https?://|mailto:)[^\s<>|]+)(?:\|[^<>\n]*)?>"#,
        options: [.caseInsensitive])

    /// Like `escape`, but an "&" that already starts &amp; &lt; or &gt; stays as it is.
    private static func escapeOnce(_ s: String, ampersandsOnly: Bool = false) -> String {
        var out = ""
        var rest = Substring(s)
        while let ch = rest.first {
            switch ch {
            case "&" where !(rest.hasPrefix("&amp;") || rest.hasPrefix("&lt;") || rest.hasPrefix("&gt;")):
                out += "&amp;"
            case "<" where !ampersandsOnly:
                out += "&lt;"
            case ">" where !ampersandsOnly:
                out += "&gt;"
            default:
                out.append(ch)
            }
            rest = rest.dropFirst()
        }
        return out
    }
}

// MARK: - The Docket app in Slack

/// The Slack app people create for themselves from a manifest: user scopes only, no bot.
enum SlackManifest {
    static let userScopes = [
        "reactions:read", "search:read", "users:read", "users.profile:write", "dnd:write",
        "chat:write", "channels:read", "groups:read", "im:read", "mpim:read",
        // The complete message: its files, and the rest of its thread (see `contentScopes`).
        "files:read", "channels:history", "groups:history", "im:history", "mpim:history",
        // Starring a message saves it for later in Slack too.
        "stars:read", "stars:write",
    ]

    /// What the complete message needs: attachments (files:read), the rest of a thread (the history scopes)
    /// and saving it for later (the stars scopes). Apps made from an older manifest lack them;
    /// `Integrations.missingSlackScopes` says which.
    static let contentScopes: Set<String> = ["files:read", "channels:history", "groups:history", "im:history", "mpim:history",
                                             "stars:read", "stars:write"]

    static let description = "Turns Slack messages into tasks, shows files and threads, saves messages for later, posts your replies and plans, and sets focus status."

    static var manifest: [String: Any] {
        [
            "display_information": [
                "name": "Docket",
                "description": description,
                "background_color": "#0e0e0c",
            ],
            "oauth_config": ["scopes": ["user": userScopes]],
            "settings": [
                "org_deploy_enabled": false,
                "socket_mode_enabled": false,
                "token_rotation_enabled": false,
            ],
        ]
    }

    static var json: String {
        let data = (try? JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Opens Slack's "Create an app" with the manifest filled in.
    static var createAppURL: URL {
        URL(string: "https://api.slack.com/apps?new_app=1&manifest_json=" + IntegrationHTTP.escape(json))!
    }
}

// MARK: - Sharing a plan

/// Tasks as a Slack message: "*Plan for Mon 5 Oct*" then "• Title — 10:00 AM · 30m" lines.
enum SlackShare {
    static let maxTasks = 50

    static func message(for tasks: [TaskItem], now: Date = Date(), calendar: Calendar = .current) -> String {
        let today = calendar.startOfDay(for: now)
        // The day a task is planned for; a missed day counts as today.
        func day(_ t: TaskItem) -> Date? { t.agendaDay(calendar: calendar).map { max($0, today) } }
        func time(_ t: TaskItem) -> Date? {
            guard t.dueHasTime, let due = t.dueDate, let d = day(t), calendar.isDate(due, inSameDayAs: d) else { return nil }
            return due
        }

        let ordered = tasks.sorted { a, b in
            let da = day(a) ?? .distantFuture, db = day(b) ?? .distantFuture
            if da != db { return da < db }
            let ta = time(a) ?? .distantFuture, tb = time(b) ?? .distantFuture
            if ta != tb { return ta < tb }
            if a.priority != b.priority { return a.priority > b.priority }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
        let days = Set(ordered.compactMap(day)).sorted()
        let header: String
        if let first = days.first, let last = days.last {
            header = first == last ? "*Plan for \(Fmt.absoluteDay(first, now: now))*"
                : "*Plan for \(Fmt.absoluteDay(first, now: now)) – \(Fmt.absoluteDay(last, now: now))*"
        } else {
            header = "*Plan*"
        }

        var lines = [header]
        for t in ordered.prefix(maxTasks) {
            var parts: [String] = []
            if days.count > 1, let d = day(t) { parts.append(Fmt.absoluteDay(d, now: now)) }
            if let at = time(t) { parts.append(Fmt.time(at)) }
            if let minutes = t.estimateMinutes, minutes > 0, !t.isCompleted { parts.append(Fmt.duration(minutes: minutes)) }
            if let who = t.waitingOn?.trimmingCharacters(in: .whitespacesAndNewlines), !who.isEmpty { parts.append("waiting on \(SlackText.escape(who))") }
            if !t.isCompleted, let due = t.dueDate, calendar.startOfDay(for: due) < today { parts.append("was due \(Fmt.absoluteDay(due, now: now))") }
            let title = SlackText.escape(SlackText.collapsed(t.title))
            var line = "• " + (t.isCompleted ? "~\(title)~" : title)
            if !parts.isEmpty { line += " — " + parts.joined(separator: " · ") }
            if t.isCompleted { line += " ✓" }
            lines.append(line)
        }
        if ordered.count > maxTasks { lines.append("…and \(ordered.count - maxTasks) more") }
        return lines.joined(separator: "\n")
    }
}
