import XCTest
@testable import Docket

final class QuickParserTests: XCTestCase {
    let cal = Calendar.current
    var now: Date { Date() }
    var today: Date { cal.startOfDay(for: now) }
    func day(_ offset: Int) -> Date { cal.date(byAdding: .day, value: offset, to: today)! }

    func testFullExample() {
        let board = TaskList(name: "Board")
        let p = QuickParser(lists: [board]).parse("Review board deck tomorrow 4pm 45m !!! #board @alarm15")
        XCTAssertEqual(p.title, "Review board deck")
        XCTAssertEqual(p.estimateMinutes, 45)
        XCTAssertEqual(p.priority, .high)
        XCTAssertEqual(p.listID, board.id)
        XCTAssertEqual(p.tags, [])
        XCTAssertTrue(p.dueHasTime)
        XCTAssertEqual(p.dueDate, cal.date(bySettingHour: 16, minute: 0, second: 0, of: day(1)))
        XCTAssertEqual(p.reminders, [.init(minutesBefore: 15, isAlarm: true)])
    }

    func testTagWhenNoMatchingList() {
        let p = QuickParser().parse("Call Priya #sales #followup")
        XCTAssertEqual(p.title, "Call Priya")
        XCTAssertEqual(Set(p.tags), ["sales", "followup"])
        XCTAssertNil(p.listID)
    }

    func testDateOnlyWeekday() {
        let p = QuickParser().parse("Send update fri")
        XCTAssertEqual(p.title, "Send update")
        XCTAssertFalse(p.dueHasTime)
        XCTAssertEqual(cal.component(.weekday, from: p.dueDate!), 6)
        XCTAssertEqual(p.dueDate, cal.startOfDay(for: p.dueDate!))
    }

    func testDanglingPrepositionRemoved() {
        let p = QuickParser().parse("Send deck by tomorrow")
        XCTAssertEqual(p.title, "Send deck")
        XCTAssertEqual(p.dueDate, day(1))
    }

    func testDurations() {
        XCTAssertEqual(QuickParser().parse("Deep work 1h30m").estimateMinutes, 90)
        XCTAssertEqual(QuickParser().parse("Deep work 1.5h").estimateMinutes, 90)
        XCTAssertEqual(QuickParser().parse("Deep work ~2h").estimateMinutes, 120)
        XCTAssertEqual(QuickParser().parse("Gym for 45 min").estimateMinutes, 45)
        XCTAssertEqual(QuickParser().parse("Gym for 45 min").title, "Gym")
        XCTAssertEqual(QuickParser().parse("Read memo half an hour").estimateMinutes, 30)
        XCTAssertNil(QuickParser().parse("Call 5 investors").estimateMinutes)
        XCTAssertEqual(QuickParser().parse("Call 5 investors").title, "Call 5 investors")
        XCTAssertNil(QuickParser().parse("Q3 planning").estimateMinutes)
    }

    func testRelativeHours() {
        let start = Date()
        let p = QuickParser(now: start).parse("Draft memo in 2 hours")
        XCTAssertEqual(p.title, "Draft memo")
        XCTAssertTrue(p.dueHasTime)
        XCTAssertEqual(p.dueDate!.timeIntervalSince(start), 7200, accuracy: 1)
        XCTAssertNil(p.estimateMinutes)
    }

    func testEndOfDay() {
        let p = QuickParser(workdayEndMinutes: 18 * 60).parse("Ship pricing page by eod !!")
        XCTAssertEqual(p.title, "Ship pricing page")
        XCTAssertEqual(p.priority, .medium)
        XCTAssertTrue(p.dueHasTime)
        XCTAssertEqual(p.dueDate, cal.date(bySettingHour: 18, minute: 0, second: 0, of: today))
    }

    func testMealWordStaysInTitle() {
        let p = QuickParser().parse("Dinner tonight with Sam")
        XCTAssertEqual(p.title, "Dinner with Sam")
        XCTAssertTrue(p.dueHasTime)
        XCTAssertTrue(cal.isDate(p.dueDate!, inSameDayAs: now))
    }

    func testRecurrenceWeekdays() {
        let p = QuickParser().parse("Gym every mon, wed & fri 7am 1h")
        XCTAssertEqual(p.title, "Gym")
        XCTAssertEqual(p.recurrence, Recurrence(frequency: .weekly, weekdays: [2, 4, 6]))
        XCTAssertEqual(p.estimateMinutes, 60)
        XCTAssertTrue(p.dueHasTime)
        XCTAssertEqual(cal.component(.hour, from: p.dueDate!), 7)
    }

