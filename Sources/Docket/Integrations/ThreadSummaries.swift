import Foundation

// Summaries of important Slack threads and email conversations: a "Summary" card at the top of the open
// message in Messages (2–4 bullets and what's waiting on the user), written by Gemini, kept per item with a
// fingerprint of the thread it was made from (in integrations.json), and made again when the thread changes.

// MARK: - What a summary says

/// What AI writes: 2–4 bullets and, when something is waiting on the user, what.
struct SummaryText: Hashable, Sendable {
    var bullets: [String]
    var needsFromYou: String?
}

/// A summary as Docket keeps it: the words, and which version of the thread they're about.
struct ThreadSummary: Codable, Hashable, Sendable {
    var bullets: [String]
    var needsFromYou: String?
    /// `ThreadImportance.fingerprint` of the thread it was made from: another one means the thread changed.
    var fingerprint: String
    var madeAt: Date

    init(_ text: SummaryText, fingerprint: String, madeAt: Date) {
        bullets = text.bullets
        needsFromYou = text.needsFromYou
        self.fingerprint = fingerprint
        self.madeAt = madeAt
    }

    enum CodingKeys: String, CodingKey { case bullets, needsFromYou, fingerprint, madeAt }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bullets = c.value(.bullets, default: [])
        needsFromYou = c.value(.needsFromYou, default: nil)
        fingerprint = c.value(.fingerprint, default: "")
        madeAt = c.value(.madeAt, default: .distantPast)
    }
}

// MARK: - Which threads are important

/// Which threads get a summary by themselves. A thread is important when any of these holds:
/// - **Starred**: the user starred the item (in Docket, Gmail or Slack).
/// - **Long**: it has 5 or more messages (replies sent from Docket a moment ago don't count yet).
/// - **Waiting on you**: its newest message isn't the user's, the user hasn't replied from Docket since, and
///   either it came in because it asks for the user (an @mention, an email waiting for a reply) or the user
///   wrote earlier in the thread, so the newest message answers them.
///
/// Before the thread is loaded, only the item itself counts (one message). Pure, so it's easy to test.
enum ThreadImportance {
    enum Reason: String, Equatable, CaseIterable {
        case starred, longThread, waitingOnYou
    }

    static let longThread = 5

    /// One message as importance and fingerprints see it.
    struct Entry: Equatable {
        var id: String
        var date: Date
        var isMine: Bool
    }

    static func reasons(_ s: Suggestion, thread: InboxThread?) -> [Reason] {
        var reasons: [Reason] = []
        if s.isStarred { reasons.append(.starred) }
        if messageCount(s, thread: thread) >= longThread { reasons.append(.longThread) }
        if waitingOnYou(s, thread: thread) { reasons.append(.waitingOnYou) }
        return reasons
    }

    static func isImportant(_ s: Suggestion, thread: InboxThread?) -> Bool {
        !reasons(s, thread: thread).isEmpty
    }

    /// The thread's messages oldest first; the item alone while the thread isn't loaded.
    static func entries(_ s: Suggestion, thread: InboxThread?) -> [Entry] {
        switch thread {
        case .slack(let messages, _)? where !messages.isEmpty:
            return messages.map { Entry(id: $0.id, date: $0.date, isMine: $0.isMine) }
        case .email(let emails, _)? where !emails.isEmpty:
            return emails.map { Entry(id: $0.id, date: $0.date, isMine: $0.isMine) }
        default:
            return [Entry(id: InboxThread.bareMessageID(s.id), date: s.receivedAt, isMine: false)]
        }
    }

    /// Messages as Slack or Gmail lists them (not replies sent from Docket a moment ago).
    static func messageCount(_ s: Suggestion, thread: InboxThread?) -> Int {
        entries(s, thread: thread).filter { !InboxThread.isSentFromDocket($0.id) }.count
    }

    static func waitingOnYou(_ s: Suggestion, thread: InboxThread?) -> Bool {
        let all = entries(s, thread: thread)
        // A reply that just went out from Docket is the user's.
        guard let newest = all.last, !newest.isMine else { return false }
        if let replied = s.repliedAt, replied >= newest.date { return false }
        if s.trigger == .needsReply || s.trigger == .mention { return true }
        return all.dropLast().contains { $0.isMine }
    }

