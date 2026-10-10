@testable import MemoryKit
import XCTest

/// Dictated scheduling: deadline vs time slot vs "Do on", length, reminder or alarm, repeat, lists and tags, all
/// with real dates in the user's time zone; and the envelope carrying the parsed task to the Mac.
final class SpokenTasksTests: XCTestCase {
    let kolkata = TimeZone(identifier: "Asia/Kolkata")!

    /// Sat 10 Oct 2026, 11:20 in Kolkata.
    var now: Date {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = kolkata
        return c.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 11, minute: 20))!
    }

    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = kolkata
        return c
    }

    let answer = #"""
    {"tasks":[
      {"title":"Call Rohan Mehta about the quote","notes":"","dueDate":"2026-10-16","dueTime":"15:00","doOn":"","minutes":30,
       "reminderMinutes":15,"alarm":false,"repeat":"","interval":1,"weekdays":[],"priority":0,"listName":"work","tags":[],"waitingOn":""},
      {"title":"Finish the board deck","notes":"Use the September numbers","dueDate":"2026-10-23","dueTime":"","doOn":"2026-10-19","minutes":120,
       "reminderMinutes":-1,"alarm":false,"repeat":"","interval":1,"weekdays":[],"priority":3,"listName":"","tags":["Board"],"waitingOn":""},
      {"title":"Team standup","notes":"","dueDate":"2026-10-12","dueTime":"09:30","doOn":"","minutes":15,
       "reminderMinutes":0,"alarm":true,"repeat":"weekly","interval":0,"weekdays":[2,3,4,5,6,9],"priority":0,"listName":"","tags":[],"waitingOn":""},
      {"title":"","notes":"","dueDate":"","dueTime":"","doOn":"","minutes":0,"reminderMinutes":-1,"alarm":false,"repeat":"","interval":1,
       "weekdays":[],"priority":0,"listName":"","tags":[],"waitingOn":""}
    ]}
    """#

    func testParseSchedulesWithRealDatesRemindersAndRepeats() throws {
        let tasks = try SpokenTaskParser.parse(Data(answer.utf8), now: now, timeZone: kolkata, listNames: ["Work", "Personal"])
        XCTAssertEqual(tasks.count, 3, "blank titles dropped")

        let call = tasks[0]
        XCTAssertTrue(call.dueHasTime)
        XCTAssertEqual(calendar.dateComponents([.month, .day, .hour, .minute], from: call.dueDate!), DateComponents(month: 10, day: 16, hour: 15, minute: 0))
        XCTAssertEqual(call.estimateMinutes, 30)
        XCTAssertEqual(call.reminderMinutes, 15)
        XCTAssertEqual(call.listName, "Work", "the user's spelling")

        let deck = tasks[1]
        XCTAssertFalse(deck.dueHasTime)
        XCTAssertEqual(calendar.component(.day, from: deck.dueDate!), 23)
        XCTAssertEqual(calendar.component(.day, from: deck.scheduledDate!), 19, "Do on is separate from the deadline")
        XCTAssertNil(deck.reminderMinutes, "-1 means none asked: the app's default applies")
        XCTAssertEqual(deck.priority, 3)
        XCTAssertEqual(deck.tags, ["board"])

        let standup = tasks[2]
        XCTAssertTrue(standup.isAlarm)
        XCTAssertEqual(standup.reminderMinutes, 0)
        XCTAssertEqual(standup.repeatRule, TaskRepeat(frequency: .weekly, interval: 1, weekdays: [2, 3, 4, 5, 6]), "bad weekday and interval cleaned")
        XCTAssertEqual(standup.repeatRule?.label, "every weekday")
    }

    func testParserSendsNowListsAndWords() async throws {
        let ai = FakeAI(onGenerate: { _ in Data(self.answer.utf8) })
        let parser = SpokenTaskParser(ai: ai, listNames: ["Work"], knownPeople: ["Rohan Mehta"], timeZone: kolkata)
        let tasks = try await parser.parse("Rohan ko Friday 3 baje call karna hai, half an hour, remind me 15 min pehle", now: now)
        XCTAssertEqual(tasks.count, 3)
        let call = try XCTUnwrap(ai.generateCalls.first)
        XCTAssertTrue(call.prompt.contains("Saturday 10 October 2026, 11:20"), call.prompt)
        XCTAssertTrue(call.prompt.contains("Lists: Work"))
        XCTAssertTrue(call.prompt.contains("Rohan ko Friday 3 baje"))
        XCTAssertTrue(call.parts.isEmpty)
    }

    func testEmptyDictationThrowsWithoutCallingGemini() async {
        let ai = FakeAI()
        do {
            _ = try await SpokenTaskParser(ai: ai).parse("   ", now: now)
            XCTFail("should throw")
        } catch {}
        XCTAssertTrue(ai.generateCalls.isEmpty)
    }

    func testRepeatLabels() {
        XCTAssertEqual(TaskRepeat(frequency: .daily).label, "every day")
        XCTAssertEqual(TaskRepeat(frequency: .weekly, interval: 2).label, "every 2 weeks")
        XCTAssertEqual(TaskRepeat(frequency: .weekly, weekdays: [3, 5]).label, "every week on Tue, Thu")
        XCTAssertEqual(TaskRepeat(frequency: .monthly).label, "every month")
    }

    func testTaskEnvelopeCarriesTheParsedTask() throws {
        let parsed = try SpokenTaskParser.parse(Data(answer.utf8), now: now, timeZone: kolkata)[0]
        let env = CaptureEnvelope(kind: .task, title: parsed.title, task: parsed)
        let back = try MemoryCoding.decoder.decode(CaptureEnvelope.self, from: MemoryCoding.encoder.encode(env))
        XCTAssertEqual(back.task, parsed)
        let old = try MemoryCoding.decoder.decode(DebriefTask.self, from: Data(#"{"title":"Old phone task"}"#.utf8))
        XCTAssertNil(old.repeatRule)
        XCTAssertFalse(old.isAlarm)
        XCTAssertEqual(old.tags, [])
    }
}
