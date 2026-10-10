import AppKit
import MemoryKit
import SwiftUI

/// The open memory, on the right of Memory: its title (editable), what AI made of it (summary, takeaways,
/// moments in the lens's words), its topics (with "Move to topic…"), who and what it's about (each opens its
/// page), where it came from, its files, the user's own note, and related memories. A voice note also gets a player, the tasks it made and its transcript.
struct MemoryItemDetail: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var app: AppState
    @ObservedObject private var center = MemoryCenter.shared
    @ObservedObject private var library = MemoryCenter.shared.library
    @ObservedObject private var processor = MemoryCenter.shared.processor
    @ObservedObject private var brain = MemoryCenter.shared.brain
    @ObservedObject private var integrations = Integrations.shared
    @ObservedObject private var ledger = MemoryCenter.shared.voice.ledger
    let itemID: UUID

    @State private var title = ""
    @State private var note = ""
    @State private var noteSave: Task<Void, Never>?
    @StateObject private var quickLook = QuickLookController()
    @FocusState private var titleFocused: Bool

    var body: some View {
        if let item = library.item(itemID) {
            content(item)
                .background(Color.paper)
                .background(QuickLookAnchor(controller: quickLook).frame(width: 0, height: 0))
                .onAppear {
                    title = item.title
                    note = item.body
                    if !DebugSnapshot.isActive { library.markViewed(itemID) }
                }
                .onDisappear(perform: commit)
                .onChange(of: titleFocused) { focused in if !focused { commitTitle() } }
                .onChange(of: note) { _ in scheduleNoteSave() }
        }
    }

    private func content(_ item: MemoryItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                topBar(item)
                TextField(item.displayTitle, text: $title, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 22, weight: .bold))
                    .tracking(-0.4)
                    .foregroundStyle(Color.ink)
                    .lineLimit(1...5)
                    .focused($titleFocused)
                    .onSubmit(commitTitle)
                    .padding(.top, -Space.sm)
                status(item)
                if let audio = recording(item) {
                    VoiceMemoryPlayer(url: library.fileURL(for: audio, of: itemID))
                }
                if !item.summary.isEmpty {
                    Text(item.summary)
                        .font(.system(size: 15))
                        .lineSpacing(3)
                        .foregroundStyle(Color.bodyText)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                takeaways(item)
                voiceTasks(item)
                pictures(item)
                moments(item)
                topics(item)
                names(item)
                source(item)
                transcript(item)
                files(item)
                noteField(item)
                related(item)
                footer(item)
            }
            .padding(Space.xl)
        }
    }

    // MARK: Top

    private func topBar(_ item: MemoryItem) -> some View {
        HStack(spacing: Space.sm) {
            if let back = app.memoryBackEntityID.flatMap(brain.entity) {
                Button { app.selectedEntityID = back.id } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 10, weight: .bold))
                        Text(back.name).lineLimit(1)
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.ink2)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                }
                .buttonStyle(MenuChromeStyle(shape: Capsule(), fill: .fill, hoverFill: .fillStrong))
                .help("Back to \(back.name)")
            } else {
                Label(MemoryText.origin(item), systemImage: item.kind.symbolName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.ink2)
                    .lineLimit(1)
            }
            Spacer(minLength: Space.sm)
            Button { withAnimation(Motion.snappy) { library.setPinned(itemID, !item.pinned) } } label: {
                Image(systemName: item.pinned ? "pin.fill" : "pin")
            }
            .buttonStyle(IconButtonStyle(size: 28, filled: item.pinned))
            .help(item.pinned ? "Unpin" : "Pin: it comes back now and then")
            Menu {
                Button("Summarise Again") { processor.reprocess(itemID) }
                    .disabled(!center.hasAI)
                Button("Copy Text") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString([item.displayTitle, item.summary, item.fullText].filter { !$0.isEmpty }.joined(separator: "\n\n"), forType: .string)
                    app.showToast("Copied")
                }
                Divider()
                Button("Delete…", role: .destructive) { MemoryDelete.confirm(item, app: app) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.ink)
                    .frame(width: 28, height: 28)
            }
            .menuChrome(Circle())
            .help("More")
            Button { withAnimation(Motion.sheet) { app.selectedMemoryID = nil } } label: { Image(systemName: "xmark") }
                .buttonStyle(IconButtonStyle(size: 28, filled: true))
                .keyboardShortcut(.cancelAction)
                .help("Close")
        }
    }

    /// Being summarised, waiting for a key, or failed (with Retry).
    @ViewBuilder
    private func status(_ item: MemoryItem) -> some View {
        if processor.runningIDs.contains(itemID) || (item.processing == .pending && center.hasAI) {
            HStack(spacing: Space.sm) {
                ProgressView().controlSize(.small)
                Text("Summarising…").textStyle(.footnote).foregroundStyle(Color.ink2)
            }
        } else if case .failed(let message) = item.processing {
            MemoryNote(icon: "exclamationmark.triangle.fill", warning: true, text: message) {
                Button("Retry") { processor.reprocess(itemID) }
                    .buttonStyle(SecondaryPill(height: 26))
            }
        } else if item.processing == .skipped && !center.hasAI {
            MemoryNote(icon: "key", text: "Not summarised yet. Add a Gemini key in Settings → AI and Docket will.") {
                Button("Open Settings") { MemorySettings.openAI(app) }
                    .buttonStyle(SecondaryPill(height: 26))
            }
        }
    }

    // MARK: What AI made of it

    @ViewBuilder
    private func takeaways(_ item: MemoryItem) -> some View {
        if !item.keyTakeaways.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(item.keyTakeaways.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                        Circle().fill(Color.ink3).frame(width: 4, height: 4).offset(y: -2)
                        Text(line)
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(Color.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    /// Decisions, promises, ideas and insights, each under the lens's name for it.
    @ViewBuilder
    private func moments(_ item: MemoryItem) -> some View {
        let vocabulary = library.vocabulary
        ForEach(MemoryScope.momentKinds, id: \.self) { kind in
            let list = item.moments.filter { $0.kind == kind }
            if !list.isEmpty {
                DetailSection(vocabulary.label(for: kind)) {
                    ForEach(list) { m in momentRow(m, kind: kind) }
                }
            }
        }
    }

    private func momentRow(_ m: Moment, kind: MomentKind) -> some View {
        HStack(alignment: .top, spacing: Space.md) {
            if kind == .promise {
                CheckCircle(done: m.done, priority: .none, size: 18) {
                    withAnimation(Motion.snappy) { library.setMomentDone(m.id, in: itemID, !m.done) }
                }
                .padding(.top, 1)
            } else {
                Image(systemName: MemoryText.symbol(for: kind))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color.ink2)
                    .frame(width: 18, height: 18)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(m.text)
                    .font(.system(size: 13.5, weight: .medium))
                    .strikethrough(m.done, color: .ink3)
                    .foregroundStyle(m.done ? Color.ink3 : Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let line = kind == .promise ? MemoryText.promiseLine(m, now: app.clock) : MemoryText.whoLine(m) {
                    Text(line)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isLate(m) ? Color.dangerText : Color.ink2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.hair).frame(height: 1).padding(.leading, 42)
        }
    }

    private func isLate(_ m: Moment) -> Bool {
        guard m.kind == .promise, !m.done, let due = m.due else { return false }
        return Calendar.current.startOfDay(for: due) < Calendar.current.startOfDay(for: app.clock)
    }

    /// People, organisations and projects; a click opens their page (or, before the brain knows them, shows
    /// every memory that mentions them).
    @ViewBuilder
    private func names(_ item: MemoryItem) -> some View {
        let names: [(String, EntityKind)] = item.people.map { ($0, .person) } + item.organisations.map { ($0, .organisation) }
            + item.projects.map { ($0, .project) }
        if !names.isEmpty {
            FlowLayout(spacing: Space.sm, lineSpacing: Space.sm) {
                ForEach(names, id: \.0) { name, kind in
                    let entity = brain.entity(named: name, kind: kind)
                    SuggestionChip(title: entity?.name ?? name, icon: kind.symbolName) { open(name, kind: kind) }
                        .help("Everything about \(entity?.name ?? name)")
                }
            }
        }
    }

    private func open(_ name: String, kind: EntityKind) {
        if let e = brain.entity(named: name, kind: kind) {
            app.selectedEntityID = e.id
            return
        }
        app.memoryAsk.clear()
        app.memoryMode = .library
        withAnimation(Motion.snappy) { app.memoryScope = kind == .person ? .person(name) : .project(name) }
    }

    /// The topics it's filed under (the main one first; each opens), and "Move to topic…".
    @ViewBuilder
    private func topics(_ item: MemoryItem) -> some View {
        let topics = brain.entities(for: itemID).filter { $0.kind == .topic }
        if !topics.isEmpty || brain.organizedAt != nil {
            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                FlowLayout(spacing: Space.sm, lineSpacing: Space.sm) {
                    if topics.isEmpty {
                        Text("Not sorted yet")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Color.ink3)
                            .frame(height: 28)
                    }
                    ForEach(Array(topics.enumerated()), id: \.element.id) { i, t in
                        SuggestionChip(title: brain.path(to: t.id).dropFirst().map(\.name).joined(separator: " › "),
                                       icon: i == 0 ? "number" : nil) { app.selectedEntityID = t.id }
                            .help(i == 0 ? "Its main topic" : "Also in \(t.name)")
                    }
                }
                moveMenu(current: topics)
            }
        }
    }

    private func moveMenu(current: [BrainEntity]) -> some View {
        Menu {
            ForEach(brain.areas()) { area in
                let list = brain.topics(in: area.id)
                if !list.isEmpty {
                    Section(area.name) {
                        ForEach(list) { t in
                            topicButton(t, current: current)
                            ForEach(brain.children(of: t.id)) { sub in topicButton(sub, current: current, indent: true) }
                        }
                    }
                }
            }
            let loose = brain.topics(in: nil)
            if !loose.isEmpty {
                Section("Other topics") { ForEach(loose) { t in topicButton(t, current: current) } }
            }
            if let main = current.first {
                Divider()
                Button("Take Out of \(main.name)") { brain.removeItem(itemID, fromTopic: main.id) }
            }
        } label: {
            Image(systemName: "arrow.right.circle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.ink2)
                .frame(width: 28, height: 28)
        }
        .menuChrome(Circle(), fill: .clear, hoverFill: .pressedTint)
        .help("Move to topic…")
    }

    private func topicButton(_ t: BrainEntity, current: [BrainEntity], indent: Bool = false) -> some View {
        Button {
            brain.setPrimaryTopic(t.id, for: itemID)
            app.showToast("Filed under \(t.name)")
        } label: {
            if current.first?.id == t.id {
                Label((indent ? "   " : "") + t.name, systemImage: "checkmark")
            } else {
                Text((indent ? "   " : "") + t.name)
            }
        }
    }

    // MARK: Where it came from, files

    @ViewBuilder
    private func source(_ item: MemoryItem) -> some View {
        if let link = MemorySourceLink.resolve(item, messageIDs: integrations.suggestions.map(\.id)) {
            Button { open(link) } label: {
                Label(link.title, systemImage: link.symbol)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .buttonStyle(SecondaryPill(height: 32, truncates: true))
            .help(item.url ?? link.title)
        }
    }

    private func open(_ link: MemorySourceLink) {
        switch link {
        case .task(let id):
            if store.task(id) != nil { app.reveal(task: id, in: store) } else { app.showToast("That task is gone") }
        case .note(let id):
            if store.note(id) != nil { app.reveal(note: id) } else { app.showToast("That note is gone") }
        case .message(let id): app.reveal(message: id)
        case .web(let url): NSWorkspace.shared.open(url)
        }
    }

    /// Photos inline, full width; a link's preview image too.
    @ViewBuilder
    private func pictures(_ item: MemoryItem) -> some View {
        let images = item.attachments.filter(\.isImage)
        if !images.isEmpty {
            VStack(spacing: Space.sm) {
                ForEach(images) { a in
                    let url = library.fileURL(for: a, of: itemID)
                    if let image = MediaCache.shared.image(for: url) {
                        Button { preview(a, in: item) } label: {
                            Image(nsImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: .infinity, maxHeight: 260)
                                .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).strokeBorder(Color.hair))
                        }
                        .buttonStyle(PressScale(scale: 0.99))
                        .help("Look at \(a.name) (Quick Look)")
                    }
                }
            }
        } else if item.kind == .link, let image = MemoryVisual.image(for: item, library: library) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: 180)
                .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).strokeBorder(Color.hair))
        }
    }

    // MARK: Voice notes

    /// A voice note's recording (the player shows it, so Files doesn't).
    private func recording(_ item: MemoryItem) -> MemoryAttachment? {
        guard item.kind == .audio else { return nil }
        return item.attachments.first { $0.mimeType.hasPrefix("audio/") }
    }

    /// The tasks the voice note made that are still around.
    @ViewBuilder
    private func voiceTasks(_ item: MemoryItem) -> some View {
        let tasks = item.kind == .audio ? ledger.taskIDs(for: itemID).compactMap(store.task) : []
        if !tasks.isEmpty {
            VoiceTasksSection(tasks: tasks)
        }
    }

    @ViewBuilder
    private func transcript(_ item: MemoryItem) -> some View {
        let text = item.extractedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if item.kind == .audio, !text.isEmpty {
            VoiceTranscriptSection(text: text)
        }
    }

    /// Everything that isn't a photo: PDFs, videos, recordings, documents. A click opens Quick Look.
    @ViewBuilder
    private func files(_ item: MemoryItem) -> some View {
        let shownAbove = recording(item)?.id
        let others = item.attachments.filter { !$0.isImage && $0.id != shownAbove }
        if !others.isEmpty {
            DetailSection("Files") {
                ForEach(others) { a in
                    Button { preview(a, in: item) } label: { fileRow(a, item: item) }
                        .buttonStyle(.plain)
                        .help("Look at \(a.name) (Quick Look)")
                        .contextMenu {
                            Button("Open") { NSWorkspace.shared.open(library.fileURL(for: a, of: itemID)) }
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([library.fileURL(for: a, of: itemID)]) }
                        }
                }
            }
        }
    }

    private func fileRow(_ a: MemoryAttachment, item: MemoryItem) -> some View {
        let url = library.fileURL(for: a, of: itemID)
        let thumb: NSImage? = a.mimeType == "application/pdf" ? MediaCache.shared.pdf(for: url)?.thumbnail
            : a.mimeType.hasPrefix("video/") ? MediaCache.shared.poster(for: url) : nil
        return HStack(spacing: Space.md) {
            ZStack {
                RoundedRectangle(cornerRadius: Radius.xs, style: .continuous).fill(Color.fill)
                if let thumb {
                    Image(nsImage: thumb).resizable().scaledToFill()
                } else {
                    Image(systemName: Self.fileSymbol(a.mimeType))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.ink2)
                }
            }
            .frame(width: 34, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: Radius.xs, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(a.name)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(MemoryText.size(a.byteCount))
                    .textStyle(.caption)
                    .foregroundStyle(Color.ink3)
            }
            Spacer(minLength: Space.sm)
            Image(systemName: "eye")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.ink3)
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    static func fileSymbol(_ mime: String) -> String {
        if mime == "application/pdf" { return "doc.richtext" }
        if mime.hasPrefix("video/") { return "film" }
        if mime.hasPrefix("audio/") { return "waveform" }
        if mime.hasPrefix("text/") { return "doc.text" }
        return "doc"
    }

    private func preview(_ a: MemoryAttachment, in item: MemoryItem) {
        let urls = item.attachments.map { library.fileURL(for: $0, of: itemID) }
        let index = item.attachments.firstIndex { $0.id == a.id } ?? 0
        quickLook.preview(urls, at: index)
    }

    // MARK: The user's note

    private func noteField(_ item: MemoryItem) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Eyebrow(text: item.kind == .note || item.kind == .text ? "Note" : "Your note")
                .padding(.leading, 4)
            TextField(item.kind == .note ? "Write it down" : "Add a note: why it matters, what to do with it", text: $note, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(Color.bodyText)
                .lineLimit(1...16)
                .padding(.horizontal, Space.md)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(Color.fill))
        }
    }

    // MARK: Related, footer

    @ViewBuilder
    private func related(_ item: MemoryItem) -> some View {
        let hits = library.related(toItem: itemID, limit: 3)
        if !hits.isEmpty {
            DetailSection("Related") {
                ForEach(hits) { hit in
                    Button { app.selectedMemoryID = hit.item.id } label: {
                        HStack(spacing: Space.md) {
                            MemoryKindTile(item: hit.item, size: 28)
                            Text(hit.item.displayTitle)
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundStyle(Color.ink)
                                .lineLimit(1)
                            Spacer(minLength: Space.sm)
                            Text(MemoryText.date(hit.item.createdAt, now: app.clock))
                                .font(.system(size: 12.5, weight: .bold))
                                .monospacedDigit()
                                .foregroundStyle(Color.ink2)
                                .fixedSize()
                        }
                        .padding(.horizontal, Space.md)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                        .hoverHighlight(cornerRadius: Radius.sm)
                    }
                    .buttonStyle(PressScale(scale: 0.985))
                }
            }
        }
    }

    private func footer(_ item: MemoryItem) -> some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Saved \(MemoryText.dateTime(item.createdAt, now: app.clock))")
                if let done = item.processedAt, item.processing == .processed {
                    Text("Summarised \(MemoryText.dateTime(done, now: app.clock))")
                }
            }
            .textStyle(.caption)
            .foregroundStyle(Color.ink3)
            Spacer()
            Button(role: .destructive) { MemoryDelete.confirm(item, app: app) } label: {
                Label("Delete", systemImage: "trash")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.dangerText)
            }
            .buttonStyle(PressScale())
        }
        .padding(.top, Space.sm)
    }

    // MARK: Saving edits

    private func commitTitle() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let item = library.item(itemID), trimmed != item.title, !trimmed.isEmpty || !item.title.isEmpty else { return }
        library.update(itemID) { $0.title = trimmed }
    }

    private func scheduleNoteSave() {
        noteSave?.cancel()
        noteSave = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            saveNote()
        }
    }

    private func saveNote() {
        guard let item = library.item(itemID), item.body != note else { return }
        library.update(itemID) { $0.body = note }
    }

    private func commit() {
        noteSave?.cancel()
        commitTitle()
        saveNote()
    }
}
