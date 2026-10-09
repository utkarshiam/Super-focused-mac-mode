import AppKit
import SwiftUI

// Replying from the message detail (it comes out on Reply, or when there's a draft): one editor, Draft with
// AI as an optional helper on one row (tone, an instruction), the message of the thread being answered
// ("Replying to Priya · 10:42 AM"), and Send (always after a confirmation), Save as Gmail draft, or Copy.
//
// Nothing is ever sent without the confirmation: the Send button and ⌘↩ both only ask, and the reply goes to
// exactly what the confirmation named.

// MARK: - Words

/// Where a reply goes, what the confirmation asks and what the toast says. Pure, so it's easy to test.
enum ReplyText {
    /// Where a Slack message was posted, read from its label ("#leadership · Priya").
    enum Place: Equatable {
        case channel(String)
        case direct
        case group
        case unknown
    }

    static func place(of item: Suggestion) -> Place {
        let first = item.source.label.components(separatedBy: " · ").first?.trimmingCharacters(in: .whitespaces) ?? ""
        if first.hasPrefix("#"), first.count > 1 { return .channel(first) }
        if InboxText.isDirect(first) { return .direct }
        if InboxText.isGroup(first) { return .group }
        return .unknown
    }

    /// "Sam Lee <Sam@Northwind.example>" → "sam@northwind.example".
    static func address(_ entry: String) -> String {
        let sender = MailSender(header: entry)
        return (sender.address ?? sender.name ?? entry).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Everyone on the email but `excluding` (you, the sender, the Reply-To): who "Reply all" adds. In order,
    /// each once.
    static func otherRecipients(to: [String], cc: [String], excluding: [String]) -> [String] {
        var seen = Set(excluding.map(address))
        var result: [String] = []
        for entry in to + cc {
            let a = address(entry)
            guard a.contains("@"), seen.insert(a).inserted else { continue }
            result.append(entry.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result
    }

    /// Who a reply to the email goes to: its Reply-To, else its sender; the address when Gmail gave it.
    static func recipient(of item: Suggestion) -> String {
        guard let headers = item.replyHeaders else { return item.from }
        let replyTo = headers.replyTo?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sender = MailSender(header: replyTo.contains("@") ? replyTo : headers.from)
        return sender.address ?? sender.name ?? item.from
    }

    /// Who an email reply goes to, by the rules it's sent with (`MailReplyBuilder`: never you, nobody twice,
    /// and for an email you sent, the people you sent it to): To, then Cc. Nil until the email's headers are
    /// known (it's been opened).
    static func mailRecipients(for item: Suggestion, myAddress: String?, replyAll: Bool) -> [MailSender]? {
        guard item.source.kind == .gmail, let headers = item.replyHeaders else { return nil }
        return mailRecipients(headers: headers, myAddress: myAddress, replyAll: replyAll)
    }

    /// Who a reply to the email with these headers goes to (any message of the conversation), by the same rules.
    static func mailRecipients(headers: MailReplyHeaders, myAddress: String?, replyAll: Bool) -> [MailSender] {
        let reply = MailReply(threadID: "", headers: headers, fromAddress: myAddress ?? "", body: "", replyAll: replyAll)
        let recipients = MailReplyBuilder.recipients(for: reply)
        return recipients.to + recipients.cc
    }

    /// "Send this reply to Priya Shah in #leadership?" / "Send to sam@northwind.example (and 2 others)?"
    /// `to`: who an email goes to first, when known; `others`: how many more it goes to. `person`: Slack, whose
    /// message of the thread the reply answers, when one was picked (the thread is the same either way).
    static func confirmation(for item: Suggestion, to first: String? = nil, others: Int, person: String? = nil) -> String {
        switch item.source.kind {
        case .gmail:
            return "Send to \(first ?? recipient(of: item))" + (others > 0 ? " (and \(Fmt.plural(others, "other")))?" : "?")
        case .slack, .ai:
            let who = person ?? item.from
            switch place(of: item) {
            case .channel(let name): return "Send this reply to \(who) in \(name)?"
            case .direct: return "Send this reply to \(item.from)?"
            case .group: return "Send this reply to the group message with \(item.from)?"
            case .unknown: return "Send this reply to \(who) in Slack?"
            }
        }
    }

    /// Next to "Reply": where it will go, in a few words ("To Sam and 2 others", "In thread · #leadership").
    /// `to`: who an email goes to first, when known; `others`: how many more it goes to.
    static func destination(for item: Suggestion, to first: String? = nil, others: Int) -> String {
        switch item.source.kind {
        case .gmail:
            var line = "To \(first ?? item.from)"
            if others > 0 { line += " and \(Fmt.plural(others, "other"))" }
            return line
        case .slack, .ai:
            switch place(of: item) {
            case .channel(let name): return "In thread · \(name)"
            case .direct: return "In thread · DM with \(item.from)"
            case .group: return "In thread · group message"
            case .unknown: return "In thread"
            }
        }
    }

    /// Add task leads until there's a reply to send; then sending does (one primary button per screen).
    static func sendLeads(_ reply: String, canSend: Bool) -> Bool {
        canSend && !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static let placeholder = try! NSRegularExpression(pattern: #"\[[^\[\]\n]{1,80}\]"#)

    /// AI leaves "[placeholder]" where it didn't know a fact: worth filling in before sending.
    static func hasPlaceholders(_ reply: String) -> Bool {
        let ns = reply as NSString
        return placeholder.firstMatch(in: reply, range: NSRange(location: 0, length: ns.length)) != nil
    }

    /// The reply as the confirmation shows it: its opening, cut at a word.
    static func preview(_ reply: String, limit: Int = 280) -> String {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > limit else { return text }
        var cut = String(text.prefix(limit))
        if let space = cut.lastIndex(where: \.isWhitespace), cut.distance(from: cut.startIndex, to: space) > limit / 2 {
            cut = String(cut[..<space])
        }
        return cut + "…"
    }
}

// MARK: - The composer

/// The Reply section of the message detail.
struct ReplyComposer: View {
    static let toneKey = "inboxReplyTone"

    @EnvironmentObject var app: AppState
    @ObservedObject private var integrations = Integrations.shared
    @AppStorage(Prefs.Key.aiEnabled) private var aiEnabled = true
    @AppStorage(ReplyComposer.toneKey) private var toneRaw = ReplyTone.brief.rawValue

    let item: Suggestion
    @Binding var text: String
    /// The complete message, for who else is on an email.
    let content: MessageContent?
    /// Gmail: whether the sign-in allows sending and saving drafts. Slack can always reply.
    let canSend: Bool
    /// The open message's thread: which of its messages the reply answers.
    @ObservedObject var conversation: ConversationModel
    /// It came out because Reply was clicked: the editor takes the keyboard as it shows.
    let takesFocus: Bool
    /// Saves whatever is typed but not saved yet: the notes before AI reads them, the reply before it goes.
    let flush: () -> Void
    let reconnectGmail: () -> Void

    private enum Phase: Equatable {
        case idle
        case drafting
        /// AI wrote what's in the editor.
        case drafted
        case aiFailed(String, needsSettings: Bool)
        case sending
        case savingDraft
        case failed(String, retry: Retry)
    }

    private enum Retry { case send, saveDraft }

    /// What the confirmation asked about: the reply goes exactly there, even if the thread changes meanwhile.
    private struct PendingSend: Equatable {
        var title: String
        var replyingTo: String?
        var replyAll: Bool
    }

    /// The message of the thread picked to reply to, as the composer names it.
    private struct Picked {
        var name: String
        var isMine: Bool
        var date: Date
        /// Slack: the line the reply can start with to quote it.
        var quote: String?
    }

    @State private var phase: Phase = .idle
    @State private var instruction = ""
    /// What was in the editor before AI replaced it, so Undo can bring it back.
    @State private var previous: String?
    @State private var confirming = false
    @State private var pending: PendingSend?
    @State private var replyAll = false
    @State private var drafting: Task<Void, Never>?
    /// The quote line Docket put at the top of the reply (Slack's Quote switch).
    @State private var quote: String?
    @FocusState private var editorFocused: Bool

    private var tone: ReplyTone { ReplyTone(rawValue: toneRaw) ?? .brief }
    private var isEmail: Bool { item.source.kind == .gmail }
    private var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var busy: Bool { phase == .drafting || phase == .sending || phase == .savingDraft }
    private var canSendNow: Bool { canSend && hasText && !busy }

    private var picked: Picked? {
        if let m = conversation.pickedSlack {
            return Picked(name: ThreadText.sender(of: m, names: integrations.slackNames), isMine: m.isMine, date: m.date,
                          quote: ThreadText.quoteLine(m.text))
        }
        if let e = conversation.pickedEmail {
            return Picked(name: ThreadText.sender(of: e), isMine: e.isMine, date: e.date, quote: nil)
        }
        return nil
    }

    /// The email being answered: the message picked in the conversation, else its newest one that isn't
    /// yours once the conversation is in, else the email itself (once its headers are known). The same
    /// message `sendReply` gets, so the confirmation names who the reply really goes to.
    private var replyHeaders: MailReplyHeaders? {
        guard isEmail else { return nil }
        return integrations.replyHeaders(for: item.id, replyingTo: conversation.replyingTo)
    }

    /// Who an email reply goes to as it will be sent: replying, and with Reply all. Nil until the email's
    /// headers are known (it's been opened).
    private var mailRecipients: (direct: [MailSender], all: [MailSender])? {
        guard let headers = replyHeaders else { return nil }
        let me = integrations.gmailAddress
        return (ReplyText.mailRecipients(headers: headers, myAddress: me, replyAll: false),
                ReplyText.mailRecipients(headers: headers, myAddress: me, replyAll: true))
    }

    /// Who Reply all adds.
    private var others: [String] {
        guard isEmail else { return [] }
        if let recipients = mailRecipients {
            let direct = Set(recipients.direct.compactMap { $0.address?.lowercased() })
            return recipients.all.filter { !direct.contains($0.address?.lowercased() ?? "") }.map(\.headerForm)
        }
        // Before its headers are in: from what's known of it.
        let excluding = [integrations.gmailAddress, item.from].compactMap { $0 }
        return ReplyText.otherRecipients(to: content?.to ?? [], cc: content?.cc ?? [], excluding: excluding)
    }

    /// Everyone the email reply would go to now (with Reply all or without), in order. Nil until its
    /// headers are known.
    private func sendingTo(others: [String]) -> [MailSender]? {
        mailRecipients.map { replyAll && !others.isEmpty ? $0.all : $0.direct }
    }

    var body: some View {
        let others = self.others
        let sendingTo = self.sendingTo(others: others)
        VStack(alignment: .leading, spacing: Space.sm) {
            headerRow(others: others, sendingTo: sendingTo)

            if let picked { replyingRow(picked) }

            // Optional: the editor below works without AI.
            if aiEnabled { aiRow }

            GrowingTextEditor(text: $text, placeholder: "Write a reply…",
                              minHeight: 80, maxHeight: 340, focus: $editorFocused, disabled: busy)
                .help("Your reply, saved as you type. ⌘↩ sends it, after asking.")

            status

            actions

            if isEmail && !canSend {
                HStack(alignment: .center, spacing: 6) {
                    Image(systemName: "lock")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.ink3)
                    Text("Reconnect Gmail to send from Docket.")
                        .textStyle(.footnote)
                        .foregroundStyle(Color.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: Space.sm)
                    Button("Reconnect", action: reconnectGmail)
                        .buttonStyle(SecondaryPill(height: 28))
                        .disabled(integrations.isSigningInToGmail)
                        .help("Sign in to Google again and allow Docket to send your replies and save drafts (Copy works now)")
                }
            }
        }
        .animation(Motion.base, value: phase)
        .animation(Motion.base, value: conversation.target)
        .background {
            // ⌘↩ asks to send, wherever the cursor is in the detail (kept out of the button rows).
            Button("") { requestSend() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canSendNow)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .alert(pending?.title ?? "", isPresented: $confirming) {
            Button("Send") { if let pending { send(pending) } }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmationMessage)
        }
        .onChange(of: conversation.target) { _ in
            // Answering another message: the quote of the last one goes.
            setQuote(nil)
        }
        .onChange(of: conversation.composerRequests) { _ in editorFocused = true }
        .onAppear {
            // Out because Reply was clicked: the keyboard goes to the editor once it's on screen.
            guard takesFocus else { return }
            DispatchQueue.main.async { editorFocused = true }
        }
        .onDisappear {
            // A draft being written goes with the message; a reply being sent finishes either way.
            drafting?.cancel()
        }
    }

    // MARK: Replying to one message

    /// The message picked in the thread: "Replying to Priya · 10:42 AM", the Quote switch (Slack), and ✕ to
    /// answer the default one again (Slack: the thread; email: its newest message that isn't yours).
    private func replyingRow(_ picked: Picked) -> some View {
        let who = Text("Replying to \(ThreadText.replyingToName(picked.name, isMine: picked.isMine))")
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(Color.ink)
        return HStack(spacing: Space.sm) {
            Image(systemName: "arrowshape.turn.up.left")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.ink2)
            // When it's narrow, the time goes first (it's in the tooltip), then the name is cut short.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 4) {
                    who
                    Text("· " + ThreadText.when(picked.date, now: app.clock))
                        .font(.system(size: 12.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(Color.ink2)
                }
                .lineLimit(1)
                .fixedSize()
                who.lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let line = picked.quote {
                Toggle("Quote", isOn: Binding(get: { quote != nil }, set: { setQuote($0 ? line : nil) }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.ink2)
                    .fixedSize()
                    .disabled(busy)
                    .help(picked.isMine ? "Start your reply with a quote of your message"
                          : "Start your reply with a quote of \(ThreadText.firstName(picked.name))’s message")
            }
            Button { withAnimation(Motion.base) { conversation.target = nil } } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9.5, weight: .bold))
            }
            .buttonStyle(IconButtonStyle(size: 22))
            .disabled(busy)
            .help(isEmail ? "Reply to the latest message instead" : "Reply to the thread instead")
            .accessibilityLabel(isEmail ? "Reply to the latest message instead" : "Reply to the thread instead")
        }
        .padding(.leading, 10)
        .padding(.trailing, 5)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(Color.fill))
        .help(ThreadText.replyingTo(picked.name, isMine: picked.isMine, at: picked.date, now: app.clock))
        .transition(.opacity)
    }

    /// Puts `line` at the top of the reply as a quote, replacing the one Docket put there before (nil takes it away).
    private func setQuote(_ line: String?) {
        guard line != quote else { return }
        if let quote { text = ThreadText.removing(quote: quote, from: text) }
        quote = line
        if let line {
            text = ThreadText.adding(quote: line, to: text)
            editorFocused = true
        }
    }

    // MARK: Pieces

    /// "REPLY  To Sam and 2 others" with Reply all on the right (when there are others to add).
    private func headerRow(others: [String], sendingTo: [MailSender]?) -> some View {
        HStack(alignment: .center, spacing: Space.sm) {
            Eyebrow(text: "Reply")
            Text(destinationLine(others: others, sendingTo: sendingTo))
                .textStyle(.footnote)
                .foregroundStyle(Color.ink2)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(destinationHelp(others: others, sendingTo: sendingTo))
            Spacer(minLength: Space.sm)
            if isEmail, !others.isEmpty, canSend {
                Toggle("Reply all", isOn: $replyAll)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.ink2)
                    .fixedSize()
                    .disabled(busy)
                    .help("Also send it to " + others.joined(separator: ", "))
            }
        }
    }

