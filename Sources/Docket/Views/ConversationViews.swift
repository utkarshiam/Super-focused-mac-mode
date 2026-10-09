import AppKit
import SwiftUI

// The open message's whole Slack thread or email conversation, shown as a conversation: every message oldest
// first, the inbox's own one highlighted and brought into view, each with its own files, a star, and a Reply
// that points the composer at it. Replies sent from Docket show at the end at once. Stars anywhere in the
// inbox (the list, the header, a message of a thread) go through `InboxStarring`.

// MARK: - Rules (pure, so they're easy to test)

/// How a thread or conversation is laid out.
enum ThreadLayout {
    /// At most this many messages show above the inbox's own one until "Show N earlier" is clicked.
    static let earlierShown = 20

    /// How many messages at the start wait behind "Show N earlier".
    static func hiddenEarlier(highlighted: Int?, showAll: Bool, limit: Int = earlierShown) -> Int {
        guard let highlighted, !showAll else { return 0 }
        return max(0, highlighted - limit)
    }

    /// The message the conversation highlights: the inbox's own one, when there's more than it to see.
    static func highlight(_ index: Int, count: Int) -> Int? {
        count > 1 && (0..<count).contains(index) ? index : nil
    }

    /// The newest message of the conversation as Gmail has it: replies that just went out from Docket don't
    /// count (so the email they answered stays open). Nil for none.
    static func newest(_ ids: [String]) -> Int? {
        ids.lastIndex { !InboxThread.isSentFromDocket($0) } ?? (ids.isEmpty ? nil : ids.count - 1)
    }

    /// Whether an email of the conversation shows open: the newest, the inbox's own one and replies that just
    /// went out from Docket do; the others show as one line. Clicking one opens or closes it (`toggled`).
    static func isOpen(_ id: String, at index: Int, newest: Int?, highlighted: Int?, toggled: [String: Bool]) -> Bool {
        if let open = toggled[id] { return open }
        return index == newest || index == highlighted || InboxThread.isSentFromDocket(id)
    }

    /// Whether a message shows its day as well as its time: the first one shown does, and one written on
    /// another day than the message above it.
    static func showsDay(_ date: Date, after previous: Date?, calendar: Calendar = .current) -> Bool {
        guard let previous else { return true }
        return !calendar.isDate(date, inSameDayAs: previous)
    }
}

/// What the conversation says about its messages.
enum ThreadText {
    /// "P" for Priya Shah, "S" for sam@northwind.example; "?" with nothing to go on.
    static func initial(of name: String) -> String {
        name.first { $0.isLetter || $0.isNumber }.map { String($0).uppercased() } ?? "?"
    }

    /// "Priya" from "Priya Shah"; a name that's one word (or an address) stays whole.
    static func firstName(_ name: String) -> String {
        let words = name.split(whereSeparator: \.isWhitespace)
        guard let first = words.first, first.contains(where: \.isLetter) else { return name }
        return String(first)
    }

    /// The eyebrow over the messages: "Thread · 6 messages", "Conversation · 4 messages", or "Message".
    static func title(_ kind: TaskSource.Kind, count: Int) -> String {
        guard count > 1 else { return "Message" }
        return (kind == .gmail ? "Conversation" : "Thread") + " · \(count) messages"
    }

    /// "Show 4 earlier messages".
    static func showEarlier(_ count: Int) -> String {
        count == 1 ? "Show 1 earlier message" : "Show \(count) earlier messages"
    }

    /// "10:42 AM" for a message from `now`'s day, "Fri 2 Oct · 9:15 AM" for any other.
    static func when(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        calendar.isDate(date, inSameDayAs: now) ? Fmt.time(date) : Fmt.due(date, hasTime: true, now: now)
    }

    /// Who a message is from, for "Replying to …": "Priya", or "your message" for the user's own.
    static func replyingToName(_ name: String, isMine: Bool) -> String {
        isMine ? "your message" : firstName(name)
    }

    /// "Replying to Priya · 10:42 AM", "Replying to your message · Fri 2 Oct · 9:15 AM".
    static func replyingTo(_ name: String, isMine: Bool, at date: Date, now: Date, calendar: Calendar = .current) -> String {
        "Replying to \(replyingToName(name, isMine: isMine)) · \(when(date, now: now, calendar: calendar))"
    }

    /// The line a Slack reply starts with to quote the message it answers: "> " and the message's first
    /// words on one line (cut at a word). Nil when the message has no words.
    static func quoteLine(_ text: String, limit: Int = 140) -> String? {
        let words = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !words.isEmpty else { return nil }
        return "> " + ReplyText.preview(words, limit: limit)
    }

    /// The reply with `quote` as its first line.
    static func adding(quote: String, to text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? quote + "\n" : quote + "\n" + text
    }

    /// The reply without the quote line Docket put at its top. Left as it is when the user changed that line.
    static func removing(quote: String, from text: String) -> String {
        guard text.hasPrefix(quote) else { return text }
        var rest = text.dropFirst(quote.count)
        if rest.first == "\n" { rest = rest.dropFirst() }
        return String(rest)
    }

    /// Who wrote a Slack message, by name: "You" for the user's own; a user id is looked up in `names`.
    static func sender(of m: ThreadSlackMessage, names: [String: String]) -> String {
        if m.isMine { return "You" }
        if let id = m.userID, let name = names[id], !name.isEmpty { return name }
        if InboxText.isSlackUserID(m.from), let name = names[m.from], !name.isEmpty { return name }
        let from = m.from.trimmingCharacters(in: .whitespacesAndNewlines)
        return from.isEmpty ? "Someone" : from
    }

