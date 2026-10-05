import XCTest
@testable import Docket

/// Shared setup: a store in a throwaway folder and days relative to today.
@MainActor
class ExtrasTestCase: XCTestCase {
    var dir: URL!
    let cal = Calendar.current

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("docket-extras-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func makeStore() -> Store { Store(persistence: Persistence(directory: dir), seedIfEmpty: false) }

    var today: Date { cal.startOfDay(for: Date()) }

    func day(_ offset: Int, hour: Int? = nil, minute: Int = 0) -> Date {
        let d = cal.date(byAdding: .day, value: offset, to: today)!
        guard let hour else { return d }
        return cal.date(bySettingHour: hour, minute: minute, second: 0, of: d)!
    }

    @discardableResult
    func add(_ store: Store, _ title: String, due: Date? = nil, timed: Bool = false, planned: Date? = nil) -> UUID {
        var t = TaskItem(title: title)
        t.dueDate = due
        t.dueHasTime = timed
        t.scheduledDate = planned
        return store.addTask(t).id
    }

    func count(_ store: Store, _ id: UUID) -> Int { store.task(id)?.postponeCount ?? -1 }
}

// MARK: - Slipping: what counts as a push

@MainActor
final class ExtrasSlipCountingTests: ExtrasTestCase {
    func testOnlyMovingADateToALaterDayIsAPush() {
        var base = TaskItem(title: "Investor update")
        base.dueDate = day(0)
        base.scheduledDate = day(0)
        func pushes(_ change: (inout TaskItem) -> Void) -> Bool {
            var changed = base
            change(&changed)
            return Slipping.isPostponement(from: base, to: changed, calendar: cal)
        }
        XCTAssertTrue(pushes { $0.dueDate = day(1) }, "deadline to a later day")
        XCTAssertTrue(pushes { $0.scheduledDate = day(3) }, "plan date to a later day")
        XCTAssertFalse(pushes { $0.dueDate = day(-1) }, "earlier")
        XCTAssertFalse(pushes { $0.dueDate = nil }, "cleared")
        XCTAssertFalse(pushes { $0.scheduledDate = nil }, "plan date removed")
        XCTAssertFalse(pushes {
            $0.dueDate = self.day(0, hour: 18)
            $0.dueHasTime = true
        }, "a time on the same day")
        XCTAssertFalse(pushes { $0.title = "Investor update v2" })
        XCTAssertFalse(pushes {
            $0.dueDate = self.day(2)
            $0.completedAt = Date()
        }, "nothing counts on a finished task")

        let undated = TaskItem(title: "Someday")
        var dated = undated
        dated.dueDate = day(5)
        XCTAssertFalse(Slipping.isPostponement(from: undated, to: dated, calendar: cal), "a first date isn't a push")
    }

    func testPushesCountFromEveryPath() {
        let store = makeStore()
        let notification = add(store, "Notification Tomorrow", due: day(0))
        let menu = add(store, "Context menu deadline", due: day(0))
        let plan = add(store, "Do tomorrow", planned: day(0))
        let picker = add(store, "Detail date picker", due: day(1, hour: 10), timed: true)
        let dropped = add(store, "Dropped on a day", due: day(0))

        store.pushToTomorrow(notification)
        store.setDueDay(menu, day(7))
        store.setScheduled(plan, day(1))
        store.binding(forTask: picker).wrappedValue.dueDate = day(3, hour: 10)
        store.move(dropped, toDay: day(2))

        for id in [notification, menu, plan, picker, dropped] {
            XCTAssertEqual(count(store, id), 1, store.task(id)?.title ?? "")
        }
        XCTAssertEqual(cal.component(.hour, from: store.task(picker)!.dueDate!), 10, "time kept")
    }

