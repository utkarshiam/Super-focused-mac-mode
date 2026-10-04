import XCTest
@testable import Docket

@MainActor
final class StoreTests: XCTestCase {
    var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("docket-tests-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func makeStore() -> Store { Store(persistence: Persistence(directory: dir), seedIfEmpty: false) }

    func testRoundTripPersistence() {
        let store = makeStore()
        var t = TaskItem(title: "Persist me")
        t.estimateMinutes = 30
        t.reminders = [Reminder(trigger: .beforeDue(minutes: 10), isAlarm: true)]
        store.addTask(t)
        store.addNote(body: "# Hello")
        store.saveNow()

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.tasks.map(\.title), ["Persist me"])
        XCTAssertEqual(reloaded.tasks.first?.reminders.first?.isAlarm, true)
        XCTAssertEqual(reloaded.notes.first?.title, "Hello")
    }

    func testOldFilesWithMissingKeysStillLoad() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = #"{"tasks":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","title":"Legacy"}],"notes":[],"lists":[]}"#
        try json.data(using: .utf8)!.write(to: dir.appendingPathComponent("docket.json"))
        let store = makeStore()
        XCTAssertEqual(store.tasks.first?.title, "Legacy")
        XCTAssertNil(store.loadMessage)
    }

    func testCorruptFileIsKeptAndBackupRestored() throws {
        let store = makeStore()
        store.addTask(TaskItem(title: "Backed up"))
        store.saveNow()
        try "{ not json".data(using: .utf8)!.write(to: dir.appendingPathComponent("docket.json"))

        let recovered = makeStore()
        XCTAssertEqual(recovered.tasks.map(\.title), ["Backed up"])
        XCTAssertNotNil(recovered.loadMessage)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(files.contains { $0.hasPrefix("docket.unreadable-") })
    }

    func testCompletingRepeatingTaskLogsCopyAndAdvances() {
        let store = makeStore()
        let cal = Calendar.current
        var t = TaskItem(title: "Daily review")
        t.recurrence = .daily
        t.dueDate = cal.startOfDay(for: Date())
        t.subtasks = [Subtask(title: "a", done: true)]
        let added = store.addTask(t)

        let next = store.setCompleted(added.id, true)
        XCTAssertEqual(next, cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date())))
        XCTAssertEqual(store.tasks.count, 2)
        let original = store.task(added.id)!
        XCTAssertFalse(original.isCompleted)
        XCTAssertEqual(original.dueDate, next)
        XCTAssertFalse(original.subtasks[0].done)
        XCTAssertEqual(store.tasks.filter(\.isCompleted).count, 1)
    }

    func testNoteActionItemsSyncBothWays() {
        let store = makeStore()
        let note = store.addNote(body: "# Sync\n- [ ] Send deck tomorrow 30m\n- [x] Already done\n- [ ] Book venue")
        let created = store.extractActionItems(fromNote: note.id, parser: QuickParser())
        XCTAssertEqual(created, 2)
        XCTAssertEqual(store.extractActionItems(fromNote: note.id, parser: QuickParser()), 0, "no duplicates")

        let deck = store.tasks.first { $0.noteLine == "Send deck tomorrow 30m" }!
        XCTAssertEqual(deck.title, "Send deck")
        XCTAssertEqual(deck.estimateMinutes, 30)

        // Completing the task ticks the note.
        store.setCompleted(deck.id, true)
        XCTAssertTrue(store.note(note.id)!.body.contains("- [x] Send deck tomorrow 30m"))

        // Ticking in the note completes the task.
        let venue = store.tasks.first { $0.noteLine == "Book venue" }!
        store.updateNoteBody(note.id, store.note(note.id)!.body.replacingOccurrences(of: "- [ ] Book venue", with: "- [x] Book venue"))
        XCTAssertTrue(store.task(venue.id)!.isCompleted)
    }

    func testUndoDelete() {
        let store = makeStore()
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.undoManager = undo
        undo.beginUndoGrouping()
        let t = store.addTask(TaskItem(title: "Oops"))
        undo.endUndoGrouping()
        undo.beginUndoGrouping()
        store.deleteTasks([t.id])
        undo.endUndoGrouping()
        XCTAssertNil(store.task(t.id))
        undo.undo()
        XCTAssertNotNil(store.task(t.id))
    }

    func testTodaySections() {
        let store = makeStore()
        let cal = Calendar.current
        var overdue = TaskItem(title: "Late")
        overdue.dueDate = cal.date(byAdding: .day, value: -2, to: cal.startOfDay(for: Date()))
        var planned = TaskItem(title: "Planned")
        planned.scheduledDate = Date()
        var later = TaskItem(title: "Later")
        later.dueDate = cal.date(byAdding: .day, value: 3, to: Date())
        [overdue, planned, later].forEach { store.addTask($0) }

        let sections = store.sections(for: .calendar, keeping: [])
        XCTAssertEqual(sections.map(\.id), ["overdue", "today"])
        XCTAssertEqual(sections[0].tasks.map(\.title), ["Late"])
        XCTAssertEqual(sections[1].tasks.map(\.title), ["Planned"])

        // The agenda lists every day in range; "Later" sits on its day, overdue work above all days.
        let today = cal.startOfDay(for: Date())
        let agenda = store.agenda(from: today, to: cal.date(byAdding: .day, value: 6, to: today)!, events: { _ in [] }, keeping: [])
        XCTAssertEqual(agenda.overdue.map(\.title), ["Late"])
        XCTAssertEqual(agenda.days.count, 7)
        XCTAssertEqual(agenda.days[0].items.compactMap(\.task).map(\.title), ["Planned"])
        XCTAssertEqual(agenda.days[3].items.compactMap(\.task).map(\.title), ["Later"])
        XCTAssertTrue(agenda.later.isEmpty)
    }
}

