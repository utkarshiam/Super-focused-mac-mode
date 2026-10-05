import AppKit
import CoreServices
import ImageIO
import Quartz
import SwiftUI
import UniformTypeIdentifiers

// The Slack and Email tabs of "From Slack & Gmail": the message list and the message detail (header,
// earlier messages, the complete message, attachments, notes, the suggested task and the reply).
// `SuggestionsView` in IntegrationViews.swift stays the entry point.

// MARK: - Layout and words (pure, so they're easy to test)

enum InboxLayout {
    /// Below this width the list shows alone, and a message opens in its place with a back button.
    static let twoPaneMinWidth: CGFloat = 720
    static let listWidth: CGFloat = 340
    /// The message column never gets wider than this, so lines stay readable in a wide window.
    static let readingWidth: CGFloat = 720

    static func isNarrow(_ width: CGFloat) -> Bool { width < twoPaneMinWidth }

    /// The message to open once `id` has left the list (added as a task, dismissed): the one that was below
    /// it, else the one above, else the first.
    static func successor(of id: String, before: [String], after: [String]) -> String? {
        let remaining = Set(after)
        if remaining.contains(id) { return id }
        guard let i = before.firstIndex(of: id) else { return after.first }
        return before[(i + 1)...].first(where: remaining.contains) ?? before[..<i].last(where: remaining.contains) ?? after.first
    }

    /// ↑ / ↓ through the list, stopping at the ends. With nothing selected, ↓ starts at the top and ↑ at the bottom.
    static func step(from id: String?, by delta: Int, in ids: [String]) -> String? {
        guard !ids.isEmpty else { return nil }
        guard let id, let i = ids.firstIndex(of: id) else { return delta > 0 ? ids.first : ids.last }
        return ids[min(max(i + delta, 0), ids.count - 1)]
    }
}

/// What the list and the detail say about a message.
enum InboxItemText {
    static let filesScope = InboxScopes.slackFiles
    static var historyScopes: Set<String> { InboxScopes.slackHistory }

    /// AI proposed a real task for it, not just the plain "Slack: …" / "Reply to Sam" stand-in.
    static func hasSuggestedTask(_ s: Suggestion) -> Bool {
        guard let draft = s.draft else { return false }
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return !title.isEmpty && title != SuggestionDrafts.title(for: s)
    }

    /// A Slack message that answers another one in a thread (not the thread's first message).
    static func isThreadReply(_ s: Suggestion) -> Bool {
        guard s.source.kind == .slack, let parent = s.threadTS, !parent.isEmpty else { return false }
        return !s.id.hasSuffix("/" + parent)
    }

    /// Where a Slack message was posted ("#leadership", "Direct message"), from its label.
    static func place(of s: Suggestion) -> String {
        let place = s.source.label.components(separatedBy: " · ").first?.trimmingCharacters(in: .whitespaces) ?? ""
        return place.isEmpty ? "Slack" : place
    }

    /// The second line: "#leadership · in a thread", "Direct message", or the email's subject.
    static func context(of s: Suggestion) -> String {
        switch s.source.kind {
        case .gmail:
            let subject = s.subject?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return subject.isEmpty ? "(no subject)" : subject
        case .slack, .ai:
            return isThreadReply(s) ? "\(place(of: s)) · in a thread" : place(of: s)
        }
    }

    /// Files to list under a message. In an email shown formatted, the images its HTML shows inline are
    /// already in the body (all but ones too big to put in the page). `inline`: the Content-IDs the HTML
    /// shows, when they're already known.
    static func listedAttachments(_ content: MessageContent, showsHTML: Bool, inline known: Set<String>? = nil) -> [MessageAttachment] {
        guard showsHTML, let html = content.html, !html.isEmpty else { return content.attachments }
        let inline = known ?? MailHTML.referencedContentIDs(in: html)
        guard !inline.isEmpty else { return content.attachments }
        return content.attachments.filter { a in
            guard let cid = a.contentID, (a.size ?? 0) <= MailHTML.maxInlineBytes else { return true }
            return !inline.contains(MailHTML.normalizedContentID(cid))
        }
    }

    /// The 📎 count in the list (images with a Content-ID count as part of an email's body).
    static func attachmentCount(_ s: Suggestion) -> Int {
        (s.content?.attachments ?? []).filter { !($0.contentID != nil && $0.isImage) }.count
    }

    /// The banner when the Docket app in Slack was made before Docket showed files and threads.
    static func slackPermissionBanner(missing: Set<String>) -> String? {
        let files = missing.contains(filesScope)
        let threads = !missing.isDisjoint(with: historyScopes)
        switch (files, threads) {
        case (true, true): return "Docket needs two more Slack permissions to show files and threads."
        case (true, false): return "Docket needs one more Slack permission to show files."
        case (false, true): return "Docket needs one more Slack permission to show threads."
        case (false, false): return nil
        }
    }

    /// What works differently until then (Connections).
    static func slackPermissionEffect(missing: Set<String>) -> String {
        let files = missing.contains(filesScope)
        let threads = !missing.isDisjoint(with: historyScopes)
        switch (files, threads) {
        case (true, false): return "Until then, files open in Slack. Everything else works."
        case (false, true): return "Until then, threads stay hidden. Everything else works."
        default: return "Until then, files open in Slack and threads stay hidden. Everything else works."
        }
    }

    /// "Maya Chen, alex@acme.example": names where the address has one.
    static func people(_ entries: [String]) -> String {
        entries.map { MailSender(header: $0).displayName }.joined(separator: ", ")
    }

    /// "3 earlier messages".
    static func earlierTitle(_ count: Int) -> String {
        count == 1 ? "1 earlier message" : "\(count) earlier messages"
    }

    /// Who wrote the earlier messages, newest first, each once ("You" for your own), at most three.
    static func earlierPeople(_ messages: [ThreadMessage]) -> String {
        var seen = Set<String>()
        let names = messages.reversed().map { $0.isMine ? "You" : $0.from }.filter { seen.insert($0).inserted }
        return names.count > 3 ? names.prefix(3).joined(separator: ", ") + "…" : names.joined(separator: ", ")
    }
}

/// Attachments: an icon per kind, sizes, safe names, and which files Docket won't open.
enum AttachmentInfo {
    /// The type, from the MIME type, or from the name when the MIME type says nothing useful.
    static func type(of a: MessageAttachment) -> UTType? {
        let byName = UTType(filenameExtension: (a.name as NSString).pathExtension.lowercased())
        guard let byMime = UTType(mimeType: a.mimeType.lowercased()), byMime != .data else { return byName }
        return byMime
    }

