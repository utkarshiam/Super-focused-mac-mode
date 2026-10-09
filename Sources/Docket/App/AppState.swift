import AppKit
import SwiftUI

enum SidebarItem: Hashable {
    case calendar, inbox, important, all, completed
    case list(UUID)
    case tag(String)
    case notes
    case insights
    case search, waiting, suggestions

    var isTaskView: Bool {
        switch self {
        case .notes, .insights, .suggestions: false
        default: true
        }
    }
}

/// What the "Plan with AI" sheet starts from.
struct AIPlannerRequest: Identifiable {
    let id = UUID()
    var text = ""
    /// Set when planning from a note: created tasks link back to it.
    var noteID: UUID?
    /// Pre-filled drafts to review (e.g. from a Slack/Gmail suggestion); skips the prompt step when non-empty.
    var drafts: [TaskDraft] = []
}

/// UI navigation state shared by the main window, menu bar popover, quick capture and command palette.
@MainActor
final class AppState: ObservableObject {
    @Published var selection: SidebarItem = .calendar {
        didSet {
            if oldValue != selection {
                selectedTaskID = nil
                selectedTaskIDs = []
                selectionAnchor = nil
            }
        }
    }

    enum CalendarMode: String { case agenda, month }
    @Published var calendarMode: CalendarMode = .agenda
    /// The day highlighted in the week strip / month grid (start of day).
    @Published var selectedDay = Calendar.current.startOfDay(for: Date())
    /// Set to scroll the agenda to a day; the view clears it once it has scrolled.
    @Published var scrollRequest: Date?
    /// The task being dragged right now, so rows can tell whether they'd accept it before the drop.
    @Published var draggingTaskID: UUID?

    /// The sidebar can be hidden for a focused, full-width view (⌃⌘S). Remembered across launches.
    @Published var sidebarVisible = UserDefaults.standard.object(forKey: "sidebarVisible") as? Bool ?? true {
        didSet { UserDefaults.standard.set(sidebarVisible, forKey: "sidebarVisible") }
    }

    func toggleSidebar() {
        withAnimation(Motion.sheet) { sidebarVisible.toggle() }
    }

    /// ⌘F: puts the cursor in the sidebar search field, bringing the sidebar back first if it's hidden.
    func beginSearch() {
        guard sidebarVisible else {
            toggleSidebar()
            // The field only exists once the sidebar is back on screen.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.focusSearch += 1 }
            return
        }
        focusSearch += 1
    }

