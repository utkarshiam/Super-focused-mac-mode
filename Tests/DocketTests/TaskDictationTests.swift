@testable import MemoryKit
import SwiftUI
import XCTest
@testable import Docket

/// Scheduling by voice on the Mac: a dictated (or phone-parsed) task becomes a Store task with every field it was
/// given (deadline vs "Do on", reminder nil / 0 / 15 / none, alarm, repeat, tags, list); the page fills in what
/// wasn't said; `.task` envelopes carrying the parsed task keep the phone's id once; the phone's snapshot shows
/// repeat, reminder and alarm; the result's ✕ and Undo all; when listening stops by itself. No microphone,
/// no network: a fake Gemini and temporary folders.
@MainActor
final class TaskDictationTests: XCTestCase {
    var dir: URL!
    var store: Store!
    var library: MemoryLibrary!
    var intake: VoiceIntake!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("docket-dictation-\(UUID().uuidString)")
        store = Store(persistence: Persistence(directory: dir.appendingPathComponent("Store")), seedIfEmpty: false)
        library = MemoryLibrary(directory: dir.appendingPathComponent("Memory"), saveDelay: 60)
        intake = VoiceIntake(library: library, store: store)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private let cal = Calendar.current

    /// Sat 10 Oct 2026, 11:20 here.
    private var now: Date { cal.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 11, minute: 20))! }

    private func day(_ d: Int, hour: Int? = nil, minute: Int = 0) -> Date {
        var c = DateComponents(year: 2026, month: 10, day: d)
        if let hour { c.hour = hour; c.minute = minute }
        return cal.date(from: c)!
    }

    private func make(_ t: DebriefTask, defaultReminder: Int = 10, defaultIsAlarm: Bool = false) -> TaskItem {
        VoiceIntake.task(from: t, recordedAt: now, store: store, fromVoiceNote: false, defaultReminder: defaultReminder,
                         defaultIsAlarm: defaultIsAlarm, allDayHour: 9)
    }

    private func minutesBefore(_ t: TaskItem) -> [Int] {
        t.reminders.compactMap { if case .beforeDue(let m) = $0.trigger { return m } else { return nil } }
    }

    // MARK: DebriefTask → TaskItem

    func testDoOnIsThePlanDayAndNeverMovesTheDeadline() {
        let t = make(DebriefTask(title: "Finish the board deck", notes: "Use the September numbers", dueDate: day(23),
                                 scheduledDate: day(19, hour: 14)))
        XCTAssertEqual(t.dueDate, day(23), "the deadline as said")
        XCTAssertFalse(t.dueHasTime)
        XCTAssertEqual(t.scheduledDate, day(19), "Do on is a day")
        XCTAssertEqual(t.notes, "Use the September numbers", "no voice-note header for dictated tasks")
        XCTAssertTrue(t.reminders.isEmpty, "all day, nothing asked: no default reminder")
    }

    func testReminderNilZeroFifteenAndNone() {
        let at3 = day(16, hour: 15)
        // Nothing asked: the app's default, for a task with a time only.
        XCTAssertEqual(minutesBefore(make(DebriefTask(title: "Call Rohan", dueDate: at3, dueHasTime: true))), [10])
        XCTAssertEqual(minutesBefore(make(DebriefTask(title: "Call Rohan", dueDate: at3, dueHasTime: true), defaultReminder: -1)), [],
                       "default reminder off in Settings")
        XCTAssertEqual(minutesBefore(make(DebriefTask(title: "Pay rent", dueDate: day(16)))), [])
        // Asked: exactly that, timed or all day.
        XCTAssertEqual(minutesBefore(make(DebriefTask(title: "Call Rohan", dueDate: at3, dueHasTime: true, reminderMinutes: 0))), [0])
        let fifteen = make(DebriefTask(title: "Call Rohan", dueDate: at3, dueHasTime: true, reminderMinutes: 15))
        XCTAssertEqual(minutesBefore(fifteen), [15])
        XCTAssertFalse(fifteen.hasAlarm)
        XCTAssertEqual(fifteen.reminders.first?.fireDate(for: fifteen, allDayHour: 9), day(16, hour: 14, minute: 45))
        let allDay = make(DebriefTask(title: "Pay rent", dueDate: day(16), reminderMinutes: 60))
        XCTAssertEqual(allDay.reminders.first?.fireDate(for: allDay, allDayHour: 9), day(16, hour: 8), "an hour before the all-day hour")
        // Below 0: the phone's "None": no reminder, not even the default.
        XCTAssertEqual(make(DebriefTask(title: "Call Rohan", dueDate: at3, dueHasTime: true, reminderMinutes: -1)).reminders, [])
        XCTAssertEqual(make(DebriefTask(title: "Call Rohan", dueDate: at3, dueHasTime: true, reminderMinutes: -1, isAlarm: true)).reminders, [])
    }

    func testAlarm() {
        let standup = make(DebriefTask(title: "Standup", dueDate: day(12, hour: 9, minute: 30), dueHasTime: true,
                                       reminderMinutes: 5, isAlarm: true))
        XCTAssertEqual(minutesBefore(standup), [5])
        XCTAssertTrue(standup.hasAlarm)
        // "Alarm" with no lead: the default lead for a timed task, the all-day hour for a day.
        let timed = make(DebriefTask(title: "Flight", dueDate: day(12, hour: 6), dueHasTime: true, isAlarm: true))
        XCTAssertEqual(minutesBefore(timed), [10])
        XCTAssertTrue(timed.hasAlarm)
        let allDay = make(DebriefTask(title: "Renew passport", dueDate: day(12), isAlarm: true))
        XCTAssertEqual(minutesBefore(allDay), [0])
        XCTAssertTrue(allDay.hasAlarm)
        // No deadline but a "Do on" day: it rings that morning.
        let planned = make(DebriefTask(title: "Draft the memo", scheduledDate: day(14), reminderMinutes: 0, isAlarm: true))
        XCTAssertNil(planned.dueDate)
        XCTAssertEqual(planned.reminders.first?.trigger, .absolute(day(14, hour: 9)))
        XCTAssertTrue(planned.hasAlarm)
        XCTAssertEqual(make(DebriefTask(title: "Someday", reminderMinutes: 15)).reminders, [], "nothing to remind against")
    }

    func testRepeatWeekdaysIntervalAndAFirstDay() {
        let weekdays = make(DebriefTask(title: "Standup", dueDate: day(12, hour: 9, minute: 30), dueHasTime: true,
                                        repeatRule: TaskRepeat(frequency: .weekly, weekdays: [2, 3, 4, 5, 6])))
        XCTAssertEqual(weekdays.recurrence, .weekdaysOnly)
        XCTAssertEqual(weekdays.recurrence?.summary, "Every weekday")
        let fortnightly = make(DebriefTask(title: "Payroll", dueDate: day(16), repeatRule: TaskRepeat(frequency: .weekly, interval: 2)))
        XCTAssertEqual(fortnightly.recurrence, .biweekly)
        let monthly = make(DebriefTask(title: "Invoices", dueDate: day(31), repeatRule: TaskRepeat(frequency: .monthly, weekdays: [2])))
        XCTAssertEqual(monthly.recurrence, .monthly, "weekdays only for weekly rules")
        // A repeat with no date starts on its first day (Monday 12 Oct from Saturday).
        let noDate = make(DebriefTask(title: "Weekly planning", repeatRule: TaskRepeat(frequency: .weekly, weekdays: [2])))
        XCTAssertEqual(noDate.dueDate, day(12))
        XCTAssertFalse(noDate.dueHasTime)
        // Round trip with the phone's rule.
        let rule = TaskRepeat(frequency: .weekly, interval: 3, weekdays: [3, 5])
        XCTAssertEqual(Recurrence(rule).taskRepeat, rule)
    }

    func testTagsListLengthPriorityWaiting() {
        let work = store.addList(name: "Work", color: .blue)
        let t = make(DebriefTask(title: "  Chase the samples ", dueDate: day(14), estimateMinutes: 45, priority: 3, waitingOn: " Priya ",
                                 listName: "work", tags: ["Finance", "finance", " ", "q4"]))
        XCTAssertEqual(t.title, "Chase the samples")
        XCTAssertEqual(t.listID, work.id, "list matched without case")
        XCTAssertEqual(t.tags, ["finance", "q4"])
        XCTAssertEqual(t.estimateMinutes, 45)
        XCTAssertEqual(t.priority, .high)
        XCTAssertEqual(t.waitingOn, "Priya")
        XCTAssertNil(make(DebriefTask(title: "Nowhere", listName: "Gym")).listID, "no such list: Inbox")
    }

    func testVoiceNoteTasksAreUnchanged() {
        let t = VoiceIntake.task(from: DebriefTask(title: "Call Anil", dueDate: day(11, hour: 15), dueHasTime: true),
                                 recordedAt: now, store: store, defaultReminder: 10, defaultIsAlarm: true)
        XCTAssertTrue(t.notes.hasPrefix("From your voice note"))
        XCTAssertEqual(minutesBefore(t), [10])
        XCTAssertTrue(t.hasAlarm, "the default's kind")
        XCTAssertNil(t.recurrence)
        XCTAssertNil(t.scheduledDate)
    }

    // MARK: The page's defaults

    func testWhatWasntSaidComesFromThePage() {
        let work = store.addList(name: "Work", color: .blue)
        let home = store.addList(name: "Home", color: .green)
        let plain = DebriefTask(title: "Book the venue")
        let onList = TaskDictation.task(from: plain, context: AddContext(listID: work.id, tag: "offsite", minimumPriority: .high),
                                        store: store, now: now, defaultReminder: 10)
        XCTAssertEqual(onList.listID, work.id)
        XCTAssertEqual(onList.tags, ["offsite"])
        XCTAssertEqual(onList.priority, .high)
        XCTAssertNil(onList.scheduledDate)
        let said = TaskDictation.task(from: DebriefTask(title: "Fix the tap", listName: "Home"), context: AddContext(listID: work.id),
                                      store: store, now: now)
        XCTAssertEqual(said.listID, home.id, "a list that was said wins")
        // The Calendar's day plans an undated task, never in the past; a dated one keeps its date.
        let calendarDay = TaskDictation.task(from: plain, context: AddContext(day: day(13)), store: store, now: now)
        XCTAssertEqual(calendarDay.scheduledDate, day(13))
        XCTAssertNil(calendarDay.dueDate)
        XCTAssertEqual(TaskDictation.task(from: plain, context: AddContext(day: day(2)), store: store, now: now).scheduledDate, day(10))
        let dated = TaskDictation.task(from: DebriefTask(title: "Pay rent", dueDate: day(16)), context: AddContext(day: day(13)),
                                       store: store, now: now)
        XCTAssertNil(dated.scheduledDate)
    }

    // MARK: Phone envelopes

    func testTaskEnvelopeWithAParsedTask() throws {
        let work = store.addList(name: "Work", color: .blue)
        let ledger = intake.ledger
        let spoken = DebriefTask(id: UUID(), title: "Team standup", dueDate: day(12, hour: 9, minute: 30), dueHasTime: true,
                                 estimateMinutes: 15, listName: "Work", scheduledDate: nil, reminderMinutes: 0, isAlarm: true,
                                 repeatRule: TaskRepeat(frequency: .weekly, weekdays: [2, 3, 4, 5, 6]), tags: ["team"])
        let env = CaptureEnvelope(kind: .task, createdAt: now, title: "Team standup", task: spoken)
        XCTAssertTrue(PhoneSync.apply(env, to: store, ledger: ledger, now: now))
        let t = try XCTUnwrap(store.task(env.id), "the envelope's id, not the payload's")
        XCTAssertNil(store.task(spoken.id))
        XCTAssertEqual(t.dueDate, day(12, hour: 9, minute: 30))
        XCTAssertTrue(t.dueHasTime)
        XCTAssertEqual(t.estimateMinutes, 15)
        XCTAssertEqual(t.listID, work.id)
        XCTAssertEqual(minutesBefore(t), [0])
        XCTAssertTrue(t.hasAlarm)
        XCTAssertEqual(t.recurrence, .weekdaysOnly)
        XCTAssertEqual(t.tags, ["team"])
        XCTAssertTrue(ledger.taskIDs(since: now.addingTimeInterval(-60)).contains(env.id), "on the phone's list whatever its date")
        XCTAssertTrue(VoiceLedger(fileURL: ledger.fileURL).taskIDs(since: now.addingTimeInterval(-60)).contains(env.id), "saved")

        // Again: nothing new. Deleted: never back.
        XCTAssertTrue(PhoneSync.apply(env, to: store, ledger: ledger, now: now))
        XCTAssertEqual(store.tasks.count, 1)
        XCTAssertTrue(PhoneSync.apply(CaptureEnvelope(kind: .taskDelete, taskID: env.id), to: store, ledger: ledger, now: now))
        XCTAssertTrue(PhoneSync.apply(env, to: store, ledger: ledger, now: now))
        XCTAssertTrue(store.tasks.isEmpty)
    }

    func testTaskEnvelopeReminderNoneAndAnUnscheduledPayload() throws {
        // "None" picked on the phone: no reminder, not even the default.
        let none = CaptureEnvelope(kind: .task, createdAt: now, title: "Call the bank",
                                   task: DebriefTask(title: "Call the bank", dueDate: day(16, hour: 15), dueHasTime: true, reminderMinutes: -1))
        PhoneSync.apply(none, to: store, now: now)
        XCTAssertEqual(store.task(none.id)?.reminders, [])

        // No date in the payload (no key on the phone, or Siri): quick add reads the title; the rest is kept.
        let personal = store.addList(name: "Personal", color: .green)
        let siri = CaptureEnvelope(kind: .task, createdAt: now, title: "call bank fri 3pm",
                                   task: DebriefTask(title: "call bank fri 3pm", estimateMinutes: 20, listName: "Personal", reminderMinutes: 5))
        PhoneSync.apply(siri, to: store, now: now)
        let t = try XCTUnwrap(store.task(siri.id))
        let expected = QuickParser(now: now, lists: store.lists, workdayEndMinutes: Prefs.workdayEnd).parse("call bank fri 3pm")
        XCTAssertEqual(t.title, expected.title)
        XCTAssertEqual(t.dueDate, expected.dueDate)
        XCTAssertTrue(t.dueHasTime)
        XCTAssertEqual(cal.component(.weekday, from: try XCTUnwrap(t.dueDate)), 6, "a Friday")
        XCTAssertEqual(t.estimateMinutes, 20, "the payload's length")
        XCTAssertEqual(t.listID, personal.id)
        XCTAssertEqual(minutesBefore(t), [5], "the payload's reminder")

        // What the payload left open comes from the title too.
        var open = DebriefTask(title: "Board prep 90m !!! every monday @alarm15")
        PhoneSync.fill(&open, from: QuickParser(now: now, lists: [], workdayEndMinutes: 18 * 60).parse(open.title))
        XCTAssertEqual(open.title, "Board prep")
        XCTAssertEqual(open.estimateMinutes, 90)
        XCTAssertEqual(open.priority, Priority.high.rawValue)
        XCTAssertEqual(open.repeatRule?.frequency, .weekly)
        XCTAssertEqual(open.reminderMinutes, 15)
        XCTAssertTrue(open.isAlarm)
    }

    // MARK: To the phone

    func testSnapshotCarriesRepeatReminderAndAlarm() throws {
        var standup = TaskItem(title: "Standup")
        standup.dueDate = day(12, hour: 9, minute: 30)
        standup.dueHasTime = true
        standup.recurrence = .weekdaysOnly
        standup.reminders = [Reminder(trigger: .beforeDue(minutes: 0), isSnooze: true), Reminder(trigger: .beforeDue(minutes: 5), isAlarm: true)]
        var rent = TaskItem(title: "Pay rent")
        rent.dueDate = day(11)
        rent.reminders = [Reminder(trigger: .absolute(day(11, hour: 8)))]
        var plain = TaskItem(title: "Water the plants")
        plain.dueDate = day(11)
        for t in [standup, rent, plain] { store.addTask(t) }

        let tasks = PhoneSync.snapshotTasks(store, now: now)
        let s = try XCTUnwrap(tasks.first { $0.title == "Standup" })
        XCTAssertEqual(s.repeatRule, TaskRepeat(frequency: .weekly, weekdays: [2, 3, 4, 5, 6]))
        XCTAssertEqual(s.reminderMinutes, 5, "snoozes don't count")
        XCTAssertTrue(s.isAlarm)
        let r = try XCTUnwrap(tasks.first { $0.title == "Pay rent" })
        XCTAssertEqual(PhoneSync.reminderMinutes(rent, allDayHour: 9), 60, "a set time before the deadline counts")
        XCTAssertFalse(r.isAlarm)
        XCTAssertNil(r.repeatRule)
        let p = try XCTUnwrap(tasks.first { $0.title == "Water the plants" })
        XCTAssertNil(p.reminderMinutes)
        XCTAssertFalse(p.isAlarm)

        let decoded = try MemoryCoding.decoder.decode([TaskSnapshot].self, from: MemoryCoding.compactEncoder.encode(tasks))
        XCTAssertEqual(decoded, tasks)
    }

    // MARK: The model

    /// A field's text, as a binding the model writes to.
    private final class Field {
        var text = ""
        var binding: Binding<String> { Binding(get: { self.text }, set: { self.text = $0 }) }
    }

    func testResultRemoveAndUndoAll() throws {
        let dictation = TaskDictation(intake: intake)
        let a = DebriefTask(title: "Call Rohan Mehta about the quote", dueDate: day(16, hour: 15), dueHasTime: true, estimateMinutes: 30)
        let b = DebriefTask(title: "Send the weekly investor update", dueDate: day(16, hour: 17), dueHasTime: true,
                            reminderMinutes: 30, isAlarm: true, repeatRule: TaskRepeat(frequency: .weekly, weekdays: [6]))
        let c = DebriefTask(title: "  ")
        XCTAssertEqual(dictation.add([a, b, a, c], at: now), [a.id, b.id], "one each; blank titles dropped")
        XCTAssertEqual(dictation.phase, .result)
        XCTAssertEqual(dictation.result?.made, 2)
        XCTAssertEqual(store.tasks.map(\.id), [a.id, b.id])
        XCTAssertTrue(intake.ledger.taskIDs(since: now.addingTimeInterval(-1)).isSuperset(of: [a.id, b.id]))

        dictation.remove(a.id)
        XCTAssertNil(store.task(a.id))
        XCTAssertTrue(intake.ledger.isDeleted(a.id), "stays gone")
        XCTAssertEqual(dictation.result?.taskIDs, [b.id])
        XCTAssertEqual(dictation.result?.undone, false)

        dictation.undoAll()
        XCTAssertTrue(store.tasks.isEmpty)
        XCTAssertEqual(dictation.result?.undone, true)
        XCTAssertEqual(dictation.add([a, b], at: now), [], "deleted ones don't come back")

        dictation.dismiss()
        XCTAssertEqual(dictation.phase, .idle)
        XCTAssertNil(dictation.result)
    }

    func testSubmitSchedulesWithGeminiAndClearsTheField() async throws {
        store.addList(name: "Work", color: .blue)
        let ai = DocketFakeAI(answer: Self.answer)
        intake.ai = { ai }
        let field = Field()
        let dictation = TaskDictation(intake: intake)
        dictation.now = { self.now }
        dictation.start(field: field.binding, context: AddContext())
        dictation.cancel()
        field.text = "Call Rohan Friday at 3 for half an hour, remind me 15 minutes before, for work"
        dictation.submit(field.text)
        XCTAssertEqual(dictation.phase, .working)
        await dictation.waitUntilScheduled()
        XCTAssertEqual(dictation.phase, .result)
        XCTAssertEqual(field.text, "", "the words became a task")
        XCTAssertTrue(ai.lastPrompt.contains("Work"), "the user's lists")
        let t = try XCTUnwrap(store.tasks.first)
        XCTAssertEqual(t.title, "Call Rohan Mehta about the quote")
        XCTAssertEqual(t.dueDate, day(16, hour: 15))
        XCTAssertEqual(t.estimateMinutes, 30)
        XCTAssertEqual(minutesBefore(t), [15])
        XCTAssertEqual(t.listID, store.lists.first?.id)
        XCTAssertEqual(dictation.result?.taskIDs, [t.id])
    }

    func testWithoutAKeyTheWordsStayAsTextAndFailuresSaySo() async {
        let field = Field()
        let dictation = TaskDictation(intake: intake)
        field.text = "call bank fri 3pm"
        dictation.submit(field.text)
        XCTAssertEqual(dictation.phase, .typed)
        XCTAssertEqual(field.text, "call bank fri 3pm")
        XCTAssertTrue(store.tasks.isEmpty, "quick add takes it from here, on Return")

        intake.ai = { DocketFakeAI(error: .network("Offline")) }
        dictation.dismiss()
        dictation.submit("call bank fri 3pm")
        await dictation.waitUntilScheduled()
        guard case .failed(let message, _) = dictation.phase else { return XCTFail("expected a failure, got \(dictation.phase)") }
        XCTAssertTrue(message.hasPrefix("Gemini couldn't schedule it"))
        XCTAssertTrue(store.tasks.isEmpty)

        intake.ai = { DocketFakeAI(answer: #"{"tasks":[]}"#) }
        dictation.dismiss()
        dictation.submit("hmm")
        await dictation.waitUntilScheduled()
        XCTAssertEqual(dictation.phase, .failed(DictationText.noTask, privacy: nil))
    }

    func testEscapeCancelsThenCloses() {
        let field = Field()
        field.text = "Call Rohan"
        let dictation = TaskDictation(intake: intake)
        // Never the microphone here: starting fails politely (not allowed in tests).
        dictation.start(field: field.binding, context: AddContext())
        XCTAssertTrue(dictation.isListening)
        XCTAssertTrue(dictation.escape())
        XCTAssertEqual(dictation.phase, .idle)
        XCTAssertEqual(field.text, "Call Rohan", "what was typed comes back")
        XCTAssertFalse(dictation.escape(), "nothing left to close")
        XCTAssertEqual(TaskDictation.combine("Call Rohan", "Friday at 3"), "Call Rohan Friday at 3")
        XCTAssertEqual(TaskDictation.combine("", "Friday at 3"), "Friday at 3")
    }

    // MARK: Stopping by itself

    func testSilenceStopsOnlyAfterSpeech() {
        let t0 = now
        var s = DictationSilence()
        s.level(0.9, at: t0)
        XCTAssertFalse(s.shouldStop(at: t0.addingTimeInterval(30)), "waits for the first words")
        s.heard("Call", at: t0.addingTimeInterval(1))
        XCTAssertFalse(s.shouldStop(at: t0.addingTimeInterval(2.5)))
        s.heard("Call Rohan", at: t0.addingTimeInterval(2))
        s.heard("Call Rohan", at: t0.addingTimeInterval(3.5))
        XCTAssertFalse(s.shouldStop(at: t0.addingTimeInterval(3.9)), "the same words again aren't new speech")
        XCTAssertTrue(s.shouldStop(at: t0.addingTimeInterval(4)), "2 s after the last new word")
        s.level(0.6, at: t0.addingTimeInterval(4.5))
        XCTAssertFalse(s.shouldStop(at: t0.addingTimeInterval(6)), "still speaking (the words lag)")
        s.level(0.05, at: t0.addingTimeInterval(6))
        XCTAssertTrue(s.shouldStop(at: t0.addingTimeInterval(6.5)), "quiet input doesn't count")
    }

    // MARK: Words

    func testWords() {
        let work = store.addList(name: "Work", color: .blue)
        var t = TaskItem(title: "Send the weekly investor update")
        t.dueDate = day(16, hour: 17)
        t.dueHasTime = true
        t.scheduledDate = day(15)
        t.recurrence = Recurrence(frequency: .weekly, weekdays: [6])
        t.reminders = [Reminder(trigger: .beforeDue(minutes: 30), isAlarm: true)]
        t.listID = work.id
        XCTAssertEqual(DictationText.details(t, listName: "Work", now: now).map(\.text),
                       ["Alarm 30m before", "Every week on Fri", "Do on \(Fmt.absoluteDay(day(15), now: now))", "Work"])
        XCTAssertEqual(DictationText.when(t, now: now), Fmt.due(day(16, hour: 17), hasTime: true, now: now))
        XCTAssertEqual(DictationText.toast(t, count: 1, now: now),
                       "Added “Send the weekly investor update” for \(Fmt.due(day(16, hour: 17), hasTime: true, now: now))")
        XCTAssertEqual(DictationText.toast(t, count: 2, now: now), "Added 2 tasks, from “Send the weekly investor update”")

        var planned = TaskItem(title: "Draft the memo")
        planned.scheduledDate = day(14)
        planned.reminders = [Reminder(trigger: .beforeDue(minutes: 15))]
        XCTAssertEqual(DictationText.when(planned, now: now), Fmt.absoluteDay(day(14), now: now), "the Do on day stands in")
        XCTAssertEqual(DictationText.details(planned, listName: nil, now: now).map(\.text), ["15m before"])
        XCTAssertEqual(DictationText.when(TaskItem(title: "Someday")), "No date")
        XCTAssertEqual(DictationText.headline(tasks: 1), "Added 1 task")

        XCTAssertEqual(DictationLayout.card(rows: 7, maxRows: 4) - DictationLayout.card(rows: 4, maxRows: 4), 20, "four rows, then a line")
        XCTAssertGreaterThan(DictationLayout.capturePanel(.result, rows: 2, base: 172, maxRows: 4), 172)
        XCTAssertEqual(DictationLayout.capturePanel(.listening, rows: 0, base: 172, maxRows: 4), 172)
    }

    static let answer = #"""
    {"tasks":[
      {"title":"Call Rohan Mehta about the quote","notes":"","dueDate":"2026-10-16","dueTime":"15:00","doOn":"","minutes":30,
       "reminderMinutes":15,"alarm":false,"repeat":"","interval":1,"weekdays":[],"priority":0,"listName":"work","tags":[],"waitingOn":""}
    ]}
    """#
}
