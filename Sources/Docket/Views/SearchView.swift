import AppKit
import SwiftUI

// MARK: - Search view

/// Search results across every task and note. Shown while the sidebar search field has text.
/// Same two panes as a task list: results on the left; on the right the selected task's details, or the
/// bulk edit panel when several tasks are selected.
struct SearchView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var app: AppState
    @State private var escapeMonitor: Any?

    var body: some View {
        HStack(spacing: 0) {
            SearchResultsPane()
                .frame(minWidth: 368, maxWidth: .infinity, alignment: .leading)

            // Several tasks selected: edit them together. One task: its details.
            let bulk = showsBulkPanel
            let detailID = app.selectedTaskID.flatMap { store.task($0) != nil ? $0 : nil }
            if bulk || detailID != nil {
                Rectangle().fill(Color.hair).frame(width: 1).ignoresSafeArea()
                if bulk {
                    BulkEditPanel()
                        .frame(width: 370)
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 16)), removal: .opacity))
                } else if let detailID {
                    TaskDetailView(taskID: detailID)
                        .frame(width: 370)
                        .id(detailID)
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 16)), removal: .opacity))
                }
            }
        }
        .onAppear(perform: watchEscape)
        .onDisappear(perform: stopWatchingEscape)
    }

    /// At least two of the selected tasks still exist.
    private var showsBulkPanel: Bool {
        app.isMultiSelecting && store.tasks.lazy.filter { app.selectedTaskIDs.contains($0.id) }.prefix(2).count == 2
    }

    /// Esc in the results, once there's no selection or open task left for it to close, ends the search.
    /// (This runs before the app's own Esc handling, which closes the details and drops a multi-selection.)
    private func watchEscape() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                  let window = event.window, window === NSApp.docketMainWindow, window.attachedSheet == nil,
                  !(window.firstResponder is NSText), !app.showPalette, app.selection == .search,
                  !app.isMultiSelecting, app.selectedTaskID.flatMap({ store.task($0) }) == nil else { return event }
            withAnimation(Motion.fast) { app.endSearch(in: store) }
            return nil
        }
    }

    private func stopWatchingEscape() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
    }
}

private struct SearchResultsPane: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var app: AppState

    /// Scrolled to whenever the query changes, so the best matches are in view.
    private static let top = "search-top"

    var body: some View {
        let results = store.search(app.searchText, keeping: app.recentlyCompleted, now: app.clock)

        VStack(alignment: .leading, spacing: 0) {
            SearchHeader(subtitle: subtitle(results))

            if results.query.isEmpty {
                SearchHint()
            } else if results.isEmpty {
                EmptyState(icon: "magnifyingglass", title: "No matches for “\(shownQuery)”",
                           message: "Check the spelling or try fewer words. Lists, tags, steps and notes are searched too.")
            } else {
                list(results)
            }
        }
        .background(Color.paper)
        // ↑/↓, ⇧-click ranges and ⌘A go through `searchResultIDs` here, so it follows the rows on screen
        // whenever they change: a new query, an edit, a task ticked off.
        .onAppear { app.searchResultIDs = results.taskOrder }
        .onChange(of: results.taskOrder) { app.searchResultIDs = $0 }
    }

    private func list(_ results: SearchResults) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                EnterUpWindow {
                    LazyVStack(alignment: .leading, spacing: app.compactRows ? 1 : 2) {
                        Color.clear.frame(height: 0).id(Self.top)
                        if !results.tasks.isEmpty {
                            sectionHeader("Tasks", TaskSection(id: "search", title: "Tasks", tasks: results.tasks).subtitle, first: true)
                            ForEach(Array(results.tasks.enumerated()), id: \.element.id) { i, task in
                                TaskRow(task: task, context: .search, index: i)
                            }
                        }
                        if !results.completed.isEmpty {
                            sectionHeader("Completed", completedSubtitle(results), first: results.tasks.isEmpty)
                            ForEach(Array(results.completed.enumerated()), id: \.element.id) { i, task in
                                TaskRow(task: task, context: .search, index: results.tasks.count + i)
                            }
                        }
                        if !results.notes.isEmpty {
                            sectionHeader("Notes", Fmt.plural(results.notes.count, "note"), first: results.tasks.isEmpty && results.completed.isEmpty)
                            ForEach(Array(results.notes.enumerated()), id: \.element.id) { i, note in
                                SearchNoteRow(note: note, query: results.query, index: results.tasks.count + results.completed.count + i)
                            }
                        }
                    }
                }
                .padding(.horizontal, Space.gutter - 14)
                .padding(.bottom, Space.x6)
            }
            .onChange(of: app.selectedTaskID) { id in
                if let id { withAnimation(Motion.snappy) { proxy.scrollTo(id) } }
            }
            .onChange(of: app.searchText) { _ in proxy.scrollTo(Self.top, anchor: .top) }
            .onAppear {
                if let id = app.selectedTaskID { proxy.scrollTo(id) }
            }
        }
    }

    /// Spaced like the task lists' section headers; the first one sits close under the page header.
    private func sectionHeader(_ title: String, _ detail: String, first: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Eyebrow(text: title)
            Spacer()
            Text(detail).textStyle(.caption).foregroundStyle(Color.ink3).lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.top, first ? Space.xs : (app.compactRows ? Space.md : Space.xl))
        .padding(.bottom, app.compactRows ? Space.xs : Space.sm)
    }

    /// "3 tasks · 1 note for “board”".
    private func subtitle(_ results: SearchResults) -> String? {
        results.summary.map { "\($0) for “\(shownQuery)”" }
    }

    private func completedSubtitle(_ results: SearchResults) -> String {
        results.completedTotal > results.completed.count
            ? "Latest \(results.completed.count) of \(results.completedTotal)"
            : Fmt.plural(results.completed.count, "task")
    }

    /// The query as typed, cut short so a pasted paragraph doesn't take over the header.
    private var shownQuery: String {
        let text = app.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count > 40 ? text.prefix(39).trimmingCharacters(in: .whitespaces) + "…" : text
    }
}

