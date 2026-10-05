import AppKit
import Combine
import SwiftUI
import XCTest
@testable import Docket

/// Bulk edits on the store: each is one undo step, changes only what needs changing, and keeps the
/// rules of the single-task versions (deadlines keep their time, repeats roll forward).
@MainActor
final class BulkActionsTests: XCTestCase {
    var dir: URL!
    var undo: UndoManager!
    let cal = Calendar.current

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("docket-bulk-\(UUID().uuidString)")
        undo = UndoManager()
        undo.groupsByEvent = false
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var today: Date { cal.startOfDay(for: Date()) }
    private func day(_ offset: Int) -> Date { cal.date(byAdding: .day, value: offset, to: today)! }
    private func at(_ hour: Int, _ minute: Int = 0, on date: Date) -> Date {
        cal.date(bySettingHour: hour, minute: minute, second: 0, of: date)!
    }

    private func task(_ title: String, due: Date? = nil, timed: Bool = false, planned: Date? = nil) -> TaskItem {
        var t = TaskItem(title: title)
        t.dueDate = due
        t.dueHasTime = timed
        t.scheduledDate = planned
        return t
    }

    /// A store holding `tasks` (plus whatever `extra` adds); undo starts recording after that.
    private func makeStore(_ tasks: [TaskItem], extra: (Store) -> Void = { _ in }) -> (Store, [UUID]) {
        let store = Store(persistence: Persistence(directory: dir), seedIfEmpty: false)
        extra(store)
        let ids = tasks.map { store.addTask($0).id }
        store.undoManager = undo
        return (store, ids)
    }

    /// One user action: the window's undo manager groups by event.
    private func step<T>(_ body: () -> T) -> T {
        undo.beginUndoGrouping()
        defer { undo.endUndoGrouping() }
        return body()
    }

    func testMovingSeveralTasksKeepsTimesAndIsOneUndoStep() {
        let (store, ids) = makeStore([
            task("Board call", due: at(15, 30, on: day(2)), timed: true, planned: day(1)),
            task("Read the deck", planned: day(3)),
            task("Send notes", due: day(5)),
        ])
        let before = store.tasks
        let friday = day(4)
        XCTAssertEqual(step { store.moveTasks(ids, toDay: friday) }, 3)

        let call = store.task(ids[0])!
        XCTAssertTrue(cal.isDate(call.dueDate!, inSameDayAs: friday))
        XCTAssertEqual(cal.component(.hour, from: call.dueDate!), 15)
        XCTAssertEqual(cal.component(.minute, from: call.dueDate!), 30)
        XCTAssertTrue(call.dueHasTime)
        XCTAssertNil(call.scheduledDate, "the plan date goes, so the task follows its deadline")
        XCTAssertEqual(store.task(ids[1])!.scheduledDate, friday)
        XCTAssertNil(store.task(ids[1])!.dueDate)
        XCTAssertEqual(store.task(ids[2])!.dueDate, friday)
        XCTAssertEqual(undo.undoActionName, "Reschedule")

        // One ⌘Z puts all three back with a single restore: the steps setDueDay/setScheduled record are folded in.
        var changes = 0
        let watch = store.objectWillChange.sink { changes += 1 }
        undo.undo()
        watch.cancel()
        XCTAssertEqual(store.tasks, before)
        XCTAssertLessThanOrEqual(changes, 4, "one snapshot restore, not one per task")
        XCTAssertFalse(undo.canUndo)

        undo.redo()
        XCTAssertEqual(store.task(ids[1])!.scheduledDate, friday)
        XCTAssertEqual(store.task(ids[2])!.dueDate, friday)
        XCTAssertNil(store.task(ids[0])!.scheduledDate)
    }

