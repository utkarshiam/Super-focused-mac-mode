import Foundation
import UniformTypeIdentifiers

// MARK: - The Slack and Email tabs

/// What the inbox shows and does with a message: each tab's items, the complete message and its thread,
/// attachments, the user's notes, and replies.
///
/// Nothing here blocks the UI, and nothing goes out by itself: a reply is sent (or saved as a Gmail draft)
/// only by `sendReply` / `saveReplyAsDraft`, which the views call after the user confirmed it. Problems come
/// back as `IntegrationError`s in plain words; a Slack or Google sign-out disconnects, as a refresh would.
extension Integrations {
    /// At most this many earlier messages of a thread or an email conversation are shown.
    static let threadLimit = 20
    /// AI reads at most this much of a message's text.
    static let replyContextLimit = 20_000

    /// One tab's items (Slack or Gmail), newest first; with `starredOnly`, just the starred ones.
    func items(_ kind: TaskSource.Kind, starredOnly: Bool = false) -> [Suggestion] {
        // TODO(group 3): starred items first within a tab.
        suggestions.filter { $0.source.kind == kind && (!starredOnly || $0.isStarred) }.sorted { $0.receivedAt > $1.receivedAt }
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
    /// message as `highlighted`. Loaded when the item opens and kept for the session; `reload` fetches it again.
    func fullThread(for id: String, reload: Bool) async throws -> InboxThread {
        // TODO(group 3): Slack `fullThread`, Gmail `conversationMessages`; cache per session; friendly missing-scope state.
        throw Self.notBuilt(id, "the whole thread")
    }

    // MARK: Stars

    /// Stars or unstars the item: at once in Docket (saved), then in Gmail (the STARRED label) or Slack (saved
    /// for later); put back, with an inline error, when that fails.
    func setStarred(_ starred: Bool, for id: String) async {
        // TODO(group 3): optimistic star, the Gmail or Slack call, reconcile or revert.
    }

    // MARK: Attachments

    /// A local copy of the attachment, for Quick Look: downloaded once, then kept in IntegrationCache/ (see
    /// `InboxCache`). Files over 100 MB aren't downloaded, and neither are Slack files the app has no
    /// permission for (`missingSlackScopes` has files:read): the views offer to open those in Slack.
    func file(for attachment: MessageAttachment, messageID id: String) async throws -> URL {
        let key = InboxCache.key(messageID: id, attachmentID: attachment.id)
        if let local = inbox.localFiles[key] { return local }
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

    /// The cache keys of these items' attachments.
    func inboxCacheKeys(_ items: [Suggestion]) -> Set<String> {
        Set(items.flatMap { s in (s.content?.attachments ?? []).map { InboxCache.key(messageID: s.id, attachmentID: $0.id) } })
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
        for s in items { inbox.threads[s.id] = nil }
        guard let root = cacheDirectory else { return }
        let keys = inboxCacheKeys(items)
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
    /// context from the complete message and its thread. It becomes the item's reply draft. Without the whole
    /// message or the thread (offline, a missing permission), it's written from what Docket has.
    func draftReply(for id: String, tone: ReplyTone, instruction: String?) async throws -> String {
        guard suggestion(id) != nil else { throw Self.gone(id) }
        let content = try? await content(for: id)
        let thread = (try? await thread(for: id)) ?? []
        // Read after the waits, so notes typed meanwhile count.
        guard let s = suggestion(id) else { throw Self.gone(id) }
        let ask = instruction?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let request = ReplyRequest(message: incoming(s, content: content), content: content, thread: thread,
                                   notes: s.note.trimmingCharacters(in: .whitespacesAndNewlines), tone: tone,
                                   instruction: ask.isEmpty ? nil : ask, myName: replyName(for: s.source.kind))
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

    /// Sends the reply as the user: in the Slack message's thread, or as an email in its conversation (to
    /// the sender, or with `replyAll` to everyone on it but the user). Only ever called once the user
    /// confirmed it. Afterwards the item shows "Replied" and its draft is cleared. Calling again while it
    /// goes out waits for that send instead of sending twice.
    ///
    /// `replyingTo` is the message in the thread being answered (a `ThreadSlackMessage` or `ThreadEmail` id);
    /// nil answers the default one.
    func sendReply(_ text: String, for id: String, replyingTo messageID: String?, replyAll: Bool) async throws {
        // TODO(group 3): reply to the chosen message; default target (Slack: the thread; email: the newest not from you).
        guard messageID == nil else { throw Self.notBuilt(id, "replying to one message") }
        try await deliver(text, for: id, replyAll: replyAll, asDraft: false)
    }

    /// Saves the reply as a draft in the email's Gmail conversation, to finish there. The text stays here too.
    /// `replyingTo` as for `sendReply`.
    func saveReplyAsDraft(_ text: String, for id: String, replyingTo messageID: String?, replyAll: Bool) async throws {
        // TODO(group 3): a draft answering the chosen message.
        guard messageID == nil else { throw Self.notBuilt(id, "replying to one message") }
        try await deliver(text, for: id, replyAll: replyAll, asDraft: true)
    }

    /// `sendReply(_:for:replyingTo:replyAll:)`, answering the default message.
    func sendReply(_ text: String, for id: String, replyAll: Bool) async throws {
        try await sendReply(text, for: id, replyingTo: nil, replyAll: replyAll)
    }

    /// `saveReplyAsDraft(_:for:replyingTo:replyAll:)`, answering the default message.
    func saveReplyAsDraft(_ text: String, for id: String, replyAll: Bool) async throws {
        try await saveReplyAsDraft(text, for: id, replyingTo: nil, replyAll: replyAll)
    }

    private func deliver(_ text: String, for id: String, replyAll: Bool, asDraft: Bool) async throws {
        guard let s = suggestion(id) else { throw Self.gone(id) }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw IntegrationError.api(Self.service(of: s.source.kind), "Write a reply first.") }
        try await once((asDraft ? "draft " : "send ") + id, in: \.inbox.sends) { [self] in
            switch s.source.kind {
            case .slack:
                guard !asDraft else { throw IntegrationError.api(.slack, "Slack has no drafts. Copy the reply instead.") }
                guard let ids = InboxIDs.slack(id) else { throw IntegrationError.unexpected(.slack, "a bad message id") }
                do {
                    // Under the message: in its thread, or starting one. (The client escapes it for Slack.)
                    try await slackInbox().reply(channel: ids.channel, threadTS: s.threadTS ?? ids.ts, text: body)
                } catch {
                    throw inboxFailure(error, .slack)
                }
                markReplied(id)
                app?.showToast(InboxText.repliedToast(for: s))
            case .gmail:
                let reply = try await mailReply(body, to: id, replyAll: replyAll)
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
                    app?.showToast("Reply sent")
                }
            case .ai:
                throw IntegrationError.api(.slack, "There's nowhere to send this reply.")
            }
        }
    }

    /// The reply email: the original's headers (fetched once if the email was never opened) and the
    /// account it goes out from.
    private func mailReply(_ body: String, to id: String, replyAll: Bool) async throws -> MailReply {
        guard isGmailConnected, let address = gmailAddress else { throw IntegrationError.notConnected(.gmail) }
        guard gmailCanCompose else { throw Self.cantCompose }
        guard let ids = InboxIDs.gmail(id) else { throw IntegrationError.unexpected(.gmail, "a bad message id") }
        let headers: MailReplyHeaders
        if let known = suggestion(id)?.replyHeaders {
            headers = known
        } else {
            headers = try await email(id).replyHeaders
        }
        return MailReply(threadID: ids.thread, headers: headers, fromAddress: address, body: body, replyAll: replyAll)
    }

    private func markReplied(_ id: String, at now: Date = Date()) {
        guard let i = index(of: id) else { return }
        suggestions[i].repliedAt = now
        suggestions[i].replyDraft = ""
        save()
    }

    /// Google turned a send down for lack of the compose permission: Docket stops offering to send (the
    /// views ask to reconnect Gmail) and says so in those words.
    private func composeFailure(_ error: Error) -> IntegrationError {
        let e = inboxFailure(error, .gmail)
        guard case .missingPermission(.gmail, _) = e else { return e }
        grantedGmailScopes?.remove(GoogleOAuth.composeScope)
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

    /// Whether the Gmail sign-in allows sending replies and saving drafts (the gmail.compose scope). Sign-ins
    /// from before Docket asked for it don't: the views ask to reconnect Gmail.
    var gmailCanCompose: Bool {
        isGmailConnected && grantedGmailScopes?.contains(GoogleOAuth.composeScope) == true
    }

    /// Whether the Gmail sign-in allows starring (the gmail.modify scope, which also covers reading, drafts and
    /// sending). Sign-ins from before Docket asked for it don't: the views ask to reconnect Gmail.
    var gmailCanModify: Bool {
        // TODO(group 3): check against what the sign-in reports, as for compose.
        isGmailConnected && grantedGmailScopes?.contains(GoogleOAuth.modifyScope) == true
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

    /// What the stubs above throw until they're built. TODO(group 3): remove with the last stub.
    private static func notBuilt(_ id: String, _ what: String) -> IntegrationError {
        .unexpected(id.hasPrefix("gmail:") ? .gmail : .slack, "\(what) isn't built yet")
    }

    private static func service(of kind: TaskSource.Kind) -> IntegrationError.Service {
        kind == .gmail ? .gmail : .slack
    }

    private static func service(of attachment: MessageAttachment) -> IntegrationError.Service {
        if case .gmail = attachment.remote { return .gmail }
        return .slack
    }

    // MARK: Screenshot mode

    /// Screenshot mode only: sample Slack and email items with content, a thread, notes, a reply draft, and
    /// attachments backed by the given local files (no network, nothing saved). It never replaces real data:
    /// outside screenshot mode it does nothing once saved state was loaded.
    func debugSeed(imageFile: URL?, documentFile: URL?, now: Date) {
        guard DebugSnapshot.isActive || !hasSavedState else { return }
        let samples = InboxSamples(imageFile: imageFile, documentFile: documentFile, now: now)
        showSampleAccounts(slack: InboxSamples.account, gmail: InboxSamples.address, refreshedAt: now.addingTimeInterval(-4 * 60))
        savedSlackNames = InboxSamples.names
        inbox = InboxMemory()
        inbox.threads = samples.threads
        inbox.localFiles = samples.files
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
    func download(_ url: URL) async throws -> Data
    func user(_ id: String) async throws -> SlackUser
}

extension SlackClient: SlackInbox {}

/// The Gmail calls the Email tab makes: `GmailClient` in the app, a stand-in in tests.
protocol MailInbox: Sendable {
    func fullMessage(_ id: String) async throws -> GmailFullMessage
    func conversation(threadID: String, excluding messageID: String?, limit: Int, myAddress: String) async throws -> [ThreadMessage]
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
    var thread: [ThreadMessage]
    var notes: String
    var tone: ReplyTone
    var instruction: String?
    var myName: String?
}

/// The AI step that writes a reply. Tests swap in a fake.
struct ReplyWriter {
    var write: @MainActor (ReplyRequest) async throws -> String

    static var gemini: ReplyWriter {
        ReplyWriter { r in
            try await AIService.shared.draftReply(to: r.message, content: r.content, thread: r.thread, notes: r.notes,
                                                  tone: r.tone, instruction: r.instruction, myName: r.myName)
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
    var fileLoads: [String: Task<URL, Error>] = [:]
    var sends: [String: Task<Void, Error>] = [:]
    /// Screenshot mode: attachments backed by local files, by cache key.
    var localFiles: [String: URL] = [:]
}

/// The Slack permissions the complete message needs (all in `SlackManifest.contentScopes`).
enum InboxScopes {
    static let slackFiles = "files:read"
    static let slackHistory: Set<String> = ["channels:history", "groups:history", "im:history", "mpim:history"]
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
    var threads: [String: [ThreadMessage]] = [:]
    var files: [String: URL] = [:]

    init(imageFile: URL?, documentFile: URL?, now: Date) {
        let calendar = Calendar.current
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)) ?? now }
        func ts(_ date: Date) -> String { String(format: "%.6f", date.timeIntervalSince1970) }
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
        threads[budgetID] = [
            ThreadMessage(id: ts(parent), from: "Sam Lee", date: parent,
                          text: "Board call moved to Thursday at 10:00. The deck goes out Wednesday night.", isMine: false),
            ThreadMessage(id: ts(ago(150)), from: "Maya Chen", date: ago(150), text: "Thanks. I'll pull the numbers together.", isMine: true),
            ThreadMessage(id: ts(ago(60)), from: "Priya Shah", date: ago(60), text: "Great, I'll keep a slide for them.", isMine: false),
        ]

        // Slack: a direct message with a document, and a reply being written.
        let shared = ago(170)
        let copyID = "slack:D0DEMOALEX/\(ts(shared))"
        var copy = slack("D0DEMOALEX", "Direct message", from: "Alex Kim", at: shared, markup:
            "Pricing page copy is ready for your sign-off :tada: Two options for the headline are in the doc. Can we ship it Monday?",
            trigger: .reaction, task: TaskDraft(title: "Sign off on the pricing page copy", estimateMinutes: 15),
            files: [attachment(documentFile, "Pricing page copy", id: "F0DEMOCOPY", item: copyID,
                               remote: Self.slackFile("F0DEMOCOPY"))].compactMap { $0 })
        copy.replyDraft = "Looks great. Let's go with option B for the headline and ship it Monday."
        threads[copyID] = []

        // Slack: a mention, already answered.
        let mentioned = ago(26 * 60)
        var launch = slack("C0DEMOPROD", "#product", from: "Jordan Rivera", at: mentioned, markup:
            "<@U0DEMOMAYA> the launch checklist is updated. Can you confirm the press date by Friday? Everything else is on track.",
            trigger: .mention, task: TaskDraft(title: "Confirm the press date for the launch", due: day(4), estimateMinutes: 10))
        launch.repliedAt = ago(22 * 60)
        threads[launch.id] = []

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
        threads[redlinesID] = [
            ThreadMessage(id: "18f2a0c4d5e6f6b1", from: "Maya Chen", date: ago(3 * 24 * 60),
                          text: "Sam, here's our MSA draft for Northwind. Let me know what their legal team thinks.", isMine: true),
            ThreadMessage(id: "18f2a0c4d5e6f6c9", from: "Sam Lee", date: ago(2 * 24 * 60),
                          text: "Thanks, sending it over to them today.", isMine: false),
        ]

        // Email: an introduction waiting for a reply.
        let intro = email(thread: "18f2a0c4d5e6f801", message: "18f2a0c4d5e6f8b3", from: ("Dana Whitfield", "dana@contoso.example"),
                          subject: "Intro: Contoso platform team", at: ago(5 * 60), text: """
            Hi Maya,

            Great meeting you at the summit last week. I'd love to introduce you to our platform team; they're looking at tools like yours for Q1.

            Are you free for 30 minutes next Tuesday or Wednesday?

            Best,
            Dana
            """, trigger: .needsReply, task: TaskDraft(title: "Find a time for the Contoso intro", estimateMinutes: 10))
        threads[intro.id] = []

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
        threads[venues.id] = []

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
        return MessageAttachment(id: id, name: ext.isEmpty ? name : "\(name).\(ext)",
                                 mimeType: UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream",
                                 size: size, remote: remote)
    }
}