    /// An SF Symbol for the kind of file.
    static func symbol(for a: MessageAttachment) -> String {
        guard let type = type(of: a) else { return "doc" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return "film" }
        if type.conforms(to: .audio) { return "waveform" }
        if type.conforms(to: .pdf) { return "doc.richtext" }
        if type.conforms(to: .archive) { return "doc.zipper" }
        if type.conforms(to: .spreadsheet) { return "tablecells" }
        if type.conforms(to: .presentation) { return "rectangle.on.rectangle.angled" }
        if type.conforms(to: .calendarEvent) { return "calendar" }
        if type.conforms(to: .vCard) || type.conforms(to: .contact) { return "person.crop.square" }
        if type.conforms(to: .sourceCode) || type.conforms(to: .script) { return "chevron.left.forwardslash.chevron.right" }
        if type.conforms(to: .text) || type.conforms(to: .rtf) { return "doc.text" }
        return "doc"
    }

    /// "240 KB".
    static func size(_ bytes: Int?) -> String? {
        guard let bytes, bytes >= 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// Apps, installers, scripts and other files that do something when opened (web pages too: a browser
    /// would run their scripts): Docket previews and saves them, but never opens them.
    static let runnableExtensions: Set<String> = [
        "app", "command", "tool", "sh", "bash", "zsh", "csh", "ksh", "fish", "py", "pl", "rb", "php", "js", "jar",
        "pkg", "mpkg", "scpt", "scptd", "applescript", "workflow", "action", "terminal", "fileloc", "webloc", "inetloc",
        "prefpane", "saver", "kext", "plugin", "bundle", "mobileconfig", "dylib", "so", "exe", "msi", "bat", "cmd",
        "vbs", "ps1", "wsf", "osax", "xpc", "shortcut", "dmg",
        "html", "htm", "xhtml", "shtml", "mht", "mhtml", "webarchive", "svg", "svgz", "hta",
    ]

    static func isRunnable(_ a: MessageAttachment) -> Bool {
        let ext = (a.name as NSString).pathExtension.lowercased()
        if runnableExtensions.contains(ext) { return true }
        let types = [UTType(filenameExtension: ext), UTType(mimeType: a.mimeType.lowercased())].compactMap { $0 }
        return types.contains { t in
            t.conforms(to: .executable) || t.conforms(to: .script) || t.conforms(to: .shellScript)
                || t.conforms(to: .application) || t.conforms(to: .applicationBundle)
                || t.conforms(to: .html) || t.conforms(to: .webArchive) || t.conforms(to: .svg)
        }
    }

    /// "report.pdf", or "report 2.pdf" when that's taken (and so on).
    static func uniqueName(_ name: String, taken: (String) -> Bool) -> String {
        guard taken(name) else { return name }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        for n in 2...999 {
            let candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            if !taken(candidate) { return candidate }
        }
        return ext.isEmpty ? "\(base) \(UUID().uuidString.prefix(8))" : "\(base) \(UUID().uuidString.prefix(8)).\(ext)"
    }
}

// MARK: - Selection and keys

/// The open message in each tab, the narrow window's list-or-detail, and the arrow keys.
@MainActor
final class InboxModel: ObservableObject {
    @Published var selected: [TaskSource.Kind: String] = [:]
    /// Narrow window: the open message shows in place of the list.
    @Published var showsDetail = false
    /// The tab on screen and whether the window is narrow, kept up to date by the panes.
    var kind: TaskSource.Kind = .slack
    var isNarrow = false
    private var monitor: Any?

    /// Posted before acting on several messages at once (Add all), so notes still being typed are saved first.
    static let saveEditsNow = Notification.Name("DocketInboxSaveEditsNow")

    func select(_ id: String?, in kind: TaskSource.Kind) {
        guard selected[kind] != id else { return }
        selected[kind] = id
    }

    /// ↑/↓ move through the list, Return opens the message and Esc goes back (narrow window). Only when the
    /// keyboard isn't in a text field, and only on this screen.
    func startWatchingKeys(app: AppState) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak app] event in
            guard let self, let app else { return event }
            return self.handle(event, app: app) ? nil : event
        }
    }

    func stopWatchingKeys() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent, app: AppState) -> Bool {
        guard let window = event.window, window === NSApp.docketMainWindow, window.attachedSheet == nil,
              !(window.firstResponder is NSText), !app.showPalette, app.selection == .suggestions,
              event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return false }
        let ids = Integrations.shared.items(kind).map(\.id)
        switch event.keyCode {
        case 125, 126: // down, up
            guard let next = InboxLayout.step(from: selected[kind], by: event.keyCode == 125 ? 1 : -1, in: ids) else { return false }
            select(next, in: kind)
            return true
        case 36, 76: // return, enter
            guard isNarrow, !showsDetail, let id = selected[kind].flatMap({ ids.contains($0) ? $0 : nil }) ?? ids.first else { return false }
            select(id, in: kind)
            withAnimation(Motion.snappy) { showsDetail = true }
            return true
        case 53: // esc
            guard isNarrow, showsDetail else { return false }
            withAnimation(Motion.snappy) { showsDetail = false }
            return true
        default:
            return false
        }
    }
}

// MARK: - The panes