    func testRecurrenceWithoutDateGetsFirstOccurrence() {
        let p = QuickParser().parse("Standup every weekday")
        XCTAssertEqual(p.title, "Standup")
        XCTAssertEqual(p.recurrence, .weekdaysOnly)
        let wd = cal.component(.weekday, from: p.dueDate!)
        XCTAssertTrue((2...6).contains(wd))
        XCTAssertGreaterThanOrEqual(p.dueDate!, today)
    }

    func testBareAdjectiveKeepsTitle() {
        let p = QuickParser().parse("Weekly investor update")
        XCTAssertEqual(p.title, "Weekly investor update")
        XCTAssertEqual(p.recurrence, .weekly)
        XCTAssertEqual(p.dueDate, today)
    }

    func testEveryTwoWeeks() {
        let p = QuickParser().parse("Payroll review every 2 weeks")
        XCTAssertEqual(p.recurrence, Recurrence(frequency: .weekly, interval: 2))
        XCTAssertEqual(p.title, "Payroll review")
    }

    func testRemindToken() {
        let p = QuickParser().parse("Board call tomorrow 10am @remind1h")
        XCTAssertEqual(p.reminders, [.init(minutesBefore: 60, isAlarm: false)])
        XCTAssertEqual(p.title, "Board call")
    }

    func testEmailIsNotAReminderToken() {
        let p = QuickParser().parse("Email bob@acme.com")
        XCTAssertEqual(p.title, "Email bob@acme.com")
        XCTAssertTrue(p.reminders.isEmpty)
    }

    func testShorthandTomorrow() {
        let p = QuickParser().parse("call mom tmrw")
        XCTAssertEqual(p.title, "Call mom")
        XCTAssertEqual(p.dueDate, day(1))
    }

    func testNextWeekIsAMonday() {
        let p = QuickParser().parse("Plan offsite next week")
        XCTAssertEqual(p.title, "Plan offsite")
        XCTAssertEqual(cal.component(.weekday, from: p.dueDate!), 2)
        XCTAssertGreaterThan(p.dueDate!, today)
    }

    func testPlainTitle() {
        let p = QuickParser().parse("  iPhone app review  ")
        XCTAssertEqual(p.title, "iPhone app review")
        XCTAssertNil(p.dueDate)
        XCTAssertEqual(p.priority, .none)
    }
}

final class RecurrenceTests: XCTestCase {
    var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = 2
        return c
    }()

    func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    func testDaily() {
        XCTAssertEqual(Recurrence.daily.advance(date(2026, 10, 4), calendar: cal), date(2026, 10, 5))
    }

    func testWeekdaysSkipsWeekend() {
        // Fri Oct 9 2026 -> Mon Oct 12
        XCTAssertEqual(Recurrence.weekdaysOnly.advance(date(2026, 10, 9), calendar: cal), date(2026, 10, 12))
    }

    func testWeeklyOnSpecificDays() {
        let r = Recurrence(frequency: .weekly, weekdays: [2, 5]) // Mon, Thu
        XCTAssertEqual(r.advance(date(2026, 10, 5), calendar: cal), date(2026, 10, 8))  // Mon -> Thu
        XCTAssertEqual(r.advance(date(2026, 10, 8), calendar: cal), date(2026, 10, 12)) // Thu -> Mon
    }

    func testBiweeklyOnDays() {
        let r = Recurrence(frequency: .weekly, interval: 2, weekdays: [2, 5])
        XCTAssertEqual(r.advance(date(2026, 10, 5), calendar: cal), date(2026, 10, 8))  // same week
        XCTAssertEqual(r.advance(date(2026, 10, 8), calendar: cal), date(2026, 10, 19)) // skip a week
    }

    func testMonthly() {
        XCTAssertEqual(Recurrence.monthly.advance(date(2026, 1, 15), calendar: cal), date(2026, 2, 15))
    }

    func testLateCompletionSkipsPastOccurrences() {
        let now = date(2026, 10, 10, 15)
        let next = Recurrence.daily.nextOccurrence(after: date(2026, 10, 1), hasTime: false, now: now, calendar: cal)
        XCTAssertEqual(next, date(2026, 10, 10))
        let timed = Recurrence.daily.nextOccurrence(after: date(2026, 10, 1, 9), hasTime: true, now: now, calendar: cal)
        XCTAssertEqual(timed, date(2026, 10, 11, 9))
    }

    func testFirstOccurrence() {
        let r = Recurrence(frequency: .weekly, weekdays: [2])
        XCTAssertEqual(r.firstOccurrence(onOrAfter: date(2026, 10, 7), calendar: cal), date(2026, 10, 12))
        XCTAssertEqual(r.firstOccurrence(onOrAfter: date(2026, 10, 12, 10), calendar: cal), date(2026, 10, 12))
    }
}