    private func destinationLine(others: [String], sendingTo: [MailSender]?) -> String {
        guard let sendingTo, let first = sendingTo.first else {
            return ReplyText.destination(for: item, others: replyAll ? others.count : 0)
        }
        return ReplyText.destination(for: item, to: first.displayName, others: sendingTo.count - 1)
    }

    private func destinationHelp(others: [String], sendingTo: [MailSender]?) -> String {
        guard isEmail else { return "Your reply posts as you, in the message's thread in Slack" }
        if let sendingTo, !sendingTo.isEmpty { return "To " + sendingTo.map(\.headerForm).joined(separator: ", ") }
        let to = ReplyText.recipient(of: item)
        return replyAll && !others.isEmpty ? "To \(to), and \(others.joined(separator: ", "))" : "To \(to)"
    }

    /// The confirmation's question, naming who the reply really goes to.
    private func confirmationTitle(others: [String], sendingTo: [MailSender]?) -> String {
        guard let sendingTo, let first = sendingTo.first else {
            return ReplyText.confirmation(for: item, others: replyAll ? others.count : 0, person: pickedPerson)
        }
        return ReplyText.confirmation(for: item, to: first.address ?? first.displayName, others: sendingTo.count - 1)
    }

    /// Slack: whose message of the thread the reply answers, when one was picked ("the thread" for your own).
    private var pickedPerson: String? {
        guard !isEmail, let picked else { return nil }
        return picked.isMine ? "the thread" : picked.name
    }

