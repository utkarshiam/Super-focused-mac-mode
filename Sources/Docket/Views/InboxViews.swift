import AppKit
import CoreServices
import ImageIO
import Quartz
import SwiftUI
import UniformTypeIdentifiers

// The Slack and Email tabs of "Messages": the message list (All · Starred, ☆ and S) and the message
// detail (header, the whole thread or conversation from ConversationViews.swift with each message's files,
// notes, the suggested task and the reply). `SuggestionsView` in IntegrationViews.swift stays the entry point.

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
    /// Saving starred messages for later in Slack (in `SlackManifest.contentScopes`).
    static let starScopes: Set<String> = ["stars:read", "stars:write"]

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

    /// What the Docket app in Slack can't do yet, for want of permissions it was made without: show files,
    /// show threads, star messages in Slack. In that order.
    private static func missingFeatures(_ missing: Set<String>) -> [String] {
        var features: [String] = []
        if missing.contains(filesScope) { features.append("files") }
        if !missing.isDisjoint(with: historyScopes) { features.append("threads") }
        if !missing.isDisjoint(with: starScopes) { features.append("stars") }
        return features
    }

    /// The banner when the Docket app in Slack was made before Docket showed files and threads, or starred
    /// messages in Slack: "Docket needs two more Slack permissions to show files and threads."
    static func slackPermissionBanner(missing: Set<String>) -> String? {
        let features = missingFeatures(missing)
        guard !features.isEmpty else { return nil }
        let count = ["one more Slack permission", "two more Slack permissions", "three more Slack permissions"][features.count - 1]
        let shows = features.filter { $0 != "stars" }
        var purposes: [String] = []
        if !shows.isEmpty { purposes.append("show " + shows.joined(separator: " and ")) }
        if features.contains("stars") { purposes.append("star messages in Slack") }
        return "Docket needs \(count) to \(purposes.joined(separator: shows.count > 1 ? ", and to " : " and to "))."
    }

    /// What works differently until then (Connections).
    static func slackPermissionEffect(missing: Set<String>) -> String {
        let effects = missingFeatures(missing).map { feature in
            switch feature {
            case "files": "files open in Slack"
            case "threads": "threads stay hidden"
            default: "stars stay in Docket"
            }
        }
        guard !effects.isEmpty else { return "Everything works." }
        let list = effects.count > 2 ? effects.dropLast().joined(separator: ", ") + ", and " + (effects.last ?? "")
            : effects.joined(separator: " and ")
        return "Until then, \(list). Everything else works."
    }

    /// "Maya Chen, alex@acme.example": names where the address has one.
    static func people(_ entries: [String]) -> String {
        entries.map { MailSender(header: $0).displayName }.joined(separator: ", ")
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

/// The open message in each tab, the narrow window's list-or-detail, the Starred filter, and the keys.
@MainActor
final class InboxModel: ObservableObject {
    @Published var selected: [TaskSource.Kind: String] = [:]
    /// Narrow window: the open message shows in place of the list.
    @Published var showsDetail = false
    /// The tabs showing only starred messages (remembered across launches, per tab).
    @Published private(set) var starredOnly: Set<TaskSource.Kind>
    /// The tab on screen and whether the window is narrow, kept up to date by the panes.
    var kind: TaskSource.Kind = .slack
    var isNarrow = false
    private var monitor: Any?
    private let defaults: UserDefaults

    /// Posted before acting on several messages at once (Add all), so notes still being typed are saved first.
    static let saveEditsNow = Notification.Name("DocketInboxSaveEditsNow")

    /// "inboxStarredOnly.slack", "inboxStarredOnly.gmail".
    static func starredOnlyKey(_ kind: TaskSource.Kind) -> String { "inboxStarredOnly." + kind.rawValue }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        starredOnly = Set([TaskSource.Kind.slack, .gmail].filter { defaults.bool(forKey: Self.starredOnlyKey($0)) })
    }

    func select(_ id: String?, in kind: TaskSource.Kind) {
        guard selected[kind] != id else { return }
        selected[kind] = id
    }

    func isStarredOnly(_ kind: TaskSource.Kind) -> Bool { starredOnly.contains(kind) }

    /// All · Starred for one tab.
    func setStarredOnly(_ on: Bool, for kind: TaskSource.Kind) {
        guard on != starredOnly.contains(kind) else { return }
        if on { starredOnly.insert(kind) } else { starredOnly.remove(kind) }
        defaults.set(on, forKey: Self.starredOnlyKey(kind))
    }

    /// The tab's messages as the list shows them: starred first, newest first; with the filter on, only
    /// the starred ones. From `Integrations.shared` unless given others.
    func items(_ kind: TaskSource.Kind, in integrations: Integrations? = nil) -> [Suggestion] {
        (integrations ?? .shared).items(kind, starredOnly: isStarredOnly(kind))
    }

    /// ↑/↓ move through the list, Return opens the message, Esc goes back (narrow window) and S stars or
    /// unstars it. Only when the keyboard isn't in a text field, and only on this screen.
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
        let ids = items(kind).map(\.id)
        if event.charactersIgnoringModifiers?.lowercased() == "s" {
            // S: star or unstar the open message (once per press, however long it's held).
            guard let id = selected[kind], ids.contains(id) else { return false }
            if !event.isARepeat { InboxStarring.toggle(item: id) }
            return true
        }
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
        let items = model.items(kind, in: integrations)
        let ids = items.map(\.id)
        let tabIsEmpty = items.isEmpty && !integrations.suggestions.contains { $0.source.kind == kind }
        GeometryReader { geo in
            let narrow = InboxLayout.isNarrow(geo.size.width)
            Group {
                if tabIsEmpty {
                    emptyState
                } else if items.isEmpty {
                    // Starred only, and nothing starred.
                    VStack(spacing: 0) {
                        filterBar
                        noStarred
                    }
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
        VStack(spacing: 0) {
            filterBar
            InboxList(items: items, selectedID: model.selected[kind]) { id in
                model.select(id, in: kind)
                if model.isNarrow { withAnimation(Motion.snappy) { model.showsDetail = true } }
            }
        }
        .background(Color.paper)
    }

    /// All · Starred, over the list.
    private var filterBar: some View {
        let starred = integrations.suggestions.lazy.filter { $0.source.kind == kind && $0.isStarred }.count
        return InboxFilterBar(starredOnly: Binding(get: { model.isStarredOnly(kind) },
                                                   set: { on in withAnimation(Motion.snappy) { model.setStarredOnly(on, for: kind) } }),
                              starredCount: starred)
    }

    private var noStarred: some View {
        VStack(spacing: Space.md) {
            EmptyState(icon: "star", title: kind == .slack ? "No starred Slack messages" : "No starred emails",
                       message: "Star a message with ☆, or press S, and it shows up here.")
                .frame(maxHeight: 260)
            Button("Show all") { withAnimation(Motion.snappy) { model.setStarredOnly(false, for: kind) } }
                .buttonStyle(SecondaryPill(height: 32))
                .help("Show every message in this tab")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

/// A tab whose service isn't connected: what it's for, and the way in. For Gmail, what to do when Google
/// says "Access blocked" (the sign-in page never comes back to Docket then).
private struct InboxPitch: View {
    @ObservedObject private var integrations = Integrations.shared
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
                 : "Emails you star, and the ones waiting on your reply, show up here with their whole conversation and attachments, ready to answer or turn into tasks.")
                .textStyle(.callout)
                .foregroundStyle(Color.ink2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            if kind == .gmail, integrations.isSigningInToGmail {
                HStack(spacing: Space.sm) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for you in the browser…")
                        .textStyle(.callout)
                        .foregroundStyle(Color.ink)
                    Button("Cancel") { integrations.cancelGmailSignIn() }
                        .buttonStyle(SecondaryPill(height: 30))
                        .help("Stop waiting for the browser")
                }
                .padding(.top, Space.xs)
            } else {
                Button(kind == .slack ? "Connect Slack" : "Connect Gmail", action: connect)
                    .buttonStyle(PrimaryPill())
                    .help(kind == .slack ? "Set up Slack in Connections" : "Set up Gmail in Connections")
                    .padding(.top, Space.xs)
            }
            if kind == .gmail {
                GmailSignInHint(style: .centered)
                    .frame(maxWidth: 380)
                    .padding(.top, Space.sm)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Space.x4)
        .enterUp()
        .animation(Motion.base, value: integrations.isSigningInToGmail)
    }
}

/// All · Starred over the list: two chips, the one in use filled.
private struct InboxFilterBar: View {
    @Binding var starredOnly: Bool
    let starredCount: Int

    var body: some View {
        HStack(spacing: 6) {
            FilterChip(title: "All", icon: nil, isOn: !starredOnly, help: "Show every message") { starredOnly = false }
            FilterChip(title: starredCount > 0 ? "Starred (\(starredCount))" : "Starred", icon: "star", isOn: starredOnly,
                       help: "Show only starred messages (star one with ☆ or S)") { starredOnly = true }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.md)
        .padding(.top, Space.md)
        .padding(.bottom, Space.xxs)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct FilterChip: View {
    let title: String
    let icon: String?
    let isOn: Bool
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: isOn ? icon + ".fill" : icon)
                        .font(.system(size: 10, weight: .bold))
                }
                Text(title)
                    .lineLimit(1)
            }
            .font(.system(size: 12.5, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(isOn ? Color.ink : Color.ink2)
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background(Capsule().fill(isOn ? Color.fillStrong : (hovering ? Color.pressedTint : Color.clear)))
            .overlay(Capsule().strokeBorder(isOn ? Color.clear : Color.hair, lineWidth: 1))
            .contentShape(Capsule())
            .fixedSize()
        }
        .buttonStyle(PressScale(scale: 0.95))
        .onHover { h in withAnimation(Motion.fast) { hovering = h } }
        .help(help)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
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
                            InboxRow(item: item, isSelected: item.id == selectedID, starProblem: integrations.starProblem(for: item.id),
                                     toggleStar: { InboxStarring.toggle(item: item.id) })
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
            .onChange(of: items.map(\.id)) { _ in
                // Starring moves a message to the top: the open one stays in view.
                if let selectedID { withAnimation(Motion.snappy) { proxy.scrollTo(selectedID) } }
            }
            .onAppear {
                if let selectedID { proxy.scrollTo(selectedID) }
            }
        }
        .background(Color.paper)
    }

    @ViewBuilder
    private func menu(for item: Suggestion) -> some View {
        Button(item.isStarred ? "Unstar" : "Star") { InboxStarring.toggle(item: item.id) }
        Divider()
        Button("Add Task") {
            NotificationCenter.default.post(name: InboxModel.saveEditsNow, object: nil)
            // As it is now, with the notes just saved (this row's copy can be a keystroke behind).
            let current = integrations.suggestion(item.id) ?? item
            withAnimation(Motion.gentle) { _ = integrations.add(current) }
        }
        Button("Save as Note") {
            NotificationCenter.default.post(name: InboxModel.saveEditsNow, object: nil)
            InboxNotes.save(item: item.id, app: app)
        }
        if item.source.url?.scheme == "https" {
            Button(SourceStyle.openTitle(item.source.kind)) { integrations.open(item) }
        }
        Divider()
        Button("Dismiss") { withAnimation(Motion.gentle) { integrations.dismiss(item) } }
    }
}

/// One message in the list: who, where (or the subject), two lines of it, when, its star, and one small chip.
private struct InboxRow: View {
    let item: Suggestion
    let isSelected: Bool
    /// Why its star didn't take, if it didn't.
    let starProblem: String?
    let toggleStar: () -> Void
    @State private var hovering = false

    /// Slack previews show their formatting and emoji the way the message does, not raw *markup*.
    private var snippetText: Text {
        guard item.source.kind == .slack else { return Text(item.snippet) }
        return Text(SlackText.attributed(item.snippet, names: Integrations.shared.slackNames))
    }

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
                star
            }
            Text(InboxItemText.context(of: item))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.ink)
                .lineLimit(1)
            if !item.snippet.isEmpty {
                snippetText
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
        .accessibilityValue(item.isStarred ? "Starred" : "")
        .accessibilityAction(named: item.isStarred ? "Unstar" : "Star", toggleStar)
    }

    /// ★ when starred; ☆ while the pointer is over the row or it's open. A warning next to it when the last
    /// change didn't take (the tooltip says why; clicking the star tries again).
    private var star: some View {
        let shown = item.isStarred || hovering || isSelected || starProblem != nil
        return HStack(spacing: 2) {
            if let starProblem {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color.warning)
                    .help(starProblem)
                    .accessibilityLabel(starProblem)
            }
            StarButton(isOn: item.isStarred, size: 20, iconSize: 11, help: item.isStarred ? "Unstar (S)" : "Star (S)", action: toggleStar)
                .frame(height: 16)
                .opacity(shown ? 1 : 0)
                .allowsHitTesting(shown)
        }
    }

    /// At most one: Replied once you've answered it, else how many files it has.
    @ViewBuilder
    private var chips: some View {
        let files = InboxItemText.attachmentCount(item)
        if let replied = item.repliedAt {
            Badge(text: "Replied", tone: .success, icon: "arrowshape.turn.up.left")
                .help("You replied on \(Fmt.dateTime(replied))" + (files > 0 ? " · \(Fmt.plural(files, "attachment"))" : ""))
                .padding(.top, 3)
        } else if files > 0 {
            Badge(text: "\(files)", icon: "paperclip")
                .help(Fmt.plural(files, "attachment"))
                .padding(.top, 3)
        }
    }
}

