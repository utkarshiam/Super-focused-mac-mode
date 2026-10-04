import AppKit
import SwiftUI

struct NotesView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var app: AppState

    var body: some View {
        HStack(spacing: 0) {
            NotesListPane()
                .frame(width: 300)
            Rectangle().fill(Color.hair).frame(width: 1).ignoresSafeArea()
            if let id = app.selectedNoteID, store.note(id) != nil {
                NoteEditorPane(noteID: id)
                    .id(id)
                    .transition(.opacity)
            } else {
                EmptyState(icon: "doc.text", title: "No note open", message: "Start one with ⇧⌘N, or open today's daily note with ⌘D.")
            }
        }
        .background(Color.paper)
        .animation(Motion.fast, value: app.selectedNoteID)
        .onAppear {
            if app.selectedNoteID == nil || store.note(app.selectedNoteID) == nil {
                app.selectedNoteID = store.searchNotes("").first?.id
            }
        }
    }
}

struct NotesListPane: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var app: AppState
    @State private var noteToDelete: Note?

    var body: some View {
        let notes = store.searchNotes(app.noteSearch, limit: 1000)
        let pinned = notes.filter(\.isPinned)
        let others = notes.filter { !$0.isPinned }

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.sm) {
                Text("Notes")
                    .textStyle(.title1)
                    .foregroundStyle(Color.ink)
                Spacer()
                Button { app.reveal(note: store.dailyNote().id) } label: { Image(systemName: "sun.max") }
                    .buttonStyle(IconButtonStyle(filled: true))
                    .help("Today's daily note (⌘D)")
                Menu {
                    Button { app.newNoteFromClipboard(store) } label: { Label("From Clipboard", systemImage: "doc.on.clipboard") }
                    Divider()
                    ForEach(NoteTemplate.allCases) { template in
                        Button { create(template) } label: { Label(template.label, systemImage: template.icon) }
                    }
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.onPrimary)
                        .frame(width: 32, height: 32)
                } primaryAction: {
                    create(.blank)
                }
                .menuChrome(Circle(), fill: .primaryFill, hoverFill: Color.primaryFill.opacity(0.85))
                .help("New note (⇧⌘N). Hold for templates")
            }
            .padding(.horizontal, Space.xl)
            .padding(.top, Space.lg)
            .padding(.bottom, Space.md)

            HStack(spacing: Space.sm) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.ink2)
                TextField("Search notes", text: $app.noteSearch)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .medium))
                if !app.noteSearch.isEmpty {
                    Button { app.noteSearch = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.ink3)
                }
            }
            .padding(.horizontal, Space.md)
            .frame(height: 38)
            .background(Capsule().fill(Color.fill))
            .padding(.horizontal, Space.lg)
            .padding(.bottom, Space.sm)

            ScrollViewReader { proxy in
            ScrollView {
                EnterUpWindow {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if !pinned.isEmpty {
                        Eyebrow(text: "Pinned").padding(.horizontal, Space.md).padding(.top, Space.md).padding(.bottom, Space.xs)
                        ForEach(Array(pinned.enumerated()), id: \.element.id) { i, note in row(note, index: i) }
                    }
                    if !others.isEmpty {
                        if !pinned.isEmpty {
                            Eyebrow(text: "Notes").padding(.horizontal, Space.md).padding(.top, Space.lg).padding(.bottom, Space.xs)
                        }
                        ForEach(Array(others.enumerated()), id: \.element.id) { i, note in row(note, index: i + pinned.count) }
                    }
                    if notes.isEmpty {
                        Text(app.noteSearch.isEmpty ? "No notes yet." : "Nothing matches “\(app.noteSearch)”.")
                            .textStyle(.callout)
                            .foregroundStyle(Color.ink2)
                            .padding(Space.lg)
                    }
                }
                }
                .padding(.horizontal, Space.sm)
                .padding(.bottom, Space.xl)
            }
            .onChange(of: app.selectedNoteID) { id in
                if let id { withAnimation(Motion.snappy) { proxy.scrollTo(id) } }
            }
            }
        }
        .background(Color.paper)
        .alert("Delete “\(noteToDelete?.title ?? "")”?", isPresented: Binding(get: { noteToDelete != nil }, set: { if !$0 { noteToDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let note = noteToDelete { delete(note) }
                noteToDelete = nil
            }
            Button("Cancel", role: .cancel) { noteToDelete = nil }
        } message: {
            Text("You can undo this with ⌘Z.")
        }
    }

    private func row(_ note: Note, index: Int) -> some View {
        NoteRow(note: note, isSelected: app.selectedNoteID == note.id, index: index)
            .onTapGesture { withAnimation(Motion.snappy) { app.selectedNoteID = note.id } }
            .contextMenu {
                Button(note.isPinned ? "Unpin" : "Pin to Top") { withAnimation(Motion.base) { store.setPinned(note.id, !note.isPinned) } }
                Button("Copy as Markdown") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(note.body, forType: .string)
                }
                Divider()
                Button("Delete", role: .destructive) { noteToDelete = note }
            }
    }

    private func create(_ template: NoteTemplate) {
        let note = withAnimation(Motion.gentle) { store.addNote(body: template.body()) }
        app.noteSearch = ""
        app.selectedNoteID = note.id
    }

    private func delete(_ note: Note) {
        let ordered = store.searchNotes(app.noteSearch, limit: 1000)
        let index = ordered.firstIndex { $0.id == note.id } ?? 0
        withAnimation(Motion.base) { store.deleteNote(note.id) }
        let remaining = store.searchNotes(app.noteSearch, limit: 1000)
        app.selectedNoteID = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)].id
    }
}