    func testNothingToChangeRecordsNoUndoStep() {
        let (store, ids) = makeStore([task("Planned today", planned: today), task("Due today", due: today)])
        XCTAssertEqual(step { store.moveTasks(ids, toDay: today) }, 0)
        XCTAssertEqual(step { store.setPriority(.none, for: ids) }, 0)
        XCTAssertTrue(step { store.completeTasks(ids, done: false) }.isEmpty)
        XCTAssertEqual(step { store.clearDates(of: [UUID()]) }, 0, "unknown ids are skipped")
        XCTAssertFalse(undo.canUndo)

        // And the single-task methods record their own steps again afterwards.
        step { store.mutateTask(ids[0], undo: "Rename") { $0.title = "Renamed" } }
        XCTAssertEqual(undo.undoActionName, "Rename")
        undo.undo()
        XCTAssertEqual(store.task(ids[0])?.title, "Planned today")
    }

    func testClearingDatesRemovesPlanDateDeadlineAndTime() {
        let (store, ids) = makeStore([
            task("Timed", due: at(10, on: day(1)), timed: true, planned: today),
            task("Planned", planned: day(2)),
            task("Loose"),
        ])
        XCTAssertEqual(step { store.clearDates(of: ids) }, 2, "the one without dates doesn't count")
        for id in ids {
            let t = store.task(id)!
            XCTAssertNil(t.dueDate)
            XCTAssertNil(t.scheduledDate)
            XCTAssertFalse(t.dueHasTime)
        }
        XCTAssertEqual(undo.undoActionName, "Remove Dates")
        undo.undo()
        XCTAssertTrue(store.task(ids[0])!.dueHasTime)
        XCTAssertEqual(store.task(ids[1])!.scheduledDate, day(2))
    }

    func testDoTodayAndMoveToTomorrowOnSeveralTasks() {
        let (store, ids) = makeStore([task("Deadline", due: day(3)), task("Planned", planned: day(2)), task("Nothing yet")])
        XCTAssertEqual(step { store.planTasks(ids, on: Date()) }, 3)
        XCTAssertEqual(store.task(ids[0])!.dueDate, day(3), "Do Today leaves deadlines alone")
        XCTAssertTrue(ids.allSatisfy { store.task($0)!.scheduledDate == today })
        undo.undo()

        XCTAssertEqual(step { store.pushTasksToTomorrow(ids) }, 3)
        XCTAssertEqual(store.task(ids[0])!.dueDate, day(1), "the deadline moves when there is one")
        XCTAssertEqual(store.task(ids[1])!.scheduledDate, day(1))
        XCTAssertEqual(store.task(ids[2])!.scheduledDate, day(1))
        XCTAssertEqual(undo.undoActionName, "Move to Tomorrow")
    }

    func testCompletingSeveralTasksIsOneStepAndRepeatsRollForward() {
        var daily = task("Standup notes", due: today)
        daily.recurrence = .daily
        var finished = task("Done already")
        finished.completedAt = Date()
        let (store, ids) = makeStore([task("Send deck"), daily, finished])

        let changed = step { store.completeTasks(ids, done: true) }
        XCTAssertEqual(changed.map { $0.id }, [ids[0], ids[1]], "a task that's already done is left alone")
        XCTAssertNil(changed[0].next)
        XCTAssertEqual(changed[1].next, day(1))
        XCTAssertTrue(store.task(ids[0])!.isCompleted)
        XCTAssertFalse(store.task(ids[1])!.isCompleted, "a repeating task moves to its next date instead")
        XCTAssertEqual(store.task(ids[1])!.dueDate, day(1))
        XCTAssertEqual(store.tasks.count, 4, "plus the logged copy of the repeat")
        XCTAssertEqual(undo.undoActionName, "Complete Tasks")

        undo.undo()
        XCTAssertEqual(store.tasks.count, 3)
        XCTAssertFalse(store.task(ids[0])!.isCompleted)
        XCTAssertEqual(store.task(ids[1])!.dueDate, today)

        XCTAssertEqual(step { store.completeTasks(ids, done: false) }.map { $0.id }, [ids[2]], "reopening touches only done tasks")
        XCTAssertEqual(undo.undoActionName, "Reopen Tasks")
    }