/// "Search" and what was found, laid out like the other pages' headers. Unlike theirs it never moves the
/// compact-rows button onto a line of its own when the summary is long: the summary is cut short instead,
/// so the results don't jump around while you type.
private struct SearchHeader: View {
    var subtitle: String?

    var body: some View {
        HStack(alignment: .center, spacing: Space.md) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Search")
                    .textStyle(.largeTitle)
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                // The line stays when there's nothing to say, so the page doesn't shift as results come and go.
                Text(subtitle ?? " ")
                    .textStyle(.callout)
                    .foregroundStyle(Color.ink2)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityHidden(subtitle == nil)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            CompactRowsToggle()
        }
        .padding(.horizontal, Space.gutter)
        .padding(.top, Space.lg)
        .padding(.bottom, Space.lg)
    }
}

/// A note in the results: its title, the line that matched (or its opening lines) and when it was edited.
private struct SearchNoteRow: View {
    @EnvironmentObject var app: AppState
    let note: Note
    let query: SearchQuery
    let index: Int
    @State private var hovering = false

    var body: some View {
        let excerpt = query.excerpt(for: note)
        Button { app.reveal(note: note.id) } label: {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: note.dailyKey != nil ? "sun.max" : "doc.text")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.ink2)
                    .frame(width: 22, height: 22)
                TitleWhenLayout {
                    if app.compactRows {
                        HStack(spacing: Space.sm) {
                            title
                            if !excerpt.isEmpty {
                                highlighted(excerpt)
                                    .font(.system(size: 12.5))
                                    .lineLimit(1)
                            }
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 3) {
                            title
                            if !excerpt.isEmpty {
                                highlighted(excerpt)
                                    .font(.system(size: 12.5))
                                    .lineLimit(2)
                            }
                        }
                    }
                    Text(Fmt.absoluteDay(note.updatedAt, now: app.clock))
                        .font(.system(size: app.compactRows ? 13 : 14, weight: .semibold))
                        .tracking(-0.2)
                        .monospacedDigit()
                        .foregroundStyle(Color.ink2)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, app.compactRows ? 6 : 11)
            .background(
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .fill(hovering ? Color.pressedTint : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale(scale: 0.985))
        .onHover { h in withAnimation(Motion.fast) { hovering = h } }
        .help("Open this note")
        .contextMenu {
            Button("Open Note") { app.reveal(note: note.id) }
            Button("Copy as Markdown") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(note.body, forType: .string)
            }
        }
        .enterUp(index)
    }

    private var title: some View {
        Text(note.title)
            .font(.system(size: app.compactRows ? 13.5 : 15, weight: .semibold))
            .tracking(-0.2)
            .foregroundStyle(Color.ink)
            .lineLimit(1)
            .layoutPriority(1)
    }

    /// The excerpt in ink2, with the words that matched in ink.
    private func highlighted(_ text: String) -> Text {
        var result = Text("")
        var cursor = text.startIndex
        for range in query.highlights(in: text) {
            if cursor < range.lowerBound { result = result + Text(text[cursor..<range.lowerBound]).foregroundColor(.ink2) }
            result = result + Text(text[range]).fontWeight(.semibold).foregroundColor(.ink)
            cursor = range.upperBound
        }
        if cursor < text.endIndex { result = result + Text(text[cursor...]).foregroundColor(.ink2) }
        return result
    }
}