    /// Tone, what the reply should say (optional) and Draft with AI, on one row.
    private var aiRow: some View {
        HStack(spacing: Space.sm) {
            toneMenu
            HStack(spacing: 6) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.ink3)
                TextField("What should it say? (optional)", text: $instruction)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(Color.ink)
                    .onSubmit(draftWithAI)
                    .disabled(busy)
                    .help("Say what the reply should get across, like “yes to Thursday, ask for the deck first”")
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(Color.fill))

            ViewThatFits(in: .horizontal) {
                draftButton(title: hasText ? "Redraft with AI" : "Draft with AI")
                draftButton(title: hasText ? "Redraft" : "Draft")
            }
        }
    }

    /// "Brief ⌄": how the AI draft should sound.
    private var toneMenu: some View {
        Menu {
            Picker("Tone", selection: Binding(get: { tone }, set: { toneRaw = $0.rawValue })) {
                ForEach(ReplyTone.allCases) { t in Text(t.label).tag(t) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 4) {
                Text(tone.label)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .bold))
            }
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(Color.ink)
            .padding(.horizontal, 12)
            .frame(height: 32)
        }
        .menuChrome(Capsule())
        .disabled(busy)
        .help("How the AI draft should sound: brief, friendly or formal")
        .accessibilityLabel("Tone: \(tone.label)")
    }

    private func draftButton(title: String) -> some View {
        Button(action: draftWithAI) { Label(title, systemImage: "sparkles") }
            .buttonStyle(SecondaryPill(height: 32))
            .disabled(busy)
            .help(hasText ? "Write the reply again with AI, from the message, its thread and your notes"
                : "Write a reply with AI, from the message, its thread and your notes")
    }

    @ViewBuilder
    private var status: some View {
        switch phase {
        case .drafting:
            HStack(spacing: Space.sm) {
                ReplyThinkingDots()
                Text("Writing a reply…")
                    .textStyle(.footnote)
                    .foregroundStyle(Color.ink2)
                Spacer(minLength: Space.sm)
                Button("Stop", action: stopDrafting)
                    .buttonStyle(SecondaryPill(height: 26))
                    .help("Stop writing")
            }
            .transition(.opacity)
        case .drafted:
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.ink3)
                Text(ReplyText.hasPlaceholders(text) ? "Drafted with AI. Fill in the parts in [brackets], then check it before you send."
                     : "Drafted with AI. Check it before you send.")
                    .textStyle(.footnote)
                    .foregroundStyle(Color.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Space.sm)
                if let previous {
                    Button("Undo") {
                        withAnimation(Motion.base) {
                            text = previous
                            self.previous = nil
                            phase = .idle
                        }
                    }
                    .buttonStyle(SecondaryPill(height: 26))
                    .help("Put back what you had before")
                }
            }
            .transition(.opacity)
        case .aiFailed(let message, let needsSettings):
            problem(message) {
                Button("Try again", action: draftWithAI)
                    .buttonStyle(SecondaryPill(height: 26))
                    .help("Ask AI again")
                if needsSettings {
                    Button("Open Settings") { SettingsView.show(.ai, app: app) }
                        .buttonStyle(SecondaryPill(height: 26))
                        .help("Open Settings → AI")
                }
            }
        case .failed(let message, let retry):
            problem(message) {
                Button("Retry") {
                    switch retry {
                    case .send: requestSend()
                    case .saveDraft: saveDraft(replyAll: replyAll && !others.isEmpty)
                    }
                }
                .buttonStyle(SecondaryPill(height: 26))
                .help(retry == .send ? "Try sending again (Docket asks first)" : "Try saving the draft again")
            }
        case .idle, .sending, .savingDraft:
            EmptyView()
        }
    }

    private func problem<Buttons: View>(_ message: String, @ViewBuilder buttons: () -> Buttons) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.dangerText)
                Text(message)
                    .textStyle(.footnote)
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Space.sm) { buttons() }
                .padding(.leading, 17)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.opacity)
    }

    /// The longest labels that fit, so nothing wraps in the narrowest pane. The ⌘↩ hint takes the same room
    /// whether or not there's anything to send, so typing never changes which labels show.
    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            actionRow(saveTitle: "Save as Gmail draft", iconCopy: false, hint: true)
            actionRow(saveTitle: "Save draft", iconCopy: false, hint: true)
            actionRow(saveTitle: "Save draft", iconCopy: false, hint: false)
            actionRow(saveTitle: "Save draft", iconCopy: true, hint: false)
        }
    }

    private func actionRow(saveTitle: String, iconCopy: Bool, hint: Bool) -> some View {
        HStack(spacing: Space.sm) {
            if canSend {
                Button(action: requestSend) {
                    Label(phase == .sending ? "Sending…" : (isEmail ? "Send reply" : "Send in thread"), systemImage: "paperplane")
                }
                .buttonStyle(LeadPill(primary: ReplyText.sendLeads(text, canSend: canSend)))
                .disabled(!canSendNow)
                .help(isEmail ? "Send this reply as you (⌘↩). Docket asks first."
                      : "Post this reply as you, in the message's thread (⌘↩). Docket asks first.")
                if isEmail {
                    Button(action: { saveDraft(replyAll: replyAll && !others.isEmpty) }) {
                        Text(phase == .savingDraft ? "Saving…" : saveTitle)
                    }
                    .buttonStyle(SecondaryPill(height: 34))
                    .disabled(!hasText || busy)
                    .help("Save it to your Gmail drafts, in this conversation, without sending")
                }
            }
            if iconCopy {
                Button(action: copy) { Image(systemName: "doc.on.doc") }
                    .buttonStyle(IconButtonStyle(size: 34, filled: true))
                    .disabled(!hasText)
                    .help("Copy the reply")
                    .accessibilityLabel("Copy the reply")
            } else {
                Button(action: copy) { Label("Copy", systemImage: "doc.on.doc") }
                    .buttonStyle(SecondaryPill(height: 34))
                    .disabled(!hasText)
                    .help("Copy the reply, to paste it anywhere")
            }
            Spacer(minLength: 0)
            if hint && canSend {
                KeyCap(text: "⌘↩")
                    .opacity(canSendNow ? 1 : 0.35)
                    .help("⌘↩ sends, after Docket asks")
            }
        }
    }

    private var confirmationMessage: String {
        var lines = ["“\(ReplyText.preview(text))”"]
        if ReplyText.hasPlaceholders(text) { lines.append("It still has parts in [brackets] to fill in.") }
        return lines.joined(separator: "\n\n")
    }

    // MARK: Actions

    private func draftWithAI() {
        guard !busy else { return }
        flush()
        drafting?.cancel()
        let id = item.id
        let tone = self.tone
        let ask = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        // AI answers the message the reply goes to (the one picked in the thread, or the default).
        let target = conversation.replyingTo
        withAnimation(Motion.base) { phase = .drafting }
        drafting = Task { @MainActor in
            do {
                let reply = try await integrations.draftReply(for: id, tone: tone, instruction: ask.isEmpty ? nil : ask, replyingTo: target)
                try Task.checkCancellation()
                let written = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !written.isEmpty else { throw AIError.badResponse("") }
                let before = text
                withAnimation(Motion.base) {
                    previous = before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : before
                    // The quote stays on top while Quote is on.
                    text = quote.map { ThreadText.adding(quote: $0, to: written) } ?? written
                    phase = .drafted
                }
                editorFocused = true
            } catch is CancellationError {
                // Stopped, or the message was closed.
            } catch {
                guard !Task.isCancelled else { return }
                phase = .aiFailed(error.localizedDescription, needsSettings: (error as? AIError)?.needsSettings ?? false)
            }
        }
    }

    private func stopDrafting() {
        drafting?.cancel()
        drafting = nil
        withAnimation(Motion.base) { phase = .idle }
    }

    /// Only ever asks: sending happens from the confirmation, to what it named (taken down now).
    private func requestSend() {
        guard canSendNow else { return }
        flush()
        let others = self.others
        let sendingTo = self.sendingTo(others: others)
        pending = PendingSend(title: confirmationTitle(others: others, sendingTo: sendingTo), replyingTo: conversation.sendTarget,
                              replyAll: replyAll && !others.isEmpty)
        confirming = true
    }

    /// Integrations marks the message Replied, clears the saved draft and says so in a toast; the reply shows
    /// in the thread at once.
    private func send(_ request: PendingSend) {
        guard canSendNow else { return }
        let body = text
        let id = item.id
        flush()
        withAnimation(Motion.base) { phase = .sending }
        // Not cancelled when the message closes: a reply on its way finishes, and says so.
        Task { @MainActor in
            do {
                try await integrations.sendReply(body, for: id, replyingTo: request.replyingTo, replyAll: request.replyAll)
                Haptics.success()
                conversation.didSend()
                withAnimation(Motion.base) {
                    if text == body { text = "" }
                    quote = nil
                    previous = nil
                    instruction = ""
                    replyAll = false
                    phase = .idle
                }
            } catch {
                withAnimation(Motion.base) { phase = .failed(Self.message(for: error, service: isEmail ? .gmail : .slack), retry: .send) }
            }
        }
    }

    private func saveDraft(replyAll all: Bool) {
        guard canSend, hasText, !busy else { return }
        let body = text
        let id = item.id
        // To the people the composer shows now, even if the conversation arrives meanwhile.
        let target = conversation.sendTarget
        flush()
        withAnimation(Motion.base) { phase = .savingDraft }
        Task { @MainActor in
            do {
                // The text stays here too; Integrations says it's saved.
                try await integrations.saveReplyAsDraft(body, for: id, replyingTo: target, replyAll: all)
                withAnimation(Motion.base) { phase = .idle }
            } catch {
                withAnimation(Motion.base) { phase = .failed(Self.message(for: error, service: .gmail), retry: .saveDraft) }
            }
        }
    }

    private func copy() {
        let reply = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(reply, forType: .string)
        app.showToast("Copied the reply")
    }

    private static func message(for error: Error, service: IntegrationError.Service) -> String {
        let e = IntegrationError.wrap(error, service)
        return e.errorDescription ?? "Something went wrong. Try again."
    }
}

