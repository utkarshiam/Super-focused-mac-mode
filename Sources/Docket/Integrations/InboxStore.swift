import Foundation
import UniformTypeIdentifiers

// MARK: - The Slack and Email tabs

/// What the inbox shows and does with a message: each tab's items, the complete message and its whole thread,
/// stars, attachments, the user's notes, and replies (to it or to any message of its thread).
///
/// Nothing here blocks the UI, and nothing goes out by itself: a reply is sent (or saved as a Gmail draft)
/// only by `sendReply` / `saveReplyAsDraft`, which the views call after the user confirmed it. Problems come
/// back as `IntegrationError`s in plain words; a Slack or Google sign-out disconnects, as a refresh would.
extension Integrations {
    /// At most this many earlier messages of a thread or an email conversation are shown.
    static let threadLimit = 20
    /// AI reads at most this much of a message's text.
    static let replyContextLimit = 20_000

    /// One tab's items (Slack or Gmail): the starred ones first, each part newest first. With `starredOnly`,
    /// just the starred ones (the tab's Starred filter).
    func items(_ kind: TaskSource.Kind, starredOnly: Bool = false) -> [Suggestion] {
        suggestions.filter { $0.source.kind == kind && (!starredOnly || $0.isStarred) }
            .sorted { ($0.isStarred ? 1 : 0, $0.receivedAt, $0.id) > ($1.isStarred ? 1 : 0, $1.receivedAt, $1.id) }
    }

    /// The item with this id, if it's still in the inbox.
    func suggestion(_ id: String) -> Suggestion? {
        suggestions.first { $0.id == id }
    }

    // MARK: The complete message

    /// The complete message. A Slack message comes with it; an email is fetched (format=full) the first time
    /// it's opened, then saved with its item, along with what a reply to it needs. A Slack message saved
    /// before Docket kept whole messages shows the text kept then, until the next check fills it in.
    func content(for id: String) async throws -> MessageContent {
        guard let s = suggestion(id) else { throw Self.gone(id) }
        if let content = s.content { return content }
        switch s.source.kind {
        case .gmail:
            return try await email(id).content
        case .slack, .ai:
            return MessageContent(text: s.snippet, fetchedAt: s.receivedAt)
        }
    }

    /// The whole email, fetched once (asking again while it loads waits for the same answer) and kept with
    /// its item.
    private func email(_ id: String) async throws -> GmailFullMessage {
        try await once(id, in: \.inbox.emailLoads) { [self] in
            guard let ids = InboxIDs.gmail(id) else { throw IntegrationError.unexpected(.gmail, "a bad message id") }
            do {
                let full = try await mailInbox().fullMessage(ids.message)
                if let i = index(of: id) {
                    suggestions[i].content = full.content
                    suggestions[i].replyHeaders = full.replyHeaders
                    save()
                }
                return full
            } catch {
                throw inboxFailure(error, .gmail)
            }
        }
    }

    // MARK: Earlier messages

    /// The earlier messages of its Slack thread or email conversation, oldest first. Not saved: kept in
    /// memory until Docket quits. A Slack message outside a thread has none. When the Docket app in Slack
    /// can't read message history, the answer is empty rather than an error, and `missingSlackScopes` says
    /// which permissions to add.
    func thread(for id: String) async throws -> [ThreadMessage] {
        if let known = inbox.threads[id] { return known }
        guard let s = suggestion(id) else { return [] }
        return try await once(id, in: \.inbox.threadLoads) { [self] in
            let (messages, lasting) = try await earlierMessages(s)
            // Not when a permission was missing: once the app is updated, it's asked again.
            if lasting, suggestion(id) != nil { inbox.threads[id] = messages }
            return messages
        }
    }

    /// The thread's earlier messages, and whether the answer can be kept.
    private func earlierMessages(_ s: Suggestion) async throws -> (messages: [ThreadMessage], lasting: Bool) {
        switch s.source.kind {
        case .slack:
            // Only a reply in a thread has earlier messages there. An item saved before Docket kept whole
            // messages doesn't know yet whether it's one (the next check fills that in), so that answer isn't kept.
            guard let ids = InboxIDs.slack(s.id), let parent = s.threadTS, parent != ids.ts else { return ([], s.content != nil) }
            guard let account = slackAccount else { throw IntegrationError.notConnected(.slack) }
            // The app can't read any history: no need to have Slack say so again.
            if let granted = grantedSlackScopes, granted.isDisjoint(with: InboxScopes.slackHistory) { return ([], false) }
            do {
                let slack = try slackInbox()
                // With the names already known, so only new people are looked up.
                let messages = try await slack.thread(channel: ids.channel, threadTS: parent, excluding: ids.ts,
                                                      limit: Self.threadLimit, myUserID: account.userID, names: slackNames)
                return (await named(messages, slack: slack), true)
            } catch {
                let e = inboxFailure(error, .slack)
                if case .missingPermission = e { return ([], false) }
                throw e
            }
        case .gmail:
            guard let ids = InboxIDs.gmail(s.id) else { return ([], true) }
            guard let address = gmailAddress else { throw IntegrationError.notConnected(.gmail) }
            do {
                let messages = try await mailInbox().conversation(threadID: ids.thread, excluding: ids.message,
                                                                  limit: Self.threadLimit, myAddress: address)
                return (messages, true)
            } catch {
                throw inboxFailure(error, .gmail)
            }
        case .ai:
            return ([], true)
        }
    }

    /// Thread messages by name: an author given as a Slack user id ("U0…") is looked up, a few at a time,
    /// and remembered like the people a refresh meets.
    private func named(_ messages: [ThreadMessage], slack: any SlackInbox) async -> [ThreadMessage] {
        let unknown = Set(messages.map(\.from).filter { InboxText.isSlackUserID($0) && slackNames[$0] == nil })
        if !unknown.isEmpty {
            let found = await IntegrationHTTP.concurrentMap(Array(unknown.prefix(20)), limit: 4) { id in try? await slack.user(id) }
            rememberSlackUsers(found.compactMap { $0 })
        }
        let names = slackNames
        return messages.map { message in
            guard let name = names[message.from] else { return message }
            var named = message
            named.from = name
            return named
        }
    }

    // MARK: The whole thread

    /// The whole Slack thread or email conversation the item belongs to, oldest first, with the item's own
    /// message as `highlighted`. Loaded when the item opens and kept for the session (`wholeThreads`, which
    /// also shows replies sent from Docket and stars as they change); `reload` fetches it again. Asking again
    /// while it loads waits for the same answer.
    ///
    /// A Slack message outside a thread is a conversation of one. So is any Slack message while the Docket
    /// app in Slack can't read message history: that answer isn't an error and isn't kept, and
    /// `missingSlackScopes` says which permissions to add. Anything else that goes wrong throws, in plain words.
    func fullThread(for id: String, reload: Bool) async throws -> InboxThread {
        // Screenshot mode never fetches: its samples come with their threads.
        if let known = wholeThreads[id], !reload || DebugSnapshot.isActive { return known }
        guard let s = suggestion(id) else { throw Self.gone(id) }
        return try await once(id, in: \.inbox.wholeThreadLoads) { [self] in
            let (fetched, lasting) = try await wholeThread(s)
            guard lasting, suggestion(id) != nil else { return withDocketStars(fetched.thread, for: suggestion(id) ?? s) }
            if fetched.hasOwn { fillIn(from: fetched.thread, for: id) }
            return keep(fetched.thread, for: id)
        }
    }

    /// The whole thread as Slack or Gmail has it (`hasOwn`: with the item's own message in it), and whether
    /// the answer can be kept (not when a permission was missing: once the app is updated, it's asked again).
    private func wholeThread(_ s: Suggestion) async throws -> (fetched: (thread: InboxThread, hasOwn: Bool), lasting: Bool) {
        switch s.source.kind {
        case .slack, .ai:
            let own = ownSlackMessage(s)
            let one = (thread: InboxThread.slack([own], highlighted: 0), hasOwn: false)
            guard s.source.kind == .slack, let ids = InboxIDs.slack(s.id) else { return (one, true) }
            guard isSlackConnected, let account = slackAccount else { throw IntegrationError.notConnected(.slack) }
            // The app can't read any history: no need to have Slack say so again.
            if let granted = grantedSlackScopes, granted.isDisjoint(with: InboxScopes.slackHistory) { return (one, false) }
            do {
                let slack = try slackInbox()
                // Asked by the parent when it's known; by its own ts otherwise, which Slack answers with the
                // whole thread it's in (or just the message). Around the item's own message, which a very long
                // thread keeps, and with the names already known, so only new people are looked up.
                let messages = try await slack.fullThread(channel: ids.channel, threadTS: s.threadTS ?? ids.ts, myUserID: account.userID,
                                                          names: slackNames, around: ids.ts)
                return (Self.slackThread(await named(messages, slack: slack), own: own), true)
            } catch {
                let e = inboxFailure(error, .slack)
                if case .missingPermission = e { return (one, false) }
                throw e
            }
        case .gmail:
            let own = ownEmail(s)
            guard let ids = InboxIDs.gmail(s.id) else { return ((.email([own], highlighted: 0), false), true) }
            guard isGmailConnected, let address = gmailAddress else { throw IntegrationError.notConnected(.gmail) }
            do {
                let messages = try await mailInbox().conversationMessages(threadID: ids.thread, myAddress: address)
                return (Self.emailThread(messages, own: own), true)
            } catch {
                throw inboxFailure(error, .gmail)
            }
        }
    }

    /// A Slack thread with the item's own message highlighted: where the thread has it, else put in its
    /// place by time (a very long thread can leave it out).
    static func slackThread(_ messages: [ThreadSlackMessage], own: ThreadSlackMessage) -> (thread: InboxThread, hasOwn: Bool) {
        if let i = messages.firstIndex(where: { InboxThread.sameSlackMessage($0.id, own.id) }) { return (.slack(messages, highlighted: i), true) }
        var list = messages
        let at = list.firstIndex { $0.date > own.date } ?? list.count
        list.insert(own, at: at)
        return (.slack(list, highlighted: at), false)
    }

    /// An email conversation with the item's own message highlighted: where the conversation has it, else
    /// (deleted since, or in Trash) the copy Docket kept, put in its place by time.
    static func emailThread(_ messages: [ThreadEmail], own: ThreadEmail) -> (thread: InboxThread, hasOwn: Bool) {
        if let i = messages.firstIndex(where: { $0.id == own.id }) { return (.email(messages, highlighted: i), true) }
        var list = messages
        let at = list.firstIndex { $0.date > own.date } ?? list.count
        list.insert(own, at: at)
        return (.email(list, highlighted: at), false)
    }