    func testEarlierMovesTimesFirstDatesReordersAndCompletionNeverCount() {
        let store = makeStore()
        let earlier = add(store, "Pulled in", due: day(4))
        let timeOnly = add(store, "New time", due: day(1, hour: 9), timed: true)
        let firstDate = add(store, "Undated")
        let cleared = add(store, "Cleared", due: day(2))
        let a = add(store, "A", planned: day(0))
        let b = add(store, "B", planned: day(0))
        let done = add(store, "Done", due: day(0))

        store.setDueDay(earlier, day(1))
        store.binding(forTask: timeOnly).wrappedValue.dueDate = day(1, hour: 17)
        store.setDueDay(firstDate, day(3))
        store.setDueDay(cleared, nil)
        store.placeInDay(b, before: a)
        store.moveInDay(b, by: 1)
        store.setCompleted(done, true)
        store.setDueDay(done, day(5))

        for id in [earlier, timeOnly, firstDate, cleared, a, b, done] {
            XCTAssertEqual(count(store, id), 0, store.task(id)?.title ?? "")
        }
    }

    func testAMoveThatAlsoClearsThePlanDateCountsOnce() {
        let store = makeStore()
        // Moving onto a day sets the deadline and then clears the plan date: two changes, one push.
        let id = add(store, "Board pack", due: day(2), planned: day(0))
        store.move(id, toDay: day(5))
        XCTAssertEqual(count(store, id), 1)
        XCTAssertNil(store.task(id)?.scheduledDate)
    }

    func testQuickRepicksCountOnceAndMovingBackCancelsThePush() {
        let store = makeStore()
        let id = add(store, "Hire a CFO", due: day(0))
        store.setDueDay(id, day(1))
        XCTAssertEqual(count(store, id), 1)
        // Clicking around the date picker, or "tomorrow" then "next week": still one push.
        store.setDueDay(id, day(3))
        store.binding(forTask: id).wrappedValue.dueDate = day(4)
        XCTAssertEqual(count(store, id), 1)
        // Back where it started: that push didn't happen after all.
        store.setDueDay(id, day(0))
        XCTAssertEqual(count(store, id), 0)
        // Each task is counted on its own.
        let other = add(store, "Renew insurance", due: day(0))
        store.setDueDay(id, day(2))
        store.setDueDay(other, day(2))
        XCTAssertEqual(count(store, id), 1)
        XCTAssertEqual(count(store, other), 1)
    }

    func testUndoingAPushAndPushingAgainCountsAgain() {
        let store = makeStore()
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.undoManager = undo
        undo.beginUndoGrouping()
        let id = add(store, "Close the round", due: day(0))
        undo.endUndoGrouping()

        undo.beginUndoGrouping()
        store.pushToTomorrow(id)
        undo.endUndoGrouping()
        XCTAssertEqual(count(store, id), 1)
        undo.undo()
        XCTAssertEqual(count(store, id), 0)
        XCTAssertEqual(store.task(id)?.dueDate, day(0))

        undo.beginUndoGrouping()
        store.pushToTomorrow(id)
        undo.endUndoGrouping()
        XCTAssertEqual(count(store, id), 1)
    }

    func testARepeatingTaskStartsItsNextOccurrenceFresh() {
        let store = makeStore()
        var weekly = TaskItem(title: "Weekly metrics review")
        weekly.recurrence = .weekly
        weekly.dueDate = day(0)
        weekly.postponeCount = 4
        let id = store.addTask(weekly).id

        store.setCompleted(id, true)
        XCTAssertEqual(count(store, id), 0, "next occurrence")
        XCTAssertEqual(store.tasks.first { $0.isCompleted }?.postponeCount, 4, "the logged copy keeps its history")
    }