/// One tab: the list and the open message side by side, or one at a time in a narrow window.
struct InboxPanes: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var model: InboxModel
    @ObservedObject private var integrations = Integrations.shared
    @AppStorage(Prefs.Key.slackSaveEmoji) private var saveEmoji = SlackSaveEmoji.standard
    let kind: TaskSource.Kind
    /// Opens the Connections sheet.
    let connect: () -> Void
    /// Starts updating the Docket app in Slack (new permissions).
    let updateSlack: () -> Void
    /// The ids on screen last time, to find the next message when the open one leaves.
    @State private var shownIDs: [String] = []

    var body: some View {
        let items = integrations.items(kind)
        let ids = items.map(\.id)
        GeometryReader { geo in
            let narrow = InboxLayout.isNarrow(geo.size.width)
            Group {
                if items.isEmpty {
                    emptyState
                } else if narrow {
                    if model.showsDetail, let item = selectedItem(in: items) {
                        detail(item, paneHeight: geo.size.height, narrow: true)
                            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
                    } else {
                        list(items)
                            .transition(.opacity)
                    }
                } else {
                    HStack(spacing: 0) {
                        list(items)
                            .frame(width: InboxLayout.listWidth)
                        Rectangle().fill(Color.hair).frame(width: 1)
                        if let item = selectedItem(in: items) {
                            detail(item, paneHeight: geo.size.height, narrow: false)
                        } else {
                            EmptyState(icon: kind == .slack ? "number" : "envelope", title: "No message open",
                                       message: "Pick one on the left, or use ↑ and ↓.")
                        }
                    }
                }
            }
            .onAppear {
                model.isNarrow = narrow
                pickIfNeeded(ids)
            }
            .onChange(of: narrow) { isNarrow in
                model.isNarrow = isNarrow
                if !isNarrow { model.showsDetail = false }
            }
        }
        .onAppear {
            model.kind = kind
            model.showsDetail = false
            shownIDs = ids
            pickIfNeeded(ids)
        }
        .onChange(of: ids) { now in
            follow(now)
            shownIDs = now
        }
    }

    private func selectedItem(in items: [Suggestion]) -> Suggestion? {
        guard let id = model.selected[kind] else { return nil }
        return items.first { $0.id == id }
    }

    /// Something is always open in the two-pane layout: the newest message, to start with.
    private func pickIfNeeded(_ ids: [String]) {
        if let current = model.selected[kind], ids.contains(current) { return }
        model.select(ids.first, in: kind)
    }

    /// The open message left the list: open the one that took its place.
    private func follow(_ ids: [String]) {
        guard let current = model.selected[kind] else { return pickIfNeeded(ids) }
        guard !ids.contains(current) else { return }
        let next = InboxLayout.successor(of: current, before: shownIDs, after: ids)
        model.select(next, in: kind)
        if next == nil { model.showsDetail = false }
    }

    private func list(_ items: [Suggestion]) -> some View {
        InboxList(items: items, selectedID: model.selected[kind]) { id in
            model.select(id, in: kind)
            if model.isNarrow { withAnimation(Motion.snappy) { model.showsDetail = true } }
        }
    }

    private func detail(_ item: Suggestion, paneHeight: CGFloat, narrow: Bool) -> some View {
        InboxDetail(item: item, paneHeight: paneHeight,
                    back: narrow ? { withAnimation(Motion.snappy) { model.showsDetail = false } } : nil,
                    backTitle: kind == .slack ? "Slack" : "Email", updateSlack: updateSlack)
            .id(item.id)
    }

    // MARK: Empty, loading, not connected

    @ViewBuilder
    private var emptyState: some View {
        let connected = kind == .slack ? integrations.isSlackConnected : integrations.isGmailConnected
        if !connected {
            InboxPitch(kind: kind, saveEmoji: saveEmoji, connect: connect)
        } else if integrations.isRefreshing && integrations.lastRefresh == nil {
            VStack(spacing: Space.md) {
                ProgressView().controlSize(.small)
                Text("Looking for messages that need you…").textStyle(.callout).foregroundStyle(Color.ink2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if kind == .slack {
            EmptyState(icon: "number", title: "Nothing from Slack",
                       message: "React with \(SlackSaveEmoji.glyph(saveEmoji)) to a message and it shows up here.")
        } else {
            EmptyState(icon: "envelope", title: "Nothing from Gmail", message: "Star an email and it shows up here.")
        }
    }
}

/// A tab whose service isn't connected: what it's for, and the way in.
private struct InboxPitch: View {
    let kind: TaskSource.Kind
    let saveEmoji: String
    let connect: () -> Void

    var body: some View {
        VStack(spacing: Space.md) {
            Image(systemName: kind == .slack ? "number" : "envelope")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(Color.ink)
                .frame(width: 56, height: 56)
                .background(Circle().fill(Color.fill))
            Text(kind == .slack ? "Bring in Slack" : "Bring in Gmail")
                .textStyle(.title3)
                .foregroundStyle(Color.ink)
            Text(kind == .slack
                 ? "Messages you react to with \(SlackSaveEmoji.glyph(saveEmoji)), and the ones that @mention you, show up here with their files and threads, ready to answer or turn into tasks."
                 : "Emails you star, and the ones waiting on your reply, show up here with their attachments, ready to answer or turn into tasks.")
                .textStyle(.callout)
                .foregroundStyle(Color.ink2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button(kind == .slack ? "Connect Slack" : "Connect Gmail", action: connect)
                .buttonStyle(PrimaryPill())
                .help(kind == .slack ? "Set up Slack in Connections" : "Set up Gmail in Connections")
                .padding(.top, Space.xs)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Space.x4)
        .enterUp()
    }
}

// MARK: - The list

private struct InboxList: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var integrations = Integrations.shared
    let items: [Suggestion]
    let selectedID: String?
    let select: (String) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                EnterUpWindow {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                            InboxRow(item: item, isSelected: item.id == selectedID)
                                .id(item.id)
                                .onTapGesture {
                                    // Clicking a message puts the keyboard on the list (↑ / ↓), out of the notes or reply.
                                    if let window = NSApp.keyWindow, window.firstResponder is NSText {
                                        window.makeFirstResponder(nil)
                                    }
                                    select(item.id)
                                }
                                .contextMenu { menu(for: item) }
                                .enterUp(i)
                        }
                    }
                    .padding(.horizontal, Space.sm)
                    .padding(.top, Space.sm)
                    .padding(.bottom, Space.x4)
                }
            }
            .onChange(of: selectedID) { id in
                if let id { withAnimation(Motion.snappy) { proxy.scrollTo(id) } }
            }
            .onAppear {
                if let selectedID { proxy.scrollTo(selectedID) }
            }
        }
        .background(Color.paper)
    }

    @ViewBuilder
    private func menu(for item: Suggestion) -> some View {
        Button("Add Task") {
            NotificationCenter.default.post(name: InboxModel.saveEditsNow, object: nil)
            // As it is now, with the notes just saved (this row's copy can be a keystroke behind).
            let current = integrations.suggestion(item.id) ?? item
            withAnimation(Motion.gentle) { _ = integrations.add(current) }
        }
        if item.source.url?.scheme == "https" {
            Button(SourceStyle.openTitle(item.source.kind)) { integrations.open(item) }
        }
        Divider()
        Button("Dismiss") { withAnimation(Motion.gentle) { integrations.dismiss(item) } }
    }
}