    /// The item's own Slack message, from what Docket kept of it: a conversation of one, or its place in a
    /// thread that left it out.
    private func ownSlackMessage(_ s: Suggestion) -> ThreadSlackMessage {
        let text = s.content.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? s.snippet : $0.text } ?? s.snippet
        return ThreadSlackMessage(id: InboxIDs.slack(s.id)?.ts ?? s.id, from: s.from, userID: nil, date: s.receivedAt,
                                  markup: s.content?.markup ?? SlackText.outgoing(text), text: text,
                                  files: s.content?.attachments ?? [], isMine: isFromMe(s))
    }

    /// The item's own email, from what Docket kept of it. Its sender as a From header when that's known, like
    /// the conversation's other emails ("Sam Lee <sam@northwind.example>").
    private func ownEmail(_ s: Suggestion) -> ThreadEmail {
        ThreadEmail(id: InboxIDs.gmail(s.id)?.message ?? s.id, from: s.replyHeaders?.from ?? s.from, date: s.receivedAt,
                    content: s.content ?? MessageContent(text: s.snippet, fetchedAt: s.receivedAt),
                    replyHeaders: s.replyHeaders ?? MailReplyHeaders(subject: s.subject ?? "", from: s.from),
                    isMine: isFromMe(s), isStarred: s.isStarred, snippet: s.snippet)
    }

    /// What the thread tells about the item that Docket didn't know yet: an email's whole message and what a
    /// reply needs (so opening it fetches nothing more); for a Slack item saved before Docket kept whole
    /// messages, its whole text and files, and the thread it's a reply in.
    private func fillIn(from thread: InboxThread, for id: String) {
        guard let i = index(of: id) else { return }
        var changed = false
        switch thread {
        case .email(let messages, let h):
            guard messages.indices.contains(h) else { return }
            if suggestions[i].content == nil {
                suggestions[i].content = messages[h].content
                changed = true
            }
            if suggestions[i].replyHeaders == nil {
                suggestions[i].replyHeaders = messages[h].replyHeaders
                changed = true
            }
        case .slack(let messages, let h):
            guard messages.indices.contains(h) else { return }
            if suggestions[i].threadTS == nil, h > 0, let parent = messages.first?.id, SlackClient.isTimestamp(parent) {
                suggestions[i].threadTS = parent
                changed = true
            }
            if suggestions[i].content == nil {
                let own = messages[h]
                suggestions[i].content = MessageContent(text: own.text, markup: own.markup, attachments: own.files, fetchedAt: Date())
                changed = true
            }
        }
        if changed { save() }
    }

    /// Keeps a fetched thread for the session, as Docket shows it: with the replies sent from Docket that
    /// Slack or Gmail doesn't list yet, and Docket's stars.
    private func keep(_ fetched: InboxThread, for id: String) -> InboxThread {
        guard let s = suggestion(id) else { return fetched }
        let thread = withDocketStars(withSentReplies(fetched, for: id), for: s)
        wholeThreads[id] = thread
        return thread
    }

    /// Thread messages by name: authors Slack gave by id are looked up (a few at a time), and every name the
    /// thread came with is remembered like the people a refresh meets, so mentions read right everywhere.
    private func named(_ messages: [ThreadSlackMessage], slack: any SlackInbox) async -> [ThreadSlackMessage] {
        var learned: [SlackUser] = []
        var seen = Set<String>()
        let known = slackNames
        for m in messages {
            guard let id = m.userID, InboxText.isSlackUserID(id), known[id] == nil, seen.insert(id).inserted else { continue }
            let name = m.from.trimmingCharacters(in: .whitespacesAndNewlines)
            if !Self.isNameless(name) { learned.append(SlackUser(id: id, name: name, status: SlackStatus())) }
        }
        rememberSlackUsers(learned)
        let knownNow = slackNames
        let unknown = Set(messages.compactMap { m -> String? in
            guard Self.isNameless(m.from) else { return nil }
            let id = m.userID ?? m.from
            return InboxText.isSlackUserID(id) && knownNow[id] == nil ? id : nil
        })
        if !unknown.isEmpty {
            let found = await IntegrationHTTP.concurrentMap(Array(unknown.sorted().prefix(20)), limit: 4) { id in try? await slack.user(id) }
            rememberSlackUsers(found.compactMap { $0 })
        }
        let names = slackNames
        return messages.map { m in
            let id: String = m.userID ?? m.from
            guard Self.isNameless(m.from), let name = names[id] else { return m }
            var named = m
            named.from = name
            return named
        }
    }

    /// No name to show: blank, Slack's "Someone", or a user id ("U0…").
    private static func isNameless(_ name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name == "Someone" || InboxText.isSlackUserID(name)
    }

    // MARK: Stars

    /// Stars or unstars the item: at once in Docket (saved, and first in its tab), then in Gmail (the STARRED
    /// label) or Slack (saved for later). Returns once Gmail or Slack has answered:
    /// - When that fails, the star goes back and `starProblem(for:)` says why, for a moment.
    /// - When Slack doesn't allow saving messages for later (or the Gmail sign-in is from before Docket asked
    ///   to star), the star stays in Docket only, and Docket says so once, quietly.
    ///
    /// `id` may also name a message of a thread that's loaded ("slack:<channel>/<ts>", "gmail:<thread>/<id>",
    /// or its bare id): that message's star, as `setStarred(_:message:in:)`.
    func setStarred(_ starred: Bool, for id: String) async {
        if suggestion(id) != nil {
            await setStarred(starred, StarTarget(item: id, message: nil))
        } else if let target = loadedMessage(id) {
            await setStarred(starred, target)
        }
    }

    /// Stars or unstars one message of the item's thread or conversation (a `ThreadSlackMessage` or
    /// `ThreadEmail` id), as `setStarred(_:for:)` does: an email in Gmail; a Slack message saved for later in
    /// Slack when Slack allows it, and kept in Docket either way. The item's own message is the item's star,
    /// and so is a message that's an inbox item itself.
    func setStarred(_ starred: Bool, message messageID: String, in id: String) async {
        await setStarred(starred, starTarget(messageID, in: id))
    }

    /// Whether a message of the item's thread is starred (`message` nil: the item itself), as Docket shows it.
    func isStarred(message messageID: String?, in id: String) -> Bool {
        isStarred(starTarget(messageID, in: id))
    }

    /// Why the last star on the item, or on a message of its thread, didn't take: shown inline for a moment,
    /// or until the next try.
    func starProblem(for id: String, message messageID: String? = nil) -> String? {
        starProblems[starTarget(messageID, in: id).key]
    }

    /// What a star is on, by the item's id and a message id in its thread (none: the item).
    private func starTarget(_ messageID: String?, in id: String) -> StarTarget {
        guard let raw = messageID?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return StarTarget(item: id, message: nil)
        }
        let message = InboxThread.bareMessageID(raw)
        guard message != InboxThread.bareMessageID(id) else { return StarTarget(item: id, message: nil) }
        // A message that's in the inbox itself: its own star.
        if let other = InboxThread.itemID(of: message, inThreadOf: id), suggestion(other) != nil {
            return StarTarget(item: other, message: nil)
        }
        return StarTarget(item: id, message: message)
    }

    /// The thread message `raw` names, among the threads loaded: "slack:<channel>/<ts>",
    /// "gmail:<thread>/<message>", or its bare id when only one loaded thread has it.
    private func loadedMessage(_ raw: String) -> StarTarget? {
        let message = InboxThread.bareMessageID(raw)
        let found = wholeThreads.compactMap { item, thread -> StarTarget? in
            guard suggestion(item) != nil, thread.allMessageIDs.contains(message) else { return nil }
            if raw != message, InboxThread.itemID(of: message, inThreadOf: item) != raw { return nil }
            return starTarget(message, in: item)
        }
        let targets = Set(found)
        return targets.count == 1 ? targets.first : nil
    }

    /// The star as Docket shows it.
    private func isStarred(_ t: StarTarget) -> Bool {
        guard let s = suggestion(t.item) else { return false }
        guard let message = t.message else { return s.isStarred }
        if let wanted = inbox.starWanted[t.key] { return wanted }
        switch s.source.kind {
        case .gmail:
            // Starred in Docket only (Gmail couldn't), else as Gmail has it.
            if s.starredInThread.contains(message) { return true }
            guard case .email(let messages, _)? = wholeThreads[t.item] else { return false }
            return messages.first { $0.id == message }?.isStarred ?? false
        case .slack, .ai:
            // Docket's record: on this item, or another item of the same conversation.
            let channel = InboxIDs.slack(t.item)?.channel
            return suggestions.contains { $0.source.kind == s.source.kind && InboxIDs.slack($0.id)?.channel == channel && $0.starredInThread.contains(message) }
        }
    }

    private func setStarred(_ starred: Bool, _ t: StarTarget) async {
        guard suggestion(t.item) != nil else { return }
        clearStarProblem(t.key)
        let running = inbox.starSyncs[t.key]
        let before = isStarred(t)
        guard before != starred || running != nil else { return }
        show(starred, t)
        if let running {
            // A change is on its way to Gmail or Slack already: this one goes right after it.
            await running.value
            return
        }
        let sync = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.syncStar(t, from: before)
        }
        inbox.starSyncs[t.key] = sync
        await sync.value
    }

    /// Shows the star at once: on the item (saved), in Docket's record of a Slack thread (saved), and in the
    /// conversations loaded.
    private func show(_ starred: Bool, _ t: StarTarget) {
        guard let i = index(of: t.item) else { return }
        let kind = suggestions[i].source.kind
        guard let message = t.message else {
            suggestions[i].isStarred = starred
            save()
            if kind == .gmail, let ids = InboxIDs.gmail(t.item) { showEmailStar(starred, message: ids.message, thread: ids.thread) }
            return
        }
        switch kind {
        case .gmail:
            inbox.starWanted[t.key] = starred
            if let ids = InboxIDs.gmail(t.item) { showEmailStar(starred, message: message, thread: ids.thread) }
        case .slack, .ai:
            if starred {
                suggestions[i].starredInThread.insert(message)
            } else {
                let channel = InboxIDs.slack(t.item)?.channel
                for j in suggestions.indices where InboxIDs.slack(suggestions[j].id)?.channel == channel {
                    suggestions[j].starredInThread.remove(message)
                }
            }
            save()
        }
    }

    /// An email's star in every conversation loaded that has it.
    private func showEmailStar(_ starred: Bool, message: String, thread: String) {
        for (item, conversation) in wholeThreads {
            guard InboxIDs.gmail(item)?.thread == thread, case .email(var messages, let h) = conversation,
                  let j = messages.firstIndex(where: { $0.id == message }), messages[j].isStarred != starred else { continue }
            messages[j].isStarred = starred
            wholeThreads[item] = .email(messages, highlighted: h)
        }
    }

    /// A fetched conversation with Docket's stars: the item's own message (and any other inbox item) with its
    /// star, stars on their way to Gmail as they'll be, and ones Gmail couldn't take.
    private func withDocketStars(_ thread: InboxThread, for s: Suggestion) -> InboxThread {
        guard case .email(var messages, let h) = thread else { return thread }
        for j in messages.indices {
            let t = j == h ? StarTarget(item: s.id, message: nil) : starTarget(messages[j].id, in: s.id)
            guard t.message == nil || inbox.starWanted[t.key] != nil || s.starredInThread.contains(messages[j].id) else { continue }
            messages[j].isStarred = isStarred(t)
        }
        return .email(messages, highlighted: h)
    }

    /// Takes the star to Gmail or Slack, and again for any change made while it went. When that fails, the
    /// star goes back to what they have, and `starProblems` says why.
    private func syncStar(_ t: StarTarget, from before: Bool) async {
        defer {
            inbox.starSyncs[t.key] = nil
            inbox.starWanted[t.key] = nil
        }
        // What Gmail or Slack has, as far as Docket knows.
        var remote = before
        while let s = suggestion(t.item) {
            let want = isStarred(t)
            guard want != remote else { return }
            let route = starRoute(t, s, starring: want)
            do {
                switch route {
                case .docket(let note):
                    keepInDocket(t)
                    if let note { sayOnce(note) }
                    return
                case .slack(let channel, let ts):
                    try await slackInbox().setStarred(want, channel: channel, ts: ts)
                case .gmail(let message):
                    try await mailInbox().setStarred(want, messageID: message)
                    // Gmail has it now: its label is the star.
                    if let m = t.message, let i = index(of: t.item), suggestions[i].starredInThread.remove(m) != nil { save() }
                }
                remote = want
            } catch {
                let service: IntegrationError.Service = s.source.kind == .gmail ? .gmail : .slack
                let e = inboxFailure(error, service)
                if case .slack = route, InboxStarRules.slackDeclined(e) {
                    // For good, not just this time: stars stay in Docket until Slack is connected again.
                    slackStarsStayInDocket = true
                    save()
                    sayOnce(InboxStarRules.docketOnly(.slack, starring: want))
                    return
                }
                if case .gmail = route, case .missingPermission(.gmail, _) = e {
                    // A sign-in without gmail.modify: the views ask to reconnect Gmail.
                    grantedGmailScopes?.remove(GoogleOAuth.modifyScope)
                    keepInDocket(t)
                    save()
                    sayOnce(InboxStarRules.docketOnly(.gmail, starring: want))
                    return
                }
                // Didn't take: back to what Gmail or Slack has.
                if suggestion(t.item) != nil, isStarred(t) != remote { show(remote, t) }
                if e != .cancelled { reportStarProblem(InboxStarRules.problem(e, starring: want, service: service), for: t.key) }
                return
            }
        }
    }

    /// Where a star goes besides Docket.
    private enum StarRoute {
        /// Nowhere: it stays in Docket (saying `note` once, when there is one).
        case docket(note: String?)
        case slack(channel: String, ts: String)
        case gmail(messageID: String)
    }

    /// `starring`: the change is a star put on (else taken off), for the note said when it stays in Docket.
    private func starRoute(_ t: StarTarget, _ s: Suggestion, starring: Bool) -> StarRoute {
        // Screenshot mode never reaches Slack or Gmail.
        guard !DebugSnapshot.isActive else { return .docket(note: nil) }
        switch s.source.kind {
        case .slack:
            guard isSlackConnected, let ids = InboxIDs.slack(s.id) else { return .docket(note: nil) }
            let ts = t.message ?? ids.ts
            // A reply sent from Docket a moment ago has no ts yet.
            guard SlackClient.isTimestamp(ts), !slackStarsStayInDocket else { return .docket(note: nil) }
            if let granted = grantedSlackScopes, !granted.contains(InboxStarRules.slackWrite) {
                // An app made before Docket saved messages for later: Slack would say no.
                slackStarsStayInDocket = true
                save()
                return .docket(note: InboxStarRules.docketOnly(.slack, starring: starring))
            }
            return .slack(channel: ids.channel, ts: ts)
        case .gmail:
            guard isGmailConnected, let ids = InboxIDs.gmail(s.id) else { return .docket(note: nil) }
            let message = t.message ?? ids.message
            guard GmailClient.isGmailID(message) else { return .docket(note: nil) }
            guard gmailCanModify else { return .docket(note: InboxStarRules.docketOnly(.gmail, starring: starring)) }
            return .gmail(messageID: message)
        case .ai:
            return .docket(note: nil)
        }
    }

    /// The star stays in Docket only: an email of the conversation goes into Docket's record (items and Slack
    /// messages have theirs already).
    private func keepInDocket(_ t: StarTarget) {
        guard let message = t.message, let i = index(of: t.item), suggestions[i].source.kind == .gmail else { return }
        if isStarred(t) {
            suggestions[i].starredInThread.insert(message)
        } else {
            suggestions[i].starredInThread.remove(message)
        }
        save()
    }

    /// Says `note` once while Docket runs.
    private func sayOnce(_ note: String) {
        guard inbox.notesSaid.insert(note).inserted else { return }
        app?.showToast(note)
    }

    private func reportStarProblem(_ problem: String, for key: String) {
        starProblems[key] = problem
        inbox.starProblemClears[key]?.cancel()
        inbox.starProblemClears[key] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(InboxStarRules.problemShownFor * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.starProblems[key] = nil
            self.inbox.starProblemClears[key] = nil
        }
    }

    private func clearStarProblem(_ key: String) {
        inbox.starProblemClears[key]?.cancel()
        inbox.starProblemClears[key] = nil
        if starProblems[key] != nil { starProblems[key] = nil }
    }

    // MARK: Attachments

    /// A local copy of the attachment, for Quick Look: downloaded once, then kept in IntegrationCache/ (see
    /// `InboxCache`). Files over 100 MB aren't downloaded, and neither are Slack files the app has no
    /// permission for (`missingSlackScopes` has files:read): the views offer to open those in Slack.
    func file(for attachment: MessageAttachment, messageID id: String) async throws -> URL {
        let key = InboxCache.key(messageID: id, attachmentID: attachment.id)
        // Screenshot mode: the sample's local file, whichever message of its thread it's asked for with.
        if let local = inbox.localFiles[key] ?? inbox.sampleFiles[attachment.id] { return local }
        let service = Self.service(of: attachment)
        guard let root = cacheDirectory else { throw IntegrationError.unexpected(service, "no data folder") }
        let url = InboxCache.location(for: attachment, key: key, in: root)
        if InboxCache.isCached(url) { return url }
        return try await once(key, in: \.inbox.fileLoads) { [self] in
            try await download(attachment, service: service, to: url)
            pruneInboxCache(keeping: [key])
            return url
        }
    }

    private func download(_ attachment: MessageAttachment, service: IntegrationError.Service, to url: URL) async throws {
        if let size = attachment.size, size > InboxCache.largestFile { throw InboxCache.tooBig(size, service) }
        let data: Data
        do {
            switch attachment.remote {
            case .slack(let remote, _):
                // The token only ever goes to Slack.
                guard InboxCache.isSlackFile(remote) else {
                    throw IntegrationError.api(.slack, "That file isn't stored in Slack, so Docket can't download it.")
                }
                if missingSlackScopes.contains(InboxScopes.slackFiles) {
                    throw IntegrationError.missingPermission(.slack, InboxScopes.slackFiles)
                }
                data = try await slackInbox().download(remote)
            case .gmail(let messageID, let attachmentID):
                data = try await mailInbox().attachment(messageID: messageID, attachmentID: attachmentID)
            }
        } catch {
            throw inboxFailure(error, service)
        }
        guard data.count <= InboxCache.largestFile else { throw InboxCache.tooBig(data.count, service) }
        do {
            try await InboxCache.write(data, to: url)
        } catch {
            throw IntegrationError.api(service, "Docket couldn't keep a copy of the file. \(error.localizedDescription)")
        }
    }

    /// The cache keys of these items' attachments, and of the files in their whole threads loaded this
    /// session (kept under the item's id too).
    func inboxCacheKeys(_ items: [Suggestion]) -> Set<String> {
        Set(items.flatMap { s in
            ((s.content?.attachments ?? []) + (wholeThreads[s.id]?.attachments ?? [])).map { InboxCache.key(messageID: s.id, attachmentID: $0.id) }
        })
    }

    /// Tidies IntegrationCache/ in the background (see `InboxCache.prune`): at launch and after each download.
    @discardableResult
    func pruneInboxCache(keeping keep: Set<String> = [], now: Date = Date()) -> Task<[String], Never>? {
        guard let root = cacheDirectory else { return nil }
        let live = inboxCacheKeys(suggestions)
        return Task.detached(priority: .utility) { InboxCache.prune(root, live: live, keep: keep, now: now) }
    }

    /// Forgets what Docket kept of these items besides the items themselves: their threads, and the files
    /// of their attachments (disconnecting a service).
    func forgetInbox(_ items: [Suggestion]) {
        // Before their threads go: the files of those are kept under the items' ids too.
        let keys = inboxCacheKeys(items)
        for s in items {
            inbox.threads[s.id] = nil
            inbox.sentReplies[s.id] = nil
            inbox.rechecks.removeValue(forKey: s.id)?.cancel()
            wholeThreads[s.id] = nil
        }
        let ids = Set(items.map(\.id))
        if starProblems.keys.contains(where: { ids.contains(StarTarget.item(ofKey: $0)) }) {
            starProblems = starProblems.filter { !ids.contains(StarTarget.item(ofKey: $0.key)) }
        }
        guard let root = cacheDirectory else { return }
        if !keys.isEmpty { InboxCache.remove(keys, in: root) }
    }

    // MARK: Notes and replies

    /// The user's notes on the message, saved as they type (written once typing pauses). They go into the
    /// task's notes when the message becomes a task (`SuggestionDrafts.withNote`).
    func setNote(_ text: String, for id: String) {
        guard let i = index(of: id), suggestions[i].note != text else { return }
        suggestions[i].note = text
        save(soon: true)
    }

    /// The reply being written, saved as they type (written once typing pauses).
    func setReplyDraft(_ text: String, for id: String) {
        guard let i = index(of: id), suggestions[i].replyDraft != text else { return }
        suggestions[i].replyDraft = text
        save(soon: true)
    }

    /// A reply written by AI in the user's voice: what to say comes from their notes and `instruction`, the
    /// context from the complete message and its whole thread. It becomes the item's reply draft. Without the
    /// whole message or the thread (offline, a missing permission), it's written from what Docket has.
    func draftReply(for id: String, tone: ReplyTone, instruction: String?) async throws -> String {
        try await draftReply(for: id, tone: tone, instruction: instruction, replyingTo: nil)
    }

    /// The same, answering one message of the thread (a `ThreadSlackMessage` or `ThreadEmail` id): AI is told
    /// which. Nil answers the message a reply goes to by default (`defaultReplyTarget(for:)`).
    func draftReply(for id: String, tone: ReplyTone, instruction: String?, replyingTo messageID: String?) async throws -> String {
        guard suggestion(id) != nil else { throw Self.gone(id) }
        // The thread first: an email's whole message comes with its conversation.
        let whole = try? await fullThread(for: id, reload: false)
        let content = try? await content(for: id)
        // Without the whole thread, the earlier messages may still be there to read.
        let earlier = whole == nil ? ((try? await thread(for: id)) ?? []) : []
        // Read after the waits, so notes typed meanwhile count.
        guard let s = suggestion(id) else { throw Self.gone(id) }
        let context: (thread: [ThreadMessage], target: ThreadMessage?) =
            whole.map { replyContext($0, for: s, replyingTo: messageID) } ?? (earlier, nil)
        let ask = instruction?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let request = ReplyRequest(message: incoming(s, content: content), content: content, thread: context.thread,
                                   notes: s.note.trimmingCharacters(in: .whitespacesAndNewlines), tone: tone,
                                   instruction: ask.isEmpty ? nil : ask, myName: replyName(for: s.source.kind),
                                   replyingTo: context.target)
        let reply = try await replyWriter.write(request).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty else { throw AIError.badResponse("AI didn't write a reply. Try again.") }
        // Stopped (or the message closed) while AI wrote: what the user had stays their reply.
        try Task.checkCancellation()
        setReplyDraft(reply, for: id)
        return reply
    }

    /// The message as AI reads it: the sender with their address (for an email) and the whole text. The
    /// user's own message (a sent email they starred, a Slack message of theirs they saved) is marked
    /// "(you)", as their messages in the thread are, so the reply follows it up instead of answering them.
    private func incoming(_ s: Suggestion, content: MessageContent?) -> IncomingMessage {
        let whole = content?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let text = whole.isEmpty ? s.snippet : whole
        let from = s.replyHeaders?.from ?? s.from
        return IncomingMessage(source: s.source, from: isFromMe(s) ? "\(from) (you)" : from, subject: s.subject,
                               text: String(text.prefix(Self.replyContextLimit)), date: s.receivedAt)
    }

    /// Whether the user wrote the message: an email from the connected address, a Slack message under
    /// their own name in Slack. Unknown counts as no.
    private func isFromMe(_ s: Suggestion) -> Bool {
        switch s.source.kind {
        case .gmail:
            guard let me = gmailAddress?.lowercased(), let from = s.replyHeaders?.from else { return false }
            return MailSender(header: from).address?.lowercased() == me
        case .slack:
            guard let me = slackAccount.flatMap({ slackNames[$0.userID] }), !me.isEmpty else { return false }
            return s.from == me
        case .ai:
            return false
        }
    }

    /// Who's replying, to sign an email and to tell their own messages apart: their name in Slack, or the
    /// Mac account's full name.
    private func replyName(for kind: TaskSource.Kind) -> String? {
        let name = fullName().trimmingCharacters(in: .whitespacesAndNewlines)
        if kind == .slack, let me = slackAccount {
            return slackNames[me.userID] ?? (name.isEmpty ? me.userName : name)
        }
        return name.isEmpty ? nil : name
    }

    /// The thread as AI reads it: every message but the item's own (AI gets that one whole), and the message
    /// being answered when it isn't the item's own: the one picked, else the default (`defaultReplyTarget`).
    private func replyContext(_ thread: InboxThread, for s: Suggestion, replyingTo messageID: String?) -> (thread: [ThreadMessage], target: ThreadMessage?) {
        let all = thread.forReplyContext
        let own = thread.ownMessageID
        let wanted = messageID.map(InboxThread.bareMessageID) ?? thread.defaultReplyMessageID
        let target = wanted.flatMap { w in w == own ? nil : all.first { $0.id == w } }
        return (all.filter { $0.id != own }, target)
    }

    /// Sends the reply as the user: in the Slack message's thread, or as an email in its conversation (to
    /// the sender, or with `replyAll` to everyone on it but the user). Only ever called once the user
    /// confirmed it. Afterwards the item shows "Replied", its draft is cleared, and the reply shows in the
    /// thread at once (then as Slack or Gmail has it, after a moment). Calling again while it goes out waits
    /// for that send instead of sending twice.
    ///
    /// `replyingTo` is the message in the thread being answered (a `ThreadSlackMessage` or `ThreadEmail` id).
    /// Slack: the reply goes in the same thread whichever it is (thread_ts is the thread's parent). Email:
    /// it answers that email (its Message-ID and References, its sender; Reply all uses its recipients).
    /// Nil answers the default one (`defaultReplyTarget(for:)`): Slack, the thread; email, the newest message
    /// in the conversation that isn't yours. Pass the one the confirmation showed.
    func sendReply(_ text: String, for id: String, replyingTo messageID: String?, replyAll: Bool) async throws {
        try await deliver(text, for: id, replyingTo: messageID, replyAll: replyAll, asDraft: false)
    }

    /// Saves the reply as a draft in the email's Gmail conversation, to finish there. The text stays here too.
    /// `replyingTo` as for `sendReply`.
    func saveReplyAsDraft(_ text: String, for id: String, replyingTo messageID: String?, replyAll: Bool) async throws {
        try await deliver(text, for: id, replyingTo: messageID, replyAll: replyAll, asDraft: true)
    }

    /// `sendReply(_:for:replyingTo:replyAll:)`, answering the default message.
    func sendReply(_ text: String, for id: String, replyAll: Bool) async throws {
        try await sendReply(text, for: id, replyingTo: nil, replyAll: replyAll)
    }

    /// `saveReplyAsDraft(_:for:replyingTo:replyAll:)`, answering the default message.
    func saveReplyAsDraft(_ text: String, for id: String, replyAll: Bool) async throws {
        try await saveReplyAsDraft(text, for: id, replyingTo: nil, replyAll: replyAll)
    }

    private func deliver(_ text: String, for id: String, replyingTo messageID: String?, replyAll: Bool, asDraft: Bool) async throws {
        guard let s = suggestion(id) else { throw Self.gone(id) }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw IntegrationError.api(Self.service(of: s.source.kind), "Write a reply first.") }
        try await once((asDraft ? "draft " : "send ") + id, in: \.inbox.sends) { [self] in
            switch s.source.kind {
            case .slack:
                guard !asDraft else { throw IntegrationError.api(.slack, "Slack has no drafts. Copy the reply instead.") }
                guard let ids = InboxIDs.slack(id) else { throw IntegrationError.unexpected(.slack, "a bad message id") }
                do {
                    // In the thread, whichever of its messages it answers: under the message, or starting a
                    // thread there. (The client escapes it for Slack.)
                    try await slackInbox().reply(channel: ids.channel, threadTS: slackThreadParent(of: s), text: body)
                } catch {
                    throw inboxFailure(error, .slack)
                }
                markReplied(id)
                showSent(.slack(sentSlackMessage(body)), in: id)
                app?.showToast(InboxText.repliedToast(for: s))
            case .gmail:
                let reply = try await mailReply(body, to: id, replyingTo: messageID, replyAll: replyAll)
                do {
                    let gmail = try mailInbox()
                    if asDraft { try await gmail.saveDraft(reply) } else { try await gmail.sendReply(reply) }
                } catch {
                    throw composeFailure(error)
                }
                if asDraft {
                    app?.showToast("Saved as a draft in Gmail")
                } else {
                    markReplied(id)
                    showSent(.email(sentEmail(reply)), in: id)
                    app?.showToast("Reply sent")
                }
            case .ai:
                throw IntegrationError.api(.slack, "There's nowhere to send this reply.")
            }
        }
    }

    /// The ts of the Slack thread the item is in (its parent), which every reply to it or to another of its
    /// messages goes under: known from the message, else from its thread as loaded; for a message outside a
    /// thread, its own (the reply starts one).
    private func slackThreadParent(of s: Suggestion) -> String {
        let own = InboxIDs.slack(s.id)?.ts ?? ""
        if let parent = s.threadTS, SlackClient.isTimestamp(parent) { return parent }
        if case .slack(let messages, _)? = wholeThreads[s.id], let first = messages.first?.id, SlackClient.isTimestamp(first) {
            return first
        }
        return own
    }

    /// The reply email: the headers of the email it answers and the account it goes out from.
    private func mailReply(_ body: String, to id: String, replyingTo messageID: String?, replyAll: Bool) async throws -> MailReply {
        guard isGmailConnected, let address = gmailAddress else { throw IntegrationError.notConnected(.gmail) }
        guard gmailCanCompose else { throw Self.cantCompose }
        guard let ids = InboxIDs.gmail(id) else { throw IntegrationError.unexpected(.gmail, "a bad message id") }
        let headers = try await replyHeadersToSend(for: id, message: ids.message, replyingTo: messageID)
        return MailReply(threadID: ids.thread, headers: headers, fromAddress: address, body: body, replyAll: replyAll)
    }

    /// The headers of the email a reply answers: the one picked in the conversation (loaded if it isn't yet),
    /// else the default one (`defaultReplyTarget`), else the item's own (fetched once if it was never opened).
    private func replyHeadersToSend(for id: String, message own: String, replyingTo messageID: String?) async throws -> MailReplyHeaders {
        // A reply sent from here a moment ago has no headers of its own yet; it went to the people the
        // default reply goes to.
        let picked = messageID.map(InboxThread.bareMessageID).flatMap { InboxThread.isSentFromDocket($0) ? nil : $0 }
        if let picked, picked != own {
            guard case .email(let messages, _) = try await fullThread(for: id, reload: false),
                  let email = messages.first(where: { $0.id == picked }) else {
                throw IntegrationError.api(.gmail, "That email isn't in the conversation any more. Reply to another one.")
            }
            return email.replyHeaders
        }
        if picked == nil, let target = defaultReplyEmail(for: id), target.id != own { return target.replyHeaders }
        if let known = suggestion(id)?.replyHeaders { return known }
        return try await email(id).replyHeaders
    }

    /// Which message of the thread a reply answers when none is picked: for Slack the item's own (the reply
    /// goes in its thread), for email the newest in the conversation that isn't yours (the newest when all
    /// are). Nil until the thread is loaded. The views show who that is and pass it on to `sendReply`.
    func defaultReplyTarget(for id: String) -> String? {
        wholeThreads[id]?.defaultReplyMessageID
    }

    /// The headers an email reply answering `messageID` (nil: the default one) goes out with, as `sendReply`
    /// picks them, for the confirmation's recipients: that email's from the conversation as loaded, or the
    /// item's own. Nil for Slack, for an email that isn't in the conversation as loaded, and until the item's
    /// own headers are known (it's been opened).
    func replyHeaders(for id: String, replyingTo messageID: String?) -> MailReplyHeaders? {
        guard let s = suggestion(id), s.source.kind == .gmail else { return nil }
        let picked = messageID.map(InboxThread.bareMessageID).flatMap { InboxThread.isSentFromDocket($0) ? nil : $0 }
        guard let wanted = picked ?? defaultReplyTarget(for: id), wanted != InboxIDs.gmail(id)?.message else { return s.replyHeaders }
        guard case .email(let messages, _)? = wholeThreads[id] else { return nil }
        return messages.first { $0.id == wanted }?.replyHeaders
    }

    /// The email a reply answers by default, from the conversation as loaded.
    private func defaultReplyEmail(for id: String) -> ThreadEmail? {
        guard case .email(let messages, _)? = wholeThreads[id], let target = defaultReplyTarget(for: id) else { return nil }
        return messages.first { $0.id == target }
    }

    // MARK: Replies in the thread

    /// Shows a reply that just went out in its thread (when the thread is loaded) until Slack or Gmail lists
    /// it, then fetches the thread again a moment later to show it as they have it.
    private func showSent(_ message: SentFromDocket.Message, in id: String) {
        guard let thread = wholeThreads[id] else { return }
        let reply = SentFromDocket(message: message, before: Set(thread.allMessageIDs))
        inbox.sentReplies[id, default: []].append(reply)
        wholeThreads[id] = thread.appendingSent([reply])
        inbox.rechecks[id]?.cancel()
        let wait = sleep
        inbox.rechecks[id] = Task { @MainActor [weak self] in
            try? await wait(Self.sentReplyRecheck)
            guard !Task.isCancelled else { return }
            _ = try? await self?.fullThread(for: id, reload: true)
        }
    }

    /// The thread as fetched, with the replies sent from Docket that it doesn't list yet at the end
    /// (`SentFromDocket.unlisted`). Ones it never lists are let go after a while.
    private func withSentReplies(_ thread: InboxThread, for id: String, now: Date = Date()) -> InboxThread {
        guard let sent = inbox.sentReplies[id], !sent.isEmpty else { return thread }
        let waiting = SentFromDocket.unlisted(sent.filter { now.timeIntervalSince($0.date) < Self.sentReplyWait }, in: thread)
        inbox.sentReplies[id] = waiting.isEmpty ? nil : waiting
        return thread.appendingSent(waiting)
    }

    /// Waits for the fetches that follow sent replies (tests).
    func waitForThreadRechecks() async {
        for recheck in Array(inbox.rechecks.values) { await recheck.value }
    }

    /// A Slack reply as it went out, for its thread until Slack lists it.
    private func sentSlackMessage(_ body: String, at now: Date = Date()) -> ThreadSlackMessage {
        ThreadSlackMessage(id: InboxThread.newSentFromDocketID(), from: replyName(for: .slack) ?? "You", userID: slackAccount?.userID,
                           date: now, markup: SlackText.outgoing(body), text: body, files: [], isMine: true)
    }

    /// An email reply as it went out, for its conversation until Gmail lists it.
    private func sentEmail(_ reply: MailReply, at now: Date = Date()) -> ThreadEmail {
        let recipients = MailReplyBuilder.recipients(for: reply)
        let to = recipients.to.map(\.headerForm), cc = recipients.cc.map(\.headerForm)
        let name = replyName(for: .gmail)
        let headers = MailReplyHeaders(messageID: nil, references: reply.headers.messageID,
                                       subject: MailReplyBuilder.subject(replyingTo: reply.headers.subject),
                                       from: MailSender(name: name, address: reply.fromAddress).headerForm, to: to, cc: cc)
        return ThreadEmail(id: InboxThread.newSentFromDocketID(), from: name ?? reply.fromAddress, date: now,
                           content: MessageContent(text: reply.body, to: to, cc: cc, fetchedAt: now), replyHeaders: headers,
                           isMine: true, isStarred: false, snippet: SlackText.firstLine(reply.body, limit: 200))
    }

    /// How long after a reply went out the thread is fetched again, to show it as Slack or Gmail has it.
    static let sentReplyRecheck: TimeInterval = 1.5
    /// A reply Slack or Gmail still doesn't list after this long is let go: the thread as fetched is right.
    static let sentReplyWait: TimeInterval = 10 * 60

    private func markReplied(_ id: String, at now: Date = Date()) {
        guard let i = index(of: id) else { return }
        suggestions[i].repliedAt = now
        suggestions[i].replyDraft = ""
        save()
    }

    /// Google turned a send down for lack of permission (gmail.compose, or gmail.modify which covers it): Docket
    /// stops offering to send (the views ask to reconnect Gmail) and says so in those words.
    private func composeFailure(_ error: Error) -> IntegrationError {
        let e = inboxFailure(error, .gmail)
        guard case .missingPermission(.gmail, _) = e else { return e }
        grantedGmailScopes?.subtract([GoogleOAuth.composeScope, GoogleOAuth.modifyScope])
        save()
        return Self.cantCompose
    }

    static let cantCompose = IntegrationError.missingPermission(.gmail, "send replies and save drafts")

    // MARK: Permissions

    /// Permissions from `SlackManifest.contentScopes` the Docket app in Slack doesn't have: files:read for
    /// attachments, the history scopes for threads. Empty when they're all there, or while that isn't known.
    var missingSlackScopes: Set<String> {
        guard isSlackConnected else { return [] }
        var missing = refusedSlackScopes
        if let granted = grantedSlackScopes { missing.formUnion(SlackManifest.contentScopes.subtracting(granted)) }
        return missing.intersection(SlackManifest.contentScopes)
    }

    /// Whether the Gmail sign-in allows sending replies and saving drafts: gmail.compose, or gmail.modify,
    /// which covers it (what Docket asks for now). Sign-ins from before Docket replied don't: the views ask to
    /// reconnect Gmail.
    var gmailCanCompose: Bool {
        guard isGmailConnected, let granted = grantedGmailScopes else { return false }
        return granted.contains(GoogleOAuth.composeScope) || granted.contains(GoogleOAuth.modifyScope)
    }

    /// Whether the Gmail sign-in allows starring (the gmail.modify scope, which also covers reading, drafts and
    /// sending). Sign-ins from before Docket asked for it don't: stars stay in Docket, and the views ask to
    /// reconnect Gmail.
    var gmailCanModify: Bool {
        isGmailConnected && grantedGmailScopes?.contains(GoogleOAuth.modifyScope) == true
    }

    /// Whether a Google sign-in that granted `scopes` can read mail (gmail.readonly, or gmail.modify, which
    /// covers it). Google doesn't always list them; then what Docket asked for counts.
    static func canReadMail(granted scopes: Set<String>) -> Bool {
        scopes.isEmpty || scopes.contains(GoogleOAuth.gmailScope) || scopes.contains(GoogleOAuth.modifyScope)
    }

    /// Slack turned a request down for want of these permissions ("channels:history", or a list).
    func noteRefusedSlackScopes(_ scopes: String) {
        let names = Set(scopes.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init))
        let content = names.intersection(SlackManifest.contentScopes)
        guard !content.isEmpty, !content.isSubset(of: refusedSlackScopes) else { return }
        refusedSlackScopes.formUnion(content)
    }

    // MARK: Plumbing

    /// An error from Slack or Gmail in plain words, after doing what it calls for: a sign-out disconnects (as
    /// a refresh would), and a permission Slack refused shows up in `missingSlackScopes`.
    func inboxFailure(_ error: Error, _ service: IntegrationError.Service) -> IntegrationError {
        let e = IntegrationError.wrap(error, service)
        switch e {
        case .signedOut(.slack):
            if isSlackConnected { disconnectSlack(problem: e.errorDescription) }
        case .signedOut:
            if isGmailConnected { disconnectGmail(problem: e.errorDescription) }
        case .missingPermission(.slack, let scopes):
            noteRefusedSlackScopes(scopes)
        default:
            break
        }
        return e
    }

    /// Slack, as the inbox reaches it: the stand-in from `inboxClients` (tests), else the client for the
    /// token in the keychain.
    func slackInbox() throws -> any SlackInbox {
        guard isSlackConnected else { throw IntegrationError.notConnected(.slack) }
        if let stand = inboxClients.slack { return stand }
        guard let token = slackToken() else {
            throw IntegrationError.api(.slack, "Docket couldn't read the Slack token from your keychain. Try again, or connect Slack again in Settings → Connections.")
        }
        return SlackClient(token: token, transport: transport, sleep: sleep)
    }

    /// Gmail, as the inbox reaches it: the stand-in from `inboxClients` (tests), else the signed-in client.
    func mailInbox() throws -> any MailInbox {
        guard isGmailConnected else { throw IntegrationError.notConnected(.gmail) }
        if let stand = inboxClients.gmail { return stand }
        guard let session = googleSession() else {
            throw IntegrationError.api(.gmail, "Docket couldn't read the Gmail sign-in from your keychain. Try again, or connect Gmail again in Settings → Connections.")
        }
        return GmailClient(session: session, transport: transport)
    }

    /// Runs `work` once per key at a time: asking again while it runs waits for the same answer, so a view
    /// that appears twice, or a second click, never fetches or sends twice.
    private func once<T: Sendable>(_ key: String, in running: ReferenceWritableKeyPath<Integrations, [String: Task<T, Error>]>,
                                   _ work: @escaping @MainActor () async throws -> T) async throws -> T {
        if let task = self[keyPath: running][key] { return try await task.value }
        let task = Task { @MainActor in try await work() }
        self[keyPath: running][key] = task
        defer { self[keyPath: running][key] = nil }
        return try await task.value
    }

    private func index(of id: String) -> Int? {
        suggestions.firstIndex { $0.id == id }
    }

    private static func gone(_ id: String) -> IntegrationError {
        .api(id.hasPrefix("gmail:") ? .gmail : .slack, "This message isn't in Docket's inbox any more.")
    }

    private static func service(of kind: TaskSource.Kind) -> IntegrationError.Service {
        kind == .gmail ? .gmail : .slack
    }

    private static func service(of attachment: MessageAttachment) -> IntegrationError.Service {
        if case .gmail = attachment.remote { return .gmail }
        return .slack
    }

    // MARK: Screenshot mode

    /// Screenshot mode only: sample Slack and email items with content, whole threads (a 6-message Slack thread
    /// with files in 2 messages, a 4-message email conversation with one email from you, one with attachments
    /// and one starred), notes, a reply draft, stars, and attachments backed by the given local files (no
    /// network, nothing saved). It never replaces real data: outside screenshot mode it does nothing once saved
    /// state was loaded.
    func debugSeed(imageFile: URL?, documentFile: URL?, now: Date) {
        guard DebugSnapshot.isActive || !hasSavedState else { return }
        let samples = InboxSamples(imageFile: imageFile, documentFile: documentFile, now: now)
        showSampleAccounts(slack: InboxSamples.account, gmail: InboxSamples.address, refreshedAt: now.addingTimeInterval(-4 * 60))
        savedSlackNames = InboxSamples.names
        inbox = InboxMemory()
        inbox.threads = samples.threads
        inbox.localFiles = samples.files
        inbox.sampleFiles = samples.filesByAttachment
        wholeThreads = samples.wholeThreads
        starProblems = [:]
        suggestions = samples.items.sorted { $0.receivedAt > $1.receivedAt }
    }
}