    func testPriorityListEstimateAndWaitingOnApplyToAllAsOneStepEach() {
        var listID: UUID?
        var high = task("Agenda")
        high.priority = .high
        let (store, ids) = makeStore([high, task("Budget"), task("Hiring plan")]) { store in
            listID = store.addList(name: "Board", color: .blue).id
        }

        XCTAssertEqual(step { store.setPriority(.urgent, for: ids) }, 3)
        XCTAssertEqual(step { store.setPriority(.urgent, for: ids) }, 0)
        XCTAssertEqual(step { store.setList(listID, for: ids) }, 3)
        XCTAssertEqual(step { store.setEstimate(45, for: ids) }, 3)
        XCTAssertEqual(step { store.setWaitingOn("  Sam Lee ", for: ids) }, 3)
        for id in ids {
            let t = store.task(id)!
            XCTAssertEqual(t.priority, .urgent)
            XCTAssertEqual(t.listID, listID)
            XCTAssertEqual(t.estimateMinutes, 45)
            XCTAssertEqual(t.waitingOn, "Sam Lee", "names are trimmed")
        }
        XCTAssertEqual(store.sections(for: .waiting, keeping: []).first?.tasks.count, 3)

        XCTAssertEqual(step { store.setWaitingOn("   ", for: ids) }, 3, "a blank name clears it")
        XCTAssertTrue(ids.allSatisfy { store.task($0)!.waitingOn == nil })

        // Each change undoes on its own, newest first.
        undo.undo()
        XCTAssertTrue(ids.allSatisfy { store.task($0)!.waitingOn == "Sam Lee" })
        undo.undo()
        XCTAssertTrue(ids.allSatisfy { store.task($0)!.waitingOn == nil })
        undo.undo()
        XCTAssertTrue(ids.allSatisfy { store.task($0)!.estimateMinutes == nil })
        undo.undo()
        XCTAssertTrue(ids.allSatisfy { store.task($0)!.listID == nil })
        undo.undo()
        XCTAssertEqual(ids.map { store.task($0)!.priority }, [.high, .none, .none])
        XCTAssertFalse(undo.canUndo)
    }

    func testTagsAreAddedOnceInAnyCapitalisationAndRemovedEverywhere() {
        var tagged = task("Agenda")
        tagged.tags = ["Board"]
        var other = task("Forecast")
        other.tags = ["q3"]
        let (store, ids) = makeStore([tagged, task("Budget"), other])

        XCTAssertEqual(step { store.addTag("#board", to: ids) }, 2, "“Board” already counts")
        XCTAssertEqual(store.task(ids[0])!.tags, ["Board"])
        XCTAssertEqual(store.task(ids[1])!.tags, ["board"])
        XCTAssertEqual(store.task(ids[2])!.tags, ["q3", "board"])
        XCTAssertEqual(step { store.addTag("  #Board prep ", to: [ids[1]]) }, 1)
        XCTAssertEqual(store.task(ids[1])!.tags, ["board", "Board-prep"])
        XCTAssertEqual(step { store.addTag(" # ", to: ids) }, 0)

        XCTAssertEqual(step { store.removeTag("BOARD", from: ids) }, 3)
        XCTAssertEqual(ids.map { store.task($0)!.tags }, [[], ["Board-prep"], ["q3"]])
        XCTAssertEqual(undo.undoActionName, "Remove Tag")
        undo.undo()
        XCTAssertEqual(store.task(ids[0])!.tags, ["Board"])

        XCTAssertEqual(Store.tagName("##q3  plan "), "q3-plan")
        XCTAssertNil(Store.tagName(" # "))
        XCTAssertEqual(Store.personName("  Priya \n"), "Priya")
        XCTAssertNil(Store.personName(" "))
    }

