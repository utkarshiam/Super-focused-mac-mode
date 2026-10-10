@testable import MemoryKit
import XCTest
@testable import Docket

/// Docket Memory's Mac plumbing: what's remembered by itself, the phone's task envelopes and task list, and
/// importing from ENGRAM. Everything runs on temporary folders (never the real library or iCloud Drive).
@MainActor
final class MemoryCaptureTests: XCTestCase {
    var dir: URL!
    var store: Store!
    var library: MemoryLibrary!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("docket-memory-capture-\(UUID().uuidString)")
        store = Store(persistence: Persistence(directory: dir.appendingPathComponent("Store")), seedIfEmpty: false)
        library = MemoryLibrary(directory: dir.appendingPathComponent("Memory"), saveDelay: 60)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeCapture(notes: Bool = true, tasks: Bool = true) -> MemoryAutoCapture {
        let capture = MemoryAutoCapture(library: library, store: store, noteDelay: 0.05)
        capture.switches = { MemoryAutoCapture.Switches(notes: notes, tasks: tasks) }
        return capture
    }

    private func settle() async throws {
        try await Task.sleep(nanoseconds: 250_000_000)
    }

    private let longNote = "# Board prep\nWalk through the Q3 numbers with Priya and agree the hiring plan before Friday."

    /// Wednesday 7 October 2026, 9:00 here.
    private var wednesday: Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 9))!
    }

    // MARK: Notes

    func testNoteIsRememberedOnceEditsSettleThenUpdatedThenForgotten() async throws {
        let capture = makeCapture()
        let note = store.addNote(body: longNote)
        let ref = SourceRef.note(note.id)
        XCTAssertNil(library.item(sourceRef: ref), "not while still being written")

        try await settle()
        let item = try XCTUnwrap(library.item(sourceRef: ref))
        XCTAssertEqual(item.kind, .note)
        XCTAssertEqual(item.origin, .auto)
        XCTAssertEqual(item.title, "Board prep")
        XCTAssertEqual(item.body, longNote)
        XCTAssertEqual(item.capturedFrom, "Notes")

        store.updateNoteBody(note.id, longNote + "\nAlso: book the room.")
        try await settle()
        let updated = try XCTUnwrap(library.item(sourceRef: ref))
        XCTAssertEqual(updated.id, item.id, "the same memory, updated")
        XCTAssertTrue(updated.body.hasSuffix("book the room."))
        XCTAssertEqual(library.count, 1)

        // Re-flowing whitespace isn't a change worth processing again.
        let stamp = updated.updatedAt
        store.updateNoteBody(note.id, updated.body.replacingOccurrences(of: "\n", with: "\n\n"))
        try await settle()
        XCTAssertEqual(library.item(sourceRef: ref)?.updatedAt, stamp)

        store.deleteNote(note.id)
        try await settle()
        XCTAssertNil(library.item(sourceRef: ref))
        XCTAssertEqual(library.count, 0)
        _ = capture
    }

    func testNotesFromBeforeLaunchWaitForAnEdit() {
        let old = store.addNote(body: longNote)
        let capture = makeCapture()
        capture.notesSettled(store.notes)
        XCTAssertNil(library.item(sourceRef: SourceRef.note(old.id)), "already there at launch: not new work")

        store.updateNoteBody(old.id, longNote + " Send the deck to Lena.")
        capture.notesSettled(store.notes)
        XCTAssertNotNil(library.item(sourceRef: SourceRef.note(old.id)))
    }

    func testShortEmptyAndTemplateNotesAreLeftOut() {
        func action(_ body: String, previous: String? = nil, remembered: Bool = false) -> MemoryAutoCapture.NoteAction {
            var note = Note(body: body)
            note.createdAt = wednesday
            return MemoryAutoCapture.noteAction(note, previous: previous, remembered: remembered)
        }
        XCTAssertEqual(action(""), .none)
        XCTAssertEqual(action("   \n"), .none)
        XCTAssertEqual(action("Call Sam"), .none, "too short")
        XCTAssertEqual(action(NoteTemplate.daily.body(for: wednesday)), .none, "an untouched template")
        XCTAssertEqual(action(NoteTemplate.guideBody), .none)
        XCTAssertEqual(action(longNote), .remember)
        XCTAssertEqual(action(longNote, previous: longNote), .none, "unchanged")
        XCTAssertEqual(action(longNote, previous: "  " + longNote.replacingOccurrences(of: " ", with: "   ")), .none, "only spacing changed")
        XCTAssertEqual(action("", remembered: true), .forget, "emptied: forgotten")
    }

    func testSwitchedOffAndSkippedNotesAreNotRemembered() {
        let off = makeCapture(notes: false)
        let note = store.addNote(body: longNote)
        off.notesSettled(store.notes)
        XCTAssertNil(library.item(sourceRef: SourceRef.note(note.id)))

        let on = makeCapture()
        let fromMessage = store.addNote(body: longNote + " (from Slack)")
        on.skipNote(fromMessage.id)
        on.notesSettled(store.notes)
        XCTAssertNil(library.item(sourceRef: SourceRef.note(fromMessage.id)), "remembered as the message instead")
    }

    // MARK: Tasks

    func testBackfillAddsExistingNotesAndRecentlyFinishedTasksOnce() {
        let note = store.addNote(body: longNote)
        let short = store.addNote(body: "Call Sam")
        var recent = TaskItem(title: "Ship the pricing page")
        recent.completedAt = Date().addingTimeInterval(-3 * 86_400)
        var old = TaskItem(title: "Renew the domain")
        old.completedAt = Date().addingTimeInterval(-200 * 86_400)
        let open = store.addTask(TaskItem(title: "Draft the board memo"))
        let recentID = store.addTask(recent).id, oldID = store.addTask(old).id

        let capture = makeCapture()
        XCTAssertEqual(capture.backfill(), 2)
        XCTAssertNotNil(library.item(sourceRef: SourceRef.note(note.id)))
        XCTAssertNil(library.item(sourceRef: SourceRef.note(short.id)), "too short, same rule as new notes")
        XCTAssertNotNil(library.item(sourceRef: SourceRef.task(recentID)))
        XCTAssertNil(library.item(sourceRef: SourceRef.task(oldID)), "finished more than 90 days ago")
        XCTAssertNil(library.item(sourceRef: SourceRef.task(open.id)), "not finished")
        XCTAssertEqual(capture.backfill(), 0, "running again adds nothing twice")
        XCTAssertEqual(makeCapture(notes: false, tasks: false).backfill(), 0)
    }

    func testCompletedTaskIsRememberedAndForgottenWhenReopened() throws {
        let capture = makeCapture()
        let list = store.addList(name: "Fundraising", color: ListColor.allCases[0])
        var t = TaskItem(title: "Send the deck to Harbor Capital")
        t.notes = "Use the September numbers"
        t.listID = list.id
        t.tags = ["investors"]
        t.waitingOn = "Priya"
        let task = store.addTask(t)
        XCTAssertNil(library.item(sourceRef: SourceRef.task(task.id)))

        store.setCompleted(task.id, true)
        let item = try XCTUnwrap(library.item(sourceRef: SourceRef.task(task.id)))
        XCTAssertEqual(item.kind, .task)
        XCTAssertEqual(item.origin, .auto)
        XCTAssertTrue(item.lightweight, "embedded only, no extraction")
        XCTAssertEqual(item.title, "Send the deck to Harbor Capital")
        XCTAssertEqual(item.body, "Use the September numbers")
        XCTAssertEqual(item.projects, ["Fundraising"])
        XCTAssertEqual(item.tags, ["investors"])
        XCTAssertEqual(item.people, ["Priya"])
        XCTAssertEqual(item.capturedFrom, "Tasks · Fundraising")
        XCTAssertEqual(item.createdAt, store.task(task.id)?.completedAt, "dated when it was done")

        store.setCompleted(task.id, false)
        XCTAssertNil(library.item(sourceRef: SourceRef.task(task.id)))
        _ = capture
    }

    func testOldCompletionsAndSwitchedOffTasksAreNotRemembered() {
        let capture = makeCapture()
        var imported = TaskItem(title: "Done long ago")
        imported.completedAt = Date().addingTimeInterval(-2 * 86_400)
        store.addTask(imported)
        XCTAssertEqual(library.count, 0, "an import or undo isn't work just finished")

        capture.switches = { MemoryAutoCapture.Switches(notes: true, tasks: false) }
        let task = store.addTask(TaskItem(title: "Quiet one"))
        store.setCompleted(task.id, true)
        XCTAssertEqual(library.count, 0)
    }

    // MARK: Phone tasks

    func testTaskEnvelopeBecomesATask() throws {
        let due = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 15, minute: 30))!
        XCTAssertTrue(PhoneSync.apply(CaptureEnvelope(kind: .task, title: "Call the bank", text: "About the loan", due: due), to: store, now: wednesday))
        let dated = try XCTUnwrap(store.tasks.first { $0.title == "Call the bank" })
        XCTAssertEqual(dated.dueDate, Calendar.current.startOfDay(for: due), "a date without a time is the day")
        XCTAssertFalse(dated.dueHasTime)
        XCTAssertEqual(dated.notes, "About the loan")

        // No date sent: read from the title as quick add would.
        XCTAssertTrue(PhoneSync.apply(CaptureEnvelope(kind: .task, title: "Send deck fri 3pm"), to: store, now: wednesday))
        let parsed = try XCTUnwrap(store.tasks.first { $0.title == "Send deck" })
        let expected = QuickParser(now: wednesday, lists: store.lists, workdayEndMinutes: Prefs.workdayEnd).parse("Send deck fri 3pm")
        XCTAssertTrue(parsed.dueHasTime)
        XCTAssertEqual(parsed.dueDate, expected.dueDate)
        XCTAssertEqual(Calendar.current.component(.weekday, from: try XCTUnwrap(parsed.dueDate)), 6, "a Friday")
        XCTAssertEqual(Calendar.current.component(.hour, from: try XCTUnwrap(parsed.dueDate)), 15)

        XCTAssertTrue(PhoneSync.apply(CaptureEnvelope(kind: .task, title: "  "), to: store, now: wednesday), "nothing to add: dealt with")
        XCTAssertEqual(store.tasks.count, 2)
        XCTAssertFalse(PhoneSync.apply(CaptureEnvelope(kind: .note, text: "Not a task"), to: store, now: wednesday))
    }

    func testTaskEnvelopeKeepsThePhonesIDOnce() {
        let env = CaptureEnvelope(kind: .task, title: "Send revised quote to Rohan Mehta")
        XCTAssertTrue(PhoneSync.apply(env, to: store, now: wednesday))
        XCTAssertEqual(store.task(env.id)?.title, "Send revised quote to Rohan Mehta", "same id the phone shows")
        XCTAssertTrue(PhoneSync.apply(env, to: store, now: wednesday))
        XCTAssertEqual(store.tasks.filter { $0.id == env.id }.count, 1, "a repeat isn't added twice")
    }

    func testTaskDoneEnvelopeCompletesTheTask() {
        let task = store.addTask(TaskItem(title: "Water the plants"))
        XCTAssertTrue(PhoneSync.apply(CaptureEnvelope(kind: .taskDone, taskID: task.id), to: store))
        XCTAssertTrue(store.task(task.id)?.isCompleted == true)
        XCTAssertTrue(PhoneSync.apply(CaptureEnvelope(kind: .taskDone, taskID: UUID()), to: store), "a task that's gone counts as done")
    }

    func testIngestFromTheFolderAddsTasksAndMemories() throws {
        let root = dir.appendingPathComponent("Phone")
        let bridge = PhoneBridge(root: root)
        try bridge.writeCapture(CaptureEnvelope(kind: .task, title: "Book flights"))
        try bridge.writeCapture(CaptureEnvelope(kind: .note, text: "Lena prefers async updates on Fridays"))
        let report = bridge.ingest(into: library, now: Date().addingTimeInterval(10)) { PhoneSync.apply($0, to: self.store) }
        XCTAssertEqual(report.tasksHandled, 1)
        XCTAssertEqual(report.itemIDs.count, 1)
        XCTAssertEqual(store.tasks.map(\.title), ["Book flights"])
        XCTAssertEqual(library.items.first?.origin, .phone)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: bridge.inboxURL.path), [], "the inbox is emptied")
    }

    // MARK: Phone task list

    func testSnapshotHasOverdueTodayAndTheNextSevenDaysThenTodaysDone() {
        let cal = Calendar.current
        let now = wednesday
        let today = cal.startOfDay(for: now)
        func day(_ offset: Int) -> Date { cal.date(byAdding: .day, value: offset, to: today)! }
        func add(_ title: String, due: Date? = nil, hasTime: Bool = false, planned: Date? = nil, done: Date? = nil) {
            var t = TaskItem(title: title)
            t.dueDate = due
            t.dueHasTime = hasTime
            t.scheduledDate = planned
            t.completedAt = done
            store.addTask(t)
        }
        add("Later", due: day(10))
        add("Someday")
        add("In three days", due: day(3))
        add("Planned today", planned: today)
        add("Meeting at 2", due: cal.date(byAdding: .hour, value: 14, to: today), hasTime: true)
        add("Overdue", due: day(-2))
        add("Next week edge", due: day(7))
        add("Done today", due: today, done: now)
        add("Done yesterday", due: day(-1), done: day(-1))

        let tasks = PhoneSync.snapshotTasks(store, now: now)
        XCTAssertEqual(tasks.map(\.title), ["Overdue", "Planned today", "Meeting at 2", "In three days", "Next week edge", "Done today"])
        XCTAssertEqual(tasks.first?.dueDate, day(-2), "real dates, not relative ones")
        XCTAssertEqual(tasks.last?.done, true)
        XCTAssertTrue(tasks.dropLast().allSatisfy { !$0.done })
        XCTAssertEqual(tasks.first { $0.title == "Meeting at 2" }?.dueHasTime, true)
    }

    // MARK: Messages

    func testMessageMemoryKeepsTheSummaryWhoAndWhere() {
        let received = wednesday
        let s = Suggestion(source: TaskSource(kind: .slack, externalID: "slack:C024BE91L/1712345700.000200",
                                              url: URL(string: "https://acme.slack.com/archives/C024BE91L/p1712345700000200"),
                                              label: "#leadership · Priya Shah"),
                           from: "Priya Shah", subject: nil, snippet: "Can you send the deck?", receivedAt: received,
                           threadTS: "1712345678.000100")
        let summary = ThreadSummary(SummaryText(bullets: ["Priya needs the Q3 deck", "Board meets Friday"], needsFromYou: "Send the deck"),
                                    fingerprint: "2-x", madeAt: received)
        let thread = [
            ThreadMessage(id: "1712345678.000100", from: "Sam Lee", date: received.addingTimeInterval(-600), text: "Board is Friday.", isMine: false),
            ThreadMessage(id: "1712345700.000200", from: "Priya Shah", date: received, text: "Can you send the deck?", isMine: false),
        ]
        let item = MessageMemory.item(for: s, summary: summary, thread: thread, reply: "Sending it tonight", origin: .manual)
        XCTAssertEqual(item.kind, .message)
        XCTAssertEqual(item.sourceRef, SourceRef.slack(channel: "C024BE91L", ts: "1712345678.000100"), "one memory per thread")
        XCTAssertEqual(item.capturedFrom, "Slack #leadership")
        XCTAssertEqual(item.title, "#leadership · Priya Shah")
        XCTAssertEqual(item.people, ["Priya Shah", "Sam Lee"])
        XCTAssertEqual(item.createdAt, thread[0].date)
        XCTAssertTrue(item.body.hasPrefix("- Priya needs the Q3 deck\n- Board meets Friday\n\nNeeds from you: Send the deck"))
        XCTAssertTrue(item.body.contains("Sam Lee, \(MemoryDates.label(thread[0].date)): Board is Friday."))
        XCTAssertTrue(item.body.hasSuffix("You replied: Sending it tonight"))

        // Remembering it again updates the same memory.
        library.add(item)
        library.add(MessageMemory.item(for: s, summary: nil, thread: thread, origin: .auto))
        XCTAssertEqual(library.count, 1)

        let email = Suggestion(source: TaskSource(kind: .gmail, externalID: "gmail:18c2f/18c30", url: nil, label: "Sam Lee · Contract"),
                               from: "Sam Lee <sam@northwind.example>", subject: "Re: Contract", snippet: "See the redlines", receivedAt: received)
        let mail = MessageMemory.item(for: email, summary: nil, thread: nil, origin: .auto)
        XCTAssertEqual(mail.sourceRef, SourceRef.gmail(threadID: "18c2f"))
        XCTAssertEqual(mail.capturedFrom, "Email")
        XCTAssertEqual(mail.people, ["Sam Lee"])
        XCTAssertTrue(mail.body.contains("See the redlines"))
    }

    // MARK: ENGRAM

    func testEngramImportThroughMemoryCenter() throws {
        let center = MemoryCenter(directory: dir.appendingPathComponent("Center"))
        center.processor.ai = nil
        let file = dir.appendingPathComponent("engram-export.json")
        let json = #"""
        {"app": "ENGRAM", "exportedAt": "2026-09-30T10:00:00.000Z",
         "entries": [
           {"id": "e1", "title": "Seed pitch feedback", "summary": "Priya liked the retention story.",
            "originalContent": "Met Priya Shah. She liked retention.", "contentType": "text", "keyTakeaways": [], "createdAt": 1758000000000},
           {"id": "e2", "title": "Pricing", "summary": "Three tiers convert best.", "originalContent": "Three tiers.",
            "contentType": "text", "keyTakeaways": [], "createdAt": 1757000000000}
         ],
         "entities": [], "relationships": []}
        """#
        try Data(json.utf8).write(to: file)

        let first = try center.importEngram(from: file)
        XCTAssertEqual(first.imported, 2)
        XCTAssertEqual(MemoryCenter.importLine(first), "Imported 2 memories")
        XCTAssertNotNil(center.library.item(sourceRef: SourceRef.engram("e1")))

        let again = try center.importEngram(from: file)
        XCTAssertEqual(again.imported, 0)
        XCTAssertEqual(again.skippedDuplicates, 2)
        XCTAssertEqual(MemoryCenter.importLine(again), "Nothing new: 2 memories already here")
        XCTAssertEqual(center.library.count, 2)

        var mixed = EngramImporter.Report()
        mixed.imported = 412
        mixed.skippedDuplicates = 3
        XCTAssertEqual(MemoryCenter.importLine(mixed), "Imported 412 memories (3 already here)")

        try Data("{\"notes\": []}".utf8).write(to: file)
        XCTAssertThrowsError(try center.importEngram(from: file))
        center.processor.cancelAll()
    }
}