// MARK: - Notes into tasks

extension SuggestionDrafts {
    /// The user's notes on the message go first in the task's notes, above a link back to the message and
    /// then whatever the draft had (AI's notes, or the message itself). Without notes, the draft is as it was.
    static func withNote(_ draft: TaskDraft, for s: Suggestion) -> TaskDraft {
        let note = s.note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty else { return draft }
        var d = draft
        d.notes = [note, linkLine(for: s), draft.notes.trimmingCharacters(in: .whitespacesAndNewlines)]
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
        return d
    }

    /// "From Slack · #leadership: <permalink>", "From Gmail: <link>".
    static func linkLine(for s: Suggestion) -> String {
        let link = s.source.url.map { ": \($0.absoluteString)" } ?? ""
        switch s.source.kind {
        case .slack:
            let place = InboxText.place(of: s)
            let label = InboxText.isConversation(place) ? "\(place) from \(s.from)" : place
            return "From Slack · \(label)\(link)"
        case .gmail:
            return "From Gmail\(link)"
        case .ai:
            return s.source.label.isEmpty ? "" : "From \(s.source.label)\(link)"
        }
    }
}

extension Suggestion {
    /// Bigger HTML bodies stay out of integrations.json (it's read at launch): such an email is fetched
    /// again the next time it's opened.
    static let largestSavedHTML = 300_000