    /// Which version of the thread a summary is about: its messages (by id) as Slack or Gmail lists them.
    /// A new message (or one deleted) gives another fingerprint.
    static func fingerprint(_ s: Suggestion, thread: InboxThread?) -> String {
        let ids = entries(s, thread: thread).map(\.id).filter { !InboxThread.isSentFromDocket($0) }
        return "\(ids.count)-" + stableHash(ids.joined(separator: "|"))
    }
}

// MARK: - Writing one

/// Everything AI gets to summarize a thread.
struct SummaryRequest {
    /// The email's subject, or where the Slack message was posted ("#leadership").
    var title: String
    var kind: TaskSource.Kind
    /// The thread, oldest first, the user's own marked `isMine`.
    var messages: [ThreadMessage]
    var myName: String?
}

/// The AI step that summarizes a thread. Tests swap in a fake.
struct ThreadSummarizer {
    var isAvailable: @MainActor () -> Bool
    var summarize: @MainActor (SummaryRequest) async throws -> SummaryText

    static var gemini: ThreadSummarizer {
        ThreadSummarizer(isAvailable: { AIService.shared.isConfigured },
                         summarize: { r in
                             try await AIService.shared.summarizeThread(title: r.title, kind: r.kind, messages: r.messages, myName: r.myName)
                         })
    }

    /// No AI: no summaries.
    static var none: ThreadSummarizer {
        ThreadSummarizer(isAvailable: { false }, summarize: { _ in throw AIError.notConfigured })
    }
}

// MARK: - Integrations

extension Integrations {
    /// After a check, at most this many of the newest important items are summarized in the background…
    static let backgroundSummaryLimit = 5
    /// …and at most this often.
    static let backgroundSummaryInterval: TimeInterval = 10 * 60

    /// Whether summaries show: AI is on with a key (screenshot mode shows its samples).
    var showsSummaries: Bool { DebugSnapshot.isActive || summarizer.isAvailable() }

    /// The item's summary, as made last (it may be about an older version of the thread: `summaryIsCurrent`).
    func summary(for id: String) -> ThreadSummary? {
        threadSummaries[id]
    }

    /// Whether the item's thread is important (`ThreadImportance`), as far as Docket knows it now.
    func isImportant(_ id: String) -> Bool {
        guard let s = suggestion(id) else { return false }
        return ThreadImportance.isImportant(s, thread: wholeThreads[id])
    }

    /// The summary is about the thread as it is now (or the thread isn't loaded, so there's nothing newer).
    func summaryIsCurrent(_ id: String) -> Bool {
        guard let s = suggestion(id), let summary = threadSummaries[id] else { return false }
        guard let thread = wholeThreads[id] else { return true }
        return summary.fingerprint == ThreadImportance.fingerprint(s, thread: thread)
    }

    /// When the item is opened: an important thread is summarized (again, when it changed since). Others wait
    /// for "Summarize".
    func summarizeIfImportant(_ id: String) async {
        guard showsSummaries, !DebugSnapshot.isActive, isImportant(id), !summaryIsCurrent(id) else { return }
        await summarize(id)
    }

    /// Summarizes the item's thread (loading it if needed) and keeps the summary. Without `force`, a summary
    /// of the thread as it is now is kept as it is. Asking again while one is being written waits for it. A
    /// problem is kept in `summaryProblems` (nil back) for the card to show.
    @discardableResult
    func summarize(_ id: String, force: Bool = false) async -> ThreadSummary? {
        guard summarizer.isAvailable(), !DebugSnapshot.isActive, suggestion(id) != nil else { return nil }
        if let running = inbox.summaryLoads[id] { return await running.value }
        let task = Task { @MainActor [weak self] () -> ThreadSummary? in
            await self?.writeSummary(id, force: force)
        }
        inbox.summaryLoads[id] = task
        summarizing.insert(id)
        summaryProblems[id] = nil
        let summary = await task.value
        inbox.summaryLoads[id] = nil
        summarizing.remove(id)
        return summary
    }