    func testPushesFarApartCountSeparately() {
        var tracker = SlipTracker(window: 60)
        let start = Date()
        var t = TaskItem(title: "Quarterly OKRs")
        t.dueDate = day(0)
        func push(to dayOffset: Int, after seconds: TimeInterval) {
            var next = t
            next.dueDate = day(dayOffset)
            tracker.record(from: t, to: &next, now: start.addingTimeInterval(seconds), calendar: cal)
            t = next
        }
        push(to: 1, after: 0)
        XCTAssertEqual(t.postponeCount, 1)
        push(to: 2, after: 30)
        XCTAssertEqual(t.postponeCount, 1, "within a minute: the same push")
        push(to: 3, after: 200)
        XCTAssertEqual(t.postponeCount, 2, "a new decision later on")
        push(to: 4, after: 220)
        XCTAssertEqual(t.postponeCount, 2, "still later than before that push")
        push(to: 2, after: 230)
        XCTAssertEqual(t.postponeCount, 1, "back where that push started: undone")
        push(to: 0, after: 400)
        XCTAssertEqual(t.postponeCount, 1, "an earlier move later on never takes a push away")
    }

    func testOnlyOpenSlippingTasksThatAreStillYoursGetTheNudge() {
        var t = TaskItem(title: "Update the cap table")
        t.postponeCount = 2
        XCTAssertFalse(Slipping.needsNudge(t))
        t.postponeCount = 3
        XCTAssertTrue(Slipping.needsNudge(t))
        t.waitingOn = "  "
        XCTAssertTrue(Slipping.needsNudge(t), "a blank name isn't a delegation")
        t.waitingOn = "Priya"
        XCTAssertFalse(Slipping.needsNudge(t), "delegated: answered")
        t.waitingOn = nil
        t.completedAt = Date()
        XCTAssertFalse(Slipping.needsNudge(t))
    }
}

// MARK: - Day cleared

@MainActor
final class ExtrasDayClearedTests: ExtrasTestCase {
    private var defaults: UserDefaults!
    private var suite = ""
    private var saved: (UserDefaults, Bool, () -> Bool)!

    override func setUp() async throws {
        try await super.setUp()
        suite = "docket-extras-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        let c = Celebration.shared
        saved = (c.defaults, c.playsSound, c.reduceMotion)
        c.defaults = defaults
        c.playsSound = false
        c.reduceMotion = { false }
    }

    override func tearDown() async throws {
        let c = Celebration.shared
        c.defaults = saved.0
        c.playsSound = saved.1
        c.reduceMotion = saved.2
        defaults.removePersistentDomain(forName: suite)
        try await super.tearDown()
    }

    func testTheLastOfTodaysTasksClearsTheDay() {
        let store = makeStore()
        let dueToday = add(store, "Sign the lease", due: day(0, hour: 15), timed: true)
        let plannedToday = add(store, "Call Northwind", planned: day(0))
        let overdue = add(store, "Expense report", due: day(-2))
        add(store, "Board dinner", due: day(1))
        add(store, "Someday idea")
        let now = day(0, hour: 11)

        func finish(_ id: UUID) -> Bool {
            store.setCompleted(id, true)
            return DayClear.didClearDay(completing: store.task(id)!, in: store.tasks, now: now, calendar: cal)
        }
        XCTAssertFalse(finish(dueToday))
        XCTAssertFalse(finish(plannedToday), "the overdue task is still open")
        XCTAssertTrue(finish(overdue), "tomorrow's and undated tasks don't count")
        XCTAssertTrue(DayClear.openTasks(in: store.tasks, now: now, calendar: cal).isEmpty)
    }

    func testFinishingSomethingThatWasntForTodayDoesNotCount() {
        let store = makeStore()
        let later = add(store, "Plan offsite", due: day(6))
        let undated = add(store, "Read the memo")
        let now = day(0, hour: 9)
        for id in [later, undated] {
            store.setCompleted(id, true)
            XCTAssertFalse(DayClear.didClearDay(completing: store.task(id)!, in: store.tasks, now: now, calendar: cal))
        }
    }

    func testAMissedPlanDateStillBelongsToToday() {
        let store = makeStore()
        let first = add(store, "Prep 1:1s", planned: day(0))
        add(store, "Slipped from yesterday", planned: day(-1))
        store.setCompleted(first, true)
        XCTAssertFalse(DayClear.didClearDay(completing: store.task(first)!, in: store.tasks, now: day(0, hour: 10), calendar: cal))
    }