    /// The item as integrations.json keeps it.
    var forSaving: Suggestion {
        guard let html = content?.html, html.utf8.count > Self.largestSavedHTML else { return self }
        var copy = self
        copy.content = nil
        return copy
    }
}

// MARK: - Clients

/// The Slack calls the Slack tab makes: `SlackClient` in the app, a stand-in in tests.
protocol SlackInbox: Sendable {
    func reply(channel: String, threadTS: String, text: String) async throws
    /// `names`: people and channels already known by id ("U0…" → "Priya Shah"); only the others are looked up.
    func thread(channel: String, threadTS: String, excluding ts: String, limit: Int, myUserID: String,
                names: [String: String]) async throws -> [ThreadMessage]
    /// The whole thread, oldest first: the parent at `threadTS` and every reply (a message outside a thread
    /// alone), each with its own files.
    func fullThread(channel: String, threadTS: String, myUserID: String) async throws -> [ThreadSlackMessage]
    /// The same, with the people and channels already known by name (only the others are looked up), and the
    /// inbox message (`around`, its ts), which a very long thread keeps in what it shows.
    func fullThread(channel: String, threadTS: String, myUserID: String, names: [String: String],
                    around: String?) async throws -> [ThreadSlackMessage]
    /// Saves the message for later in Slack (stars.add), or takes it out again (stars.remove).
    func setStarred(_ starred: Bool, channel: String, ts: String) async throws
    func download(_ url: URL) async throws -> Data
    func user(_ id: String) async throws -> SlackUser
}