private struct NoteRow: View {
    let note: Note
    let isSelected: Bool
    let index: Int
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                if note.dailyKey != nil {
                    Image(systemName: "sun.max.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.ink2)
                }
                Text(note.title)
                    .font(.system(size: 14, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
            }
            if !note.preview.isEmpty {
                Text(note.preview)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.ink2)
                    .lineLimit(2)
            }
            HStack(spacing: 6) {
                Text("\(Fmt.absoluteDay(note.updatedAt)), \(Fmt.time(note.updatedAt))")
                let open = note.openChecklistCount
                if open > 0 {
                    Label("\(open) open", systemImage: "checklist").labelStyle(.titleAndIcon)
                }
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.ink3)
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .fill(isSelected ? Color.fill : (hovering ? Color.pressedTint : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .strokeBorder(isSelected ? Color.hairStrong : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { h in withAnimation(Motion.fast) { hovering = h } }
        .enterUp(index)
    }
}

struct NoteEditorPane: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var app: AppState
    let noteID: UUID
    @State private var showLinked = false
    /// After ⌘E or the Read/Edit switch the new view takes the keyboard (opening a note doesn't).
    @State private var focusAfterSwitch = false
    @StateObject private var bridge = NoteBridge()

    var body: some View {
        let note = store.note(noteID) ?? Note(body: "")
        let isEmpty = note.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let mode = app.noteModes[noteID] ?? (isEmpty ? .edit : .read)
        let open = note.openChecklistCount
        let linked = store.linkedTasks(forNote: noteID)
        let unlinkedOpen = max(0, open - linked.filter { !$0.isCompleted }.count)

        VStack(spacing: 0) {
            HStack(spacing: Space.sm) {
                Button { withAnimation(Motion.snappy) { store.setPinned(noteID, !note.isPinned) } } label: {
                    Image(systemName: note.isPinned ? "pin.fill" : "pin")
                }
                .buttonStyle(IconButtonStyle(filled: note.isPinned))
                .help(note.isPinned ? "Unpin" : "Pin to top")

                SegmentedControl(selection: Binding(get: { mode }, set: { setMode($0) }),
                                 options: [(AppState.NoteMode.read, "Read"), (AppState.NoteMode.edit, "Edit")])
                    .help("Read shows the note formatted; Edit shows the Markdown (⌘E)")

                Button { addMedia(mode: mode) } label: { Image(systemName: "photo.badge.plus") }
                    .buttonStyle(IconButtonStyle(filled: true))
                    .help("Add photos or videos (or drop them on the note)")

                Spacer(minLength: Space.sm)

                ViewThatFits(in: .horizontal) {
                    trailingActions(linked: linked, unlinkedOpen: unlinkedOpen, style: .full)
                    trailingActions(linked: linked, unlinkedOpen: unlinkedOpen, style: .compact)
                    trailingActions(linked: linked, unlinkedOpen: unlinkedOpen, style: .icons)
                }

                Menu {
                    Menu("Insert Template") {
                        ForEach(NoteTemplate.allCases.filter { $0 != .blank }) { t in
                            Button(t.label) { append(t.body()) }
                        }
                    }
                    Button("Add Photos or Videos…") { addMedia(mode: mode) }
                    Divider()
                    Button("Copy as Formatted Text") {
                        MarkdownExport.copyFormatted(note.body)
                        app.showToast("Copied with formatting")
                    }
                    Button("Copy as Markdown") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(note.body, forType: .string)
                    }
                    Divider()
                    Button("Export as PDF…") { MarkdownExport.exportPDF(note.body, title: note.title) }
                    Button("Export as Markdown…") { export(note) }
                    Divider()
                    Button("Delete Note", role: .destructive) {
                        store.deleteNote(noteID)
                        app.selectedNoteID = store.searchNotes(app.noteSearch).first?.id
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.ink)
                        .frame(width: 32, height: 32)
                }
                .menuChrome(Circle())
            }
            .padding(.horizontal, Space.xl)
            .frame(height: 60)
            .animation(Motion.base, value: unlinkedOpen)
            .background {
                // ⌘E flips Read/Edit (kept out of the toolbar row so it takes no space).
                Button("") { setMode(mode == .read ? .edit : .read) }
                    .keyboardShortcut("e", modifiers: .command)
                    .opacity(0)
                    .accessibilityHidden(true)
            }

            Rectangle().fill(Color.hair).frame(height: 1)

            Group {
                if mode == .read {
                    if isEmpty {
                        emptyReadState
                    } else {
                        MarkdownReader(text: note.body, onToggleTask: toggleTask, onAppend: append, focusOnAppear: focusAfterSwitch)
                    }
                } else {
                    MarkdownEditor(
                        text: Binding(get: { store.note(noteID)?.body ?? "" }, set: { store.updateNoteBody(noteID, $0) }),
                        onCreateTask: { text in
                            let t = store.createTask(fromText: text, note: noteID, parser: QuickParser(lists: store.lists, workdayEndMinutes: Prefs.workdayEnd))
                            Haptics.success()
                            app.showToast("Task created: \(t.title)")
                        },
                        focusOnAppear: isEmpty || focusAfterSwitch,
                        bridge: bridge,
                        onPastedDocument: {
                            setMode(.read)
                            app.showToast("Showing it formatted. ⌘E to edit.")
                        },
                        onAppend: append
                    )
                }
            }
            .transition(.opacity)
            .id(mode)

            HStack(spacing: Space.sm) {
                let words = note.body.split { $0.isWhitespace || $0.isNewline }.count
                Text("Edited \(Fmt.absoluteDay(note.updatedAt)), \(Fmt.time(note.updatedAt)) · \(Fmt.plural(words, "word"))")
                    .lineLimit(1)
                Spacer()
                Text(verbatim: mode == .read
                     ? "⌘E to edit · click a checkbox to tick it · drop photos or videos here"
                     : "⌘E to read · **bold**  *italic*  # heading  - [ ] checkbox")
                    .lineLimit(1)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.ink3)
            .padding(.horizontal, Space.xl)
            .frame(height: 30)
        }
        .background(Color.paper)
        .animation(Motion.base, value: mode)
        .onAppear {
            // Settle the mode once, so typing the first characters of a new note doesn't flip it to Read.
            if app.noteModes[noteID] == nil { app.noteModes[noteID] = isEmpty ? .edit : .read }
        }
    }

    private enum ActionStyle { case full, compact, icons }

    @ViewBuilder
    private func trailingActions(linked: [TaskItem], unlinkedOpen: Int, style: ActionStyle) -> some View {
        let compact = style != .full
        HStack(spacing: Space.sm) {
            if !linked.isEmpty {
                let done = linked.filter(\.isCompleted).count
                Button { showLinked.toggle() } label: {
                    if style == .icons {
                        Image(systemName: "link")
                    } else {
                        Label(compact ? "\(done)/\(linked.count)" : "\(done) of \(linked.count) done", systemImage: "link")
                    }
                }
                .buttonStyle(SecondaryPill(height: 32))
                .help("\(done) of \(linked.count) tasks from this note are done")
                .popover(isPresented: $showLinked) { LinkedTasksPopover(noteID: noteID) }
            }
            if unlinkedOpen > 0 {
                Button {
                    let n = withAnimation(Motion.gentle) {
                        store.extractActionItems(fromNote: noteID, parser: QuickParser(lists: store.lists, workdayEndMinutes: Prefs.workdayEnd))
                    }
                    Haptics.success()
                    app.showToast(n == 0 ? "No new action items" : "Created \(Fmt.plural(n, "task")) from this note")
                } label: {
                    if style == .icons {
                        Image(systemName: "checklist")
                    } else {
                        Label(compact ? "Extract \(unlinkedOpen)" : "Extract \(unlinkedOpen) action item\(unlinkedOpen == 1 ? "" : "s")", systemImage: "checklist")
                    }
                }
                .buttonStyle(PrimaryPill(height: 32))
                .help("Turn every open “- [ ]” line into a task. Dates, durations and #lists in the line are understood.")
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
    }

    /// Read mode on an empty note: paste a document straight in, or start writing.
    private var emptyReadState: some View {
        VStack(spacing: Space.md) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(Color.ink)
                .frame(width: 56, height: 56)
                .background(Circle().fill(Color.fill))
            Text("Nothing here yet").textStyle(.title3).foregroundStyle(Color.ink)
            Text("Paste Markdown to see it formatted, drop in photos or videos, or start writing.")
                .textStyle(.callout)
                .foregroundStyle(Color.ink2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            HStack(spacing: Space.sm) {
                Button("Paste from clipboard") { pasteIntoEmpty() }
                    .buttonStyle(PrimaryPill())
                Button("Start writing") { setMode(.edit) }
                    .buttonStyle(SecondaryPill())
            }
            .padding(.top, Space.xs)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Space.x4)
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter { $0.isFileURL && MediaLibrary.kind(of: $0) != nil }
            guard !files.isEmpty else { return false }
            addFiles(files)
            return true
        }
    }

    // MARK: Actions

    private func setMode(_ mode: AppState.NoteMode) {
        focusAfterSwitch = true
        withAnimation(Motion.base) { app.noteModes[noteID] = mode }
    }

    // Changes made outside the text editor are store undo steps, so ⌘Z (the window's undo manager,
    // which the store shares) undoes them one at a time.

    private func toggleTask(_ line: Int) {
        guard let body = store.note(noteID)?.body, let updated = NoteChecklist.toggle(lineAt: line, in: body) else { return }
        store.undoable("Tick Checkbox") { store.updateNoteBody(noteID, updated) }
    }

    /// Adds a block to the end of the note, separated by a blank line.
    private func append(_ snippet: String) {
        guard let body = store.note(noteID)?.body else { return }
        let trimmed = body.trimmingCharacters(in: .newlines)
        store.undoable("Add to Note") {
            store.updateNoteBody(noteID, (trimmed.isEmpty ? snippet : trimmed + "\n\n" + snippet) + "\n")
        }
    }

    private func pasteIntoEmpty() {
        let pb = NSPasteboard.general
        let files = MediaLibrary.mediaFileURLs(on: pb)
        if !files.isEmpty {
            addFiles(files)
        } else if let lines = MediaLibrary.importFromPasteboard(pb) {
            append(lines.joined(separator: "\n\n"))
        } else if let text = pb.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            store.undoable("Paste") { store.updateNoteBody(noteID, text) }
        } else {
            app.showToast("The clipboard is empty")
        }
    }

    private func addMedia(mode: AppState.NoteMode) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .movie, .video]
        panel.allowsMultipleSelection = true
        panel.message = "Choose photos or videos to add to this note"
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        addFiles(panel.urls, atCursor: mode == .edit)
    }

    /// Copies photos or videos without holding up the app (a big video from another disk can take
    /// a while), then puts them at the editor's cursor if asked and it's still open, else at the end.
    private func addFiles(_ urls: [URL], atCursor: Bool = false) {
        let bridge = bridge
        MediaLibrary.importFilesInBackground(urls) { lines in
            guard !lines.isEmpty else {
                app.showToast("Couldn't add the photos or videos")
                return
            }
            let snippet = lines.joined(separator: "\n\n")
            if atCursor, bridge.insertAtCursor(snippet) { return }
            append(snippet)
        }
    }

    private func export(_ note: Note) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = note.title.replacingOccurrences(of: "/", with: "-") + ".md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? note.body.write(to: url, atomically: true, encoding: .utf8)
        // Photos and videos travel with it, so the Markdown's links keep working.
        MediaLibrary.copyReferencedMedia(for: [note.body], to: url.deletingLastPathComponent())
    }
}

struct LinkedTasksPopover: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var app: AppState
    let noteID: UUID

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("Tasks from this note").textStyle(.title3).foregroundStyle(Color.ink)
            ScrollView {
            VStack(alignment: .leading, spacing: Space.sm) {
            ForEach(store.linkedTasks(forNote: noteID)) { t in
                HStack(spacing: Space.md) {
                    CheckCircle(done: t.isCompleted, priority: t.priority, size: 18) { app.toggle(t.id, in: store) }
                    Button {
                        app.reveal(task: t.id, in: store)
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(t.title)
                                .font(.system(size: 13.5, weight: .semibold))
                                .lineLimit(2)
                                .strikethrough(t.isCompleted, color: .ink3)
                                .foregroundStyle(t.isCompleted ? Color.ink3 : Color.ink)
                            if let due = t.dueDate {
                                Text(Fmt.due(due, hasTime: t.dueHasTime)).textStyle(.caption).foregroundStyle(Color.ink2)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 2)
            }
            }
            }
            .frame(maxHeight: 360)
        }
        .padding(Space.lg)
        .frame(width: 320)
        .background(Color.raised)
    }
}