    /// Who wrote an email, by name: "You" for the user's own.
    static func sender(of e: ThreadEmail) -> String {
        e.isMine ? "You" : MailSender(header: e.from).displayName
    }

    /// The sender's address, shown next to their name ("sam@northwind.example"); nil for the user's own
    /// emails and when the name is the address.
    static func address(of e: ThreadEmail) -> String? {
        guard !e.isMine else { return nil }
        let sender = MailSender(header: e.from)
        guard let address = sender.address, sender.name != nil else { return nil }
        return address
    }

    /// Who an email went to, as its headers say: To, then Cc.
    static func recipientEntries(of e: ThreadEmail) -> [String] {
        e.content.to.isEmpty && e.content.cc.isEmpty ? e.replyHeaders.to + e.replyHeaders.cc : e.content.to + e.content.cc
    }

    /// "to you, Lena Park": who an email went to, To then Cc, by name; the user's own address is "you".
    /// Nil when it names nobody.
    static func recipients(of e: ThreadEmail, myAddress: String?) -> String? {
        let me = myAddress.map { MailReplyBuilder.mailbox($0) }
        var seen = Set<String>()
        let names = recipientEntries(of: e).flatMap(MailSender.list).compactMap { sender -> String? in
            let key = (sender.address ?? sender.displayName).lowercased()
            guard seen.insert(key).inserted else { return nil }
            if let me, let address = sender.address, MailReplyBuilder.mailbox(address) == me { return "you" }
            return sender.displayName
        }
        return names.isEmpty ? nil : "to " + names.joined(separator: ", ")
    }

    /// One line of an email for its collapsed row: Gmail's snippet, or the start of its text.
    static func snippet(of e: ThreadEmail) -> String {
        let snippet = e.snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        if !snippet.isEmpty { return SlackText.collapsed(snippet) }
        return SlackText.collapsed(String(MailQuote.trimmed(e.content.text).prefix(400)))
    }
}

// MARK: - Stars

/// Starring from the inbox: the list (☆ and S), the open message's header, and each message of its thread.
/// The star changes at once; Integrations takes it to Gmail or Slack, puts it back when that fails and says
/// why (`starProblem(for:message:)`), or keeps it in Docket when Slack or the Gmail sign-in won't take stars.
@MainActor
enum InboxStarring {
    /// Stars the item, or unstars it.
    static func toggle(item id: String, integrations: Integrations? = nil) {
        let integrations = integrations ?? .shared
        guard let s = integrations.suggestion(id) else { return }
        Haptics.select()
        Task { await integrations.setStarred(!s.isStarred, for: id) }
    }

    /// Stars or unstars one message of the item's thread (the item's own message is the item).
    static func toggle(message: String, in itemID: String, integrations: Integrations? = nil) {
        let integrations = integrations ?? .shared
        let starred = integrations.isStarred(message: message, in: itemID)
        Haptics.select()
        Task { await integrations.setStarred(!starred, message: message, in: itemID) }
    }
}

// MARK: - The conversation behind the open message

/// The open message's whole thread or conversation, and what the detail does with it: which message the
/// reply answers, and which emails are open. One per open message.
@MainActor
final class ConversationModel: ObservableObject {
    enum Phase: Equatable {
        /// Not asked for yet: the message opened a moment ago (arrowing past messages doesn't fetch each thread).
        case waiting
        case loading
        case loaded
        /// Slack won't show the thread until the Docket app there can read message history.
        case needsPermission
        case failed(String)
    }

    let itemID: String
    private let integrations: Integrations

    @Published private(set) var phase: Phase = .waiting
    /// The thread as it was loaded here (Integrations doesn't keep a conversation of one it got for want of
    /// a Slack permission).
    @Published private(set) var loaded: InboxThread?
    @Published private(set) var reloading = false
    /// Loading it again didn't work; what was there stays.
    @Published private(set) var reloadProblem: String?
    /// The message the reply answers (a `ThreadSlackMessage` or `ThreadEmail` id); nil: the default one
    /// (Slack: the thread; email: the newest message that isn't the user's).
    @Published var target: String?
    /// Bumped when a message's Reply is clicked: the detail brings the composer into view and it takes the keyboard.
    @Published private(set) var composerRequests = 0
    /// Emails opened or closed by a click (the others follow `ThreadLayout.isOpen`).
    @Published var toggled: [String: Bool] = [:]
    /// Emails showing their quoted history.
    @Published var untrimmed: Set<String> = []
    /// "Show N earlier" was clicked.
    @Published var showsEarlier = false
    /// The open message was brought into view (once, when the thread first shows).
    var revealed = false
    /// Saves one message of the thread (its id) as a note: set by the detail.
    var saveAsNote: ((String) -> Void)?

    /// How long the message has to stay open before its thread is fetched.
    static let settle: UInt64 = 200_000_000

    /// `integrations`: the app's (`Integrations.shared`) unless a test gives its own.
    init(itemID: String, integrations: Integrations? = nil) {
        self.itemID = itemID
        self.integrations = integrations ?? .shared
    }

    private var service: IntegrationError.Service { itemID.hasPrefix("gmail:") ? .gmail : .slack }

    /// The thread as it shows: Integrations' copy for the session (with replies just sent and stars as they
    /// change), else the one loaded here. The views watch Integrations, so they follow it.
    var thread: InboxThread? { integrations.wholeThreads[itemID] ?? loaded }

    // MARK: Loading