extension SlackInbox {
    /// Stand-ins that only answer the plain call: the whole thread as that gives it.
    func fullThread(channel: String, threadTS: String, myUserID: String, names: [String: String],
                    around: String?) async throws -> [ThreadSlackMessage] {
        try await fullThread(channel: channel, threadTS: threadTS, myUserID: myUserID)
    }
}

extension SlackClient: SlackInbox {}

/// The Gmail calls the Email tab makes: `GmailClient` in the app, a stand-in in tests.
protocol MailInbox: Sendable {
    func fullMessage(_ id: String) async throws -> GmailFullMessage
    func conversation(threadID: String, excluding messageID: String?, limit: Int, myAddress: String) async throws -> [ThreadMessage]
    /// The whole conversation, oldest first: every message with its body, files and reply headers.
    func conversationMessages(threadID: String, myAddress: String) async throws -> [ThreadEmail]
    /// Stars or unstars a message (Gmail's STARRED label).
    func setStarred(_ starred: Bool, messageID: String) async throws
    func attachment(messageID: String, attachmentID: String) async throws -> Data
    func sendReply(_ reply: MailReply) async throws
    func saveDraft(_ reply: MailReply) async throws
}

extension GmailClient: MailInbox {}

/// Stand-ins for the Slack and Gmail clients (tests). Nil: the real client, through `Integrations.transport`.
struct InboxClients {
    var slack: (any SlackInbox)?
    var gmail: (any MailInbox)?
}