    private func writeSummary(_ id: String, force: Bool) async -> ThreadSummary? {
        // The whole thread when it can be had; the message alone otherwise (offline, a missing permission).
        let thread = try? await fullThread(for: id, reload: false)
        guard let s = suggestion(id) else { return nil }
        let fingerprint = ThreadImportance.fingerprint(s, thread: thread)
        if !force, let known = threadSummaries[id], known.fingerprint == fingerprint { return known }
        let messages = thread.map(\.forReplyContext) ?? [ownMessageForSummary(s)]
        let request = SummaryRequest(title: Self.summaryTitle(s), kind: s.source.kind, messages: messages, myName: summaryName(for: s.source.kind))
        do {
            let text = try await summarizer.summarize(request)
            guard suggestion(id) != nil else { return nil }
            let summary = ThreadSummary(text, fingerprint: fingerprint, madeAt: Date())
            threadSummaries[id] = summary
            save()
            return summary
        } catch {
            if !(error is CancellationError) {
                summaryProblems[id] = (error as? LocalizedError)?.errorDescription ?? "Couldn't summarize it. Try again."
            }
            return nil
        }
    }

    /// The item's own message, for a summary of a thread that couldn't be loaded.
    private func ownMessageForSummary(_ s: Suggestion) -> ThreadMessage {
        let whole = s.content?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let text = s.source.kind == .gmail ? MailQuote.trimmed(whole) : whole
        return ThreadMessage(id: InboxThread.bareMessageID(s.id), from: s.replyHeaders?.from ?? s.from, date: s.receivedAt,
                             text: text.isEmpty ? s.snippet : text, isMine: false)
    }

    /// The email's subject, or where the Slack message was posted.
    static func summaryTitle(_ s: Suggestion) -> String {
        switch s.source.kind {
        case .gmail: MailText.cleanSubject(s.subject ?? "")
        case .slack, .ai: InboxText.place(of: s)
        }
    }

    /// The user's name, so AI can tell their messages apart: their name in Slack, or the Mac account's.
    private func summaryName(for kind: TaskSource.Kind) -> String? {
        if kind == .slack, let me = slackAccount, let name = slackNames[me.userID], !name.isEmpty { return name }
        let name = fullName().trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    // MARK: In the background

    /// The items a background pass summarizes: the newest important ones (as far as Docket knows them) without
    /// a summary, or whose loaded thread has changed since theirs. At most `limit`. Pure, so it's easy to test.
    static func backgroundSummaryCandidates(_ items: [Suggestion], threads: [String: InboxThread],
                                            summaries: [String: ThreadSummary], limit: Int? = nil) -> [String] {
        let important = items.filter { ThreadImportance.isImportant($0, thread: threads[$0.id]) }
            .sorted { ($0.receivedAt, $0.id) > ($1.receivedAt, $1.id) }
            .prefix(limit ?? backgroundSummaryLimit)
        return important.compactMap { s in
            guard let known = summaries[s.id] else { return s.id }
            guard let thread = threads[s.id] else { return nil }
            return known.fingerprint == ThreadImportance.fingerprint(s, thread: thread) ? nil : s.id
        }
    }

    /// After a check: summarizes the newest important items in the background, one at a time, at most every
    /// ten minutes. Never in screenshot mode, and never without AI.
    func summarizeImportantInBackground(now: Date = Date()) {
        guard inbox.backgroundSummaries == nil, summarizer.isAvailable(), !DebugSnapshot.isActive else { return }
        if let last = inbox.lastBackgroundSummaries, now.timeIntervalSince(last) < Self.backgroundSummaryInterval { return }
        let picks = Self.backgroundSummaryCandidates(suggestions, threads: wholeThreads, summaries: threadSummaries)
        guard !picks.isEmpty else { return }
        inbox.lastBackgroundSummaries = now
        inbox.backgroundSummaries = Task { @MainActor [weak self] in
            for id in picks {
                guard let self, !Task.isCancelled, self.summarizer.isAvailable() else { break }
                await self.summarize(id)
            }
            self?.inbox.backgroundSummaries = nil
        }
    }

    /// Waits for a background pass that's running (tests).
    func waitForBackgroundSummaries() async {
        await inbox.backgroundSummaries?.value
    }

    /// Summaries of items still in the inbox (what's saved).
    var summariesToKeep: [String: ThreadSummary] {
        let ids = Set(suggestions.map(\.id))
        return threadSummaries.filter { ids.contains($0.key) }
    }
}