    /// Loads the thread a moment after the message opens; at once when Integrations has it for the session.
    func start() async {
        guard loaded == nil, phase == .waiting else { return }
        if integrations.wholeThreads[itemID] == nil {
            try? await Task.sleep(nanoseconds: Self.settle)
            guard !Task.isCancelled else { return }
        }
        await load(reload: false)
    }

    /// Loads the thread; `reload` asks Slack or Gmail again.
    func load(reload: Bool) async {
        if reload {
            guard !reloading else { return }
            reloading = true
            reloadProblem = nil
        } else if loaded == nil {
            phase = .loading
        }
        do {
            apply(try await integrations.fullThread(for: itemID, reload: reload))
        } catch {
            fail(error)
        }
        if reload { reloading = false }
    }

    private func apply(_ fresh: InboxThread) {
        loaded = fresh
        phase = .loaded
        reloadProblem = nil
        // A message picked to reply to that's gone: back to the default.
        if let target, !fresh.allMessageIDs.contains(target) { self.target = nil }
    }

    private func fail(_ error: Error) {
        let e = IntegrationError.wrap(error, service)
        if e == .cancelled {
            if loaded == nil { phase = .waiting }
            return
        }
        guard loaded == nil else {
            reloadProblem = e.errorDescription
            return
        }
        if case .missingPermission(.slack, _) = e {
            phase = .needsPermission
        } else {
            phase = .failed(e.errorDescription ?? "Something went wrong. Try again.")
        }
    }

    // MARK: Replying

    /// Points the composer at this message (and brings it into view).
    func reply(to id: String) {
        target = id
        composerRequests += 1
    }

    /// Brings out the composer (and into view) without changing which message it answers: the detail's Reply.
    func requestComposer() {
        composerRequests += 1
    }

    /// The Slack message picked to reply to.
    var pickedSlack: ThreadSlackMessage? {
        guard let target, case .slack(let messages, _)? = thread else { return nil }
        return messages.first { $0.id == target }
    }

    /// The email picked to reply to.
    var pickedEmail: ThreadEmail? {
        guard let target, case .email(let emails, _)? = thread else { return nil }
        return emails.first { $0.id == target }
    }

    /// The email a reply answers: the one picked, else the conversation's default (its newest message that
    /// isn't the user's). Nil until the conversation is in.
    var replyEmail: ThreadEmail? {
        guard case .email(let emails, _)? = thread else { return nil }
        if let picked = pickedEmail { return picked }
        guard let id = thread?.defaultReplyMessageID else { return nil }
        return emails.first { $0.id == id }
    }

    /// The message the composer names and AI answers: the one picked; for an email, the conversation's
    /// default once it's in. Nil leaves it to Integrations (Slack: the thread; an email whose conversation
    /// isn't in yet: its default once it's loaded).
    var replyingTo: String? {
        switch thread {
        case .email?: replyEmail?.id
        case .slack?: pickedSlack?.id
        case nil: nil
        }
    }

    /// What a send or a saved draft passes as `replyingTo`, taken when the user asks: `replyingTo`, or for an
    /// email whose conversation isn't in yet, the email itself (what the composer and the confirmation name
    /// then). So a conversation that arrives while the confirmation is up can't change who the reply goes to.
    var sendTarget: String? {
        if let target = replyingTo { return target }
        guard thread == nil, let ids = InboxIDs.gmail(itemID) else { return nil }
        return ids.message
    }

    /// A reply went out (Integrations shows it in the thread): the next one answers the default message again,
    /// and the emails open now stay open once the reply arrives as the conversation's newest.
    func didSend() {
        target = nil
        guard case .email(let emails, let h)? = thread else { return }
        let ids = emails.map(\.id)
        let newest = ThreadLayout.newest(ids), highlighted = ThreadLayout.highlight(h, count: emails.count)
        for (i, id) in ids.enumerated() where !InboxThread.isSentFromDocket(id)
            && ThreadLayout.isOpen(id, at: i, newest: newest, highlighted: highlighted, toggled: toggled) {
            toggled[id] = true
        }
    }
}

// MARK: - Pieces

/// A round initial: the user's own messages in ink, everyone else's on a soft fill.
struct InboxAvatar: View {
    let name: String
    let isMine: Bool
    var size: CGFloat = 28

    var body: some View {
        Text(ThreadText.initial(of: name))
            .font(.system(size: size * 0.43, weight: .semibold))
            .foregroundStyle(isMine ? Color.onPrimary : Color.ink)
            .frame(width: size, height: size)
            .background(Circle().fill(isMine ? Color.primaryFill : Color.fillStrong))
            .accessibilityHidden(true)
    }
}

/// ☆ / ★. A filled star in ink; it pops when it's set.
struct StarButton: View {
    let isOn: Bool
    var size: CGFloat = 26
    var iconSize: CGFloat = 12.5
    var filled = false
    /// The tooltip; "Star" / "Unstar" by default.
    var help: String?
    let action: () -> Void
    @State private var pop = false

    var body: some View {
        Button {
            if !isOn {
                withAnimation(Motion.instant) { pop = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) {
                    withAnimation(Motion.bouncy) { pop = false }
                }
            }
            action()
        } label: {
            Image(systemName: isOn ? "star.fill" : "star")
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(isOn ? Color.ink : Color.ink3)
                .scaleEffect(pop ? 1.3 : 1)
                .animation(Motion.bouncy, value: isOn)
        }
        .buttonStyle(IconButtonStyle(size: size, filled: filled))
        .help(help ?? (isOn ? "Unstar" : "Star"))
        .accessibilityLabel(isOn ? "Unstar" : "Star")
    }
}

/// Why a star didn't take: a small warning line.
private struct StarProblemLine: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(Color.ink2)
            .labelStyle(WarningLabelStyle())
            .fixedSize(horizontal: false, vertical: true)
            .transition(.opacity)
    }
}