/// Everything AI gets to write a reply.
struct ReplyRequest {
    var message: IncomingMessage
    var content: MessageContent?
    /// The rest of the thread or conversation (without `message`), oldest first.
    var thread: [ThreadMessage]
    var notes: String
    var tone: ReplyTone
    var instruction: String?
    var myName: String?
    /// The message of `thread` the reply answers, when it isn't `message`.
    var replyingTo: ThreadMessage? = nil
}

/// The AI step that writes a reply. Tests swap in a fake.
struct ReplyWriter {
    var write: @MainActor (ReplyRequest) async throws -> String

    static var gemini: ReplyWriter {
        ReplyWriter { r in
            try await AIService.shared.draftReply(to: r.message, content: r.content, thread: r.thread, notes: r.notes,
                                                  tone: r.tone, instruction: r.instruction, myName: r.myName,
                                                  replyingTo: r.replyingTo)
        }
    }
}

/// What the Slack and Email tabs keep while Docket runs, never saved: threads, and the loads and sends
/// under way (asking again waits for the same answer).
struct InboxMemory {
    /// Earlier messages of threads and conversations, by item id.
    var threads: [String: [ThreadMessage]] = [:]
    var emailLoads: [String: Task<GmailFullMessage, Error>] = [:]
    var threadLoads: [String: Task<[ThreadMessage], Error>] = [:]
    var wholeThreadLoads: [String: Task<InboxThread, Error>] = [:]
    var fileLoads: [String: Task<URL, Error>] = [:]
    var sends: [String: Task<Void, Error>] = [:]
    /// Replies sent from Docket that their thread, as fetched, doesn't list yet (by item id, oldest first).
    var sentReplies: [String: [SentFromDocket]] = [:]
    /// The fetches that follow sent replies, by item id.
    var rechecks: [String: Task<Void, Never>] = [:]
    /// Stars on their way to Gmail or Slack, by `StarTarget.key`; and, for emails of a conversation, the
    /// star each is going to have.
    var starSyncs: [String: Task<Void, Never>] = [:]
    var starWanted: [String: Bool] = [:]
    /// Star problems clear by themselves after a moment.
    var starProblemClears: [String: Task<Void, Never>] = [:]
    /// Notes Docket already said this session ("Saved in Docket only…").
    var notesSaid: Set<String> = []
    /// Screenshot mode: attachments backed by local files, by cache key, and by attachment id.
    var localFiles: [String: URL] = [:]
    var sampleFiles: [String: URL] = [:]
}

/// The Slack permissions the complete message needs (all in `SlackManifest.contentScopes`).
enum InboxScopes {
    static let slackFiles = "files:read"
    static let slackHistory: Set<String> = ["channels:history", "groups:history", "im:history", "mpim:history"]
}

// MARK: - Stars

/// What a star is on: an inbox item, or another message of its thread or conversation.
struct StarTarget: Hashable {
    /// The item's id.
    var item: String
    /// A `ThreadSlackMessage` (ts) or `ThreadEmail` (Gmail message) id; nil for the item's own message.
    var message: String?

    /// "<item id>", or "<item id> <message id>": how `Integrations.starProblems` files it.
    var key: String { message.map { "\(item) \($0)" } ?? item }

    /// The item a key is about.
    static func item(ofKey key: String) -> String {
        key.split(separator: " ", maxSplits: 1).first.map(String.init) ?? key
    }
}

/// Where stars go besides Docket, and what Docket says when one stays in Docket only.
enum InboxStarRules {
    /// Gmail's label for a starred message.
    static let gmailLabel = "STARRED"
    /// Saving Slack messages for later: stars.read and stars.write (in `SlackManifest.contentScopes`).
    static let slackScopes: Set<String> = ["stars:read", "stars:write"]
    /// The one starring needs.
    static let slackWrite = "stars:write"
    /// Said once when Slack won't save messages for later.
    static let slackNote = "Saved in Docket only (Slack didn't allow saving it there)"
    /// Said once when the Gmail sign-in is from before Docket asked to star.
    static let gmailNote = "Starred in Docket only (reconnect Gmail to star it there too)"

    /// What's said once when a star stays in Docket only: put on (`starring`), or taken off (an email that
    /// came in starred, unstarred before the sign-in allows changing it in Gmail).
    static func docketOnly(_ service: IntegrationError.Service, starring: Bool) -> String {
        switch (service, starring) {
        case (.slack, true): slackNote
        case (.slack, false): "Unstarred in Docket only (Slack didn't allow changing it there)"
        case (_, true): gmailNote
        case (_, false): "Unstarred in Docket only (reconnect Gmail to change it there too)"
        }
    }
    /// How long a star that didn't take says why.
    static let problemShownFor: TimeInterval = 8

    /// Slack turned saving for later down for good rather than this once: the app lacks the permission, the
    /// workspace doesn't allow it, or the method is retired for newer apps (`SlackClient.setStarred` says so
    /// as "Saved in Docket only…"; Slack's own codes count too). A deleted message or a lost connection don't.
    static func slackDeclined(_ e: IntegrationError) -> Bool {
        switch e {
        case .missingPermission(.slack, _):
            return true
        case .api(.slack, let message):
            let m = message.lowercased()
            return ["docket only", "didn't allow", "doesn't allow", "not_allowed", "deprecated", "restricted", "stars:write"]
                .contains { m.contains($0) }
        default:
            return false
        }
    }

    /// Why a star didn't take, in a line next to it: "Couldn't reach Gmail. You seem to be offline.",
    /// "Couldn't star it in Slack. That message isn't in Slack any more."
    static func problem(_ e: IntegrationError, starring: Bool, service: IntegrationError.Service) -> String {
        let lead = "Couldn't \(starring ? "star" : "unstar") it in \(service.rawValue)."
        let detail = (e.errorDescription ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch e {
        case .offline:
            return detail
        case .rateLimited:
            // Nothing tries again by itself.
            return "\(lead) Try again in a minute."
        case .unexpected:
            return "\(lead) Try again."
        default:
            return detail.isEmpty ? lead : "\(lead) \(detail)"
        }
    }
}

// MARK: - Whole threads

/// A reply sent from Docket, shown in its thread until Slack or Gmail lists it.
struct SentFromDocket: Sendable {
    enum Message: Sendable {
        case slack(ThreadSlackMessage)
        case email(ThreadEmail)
    }

    var message: Message
    /// The thread's messages when it went: none of them is it.
    var before: Set<String>

    var date: Date {
        switch message {
        case .slack(let m): m.date
        case .email(let m): m.date
        }
    }

    /// Its words, to find it in the thread as Slack or Gmail lists it.
    var words: String {
        switch message {
        case .slack(let m): Self.words(m.text)
        case .email(let m): Self.words(m.content.text)
        }
    }

    /// Letters and digits only, lowercased: Slack and Gmail give back the words, not always the same spacing,
    /// quote marks or formatting.
    static func words(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// Of the replies sent from Docket (oldest first), the ones `thread` doesn't list yet. A message of yours
    /// that wasn't in the thread when a reply went is that reply: one with the same words first, else any such
    /// message (each stands for one reply).
    static func unlisted(_ sent: [SentFromDocket], in thread: InboxThread) -> [SentFromDocket] {
        var mine = thread.mineListed
        var listed = Set<Int>()
        func take(_ i: Int, where matches: ((id: String, words: String)) -> Bool) {
            guard !listed.contains(i), let j = mine.firstIndex(where: { !sent[i].before.contains($0.id) && matches($0) }) else { return }
            mine.remove(at: j)
            listed.insert(i)
        }
        for i in sent.indices { take(i) { $0.words == sent[i].words } }
        for i in sent.indices { take(i) { _ in true } }
        return sent.indices.filter { !listed.contains($0) }.map { sent[$0] }
    }
}

extension InboxThread {
    /// Messages sent from Docket a moment ago, until Slack or Gmail lists them, have ids starting with this.
    static let sentFromDocketPrefix = "docket-sent-"

    static func newSentFromDocketID() -> String { sentFromDocketPrefix + UUID().uuidString }

    static func isSentFromDocket(_ id: String) -> Bool { id.hasPrefix(sentFromDocketPrefix) }

    /// A message's id as a thread has it: "slack:<channel>/<ts>" → the ts, "gmail:<thread>/<id>" → the Gmail
    /// id; anything else as it is.
    static func bareMessageID(_ raw: String) -> String {
        InboxIDs.slack(raw)?.ts ?? InboxIDs.gmail(raw)?.message ?? raw
    }

    /// The id a message of item `id`'s thread has as an inbox item of its own: "slack:<channel>/<ts>",
    /// "gmail:<thread>/<message>".
    static func itemID(of message: String, inThreadOf id: String) -> String? {
        if let ids = InboxIDs.slack(id) { return "slack:\(ids.channel)/\(message)" }
        if let ids = InboxIDs.gmail(id) { return "gmail:\(ids.thread)/\(message)" }
        return nil
    }