    /// What a checkbox click does after ticking a task off (AppState.toggle), minus its sound.
    private func complete(_ id: UUID, _ store: Store, _ app: AppState) {
        store.setCompleted(id, true)
        Extras.didComplete(id, store: store, app: app)
    }

    func testCelebratesOnceADayWithToastAndConfetti() {
        let store = makeStore()
        let app = AppState()
        let id = add(store, "Send the update", due: day(0))
        let other = add(store, "Book flights", planned: day(0))
        let before = Celebration.shared.burst

        complete(other, store, app)
        XCTAssertNil(app.toast, "one task still open today")
        XCTAssertEqual(Celebration.shared.burst, before)

        complete(id, store, app)
        XCTAssertEqual(app.toast, "Day cleared. Nice work.")
        XCTAssertNotNil(Celebration.shared.burst)
        XCTAssertNotEqual(Celebration.shared.burst, before)
        XCTAssertEqual(defaults.string(forKey: DayClear.lastCelebratedKey), Fmt.dayKey(Date()))

        // Reopen and finish again: not twice in a day.
        let first = Celebration.shared.burst
        store.setCompleted(id, false)
        app.toast = nil
        complete(id, store, app)
        XCTAssertNil(app.toast)
        XCTAssertEqual(Celebration.shared.burst, first)

        // A new day celebrates again.
        defaults.set("2001-01-01", forKey: DayClear.lastCelebratedKey)
        store.setCompleted(id, false)
        complete(id, store, app)
        XCTAssertEqual(app.toast, "Day cleared. Nice work.")
    }

    func testReduceMotionGetsTheToastOnly() {
        Celebration.shared.reduceMotion = { true }
        let store = makeStore()
        let app = AppState()
        let id = add(store, "Approve budget", planned: day(0))
        let before = Celebration.shared.burst

        complete(id, store, app)
        XCTAssertEqual(app.toast, "Day cleared. Nice work.")
        XCTAssertEqual(Celebration.shared.burst, before, "no confetti")
    }

    func testOnlyOncePerCalendarDay() {
        let now = day(0, hour: 12)
        XCTAssertTrue(DayClear.shouldCelebrate(lastCelebrated: nil, now: now))
        XCTAssertTrue(DayClear.shouldCelebrate(lastCelebrated: Fmt.dayKey(day(-1)), now: now))
        XCTAssertFalse(DayClear.shouldCelebrate(lastCelebrated: Fmt.dayKey(now), now: day(0, hour: 23)))
    }
}

// MARK: - Overdue rollover

@MainActor
final class ExtrasRolloverTests: ExtrasTestCase {
    func testMovesEveryOverdueTaskToTodayInOneUndoStep() {
        let store = makeStore()
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.undoManager = undo
        undo.beginUndoGrouping()
        let timed = add(store, "Call the bank", due: day(-3, hour: 15, minute: 30), timed: true)
        let planned = add(store, "Expense report", due: day(-1), planned: day(-2))
        let todays = add(store, "Today's task", due: day(0))
        let tomorrows = add(store, "Tomorrow's task", due: day(1))
        let finished = add(store, "Already done", due: day(-4))
        store.setCompleted(finished, true)
        let undated = add(store, "Undated")
        undo.endUndoGrouping()
        let before = store.tasks

        XCTAssertEqual(Set(store.rolloverCandidates()), [timed, planned])

        undo.beginUndoGrouping()
        XCTAssertEqual(store.rollOverdueToToday(), 2)
        undo.endUndoGrouping()

        let call = store.task(timed)!
        XCTAssertTrue(cal.isDateInToday(call.dueDate!))
        XCTAssertEqual(cal.component(.hour, from: call.dueDate!), 15, "the time is kept")
        XCTAssertEqual(cal.component(.minute, from: call.dueDate!), 30)
        XCTAssertTrue(call.dueHasTime)
        let report = store.task(planned)!
        XCTAssertEqual(report.dueDate, day(0))
        XCTAssertNil(report.scheduledDate, "it follows its deadline now")
        XCTAssertEqual(count(store, timed), 1, "an explicit move to a later day counts as a push")
        XCTAssertEqual(count(store, planned), 1)
        for id in [todays, tomorrows, finished, undated] {
            XCTAssertEqual(store.task(id), before.first { $0.id == id }, "untouched")
        }
        XCTAssertTrue(store.rolloverCandidates().isEmpty)
        XCTAssertEqual(store.rollOverdueToToday(), 0, "nothing left to move")

        XCTAssertEqual(undo.undoActionName, "Move to Today")
        undo.undo()
        XCTAssertEqual(store.tasks, before, "one ⌘Z puts everything back, counts included")
    }
}

// MARK: - Delegation

final class ExtrasDelegationTests: XCTestCase {
    func testNamesAreTidied() {
        XCTAssertEqual(Delegation.normalized("  Sam   Lee \n"), "Sam Lee")
        XCTAssertNil(Delegation.normalized("   "))
        XCTAssertNil(Delegation.normalized(nil))
    }