/// A label whose icon is the warning colour.
private struct WarningLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            configuration.icon
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.warning)
            configuration.title
        }
    }
}

/// The star and Reply on a message of the thread: shown while the pointer is over it (a star that's set
/// always shows).
private struct MessageActions: View {
    let isStarred: Bool
    let shown: Bool
    let star: () -> Void
    let reply: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            StarButton(isOn: isStarred, size: 24, iconSize: 11.5, action: star)
                .opacity(isStarred || shown ? 1 : 0)
                .allowsHitTesting(isStarred || shown)
            Button(action: reply) {
                Image(systemName: "arrowshape.turn.up.left")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color.ink2)
            }
            .buttonStyle(IconButtonStyle(size: 24))
            .help("Reply to this message")
            .accessibilityLabel("Reply to this message")
            .opacity(shown ? 1 : 0)
            .allowsHitTesting(shown)
        }
        .animation(Motion.fast, value: shown)
    }
}

/// "Show 4 earlier messages".
private struct ShowEarlierButton: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(ThreadText.showEarlier(count), systemImage: "chevron.up")
        }
        .buttonStyle(SecondaryPill(height: 28))
        .help("Show the start of the thread")
        .padding(.vertical, Space.xs)
    }
}

/// "…": shows or hides an email's quoted history.
private struct QuoteToggle: View {
    @Binding var shown: Bool

    var body: some View {
        Button { withAnimation(Motion.base) { shown.toggle() } } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.ink2)
                .frame(width: 32, height: 16)
                .background(Capsule().fill(Color.fill))
                .contentShape(Capsule())
        }
        .buttonStyle(PressScale(scale: 0.95))
        .help(shown ? "Hide the quoted text" : "Show the quoted text")
        .accessibilityLabel(shown ? "Hide the quoted text" : "Show the quoted text")
    }
}

// MARK: - The section

/// The messages part of the open message: its whole thread or conversation once it's in (the message alone
/// until then, or when it can't be loaded), with a refresh button and, for email, the Plain text switch.
struct ConversationSection: View {
    @ObservedObject var conversation: ConversationModel
    @ObservedObject private var integrations = Integrations.shared
    @AppStorage(InboxDetail.plainTextKey) private var plainText = false

    let item: Suggestion
    /// The item's own message (what shows until the thread is in).
    let content: MessageContent?
    let contentLoading: Bool
    let contentProblem: String?
    let retryContent: () -> Void
    let quickLook: QuickLookController
    let paneHeight: CGFloat
    let updateSlack: () -> Void
    /// Brings a message into view (the detail scrolls to it).
    let reveal: (String) -> Void

    /// The scroll id of a message's row.
    static func rowID(_ message: String) -> String { "message:" + message }

    private enum Shown {
        case slack([ThreadSlackMessage], highlighted: Int?)
        case email([ThreadEmail], highlighted: Int?)
        /// The whole message isn't in yet: its preview.
        case preview
    }

    private var isEmail: Bool { item.source.kind == .gmail }

    /// The thread once it's in; until then (or when it can't be loaded), the item's own message alone,
    /// highlighted when it's known to answer others in a thread (as it is when Slack won't give the rest).
    private var shown: Shown {
        let reply = InboxItemText.isThreadReply(item)
        switch conversation.thread {
        case .slack(let messages, let index)? where !messages.isEmpty:
            return .slack(messages, highlighted: ThreadLayout.highlight(index, count: messages.count) ?? (reply && messages.count == 1 ? 0 : nil))
        case .email(let emails, let index)? where !emails.isEmpty:
            return .email(emails, highlighted: ThreadLayout.highlight(index, count: emails.count))
        default:
            break
        }
        guard let content else { return .preview }
        switch item.source.kind {
        case .gmail:
            return .email([ConversationStandIns.email(item, content: content, myAddress: integrations.gmailAddress)], highlighted: nil)
        case .slack, .ai:
            return .slack([ConversationStandIns.slack(item, content: content)], highlighted: reply ? 0 : nil)
        }
    }

    private var count: Int {
        switch shown {
        case .slack(let messages, _): return messages.count
        case .email(let emails, _): return emails.count
        case .preview: return 1
        }
    }

    /// The thread can't show until the Docket app in Slack can read message history.
    private var needsPermission: Bool {
        if conversation.phase == .needsPermission { return true }
        return InboxItemText.isThreadReply(item) && conversation.phase != .loading
            && !integrations.missingSlackScopes.isDisjoint(with: InboxItemText.historyScopes)
            && (conversation.thread.map { $0.allMessageIDs.count <= 1 } ?? true)
    }

    var body: some View {
        let shown = self.shown
        VStack(alignment: .leading, spacing: Space.md) {
            headerRow
            status
            switch shown {
            case .slack(let messages, let highlighted):
                SlackThreadView(conversation: conversation, item: item, messages: messages, highlighted: highlighted,
                                isStandIn: conversation.thread == nil, quickLook: quickLook, filesBlocked: filesBlocked,
                                updateSlack: updateSlack)
            case .email(let emails, let highlighted):
                EmailConversationView(conversation: conversation, item: item, emails: emails, highlighted: highlighted,
                                      isStandIn: conversation.thread == nil, quickLook: quickLook, paneHeight: paneHeight)
            case .preview:
                preview
            }
            if filesBlocked, hasFiles(shown) { filesNote }
        }
        .animation(Motion.base, value: conversation.phase)
        .task(id: item.id) { await conversation.start() }
        .onChange(of: conversation.phase) { phase in
            guard phase == .loaded else { return }
            revealHighlighted()
        }
    }