    func testChecklistMarkdownUsesRealDatesInTheGivenOrder() {
        let call = at(15, on: day(4))
        var timed = task("Board prep", due: call, timed: true)
        timed.estimateMinutes = 90
        var planned = task("Read the deck", planned: day(1))
        planned.estimateMinutes = 30
        var done = task("Send invoice", due: day(1))
        done.completedAt = Date()
        done.estimateMinutes = 15
        let (store, ids) = makeStore([timed, planned, task("Call Northwind"), done, task("Line one\nline two ")])

        let markdown = store.checklistMarkdown(for: [ids[1], ids[0], ids[2], ids[3], UUID(), ids[1], ids[4]])
        XCTAssertEqual(markdown.components(separatedBy: "\n"), [
            "- [ ] Read the deck — \(Fmt.absoluteDay(day(1))) · 30m",
            "- [ ] Board prep — \(Fmt.due(call, hasTime: true)) · 1h 30m",
            "- [ ] Call Northwind",
            "- [x] Send invoice",
            "- [ ] Line one line two",
        ])
        XCTAssertEqual(store.checklistMarkdown(for: []), "")
    }

    func testQuickDays() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        func date(_ day: Int, hour: Int = 0) -> Date { utc.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))! }

        // Thursday 8 Oct 2026, mid-morning.
        let thursday = date(8, hour: 10)
        XCTAssertEqual(QuickDay.today.date(now: thursday, calendar: utc), date(8))
        XCTAssertEqual(QuickDay.tomorrow.date(now: thursday, calendar: utc), date(9))
        XCTAssertEqual(QuickDay.nextWeek.date(now: thursday, calendar: utc), date(12), "the coming Monday")
        // On a Monday, next week is seven days on; on a Sunday it's the next day.
        XCTAssertEqual(QuickDay.nextWeek.date(now: date(12, hour: 9), calendar: utc), date(19))
        XCTAssertEqual(QuickDay.nextWeek.date(now: date(11, hour: 21), calendar: utc), date(12))
        XCTAssertEqual(QuickDay.allCases.map(\.key), ["T", "M", "W"])
    }
}