    enum NoteMode: Hashable { case read, edit }
    /// Read (formatted) or Edit (Markdown) per note, settled when a note first opens:
    /// Read if it has content, Edit if it's empty.
    @Published var noteModes: [UUID: NoteMode] = [:]
    /// The focused task: its details are open (unless several tasks are selected).
    @Published var selectedTaskID: UUID? {
        didSet {
            guard selectedTaskID != oldValue else { return }
            pendingClose?.cancel()
            pendingClose = nil
            guard let selectedTaskID else { return }
            lastFocusedTaskID = selectedTaskID
            // One task picked by any route (a click, the arrows, search, a reveal) is where ⇧-ranges start.
            if selectedTaskIDs.isEmpty { selectionAnchor = selectedTaskID }
        }
    }
    /// Several tasks selected (⌘-click / ⇧-click / ⌘A). Two or more = bulk editing; selectedTaskID stays the focused one.
    @Published var selectedTaskIDs: Set<UUID> = []
    /// Where ⇧-click and ⇧↑/⇧↓ ranges start: the task last clicked or arrowed to.
    private(set) var selectionAnchor: UUID?
    /// The task whose details were open last, so Return can bring them back.
    private(set) var lastFocusedTaskID: UUID?
    /// A click on the open task closes it a moment later, unless the click turns out to be the first half
    /// of a double-click (which keeps it open). See `click(_:_:in:closeDelay:)`.
    private var pendingClose: DispatchWorkItem?
    /// The Search view's task results in on-screen order. Search keeps this up to date as its results change
    /// (its rows don't come from `Store.sections`), so ↑/↓, ⇧-click ranges and ⌘A work there like in any list.
    var searchResultIDs: [UUID] = []
    /// Global search text (sidebar field). Non-empty shows the Search view.
    @Published var searchText = ""
    /// Bumped to move keyboard focus into the sidebar search field (⌘F).
    @Published var focusSearch = 0
    /// The view to go back to when search is cleared.
    var selectionBeforeSearch: SidebarItem = .calendar
    /// Dense one-line rows. Remembered across launches (UserDefaults "compactRows").
    @Published var compactRows: Bool = UserDefaults.standard.bool(forKey: Prefs.Key.compactRows) {
        didSet { UserDefaults.standard.set(compactRows, forKey: Prefs.Key.compactRows) }
    }
    /// Opens the "Plan with AI" sheet.
    @Published var aiPlanner: AIPlannerRequest?
    @Published var selectedNoteID: UUID?
    @Published var showPalette = false
    @Published var noteSearch = ""
    @Published var toast: String?
    /// Ticks every minute (and on wake / day change) so "today" and overdue states stay current.
    @Published var clock = Date()
    @Published var hotkeyRegistered = true
    /// Bumped to move keyboard focus into the quick-add field.
    @Published var focusQuickAdd = 0
    /// Tasks that were just ticked stay visible for a moment so the list doesn't jump.
    @Published private(set) var recentlyCompleted: Set<UUID> = []

    /// A message to open in Messages (`Suggestion.id`), from a notification or the menu bar panel. Messages
    /// opens it, switching tabs if need be, then clears it.
    @Published var messageToReveal: String?

    var showMainWindow: () -> Void = {}
    var showSettings: () -> Void = {}
    var showQuickCapture: () -> Void = {}

    private var toastWork: DispatchWorkItem?

    /// Opens Messages, on the message `id` when it's still there.
    func reveal(message id: String?) {
        selection = .suggestions
        messageToReveal = id
        showMainWindow()
    }

    func reveal(task id: UUID, in store: Store) {
        guard let t = store.task(id) else { return }
        let today = Calendar.current.startOfDay(for: Date())
        let onCalendar = !t.isCompleted && (store.isOverdueByDay(t, today: today) || store.calendarDay(of: t, today: today) != nil)
        if onCalendar {
            selection = .calendar
            calendarMode = .agenda
            if let day = store.calendarDay(of: t, today: today) { goTo(day: day) }
        } else if !selection.isTaskView || !store.sections(for: selection, keeping: []).contains(where: { $0.tasks.contains { $0.id == id } }) {
            selection = t.isCompleted ? .completed : (t.listID.map { .list($0) } ?? .inbox)
        }
        selectedTaskIDs = []
        selectionAnchor = id
        selectedTaskID = id
        showMainWindow()
    }

    /// Selects a day in the calendar and scrolls the agenda to it.
    func goTo(day: Date) {
        let d = Calendar.current.startOfDay(for: day)
        selectedDay = d
        scrollRequest = d
    }

    /// Up/down arrow selection through the visible tasks. A multi-selection collapses to the task moved to.
    /// Returns false when the view has no tasks to move through.
    @discardableResult
    func moveSelection(by delta: Int, in store: Store) -> Bool {
        let order = visibleTaskOrder(in: store)
        guard !order.isEmpty else { return false }
        let next: UUID
        if let current = selectedTaskID, let i = order.firstIndex(of: current) {
            next = order[min(max(i + delta, 0), order.count - 1)]
        } else {
            next = delta > 0 ? order[0] : order[order.count - 1]
        }
        selectedTaskIDs = []
        selectionAnchor = next
        if selectedTaskID == nil {
            withAnimation(Motion.sheet) { selectedTaskID = next }
        } else {
            selectedTaskID = next
        }
        return true
    }