    // MARK: Header and status

    /// The eyebrow, Plain text (an icon when the pane is narrow) and refresh, on one line.
    private var headerRow: some View {
        ViewThatFits(in: .horizontal) {
            headerRow(compact: false)
            headerRow(compact: true)
        }
        .frame(minHeight: 26)
    }

    private func headerRow(compact: Bool) -> some View {
        HStack(alignment: .center, spacing: Space.sm) {
            Eyebrow(text: ThreadText.title(item.source.kind, count: count))
                .lineLimit(1)
                .fixedSize(horizontal: !compact, vertical: false)
            Spacer(minLength: Space.sm)
            if isEmail, hasHTML {
                Button { withAnimation(Motion.base) { plainText.toggle() } } label: {
                    if compact {
                        Image(systemName: plainText ? "checkmark" : "text.alignleft")
                            .font(.system(size: 11.5, weight: .semibold))
                    } else {
                        Label("Plain text", systemImage: plainText ? "checkmark" : "text.alignleft")
                    }
                }
                .modifier(PlainTextButtonStyle(compact: compact))
                .help(plainText ? "Show emails formatted again" : "Show emails as plain text")
                .accessibilityLabel("Plain text")
            }
            reloadButton
        }
    }

    @ViewBuilder
    private var reloadButton: some View {
        if conversation.phase == .loading || conversation.reloading {
            ProgressView()
                .controlSize(.small)
                .frame(width: 26, height: 26)
                .help(isEmail ? "Loading the whole conversation" : "Loading the whole thread")
        } else if conversation.phase != .waiting {
            Button { Task { await conversation.load(reload: true) } } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .buttonStyle(IconButtonStyle(size: 26))
            .help(isEmail ? "Load the conversation again from Gmail" : "Load the thread again from Slack")
            .accessibilityLabel("Refresh")
        }
    }

    @ViewBuilder
    private var status: some View {
        if needsPermission {
            InlineNote(icon: "lock", text: "Docket needs permission to read threads.") {
                Button("Update the app", action: updateSlack)
                    .buttonStyle(SecondaryPill(height: 26))
                    .help("Create the Docket app in Slack again with the new permissions")
            }
        } else if case .failed(let message) = conversation.phase, !DebugSnapshot.isActive {
            InlineNote(icon: "exclamationmark.triangle.fill", warning: true,
                       text: "Couldn't load the whole \(isEmail ? "conversation" : "thread"). \(message)") {
                Button("Retry") { Task { await conversation.load(reload: false) } }
                    .buttonStyle(SecondaryPill(height: 26))
                    .help("Try loading it again")
            }
        } else if let problem = conversation.reloadProblem, !DebugSnapshot.isActive {
            InlineNote(icon: "exclamationmark.triangle.fill", warning: true, text: "Couldn't refresh it. \(problem)") { EmptyView() }
        }
    }

    // MARK: The message alone, before it's in

    private var preview: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            LinkedTextView(text: item.snippet, color: .ink2)
            if contentLoading {
                HStack(spacing: Space.sm) {
                    ProgressView().controlSize(.small)
                    Text("Loading the whole message…").textStyle(.footnote).foregroundStyle(Color.ink2)
                }
            } else if let contentProblem, !DebugSnapshot.isActive {
                InlineNote(icon: "exclamationmark.triangle.fill", warning: true, text: "Showing the preview. \(contentProblem)") {
                    Button("Retry", action: retryContent)
                        .buttonStyle(SecondaryPill(height: 26))
                        .help("Try loading the whole message again")
                }
            }
        }
    }

    // MARK: Files Slack won't give yet

    /// Slack without files:read: files show by name and open in Slack.
    private var filesBlocked: Bool {
        item.source.kind == .slack && integrations.missingSlackScopes.contains(InboxItemText.filesScope)
    }

    private func hasFiles(_ shown: Shown) -> Bool {
        if case .slack(let messages, _) = shown { return messages.contains { !$0.files.isEmpty } }
        return false
    }

    private var filesNote: some View {
        InlineNote(icon: "lock", text: "Files open in Slack until the Docket app there has one more permission.") {
            Button("Update the app", action: updateSlack)
                .buttonStyle(SecondaryPill(height: 26))
                .help("Create the Docket app in Slack again with the new permissions")
        }
    }

    private var hasHTML: Bool {
        switch conversation.thread {
        case .email(let emails, _)?:
            return emails.contains { $0.content.html.map(MailHTML.hasContent) ?? false }
        default:
            return content?.html.map(MailHTML.hasContent) ?? false
        }
    }

    /// Once, when the thread first shows: the inbox's own message comes into view, unless it's the first one
    /// shown (already in view under the header).
    private func revealHighlighted() {
        guard !conversation.revealed else { return }
        conversation.revealed = true
        let highlighted: (id: String, index: Int)?
        switch shown {
        case .slack(let messages, let h?): highlighted = (messages[h].id, h)
        case .email(let emails, let h?): highlighted = (emails[h].id, h)
        default: highlighted = nil
        }
        guard let highlighted else { return }
        let first = ThreadLayout.hiddenEarlier(highlighted: highlighted.index, showAll: conversation.showsEarlier)
        guard highlighted.index > first else { return }
        let id = Self.rowID(highlighted.id)
        Task { @MainActor in
            // After the thread is laid out.
            try? await Task.sleep(nanoseconds: 80_000_000)
            reveal(id)
        }
    }
}