/// One message in the list: who, where (or the subject), two lines of it, when, and small chips.
private struct InboxRow: View {
    let item: Suggestion
    let isSelected: Bool
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                Text(item.from)
                    .font(.system(size: 14, weight: .bold))
                    .tracking(-0.1)
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                Spacer(minLength: Space.xs)
                Text(Fmt.dateTime(item.receivedAt))
                    .font(.system(size: 11.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color.ink3)
                    .lineLimit(1)
                    .fixedSize()
            }
            Text(InboxItemText.context(of: item))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.ink)
                .lineLimit(1)
            if !item.snippet.isEmpty {
                Text(item.snippet)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.ink2)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            chips
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(isSelected ? Color.fill : (hovering ? Color.pressedTint : Color.clear)))
        .overlay(shape.strokeBorder(isSelected ? Color.hairStrong : Color.clear, lineWidth: 1))
        .contentShape(Rectangle())
        .onHover { h in withAnimation(Motion.fast) { hovering = h } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private var chips: some View {
        let files = InboxItemText.attachmentCount(item)
        let suggested = InboxItemText.hasSuggestedTask(item)
        if files > 0 || suggested || item.repliedAt != nil {
            HStack(spacing: 6) {
                if files > 0 {
                    Badge(text: "\(files)", icon: "paperclip")
                        .help(Fmt.plural(files, "attachment"))
                }
                if suggested {
                    Badge(text: "Task suggested", icon: "checklist")
                        .help(item.draft?.title ?? "")
                }
                if let replied = item.repliedAt {
                    Badge(text: "Replied", tone: .success, icon: "arrowshape.turn.up.left")
                        .help("You replied on \(Fmt.dateTime(replied))")
                }
            }
            .padding(.top, 3)
        }
    }
}

// MARK: - The message

