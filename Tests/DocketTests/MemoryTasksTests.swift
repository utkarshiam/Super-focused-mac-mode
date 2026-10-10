@testable import MemoryKit
import SwiftUI
import XCTest
@testable import Docket

/// Memory → tasks on the Mac: "Add as task" on a promise (the user's own: due on its date; someone else's: a
/// follow-up waiting on them), never twice; "Turn into tasks" adds what Gemini finds, linked back to the memory
/// and taking over matching promises; tasks remember their memory (and older files without it still load);
/// the Brief's question. Made-up names, temporary folders, a fake Gemini.
@MainActor
final class MemoryTasksTests: XCTestCase {
    var dir: URL!
    var store: Store!
    var library: MemoryLibrary!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("docket-memory-tasks-\(UUID().uuidString)")
        store = Store(persistence: Persistence(directory: dir.appendingPathComponent("Store")), seedIfEmpty: false)
        library = MemoryLibrary(directory: dir.appendingPathComponent("Memory"), saveDelay: 60)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private let cal = Calendar.current

    private func day(_ d: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: 10, day: d))! }

    private var meeting: MemoryItem {
        MemoryItem(title: "Seed round: investor feedback", people: ["Priya Shah", "Tom Becker"], projects: ["Seed round"],
                   organisations: ["Harbor Capital"],
                   moments: [Moment(kind: .promise, text: "Send Harbor Capital the CAC payback slide.", due: day(15).addingTimeInterval(3_600),
                                    direction: .mine),
                             Moment(kind: .promise, text: "Priya Shah sends a draft term sheet.", who: "Priya Shah", due: day(13),
                                    direction: .theirs),
                             Moment(kind: .decision, text: "Raise on a SAFE.")],
                   createdAt: day(9))
    }

    // MARK: Add as task

    func testMyPromiseIsATaskDueOnItsDateLinkedToTheMemory() {
        let item = meeting
        let mine = item.moments[0]
        let t = MemoryTasks.task(for: mine, in: item, calendar: cal)
        XCTAssertEqual(t.title, "Send Harbor Capital the CAC payback slide", "one line, no full stop")
        XCTAssertEqual(t.dueDate, day(15), "the day it's due")
        XCTAssertFalse(t.dueHasTime)
        XCTAssertNil(t.waitingOn)
        XCTAssertEqual(t.memoryID, item.id)
        XCTAssertEqual(t.momentID, mine.id)
        XCTAssertTrue(t.notes.hasPrefix("From memory: Seed round: investor feedback ("), t.notes)
        XCTAssertTrue(t.notes.contains("With Priya Shah, Tom Becker, Harbor Capital, Seed round"), "who and what it's about")
        XCTAssertFalse(t.notes.contains("Today") || t.notes.contains("Tomorrow"))
    }

    func testTheirPromiseIsAFollowUpWaitingOnThem() {
        let item = meeting
        let t = MemoryTasks.task(for: item.moments[1], in: item, calendar: cal)
        XCTAssertEqual(t.title, "Follow up: Priya Shah sends a draft term sheet")
        XCTAssertEqual(t.waitingOn, "Priya Shah")
        XCTAssertEqual(t.dueDate, day(13))
        XCTAssertTrue(t.notes.contains("With Priya Shah, Tom Becker"), "the person once")
    }

    func testAPromiseIsMadeIntoATaskOnce() {
        let item = meeting
        let promise = item.moments[0]
        XCTAssertNil(MemoryTasks.linkedTask(promise.id, in: store))
        let first = MemoryTasks.add(promise, in: item, store: store)
        let again = MemoryTasks.add(promise, in: item, store: store)
        XCTAssertEqual(first.id, again.id)
        XCTAssertEqual(store.tasks.count, 1)
        XCTAssertEqual(MemoryTasks.linkedTask(promise.id, in: store)?.id, first.id, "shown as “Task added · Open”")
        store.setCompleted(first.id, true)
        XCTAssertNotNil(MemoryTasks.linkedTask(promise.id, in: store), "done still counts")
        store.deleteTasks([first.id])
        XCTAssertNil(MemoryTasks.linkedTask(promise.id, in: store), "deleted: offered again")
    }

    func testToastsUseRealDates() {
        var t = TaskItem(title: "Send the slide")
        XCTAssertEqual(MemoryTasks.toast(t), "Added “Send the slide”")
        t.dueDate = day(15)
        XCTAssertEqual(MemoryTasks.toast(t, now: day(10)), "Added “Send the slide” for \(Fmt.absoluteDay(day(15), now: day(10)))")
    }

    func testATaskTitleTakesOverTheMatchingPromise() {
        let item = meeting
        XCTAssertEqual(MemoryTasks.promise(matching: "Send Harbor Capital the CAC payback slide", in: item, taken: [])?.id, item.moments[0].id)
        XCTAssertNil(MemoryTasks.promise(matching: "Send Harbor Capital the CAC payback slide", in: item, taken: [item.moments[0].id]))
        XCTAssertNil(MemoryTasks.promise(matching: "Book flights to NYC", in: item, taken: []))
    }

    // MARK: Tasks remember their memory

    func testTasksKeepTheirMemoryAndOlderFilesStillLoad() throws {
        var t = TaskItem(title: "Send the slide")
        t.memoryID = UUID()
        t.momentID = UUID()
        let back = try JSONDecoder().decode(TaskItem.self, from: JSONEncoder().encode(t))
        XCTAssertEqual(back.memoryID, t.memoryID)
        XCTAssertEqual(back.momentID, t.momentID)
        let old = try JSONDecoder().decode(TaskItem.self, from: Data(#"{"title": "From before"}"#.utf8))
        XCTAssertNil(old.memoryID)
        XCTAssertNil(old.momentID)
    }

    // MARK: Turn into tasks

    func testTurnIntoTasksAddsLinkedTasksWithMemoryContext() async throws {
        let intake = VoiceIntake(library: library, store: store)
        var contextAsked: [String] = []
        intake.memoryContext = { contextAsked.append($0); return "About the user:\n- Raising a seed round" }
        let answer = #"""
        {"tasks":[
          {"title":"Send Harbor Capital the CAC payback slide","notes":"","dueDate":"2026-10-15","dueTime":"","doOn":"","minutes":30,
           "reminderMinutes":-1,"alarm":false,"repeat":"","interval":1,"weekdays":[],"priority":0,"listName":"","tags":[],"waitingOn":""},
          {"title":"Check Priya Shah sent the term sheet","notes":"","dueDate":"2026-10-13","dueTime":"","doOn":"","minutes":0,
           "reminderMinutes":-1,"alarm":false,"repeat":"","interval":1,"weekdays":[],"priority":0,"listName":"","tags":[],"waitingOn":"Priya Shah"}
        ]}
        """#
        let ai = DocketFakeAI(answer: answer)
        intake.ai = { ai }
        let item = library.add(meeting)
        let dictation = TaskDictation(intake: intake)
        dictation.now = { self.day(10) }

        dictation.turnIntoTasks(item)
        XCTAssertEqual(dictation.phase, .working)
        XCTAssertEqual(dictation.memoryItemID, item.id)
        await dictation.waitUntilScheduled()
        XCTAssertEqual(dictation.phase, .result)
        XCTAssertEqual(store.tasks.count, 2)
        XCTAssertTrue(store.tasks.allSatisfy { $0.memoryID == item.id }, "linked back to the memory")
        let slide = try XCTUnwrap(store.tasks.first { $0.title.hasPrefix("Send Harbor") })
        XCTAssertEqual(slide.momentID, item.moments[0].id, "it is the promise: not offered again")
        XCTAssertEqual(slide.dueDate, day(15))
        XCTAssertNil(store.tasks.first { $0.title.hasPrefix("Check") }?.momentID)
        XCTAssertEqual(store.tasks.first { $0.title.hasPrefix("Check") }?.waitingOn, "Priya Shah")
        XCTAssertTrue(ai.lastSystem.contains("saved memories"))
        XCTAssertTrue(ai.lastSystem.hasSuffix("About the user:\n- Raising a seed round"))
        XCTAssertTrue(contextAsked.first?.hasPrefix("Seed round: investor feedback") == true)
        XCTAssertEqual(dictation.result?.taskIDs.count, 2)

        // Undo all takes them back, and the promise can be added again.
        dictation.undoAll()
        XCTAssertTrue(store.tasks.isEmpty)
        XCTAssertNil(MemoryTasks.linkedTask(item.moments[0].id, in: store))
    }

    func testTurnIntoTasksNeedsAKeyAndSaysWhenTheresNothing() async {
        let intake = VoiceIntake(library: library, store: store)
        let item = library.add(meeting)
        let dictation = TaskDictation(intake: intake)
        dictation.turnIntoTasks(item)
        XCTAssertEqual(dictation.phase, .failed(DictationText.memoryNeedsKey, privacy: nil))
        XCTAssertTrue(store.tasks.isEmpty)

        intake.ai = { DocketFakeAI(answer: #"{"tasks":[]}"#) }
        dictation.dismiss()
        dictation.turnIntoTasks(item)
        await dictation.waitUntilScheduled()
        XCTAssertEqual(dictation.phase, .failed(DictationText.memoryNoTask, privacy: nil))
    }

    func testDictatedTasksCarryMemoryContextOnlyWhenThereIsSome() async throws {
        let intake = VoiceIntake(library: library, store: store)
        let ai = DocketFakeAI(answer: TaskDictationTests.answer)
        intake.ai = { ai }
        let dictation = TaskDictation(intake: intake)
        dictation.submit("Call Rohan Friday at 3")
        await dictation.waitUntilScheduled()
        XCTAssertFalse(ai.lastSystem.contains("Context from the user's memory"), "nothing known: as before")
        XCTAssertNil(store.tasks.first?.memoryID, "dictated, not from a memory")

        intake.memoryContext = { _ in "People, organisations and projects in it:\n- Rohan Mehta (person)" }
        dictation.dismiss()
        dictation.submit("Call Rohan Friday at 4")
        await dictation.waitUntilScheduled()
        XCTAssertTrue(ai.lastSystem.hasSuffix("- Rohan Mehta (person)"))
    }

    // MARK: Brief

    func testBriefAsksWhatYouNeedToKnowAboutTheTask() {
        var t = TaskItem(title: "Send Jordan Lee the SOC 2 bridge letter")
        t.notes = "Acme renewal"
        t.waitingOn = "Jordan Lee"
        XCTAssertEqual(TaskBriefs.question(for: t), "What do I need to know to do: Send Jordan Lee the SOC 2 bridge letter?")
        XCTAssertEqual(TaskBriefs.about(t), "Send Jordan Lee the SOC 2 bridge letter\nAcme renewal\nWaiting on Jordan Lee")
        XCTAssertEqual(TaskBriefs.question(for: TaskItem(title: " ")), "What do I need to know to do: this task?")
    }
}