    /// Task ids in the order the current view lists them: what arrows, ⇧-click ranges and ⌘A go through.
    func visibleTaskOrder(in store: Store) -> [UUID] {
        switch selection {
        case .calendar:
            return store.timeline(keeping: recentlyCompleted, now: clock).compactMap { $0.item.task?.id }
        case .search:
            let live = Set(store.tasks.map(\.id))
            return searchResultIDs.filter(live.contains)
        case let item where item.isTaskView:
            let defaults = UserDefaults.standard
            let sort = SortMode(rawValue: defaults.string(forKey: Prefs.Key.sortMode) ?? "") ?? .smart
            return store.sections(for: item, keeping: recentlyCompleted, sort: sort,
                                  showCompleted: defaults.bool(forKey: Prefs.Key.showCompletedInLists), now: clock)
                .flatMap { $0.tasks.map(\.id) }
        default:
            return []
        }
    }

    func moveNoteSelection(by delta: Int, in store: Store) {
        let order = store.searchNotes(noteSearch, limit: 1000).map(\.id)
        guard !order.isEmpty else { return }
        if let current = selectedNoteID, let i = order.firstIndex(of: current) {
            selectedNoteID = order[min(max(i + delta, 0), order.count - 1)]
        } else {
            selectedNoteID = order.first
        }
    }

    /// Makes a note from whatever Markdown (or photo) is on the clipboard and shows it formatted.
    func newNoteFromClipboard(_ store: Store) {
        let pb = NSPasteboard.general
        let files = MediaLibrary.mediaFileURLs(on: pb)
        if !files.isEmpty {
            // Copied photo or video files: copy them in without holding up the app, then open the note.
            MediaLibrary.importFilesInBackground(files) { [weak self] lines in
                guard let self else { return }
                guard !lines.isEmpty else {
                    self.showToast("Couldn't add the photos or videos")
                    return
                }
                self.showNewNote(lines.joined(separator: "\n\n") + "\n", in: store)
            }
            return
        }
        var body: String?
        if let lines = MediaLibrary.importFromPasteboard(pb) {
            body = lines.joined(separator: "\n\n") + "\n"
        } else if let text = pb.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body = text
        }
        guard let body else {
            showToast("The clipboard is empty. Copy something first.")
            return
        }
        showNewNote(body, in: store)
    }

    private func showNewNote(_ body: String, in store: Store) {
        let note = store.addNote(body: body)
        noteModes[note.id] = .read
        reveal(note: note.id)
    }

    func reveal(note id: UUID) {
        selection = .notes
        noteSearch = ""
        selectedNoteID = id
        showMainWindow()
    }

    func markRecentlyCompleted(_ id: UUID) {
        recentlyCompleted.insert(id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            _ = withAnimation(Motion.base) { self?.recentlyCompleted.remove(id) }
        }
    }

    func showToast(_ text: String) {
        toastWork?.cancel()
        withAnimation(Motion.gentle) { toast = text }
        let work = DispatchWorkItem { [weak self] in
            withAnimation(Motion.base) { self?.toast = nil }
        }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8, execute: work)
    }

    /// Completes a task from a checkbox click with the small niceties (grace period, toast for repeats).
    func toggle(_ id: UUID, in store: Store) {
        guard let t = store.task(id) else { return }
        let next = withAnimation(Motion.base) { store.toggleCompleted(id) }
        if !t.isCompleted {
            Haptics.success()
            if let next {
                showToast("Repeats. Next on \(Fmt.absoluteDay(next)).")
            } else {
                markRecentlyCompleted(id)
                NSSound(named: "Pop")?.play()
                Extras.didComplete(id, store: store, app: self)
            }
        }
    }
}

// MARK: - Selecting tasks

