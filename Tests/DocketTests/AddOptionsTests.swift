import XCTest
@testable import Docket

/// The add-task dropdowns: a pick beats the typed text, the screen fills in the rest, and picks reset after adding.
final class AddOptionsTests: XCTestCase {
    let cal = Calendar.current
    /// 4 PM today, fixed, so "a time that has already passed" doesn't depend on when the tests run.
    let now = Calendar.current.date(bySettingHour: 16, minute: 0, second: 0, of: Date())!
    var today: Date { cal.startOfDay(for: now) }
    func day(_ offset: Int) -> Date { cal.date(byAdding: .day, value: offset, to: today)! }
    func at(_ hour: Int, _ minute: Int = 0, on d: Date) -> Date { cal.date(bySettingHour: hour, minute: minute, second: 0, of: d)! }

    let board = TaskList(name: "Board")
    let hiring = TaskList(name: "Hiring")
    var lists: [TaskList] { [board, hiring] }

    /// What "Call Sam fri 3pm 45m !! #board #followup @alarm10" parses to. Built by hand: the date
    /// detector always works from the real clock, and these tests use a fixed one.
    func typedCall(due: Date?) -> ParsedTask {
        var p = ParsedTask()
        p.title = "Call Sam"
        p.dueDate = due
        p.dueHasTime = due != nil
        p.estimateMinutes = 45
        p.priority = .medium
        p.listID = board.id
        p.tags = ["followup"]
        p.reminders = [.init(minutesBefore: 10, isAlarm: true)]
        return p
    }

    func make(_ options: AddOptions, _ parsed: ParsedTask, _ context: AddContext = AddContext()) -> TaskItem {
        options.makeTask(parsed: parsed, context: context, lists: lists, now: now, calendar: cal, defaultReminder: 15, defaultIsAlarm: false)
    }

    // MARK: Nothing picked

    func testNothingPickedAddsExactlyWhatWasTyped() {
        // The same task quick add made before the dropdowns existed.
        let realNow = Date()
        let parser = QuickParser(now: realNow, lists: lists)
        for text in ["Review board deck tomorrow 4pm 45m !!! #board @alarm15", "Call Priya #sales fri", "Standup every weekday 15m",
                     "Draft memo in 2 hours", "Ship pricing page by eod !!", "Pay rent"] {
            let p = parser.parse(text)
            let merged = AddOptions().makeTask(parsed: p, context: AddContext(), lists: lists, now: realNow,
                                               defaultReminder: 15, defaultIsAlarm: true)
            let typed = TaskItem(parsed: p, defaultReminder: 15, defaultIsAlarm: true)
            XCTAssertEqual(merged.title, typed.title, text)
            XCTAssertEqual(merged.dueDate, typed.dueDate, text)
            XCTAssertEqual(merged.dueHasTime, typed.dueHasTime, text)
            XCTAssertEqual(merged.estimateMinutes, typed.estimateMinutes, text)
            XCTAssertEqual(merged.priority, typed.priority, text)
            XCTAssertEqual(merged.tags, typed.tags, text)
            XCTAssertEqual(merged.listID, typed.listID, text)
            XCTAssertEqual(merged.recurrence, typed.recurrence, text)
            XCTAssertEqual(merged.reminders.map(\.trigger), typed.reminders.map(\.trigger), text)
            XCTAssertEqual(merged.reminders.map(\.isAlarm), typed.reminders.map(\.isAlarm), text)
            XCTAssertNil(merged.scheduledDate, text)
        }
    }

    // MARK: A pick beats the typed text

    func testPicksBeatTheTypedText() {
        var o = AddOptions()
        o.pickDate(at(13, on: day(1)))
        o.pickTime(9 * 60)
        o.pickList(hiring.id)
        o.pickEstimate(30)
        o.pickPriority(.low)
        o.pickReminder(AddReminder(minutesBefore: 5, isAlarm: false))
        XCTAssertEqual(o.date, .value(day(1)), "a picked day is the whole day")

        let t = make(o, typedCall(due: at(15, on: day(5))))
        XCTAssertEqual(t.title, "Call Sam")
        XCTAssertEqual(t.dueDate, at(9, on: day(1)))
        XCTAssertTrue(t.dueHasTime)
        XCTAssertNil(t.scheduledDate)
        XCTAssertEqual(t.listID, hiring.id)
        XCTAssertEqual(t.estimateMinutes, 30)
        XCTAssertEqual(t.priority, .low)
        XCTAssertEqual(t.reminders.map(\.trigger), [.beforeDue(minutes: 5)])
        XCTAssertEqual(t.reminders.map(\.isAlarm), [false])
        XCTAssertEqual(t.tags, ["followup"], "tags have no dropdown and always come from the text")
    }

