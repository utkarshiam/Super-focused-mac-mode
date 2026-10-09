import AppKit
import Foundation

// Checking Slack and Gmail every couple of minutes, and telling the user about what's new: the rules for when a
// quick check runs (`MessagePoll`), what each notification says (`MessageAlerts`), and where notifications go
// (`MessageAlertSink`, swapped in tests). `Integrations` runs the checks; `NotificationService` shows them.

// MARK: - The quick check

/// When the quick check (every two minutes) runs, and why it doesn't. Pure, so it's easy to test.
enum MessagePoll {
    /// How often Slack and Gmail are checked while the switch is on.
    static let interval: TimeInterval = 2 * 60

    /// Why a quick check didn't run.
    enum Skip: Equatable {
        /// "Check Slack and email every 2 minutes" is off.
        case turnedOff
        /// Neither Slack nor Gmail is connected (or Docket isn't set up yet).
        case notConnected
        /// A check is running already.
        case refreshing
        /// The Mac is asleep, its screen is off or locked, or another user is on it.
        case asleep
        /// Every connected service asked Docket to slow down, and the pause isn't over.
        case paused
    }

    static func skip(enabled: Bool, slackConnected: Bool, gmailConnected: Bool, refreshing: Bool, asleep: Bool,
                     slackPausedUntil: Date?, gmailPausedUntil: Date?, now: Date) -> Skip? {
        guard enabled else { return .turnedOff }
        guard slackConnected || gmailConnected else { return .notConnected }
        if refreshing { return .refreshing }
        if asleep { return .asleep }
        // One service waiting out a pause doesn't hold up the other (each check skips a paused service).
        let slackWaits = !slackConnected || (slackPausedUntil.map { $0 > now } ?? false)
        let gmailWaits = !gmailConnected || (gmailPausedUntil.map { $0 > now } ?? false)
        return slackWaits && gmailWaits ? .paused : nil
    }

    /// What stops the quick checks for a while: the Mac sleeping, its screens off, the screen locked, or the
    /// user switched out. Checks resume (catching up once) when none is left.
    enum Pause: Hashable {
        case sleep, screens, locked, session
    }
}

// MARK: - Notifications

/// One notification about new messages: a message of its own, or a summary of several.
struct MessageAlert: Equatable {
    /// The message (`Suggestion.id`); nil for a summary.
    var itemID: String?
    var title: String
    var body: String
    /// Notifications of one conversation group together (Slack channel or DM, email thread).
    var threadID: String
    var isSummary: Bool { itemID == nil }
}

/// What notifications about new messages say. Pure, so it's easy to test.
enum MessageAlerts {
    /// More new messages than this at once make one summary instead of one notification each.
    static let summaryAfter = 3
    /// The thread of summaries.
    static let summaryThread = "messages"
    /// A notification's text is cut to about two lines.
    static let bodyLimit = 140

    /// One notification per message, or one summary when there are more than `summaryAfter`.
    static func plan(_ items: [Suggestion]) -> [MessageAlert] {
        guard !items.isEmpty else { return [] }
        if items.count > summaryAfter { return [summary(items)] }
        // Oldest first, so the newest ends up on top of Notification Center.
        return items.sorted { $0.receivedAt < $1.receivedAt }.map(alert)
    }

    static func alert(_ s: Suggestion) -> MessageAlert {
        MessageAlert(itemID: s.id, title: title(for: s), body: body(for: s), threadID: thread(for: s))
    }

    /// "Priya Shah · #leadership", "Priya Shah · DM", "Priya Shah · Group DM", "Priya Shah · Email".
    static func title(for s: Suggestion) -> String {
        let sender = s.from.trimmingCharacters(in: .whitespacesAndNewlines)
        let who = sender.isEmpty ? "Someone" : sender
        switch s.source.kind {
        case .slack: return "\(who) · \(InboxText.place(of: s))"
        case .gmail: return "\(who) · Email"
        case .ai: return who
        }
    }

    /// The message as plain text, at most two lines: a Slack message's words; an email's subject, then its preview.
    static func body(for s: Suggestion) -> String {
        switch s.source.kind {
        case .gmail:
            let subject = SlackText.firstLine(MailText.cleanSubject(s.subject ?? ""), limit: 80)
            let preview = clipped(s.snippet, lines: subject.isEmpty ? 2 : 1)
            return [subject, preview].filter { !$0.isEmpty }.joined(separator: "\n")
        case .slack, .ai:
            let text = s.content?.text ?? s.snippet
            return clipped(text.isEmpty ? s.snippet : text, lines: 2)
        }
    }