extension AppState {
    /// How a task row was clicked.
    enum RowClick {
        /// A plain click: just this task. Clicking the open task again closes it.
        case plain
        /// ⌘-click: adds the task to the selection, or takes it out.
        case toggle
        /// ⇧-click: every task from the anchor to this one.
        case range
        /// A double-click: this task's details, open.
        case open
    }

    /// Whether a row shows as selected: the focused task, or one of several picked with ⌘ or ⇧.
    func isSelected(_ id: UUID) -> Bool { selectedTaskID == id || selectedTaskIDs.contains(id) }

    /// Two or more tasks are selected, so the right-hand panel edits them together.
    var isMultiSelecting: Bool { selectedTaskIDs.count >= 2 }

    /// `closeDelay`: how long a plain click on the open task waits before closing it, so that the first click
    /// of a double-click doesn't flash the panel shut (rows pass the double-click time; tests use 0).
    func click(_ id: UUID, _ kind: RowClick, in store: Store, closeDelay: TimeInterval = 0) {
        pendingClose?.cancel()
        pendingClose = nil
        switch kind {
        case .plain:
            if isMultiSelecting || (selectedTaskID != nil && selectedTaskID != id) {
                selectOnly(id)
            } else if selectedTaskID == id {
                closeDetail(of: id, after: closeDelay)
            } else {
                // Opening and closing the panel animate; switching to another task is instant.
                selectionAnchor = id
                withAnimation(Motion.sheet) { selectedTaskID = id }
            }
        case .open:
            selectOnly(id)
        case .toggle:
            toggleInSelection(id, in: store)
        case .range:
            selectRange(to: id, in: store)
        }
    }

    /// Just this task, with its details open.
    func selectOnly(_ id: UUID) {
        let opening = selectedTaskID == nil
        selectedTaskIDs = []
        selectionAnchor = id
        if opening {
            withAnimation(Motion.sheet) { selectedTaskID = id }
        } else {
            selectedTaskID = id
        }
    }

    /// Closes the right-hand panel and clears the selection.
    func deselectAll() {
        withAnimation(Motion.sheet) {
            selectedTaskIDs = []
            selectedTaskID = nil
        }
        selectionAnchor = nil
    }