/// Primary while it's the screen's next step, secondary otherwise.
struct LeadPill: ButtonStyle {
    var primary: Bool
    var height: CGFloat = 34

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        if primary {
            PrimaryPill(height: height).makeBody(configuration: configuration)
        } else {
            SecondaryPill(height: height).makeBody(configuration: configuration)
        }
    }
}

/// Three dots breathing in turn while AI writes. Still with Reduce Motion.
private struct ReplyThinkingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Color.ink)
                        .frame(width: 5, height: 5)
                        .opacity(reduceMotion ? 0.5 : Self.brightness(at: time, dot: i))
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Writing")
    }

    static func brightness(at time: TimeInterval, dot: Int) -> Double {
        var phase = (time - Double(dot) * 0.2).truncatingRemainder(dividingBy: 1.2) / 1.2
        if phase < 0 { phase += 1 }
        return 0.2 + 0.65 * (0.5 - 0.5 * cos(phase * 2 * .pi))
    }
}

// MARK: - A text box that grows

/// A TextEditor on a soft fill that grows with its text, between `minHeight` and `maxHeight` (then it
/// scrolls), with a placeholder. Used for the reply and for notes.
struct GrowingTextEditor: View {
    @Binding var text: String
    let placeholder: String
    var minHeight: CGFloat = 72
    var maxHeight: CGFloat = 320
    var focus: FocusState<Bool>.Binding
    var disabled = false
    @State private var contentHeight: CGFloat = 0