/// The Plain text switch: a pill with its name, or an icon where there's no room for one.
private struct PlainTextButtonStyle: ViewModifier {
    let compact: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if compact {
            content.buttonStyle(IconButtonStyle(size: 26, filled: true))
        } else {
            content.buttonStyle(SecondaryPill(height: 26))
        }
    }
}

/// A calm line in the conversation: an icon, what's up, and what to do about it.
private struct InlineNote<Trailing: View>: View {
    let icon: String
    var warning = false
    let text: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: Space.sm) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(warning ? Color.warning : Color.ink3)
            Text(text)
                .textStyle(.footnote)
                .foregroundStyle(Color.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Space.sm)
            trailing
        }
        .transition(.opacity)
    }
}

/// The item's own message as a message of its thread, to show until the thread is in.
enum ConversationStandIns {
    static func slack(_ item: Suggestion, content: MessageContent) -> ThreadSlackMessage {
        ThreadSlackMessage(id: InboxIDs.slack(item.id)?.ts ?? item.id, from: item.from, userID: nil, date: item.receivedAt,
                           markup: content.markup ?? "", text: content.text, files: content.attachments, isMine: false)
    }

    static func email(_ item: Suggestion, content: MessageContent, myAddress: String?) -> ThreadEmail {
        let headers = item.replyHeaders ?? MailReplyHeaders(subject: item.subject ?? "", from: item.from, to: content.to, cc: content.cc)
        let from = MailSender(header: headers.from).address.map(MailReplyBuilder.mailbox)
        let isMine = from != nil && from == myAddress.map(MailReplyBuilder.mailbox)
        return ThreadEmail(id: InboxIDs.gmail(item.id)?.message ?? item.id, from: headers.from, date: item.receivedAt, content: content,
                           replyHeaders: headers, isMine: isMine, isStarred: item.isStarred, snippet: item.snippet)
    }
}

// MARK: - A Slack thread

private struct SlackThreadView: View {
    @ObservedObject var conversation: ConversationModel
    @ObservedObject private var integrations = Integrations.shared
    let item: Suggestion
    let messages: [ThreadSlackMessage]
    let highlighted: Int?
    /// The item's own message alone, until the thread is in: no Reply on it (the composer already answers it).
    let isStandIn: Bool
    let quickLook: QuickLookController
    let filesBlocked: Bool
    let updateSlack: () -> Void