/// Before anything's typed: what search covers and the two bits of syntax worth knowing.
private struct SearchHint: View {
    var body: some View {
        VStack(spacing: Space.md) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(Color.ink)
                .frame(width: 56, height: 56)
                .background(Circle().fill(Color.fill))
            Text("Search tasks and notes")
                .textStyle(.title3)
                .foregroundStyle(Color.ink)
            Text("Every word is looked for in titles, notes, steps, lists, tags and who you're waiting on.")
                .textStyle(.callout)
                .foregroundStyle(Color.ink2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            Grid(alignment: .leading, horizontalSpacing: Space.sm, verticalSpacing: Space.sm) {
                tip("\"board deck\"", "Exact phrase")
                tip("#hiring", "Tasks with that tag")
                tip("esc", "Back to where you were")
            }
            .padding(.top, Space.sm)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Space.x4)
        .enterUp()
    }

    private func tip(_ example: String, _ meaning: String) -> some View {
        GridRow {
            KeyCap(text: example)
            Text(meaning)
                .textStyle(.subhead)
                .foregroundStyle(Color.ink2)
        }
    }
}

// MARK: - Sidebar field

/// The search field at the top of the sidebar. Typing shows the Search view; ✕ or Esc goes back.
/// ⌘F puts the cursor here (`app.focusSearch`); ↓ or Return moves into the results.
struct SidebarSearchField: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var app: AppState
    @FocusState private var focused: Bool
    @State private var keyMonitor: Any?

    var body: some View {
        let active = app.selection == .search
        let empty = app.searchText.isEmpty

        HStack(spacing: Space.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(focused || active ? Color.ink : Color.ink2)
                .frame(width: 20)
                .contentShape(Rectangle())
                .onTapGesture { focused = true }
            TextField("Search", text: Binding(get: { app.searchText }, set: { type($0) }))
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .medium))
                // Text left from a search you've navigated away from reads as resting, not active.
                .foregroundStyle(focused || active ? Color.ink : Color.ink2)
                .focused($focused)
                .onSubmit(openFirstResult)
            if !empty {
                Button(action: clear) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.ink3)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Clear search (esc)")
                .transition(.opacity)
            } else if !focused {
                KeyCap(text: "⌘F")
                    .onTapGesture { focused = true }
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(Color.fill))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                .strokeBorder(focused ? Color.ink.opacity(0.35) : (active ? Color.hairStrong : Color.clear), lineWidth: focused ? 1.5 : 1)
        )
        .animation(Motion.fast, value: focused)
        .animation(Motion.fast, value: empty)
        .help("Search all tasks and notes (⌘F)")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Search")
        .onChange(of: app.focusSearch) { _ in
            // ⌘F again with the cursor already here selects what's typed, ready to type over (focusing does that too).
            if focused, let editor = NSApp.docketMainWindow?.firstResponder as? NSTextView, editor.isFieldEditor {
                editor.selectAll(nil)
            } else {
                focused = true
            }
        }
        .onChange(of: focused) { isFocused in
            if isFocused {
                watchKeys()
                // Back in the field with a search still in it: show its results again.
                if hasQuery(app.searchText) { app.enterSearch() }
                // Get every task ready to search while the cursor settles in, not on the first letter typed.
                DispatchQueue.main.async { store.prepareSearch() }
            } else {
                stopWatchingKeys()
            }
        }
        .onDisappear(perform: stopWatchingKeys)
    }

    // MARK: Actions

    private func type(_ text: String) {
        app.searchText = text
        // The first real character switches to the results and remembers where you were.
        if hasQuery(text) { app.enterSearch() }
    }

    private func hasQuery(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func clear() {
        withAnimation(Motion.fast) { app.endSearch(in: store) }
    }

    private func escape() {
        if !app.searchText.isEmpty || app.selection == .search {
            withAnimation(Motion.fast) { app.endSearch(in: store) }
        }
        // Hand the keyboard back to the list, so the arrow keys work there again.
        focused = false
    }

    /// ↓: select the first result (unless one already is) and give the keyboard to the list, where ↑/↓,
    /// ⇧↑/⇧↓, Return and t / m / w / x carry on from it.
    private func moveIntoResults() -> Bool {
        guard app.selection == .search else { return false }
        let order = app.searchTaskOrder(in: store)
        guard let first = order.first else { return false }
        focused = false
        if let current = app.selectedTaskID, order.contains(current) { return true }
        app.selectOnly(first)
        return true
    }

    /// Return: open the best task, or the best note when no task matched.
    private func openFirstResult() {
        guard app.selection == .search else { return }
        if moveIntoResults() { return }
        if let note = store.search(app.searchText, keeping: app.recentlyCompleted, now: app.clock).notes.first {
            app.reveal(note: note.id)
        }
    }

    // MARK: Keys

    /// While the field has the cursor: Esc clears and goes back, ↓ moves into the results.
    /// (The app's own arrow and Esc handling stays out of the way while a text field is in use.)
    private func watchKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleKey(event) ? nil : event
        }
    }

    private func stopWatchingKeys() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard focused, let window = event.window, window === NSApp.docketMainWindow,
              let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
              // Keys that pick or cancel an input method's candidates belong to it.
              !editor.hasMarkedText(),
              event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return false }
        switch event.keyCode {
        case 53: // esc
            escape()
            return true
        case 125: // down
            return moveIntoResults()
        default:
            return false
        }
    }
}

