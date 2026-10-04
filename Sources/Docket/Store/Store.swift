import Foundation
import SwiftUI

/// Single source of truth for tasks, notes, lists and focus sessions.
/// Every mutation schedules a debounced save to disk.
@MainActor
final class Store: ObservableObject {
    @Published private(set) var tasks: [TaskItem] = []
    @Published private(set) var notes: [Note] = []
    @Published private(set) var lists: [TaskList] = []
    @Published private(set) var sessions: [FocusSession] = []
    /// Shown once in the main window when data had to be recovered from a backup.
    @Published var loadMessage: String?

    let persistence: Persistence
    weak var undoManager: UndoManager?
    private(set) var isFirstLaunch = false
    private var saveWork: DispatchWorkItem?
    private let writeQueue = DispatchQueue(label: "docket.save", qos: .utility)
    var calendar = Calendar.current

    init(persistence: Persistence = Persistence(directory: Persistence.defaultDirectory), seedIfEmpty: Bool = true) {
        self.persistence = persistence
        switch persistence.load() {
        case .fresh:
            isFirstLaunch = true
            if seedIfEmpty { seed() }
            saveNow()
        case .loaded(let db):
            apply(db)
        case .recovered(let db, let message):
            if let db { apply(db) }
            loadMessage = message
            saveNow()
        }
        pruneOldSnoozes()
    }

    // MARK: - Persistence

    var database: Database {
        var db = Database()
        db.tasks = tasks
        db.notes = notes
        db.lists = lists
        db.sessions = sessions
        return db
    }

    func apply(_ db: Database) {
        tasks = db.tasks
        notes = db.notes
        lists = db.lists.sorted { $0.sortOrder < $1.sortOrder }
        sessions = db.sessions
    }