    /// Closes the open task's details now, or after `delay` if nothing else has been picked by then
    /// (picking anything cancels it).
    private func closeDetail(of id: UUID, after delay: TimeInterval) {
        guard delay > 0 else { return closeDetailNow(of: id) }
        let work = DispatchWorkItem { [weak self] in self?.closeDetailNow(of: id) }
        pendingClose = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func closeDetailNow(of id: UUID) {
        guard selectedTaskID == id, !isMultiSelecting else { return }
        selectionAnchor = nil
        withAnimation(Motion.sheet) { selectedTaskID = nil }
    }

    /// ⇧↑ / ⇧↓: grows or shrinks the selection from the anchor, one task at a time.
    /// With nothing selected yet it's a plain arrow.
    @discardableResult
    func extendSelection(by delta: Int, in store: Store) -> Bool {
        let order = visibleTaskOrder(in: store)
        guard let lead = selectedTaskID, let i = order.firstIndex(of: lead) else {
            return moveSelection(by: delta, in: store)
        }
        let anchor = selectionAnchor.flatMap { order.contains($0) ? $0 : nil } ?? lead
        let a = order.firstIndex(of: anchor) ?? i
        let j = min(max(i + delta, 0), order.count - 1)
        let range = order[min(a, j)...max(a, j)]
        selectedTaskIDs = range.count >= 2 ? Set(range) : []
        selectedTaskID = order[j]
        selectionAnchor = anchor
        return true
    }

    /// ⌘A: every open task in the view (in Completed, every task there). False when there's nothing to select.
    @discardableResult
    func selectAllVisible(in store: Store) -> Bool {
        // The month grid has no rows to select.
        guard selection.isTaskView, !(selection == .calendar && calendarMode == .month) else { return false }
        var ids = visibleTaskOrder(in: store)
        if selection != .completed {
            let open = Set(store.tasks.lazy.filter { !$0.isCompleted }.map(\.id))
            ids = ids.filter(open.contains)
        }
        guard let first = ids.first else { return false }
        guard ids.count >= 2 else {
            selectOnly(first)
            return true
        }
        let focus = selectedTaskID.flatMap { ids.contains($0) ? $0 : nil } ?? first
        withAnimation(selectedTaskID == nil ? Motion.sheet : Motion.base) {
            selectedTaskIDs = Set(ids)
            selectedTaskID = focus
        }
        selectionAnchor = first
        return true
    }

    /// Esc with several tasks selected: keeps just the focused one, whose details then show.
    /// False when there was no multi-selection to drop.
    @discardableResult
    func collapseSelection() -> Bool {
        guard isMultiSelecting else { return false }
        withAnimation(Motion.base) { selectedTaskIDs = [] }
        selectionAnchor = selectedTaskID
        return true
    }

    /// Return: opens or closes the details. With several selected it opens the focused task on its own;
    /// with nothing open it brings back the last task you had open (or the first one in the list).
    @discardableResult
    func toggleDetail(in store: Store) -> Bool {
        if collapseSelection() { return true }
        if selectedTaskID != nil {
            withAnimation(Motion.sheet) { selectedTaskID = nil }
            return true
        }
        let order = visibleTaskOrder(in: store)
        guard let id = lastFocusedTaskID.flatMap({ order.contains($0) ? $0 : nil }) ?? order.first else { return false }
        selectOnly(id)
        return true
    }

    /// ⌘-click: adds a task to the selection or takes it out. The first ⌘-click on another task keeps the
    /// open one selected too; dropping back to a single task shows its details again.
    private func toggleInSelection(_ id: UUID, in store: Store) {
        var picked = selectedTaskIDs
        if picked.isEmpty, let focused = selectedTaskID { picked = [focused] }
        if picked.contains(id) {
            picked.remove(id)
            if picked.count >= 2 {
                selectedTaskIDs = picked
                if selectedTaskID == id { selectedTaskID = nearest(to: id, among: picked, in: store) }
                selectionAnchor = selectedTaskID
            } else if let remaining = picked.first {
                selectOnly(remaining)
            } else {
                deselectAll()
            }
        } else {
            picked.insert(id)
            guard picked.count >= 2 else { return selectOnly(id) }
            // The details make way for the bulk edit panel.
            withAnimation(Motion.base) {
                selectedTaskIDs = picked
                selectedTaskID = id
            }
            selectionAnchor = id
        }
    }

    /// ⇧-click: every task from the anchor (the one last clicked) to `id`, in list order.
    private func selectRange(to id: UUID, in store: Store) {
        let order = visibleTaskOrder(in: store)
        // Only a live selection has an anchor; with nothing selected, ⇧-click is a plain click.
        let start = selectedTaskID == nil ? nil : [selectionAnchor, selectedTaskID].compactMap { $0 }.first(where: order.contains)
        guard let start, start != id, let a = order.firstIndex(of: start), let b = order.firstIndex(of: id) else {
            return selectOnly(id)
        }
        withAnimation(Motion.base) {
            selectedTaskIDs = Set(order[min(a, b)...max(a, b)])
            selectedTaskID = id
        }
        selectionAnchor = start
    }

    /// The selected task nearest to `id` in the list: the next one down, else up.
    private func nearest(to id: UUID, among picked: Set<UUID>, in store: Store) -> UUID? {
        let order = visibleTaskOrder(in: store)
        guard let i = order.firstIndex(of: id) else { return picked.first }
        return order[(i + 1)...].first(where: picked.contains) ?? order[..<i].last(where: picked.contains) ?? picked.first
    }
}

// MARK: - Changing several tasks at once (bulk edit panel, keyboard triage, Task menu)

extension AppState {
    /// What t / m / w / x do in a task list.
    enum Triage {
        case move(QuickDay)
        case done
    }