    func testPeopleUsedBeforeAreUniqueAndMostRecentFirst() {
        func task(_ person: String?, minutesAgo: Double, done: Bool = false) -> TaskItem {
            var t = TaskItem(title: "Task")
            t.waitingOn = person
            t.updatedAt = Date().addingTimeInterval(-minutesAgo * 60)
            if done { t.completedAt = Date() }
            return t
        }
        let tasks = [
            task("Sam Lee", minutesAgo: 30),
            task("Priya", minutesAgo: 5),
            task("sam  lee", minutesAgo: 1),
            task("  ", minutesAgo: 0),
            task(nil, minutesAgo: 0),
            task("Zoë", minutesAgo: 60, done: true),
            task("Zoe", minutesAgo: 90),
        ]
        XCTAssertEqual(Delegation.recentPeople(in: tasks), ["sam lee", "Priya", "Zoë"])
        XCTAssertEqual(Delegation.recentPeople(in: tasks, limit: 2), ["sam lee", "Priya"])
    }

    func testToastTitlesStayShort() {
        XCTAssertEqual(Extras.shortTitle("  Renew the domain "), "Renew the domain")
        XCTAssertEqual(Extras.shortTitle(""), "Untitled")
        let long = Extras.shortTitle(String(repeating: "word ", count: 20))
        XCTAssertEqual(long.count, 40)
        XCTAssertTrue(long.hasSuffix("…"))
    }
}

// MARK: - Confetti

final class ExtrasConfettiTests: XCTestCase {
    func testABurstStartsAboveTheTopAndIsGoneWhenItEnds() {
        let pieces = Confetti.pieces(seed: 42)
        XCTAssertEqual(pieces.count, 90)
        XCTAssertEqual(pieces.map(\.x), Confetti.pieces(seed: 42).map(\.x), "the same seed draws the same burst every frame")
        XCTAssertNotEqual(pieces.map(\.x), Confetti.pieces(seed: 7).map(\.x))
        XCTAssertTrue(Set(pieces.map(\.tint)).isSuperset(of: [0, 2]), "ink and the accent")

        let width = 1220.0
        for p in pieces {
            if let start = p.state(at: p.delay, width: width) {
                XCTAssertLessThan(start.y, 0, "enters from above the top edge")
                XCTAssertEqual(start.opacity, 0, accuracy: 0.001, "fades in")
            }
            XCTAssertNil(p.state(at: p.delay - 0.01, width: width), "not before its start")
            XCTAssertNil(p.state(at: Confetti.duration, width: width), "all gone when the burst ends")
            let late = p.state(at: Confetti.duration - 0.05, width: width)
            XCTAssertLessThan(late?.opacity ?? 0, 0.15, "fading out at the end")
        }
        let mid = pieces.compactMap { $0.state(at: 0.5, width: width) }
        XCTAssertEqual(mid.count, pieces.count, "everyone is out mid-burst")
        XCTAssertTrue(mid.allSatisfy { $0.y > 0 && $0.opacity > 0.5 })
    }
}