    /// The text's first `lines` non-empty lines (spaces collapsed), cut to `bodyLimit` characters with "…".
    static func clipped(_ text: String, lines: Int) -> String {
        let kept = text.components(separatedBy: .newlines)
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty }
        var result = kept.prefix(max(1, lines)).joined(separator: "\n")
        if kept.count > lines, !result.isEmpty { result += "…" }
        guard result.count > bodyLimit else { return result }
        return String(result.prefix(bodyLimit - 1)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    /// "slack:C0LEAD" for a channel or DM, "gmail:t1" for an email thread.
    static func thread(for s: Suggestion) -> String {
        if let channel = InboxIDs.slack(s.id)?.channel { return "slack:\(channel)" }
        if let thread = GmailMessage.threadID(fromExternalID: s.id) { return "gmail:\(thread)" }
        return s.id
    }

    /// "4 new Slack messages", "5 new emails", "6 new messages" (Slack and email), and who they're from.
    static func summary(_ items: [Suggestion]) -> MessageAlert {
        let kinds = Set(items.map(\.source.kind))
        let title: String
        if kinds == [.slack] {
            title = "\(items.count) new Slack messages"
        } else if kinds == [.gmail] {
            title = "\(items.count) new emails"
        } else {
            title = "\(items.count) new messages"
        }
        var senders: [String] = []
        for s in items.sorted(by: { $0.receivedAt > $1.receivedAt }) {
            let name = s.from.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty, !senders.contains(name) { senders.append(name) }
        }
        let shown = senders.prefix(3).joined(separator: ", ")
        let more = senders.count > 3 ? " and \(senders.count - 3) more" : ""
        return MessageAlert(itemID: nil, title: title, body: shown.isEmpty ? "Open Messages in Docket" : "From \(shown)\(more)",
                            threadID: summaryThread)
    }
}

/// Where notifications about new messages go: macOS (through `NotificationService`), or a recorder in tests.
struct MessageAlertSink {
    var post: @MainActor ([MessageAlert]) -> Void
    /// Takes back notifications of messages handled since (added as a task, dismissed).
    var withdraw: @MainActor ([String]) -> Void

    static var system: MessageAlertSink {
        MessageAlertSink(post: { alerts in NotificationService.shared.deliverMessages(alerts) },
                         withdraw: { ids in NotificationService.shared.removeDeliveredMessages(ids) })
    }

    static var none: MessageAlertSink {
        MessageAlertSink(post: { _ in }, withdraw: { _ in })
    }
}

// MARK: - The menu bar panel

/// The menu bar panel's frame: as tall as the screen's visible frame (from just under the menu bar to above the
/// Dock), under the icon, kept on screen. Pure, so it's easy to test.
enum MenuBarPanelLayout {
    static let width: CGFloat = 380
    /// Space under the menu bar, and above the bottom of the visible frame (so the rounded card and its shadow
    /// never touch the Dock).
    static let gap: CGFloat = 6
    /// Space kept from the screen's sides.
    static let sideMargin: CGFloat = 8
    /// Never shorter than this, even on an odd screen.
    static let minHeight: CGFloat = 320

    /// `anchorMinY`: the bottom of the status item, when known (with a menu bar that hides itself the visible
    /// frame reaches the top of the screen, and the panel still starts under the icon).
    static func frame(visibleFrame v: NSRect, anchorMidX: CGFloat, anchorMinY: CGFloat? = nil) -> NSRect {
        let top = min(v.maxY, anchorMinY ?? v.maxY) - gap
        let height = max(minHeight, top - (v.minY + gap)).rounded()
        var x = anchorMidX - width / 2
        x = min(max(x, v.minX + sideMargin), v.maxX - width - sideMargin)
        return NSRect(x: x.rounded(), y: (top - height).rounded(), width: width, height: height)
    }

    /// How the panel's height is shared: today's tasks get what they need up to `taskShare` of the room for
    /// the two lists, and Messages the rest. With Slack and Gmail both off, the tasks get it all.
    static let taskShare: CGFloat = 0.45

    static func taskListHeight(available: CGFloat, tasksNeed: CGFloat, showsMessages: Bool) -> CGFloat {
        guard showsMessages else { return max(0, available) }
        return max(0, min(tasksNeed, available * taskShare))
    }
}

/// The messages the menu bar panel lists. Pure, so it's easy to test.
enum MenuBarMessageList {
    /// At most this many (Messages has the rest).
    static let limit = 40

    /// Slack messages and emails: the new ones first, then the newest first.
    static func items(_ all: [Suggestion], new: Set<String>) -> [Suggestion] {
        let messages = all.filter { $0.source.kind == .slack || $0.source.kind == .gmail }
        return Array(messages.sorted { a, b in
            let (aNew, bNew) = (new.contains(a.id), new.contains(b.id))
            if aNew != bNew { return aNew }
            return (a.receivedAt, a.id) > (b.receivedAt, b.id)
        }.prefix(limit))
    }

    /// The row's two lines of text: a Slack message's words; an email's subject, then its preview.
    static func snippet(_ s: Suggestion) -> String {
        let text = s.snippet.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        // Slack: readable text, not *markup* or :shortcodes: (the same rendering the Messages screen uses).
        guard s.source.kind == .gmail else { return String(SlackText.attributed(text, names: [:]).characters) }
        let subject = MailText.cleanSubject(s.subject ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return [subject, text].filter { !$0.isEmpty }.joined(separator: " — ")
    }
}
