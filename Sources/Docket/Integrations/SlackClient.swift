import Foundation

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
        let request = IntegrationHTTP.formPost(Self.api.appendingPathComponent(method), params, bearer: token)
        var waits = 0
        while true {
            let (data, response) = try await IntegrationHTTP.send(request, via: transport, service: .slack)
            if response.statusCode == 429 {
                let after = IntegrationHTTP.retryAfter(response) ?? Self.longestWait
                if waits < 2, after <= Self.longestWait {
                    waits += 1
                    try await sleep(after)
                    continue
                }
                throw IntegrationError.rateLimited(.slack, retryAfter: after)
            }
            guard (200..<300).contains(response.statusCode) else {
                throw IntegrationError.unexpected(.slack, "HTTP \(response.statusCode)")
            }
            guard let envelope = try? Self.decoder.decode(Envelope.self, from: data) else {
                throw IntegrationError.unexpected(.slack, "an unreadable reply")
            }
            guard envelope.ok else {
                throw Self.error(code: envelope.error ?? "unknown_error", needed: envelope.needed)
            }
            do {
                return (try Self.decoder.decode(Reply.self, from: data), response)
            } catch {
                throw IntegrationError.unexpected(.slack, "an unreadable reply to \(method)")
            }
        }
    }

    /// Slack's error codes in plain words.
    static func error(code: String, needed: String?) -> IntegrationError {
        switch code {
        case "invalid_auth", "not_authed", "token_revoked", "token_expired", "account_inactive", "user_removed_from_team":
            return .signedOut(.slack)
        case "missing_scope":
            return .missingPermission(.slack, needed ?? "a")
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
            let (reply, _) = try await call("reactions.list", params, as: ReactionsReply.self)
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
            let (reply, _) = try await call("users.conversations", params, as: ConversationsReply.self)
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
        let name: String?
        let title: String?
    }
    struct Attachment: Decodable {
        let text: String?
        let fallback: String?
        let title: String?
        let pretext: String?
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

    /// Whether `userID` reacted with `emoji` ("+1::skin-tone-2" counts as "+1").
    func hasReaction(_ emoji: String, by userID: String) -> Bool {
        (reactions ?? []).compactMap(\.value).contains { r in
            guard let name = r.name?.components(separatedBy: "::").first?.lowercased(), name == emoji.lowercased() else { return false }
            let users = r.users ?? []
            // Long lists can be cut short; reactions.list only lists messages the user reacted to.
            return users.contains(userID) || users.count < (r.count ?? 0)
        }
    }

    /// The words to show: the text, else an attachment's, else the name of a shared file.
    var displayText: String {
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        for a in (attachments ?? []).compactMap(\.value) {
            if let words = [a.text, a.fallback, a.title, a.pretext].compactMap({ $0 }).first(where: { !$0.isEmpty }) { return words }
        }
        if let file = (files ?? []).compactMap(\.value).first, let name = file.title ?? file.name, !name.isEmpty {
            return "Shared a file: \(name)"
        }
        return ""
    }
}

private extension SlackMessage {
    init?(_ raw: RawMessage, channel: String, info: RawChannel?) {
        // "1712345678.000100": seconds since 1970.
        guard let ts = raw.ts, let seconds = TimeInterval(ts), seconds.isFinite, seconds > 0, seconds < 1e11, !channel.isEmpty else { return nil }
        self.init(channelID: channel, channelName: info.flatMap { $0.isDirect || $0.isGroupDM ? nil : $0.name },
                  isDirect: info?.isDirect ?? channel.hasPrefix("D"), isGroupDM: info?.isGroupDM ?? false,
                  ts: ts, userID: raw.user, userName: raw.username, text: raw.displayText,
                  permalink: raw.permalink.flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil })
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

// MARK: - The Docket app in Slack

/// The Slack app people create for themselves from a manifest: user scopes only, no bot.
enum SlackManifest {
    static let userScopes = [
        "reactions:read", "search:read", "users:read", "users.profile:write", "dnd:write",
        "chat:write", "channels:read", "groups:read", "im:read", "mpim:read",
    ]

    static let description = "Turns Slack messages you save into tasks in Docket, shares your plan, and sets your status while you focus."

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