// MARK: - Search navigation

extension AppState {
    /// Shows the Search view, remembering the view (and open task) to go back to. Does nothing if it's showing.
    func enterSearch() {
        guard selection != .search else { return }
        selectionBeforeSearch = selection
        SearchMemory.remember(selectedTaskID, for: self)
        selection = .search
    }

    /// Clears the search; if the Search view is showing, goes back to the view (and task) open before it.
    /// A list deleted in the meantime, or a tag no open task has any more, goes back to the Inbox instead.
    func endSearch(in store: Store) {
        searchText = ""
        searchResultIDs = []
        let openBefore = SearchMemory.take(for: self)
        guard selection == .search else { return }
        var back = selectionBeforeSearch
        switch back {
        case .search:
            back = .calendar
        case .list(let id) where store.list(id) == nil:
            back = .inbox
        case .tag(let tag) where !store.allTags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }):
            back = .inbox
        default:
            break
        }
        selection = back
        if back.isTaskView, let id = openBefore, store.task(id) != nil { selectOnly(id) }
    }

    /// Task ids in the order the Search view lists them (open, then completed): what `searchResultIDs` holds
    /// while the Search view shows.
    func searchTaskOrder(in store: Store) -> [UUID] {
        store.search(searchText, keeping: recentlyCompleted, now: clock).taskOrder
    }
}

/// The task that was open when a search started, so it opens again when the search ends. Kept per
/// `AppState`, as `AppState` can't hold it itself from here.
@MainActor
private enum SearchMemory {
    private static var openTask: [ObjectIdentifier: UUID] = [:]

    static func remember(_ id: UUID?, for app: AppState) { openTask[ObjectIdentifier(app)] = id }
    static func take(for app: AppState) -> UUID? { openTask.removeValue(forKey: ObjectIdentifier(app)) }
}

extension NSApplication {
    /// Docket's main window (the one with the sidebar), so key handling ignores Settings and panels.
    @MainActor var docketMainWindow: NSWindow? { (delegate as? AppDelegate)?.mainWindow }
}