/// The open message: who and when, earlier messages, the whole message and its files, then your notes,
/// the suggested task and your reply. Notes and the reply are saved as you type (once typing pauses).
struct InboxDetail: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var app: AppState
    @ObservedObject private var integrations = Integrations.shared
    @AppStorage(InboxDetail.plainTextKey) private var plainText = false
    @AppStorage(Prefs.Key.slackSaveEmoji) private var saveEmoji = SlackSaveEmoji.standard

    static let plainTextKey = "inboxMailPlainText"

    let item: Suggestion
    let paneHeight: CGFloat
    /// Narrow window: back to the list.
    let back: (() -> Void)?
    let backTitle: String
    let updateSlack: () -> Void

    @State private var loaded: MessageContent?
    @State private var loading = false
    @State private var loadProblem: String?
    @State private var note: String
    @State private var reply: String
    /// What was last handed to Integrations, so only real edits are saved.
    @State private var savedNote: String
    @State private var savedReply: String
    @State private var noteSave: Task<Void, Never>?
    @State private var replySave: Task<Void, Never>?
    @StateObject private var quickLook = QuickLookController()
    @StateObject private var htmlFacts = MailHTMLFacts()
    @FocusState private var noteFocused: Bool

    /// How long typing has to pause before notes or the reply are saved.
    private static let saveDelay: UInt64 = 600_000_000

    init(item: Suggestion, paneHeight: CGFloat, back: (() -> Void)?, backTitle: String, updateSlack: @escaping () -> Void) {
        self.item = item
        self.paneHeight = paneHeight
        self.back = back
        self.backTitle = backTitle
        self.updateSlack = updateSlack
        _note = State(initialValue: item.note)
        _savedNote = State(initialValue: item.note)
        _reply = State(initialValue: item.replyDraft)
        _savedReply = State(initialValue: item.replyDraft)
    }

    private var content: MessageContent? { item.content ?? loaded }
    private var isEmail: Bool { item.source.kind == .gmail }
    private var hasHTML: Bool { content?.html.map(MailHTML.hasContent) ?? false }
    private var showsHTML: Bool { isEmail && !plainText && hasHTML }
    /// Gmail needs the compose permission; Slack only needs to be connected.
    private var canSend: Bool { isEmail ? integrations.gmailCanCompose : integrations.isSlackConnected }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                header
                ThreadSection(item: item, updateSlack: updateSlack)
                message
                attachments
                Rectangle().fill(Color.hair).frame(height: 1)
                notes
                SuggestedTaskSection(item: item, leads: !ReplyText.sendLeads(reply, canSend: canSend), saveEdits: flush)
                ReplyComposer(item: item, text: $reply, content: content, canSend: canSend, flush: flush,
                              reconnectGmail: { integrations.connectGmail() })
            }
            .frame(maxWidth: InboxLayout.readingWidth, alignment: .leading)
            .padding(.horizontal, Space.xl)
            .padding(.top, Space.lg)
            .padding(.bottom, Space.x6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.paper)
        .background(QuickLookAnchor(controller: quickLook).frame(width: 0, height: 0))
        .task(id: item.id) { await load() }
        .onChange(of: note) { _ in scheduleSave(note: true) }
        .onChange(of: reply) { _ in scheduleSave(note: false) }
        .onDisappear(perform: flush)
        .onReceive(NotificationCenter.default.publisher(for: InboxModel.saveEditsNow)) { _ in flush() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in flush() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            flush()
            // Quitting: on disk now, not after the pause in typing that a save normally waits for.
            integrations.flushSaves()
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            if let back {
                Button(action: back) { Label(backTitle, systemImage: "chevron.left") }
                    .buttonStyle(SecondaryPill(height: 28))
                    .help("Back to the list (esc)")
                    .padding(.bottom, Space.xs)
            }
            HStack(alignment: .top, spacing: Space.md) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.from)
                        .textStyle(.title3)
                        .foregroundStyle(Color.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(InboxItemText.context(of: item))
                        .textStyle(.headline)
                        .foregroundStyle(Color.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    dateLine
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                if item.source.url?.scheme == "https" {
                    Button { integrations.open(item) } label: {
                        Label(SourceStyle.openTitle(item.source.kind), systemImage: "arrow.up.right")
                    }
                    .buttonStyle(SecondaryPill(height: 30))
                    .help(isEmail ? "See the conversation in Gmail" : "See the message in Slack")
                }
            }
            if isEmail, let content, !(content.to.isEmpty && content.cc.isEmpty) {
                VStack(alignment: .leading, spacing: 2) {
                    if !content.to.isEmpty { recipients("To", content.to) }
                    if !content.cc.isEmpty { recipients("Cc", content.cc) }
                }
            }
        }
    }

    /// The date and time stay whole: in a narrow pane, why it's here goes on a line of its own.
    private var dateLine: some View {
        let date = Text(Fmt.dateTime(item.receivedAt)).monospacedDigit()
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                date
                if let why {
                    Text("·")
                    Text(why)
                }
            }
            .fixedSize()
            VStack(alignment: .leading, spacing: 2) {
                date
                if let why { Text(why) }
            }
        }
        .font(.system(size: 12.5, weight: .medium))
        .foregroundStyle(Color.ink2)
        .lineLimit(1)
    }

    private var why: String? {
        switch item.trigger {
        case .reaction?: "Saved with \(SlackSaveEmoji.glyph(saveEmoji))"
        case .mention?: "Mentions you"
        case .starred?: "Starred"
        case .needsReply?: "Waiting on your reply"
        case nil: nil
        }
    }

    private func recipients(_ label: String, _ entries: [String]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color.ink3)
                .frame(width: 20, alignment: .leading)
            Text(InboxItemText.people(entries))
                .textStyle(.caption)
                .foregroundStyle(Color.ink2)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .help(entries.joined(separator: ", "))
    }

    // MARK: The complete message

    @ViewBuilder
    private var message: some View {
        if let content {
            VStack(alignment: .leading, spacing: Space.sm) {
                if isEmail, hasHTML {
                    HStack {
                        Spacer()
                        Button { withAnimation(Motion.base) { plainText.toggle() } } label: {
                            Label("Plain text", systemImage: plainText ? "checkmark" : "text.alignleft")
                        }
                        .buttonStyle(SecondaryPill(height: 26))
                        .help(plainText ? "Show emails formatted again" : "Show emails as plain text")
                    }
                }
                messageBody(content)
            }
        } else {
            VStack(alignment: .leading, spacing: Space.md) {
                LinkedTextView(text: item.snippet, color: .ink2)
                if loading {
                    HStack(spacing: Space.sm) {
                        ProgressView().controlSize(.small)
                        Text("Loading the whole message…").textStyle(.footnote).foregroundStyle(Color.ink2)
                    }
                } else if let loadProblem, !DebugSnapshot.isActive {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.warning)
                        Text("Showing the preview. \(loadProblem)")
                            .textStyle(.footnote)
                            .foregroundStyle(Color.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: Space.sm)
                        Button("Retry") { Task { await load() } }
                            .buttonStyle(SecondaryPill(height: 26))
                            .help("Try loading the whole message again")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func messageBody(_ content: MessageContent) -> some View {
        let text = content.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? item.snippet : content.text
        // The text views are `.equatable()`: typing in the notes or the reply redraws this detail, and a long
        // message shouldn't be laid out again for every keystroke.
        if item.source.kind == .slack, let markup = content.markup, !markup.isEmpty {
            SlackMessageText(markup: markup, names: integrations.slackNames)
                .equatable()
        } else if showsHTML, let html = content.html {
            MailBodyView(html: html, inlineParts: content.attachments.filter { $0.contentID != nil },
                         fetch: { part in try await integrations.file(for: part, messageID: item.id) },
                         paneHeight: paneHeight, plainText: text)
        } else {
            LinkedTextView(text: text)
                .equatable()
        }
    }

    @ViewBuilder
    private var attachments: some View {
        if let content {
            let inline = showsHTML ? content.html.map(htmlFacts.inlineContentIDs) : nil
            let files = InboxItemText.listedAttachments(content, showsHTML: showsHTML, inline: inline)
            if !files.isEmpty {
                AttachmentsSection(item: item, attachments: files, quickLook: quickLook,
                                   filesBlocked: item.source.kind == .slack && integrations.missingSlackScopes.contains(InboxItemText.filesScope),
                                   updateSlack: updateSlack)
            }
        }
    }

    // MARK: Notes

    private var notes: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Eyebrow(text: "Your notes")
            GrowingTextEditor(text: $note, placeholder: "Add notes: what to do, what to say back…",
                              minHeight: 56, maxHeight: 240, focus: $noteFocused)
                .help("Your notes on this message. They go into the task if you add one, and AI follows them when it drafts a reply.")
            Text("Saved as you type. They go into the task if you add one, and AI follows them when it drafts a reply.")
                .textStyle(.footnote)
                .foregroundStyle(Color.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Loading and saving

    private func load() async {
        guard item.content == nil else { return }
        loading = true
        loadProblem = nil
        do {
            let content = try await integrations.content(for: item.id)
            guard !Task.isCancelled else { return }
            loaded = content
        } catch is CancellationError {
            // Closed before it arrived.
        } catch {
            guard !Task.isCancelled else { return }
            loadProblem = IntegrationError.wrap(error, isEmail ? .gmail : .slack).errorDescription
        }
        loading = false
    }

    private func scheduleSave(note isNote: Bool) {
        let task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.saveDelay)
            guard !Task.isCancelled else { return }
            if isNote { saveNote() } else { saveReply() }
        }
        if isNote {
            noteSave?.cancel()
            noteSave = task
        } else {
            replySave?.cancel()
            replySave = task
        }
    }

    private func saveNote() {
        guard note != savedNote else { return }
        integrations.setNote(note, for: item.id)
        savedNote = note
    }

    private func saveReply() {
        guard reply != savedReply else { return }
        integrations.setReplyDraft(reply, for: item.id)
        savedReply = reply
    }

    /// Saves whatever was typed and not saved yet (before AI reads the notes, before sending, on leaving).
    private func flush() {
        noteSave?.cancel()
        replySave?.cancel()
        saveNote()
        saveReply()
    }
}

/// A Slack message as Slack shows it: bold, italics, code, links, people and channels by name.
private struct SlackMessageText: View, Equatable {
    let markup: String
    let names: [String: String]

    var body: some View {
        Text(SlackText.attributed(markup, names: names))
            .font(.system(size: 15))
            .foregroundStyle(Color.bodyText)
            .lineSpacing(3)
            .tint(Color.ink)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .safeLinks()
    }
}

// MARK: - Earlier messages

/// "3 earlier messages", collapsed until clicked. Loaded once the message has been open a moment, so
/// arrowing past messages doesn't fetch each one's thread.
private struct ThreadSection: View {
    @ObservedObject private var integrations = Integrations.shared
    let item: Suggestion
    let updateSlack: () -> Void

    private enum LoadState: Equatable {
        case waiting
        case loading
        case loaded([ThreadMessage])
        case failed(String)
    }

    @State private var state: LoadState = .waiting
    @State private var expanded = false

    private var isSlackReply: Bool { InboxItemText.isThreadReply(item) }
    /// A Slack reply whose thread Docket isn't allowed to read yet.
    private var needsPermission: Bool {
        isSlackReply && !integrations.missingSlackScopes.isDisjoint(with: InboxItemText.historyScopes)
    }

    var body: some View {
        Group {
            switch state {
            case .loaded(let messages) where !messages.isEmpty:
                disclosure(messages)
            case .loaded:
                if needsPermission { permissionRow }
            case .waiting, .loading:
                if isSlackReply { loadingRow }
            case .failed(let message):
                failureRow(message)
            }
        }
        .animation(Motion.base, value: state)
        .task(id: item.id) { await load(after: 250_000_000) }
    }

    private func disclosure(_ messages: [ThreadMessage]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(Motion.snappy) { expanded.toggle() } } label: {
                HStack(spacing: Space.sm) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.ink2)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 12)
                    Text(InboxItemText.earlierTitle(messages.count))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.ink)
                    Text(InboxItemText.earlierPeople(messages))
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.ink3)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Space.md)
                .frame(height: 38)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "Hide the earlier messages" : "Show the earlier messages in this \(item.source.kind == .gmail ? "conversation" : "thread")")
            if expanded {
                VStack(alignment: .leading, spacing: Space.md) {
                    ForEach(messages) { m in ThreadMessageRow(message: m) }
                }
                .padding(.horizontal, Space.md)
                .padding(.top, Space.xs)
                .padding(.bottom, Space.md)
                .transition(.opacity)
            }
        }
        .hairlineCard(radius: Radius.md)
    }

    private var loadingRow: some View {
        HStack(spacing: Space.sm) {
            ProgressView().controlSize(.small)
            Text("Earlier in this thread…")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.ink2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.md)
        .frame(height: 38)
        .hairlineCard(radius: Radius.md)
    }

    private var permissionRow: some View {
        HStack(alignment: .center, spacing: Space.sm) {
            Image(systemName: "lock")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.ink3)
            Text("This is a reply in a thread. Showing the thread needs one more Slack permission.")
                .textStyle(.footnote)
                .foregroundStyle(Color.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Space.sm)
            Button("Update the app", action: updateSlack)
                .buttonStyle(SecondaryPill(height: 26))
                .help("Create the Docket app in Slack again with the new permissions")
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, 8)
        .hairlineCard(radius: Radius.md)
    }

    private func failureRow(_ message: String) -> some View {
        HStack(alignment: .center, spacing: Space.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.warning)
            Text("Couldn't load the earlier messages. \(message)")
                .textStyle(.footnote)
                .foregroundStyle(Color.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Space.sm)
            Button("Retry") { Task { await load(after: 0) } }
                .buttonStyle(SecondaryPill(height: 26))
                .help("Try loading them again")
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, 8)
        .hairlineCard(radius: Radius.md)
    }

    private func load(after delay: UInt64) async {
        if delay > 0 {
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
        }
        state = .loading
        do {
            let messages = try await integrations.thread(for: item.id)
            guard !Task.isCancelled else { return }
            state = .loaded(messages)
        } catch is CancellationError {
            // Closed before it arrived.
        } catch {
            guard !Task.isCancelled else { return }
            state = .failed(IntegrationError.wrap(error, item.source.kind == .gmail ? .gmail : .slack).errorDescription ?? "")
        }
    }
}