/// Picking tasks in a list: plain, ⌘ and ⇧ clicks, ⇧-arrows, ⌘A, Esc and Return, and where the cursor
/// goes after keyboard triage.
@MainActor
final class TaskSelectionTests: XCTestCase {
    var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("docket-selection-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// The Inbox with tasks due on consecutive days, so the list reads in the order given.
    private func makeInbox(_ titles: [String] = ["A", "B", "C", "D", "E"]) -> (Store, AppState, [UUID]) {
        let store = Store(persistence: Persistence(directory: dir), seedIfEmpty: false)
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let ids = titles.enumerated().map { i, title in
            var t = TaskItem(title: title)
            t.dueDate = cal.date(byAdding: .day, value: i + 1, to: today)
            return store.addTask(t).id
        }
        let app = AppState()
        app.selection = .inbox
        XCTAssertEqual(app.visibleTaskOrder(in: store), ids)
        return (store, app, ids)
    }

    func testCommandClickAddsAndRemovesTasks() {
        let (store, app, ids) = makeInbox()
        app.click(ids[1], .plain, in: store)
        XCTAssertEqual(app.selectedTaskID, ids[1])
        XCTAssertFalse(app.isMultiSelecting)

        app.click(ids[3], .toggle, in: store)
        XCTAssertEqual(app.selectedTaskIDs, [ids[1], ids[3]], "the open task stays selected too")
        XCTAssertEqual(app.selectedTaskID, ids[3])
        XCTAssertTrue(app.isSelected(ids[1]))
        XCTAssertFalse(app.isSelected(ids[2]))

        app.click(ids[4], .toggle, in: store)
        app.click(ids[4], .toggle, in: store)
        XCTAssertEqual(app.selectedTaskIDs, [ids[1], ids[3]])
        XCTAssertEqual(app.selectedTaskID, ids[3], "focus goes to the nearest selected task")

        app.click(ids[3], .toggle, in: store)
        XCTAssertTrue(app.selectedTaskIDs.isEmpty, "down to one task: its details again")
        XCTAssertEqual(app.selectedTaskID, ids[1])
        app.click(ids[1], .toggle, in: store)
        XCTAssertNil(app.selectedTaskID)
    }

    func testPlainClickCollapsesAndDoubleClickNeverCloses() {
        let (store, app, ids) = makeInbox()
        app.click(ids[0], .plain, in: store)
        app.click(ids[2], .toggle, in: store)
        app.click(ids[2], .plain, in: store)
        XCTAssertTrue(app.selectedTaskIDs.isEmpty)
        XCTAssertEqual(app.selectedTaskID, ids[2])

        app.click(ids[2], .plain, in: store)
        XCTAssertNil(app.selectedTaskID, "clicking the open task again closes it")
        app.click(ids[2], .open, in: store)
        app.click(ids[2], .open, in: store)
        XCTAssertEqual(app.selectedTaskID, ids[2])
    }

    func testShiftClickSelectsTheRangeFromTheAnchor() {
        let (store, app, ids) = makeInbox()
        app.click(ids[1], .plain, in: store)
        app.click(ids[3], .range, in: store)
        XCTAssertEqual(app.selectedTaskIDs, Set(ids[1...3]))
        XCTAssertEqual(app.selectedTaskID, ids[3])

        app.click(ids[0], .range, in: store)
        XCTAssertEqual(app.selectedTaskIDs, Set(ids[0...1]), "the range starts from the same anchor")

        app.deselectAll()
        app.click(ids[4], .range, in: store)
        XCTAssertEqual(app.selectedTaskID, ids[4], "with nothing selected it's a plain click")
        XCTAssertTrue(app.selectedTaskIDs.isEmpty)
    }

    func testShiftArrowsGrowAndShrinkFromTheAnchor() {
        let (store, app, ids) = makeInbox()
        app.click(ids[2], .plain, in: store)
        app.extendSelection(by: 1, in: store)
        app.extendSelection(by: 1, in: store)
        XCTAssertEqual(app.selectedTaskIDs, Set(ids[2...4]))
        app.extendSelection(by: 1, in: store)
        XCTAssertEqual(app.selectedTaskIDs, Set(ids[2...4]), "stops at the end of the list")
        XCTAssertEqual(app.selectedTaskID, ids[4])

        app.extendSelection(by: -1, in: store)
        app.extendSelection(by: -1, in: store)
        XCTAssertTrue(app.selectedTaskIDs.isEmpty, "back at the anchor")
        XCTAssertEqual(app.selectedTaskID, ids[2])
        app.extendSelection(by: -1, in: store)
        XCTAssertEqual(app.selectedTaskIDs, Set(ids[1...2]))

        // A plain arrow collapses to one task.
        app.moveSelection(by: 1, in: store)
        XCTAssertTrue(app.selectedTaskIDs.isEmpty)
        XCTAssertEqual(app.selectedTaskID, ids[2])
    }

    func testSelectAllTakesTheOpenTasksInView() {
        let (store, app, ids) = makeInbox(["A", "B", "C"])
        store.setCompleted(ids[1], true)
        app.markRecentlyCompleted(ids[1])
        XCTAssertTrue(app.visibleTaskOrder(in: store).contains(ids[1]), "just ticked, still on screen")
        XCTAssertTrue(app.selectAllVisible(in: store))
        XCTAssertEqual(app.selectedTaskIDs, [ids[0], ids[2]])
        XCTAssertEqual(app.selectedTaskID, ids[0])

        // Completed lists finished tasks, so ⌘A there takes all of them.
        store.setCompleted(ids[0], true)
        app.selection = .completed
        XCTAssertTrue(app.selectAllVisible(in: store))
        XCTAssertEqual(app.selectedTaskIDs, [ids[0], ids[1]])

        app.selection = .important
        XCTAssertFalse(app.selectAllVisible(in: store), "nothing to select")
    }

    func testEscDropsTheOthersAndReturnOpensAndCloses() {
        let (store, app, ids) = makeInbox()
        app.click(ids[0], .plain, in: store)
        app.click(ids[1], .toggle, in: store)
        XCTAssertTrue(app.collapseSelection())
        XCTAssertTrue(app.selectedTaskIDs.isEmpty)
        XCTAssertEqual(app.selectedTaskID, ids[1], "the focused task stays open")
        XCTAssertFalse(app.collapseSelection())

        XCTAssertTrue(app.toggleDetail(in: store))
        XCTAssertNil(app.selectedTaskID)
        XCTAssertTrue(app.toggleDetail(in: store))
        XCTAssertEqual(app.selectedTaskID, ids[1], "Return brings back the last task")

        app.click(ids[3], .toggle, in: store)
        XCTAssertTrue(app.toggleDetail(in: store))
        XCTAssertTrue(app.selectedTaskIDs.isEmpty)
        XCTAssertEqual(app.selectedTaskID, ids[3], "with several selected, Return opens the focused one")
    }

    func testActionsApplyToTheSelectionInListOrder() {
        let (store, app, ids) = makeInbox()
        XCTAssertTrue(app.actionTargets(in: store).isEmpty)
        app.click(ids[3], .plain, in: store)
        XCTAssertEqual(app.actionTargets(in: store), [ids[3]])
        app.click(ids[0], .toggle, in: store)
        app.click(ids[2], .toggle, in: store)
        XCTAssertEqual(app.actionTargets(in: store), [ids[0], ids[2], ids[3]])
    }

    func testDeletingTheSelectionMovesOnToTheNextTask() {
        let (store, app, ids) = makeInbox()
        app.click(ids[1], .plain, in: store)
        app.click(ids[2], .toggle, in: store)
        XCTAssertTrue(app.deleteSelection(in: store))
        XCTAssertNil(store.task(ids[1]))
        XCTAssertNil(store.task(ids[2]))
        XCTAssertTrue(app.selectedTaskIDs.isEmpty)
        XCTAssertEqual(app.selectedTaskID, ids[3])

        app.click(ids[4], .plain, in: store)
        XCTAssertTrue(app.deleteSelection(in: store))
        XCTAssertEqual(app.selectedTaskID, ids[3], "at the end of the list it steps back up")

        app.deselectAll()
        XCTAssertFalse(app.deleteSelection(in: store), "nothing selected, nothing deleted")
        XCTAssertEqual(store.tasks.count, 2)
    }

    func testMovingTheFocusedTaskAwayHandsTheCursorOn() {
        let (store, app, ids) = makeInbox()
        let today = Calendar.current.startOfDay(for: Date())

        // A is first and stays first when it moves to today: the cursor stays on it.
        app.click(ids[0], .plain, in: store)
        XCTAssertTrue(app.triage(.move(.today), in: store))
        XCTAssertEqual(store.task(ids[0])!.dueDate, today)
        XCTAssertEqual(app.selectedTaskID, ids[0])

        // C jumps up to sit after A, so the cursor goes on to D, the next task where C was.
        app.click(ids[2], .plain, in: store)
        XCTAssertTrue(app.triage(.move(.today), in: store))
        XCTAssertEqual(app.visibleTaskOrder(in: store), [ids[0], ids[2], ids[1], ids[3], ids[4]])
        XCTAssertEqual(app.selectedTaskID, ids[3])

        // Several selected: they all move and stay selected for the next change.
        app.click(ids[4], .toggle, in: store)
        XCTAssertTrue(app.triage(.move(.tomorrow), in: store))
        XCTAssertEqual(app.selectedTaskIDs, [ids[3], ids[4]])
        XCTAssertTrue([ids[3], ids[4]].allSatisfy { store.task($0)!.dueDate == QuickDay.tomorrow.date() })

        app.deselectAll()
        XCTAssertFalse(app.triage(.move(.today), in: store), "nothing selected")
    }

    func testSearchResultsUseTheOrderTheSearchViewReports() {
        let (store, app, ids) = makeInbox()
        app.selection = .search
        app.searchResultIDs = [ids[4], ids[2], UUID()]
        XCTAssertEqual(app.visibleTaskOrder(in: store), [ids[4], ids[2]], "ids that aren't tasks are skipped")
        XCTAssertTrue(app.moveSelection(by: 1, in: store))
        XCTAssertEqual(app.selectedTaskID, ids[4])
        app.extendSelection(by: 1, in: store)
        XCTAssertEqual(app.selectedTaskIDs, [ids[4], ids[2]])

        app.selection = .inbox
        app.selection = .search
        app.searchResultIDs = []
        XCTAssertFalse(app.moveSelection(by: 1, in: store), "no results: the arrow keys aren't claimed")
    }

    func testChangingViewsOrRevealingATaskClearsTheSelection() {
        let (store, app, ids) = makeInbox()
        app.click(ids[0], .plain, in: store)
        app.click(ids[1], .toggle, in: store)
        app.selection = .all
        XCTAssertNil(app.selectedTaskID)
        XCTAssertTrue(app.selectedTaskIDs.isEmpty)
        app.click(ids[3], .range, in: store)
        XCTAssertEqual(app.selectedTaskID, ids[3], "no anchor left over from the last view")

        app.click(ids[4], .toggle, in: store)
        app.reveal(task: ids[0], in: store)
        XCTAssertTrue(app.selectedTaskIDs.isEmpty)
        XCTAssertEqual(app.selectedTaskID, ids[0])
    }
}

/// Compact rows measured off screen: one short line no matter how much the task carries.
@MainActor
final class CompactRowLayoutTests: XCTestCase {
    var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("docket-compact-\(UUID().uuidString)")
        // Row badges from the Slack/Gmail and extras code must never reach the login keychain from a test.
        Keychain.useInMemoryStore()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
        UserDefaults.standard.removeObject(forKey: Prefs.Key.compactRows)
    }