    func testAPickedDayKeepsTheTypedTimeAndAPickedTimeKeepsTheTypedDay() {
        let typed = typedCall(due: at(15, on: day(5)))
        var dayOnly = AddOptions()
        dayOnly.pickDate(day(1))
        XCTAssertEqual(make(dayOnly, typed).dueDate, at(15, on: day(1)))

        var timeOnly = AddOptions()
        timeOnly.pickTime(10 * 60 + 30)
        let t = make(timeOnly, typed)
        XCTAssertEqual(t.dueDate, at(10, 30, on: day(5)))
        XCTAssertTrue(t.dueHasTime)
    }

    func testNoTimeKeepsTheDay() {
        var o = AddOptions()
        o.pickTime(nil)
        var typed = typedCall(due: at(15, on: day(5)))
        typed.reminders = []
        let t = make(o, typed)
        XCTAssertEqual(t.dueDate, day(5))
        XCTAssertFalse(t.dueHasTime)
        XCTAssertTrue(t.reminders.isEmpty, "the default reminder is only for deadlines with a time")
    }

    // MARK: A time without a date

    func testATimeWithoutADateLandsOnTheScreensDay() {
        var o = AddOptions()
        o.pickTime(17 * 60)

        let elsewhere = make(o, ParsedTask(title: "Call Sam"))
        XCTAssertEqual(elsewhere.dueDate, at(17, on: today), "outside the Calendar: today")
        XCTAssertTrue(elsewhere.dueHasTime)
        XCTAssertNil(elsewhere.scheduledDate)

        let calendarDay = make(o, ParsedTask(title: "Call Sam"), AddContext(selection: .calendar, day: day(3)))
        XCTAssertEqual(calendarDay.dueDate, at(17, on: day(3)), "on the Calendar: its day")
        XCTAssertNil(calendarDay.scheduledDate)
        XCTAssertEqual(calendarDay.reminders.map(\.trigger), [.beforeDue(minutes: 15)], "a picked time gets the default reminder too")
    }

    func testATimeThatHasPassedTodayMeansTomorrow() {
        var o = AddOptions()
        o.pickTime(9 * 60) // and it's 4 PM
        XCTAssertEqual(make(o, ParsedTask(title: "Call Sam")).dueDate, at(9, on: day(1)))
        XCTAssertEqual(make(o, ParsedTask(title: "Call Sam"), AddContext(day: today)).dueDate, at(9, on: day(1)))

        // A day picked by hand is kept, even when that time has passed.
        o.pickDate(today)
        XCTAssertEqual(make(o, ParsedTask(title: "Call Sam")).dueDate, at(9, on: today))
    }

    // MARK: No date

    func testNoDateMeansNoDeadlineAndNoPlanDate() {
        var o = AddOptions()
        o.pickTime(9 * 60)
        o.pickDate(nil)
        XCTAssertEqual(o.time, .auto, "No date lets go of the picked time")

        let t = make(o, typedCall(due: at(15, on: day(5))), AddContext(selection: .calendar, day: today))
        XCTAssertNil(t.dueDate)
        XCTAssertFalse(t.dueHasTime)
        XCTAssertNil(t.scheduledDate)
    }

    func testPickingATimeAfterNoDateBringsADayBack() {
        var o = AddOptions()
        o.pickDate(nil)
        o.pickTime(18 * 60)
        XCTAssertEqual(o.date, .auto)
        XCTAssertEqual(make(o, ParsedTask(title: "Call Sam"), AddContext(day: day(2))).dueDate, at(18, on: day(2)))
    }

    // MARK: The screen's defaults