    /// The same Slack message: the same ts, also when written differently ("…000100" and "…0001") or as an
    /// inbox id.
    static func sameSlackMessage(_ a: String, _ b: String) -> Bool {
        let x = bareMessageID(a), y = bareMessageID(b)
        if x == y { return true }
        return SlackClient.isTimestamp(x) && SlackClient.isTimestamp(y) && SlackClient.compare(x, y) == 0
    }

    /// The index of the inbox item's own message.
    var highlightedIndex: Int {
        switch self {
        case .slack(_, let h), .email(_, let h): h
        }
    }

    /// The messages' ids, oldest first.
    var allMessageIDs: [String] {
        switch self {
        case .slack(let messages, _): messages.map(\.id)
        case .email(let messages, _): messages.map(\.id)
        }
    }

    /// Every file of every message, oldest message first.
    var attachments: [MessageAttachment] {
        switch self {
        case .slack(let messages, _): messages.flatMap(\.files)
        case .email(let messages, _): messages.flatMap(\.content.attachments)
        }
    }

    /// The id of the inbox item's own message.
    var ownMessageID: String? {
        let ids = allMessageIDs
        return ids.indices.contains(highlightedIndex) ? ids[highlightedIndex] : nil
    }

    /// Which message a reply answers when none is picked: in Slack the item's own (the reply goes in its
    /// thread); in an email conversation the newest message that isn't yours, else the newest one.
    var defaultReplyMessageID: String? {
        switch self {
        case .slack:
            return ownMessageID
        case .email(let messages, _):
            let sent = messages.filter { !Self.isSentFromDocket($0.id) }
            return (sent.last { !$0.isMine } ?? sent.last)?.id
        }
    }

    /// The thread as AI reads it, oldest first: who wrote each message, when, and its words (an email
    /// without the history it quotes), with the names of its files.
    var forReplyContext: [ThreadMessage] {
        func withFiles(_ text: String, _ files: [MessageAttachment]) -> String {
            let names = files.filter { $0.contentID == nil }.map(\.name).filter { !$0.isEmpty }
            guard !names.isEmpty else { return text }
            let line = "Attached: " + names.joined(separator: ", ")
            return text.isEmpty ? line : text + "\n" + line
        }
        switch self {
        case .slack(let messages, _):
            return messages.map { m in
                let text = m.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return ThreadMessage(id: m.id, from: m.from, date: m.date, text: withFiles(text, m.files), isMine: m.isMine)
            }
        case .email(let messages, _):
            return messages.map { m in
                var text = MailQuote.trimmed(m.content.text).trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty { text = m.snippet.trimmingCharacters(in: .whitespacesAndNewlines) }
                return ThreadMessage(id: m.id, from: m.from, date: m.date, text: withFiles(text, m.content.attachments), isMine: m.isMine)
            }
        }
    }

    /// The user's messages as Slack or Gmail lists them (replies sent from Docket a moment ago aside): their
    /// ids and words (`SentFromDocket.words`).
    var mineListed: [(id: String, words: String)] {
        switch self {
        case .slack(let messages, _):
            return messages.filter { $0.isMine && !Self.isSentFromDocket($0.id) }.map { ($0.id, SentFromDocket.words($0.text)) }
        case .email(let messages, _):
            return messages.filter { $0.isMine && !Self.isSentFromDocket($0.id) }.map { ($0.id, SentFromDocket.words($0.content.text)) }
        }
    }

    /// The thread with replies sent from Docket at the end (each of its own kind).
    func appendingSent(_ sent: [SentFromDocket]) -> InboxThread {
        switch self {
        case .slack(let messages, let h):
            return .slack(messages + sent.compactMap { if case .slack(let m) = $0.message { return m } else { return nil } }, highlighted: h)
        case .email(let messages, let h):
            return .email(messages + sent.compactMap { if case .email(let m) = $0.message { return m } else { return nil } }, highlighted: h)
        }
    }
}

// MARK: - Ids and words

/// The parts of an item's id: "slack:<channel>/<ts>", "gmail:<thread>/<message>".
enum InboxIDs {
    static func slack(_ id: String) -> (channel: String, ts: String)? {
        parts(id, prefix: "slack:").map { (channel: $0.0, ts: $0.1) }
    }

    static func gmail(_ id: String) -> (thread: String, message: String)? {
        parts(id, prefix: "gmail:").map { (thread: $0.0, message: $0.1) }
    }

    private static func parts(_ id: String, prefix: String) -> (String, String)? {
        guard id.hasPrefix(prefix) else { return nil }
        let rest = id.dropFirst(prefix.count)
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let first = String(rest[..<slash]), second = String(rest[rest.index(after: slash)...])
        guard !first.isEmpty, !second.isEmpty, !second.contains("/") else { return nil }
        return (first, second)
    }
}

enum InboxText {
    private static let slackReference = try! NSRegularExpression(pattern: #"<[@#]([A-Z0-9]+)"#)

    /// The ids of the people and channels a message's markup refers to ("<@U0…>", "<#C0…|name>").
    static func slackIDs(in markup: String) -> Set<String> {
        let ns = markup as NSString
        return Set(slackReference.matches(in: markup, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) })
    }

    /// "U0123ABCD": a Slack user id rather than a name.
    static func isSlackUserID(_ s: String) -> Bool {
        guard let first = s.first, first == "U" || first == "W", s.count >= 5 else { return false }
        return s.allSatisfy { ($0.isUppercase || $0.isNumber) && $0.isASCII } && s.contains { $0.isNumber }
    }

    /// Where a Slack message was posted: "#leadership", "Direct message", "Group message".
    static func place(of s: Suggestion) -> String {
        let place = s.source.label.components(separatedBy: " · ").first?.trimmingCharacters(in: .whitespaces) ?? ""
        return place.isEmpty ? "Slack" : place
    }

    /// A direct or group message rather than a channel.
    static func isConversation(_ place: String) -> Bool {
        place == "Direct message" || place == "Group message"
    }

    /// "Replied in #leadership", "Replied to Priya Shah".
    static func repliedToast(for s: Suggestion) -> String {
        let place = place(of: s)
        if place.hasPrefix("#") { return "Replied in \(place)" }
        if place == "Direct message" { return "Replied to \(s.from)" }
        return "Reply sent"
    }
}

// MARK: - Samples for screenshots

/// Made-up messages for screenshot mode: invented people, companies and addresses.
private struct InboxSamples {
    static let me = "U0DEMOMAYA"
    static let account = SlackAccount(userID: me, userName: "maya", teamID: "T0DEMO", teamName: "Acme",
                                      teamURL: URL(string: "https://acme-demo.slack.com/"))
    static let address = "maya@acme.example"
    static let names = [
        "U0DEMOMAYA": "Maya Chen", "U0DEMOPRIYA": "Priya Shah", "U0DEMOSAM": "Sam Lee", "U0DEMOALEX": "Alex Kim",
        "U0DEMOJORDAN": "Jordan Rivera", "C0DEMOLEAD": "leadership", "C0DEMOFIN": "finance", "C0DEMOPROD": "product",
    ]

    var items: [Suggestion] = []
    /// Earlier messages, for `thread(for:)`; whole threads, for `fullThread(for:reload:)`.
    var threads: [String: [ThreadMessage]] = [:]
    var wholeThreads: [String: InboxThread] = [:]
    /// Local files standing in for attachments: by cache key, and by attachment id.
    var files: [String: URL] = [:]
    var filesByAttachment: [String: URL] = [:]

    init(imageFile: URL?, documentFile: URL?, now: Date) {
        let calendar = Calendar.current
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)) ?? now }
        func ts(_ date: Date) -> String { String(format: "%.6f", date.timeIntervalSince1970) }
        /// A message of a Slack thread by one of the sample people (`who`: their user id).
        func post(_ who: String, at date: Date, _ markup: String, files: [MessageAttachment] = []) -> ThreadSlackMessage {
            ThreadSlackMessage(id: ts(date), from: Self.names[who] ?? who, userID: who, date: date, markup: markup,
                               text: SlackText.plain(markup, users: Self.names, channels: Self.names), files: files, isMine: who == Self.me)
        }
        /// The Slack item's own message in its thread.
        func ownPost(_ s: Suggestion, by who: String) -> ThreadSlackMessage {
            ThreadSlackMessage(id: InboxIDs.slack(s.id)?.ts ?? s.id, from: s.from, userID: who, date: s.receivedAt,
                               markup: s.content?.markup ?? "", text: s.content?.text ?? s.snippet,
                               files: s.content?.attachments ?? [], isMine: who == Self.me)
        }
        /// An email of a conversation (`id`: its Gmail message id), its sender as a From header like Gmail's.
        func mail(_ id: String, from sender: (name: String, address: String), to: [String], cc: [String] = [], subject: String,
                  at date: Date, text: String, starred: Bool = false) -> ThreadEmail {
            ThreadEmail(id: id, from: "\(sender.name) <\(sender.address)>", date: date,
                        content: MessageContent(text: text, to: to, cc: cc, fetchedAt: date),
                        replyHeaders: MailReplyHeaders(messageID: "<\(id)@mail.\(sender.address.split(separator: "@").last ?? "acme.example")>",
                                                       subject: subject, from: "\(sender.name) <\(sender.address)>", to: to, cc: cc),
                        isMine: sender.address == Self.address, isStarred: starred, snippet: SlackText.firstLine(text, limit: 200))
        }
        /// The email item's own message in its conversation.
        func ownMail(_ s: Suggestion) -> ThreadEmail {
            ThreadEmail(id: InboxIDs.gmail(s.id)?.message ?? s.id, from: s.replyHeaders?.from ?? s.from, date: s.receivedAt,
                        content: s.content ?? MessageContent(text: s.snippet, fetchedAt: s.receivedAt),
                        replyHeaders: s.replyHeaders ?? MailReplyHeaders(subject: s.subject ?? "", from: s.from),
                        isMine: false, isStarred: s.isStarred, snippet: s.snippet)
        }
        /// A whole thread, and the messages before the item's own for the earlier-messages view.
        func keep(_ thread: InboxThread, for id: String) {
            wholeThreads[id] = thread
            threads[id] = Array(thread.forReplyContext.prefix(thread.highlightedIndex))
        }
        func permalink(_ channel: String, _ date: Date) -> URL? {
            URL(string: "https://acme-demo.slack.com/archives/\(channel)/p\(ts(date).replacingOccurrences(of: ".", with: ""))")
        }
        func slack(_ channel: String, _ place: String, from: String, at date: Date, markup: String, trigger: SuggestionTrigger,
                   task: TaskDraft?, files: [MessageAttachment] = []) -> Suggestion {
            let text = SlackText.plain(markup, users: Self.names, channels: Self.names)
            var s = Suggestion(source: TaskSource(kind: .slack, externalID: "slack:\(channel)/\(ts(date))", url: permalink(channel, date),
                                                  label: "\(place) · \(from)"),
                               from: from, subject: nil, snippet: String(SlackText.collapsed(text).prefix(500)), receivedAt: date,
                               draft: task, trigger: trigger)
            s.content = MessageContent(text: text, markup: markup, attachments: files, fetchedAt: date)
            return s
        }
        func email(thread: String, message: String, from: (name: String, address: String), subject: String, at date: Date,
                   text: String, html: String? = nil, cc: [String] = [], trigger: SuggestionTrigger, task: TaskDraft?,
                   files: [MessageAttachment] = []) -> Suggestion {
            let me = "Maya Chen <\(Self.address)>"
            var s = Suggestion(source: TaskSource(kind: .gmail, externalID: "gmail:\(thread)/\(message)",
                                                  url: GmailClient.threadLink(account: Self.address, threadID: thread),
                                                  label: "\(from.name) · \(subject)"),
                               from: from.name, subject: subject, snippet: String(SlackText.collapsed(text).prefix(200)),
                               receivedAt: date, draft: task, trigger: trigger)
            s.content = MessageContent(text: text, html: html, to: [me], cc: cc, attachments: files, fetchedAt: date)
            s.replyHeaders = MailReplyHeaders(messageID: "<\(message)@mail.acme.example>", subject: subject,
                                              from: "\(from.name) <\(from.address)>", to: [me], cc: cc)
            return s
        }