private struct ThreadMessageRow: View {
    let message: ThreadMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(message.isMine ? "You" : message.from)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                Text(Fmt.dateTime(message.date))
                    .font(.system(size: 11.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Color.ink3)
                    .lineLimit(1)
            }
            LinkedTextView(text: message.text, size: 13.5)
        }
        .padding(.leading, Space.md)
        .overlay(alignment: .leading) {
            Capsule().fill(message.isMine ? Color.ink3 : Color.hairStrong).frame(width: 2)
        }
    }
}

// MARK: - Attachments

/// Images as a grid of thumbnails, other files as chips. A click downloads the file once (it's kept in
/// IntegrationCache/) and shows it in Quick Look; files are never run.
private struct AttachmentsSection: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var integrations = Integrations.shared
    let item: Suggestion
    let attachments: [MessageAttachment]
    let quickLook: QuickLookController
    /// Slack without files:read: the names only; they open in Slack.
    let filesBlocked: Bool
    let updateSlack: () -> Void
    @StateObject private var files = AttachmentFiles()

    var body: some View {
        let images = filesBlocked ? [] : attachments.filter { $0.isImage && !AttachmentFiles.isTooBig($0) }
        let imageIDs = Set(images.map(\.id))
        let others = attachments.filter { !imageIDs.contains($0.id) }
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Eyebrow(text: "Attachments")
                Text("\(attachments.count)")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color.ink3)
            }
            if !images.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104, maximum: 180), spacing: Space.sm)], alignment: .leading, spacing: Space.sm) {
                    ForEach(images) { a in
                        ImageTile(attachment: a, status: files.status[a.id], thumbnail: files.thumbnails[a.id]) { preview(a, among: images) }
                            .contextMenu { menu(for: a) }
                            .task { await files.loadThumbnail(a, messageID: item.id) }
                    }
                }
            }
            if !others.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: Space.sm)], alignment: .leading, spacing: Space.sm) {
                    ForEach(others) { a in
                        FileChip(attachment: a, status: files.status[a.id], opensOutside: filesBlocked || AttachmentFiles.isTooBig(a),
                                 service: item.source.kind == .gmail ? "Gmail" : "Slack") { preview(a, among: []) }
                            .contextMenu { menu(for: a) }
                    }
                }
            }
            if filesBlocked {
                HStack(alignment: .center, spacing: Space.sm) {
                    Text("Files open in Slack until the Docket app there has one more permission.")
                        .textStyle(.footnote)
                        .foregroundStyle(Color.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: Space.sm)
                    Button("Update the app", action: updateSlack)
                        .buttonStyle(SecondaryPill(height: 26))
                        .help("Create the Docket app in Slack again with the new permissions")
                }
            }
        }
    }

    @ViewBuilder
    private func menu(for a: MessageAttachment) -> some View {
        if filesBlocked || AttachmentFiles.isTooBig(a) {
            if item.source.url?.scheme == "https" {
                Button(SourceStyle.openTitle(item.source.kind)) { integrations.open(item) }
            }
        } else {
            Button("Quick Look") { preview(a, among: a.isImage ? attachments.filter(\.isImage) : []) }
            if !AttachmentInfo.isRunnable(a) {
                Button("Open") { open(a) }
            }
            Button("Save to Downloads") { save(a) }
        }
    }

    /// Quick Look, downloading first if needed. An image opens among the other images already downloaded,
    /// so the arrow keys go through them.
    private func preview(_ a: MessageAttachment, among images: [MessageAttachment]) {
        if filesBlocked || AttachmentFiles.isTooBig(a) {
            integrations.open(item)
            return
        }
        Task {
            guard let url = await files.fetch(a, messageID: item.id) else { return }
            let ready = images.compactMap { files.url($0) }
            if ready.count > 1, let index = ready.firstIndex(of: url) {
                quickLook.preview(ready, at: index)
            } else {
                quickLook.preview([url], at: 0)
            }
        }
    }

    private func open(_ a: MessageAttachment) {
        guard !AttachmentInfo.isRunnable(a) else { return }
        Task {
            guard let url = await files.fetch(a, messageID: item.id) else { return }
            NSWorkspace.shared.open(url)
        }
    }

    private func save(_ a: MessageAttachment) {
        Task {
            guard let url = await files.fetch(a, messageID: item.id) else { return }
            do {
                // Copying a big file takes a moment: not on the main thread.
                let saved = try await Task.detached(priority: .userInitiated) { try AttachmentFiles.saveToDownloads(url) }.value
                app.showToast("Saved “\(Integrations.shortTitle(saved.lastPathComponent, limit: 40))” to Downloads")
            } catch {
                app.showToast("Couldn't save it to Downloads")
            }
        }
    }
}