    func testTheCalendarPlansUndatedTasksForItsDay() {
        let calendarPage = AddContext(selection: .calendar, day: day(2))
        let planned = make(AddOptions(), ParsedTask(title: "Board prep"), calendarPage)
        XCTAssertNil(planned.dueDate)
        XCTAssertEqual(planned.scheduledDate, day(2))
        XCTAssertEqual(make(AddOptions(), ParsedTask(title: "Board prep"), AddContext(day: day(-3))).scheduledDate, today,
                       "never planned in the past")
        XCTAssertNil(make(AddOptions(), ParsedTask(title: "Board prep"), AddContext(selection: .calendar, day: nil)).scheduledDate,
                     "no day: no date")

        // Typed and picked dates are deadlines, as everything typed into quick add is.
        let typed = make(AddOptions(), ParsedTask(title: "Board prep", dueDate: day(4)), calendarPage)
        XCTAssertEqual(typed.dueDate, day(4))
        XCTAssertNil(typed.scheduledDate)
        var o = AddOptions()
        o.pickDate(day(6))
        let picked = make(o, ParsedTask(title: "Board prep"), calendarPage)
        XCTAssertEqual(picked.dueDate, day(6))
        XCTAssertFalse(picked.dueHasTime)
        XCTAssertNil(picked.scheduledDate)

        // Other pages give no date.
        XCTAssertNil(make(AddOptions(), ParsedTask(title: "Board prep")).scheduledDate)
    }

    func testAListsPageAddsToItUnlessTypedOrPicked() {
        let page = AddContext(selection: .list(board.id), day: nil)
        XCTAssertEqual(make(AddOptions(), ParsedTask(title: "Agenda"), page).listID, board.id, "the page's list")
        XCTAssertEqual(make(AddOptions(), ParsedTask(title: "Agenda", listID: hiring.id), page).listID, hiring.id, "typed #list beats the page")

        var o = AddOptions()
        o.pickList(hiring.id)
        XCTAssertEqual(make(o, ParsedTask(title: "Agenda", listID: board.id), page).listID, hiring.id, "a pick beats both")
        o.pickList(nil)
        XCTAssertEqual(o.list, .cleared)
        XCTAssertNil(make(o, ParsedTask(title: "Agenda"), page).listID, "Inbox means the Inbox, even on a list's page")
        o.pickList(UUID())
        XCTAssertNil(make(o, ParsedTask(title: "Agenda")).listID, "a list deleted since means the Inbox")
    }

    func testImportantAndTagPages() {
        let important = AddContext(selection: .important, day: nil)
        XCTAssertEqual(make(AddOptions(), ParsedTask(title: "Fix pricing"), important).priority, .high)
        XCTAssertEqual(make(AddOptions(), ParsedTask(title: "Fix pricing", priority: .urgent), important).priority, .urgent)
        var o = AddOptions()
        o.pickPriority(.low)
        XCTAssertEqual(make(o, ParsedTask(title: "Fix pricing"), important).priority, .low, "a pick is taken as meant")

        let tagPage = AddContext(selection: .tag("board"), day: nil)
        XCTAssertEqual(make(AddOptions(), ParsedTask(title: "Deck"), tagPage).tags, ["board"])
        XCTAssertEqual(make(AddOptions(), ParsedTask(title: "Deck", tags: ["Board"]), tagPage).tags, ["Board"], "no duplicate tag")
    }

    func testPagesWithoutDefaults() {
        for page: SidebarItem in [.inbox, .all, .waiting, .search, .completed] {
            XCTAssertEqual(AddContext(selection: page, day: day(1)), AddContext(), "\(page)")
        }
    }

    // MARK: Reminders

    func testReminderPicks() {
        let typed = typedCall(due: at(15, on: day(5)))
        var o = AddOptions()
        XCTAssertEqual(make(o, typed).reminders.map(\.trigger), [.beforeDue(minutes: 10)], "as typed: @alarm10")
        XCTAssertEqual(make(o, typed).reminders.map(\.isAlarm), [true])

        o.pickReminder(AddReminder(minutesBefore: 30, isAlarm: false))
        XCTAssertEqual(make(o, typed).reminders.map(\.trigger), [.beforeDue(minutes: 30)])
        XCTAssertEqual(make(o, typed).reminders.map(\.isAlarm), [false])

        o.pickReminder(nil)
        XCTAssertTrue(make(o, typed).reminders.isEmpty, "No reminder turns off the typed one…")
        var plain = typed
        plain.reminders = []
        XCTAssertTrue(make(o, plain).reminders.isEmpty, "…and the default one")
        XCTAssertEqual(make(AddOptions(), plain).reminders.map(\.trigger), [.beforeDue(minutes: 15)], "the default from Settings")
    }

    // MARK: Reset