    /// What the keyboard and the Task menu act on: every selected task (in list order), else the focused one.
    func actionTargets(in store: Store) -> [UUID] {
        if isMultiSelecting { return inVisibleOrder(selectedTaskIDs, in: store) }
        guard let id = selectedTaskID, store.task(id) != nil else { return [] }
        return [id]
    }

    /// `ids` in the order the view lists them; any it doesn't show follow, by title. Unknown ids are dropped.
    func inVisibleOrder(_ ids: Set<UUID>, in store: Store) -> [UUID] {
        let listed = visibleTaskOrder(in: store).filter(ids.contains)
        let shown = Set(listed)
        let rest = store.tasks.filter { ids.contains($0.id) && !shown.contains($0.id) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return listed + rest.map(\.id)
    }

    /// t / m / w / x on the selected tasks (or the focused one): one undo step and a toast each.
    /// A single task that leaves its spot (ticked off, or moved elsewhere in the list) hands the cursor to
    /// the task below it, so you can work down a list from the keyboard. False when nothing is selected.
    @discardableResult
    func triage(_ action: Triage, in store: Store) -> Bool {
        let targets = actionTargets(in: store)
        guard !targets.isEmpty else { return false }
        let before = visibleTaskOrder(in: store)
        switch action {
        case .move(let day):
            move(targets, toDay: day.date(), in: store)
            if targets.count == 1 { keepPlace(of: targets[0], before: before, in: store) }
        case .done:
            toggleDone(targets, in: store)
            moveOn(from: targets, before: before, in: store)
        }
        return true
    }

    /// Delete / ⌫ in a task list: removes the selected tasks (asking first when there are more than five)
    /// and moves the cursor on to the next task. False when nothing is selected.
    @discardableResult
    func deleteSelection(in store: Store) -> Bool {
        let targets = actionTargets(in: store)
        guard !targets.isEmpty else { return false }
        let before = visibleTaskOrder(in: store)
        delete(targets, in: store) { [weak self] in self?.moveOn(from: targets, before: before, in: store) }
        return true
    }

    /// Moves the open tasks to `day` (a deadline keeps its time) as one undo step, and says so.
    /// Finished tasks keep their dates.
    func move(_ ids: [UUID], toDay day: Date, in store: Store) {
        guard !ids.isEmpty else { return }
        let date = Fmt.absoluteDay(day, now: clock)
        let open = openTasks(ids, in: store)
        guard !open.isEmpty else { return showToast(ids.count == 1 ? "It's done already" : "They're all done already") }
        let moved = withAnimation(Motion.gentle) { store.moveTasks(open, toDay: day) }
        guard moved > 0 else {
            showToast(open.count == 1 ? "Already on \(date)" : "They're all on \(date) already")
            return
        }
        Haptics.success()
        showToast(open.count == 1 ? "Moved to \(date)" : "Moved \(Fmt.plural(open.count, "task")) to \(date)")
    }

    /// Takes the plan dates and deadlines off the open tasks.
    func clearDates(_ ids: [UUID], in store: Store) {
        let cleared = withAnimation(Motion.gentle) { store.clearDates(of: ids) }
        guard cleared > 0 else { return }
        showToast(cleared == 1 ? "Removed the date" : "Removed the dates from \(Fmt.plural(cleared, "task"))")
    }

    /// "Do Today" on several tasks: plan dates only, deadlines stay.
    func plan(_ ids: [UUID], on day: Date, in store: Store) {
        let open = openTasks(ids, in: store)
        guard withAnimation(Motion.gentle, { store.planTasks(open, on: day) }) > 0 else { return }
        showToast("Planned \(Fmt.plural(open.count, "task")) for \(Fmt.absoluteDay(day, now: clock))")
    }

    /// "Move to Tomorrow" on several tasks.
    func pushToTomorrow(_ ids: [UUID], in store: Store) {
        let open = openTasks(ids, in: store)
        guard withAnimation(Motion.gentle, { store.pushTasksToTomorrow(open) }) > 0 else { return }
        showToast("Moved \(Fmt.plural(open.count, "task")) to \(Fmt.absoluteDay(QuickDay.tomorrow.date(), now: clock))")
    }

    /// The ones still to do, in the same order.
    private func openTasks(_ ids: [UUID], in store: Store) -> [UUID] {
        let open = Set(store.tasks.lazy.filter { !$0.isCompleted }.map(\.id))
        return ids.filter(open.contains)
    }

    /// Ticks the tasks off, or reopens them when they're all done already. One undo step.
    func toggleDone(_ ids: [UUID], in store: Store) {
        let picked = Set(ids)
        let tasks = store.tasks.filter { picked.contains($0.id) }
        guard !tasks.isEmpty else { return }
        let done = tasks.contains { !$0.isCompleted }
        let changed = withAnimation(Motion.base) { store.completeTasks(ids, done: done) }
        guard !changed.isEmpty else { return }
        guard done else {
            showToast(changed.count == 1 ? "Marked as not done" : "Marked \(Fmt.plural(changed.count, "task")) as not done")
            return
        }
        Haptics.success()
        NSSound(named: "Pop")?.play()
        // Finished tasks stay in view for a moment; repeating ones have already moved to their next date.
        let finished = changed.filter { $0.next == nil }.map(\.id)
        for id in finished { markRecentlyCompleted(id) }
        if changed.count == 1, let next = changed[0].next {
            showToast("Repeats. Next on \(Fmt.absoluteDay(next)).")
        } else {
            showToast(changed.count == 1 ? "Marked as done" : "Marked \(Fmt.plural(changed.count, "task")) as done")
        }
        for id in finished { Extras.didComplete(id, store: store, app: self) }
    }

    func setPriority(_ priority: Priority, for ids: [UUID], in store: Store) {
        guard store.setPriority(priority, for: ids) > 0 else { return }
        if priority == Priority.none {
            showToast(ids.count == 1 ? "Removed the priority" : "Removed the priority from \(Fmt.plural(ids.count, "task"))")
        } else {
            showToast(ids.count == 1 ? "Set to \(priority.label) priority" : "Set \(Fmt.plural(ids.count, "task")) to \(priority.label) priority")
        }
    }

    /// Moves the tasks into a list (nil = Inbox).
    func setList(_ listID: UUID?, for ids: [UUID], in store: Store) {
        guard store.setList(listID, for: ids) > 0 else { return }
        let name = store.list(listID)?.name ?? "Inbox"
        showToast(ids.count == 1 ? "Moved to \(name)" : "Moved \(Fmt.plural(ids.count, "task")) to \(name)")
    }

    func setEstimate(_ minutes: Int?, for ids: [UUID], in store: Store) {
        guard store.setEstimate(minutes, for: ids) > 0 else { return }
        if let minutes {
            let time = Fmt.duration(minutes: minutes)
            showToast(ids.count == 1 ? "Now takes \(time)" : "\(Fmt.plural(ids.count, "task")) now take \(time) each")
        } else {
            showToast(ids.count == 1 ? "Removed the estimate" : "Removed the estimates from \(Fmt.plural(ids.count, "task"))")
        }
    }

    /// Who the tasks wait on; nil or blank clears it.
    func setWaitingOn(_ name: String?, for ids: [UUID], in store: Store) {
        guard store.setWaitingOn(name, for: ids) > 0 else { return }
        if let person = Store.personName(name) {
            showToast(ids.count == 1 ? "Waiting on \(person)" : "Waiting on \(person) for \(Fmt.plural(ids.count, "task"))")
        } else {
            showToast(ids.count == 1 ? "No longer waiting on anyone" : "\(Fmt.plural(ids.count, "task")) are no longer waiting on anyone")
        }
    }

    func addTag(_ text: String, to ids: [UUID], in store: Store) {
        guard let tag = Store.tagName(text), store.addTag(tag, to: ids) > 0 else { return }
        showToast(ids.count == 1 ? "Tagged #\(tag)" : "Tagged \(Fmt.plural(ids.count, "task")) #\(tag)")
    }

    func removeTag(_ tag: String, from ids: [UUID], in store: Store) {
        let removed = store.removeTag(tag, from: ids)
        guard removed > 0 else { return }
        showToast(removed == 1 ? "Removed #\(tag)" : "Removed #\(tag) from \(Fmt.plural(removed, "task"))")
    }

    /// Puts the tasks on the clipboard as a Markdown checklist ("- [ ] Title — Mon 5 Oct · 30m").
    func copyChecklist(_ ids: [UUID], in store: Store) {
        let text = store.checklistMarkdown(for: ids, now: clock)
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showToast(ids.count == 1 ? "Copied as a checklist" : "Copied \(Fmt.plural(ids.count, "task")) as a checklist")
    }

    /// Deletes the tasks as one undo step, asking first when there are more than five. `then` runs once
    /// they're gone (not when the question is cancelled).
    func delete(_ ids: [UUID], in store: Store, then: @escaping () -> Void = {}) {
        let existing = Set(store.tasks.map(\.id))
        let ids = ids.filter(existing.contains)
        guard !ids.isEmpty else { return }
        let run = { [weak self] in
            withAnimation(Motion.base) { store.deleteTasks(Set(ids)) }
            then()
            guard let self else { return }
            // Whatever is still selected mustn't point at the deleted tasks.
            self.selectedTaskIDs.subtract(ids)
            if self.selectedTaskIDs.count == 1, let remaining = self.selectedTaskIDs.first { self.selectOnly(remaining) }
            if let focused = self.selectedTaskID, ids.contains(focused) {
                withAnimation(Motion.sheet) { self.selectedTaskID = nil }
            }
            if ids.count > 1 { self.showToast("Deleted \(Fmt.plural(ids.count, "task")). Undo with ⌘Z.") }
        }
        guard ids.count > 5 else { return run() }
        let alert = NSAlert()
        alert.messageText = "Delete \(ids.count) tasks?"
        alert.informativeText = "You can undo this with ⌘Z."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        if let window = NSApp?.keyWindow ?? NSApp?.mainWindow {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn { run() }
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            run()
        }
    }

    /// After a single task moved: if it's still in the same spot in the list, stay on it; if it went
    /// elsewhere, go on to the task that was below it.
    private func keepPlace(of id: UUID, before: [UUID], in store: Store) {
        guard let i = before.firstIndex(of: id) else { return }
        let after = visibleTaskOrder(in: store)
        if let j = after.firstIndex(of: id) {
            let aboveBefore: UUID? = i > 0 ? before[i - 1] : nil
            let aboveAfter: UUID? = j > 0 ? after[j - 1] : nil
            if aboveBefore == aboveAfter { return }
        }
        moveOn(from: [id], before: before, in: store)
    }

    /// After tasks leave their spot (done, deleted or moved away): select the task that was just below
    /// them, or just above at the end of the list, so you can keep working down it.
    private func moveOn(from acted: [UUID], before: [UUID], in store: Store) {
        let gone = Set(acted)
        let visible = Set(visibleTaskOrder(in: store))
        let usable = { (id: UUID) in !gone.contains(id) && visible.contains(id) && !self.recentlyCompleted.contains(id) }
        var next: UUID?
        if let last = before.lastIndex(where: gone.contains) {
            next = before[(last + 1)...].first(where: usable) ?? before[..<last].last(where: usable)
        }
        selectedTaskIDs = []
        selectionAnchor = next
        if let next {
            selectedTaskID = next
        } else {
            withAnimation(Motion.sheet) { selectedTaskID = nil }
        }
    }
}