    private func changed() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save(synchronously: false) }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Flushes pending changes immediately (used on quit).
    func saveNow() { save(synchronously: true) }

    private func save(synchronously: Bool) {
        saveWork?.cancel()
        saveWork = nil
        let db = database
        let persistence = persistence
        let job: @Sendable () -> Void = {
            do { try persistence.save(db) } catch { NSLog("Docket: save failed: \(error)") }
        }
        // Serial queue: writes land in order even when async.
        if synchronously { writeQueue.sync(execute: job) } else { writeQueue.async(execute: job) }
    }

    // MARK: - Undo

    private struct Snapshot {
        var tasks: [TaskItem], notes: [Note], lists: [TaskList], sessions: [FocusSession]
    }

    private func snapshot() -> Snapshot { Snapshot(tasks: tasks, notes: notes, lists: lists, sessions: sessions) }

    private func restore(_ s: Snapshot) {
        tasks = s.tasks
        notes = s.notes
        lists = s.lists
        sessions = s.sessions
        changed()
    }

    private func registerUndo(back to: Snapshot, name: String) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { store in
            // Snapshot as the step is undone, so Redo also brings back later edits that had no undo step.
            let live = store.snapshot()
            store.restore(to)
            store.registerUndo(back: live, name: name)
        }
        undoManager.setActionName(name)
    }

    /// Runs `body` as a single undoable step.
    func undoable(_ name: String, _ body: () -> Void) {
        let before = snapshot()
        body()
        registerUndo(back: before, name: name)
    }

    // MARK: - Tasks

    func task(_ id: UUID?) -> TaskItem? {
        guard let id else { return nil }
        return tasks.first { $0.id == id }
    }

    func list(_ id: UUID?) -> TaskList? {
        guard let id else { return nil }
        return lists.first { $0.id == id }
    }

    @discardableResult
    func addTask(_ task: TaskItem) -> TaskItem {
        var t = task
        t.createdAt = Date()
        t.updatedAt = Date()
        undoable("New Task") { tasks.append(t) }
        changed()
        return t
    }

    func updateTask(_ task: TaskItem) {
        guard let i = tasks.firstIndex(where: { $0.id == task.id }), tasks[i] != task else { return }
        var t = task
        t.updatedAt = Date()
        dropRankIfDayChanged(from: tasks[i], to: &t)
        tasks[i] = t
        changed()
    }

    func mutateTask(_ id: UUID, undo name: String? = nil, _ body: (inout TaskItem) -> Void) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        var t = tasks[i]
        body(&t)
        guard t != tasks[i] else { return }
        t.updatedAt = Date()
        dropRankIfDayChanged(from: tasks[i], to: &t)
        if let name {
            undoable(name) { tasks[i] = t }
        } else {
            tasks[i] = t
        }
        changed()
    }

    /// Writes manual positions for a day's tasks as one undoable step.
    func setRanks(_ positions: [UUID: Double], undo name: String) {
        undoable(name) {
            for (id, rank) in positions {
                guard let i = tasks.firstIndex(where: { $0.id == id }) else { continue }
                tasks[i].rank = rank
            }
        }
        changed()
    }

    /// A manual rank is a position on one day; after a move the task falls back to priority order.
    private func dropRankIfDayChanged(from old: TaskItem, to new: inout TaskItem) {
        guard new.rank != nil else { return }
        let today = calendar.startOfDay(for: Date())
        if calendarDay(of: old, today: today) != calendarDay(of: new, today: today)
            || isOverdueByDay(old, today: today) != isOverdueByDay(new, today: today) {
            new.rank = nil
        }
    }

    func binding(forTask id: UUID) -> Binding<TaskItem> {
        Binding(
            get: { [weak self] in self?.task(id) ?? TaskItem(title: "") },
            set: { [weak self] in self?.updateTask($0) }
        )
    }

    func deleteTasks(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        undoable(ids.count == 1 ? "Delete Task" : "Delete Tasks") {
            tasks.removeAll { ids.contains($0.id) }
        }
        changed()
    }

    func duplicateTask(_ id: UUID) -> TaskItem? {
        guard var copy = task(id) else { return nil }
        copy.id = UUID()
        copy.completedAt = nil
        copy.trackedSeconds = 0
        copy.reminders = copy.reminders.filter { !$0.isSnooze }.map { var r = $0; r.id = UUID(); return r }
        copy.linkedNoteID = nil
        copy.noteLine = nil
        return addTask(copy)
    }

    /// Completes or reopens a task. For repeating tasks a completed copy is logged
    /// and the task itself moves to its next occurrence, which is returned.
    @discardableResult
    func setCompleted(_ id: UUID, _ done: Bool) -> Date? {
        var next: Date?
        undoable(done ? "Complete Task" : "Reopen Task") {
            next = applyCompletion(id, done, syncNote: true)
        }
        changed()
        return next
    }

    @discardableResult
    func toggleCompleted(_ id: UUID) -> Date? {
        guard let t = task(id) else { return nil }
        return setCompleted(id, !t.isCompleted)
    }

    private func applyCompletion(_ id: UUID, _ done: Bool, syncNote: Bool) -> Date? {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return nil }
        var t = tasks[i]
        guard t.isCompleted != done else { return nil }
        let now = Date()

        if done, let rule = t.recurrence {
            var record = t
            record.id = UUID()
            record.completedAt = now
            record.recurrence = nil
            record.reminders = []
            record.noteLine = nil
            record.updatedAt = now
            tasks.append(record)

            let base = t.dueDate ?? calendar.startOfDay(for: now)
            let hasTime = t.dueDate != nil && t.dueHasTime
            let next = rule.nextOccurrence(after: base, hasTime: hasTime, now: now, calendar: calendar)
            let delta = next.timeIntervalSince(base)
            t.dueDate = next
            t.dueHasTime = hasTime
            t.scheduledDate = nil
            t.trackedSeconds = 0
            t.rank = nil
            t.subtasks = t.subtasks.map { var s = $0; s.done = false; return s }
            t.reminders = t.reminders.filter { !$0.isSnooze }.map { r in
                guard case .absolute(let d) = r.trigger else { return r }
                var r = r
                r.trigger = .absolute(d.addingTimeInterval(delta))
                return r
            }
            t.updatedAt = now
            tasks[i] = t
            return next
        }

        t.completedAt = done ? now : nil
        if done { t.reminders.removeAll { $0.isSnooze } }
        t.updatedAt = now
        tasks[i] = t

        if syncNote, let noteID = t.linkedNoteID, let line = t.noteLine,
           let ni = notes.firstIndex(where: { $0.id == noteID }),
           let body = NoteChecklist.setChecked(done, text: line, in: notes[ni].body) {
            notes[ni].body = body
            notes[ni].updatedAt = now
        }
        return nil
    }

    func snooze(_ id: UUID, minutes: Int, isAlarm: Bool) {
        let fire = Date().addingTimeInterval(Double(minutes) * 60)
        mutateTask(id) { t in
            t.reminders.removeAll { r in
                guard r.isSnooze, case .absolute(let d) = r.trigger else { return false }
                return d < Date()
            }
            t.reminders.append(Reminder(trigger: .absolute(fire), isAlarm: isAlarm, isSnooze: true))
        }
    }

    /// Moves the deadline to `day`, keeping the time of day. `nil` clears it.
    func setDueDay(_ id: UUID, _ day: Date?) {
        mutateTask(id, undo: "Reschedule") { t in
            guard let day else {
                t.dueDate = nil
                t.dueHasTime = false
                return
            }
            if t.dueHasTime, let old = t.dueDate {
                let time = calendar.dateComponents([.hour, .minute], from: old)
                t.dueDate = calendar.date(bySettingHour: time.hour ?? 9, minute: time.minute ?? 0, second: 0, of: day)
            } else {
                t.dueDate = calendar.startOfDay(for: day)
            }
        }
    }

    func setScheduled(_ id: UUID, _ day: Date?) {
        mutateTask(id, undo: day == nil ? "Remove from Today" : "Plan") { t in
            t.scheduledDate = day.map { calendar.startOfDay(for: $0) }
        }
    }

    /// "Tomorrow" from a notification: moves whichever date the task uses.
    func pushToTomorrow(_ id: UUID) {
        guard let t = task(id) else { return }
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date()))!
        if t.dueDate != nil { setDueDay(id, tomorrow) } else { setScheduled(id, tomorrow) }
    }

    private func pruneOldSnoozes() {
        let cutoff = Date().addingTimeInterval(-86_400)
        var dirty = false
        for i in tasks.indices {
            let before = tasks[i].reminders.count
            tasks[i].reminders.removeAll { r in
                guard r.isSnooze, case .absolute(let d) = r.trigger else { return false }
                return d < cutoff
            }
            if tasks[i].reminders.count != before { dirty = true }
        }
        if dirty { changed() }
    }

    // MARK: - Focus sessions

    func logFocus(taskID: UUID?, start: Date, seconds: Int) {
        guard seconds >= 30 else { return }
        sessions.append(FocusSession(taskID: taskID, start: start, seconds: seconds))
        if let taskID, let i = tasks.firstIndex(where: { $0.id == taskID }) {
            tasks[i].trackedSeconds += seconds
        }
        changed()
    }

    // MARK: - Lists

    @discardableResult
    func addList(name: String, color: ListColor, icon: String = "list.bullet") -> TaskList {
        let list = TaskList(name: name, color: color, icon: icon, sortOrder: (lists.map(\.sortOrder).max() ?? 0) + 1)
        undoable("New List") { lists.append(list) }
        changed()
        return list
    }

    func updateList(_ list: TaskList) {
        guard let i = lists.firstIndex(where: { $0.id == list.id }), lists[i] != list else { return }
        lists[i] = list
        changed()
    }

    func deleteList(_ id: UUID) {
        undoable("Delete List") {
            lists.removeAll { $0.id == id }
            for i in tasks.indices where tasks[i].listID == id { tasks[i].listID = nil }
        }
        changed()
    }

    func moveList(_ id: UUID, by offset: Int) {
        guard let i = lists.firstIndex(where: { $0.id == id }) else { return }
        let j = i + offset
        guard lists.indices.contains(j) else { return }
        lists.swapAt(i, j)
        for k in lists.indices { lists[k].sortOrder = k }
        changed()
    }

    // MARK: - Notes

    func note(_ id: UUID?) -> Note? {
        guard let id else { return nil }
        return notes.first { $0.id == id }
    }

    @discardableResult
    func addNote(body: String, dailyKey: String? = nil) -> Note {
        var note = Note(body: body)
        note.dailyKey = dailyKey
        undoable("New Note") { notes.append(note) }
        changed()
        return note
    }

    func updateNoteBody(_ id: UUID, _ body: String) {
        guard let i = notes.firstIndex(where: { $0.id == id }), notes[i].body != body else { return }
        notes[i].body = body
        notes[i].updatedAt = Date()

        // Ticking an extracted action item in the note completes its task (and vice versa).
        let lines = body.components(separatedBy: "\n")
        let checked = Set(lines.compactMap(NoteChecklist.checkedText))
        let open = Set(lines.compactMap(NoteChecklist.uncheckedText))
        for t in tasks where t.linkedNoteID == id {
            guard let line = t.noteLine else { continue }
            if !t.isCompleted, checked.contains(line), !open.contains(line) {
                _ = applyCompletion(t.id, true, syncNote: false)
            } else if t.isCompleted, open.contains(line), !checked.contains(line) {
                _ = applyCompletion(t.id, false, syncNote: false)
            }
        }
        changed()
    }

    func setPinned(_ id: UUID, _ pinned: Bool) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[i].isPinned = pinned
        changed()
    }

    func deleteNote(_ id: UUID) {
        undoable("Delete Note") {
            notes.removeAll { $0.id == id }
            for i in tasks.indices where tasks[i].linkedNoteID == id {
                tasks[i].linkedNoteID = nil
                tasks[i].noteLine = nil
            }
        }
        changed()
    }

    func dailyNote(for date: Date = Date()) -> Note {
        let key = Fmt.dayKey(date)
        if let existing = notes.first(where: { $0.dailyKey == key }) { return existing }
        return addNote(body: NoteTemplate.daily.body(for: date), dailyKey: key)
    }

    func linkedTasks(forNote id: UUID) -> [TaskItem] {
        tasks.filter { $0.linkedNoteID == id && $0.noteLine != nil }
    }

    /// Turns every open "- [ ] item" line into a task (dates, estimates and #lists in the line are parsed).
    /// Lines already linked to a task are skipped. Returns the number of tasks created.
    @discardableResult
    func extractActionItems(fromNote id: UUID, parser: QuickParser) -> Int {
        guard let note = note(id) else { return 0 }
        let existing = Set(linkedTasks(forNote: id).compactMap(\.noteLine))
        var created: [TaskItem] = []
        for line in note.body.components(separatedBy: "\n") {
            guard let text = NoteChecklist.uncheckedText(line), !existing.contains(text),
                  !created.contains(where: { $0.noteLine == text }) else { continue }
            var t = TaskItem(parsed: parser.parse(text), defaultReminder: Prefs.defaultReminder, defaultIsAlarm: Prefs.defaultReminderIsAlarm)
            t.linkedNoteID = id
            t.noteLine = text
            t.notes = "From note: \(note.title)"
            created.append(t)
        }
        guard !created.isEmpty else { return 0 }
        undoable("Extract Action Items") { tasks.append(contentsOf: created) }
        changed()
        return created.count
    }

    /// Creates a task from arbitrary text (e.g. a selection in a note) and links it to the note.
    @discardableResult
    func createTask(fromText text: String, note id: UUID?, parser: QuickParser) -> TaskItem {
        var t = TaskItem(parsed: parser.parse(text), defaultReminder: Prefs.defaultReminder, defaultIsAlarm: Prefs.defaultReminderIsAlarm)
        if let id, let note = note(id) {
            t.linkedNoteID = id
            t.notes = "From note: \(note.title)"
        }
        return addTask(t)
    }

    // MARK: - Import / export

    func exportData(to url: URL) throws {
        try Persistence.encoder.encode(database).write(to: url, options: .atomic)
    }

    /// Replace swaps in the file's contents; merge adds only items whose IDs aren't present yet.
    func importData(from url: URL, replace: Bool) throws -> Int {
        let db = try Persistence.decoder.decode(Database.self, from: Data(contentsOf: url))
        var added = 0
        undoable("Import") {
            if replace {
                apply(db)
                added = db.tasks.count + db.notes.count
            } else {
                let taskIDs = Set(tasks.map(\.id)), noteIDs = Set(notes.map(\.id))
                let listIDs = Set(lists.map(\.id)), sessionIDs = Set(sessions.map(\.id))
                let newTasks = db.tasks.filter { !taskIDs.contains($0.id) }
                let newNotes = db.notes.filter { !noteIDs.contains($0.id) }
                tasks += newTasks
                notes += newNotes
                lists += db.lists.filter { !listIDs.contains($0.id) }
                sessions += db.sessions.filter { !sessionIDs.contains($0.id) }
                added = newTasks.count + newNotes.count
            }
        }
        changed()
        return added
    }

    func exportNotesAsMarkdown(to folder: URL) throws -> Int {
        var used = Set<String>()
        for note in notes {
            var name = note.title.replacingOccurrences(of: "[/:\\\\?%*|\"<>]", with: "-", options: .regularExpression)
            name = String(name.prefix(80)).trimmingCharacters(in: .whitespaces)
            if name.isEmpty { name = "Note" }
            var candidate = name
            var n = 2
            while used.contains(candidate.lowercased()) { candidate = "\(name) \(n)"; n += 1 }
            used.insert(candidate.lowercased())
            try note.body.write(to: folder.appendingPathComponent(candidate + ".md"), atomically: true, encoding: .utf8)
        }
        MediaLibrary.copyReferencedMedia(for: notes.map(\.body), to: folder)
        return notes.count
    }
}

// MARK: - Building tasks from parsed input

extension TaskItem {
    init(parsed p: ParsedTask, defaultReminder: Int, defaultIsAlarm: Bool) {
        self.init(title: p.title)
        dueDate = p.dueDate
        dueHasTime = p.dueHasTime
        estimateMinutes = p.estimateMinutes
        priority = p.priority
        tags = p.tags
        listID = p.listID
        recurrence = p.recurrence
        if !p.reminders.isEmpty {
            reminders = p.reminders.map { Reminder(trigger: .beforeDue(minutes: $0.minutesBefore), isAlarm: $0.isAlarm) }
        } else if p.dueHasTime, defaultReminder >= 0 {
            reminders = [Reminder(trigger: .beforeDue(minutes: defaultReminder), isAlarm: defaultIsAlarm)]
        }
    }
}