/// The files of one open message: what's downloaded, what failed, and thumbnails.
@MainActor
final class AttachmentFiles: ObservableObject {
    enum Status: Equatable {
        case loading
        case ready(URL)
        case failed(String)
    }

    @Published private(set) var status: [String: Status] = [:]
    @Published private(set) var thumbnails: [String: NSImage] = [:]

    /// Bigger than this and Integrations won't download it: it opens in Slack or Gmail instead.
    static let largestDownload = 100 * 1024 * 1024
    /// Thumbnails come from the whole image, so very big ones wait for a click.
    static let largestThumbnailSource = 25 * 1024 * 1024

    static func isTooBig(_ a: MessageAttachment) -> Bool { (a.size ?? 0) > largestDownload }

    func url(_ a: MessageAttachment) -> URL? {
        if case .ready(let url) = status[a.id] { return url }
        return nil
    }

    /// The local copy (downloaded once; asking again while it downloads waits for the same download).
    /// Nil when it failed, and the status says why.
    func fetch(_ a: MessageAttachment, messageID: String) async -> URL? {
        if let url = url(a) { return url }
        status[a.id] = .loading
        do {
            let url = try await Integrations.shared.file(for: a, messageID: messageID)
            status[a.id] = .ready(url)
            return url
        } catch {
            let service: IntegrationError.Service
            if case .gmail = a.remote { service = .gmail } else { service = .slack }
            let e = IntegrationError.wrap(error, service)
            status[a.id] = e == .cancelled ? nil : .failed(e.errorDescription ?? "Couldn't download it.")
            return nil
        }
    }

    func loadThumbnail(_ a: MessageAttachment, messageID: String) async {
        guard thumbnails[a.id] == nil, (a.size ?? 0) <= Self.largestThumbnailSource else { return }
        guard let url = await fetch(a, messageID: messageID) else { return }
        if let image = await Thumbnails.image(for: url) { thumbnails[a.id] = image }
    }

    /// Copies the file to Downloads (as "name 2.pdf" if the name is taken), marked as downloaded so macOS
    /// checks it before anything opens it.
    nonisolated static func saveToDownloads(_ file: URL) throws -> URL {
        let fm = FileManager.default
        guard let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first else { throw CocoaError(.fileNoSuchFile) }
        let name = AttachmentInfo.uniqueName(file.lastPathComponent) { fm.fileExists(atPath: downloads.appendingPathComponent($0).path) }
        var destination = downloads.appendingPathComponent(name, isDirectory: false)
        try fm.copyItem(at: file, to: destination)
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineAgentNameKey as String: "Docket",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String,
        ]
        try? destination.setResourceValues(values)
        return destination
    }
}

/// Small images for the grid, made off the main thread and kept for the session.
@MainActor
enum Thumbnails {
    private static let cache = NSCache<NSURL, NSImage>()

    static func image(for url: URL, maxPixels: Int = 480) async -> NSImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        let made: CGImage? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: makeThumbnail(url, maxPixels: maxPixels))
            }
        }
        guard let made else { return nil }
        let image = NSImage(cgImage: made, size: NSSize(width: made.width, height: made.height))
        cache.setObject(image, forKey: url as NSURL)
        return image
    }

    nonisolated static func makeThumbnail(_ url: URL, maxPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

private struct ImageTile: View {
    let attachment: MessageAttachment
    let status: AttachmentFiles.Status?
    let thumbnail: NSImage?
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
        Button(action: open) {
            Color.fill
                .aspectRatio(4 / 3, contentMode: .fit)
                .overlay {
                    if let thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                    } else {
                        placeholder
                    }
                }
                .clipShape(shape)
                .overlay(shape.strokeBorder(Color.hair, lineWidth: 1))
                .overlay(alignment: .bottomLeading) {
                    if hovering {
                        Text(attachment.name)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.onPrimary)
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .frame(height: 20)
                            .background(Capsule().fill(Color.primaryFill.opacity(0.85)))
                            .padding(6)
                            .transition(.opacity)
                    }
                }
                .contentShape(shape)
        }
        .buttonStyle(PressScale(scale: 0.98))
        .onHover { h in withAnimation(Motion.fast) { hovering = h } }
        .help([attachment.name, AttachmentInfo.size(attachment.size)].compactMap { $0 }.joined(separator: " · ") + " · Click for Quick Look")
        .accessibilityLabel("Image \(attachment.name)")
    }

    @ViewBuilder
    private var placeholder: some View {
        switch status {
        case .loading?:
            ProgressView().controlSize(.small)
        case .failed(let message)?:
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.ink3)
                .help(message)
        default:
            Image(systemName: "photo")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(Color.ink3)
        }
    }
}

private struct FileChip: View {
    let attachment: MessageAttachment
    let status: AttachmentFiles.Status?
    /// Not downloaded here (no permission, or too big): a click opens the message in Slack or Gmail.
    let opensOutside: Bool
    let service: String
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Image(systemName: AttachmentInfo.symbol(for: attachment))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.ink)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: Radius.xs, style: .continuous).fill(Color.fill))
                VStack(alignment: .leading, spacing: 1) {
                    Text(attachment.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(detail)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(isFailed ? Color.dangerText : Color.ink3)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                trailing
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(hovering ? Color.pressedTint : Color.card))
            .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).strokeBorder(Color.hair, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale(scale: 0.98))
        .onHover { h in withAnimation(Motion.fast) { hovering = h } }
        .help(help)
        .accessibilityLabel("Attachment \(attachment.name)")
    }

    private var isFailed: Bool {
        if case .failed? = status { return true }
        return false
    }

    private var detail: String {
        if opensOutside { return [AttachmentInfo.size(attachment.size), "Opens in \(service)"].compactMap { $0 }.joined(separator: " · ") }
        switch status {
        case .loading?: return "Downloading…"
        case .failed?: return "Couldn't download. Click to try again."
        default: return AttachmentInfo.size(attachment.size) ?? "Click for Quick Look"
        }
    }

    private var help: String {
        if case .failed(let message)? = status { return message }
        if opensOutside { return "Open the message in \(service) to get this file" }
        return "\(attachment.name). Click for Quick Look; right-click to open or save it."
    }

    @ViewBuilder
    private var trailing: some View {
        if case .loading? = status {
            ProgressView().controlSize(.small)
        } else if opensOutside {
            Image(systemName: "arrow.up.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.ink3)
        }
    }
}