    func testPicksResetAfterAddingButThePagesListStays() {
        let page = AddContext(selection: .list(board.id), day: nil)
        var o = AddOptions()
        o.pickDate(day(2))
        o.pickTime(9 * 60)
        o.pickList(hiring.id)
        o.pickEstimate(45)
        o.pickPriority(.urgent)
        o.pickReminder(AddReminder(minutesBefore: 0, isAlarm: true))
        XCTAssertTrue(o.hasPicks)

        o.reset()
        XCTAssertFalse(o.hasPicks)
        XCTAssertEqual(o, AddOptions())
        let next = make(o, ParsedTask(title: "Next one"), page)
        XCTAssertEqual(next.listID, board.id)
        XCTAssertNil(next.dueDate)
        XCTAssertNil(next.scheduledDate)
        XCTAssertNil(next.estimateMinutes)
        XCTAssertEqual(next.priority, .none)
        XCTAssertTrue(next.reminders.isEmpty)
    }

    func testClearingAndBounds() {
        var o = AddOptions()
        o.pickEstimate(0)
        XCTAssertEqual(o.estimate, .cleared)
        XCTAssertNil(make(o, ParsedTask(title: "Read memo", estimateMinutes: 30)).estimateMinutes)
        o.pickTime(-5)
        XCTAssertEqual(o.time, .value(0))
        o.pickTime(5000)
        XCTAssertEqual(o.time, .value(24 * 60 - 1))
    }

    // MARK: Menus and chip labels

    func testDateShortcutsAreRealDays() {
        let sunday = cal.nextDate(after: now, matching: DateComponents(weekday: 1), matchingPolicy: .nextTime)!
        let s = cal.startOfDay(for: sunday)
        func plus(_ n: Int) -> Date { cal.date(byAdding: .day, value: n, to: s)! }

        let picks = AddOptions.quickDays(now: sunday, calendar: cal)
        XCTAssertEqual(picks.map(\.label), ["Today", "Tomorrow", "This weekend", "Next week", "In a week"])
        XCTAssertEqual(picks.map(\.day), [s, plus(1), plus(6), plus(1), plus(7)])

        let saturday = AddOptions.quickDays(now: plus(6), calendar: cal)
        XCTAssertEqual(saturday[2].day, plus(6), "on a Saturday, this weekend is today")
        XCTAssertEqual(saturday[3].day, plus(8), "next week starts on Monday")
    }

    func testOnlyTheFirstShortcutForADayIsTicked() {
        let sunday = cal.startOfDay(for: cal.nextDate(after: now, matching: DateComponents(weekday: 1), matchingPolicy: .nextTime)!)
        func plus(_ n: Int) -> Date { cal.date(byAdding: .day, value: n, to: sunday)! }
        let picks = AddOptions.quickDays(now: sunday, calendar: cal)

        // On a Sunday, Tomorrow and Next week are both Monday: the menu keeps both and ticks one.
        XCTAssertEqual(AddOptions.tickedQuickDay(plus(1), in: picks)?.label, "Tomorrow")
        XCTAssertEqual(AddOptions.tickedQuickDay(plus(6), in: picks)?.label, "This weekend")
        XCTAssertNil(AddOptions.tickedQuickDay(plus(3), in: picks), "not a shortcut: the menu ticks the day itself")
        XCTAssertNil(AddOptions.tickedQuickDay(nil, in: picks))
    }

    func testShortDateLabelsAreRealDates() {
        let year = cal.component(.year, from: now)
        let june1 = cal.date(from: DateComponents(year: year, month: 6, day: 1))!
        let june15 = cal.date(from: DateComponents(year: year, month: 6, day: 15))!
        let nextFeb = cal.date(from: DateComponents(year: year + 1, month: 2, day: 3))!

        XCTAssertEqual(AddOptions.shortDateLabel(june15, now: june1, calendar: cal), Fmt.dayMonth(june15))
        XCTAssertTrue(AddOptions.shortDateLabel(nextFeb, now: june1, calendar: cal).contains(String(year + 1)),
                      "another year keeps its year")
        XCTAssertFalse(AddOptions.shortDateLabel(june1, now: june1, calendar: cal).contains("Today"))
    }