@MainActor
final class CalendarAgendaTests: XCTestCase {
    var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("docket-agenda-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testDayOrderingUntimedThenTimedThenDone() {
        let store = Store(persistence: Persistence(directory: dir), seedIfEmpty: false)
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var late = TaskItem(title: "Afternoon call")
        late.dueDate = cal.date(bySettingHour: 16, minute: 0, second: 0, of: today)
        late.dueHasTime = true
        var early = TaskItem(title: "Morning call")
        early.dueDate = cal.date(bySettingHour: 0, minute: 30, second: 0, of: today)
        early.dueHasTime = true
        var anytime = TaskItem(title: "Anytime")
        anytime.scheduledDate = today
        var done = TaskItem(title: "Done already")
        done.scheduledDate = today
        [late, early, anytime, done].forEach { store.addTask($0) }
        store.setCompleted(store.tasks.first { $0.title == "Done already" }!.id, true)

        let event = CalendarService.Event(id: "e1", title: "Standup", start: cal.date(bySettingHour: 10, minute: 0, second: 0, of: today)!,
                                          end: cal.date(bySettingHour: 10, minute: 15, second: 0, of: today)!, isAllDay: false, calendarName: "Work")
        let agenda = store.agenda(from: today, to: today, events: { _ in [event] }, keeping: [], now: today)
        let titles = agenda.days[0].items.map { item -> String in
            switch item {
            case .task(let t): t.title
            case .event(let e): e.title
            }
        }
        XCTAssertEqual(titles, ["Anytime", "Morning call", "Standup", "Afternoon call", "Done already"])
    }

    func testDroppingOnADayMovesDeadlineKeepingTime() {
        let store = Store(persistence: Persistence(directory: dir), seedIfEmpty: false)
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var t = TaskItem(title: "Board call")
        t.dueDate = cal.date(bySettingHour: 15, minute: 30, second: 0, of: today)
        t.dueHasTime = true
        t.scheduledDate = today
        let added = store.addTask(t)
        let friday = cal.date(byAdding: .day, value: 4, to: today)!
        store.move(added.id, toDay: friday)
        let moved = store.task(added.id)!
        XCTAssertTrue(cal.isDate(moved.dueDate!, inSameDayAs: friday))
        XCTAssertEqual(cal.component(.hour, from: moved.dueDate!), 15)
        XCTAssertEqual(cal.component(.minute, from: moved.dueDate!), 30)
        XCTAssertNil(moved.scheduledDate, "plan date cleared so the task follows its deadline")

        var loose = TaskItem(title: "No deadline")
        loose.scheduledDate = today
        let l = store.addTask(loose)
        store.move(l.id, toDay: friday)
        XCTAssertEqual(store.task(l.id)!.scheduledDate, friday)
        XCTAssertNil(store.task(l.id)!.dueDate)
    }
}

@MainActor
final class DayOrderTests: XCTestCase {
    var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("docket-order-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func titles(_ store: Store, day: Date) -> [String] {
        store.agenda(from: day, to: day, events: { _ in [] }, keeping: [])
            .days[0].items.compactMap(\.task).filter { !$0.isCompleted }.map(\.title)
    }

    func testDragOrderBeatsPriorityAndSticks() {
        let store = Store(persistence: Persistence(directory: dir), seedIfEmpty: false)
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        func add(_ title: String, _ p: Priority) -> UUID {
            var t = TaskItem(title: title)
            t.scheduledDate = today
            t.priority = p
            return store.addTask(t).id
        }
        let low = add("Low", .low), high = add("High", .high), med = add("Medium", .medium)
        XCTAssertEqual(titles(store, day: today), ["High", "Medium", "Low"], "unranked tasks follow priority")

        // Drag "Low" above "High".
        store.placeInDay(low, before: high)
        XCTAssertEqual(titles(store, day: today), ["Low", "High", "Medium"])
        XCTAssertEqual(store.todayTasks().map(\.title), ["Low", "High", "Medium"], "menu bar list follows the same order")

        // ⌥⌘↓ on "Low", and nothing happens past the end.
        XCTAssertTrue(store.moveInDay(low, by: 1))
        XCTAssertEqual(titles(store, day: today), ["High", "Low", "Medium"])
        XCTAssertTrue(store.moveInDay(low, by: 1))
        XCTAssertFalse(store.moveInDay(low, by: 1))

        // The order survives a reload.
        store.saveNow()
        let reloaded = Store(persistence: Persistence(directory: dir), seedIfEmpty: false)
        XCTAssertEqual(titles(reloaded, day: today), ["High", "Medium", "Low"])

        // Moving to another day drops the manual rank there; the rest keep theirs.
        let tomorrow = cal.date(byAdding: .day, value: 1, to: today)!
        store.move(med, toDay: tomorrow)
        XCTAssertNil(store.task(med)!.rank)
        XCTAssertEqual(titles(store, day: today), ["High", "Low"])
    }