// MARK: - Quick Look

/// Shows downloaded attachments in the Quick Look panel, through a small view in the detail that takes
/// charge of the panel (the panel looks for one in the responder chain). Opens the file instead if
/// Quick Look isn't there.
@MainActor
final class QuickLookController: ObservableObject {
    fileprivate weak var anchor: QuickLookAnchorView?

    func preview(_ urls: [URL], at index: Int) {
        guard !urls.isEmpty else { return }
        let i = min(max(index, 0), urls.count - 1)
        if let anchor, anchor.window != nil, QLPreviewPanel.shared() != nil {
            anchor.show(urls, at: i)
        } else {
            NSWorkspace.shared.open(urls[i])
        }
    }
}

struct QuickLookAnchor: NSViewRepresentable {
    let controller: QuickLookController

    func makeNSView(context: Context) -> QuickLookAnchorView {
        let view = QuickLookAnchorView()
        controller.anchor = view
        return view
    }

    func updateNSView(_ view: QuickLookAnchorView, context: Context) {
        controller.anchor = view
    }
}

final class QuickLookAnchorView: NSView, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private var urls: [URL] = []
    private var index = 0

    override var acceptsFirstResponder: Bool { true }
    /// Invisible: never a stop for Tab.
    override var canBecomeKeyView: Bool { false }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        // Going away (another message opened, another screen): close Quick Look while it shows this message's
        // files. The panel doesn't keep its data source alive, so it must never be left pointing at this view.
        guard newWindow == nil, QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(),
              panel.dataSource === self else { return }
        panel.orderOut(nil)
        if panel.dataSource === self {
            panel.dataSource = nil
            panel.delegate = nil
        }
    }

    func show(_ urls: [URL], at index: Int) {
        self.urls = urls
        self.index = index
        window?.makeFirstResponder(self)
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            // The panel may still belong to someone else (a note's photos, another message).
            panel.updateController()
            panel.reloadData()
            panel.currentPreviewItemIndex = index
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { !urls.isEmpty }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = index
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        guard panel.dataSource === self else { return }
        panel.dataSource = nil
        panel.delegate = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        urls.indices.contains(index) ? urls[index] as NSURL : nil
    }
}

// MARK: - The suggested task

/// The task the message could become (drawn like a task line), with Add task, Edit… and Dismiss.
private struct SuggestedTaskSection: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var app: AppState
    @ObservedObject private var integrations = Integrations.shared
    let item: Suggestion
    /// Add task is the screen's primary button until there's a reply to send.
    let leads: Bool
    /// Saves notes still being typed: they go into the task.
    let saveEdits: () -> Void

    /// The message as it is now, once `saveEdits` has run: this view's copy can be a keystroke behind
    /// the notes, and they go into the task.
    private var current: Suggestion { integrations.suggestion(item.id) ?? item }

    var body: some View {
        let draft = item.draft ?? SuggestionDrafts.fallback(for: item)
        VStack(alignment: .leading, spacing: Space.md) {
            Eyebrow(text: "Suggested task")
            proposal(draft)
            HStack(spacing: Space.sm) {
                Button {
                    saveEdits()
                    withAnimation(Motion.gentle) { _ = integrations.add(current) }
                } label: { Label("Add task", systemImage: "plus") }
                    .buttonStyle(LeadPill(primary: leads, height: 32))
                    .help("Add this as a task, with your notes and a link back to the message")
                Button("Edit…") {
                    saveEdits()
                    integrations.edit(current)
                }
                .buttonStyle(SecondaryPill(height: 32))
                .help("Change the task before adding it")
                Button("Dismiss") { withAnimation(Motion.gentle) { integrations.dismiss(item) } }
                    .buttonStyle(SecondaryPill(height: 32))
                    .help("Take this message off the list (⌘Z brings it back)")
                Spacer(minLength: 0)
            }
        }
    }

    /// Title on the left, date bold on the right, the duration pill (under the title when the pane is
    /// narrow, as in a task list); then priority, list and the reason.
    private func proposal(_ draft: TaskDraft) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: Space.sm) {
                Image(systemName: "circle")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(Color.ink3)
                TitleWhenLayout(spacing: Space.md) {
                    Text(draft.title)
                        .font(.system(size: 15, weight: .semibold))
                        .tracking(-0.2)
                        .foregroundStyle(Color.ink)
                        .lineLimit(2)
                    HStack(spacing: Space.sm) {
                        if let due = draft.due {
                            Text(Fmt.due(due, hasTime: draft.dueHasTime, now: app.clock))
                                .font(.system(size: 15, weight: .bold))
                                .tracking(-0.2)
                                .monospacedDigit()
                                .foregroundStyle(Color.ink)
                                .lineLimit(1)
                        }
                        if let minutes = draft.estimateMinutes, minutes > 0 {
                            DurationPill(minutes: minutes)
                        }
                    }
                    .fixedSize()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            let chips = details(draft)
            if !chips.isEmpty || !(draft.reason ?? "").isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    if !chips.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(chips, id: \.text) { chip in Chip(icon: chip.icon, text: chip.text, tone: chip.tone) }
                        }
                    }
                    if let reason = draft.reason, !reason.isEmpty {
                        Label(reason, systemImage: "sparkles")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.ink3)
                            .lineLimit(2)
                    }
                }
                .padding(.leading, 15 + Space.sm)
            }
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(Color.fill))
    }

    private struct Detail {
        var icon: String
        var text: String
        var tone: Tone = .neutral
    }

    /// Priority, list, who it's waiting on, steps: whatever the draft has beyond its date and duration.
    private func details(_ draft: TaskDraft) -> [Detail] {
        var chips: [Detail] = []
        if let tone = draft.priority.tone { chips.append(Detail(icon: "flag", text: draft.priority.label, tone: tone)) }
        let listName = (draft.listName ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "#").union(.whitespaces))
        if !listName.isEmpty,
           let list = store.lists.first(where: { $0.name.compare(listName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) {
            chips.append(Detail(icon: list.icon, text: list.name))
        }
        if let who = draft.waitingOn?.trimmingCharacters(in: .whitespaces), !who.isEmpty { chips.append(Detail(icon: "hourglass", text: "Waiting on \(who)")) }
        if !draft.subtasks.isEmpty { chips.append(Detail(icon: "checklist", text: Fmt.plural(draft.subtasks.count, "step"))) }
        return chips
    }
}