    func testExtrasAreTheRepeatThenTheTags() {
        var t = TaskItem(title: "Board prep")
        XCTAssertTrue(AddOptions.extras(t).isEmpty)
        t.tags = ["board", "q4"]
        t.recurrence = .weekly
        let extras = AddOptions.extras(t)
        XCTAssertEqual(extras.map(\.icon), ["repeat", "number", "number"])
        XCTAssertEqual(extras.map(\.spoken), [Recurrence.weekly.summary, "#board", "#q4"])

        // A tag page's tag shows up there too, as the task will get it.
        let onTagPage = make(AddOptions(), ParsedTask(title: "Deck"), AddContext(tag: "board"))
        XCTAssertEqual(AddOptions.extras(onTagPage).map(\.spoken), ["#board"])
    }

    func testChipDensityOnlyEverGivesThingsUp() {
        let levels = AddChipDensity.all
        let full = AddChipDensity.full
        XCTAssertEqual(levels.first, full)
        XCTAssertFalse(full.terse || full.plainValues || full.quietList || full.short || full.minimal)
        XCTAssertTrue(full.chevrons)
        for (a, b) in zip(levels, levels.dropFirst()) {
            XCTAssertLessThan(a, b)
            // Whatever a step gives up stays given up at every tighter step.
            XCTAssertTrue(!a.terse || b.terse)
            XCTAssertTrue(!a.plainValues || b.plainValues)
            XCTAssertTrue(!a.quietList || b.quietList)
            XCTAssertTrue(a.chevrons || !b.chevrons)
            XCTAssertTrue(!a.short || b.short)
            XCTAssertTrue(!a.minimal || b.minimal)
        }
        let tightest = levels[levels.count - 1]
        XCTAssertTrue(tightest.minimal && tightest.short && !tightest.chevrons)
    }

    func testChipLabelsUseRealDates() {
        var t = TaskItem(title: "Call Sam")
        XCTAssertEqual(AddOptions.dateLabel(t, now: now), "No date")
        XCTAssertEqual(AddOptions.timeLabel(t), "No time")

        t.scheduledDate = today
        XCTAssertEqual(AddOptions.dateLabel(t, now: now), Fmt.absoluteDay(today, now: now))
        XCTAssertFalse(AddOptions.dateLabel(t, now: now).contains("Today"))

        t.dueDate = at(15, on: day(1))
        t.dueHasTime = true
        XCTAssertEqual(AddOptions.dateLabel(t, now: now), Fmt.absoluteDay(day(1), now: now), "the deadline's day wins")
        XCTAssertEqual(AddOptions.timeLabel(t), Fmt.time(at(15, on: day(1))))
    }

    func testMoreChipSummary() {
        var t = TaskItem(title: "Board prep")
        XCTAssertTrue(AddOptions.moreItems(t).isEmpty, "nothing set: the chip says More")

        t.estimateMinutes = 90
        t.priority = .high
        t.dueDate = at(15, on: day(1))
        t.dueHasTime = true
        t.reminders = [Reminder(trigger: .beforeDue(minutes: 15), isAlarm: true)]
        XCTAssertEqual(AddOptions.moreItems(t).map(\.text), ["1h 30m", "High", "15m before"])
        XCTAssertEqual(AddOptions.moreItems(t).map(\.icon), ["hourglass", "flag", "alarm"])
        XCTAssertEqual(AddOptions.currentReminder(t), AddReminder(minutesBefore: 15, isAlarm: true))

        t.reminders = [Reminder(trigger: .beforeDue(minutes: 0))]
        XCTAssertEqual(AddOptions.reminderSummary(t), "At deadline")
        t.dueHasTime = false
        XCTAssertEqual(AddOptions.reminderSummary(t), "On the day")
        t.reminders.append(Reminder(trigger: .beforeDue(minutes: 60)))
        XCTAssertEqual(AddOptions.reminderSummary(t), "2 reminders")
        XCTAssertNil(AddOptions.currentReminder(t), "several reminders: none ticked")
    }

    func testPickADateMonthsStartToday() {
        let months = AddOptions.months(from: now, count: 3, calendar: cal)
        XCTAssertEqual(months.count, 3)
        XCTAssertEqual(months.first, cal.dateInterval(of: .month, for: now)?.start)

        let thisMonth = AddOptions.days(inMonthOf: months[0], from: now, calendar: cal)
        XCTAssertEqual(thisMonth.first, today)
        XCTAssertTrue(thisMonth.allSatisfy { $0 >= today })
        let nextMonth = AddOptions.days(inMonthOf: months[1], from: now, calendar: cal)
        XCTAssertEqual(nextMonth.count, cal.range(of: .day, in: .month, for: months[1])?.count)
        XCTAssertEqual(nextMonth.first, months[1])
    }
}