    func testTimedTasksKeepTimeOrderAndCannotBeRanked() {
        let store = Store(persistence: Persistence(directory: dir), seedIfEmpty: false)
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var timed = TaskItem(title: "Call at 23:00")
        timed.dueDate = cal.date(bySettingHour: 23, minute: 0, second: 0, of: today)
        timed.dueHasTime = true
        let t = store.addTask(timed)
        var anytime = TaskItem(title: "Anytime")
        anytime.scheduledDate = today
        store.addTask(anytime)
        XCTAssertNil(store.dayList(containing: t.id))
        XCTAssertFalse(store.moveInDay(t.id, by: -1))
        XCTAssertEqual(titles(store, day: today), ["Anytime", "Call at 23:00"])
    }

    func testDraggingOnlyReordersWithinADateAndNeverChangesIt() {
        let store = Store(persistence: Persistence(directory: dir), seedIfEmpty: false)
        let cal = Calendar.current
        let now = cal.date(bySettingHour: 9, minute: 0, second: 0, of: Date())!
        let today = cal.startOfDay(for: now)
        let tomorrow = cal.date(byAdding: .day, value: 1, to: today)!
        func add(_ title: String, planned: Date? = nil, due: Date? = nil, timed: Bool = false) -> UUID {
            var t = TaskItem(title: title)
            t.scheduledDate = planned
            t.dueDate = due
            t.dueHasTime = timed
            return store.addTask(t).id
        }
        let a = add("A", planned: today), b = add("B", planned: today)
        let c = add("C", planned: tomorrow)
        let call = add("Call", due: cal.date(bySettingHour: 23, minute: 0, second: 0, of: today), timed: true)
        let late1 = add("Late 1", due: cal.date(byAdding: .day, value: -2, to: today))
        let late2 = add("Late 2", due: cal.date(byAdding: .day, value: -1, to: today))
        let dates = { Dictionary(uniqueKeysWithValues: store.tasks.map { ($0.id, [$0.dueDate, $0.scheduledDate]) }) }
        let before = dates()

        // Same date: lands above the target. Onto a timed task of that date: end of the untimed run.
        XCTAssertEqual(store.reorderSlot(b, above: a, now: now), .some(a))
        XCTAssertEqual(store.reorderSlot(a, above: call, now: now), .some(nil))
        XCTAssertEqual(store.reorderSlot(late2, above: late1, now: now), .some(late1))
        // Another date, a timed task, or across the overdue group: refused.
        XCTAssertNil(store.reorderSlot(c, above: a, now: now))
        XCTAssertNil(store.reorderSlot(a, above: c, now: now))
        XCTAssertNil(store.reorderSlot(call, above: a, now: now))
        XCTAssertNil(store.reorderSlot(late1, above: a, now: now))
        XCTAssertNil(store.reorderSlot(a, above: late1, now: now))

        // The allowed drops reorder and leave every date alone.
        store.placeInDay(b, before: a, now: now)
        store.placeInDay(late2, before: late1, now: now)
        XCTAssertEqual(titles(store, day: today), ["B", "A", "Call"])
        XCTAssertEqual(dates(), before)
    }
}

@MainActor
final class TimelineTests: XCTestCase {
    func testFlatListIsOverdueThenByDateWithoutFinishedTasks() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("docket-timeline-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = Store(persistence: Persistence(directory: dir), seedIfEmpty: false)
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        func add(_ title: String, due offset: Int?, planned: Int? = nil) -> TaskItem {
            var t = TaskItem(title: title)
            t.dueDate = offset.map { cal.date(byAdding: .day, value: $0, to: today)! }
            t.scheduledDate = planned.map { cal.date(byAdding: .day, value: $0, to: today)! }
            return store.addTask(t)
        }
        _ = add("In 40 days", due: 40)
        _ = add("Late", due: -3)
        _ = add("Tomorrow-ish", due: 1)
        _ = add("Planned today", due: nil, planned: 0)
        _ = add("No date", due: nil)
        let done = add("Finished", due: 2)
        store.setCompleted(done.id, true)

        let entries = store.timeline(keeping: [])
        XCTAssertEqual(entries.compactMap { $0.item.task?.title }, ["Late", "Planned today", "Tomorrow-ish", "In 40 days"])
        XCTAssertNil(entries[0].day, "overdue lines have no list date")
        XCTAssertEqual(entries[3].day, cal.date(byAdding: .day, value: 40, to: today), "far-off tasks are included, not cut at a horizon")
        // A task just ticked stays in place for a moment.
        XCTAssertTrue(store.timeline(keeping: [done.id]).contains { $0.item.task?.id == done.id })
    }
}