    private func height(of task: TaskItem, compact: Bool, store: Store, width: CGFloat = 560) -> CGFloat {
        let app = AppState()
        app.compactRows = compact
        let row = TaskRow(task: task, context: .inbox)
            .environmentObject(store)
            .environmentObject(app)
            .environmentObject(FocusTimer())
            .frame(width: width)
        return NSHostingView(rootView: row).fittingSize.height
    }

    func testCompactRowsStayOneShortLine() {
        let store = Store(persistence: Persistence(directory: dir), seedIfEmpty: false)
        let list = store.addList(name: "Board", color: .blue, icon: "briefcase")
        var busy = TaskItem(title: "Prepare the quarterly board update with the revenue bridge, the hiring plan and three runway scenarios")
        busy.listID = list.id
        busy.dueDate = Calendar.current.date(bySettingHour: 15, minute: 0, second: 0, of: Date().addingTimeInterval(86_400 * 3))
        busy.dueHasTime = true
        busy.estimateMinutes = 90
        busy.priority = .urgent
        busy.tags = ["board", "finance"]
        busy.recurrence = .weekly
        busy.reminders = [Reminder(trigger: .beforeDue(minutes: 15), isAlarm: true)]
        busy.notes = "Bring the deck"
        busy.subtasks = [Subtask(title: "Numbers"), Subtask(title: "Slides", done: true)]

        let compact = height(of: busy, compact: true, store: store)
        XCTAssertTrue((26...34).contains(compact), "about 30pt tall, got \(compact)")
        XCTAssertEqual(height(of: TaskItem(title: "Call Sam"), compact: true, store: store), compact, accuracy: 0.5,
                       "no second line, however much the task carries")
        XCTAssertEqual(height(of: busy, compact: true, store: store, width: 340), compact, accuracy: 0.5,
                       "a narrow list truncates the title instead of wrapping it")
        XCTAssertGreaterThan(height(of: busy, compact: false, store: store), compact + 20, "the roomy row is much taller")
    }
}