// MARK: - The message

/// The open message: who and when, one row of actions (Add task with the suggested task under it, Reply, Note,
/// Dismiss), then its whole thread or conversation (the message highlighted in it, every message with its
/// files). Notes and the reply composer show once asked for, or when there's already a note or a draft. Both
/// are saved as you type (once typing pauses).
struct InboxDetail: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var app: AppState
    @ObservedObject private var integrations = Integrations.shared
    @AppStorage(Prefs.Key.slackSaveEmoji) private var saveEmoji = SlackSaveEmoji.standard

    static let plainTextKey = "inboxMailPlainText"
    /// The reply composer's scroll id: a message's Reply brings it into view.
    private static let composerID = "inbox-reply-composer"
    /// The notes' scroll id: Note brings them into view.
    private static let notesID = "inbox-notes"

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
    @StateObject private var conversation: ConversationModel
    @FocusState private var noteFocused: Bool
    /// The notes editor is out: Note was clicked, or the message already has notes.
    @State private var showsNotes: Bool
    /// The reply composer is out: Reply (here or on a message of the thread) was clicked, or there's a draft.
    @State private var showsComposer: Bool
    /// The composer came out because it was asked for, so it takes the keyboard.
    @State private var composerAsked = false

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
        _showsNotes = State(initialValue: !item.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        _showsComposer = State(initialValue: !item.replyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        // One per open message (the panes give each message its own detail).
        _conversation = StateObject(wrappedValue: ConversationModel(itemID: item.id))
    }

    private var content: MessageContent? { item.content ?? loaded }

    /// Messages in the thread as it shows (1 until it's in).
    private var messageCount: Int { ThreadImportance.messageCount(item, thread: conversation.thread) }

    /// Changes when the thread comes in or changes, or the item is starred: time to look at its summary again.
    private var summaryTrigger: String {
        "\(conversation.phase) \(ThreadImportance.fingerprint(item, thread: conversation.thread)) \(item.isStarred)"
    }
    private var isEmail: Bool { item.source.kind == .gmail }
    /// Gmail needs a sign-in that allows sending; Slack only needs to be connected.
    private var canSend: Bool { isEmail ? integrations.gmailCanCompose : integrations.isSlackConnected }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    header
                    InboxActionBar(item: item, leads: !ReplyText.sendLeads(reply, canSend: canSend), saveEdits: flush,
                                   reply: { conversation.requestComposer() },
                                   note: { openNotes(proxy) },
                                   messageCount: messageCount,
                                   saveAsNote: { message in
                                       flush()
                                       InboxNotes.save(item: item.id, message: message, app: app)
                                   })
                    ThreadSummaryCard(itemID: item.id)
                    ConversationSection(conversation: conversation, item: item, content: content, contentLoading: loading,
                                        contentProblem: loadProblem, retryContent: { Task { await load() } },
                                        quickLook: quickLook, paneHeight: paneHeight, updateSlack: updateSlack,
                                        reveal: { id in withAnimation(Motion.gentle) { proxy.scrollTo(id, anchor: .top) } })
                    if showsNotes || showsComposer {
                        Rectangle().fill(Color.hair).frame(height: 1)
                    }
                    if showsNotes {
                        notes
                            .id(Self.notesID)
                            .transition(.opacity)
                    }
                    if showsComposer {
                        ReplyComposer(item: item, text: $reply, content: content, canSend: canSend, conversation: conversation,
                                      takesFocus: composerAsked, flush: flush, reconnectGmail: { integrations.connectGmail() })
                            .id(Self.composerID)
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: InboxLayout.readingWidth, alignment: .leading)
                .padding(.horizontal, Space.xl)
                .padding(.top, Space.lg)
                .padding(.bottom, Space.x6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: conversation.composerRequests) { _ in
                // Reply (here or on a message of the thread): the composer comes out and into view.
                if !showsComposer {
                    composerAsked = true
                    withAnimation(Motion.gentle) { showsComposer = true }
                }
                DispatchQueue.main.async {
                    withAnimation(Motion.gentle) { proxy.scrollTo(Self.composerID, anchor: .bottom) }
                }
            }
        }
        .background(Color.paper)
        .background(QuickLookAnchor(controller: quickLook).frame(width: 0, height: 0))
        .task(id: item.id) { await load() }
        // An important thread is summarized once it's in, and again when it changes.
        .task(id: summaryTrigger) {
            guard conversation.phase != .waiting && conversation.phase != .loading else { return }
            await integrations.summarizeIfImportant(item.id)
        }
        .onAppear {
            conversation.saveAsNote = { message in
                flush()
                InboxNotes.save(item: item.id, message: message, app: app)
            }
        }
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
                    if let at = item.repliedAt {
                        Badge(text: "Replied \(Fmt.dateTime(at))", tone: .success, icon: "checkmark")
                            .help("You replied from Docket")
                            .padding(.top, 2)
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: Space.sm) {
                    StarButton(isOn: item.isStarred, size: 30, iconSize: 13, filled: true,
                               help: item.isStarred ? "Unstar (S)" : "Star (S)") { InboxStarring.toggle(item: item.id) }
                    if item.source.url?.scheme == "https" {
                        Button { integrations.open(item) } label: {
                            Label(SourceStyle.openTitle(item.source.kind), systemImage: "arrow.up.right")
                        }
                        .buttonStyle(SecondaryPill(height: 30))
                        .help(isEmail ? "See the conversation in Gmail" : "See the message in Slack")
                    }
                }
            }
            if let problem = integrations.starProblem(for: item.id) {
                starProblem(problem)
            }
        }
        .animation(Motion.base, value: integrations.starProblem(for: item.id))
    }

    /// The star didn't take in Gmail or Slack (it went back): why, and the way to try again.
    private func starProblem(_ text: String) -> some View {
        HStack(alignment: .center, spacing: Space.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.warning)
            Text(text)
                .textStyle(.footnote)
                .foregroundStyle(Color.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Space.sm)
            Button("Try again") { InboxStarring.toggle(item: item.id) }
                .buttonStyle(SecondaryPill(height: 26))
                .help(item.isStarred ? "Unstar it again" : "Star it again")
        }
        .transition(.opacity)
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

    // MARK: Notes

    private var notes: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Eyebrow(text: "Note")
            GrowingTextEditor(text: $note, placeholder: "What to do, what to say back…",
                              minHeight: 44, maxHeight: 200, focus: $noteFocused)
                .help("Saved as you type. Your note goes into the task if you add one, and AI follows it when it drafts a reply.")
        }
    }

    /// Note: the editor comes out, into view, with the keyboard.
    private func openNotes(_ proxy: ScrollViewProxy) {
        if !showsNotes { withAnimation(Motion.gentle) { showsNotes = true } }
        DispatchQueue.main.async {
            noteFocused = true
            withAnimation(Motion.gentle) { proxy.scrollTo(Self.notesID, anchor: .center) }
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
struct SlackMessageText: View, Equatable {
    let markup: String
    let names: [String: String]
    var size: CGFloat = 15

    var body: some View {
        Text(SlackText.attributed(markup, names: names))
            .font(.system(size: size))
            .foregroundStyle(Color.bodyText)
            .lineSpacing(3)
            .tint(Color.ink)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .safeLinks()
    }
}

// MARK: - Attachments

/// Images as a grid of thumbnails, other files as chips. A click downloads the file once (it's kept in
/// IntegrationCache/, under the inbox item's id) and shows it in Quick Look; files are never run. Used for
/// each message of a thread.
struct AttachmentsSection: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var integrations = Integrations.shared
    /// The inbox item the message belongs to: its files are kept under its id, and it's what opens in
    /// Slack or Gmail when a file can't be downloaded here.
    let item: Suggestion
    let attachments: [MessageAttachment]
    let quickLook: QuickLookController
    /// Slack without files:read: the names only; they open in Slack (the conversation says why, once).
    let filesBlocked: Bool
    /// "Attachments 2" over them (an email); a Slack message shows its files right under its text.
    var showsTitle = true
    @StateObject private var files = AttachmentFiles()

    var body: some View {
        let images = filesBlocked ? [] : attachments.filter { $0.isImage && !AttachmentFiles.isTooBig($0) }
        let imageIDs = Set(images.map(\.id))
        let others = attachments.filter { !imageIDs.contains($0.id) }
        VStack(alignment: .leading, spacing: Space.sm) {
            if showsTitle {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Eyebrow(text: "Attachments")
                    Text("\(attachments.count)")
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Color.ink3)
                }
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

// MARK: - The actions

/// The one row of actions under the message's header: Add task (the primary until there's a reply to send),
/// Reply, Note and Dismiss; under it, the suggested task on one line (title, date, duration) with Edit….
private struct InboxActionBar: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var app: AppState
    @ObservedObject private var integrations = Integrations.shared
    let item: Suggestion
    /// Add task is the screen's primary button until there's a reply to send.
    let leads: Bool
    /// Saves notes still being typed: they go into the task.
    let saveEdits: () -> Void
    /// Brings out the reply composer.
    let reply: () -> Void
    /// Brings out the notes.
    let note: () -> Void
    /// Messages in the thread: "Save Thread as Note" and "Save This Message as Note" when there's more than one.
    let messageCount: Int
    /// Saves the whole thread (nil) or one message of it as a note.
    let saveAsNote: (String?) -> Void

    /// The message as it is now, once `saveEdits` has run: this view's copy can be a keystroke behind
    /// the notes, and they go into the task.
    private var current: Suggestion { integrations.suggestion(item.id) ?? item }

    var body: some View {
        let draft = item.draft ?? SuggestionDrafts.fallback(for: item)
        VStack(alignment: .leading, spacing: 10) {
            // The longest labels that fit, so nothing wraps in a narrow pane.
            ViewThatFits(in: .horizontal) {
                buttons(iconsOnly: false, dismissLabel: true)
                buttons(iconsOnly: false, dismissLabel: false)
                buttons(iconsOnly: true, dismissLabel: false)
            }
            taskLine(draft)
        }
        .padding(Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).strokeBorder(Color.hair, lineWidth: 1))
    }

    private func buttons(iconsOnly: Bool, dismissLabel: Bool) -> some View {
        HStack(spacing: Space.sm) {
            Button {
                saveEdits()
                withAnimation(Motion.gentle) { _ = integrations.add(current) }
            } label: { Label("Add task", systemImage: "plus") }
                .buttonStyle(LeadPill(primary: leads, height: 32))
                .help("Add the suggested task, with your note and a link back to the message")
            secondary("Reply", icon: "arrowshape.turn.up.left", iconOnly: iconsOnly, action: reply)
                .help(item.source.kind == .gmail ? "Write a reply to this email" : "Write a reply in the message's thread")
            secondary("Note", icon: "square.and.pencil", iconOnly: iconsOnly, action: note)
                .help("Add a note: it goes into the task, and AI follows it when it drafts a reply")
            Spacer(minLength: 0)
            more
            secondary("Dismiss", icon: "xmark", iconOnly: !dismissLabel) {
                withAnimation(Motion.gentle) { integrations.dismiss(item) }
            }
            .help("Take this message off the list (⌘Z brings it back)")
        }
    }

    /// ⋯: save as a note (the whole thread, or just this message), summarize.
    private var more: some View {
        Menu {
            Button(messageCount > 1 ? "Save Thread as Note" : "Save as Note") { saveAsNote(nil) }
            if messageCount > 1 {
                Button("Save This Message as Note") { saveAsNote(InboxThread.bareMessageID(item.id)) }
            }
            if integrations.showsSummaries {
                Divider()
                Button(integrations.summary(for: item.id) == nil ? "Summarize" : "Summarize Again") {
                    Task { await integrations.summarize(item.id, force: true) }
                }
                .disabled(integrations.summarizing.contains(item.id))
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.ink)
                .frame(width: 32, height: 32)
        }
        .menuChrome(Circle())
        .help("Save as a note with its attachments, or summarize the thread")
        .accessibilityLabel("More")
    }

    @ViewBuilder
    private func secondary(_ title: String, icon: String, iconOnly: Bool, action: @escaping () -> Void) -> some View {
        if iconOnly {
            Button(action: action) { Image(systemName: icon).font(.system(size: 12.5, weight: .semibold)) }
                .buttonStyle(IconButtonStyle(size: 32, filled: true))
                .accessibilityLabel(title)
        } else {
            Button(action: action) { Label(title, systemImage: icon) }
                .buttonStyle(SecondaryPill(height: 32))
        }
    }

    /// "○ Send the Q3 deck to Lena   Mon 5 Oct · 10:00 AM  30m  Edit…": the title gives way first.
    private func taskLine(_ draft: TaskDraft) -> some View {
        HStack(alignment: .center, spacing: Space.sm) {
            Image(systemName: "circle")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Color.ink3)
            Text(draft.title)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(Color.ink)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(-1)
            Spacer(minLength: Space.xs)
            if let due = draft.due {
                Text(Fmt.due(due, hasTime: draft.dueHasTime, now: app.clock))
                    .font(.system(size: 13, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                    .fixedSize()
            }
            if let minutes = draft.estimateMinutes, minutes > 0 {
                DurationPill(minutes: minutes)
                    .fixedSize()
            }
            Button("Edit…") {
                saveEdits()
                integrations.edit(current)
            }
            .buttonStyle(.plain)
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(Color.ink2)
            .fixedSize()
            .help("Change the task (title, date, duration, list) before adding it")
        }
        .help(summary(draft))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Suggested task")
    }

    /// The tooltip: the task's title and whatever else it has (priority, list, who it waits on, steps, why).
    private func summary(_ draft: TaskDraft) -> String {
        var parts = ["Suggested task: \(draft.title)"]
        if draft.priority.tone != nil { parts.append("\(draft.priority.label) priority") }
        let listName = (draft.listName ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "#").union(.whitespaces))
        if !listName.isEmpty,
           let list = store.lists.first(where: { $0.name.compare(listName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) {
            parts.append("List: \(list.name)")
        }
        if let who = draft.waitingOn?.trimmingCharacters(in: .whitespaces), !who.isEmpty { parts.append("Waiting on \(who)") }
        if !draft.subtasks.isEmpty { parts.append(Fmt.plural(draft.subtasks.count, "step")) }
        if let reason = draft.reason, !reason.isEmpty { parts.append(reason) }
        return parts.joined(separator: "\n")
    }
}