        // Slack: a reply in a #leadership thread, with a chart and the user's notes.
        let parent = ago(190), asked = ago(35)
        let budgetID = "slack:C0DEMOLEAD/\(ts(asked))"
        var budget = slack("C0DEMOLEAD", "#leadership", from: "Priya Shah", at: asked, markup: """
            Can you send me the *Q3 numbers* before Thursday's board call? <@U0DEMOSAM> has the _draft deck_ in <#C0DEMOFIN|finance>.
            Please use the `metrics-v2` export:
            ```
            ARR    $1.66M
            NRR    118%
            Burn   down 12%
            ```
            """, trigger: .reaction,
            task: TaskDraft(title: "Send Priya the Q3 numbers", due: day(2), estimateMinutes: 20, priority: .high),
            files: [attachment(imageFile, "Q3 revenue chart", id: "F0DEMOCHART", item: budgetID,
                               remote: Self.slackFile("F0DEMOCHART"))].compactMap { $0 })
        budget.threadTS = ts(parent)
        budget.note = "Use the finance export, not the dashboard. Flag the churn dip in August."
        // The whole thread: six messages, two with files, and Sam's (with the deck) starred in Docket.
        let deck = [attachment(documentFile, "Board deck draft", id: "F0DEMODECK", item: budgetID,
                               remote: Self.slackFile("F0DEMODECK"))].compactMap { $0 }
        let budgetThread = [
            post("U0DEMOSAM", at: parent, "Board call moved to *Thursday at 10:00*. The deck goes out Wednesday night; the draft is attached.",
                 files: deck),
            post(Self.me, at: ago(150), "Thanks. I'll pull the numbers together."),
            post("U0DEMOJORDAN", at: ago(95), "I can cover the product slides if that helps."),
            post("U0DEMOPRIYA", at: ago(60), "Great, I'll keep a slide for them."),
            ownPost(budget, by: "U0DEMOPRIYA"),
            post("U0DEMOALEX", at: ago(20), "<@U0DEMOMAYA> the August churn dip is in the appendix, if you want to flag it."),
        ]
        budget.starredInThread = [ts(parent)]
        keep(.slack(budgetThread, highlighted: 4), for: budgetID)

        // Slack: a direct message with a document, and a reply being written.
        let shared = ago(170)
        let copyID = "slack:D0DEMOALEX/\(ts(shared))"
        var copy = slack("D0DEMOALEX", "Direct message", from: "Alex Kim", at: shared, markup:
            "Pricing page copy is ready for your sign-off :tada: Two options for the headline are in the doc. Can we ship it Monday?",
            trigger: .reaction, task: TaskDraft(title: "Sign off on the pricing page copy", estimateMinutes: 15),
            files: [attachment(documentFile, "Pricing page copy", id: "F0DEMOCOPY", item: copyID,
                               remote: Self.slackFile("F0DEMOCOPY"))].compactMap { $0 })
        copy.replyDraft = "Looks great. Let's go with option B for the headline and ship it Monday."
        copy.isStarred = true
        keep(.slack([ownPost(copy, by: "U0DEMOALEX")], highlighted: 0), for: copyID)

        // Slack: a mention, already answered.
        let mentioned = ago(26 * 60)
        var launch = slack("C0DEMOPROD", "#product", from: "Jordan Rivera", at: mentioned, markup:
            "<@U0DEMOMAYA> the launch checklist is updated. Can you confirm the press date by Friday? Everything else is on track.",
            trigger: .mention, task: TaskDraft(title: "Confirm the press date for the launch", due: day(4), estimateMinutes: 10))
        launch.repliedAt = ago(22 * 60)
        keep(.slack([ownPost(launch, by: "U0DEMOJORDAN"),
                     post(Self.me, at: ago(22 * 60), "Confirmed, the press date holds. I'll send the final copy Thursday.")],
                    highlighted: 0), for: launch.id)

        // Email: contract redlines with a PDF and an image, an earlier conversation, and notes.
        let redlinesThread = "18f2a0c4d5e6f701", redlinesMessage = "18f2a0c4d5e6f7a2"
        let redlinesID = "gmail:\(redlinesThread)/\(redlinesMessage)"
        let lena = "Lena Park <lena@acme.example>"
        var redlines = email(thread: redlinesThread, message: redlinesMessage, from: ("Sam Lee", "sam@northwind.example"),
                             subject: "Contract redlines", at: ago(130), text: """
            Hi Maya,

            Attached are the redlines from Northwind's legal team. Two changes matter:

            • Section 4: the liability cap moves to 12 months of fees.
            • Section 7: termination for convenience on 60 days' notice.

            Could you review both by Friday? I marked our fallback positions in the PDF.

            Thanks,
            Sam
            """, html: """
            <p>Hi Maya,</p>
            <p>Attached are the redlines from Northwind's legal team. Two changes matter:</p>
            <ul>
            <li><b>Section 4</b>: the liability cap moves to 12 months of fees.</li>
            <li><b>Section 7</b>: termination for convenience on 60 days' notice.</li>
            </ul>
            <p>Could you review both by Friday? I marked our fallback positions in the PDF.</p>
            <p>Thanks,<br>Sam</p>
            """, cc: [lena], trigger: .starred,
            task: TaskDraft(title: "Review the contract redlines", due: day(4), estimateMinutes: 45, priority: .medium),
            files: [attachment(documentFile, "Northwind MSA redlines", id: "\(redlinesMessage)/ANGjdJ8demoRedlines", item: redlinesID,
                               remote: .gmail(messageID: redlinesMessage, attachmentID: "ANGjdJ8demoRedlines")),
                    attachment(imageFile, "Signature page", id: "\(redlinesMessage)/ANGjdJ8demoSignature", item: redlinesID,
                               remote: .gmail(messageID: redlinesMessage, attachmentID: "ANGjdJ8demoSignature"))].compactMap { $0 })
        redlines.note = "Section 4 is fine at 12 months only with a carve-out for data breaches."
        redlines.isStarred = true
        // The whole conversation: your draft, Sam's answer, the redlines with their attachments (starred), and
        // Lena's reply to all.
        let maya = (name: "Maya Chen", address: Self.address), sam = (name: "Sam Lee", address: "sam@northwind.example")
        keep(.email([
            mail("18f2a0c4d5e6f6b1", from: maya, to: ["Sam Lee <sam@northwind.example>"], cc: [lena], subject: "Contract redlines",
                 at: ago(3 * 24 * 60), text: "Sam, here's our MSA draft for Northwind. Let me know what their legal team thinks."),
            mail("18f2a0c4d5e6f6c9", from: sam, to: ["Maya Chen <\(Self.address)>"], cc: [lena], subject: "Re: Contract redlines",
                 at: ago(2 * 24 * 60), text: "Thanks, sending it over to them today."),
            ownMail(redlines),
            mail("18f2a0c4d5e6f7d4", from: (name: "Lena Park", address: "lena@acme.example"),
                 to: ["Sam Lee <sam@northwind.example>", "Maya Chen <\(Self.address)>"], subject: "Re: Contract redlines",
                 at: ago(60), text: "I can join a call Friday morning to walk through Section 7, if that helps."),
        ], highlighted: 2), for: redlinesID)

        // Email: an introduction waiting for a reply.
        let intro = email(thread: "18f2a0c4d5e6f801", message: "18f2a0c4d5e6f8b3", from: ("Dana Whitfield", "dana@contoso.example"),
                          subject: "Intro: Contoso platform team", at: ago(5 * 60), text: """
            Hi Maya,

            Great meeting you at the summit last week. I'd love to introduce you to our platform team; they're looking at tools like yours for Q1.

            Are you free for 30 minutes next Tuesday or Wednesday?

            Best,
            Dana
            """, trigger: .needsReply, task: TaskDraft(title: "Find a time for the Contoso intro", estimateMinutes: 10))
        keep(.email([ownMail(intro)], highlighted: 0), for: intro.id)

        // Email: already answered.
        var venues = email(thread: "18f2a0c4d5e6f901", message: "18f2a0c4d5e6f9c4", from: ("Lena Park", "lena@acme.example"),
                           subject: "Offsite venue options", at: ago(28 * 60), text: """
            Three options for the offsite, all with rooms for 40:

            • The Boathouse: lake view, $$
            • Granite Hall: downtown, $$$
            • Cedar Lodge: two hours out, $

            Can you pick one by Friday so I can book it?
            """, html: """
            <p>Three options for the offsite, all with rooms for 40:</p>
            <ul><li><b>The Boathouse</b>: lake view, $$</li><li><b>Granite Hall</b>: downtown, $$$</li>
            <li><b>Cedar Lodge</b>: two hours out, $</li></ul>
            <p>Can you pick one by Friday so I can book it?</p>
            """, trigger: .starred, task: TaskDraft(title: "Pick the offsite venue", due: day(5), estimateMinutes: 20))
        venues.repliedAt = ago(20 * 60)
        venues.isStarred = true
        keep(.email([ownMail(venues),
                     mail("18f2a0c4d5e6f9e7", from: maya, to: ["Lena Park <lena@acme.example>"], subject: "Re: Offsite venue options",
                          at: ago(20 * 60), text: "Let's go with Cedar Lodge, as long as it has rooms for all 40. Thanks for pulling these together.")],
                    highlighted: 0), for: venues.id)

        items = [budget, copy, launch, redlines, intro, venues]
    }

    /// Where Slack would have the file (never fetched: screenshot mode reads the local copy).
    private static func slackFile(_ id: String) -> MessageAttachment.Remote {
        .slack(url: URL(string: "https://files.slack.com/files-pri/T0DEMO-\(id)/download/file")!, thumbnail: nil)
    }

    /// An attachment backed by a local file (none without one), named like the file's type.
    private mutating func attachment(_ file: URL?, _ name: String, id: String, item: String, remote: MessageAttachment.Remote) -> MessageAttachment? {
        guard let file else { return nil }
        let ext = file.pathExtension.lowercased()
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        files[InboxCache.key(messageID: item, attachmentID: id)] = file
        filesByAttachment[id] = file
        return MessageAttachment(id: id, name: ext.isEmpty ? name : "\(name).\(ext)",
                                 mimeType: UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream",
                                 size: size, remote: remote)
    }
}