    var body: some View {
        let hidden = ThreadLayout.hiddenEarlier(highlighted: highlighted, showAll: conversation.showsEarlier)
        let names = integrations.slackNames
        let rows = Array(messages.enumerated())[hidden...]
        LazyVStack(alignment: .leading, spacing: 2) {
            if hidden > 0 {
                ShowEarlierButton(count: hidden) { withAnimation(Motion.snappy) { conversation.showsEarlier = true } }
            }
            ForEach(rows, id: \.element.id) { i, m in
                let sent = InboxThread.isSentFromDocket(m.id)
                SlackThreadRow(item: item, message: m, sender: ThreadText.sender(of: m, names: names), names: names,
                               showsDay: ThreadLayout.showsDay(m.date, after: i > hidden ? messages[i - 1].date : nil),
                               isHighlighted: i == highlighted, isSent: sent,
                               isStarred: integrations.isStarred(message: m.id, in: item.id),
                               starProblem: integrations.starProblem(for: item.id, message: m.id),
                               canReply: !isStandIn && messages.count > 1 && !sent, quickLook: quickLook,
                               filesBlocked: filesBlocked, updateSlack: updateSlack,
                               star: { InboxStarring.toggle(message: m.id, in: item.id) },
                               reply: { conversation.reply(to: m.id) },
                               saveNote: sent ? nil : { conversation.saveAsNote?(m.id) })
                    .id(ConversationSection.rowID(m.id))
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        // A reply sent from Docket comes in at the end.
        .animation(Motion.gentle, value: messages.count)
    }
}

/// One message of a Slack thread: who and when, the whole message, its files.
private struct SlackThreadRow: View {
    let item: Suggestion
    let message: ThreadSlackMessage
    let sender: String
    let names: [String: String]
    let showsDay: Bool
    let isHighlighted: Bool
    /// A reply that just went out from Docket, until Slack lists it.
    let isSent: Bool
    let isStarred: Bool
    let starProblem: String?
    let canReply: Bool
    let quickLook: QuickLookController
    let filesBlocked: Bool
    let updateSlack: () -> Void
    let star: () -> Void
    let reply: () -> Void
    /// Saves this message as a note (not one that just went out).
    let saveNote: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            InboxAvatar(name: sender, isMine: message.isMine)
                .padding(.top, isHighlighted ? 17 : 1)
            VStack(alignment: .leading, spacing: 4) {
                if isHighlighted { Eyebrow(text: "This message").padding(.bottom, 1) }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(sender)
                        .font(.system(size: 13.5, weight: .bold))
                        .foregroundStyle(Color.ink)
                        .lineLimit(1)
                    Text(showsDay ? Fmt.dateTime(message.date) : Fmt.time(message.date))
                        .font(.system(size: 11.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(Color.ink3)
                        .lineLimit(1)
                        .fixedSize()
                        .help(Fmt.dateTime(message.date))
                    if isSent {
                        Text("Sent from Docket")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Color.ink3)
                            .lineLimit(1)
                    }
                    Spacer(minLength: Space.xs)
                    if canReply {
                        MessageActions(isStarred: isStarred, shown: hovering, star: star, reply: reply)
                            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                    }
                }
                .frame(minHeight: 18)
                if let starProblem { StarProblemLine(text: starProblem) }
                text
                if !message.files.isEmpty {
                    AttachmentsSection(item: item, attachments: message.files, quickLook: quickLook, filesBlocked: filesBlocked,
                                       showsTitle: false)
                        .padding(.top, 2)
                }
            }
        }
        .padding(.horizontal, isHighlighted ? Space.md : Space.sm)
        .padding(.vertical, isHighlighted ? Space.md : 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .fill(isHighlighted ? Color.fill : (hovering && canReply ? Color.pressedTint : Color.clear))
        )
        .contentShape(Rectangle())
        .onHover { h in withAnimation(Motion.fast) { hovering = h } }
        .contextMenu {
            if canReply {
                Button("Reply to This Message", action: reply)
                Button(isStarred ? "Unstar" : "Star", action: star)
                Divider()
            }
            Button("Copy Text") { copy(message.text) }
            if let saveNote { Button("Save Message as Note", action: saveNote) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(sender), \(Fmt.dateTime(message.date))")
        .accessibilityActions {
            if canReply {
                Button("Reply to this message", action: reply)
                Button(isStarred ? "Unstar" : "Star", action: star)
            }
        }
    }

    @ViewBuilder
    private var text: some View {
        if !message.markup.isEmpty {
            SlackMessageText(markup: message.markup, names: names, size: 14)
                .equatable()
        } else if !message.text.isEmpty {
            LinkedTextView(text: message.text, size: 14)
                .equatable()
        }
    }
}

// MARK: - An email conversation

/// Gmail-style: older emails as one line each (click to open), the newest and the inbox's own one open, and
/// replies that just went out from Docket.
private struct EmailConversationView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var conversation: ConversationModel
    @ObservedObject private var integrations = Integrations.shared
    @AppStorage(InboxDetail.plainTextKey) private var plainText = false
    let item: Suggestion
    let emails: [ThreadEmail]
    let highlighted: Int?
    /// The item's own email alone, until the conversation is in.
    let isStandIn: Bool
    let quickLook: QuickLookController
    let paneHeight: CGFloat

    var body: some View {
        let hidden = ThreadLayout.hiddenEarlier(highlighted: highlighted, showAll: conversation.showsEarlier)
        let rows = Array(emails.enumerated())[hidden...]
        let newest = ThreadLayout.newest(emails.map(\.id))
        let myAddress = integrations.gmailAddress
        LazyVStack(alignment: .leading, spacing: 0) {
            if hidden > 0 {
                ShowEarlierButton(count: hidden) { withAnimation(Motion.snappy) { conversation.showsEarlier = true } }
                    .padding(.bottom, Space.xs)
            }
            ForEach(rows, id: \.element.id) { i, email in
                let sent = InboxThread.isSentFromDocket(email.id)
                let open = ThreadLayout.isOpen(email.id, at: i, newest: newest, highlighted: highlighted, toggled: conversation.toggled)
                let starred = integrations.isStarred(message: email.id, in: item.id)
                let star = { InboxStarring.toggle(message: email.id, in: item.id) }
                Group {
                    if open {
                        EmailCard(item: item, email: email, isHighlighted: i == highlighted, isSent: sent, isStarred: starred,
                                  starProblem: integrations.starProblem(for: item.id, message: email.id),
                                  canCollapse: emails.count > 1 && !sent, canReply: !isStandIn && emails.count > 1 && !sent,
                                  myAddress: myAddress, plainText: plainText, untrimmed: untrimmed(email.id),
                                  quickLook: quickLook, paneHeight: paneHeight,
                                  collapse: { toggle(email.id, open: false) }, star: star,
                                  reply: { conversation.reply(to: email.id) },
                                  saveNote: sent ? nil : { conversation.saveAsNote?(email.id) })
                    } else {
                        EmailLine(email: email, isStarred: starred, now: app.clock, open: { toggle(email.id, open: true) }, star: star)
                    }
                }
                .id(ConversationSection.rowID(email.id))
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                if i < emails.count - 1 {
                    Rectangle().fill(Color.hair).frame(height: 1)
                }
            }
        }
        // A reply sent from Docket comes in at the end.
        .animation(Motion.gentle, value: emails.count)
    }

    private func toggle(_ id: String, open: Bool) {
        withAnimation(Motion.snappy) { conversation.toggled[id] = open }
    }

    private func untrimmed(_ id: String) -> Binding<Bool> {
        Binding(get: { conversation.untrimmed.contains(id) },
                set: { show in
                    if show { conversation.untrimmed.insert(id) } else { conversation.untrimmed.remove(id) }
                })
    }
}

/// An email shown as one line: who, its first words, when. A click opens it.
private struct EmailLine: View {
    let email: ThreadEmail
    let isStarred: Bool
    let now: Date
    let open: () -> Void
    let star: () -> Void
    @State private var hovering = false

