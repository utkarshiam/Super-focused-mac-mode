import AppKit
import SwiftUI

enum SidebarItem: Hashable {
    case calendar, inbox, important, all, completed
    case list(UUID)
    case tag(String)
    case notes
    case insights

    var isTaskView: Bool {
        switch self {
        case .notes, .insights: false
        default: true
        }
    }
}

/// UI navigation state shared by the main window, menu bar popover, quick capture and command palette.
@MainActor
final class AppState: ObservableObject {
    @Published var selection: SidebarItem = .calendar {
        didSet { if oldValue != selection { selectedTaskID = nil } }
    }

    enum CalendarMode: String { case agenda, month }
    @Published var calendarMode: CalendarMode = .agenda
    /// The day highlighted in the week strip / month grid (start of day).
    @Published var selectedDay = Calendar.current.startOfDay(for: Date())
    /// Set to scroll the agenda to a day; the view clears it once it has scrolled.
    @Published var scrollRequest: Date?

    /// The sidebar can be hidden for a focused, full-width view (⌃⌘S). Remembered across launches.
    @Published var sidebarVisible = UserDefaults.standard.object(forKey: "sidebarVisible") as? Bool ?? true {
        didSet { UserDefaults.standard.set(sidebarVisible, forKey: "sidebarVisible") }
    }

    func toggleSidebar() {
        withAnimation(Motion.sheet) { sidebarVisible.toggle() }
    }

    enum NoteMode: Hashable { case read, edit }
    /// Read (formatted) or Edit (Markdown) per note, settled when a note first opens:
    /// Read if it has content, Edit if it's empty.
    @Published var noteModes: [UUID: NoteMode] = [:]
    @Published var selectedTaskID: UUID?
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

    var showMainWindow: () -> Void = {}
    var showSettings: () -> Void = {}
    var showQuickCapture: () -> Void = {}

    private var toastWork: DispatchWorkItem?

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
        selectedTaskID = id
        showMainWindow()
    }

    /// Selects a day in the calendar and scrolls the agenda to it.
    func goTo(day: Date) {
        let d = Calendar.current.startOfDay(for: day)
        selectedDay = d
        scrollRequest = d
    }

    /// Up/down arrow selection through the visible tasks.
    func moveSelection(by delta: Int, in store: Store) {
        let order: [UUID]
        if selection == .calendar {
            order = store.timeline(keeping: recentlyCompleted, now: clock).compactMap { $0.item.task?.id }
        } else {
            let sort = SortMode(rawValue: UserDefaults.standard.string(forKey: Prefs.Key.sortMode) ?? "") ?? .smart
            order = store.sections(for: selection, keeping: recentlyCompleted, sort: sort,
                                   showCompleted: UserDefaults.standard.bool(forKey: Prefs.Key.showCompletedInLists), now: clock)
                .flatMap { $0.tasks.map(\.id) }
        }
        guard !order.isEmpty else { return }
        let next: UUID
        if let current = selectedTaskID, let i = order.firstIndex(of: current) {
            next = order[min(max(i + delta, 0), order.count - 1)]
        } else {
            next = delta > 0 ? order[0] : order[order.count - 1]
        }
        if selectedTaskID == nil {
            withAnimation(Motion.sheet) { selectedTaskID = next }
        } else {
            selectedTaskID = next
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
            }
        }
    }
}