    private static let fontSize: CGFloat = 14
    /// One more line than the text, so the next line is always there to type into.
    private static let spare: CGFloat = 20

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: Self.fontSize))
            .foregroundStyle(Color.ink)
            .scrollContentBackground(.hidden)
            .focused(focus)
            .disabled(disabled)
            .frame(height: min(maxHeight, max(minHeight, contentHeight + Self.spare)))
            .background(alignment: .topLeading) {
                // An invisible copy of the text, wrapped at the same width, says how tall it is.
                Text(text.isEmpty ? " " : text + " ")
                    .font(.system(size: Self.fontSize))
                    .padding(.horizontal, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .hidden()
                    .background(GeometryReader { g in Color.clear.preference(key: EditorHeightKey.self, value: g.size.height) })
                    .accessibilityHidden(true)
            }
            .onPreferenceChange(EditorHeightKey.self) { contentHeight = $0 }
            .padding(.horizontal, Space.md - 5)
            .padding(.vertical, 10)
            .background(alignment: .topLeading) {
                if text.isEmpty {
                    // TextEditor has no placeholder: this sits where its first line starts.
                    Text(placeholder)
                        .font(.system(size: Self.fontSize))
                        .foregroundStyle(Color.ink3)
                        .padding(.leading, Space.md)
                        .padding(.top, 10)
                        .allowsHitTesting(false)
                }
            }
            .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(Color.fill))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .strokeBorder(focus.wrappedValue ? Color.ink.opacity(0.35) : Color.clear, lineWidth: 1.5)
            )
            .opacity(disabled ? 0.6 : 1)
            .animation(Motion.fast, value: focus.wrappedValue)
    }
}

private struct EditorHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