    var body: some View {
        let sender = ThreadText.sender(of: email)
        HStack(spacing: 10) {
            InboxAvatar(name: sender, isMine: email.isMine, size: 24)
            // The name first (up to a point), then as much of the email as fits.
            Text(sender)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.ink)
                .lineLimit(1)
                .frame(maxWidth: 150, alignment: .leading)
                .layoutPriority(1)
            Text(ThreadText.snippet(of: email))
                .font(.system(size: 12.5))
                .foregroundStyle(Color.ink2)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(Calendar.current.isDate(email.date, inSameDayAs: now) ? Fmt.time(email.date) : Fmt.absoluteDay(email.date, now: now))
                .font(.system(size: 11.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Color.ink3)
                .lineLimit(1)
                .fixedSize()
            StarButton(isOn: isStarred, size: 24, iconSize: 11.5, action: star)
                .opacity(isStarred || hovering ? 1 : 0)
                .allowsHitTesting(isStarred || hovering)
        }
        .padding(.horizontal, Space.sm)
        .frame(height: 42)
        .background(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(hovering ? Color.pressedTint : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { h in withAnimation(Motion.fast) { hovering = h } }
        .help("\(Fmt.dateTime(email.date)) · Click to read it")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Open", open)
        .accessibilityAction(named: isStarred ? "Unstar" : "Star", star)
    }
}

/// An email shown open: who, to whom and when, its body (quoted history behind "…") and attachments.
private struct EmailCard: View {
    @ObservedObject private var integrations = Integrations.shared
    let item: Suggestion
    let email: ThreadEmail
    let isHighlighted: Bool
    /// A reply that just went out from Docket, until Gmail lists it.
    let isSent: Bool
    let isStarred: Bool
    let starProblem: String?
    let canCollapse: Bool
    let canReply: Bool
    let myAddress: String?
    let plainText: Bool
    @Binding var untrimmed: Bool
    let quickLook: QuickLookController
    let paneHeight: CGFloat
    let collapse: () -> Void
    let star: () -> Void
    let reply: () -> Void
    /// Saves this email as a note (not one that just went out).
    let saveNote: (() -> Void)?
    @StateObject private var facts = MailHTMLFacts()

    private var html: String? { email.content.html.flatMap { MailHTML.hasContent($0) ? $0 : nil } }
    private var showsHTML: Bool { !plainText && html != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            if isHighlighted { Eyebrow(text: "This message") }
            header
            if let starProblem { StarProblemLine(text: starProblem) }
            messageBody
                .padding(.top, 2)
            attachments
        }
        .padding(.horizontal, isHighlighted ? Space.md : Space.sm)
        .padding(.vertical, Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(isHighlighted ? Color.fill : Color.clear))
        .padding(.vertical, isHighlighted ? Space.xs : 0)
        .contextMenu {
            if canReply {
                Button("Reply to This Email", action: reply)
                Button(isStarred ? "Unstar" : "Star", action: star)
                Divider()
            }
            Button("Copy Text") { copy(email.content.text) }
            if let saveNote { Button("Save Email as Note", action: saveNote) }
        }
    }

    private var header: some View {
        let sender = ThreadText.sender(of: email)
        return HStack(alignment: .top, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                InboxAvatar(name: sender, isMine: email.isMine)
                VStack(alignment: .leading, spacing: 2) {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            name(sender)
                            if let address = ThreadText.address(of: email) {
                                Text(address)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.ink3)
                                    .lineLimit(1)
                            }
                        }
                        name(sender)
                    }
                    if let to = ThreadText.recipients(of: email, myAddress: myAddress) {
                        Text(isSent ? to + " · Sent from Docket" : to)
                            .textStyle(.caption)
                            .foregroundStyle(Color.ink2)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(ThreadText.recipientEntries(of: email).joined(separator: ", "))
                    } else if isSent {
                        Text("Sent from Docket")
                            .textStyle(.caption)
                            .foregroundStyle(Color.ink2)
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { if canCollapse { collapse() } }
            .help(canCollapse ? "Click to show it as one line" : "")
            Spacer(minLength: Space.xs)
            Text(Fmt.dateTime(email.date))
                .font(.system(size: 11.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Color.ink3)
                .lineLimit(1)
                .fixedSize()
                .padding(.top, 2)
            if canReply {
                HStack(spacing: 0) {
                    StarButton(isOn: isStarred, size: 24, iconSize: 11.5, action: star)
                    Button(action: reply) {
                        Image(systemName: "arrowshape.turn.up.left")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(Color.ink2)
                    }
                    .buttonStyle(IconButtonStyle(size: 24))
                    .help("Reply to this email")
                    .accessibilityLabel("Reply to this email")
                }
                .padding(.top, -3)
            }
        }
    }

    private func name(_ sender: String) -> some View {
        Text(sender)
            .font(.system(size: 13.5, weight: .bold))
            .foregroundStyle(Color.ink)
            .lineLimit(1)
    }

    @ViewBuilder
    private var messageBody: some View {
        let content = email.content
        if showsHTML, let html {
            let quoted = facts.hasQuotedHistory(html)
            VStack(alignment: .leading, spacing: Space.sm) {
                MailBodyView(html: html, inlineParts: content.attachments.filter { $0.contentID != nil },
                             fetch: { part in try await integrations.file(for: part, messageID: item.id) },
                             paneHeight: paneHeight, plainText: content.text, hidesQuotes: quoted && !untrimmed)
                if quoted { QuoteToggle(shown: $untrimmed) }
            }
        } else {
            let full = content.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? email.snippet : content.text
            let trimmed = facts.trimmedText(full)
            let quoted = trimmed != nil
            VStack(alignment: .leading, spacing: Space.sm) {
                LinkedTextView(text: quoted && !untrimmed ? (trimmed ?? full) : full, size: 14.5)
                    .equatable()
                if quoted { QuoteToggle(shown: $untrimmed) }
            }
        }
    }

    @ViewBuilder
    private var attachments: some View {
        let content = email.content
        let inline = showsHTML ? html.map(facts.inlineContentIDs) : nil
        let files = InboxItemText.listedAttachments(content, showsHTML: showsHTML, inline: inline)
        if !files.isEmpty {
            AttachmentsSection(item: item, attachments: files, quickLook: quickLook, filesBlocked: false)
                .padding(.top, Space.xs)
        }
    }
}

private func copy(_ text: String) {
    let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !words.isEmpty else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(words, forType: .string)
}
