@testable import MemoryKit
import XCTest
@testable import Docket

/// Voice notes on the Mac: a debrief from the phone becomes tasks with the same ids and a memory; without one
/// the Mac asks Gemini (a fake here) or falls back; deleted tasks never come back; the phone gets list names
/// and the voice tasks; the result card's ✕ and Undo all. Temporary folders only; no microphone, no network.
@MainActor
final class VoiceIntakeTests: XCTestCase {
    var dir: URL!
    var store: Store!
    var library: MemoryLibrary!
    var intake: VoiceIntake!
    var bridge: PhoneBridge!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("docket-voice-\(UUID().uuidString)")
        store = Store(persistence: Persistence(directory: dir.appendingPathComponent("Store")), seedIfEmpty: false)
        library = MemoryLibrary(directory: dir.appendingPathComponent("Memory"), saveDelay: 60)
        intake = VoiceIntake(library: library, store: store)
        bridge = PhoneBridge(root: dir.appendingPathComponent("Phone"))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Fri 9 Oct 2026, 16:10 here.
    private var recordedAt: Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 16, minute: 10))!
    }

    private func day(_ d: Int, hour: Int? = nil) -> Date {
        let cal = Calendar.current
        var c = DateComponents(year: 2026, month: 10, day: d)
        if let hour { c.hour = hour }
        return cal.date(from: c)!
    }

    private func debrief(tasks: [DebriefTask]? = nil) -> VoiceDebrief {
        VoiceDebrief(transcript: "Mehta ji se mila. Revised quote by Friday.", title: "Pricing follow-up with Mehta Traders",
                     summary: "Rohan wants a revised quote.", keyTakeaways: ["Quote by Friday"], people: ["Rohan Mehta"],
                     projects: ["Mehta Traders"], tags: ["Sales Calls"],
                     moments: [Moment(kind: .decision, text: "Pilot in two stores first.")],
                     tasks: tasks ?? [
                        DebriefTask(title: "Send revised quote to Rohan Mehta", notes: "Include the annual discount", dueDate: day(16),
                                    estimateMinutes: 30, priority: 3, listName: "Sales"),
                        DebriefTask(title: "Call Anil", dueDate: day(10, hour: 15), dueHasTime: true, listName: "Hiring"),
                        DebriefTask(title: "Chase pilot numbers", waitingOn: "Priya Shah", listName: "Nowhere"),
                     ],
                     recordedAt: recordedAt, madeBy: "iPhone")
    }

    @discardableResult
    private func writeVoice(_ env: CaptureEnvelope, audio: Bool = true) throws -> CaptureEnvelope {
        if audio {
            try bridge.writeCapture(env, attachmentData: Data(repeating: 7, count: 2048), name: "Recording.m4a")
        } else {
            try bridge.writeCapture(env)
        }
        return env
    }

    @discardableResult
    private func ingest() -> PhoneBridge.IngestReport {
        let store = store!, intake = intake!
        return bridge.ingest(into: library, now: Date().addingTimeInterval(10), handleTask: { env in
            PhoneSync.apply(env, to: store, ledger: intake.ledger)
        }, handleVoice: { env, audio in
            intake.handleEnvelope(env, attachmentURL: audio)
        })
    }

    private func inboxFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: bridge.inboxURL.path)
    }

    // MARK: With a debrief

    func testDebriefFromThePhoneBecomesSameIDTasksAndAProcessedMemory() throws {
        let sales = store.addList(name: "Sales", color: .blue)
        let hiring = store.addList(name: "hiring", color: .green)
        let d = debrief()
        let env = try writeVoice(CaptureEnvelope(kind: .voice, createdAt: recordedAt, device: "Rohit's iPhone",
                                                 transcript: "rough words", debrief: d))
        let report = ingest()
        XCTAssertEqual(report.voiceHandled, 1)
        XCTAssertEqual(try inboxFiles(), [], "envelope and recording are gone from the inbox")

        XCTAssertEqual(store.tasks.map(\.id), d.tasks.map(\.id), "the same ids, in the order spoken")
        let quote = try XCTUnwrap(store.task(d.tasks[0].id))
        XCTAssertEqual(quote.title, "Send revised quote to Rohan Mehta")
        XCTAssertEqual(quote.listID, sales.id, "exact list name")
        XCTAssertEqual(quote.dueDate, day(16))
        XCTAssertFalse(quote.dueHasTime)
        XCTAssertEqual(quote.estimateMinutes, 30)
        XCTAssertEqual(quote.priority, .high)
        XCTAssertEqual(quote.notes, "From your voice note, \(Fmt.due(recordedAt, hasTime: true))\n\nInclude the annual discount")
        let call = try XCTUnwrap(store.task(d.tasks[1].id))
        XCTAssertTrue(call.dueHasTime)
        XCTAssertEqual(call.dueDate, day(10, hour: 15))
        XCTAssertEqual(call.listID, hiring.id, "same name in another case")
        XCTAssertEqual(call.notes, "From your voice note, \(Fmt.due(recordedAt, hasTime: true))")
        let chase = try XCTUnwrap(store.task(d.tasks[2].id))
        XCTAssertNil(chase.listID, "no such list: Inbox")
        XCTAssertEqual(chase.waitingOn, "Priya Shah")
        XCTAssertNil(chase.dueDate)

        let item = try XCTUnwrap(library.item(sourceRef: SourceRef.phone(env.id)))
        XCTAssertEqual(item.kind, .audio)
        XCTAssertEqual(item.origin, .phone)
        XCTAssertEqual(item.capturedFrom, "Rohit's iPhone")
        XCTAssertEqual(item.title, "Pricing follow-up with Mehta Traders")
        XCTAssertEqual(item.summary, "Rohan wants a revised quote.")
        XCTAssertEqual(item.extractedText, d.transcript, "the debrief's transcript, not the rough one")
        XCTAssertEqual(item.keyTakeaways, ["Quote by Friday"])
        XCTAssertEqual(item.people, ["Rohan Mehta"])
        XCTAssertEqual(item.projects, ["Mehta Traders"])
        XCTAssertEqual(item.tags, ["sales-calls"])
        XCTAssertEqual(item.moments.map(\.text), ["Pilot in two stores first."])
        XCTAssertEqual(item.createdAt, recordedAt)
        XCTAssertEqual(item.processing, .processed, "no second extraction")
        XCTAssertNotNil(item.processedAt)
        XCTAssertEqual(item.attachments.count, 1)
        XCTAssertTrue(item.attachments[0].mimeType.hasPrefix("audio/"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.fileURL(for: item.attachments[0], of: item.id).path))
        XCTAssertEqual(intake.ledger.taskIDs(for: item.id), d.tasks.map(\.id))
        XCTAssertEqual(intake.ledger.itemID(forTask: d.tasks[1].id), item.id)
    }

    func testProcessedVoiceMemoryIsOnlyEmbedded() async throws {
        let ai = DocketFakeAI()
        let processor = MemoryProcessor(library: library, ai: ai, autoProcess: false)
        processor.retryDelays = []
        try writeVoice(CaptureEnvelope(kind: .voice, createdAt: recordedAt, debrief: debrief()))
        ingest()
        processor.processPending()
        await processor.waitUntilIdle()
        XCTAssertEqual(ai.generateCount, 0, "already extracted on the phone")
        XCTAssertEqual(ai.embedCount, 1)
        XCTAssertEqual(library.vectors.count, 1)
    }

    func testTheSameDebriefTwiceAndDeletedTasksAreNotRecreated() throws {
        let d = debrief()
        let env = CaptureEnvelope(kind: .voice, createdAt: recordedAt, debrief: d)
        try writeVoice(env)
        ingest()
        XCTAssertEqual(store.tasks.count, 3)

        // The same envelope again (a sync conflict brought it back): nothing new.
        try writeVoice(env)
        XCTAssertEqual(ingest().voiceHandled, 1)
        XCTAssertEqual(store.tasks.count, 3)
        XCTAssertEqual(library.count, 1)

        // The phone deleted one; a late copy under another envelope must not bring it back.
        try bridge.writeCapture(CaptureEnvelope(kind: .taskDelete, taskID: d.tasks[0].id))
        XCTAssertEqual(ingest().tasksHandled, 1)
        XCTAssertNil(store.task(d.tasks[0].id))
        XCTAssertTrue(intake.ledger.isDeleted(d.tasks[0].id))

        try writeVoice(CaptureEnvelope(kind: .voice, createdAt: recordedAt, debrief: d))
        ingest()
        XCTAssertNil(store.task(d.tasks[0].id), "deleted stays deleted")
        XCTAssertEqual(store.tasks.count, 2, "the others aren't duplicated")
        XCTAssertEqual(try inboxFiles(), [])

        // The ledger survives a relaunch.
        XCTAssertTrue(VoiceLedger(fileURL: intake.ledger.fileURL).isDeleted(d.tasks[0].id))
    }

    func testTaskUndoneReopensAndTaskDeleteDeletes() {
        let task = store.addTask(TaskItem(title: "Water the plants"))
        store.setCompleted(task.id, true)
        XCTAssertTrue(PhoneSync.apply(CaptureEnvelope(kind: .taskUndone, taskID: task.id), to: store))
        XCTAssertEqual(store.task(task.id)?.isCompleted, false)
        XCTAssertTrue(PhoneSync.apply(CaptureEnvelope(kind: .taskUndone, taskID: UUID()), to: store), "gone: dealt with")

        let ledger = VoiceLedger(fileURL: dir.appendingPathComponent("ledger.json"))
        XCTAssertTrue(PhoneSync.apply(CaptureEnvelope(kind: .taskDelete, taskID: task.id), to: store, ledger: ledger))
        XCTAssertNil(store.task(task.id))
        XCTAssertTrue(ledger.isDeleted(task.id))
        XCTAssertTrue(PhoneSync.apply(CaptureEnvelope(kind: .taskDelete, taskID: UUID()), to: store, ledger: ledger))
    }

    // MARK: Without a debrief

    func testWithoutADebriefTheMacAsksGeminiThenApplies() async throws {
        store.addList(name: "Sales", color: .blue)
        let ai = DocketFakeAI(answer: Self.answer)
        intake.ai = { ai }
        var ready = 0
        intake.onReady = { ready += 1 }
        let env = try writeVoice(CaptureEnvelope(kind: .voice, createdAt: recordedAt, transcript: "Mehta ji se mila"))

        XCTAssertEqual(ingest().voiceHandled, 0, "Gemini is still on it")
        XCTAssertEqual(try inboxFiles().count, 2, "nothing deleted until handled")
        XCTAssertEqual(ingest().voiceHandled, 0, "not asked twice")
        await intake.waitForDebriefs()
        XCTAssertEqual(ready, 1)
        XCTAssertEqual(ai.generateCount, 1)
        XCTAssertEqual(ai.lastParts.first?.mimeType, MimeType.forExtension("m4a"), "the recording went along")
        XCTAssertTrue(ai.lastPrompt.contains("Mehta ji se mila"), "the rough transcript as a hint")
        XCTAssertTrue(ai.lastPrompt.contains("Sales"), "the user's lists")

        XCTAssertEqual(ingest().voiceHandled, 1)
        XCTAssertEqual(try inboxFiles(), [])
        XCTAssertEqual(store.tasks.map(\.title), ["Send revised quote to Rohan Mehta", "Call Rohan Mehta"])
        XCTAssertEqual(store.tasks.first?.listID, store.lists.first?.id)
        let item = try XCTUnwrap(library.item(sourceRef: SourceRef.phone(env.id)))
        XCTAssertEqual(item.title, "Revised quote for Mehta Traders")
        XCTAssertEqual(item.processing, .processed)
        XCTAssertEqual(item.extractedText, "Mehta ji se mila, revised quote by Friday.")
    }

    func testNoKeyFallsBackToOneTaskAndAPendingMemory() throws {
        let env = try writeVoice(CaptureEnvelope(kind: .voice, createdAt: recordedAt, transcript: "Call the bank about the loan"))
        XCTAssertEqual(ingest().voiceHandled, 1, "a debrief is never dropped")
        XCTAssertEqual(store.tasks.count, 1)
        let task = try XCTUnwrap(store.tasks.first)
        XCTAssertTrue(task.title.hasPrefix("Go through the voice note from"))
        XCTAssertTrue(task.notes.hasSuffix("Call the bank about the loan"))
        let item = try XCTUnwrap(library.item(sourceRef: SourceRef.phone(env.id)))
        XCTAssertEqual(item.kind, .audio)
        XCTAssertEqual(item.extractedText, "Call the bank about the loan")
        XCTAssertEqual(item.processing, .pending, "summarised once there's a key")
        XCTAssertEqual(item.attachments.count, 1)
    }

    func testGeminiFailingFallsBackAfterASecondTryButOfflineWaits() async throws {
        let ai = DocketFakeAI(error: .badResponse("Nonsense"))
        intake.ai = { ai }
        try writeVoice(CaptureEnvelope(kind: .voice, createdAt: Date(), transcript: "Book the venue"))
        ingest()
        await intake.waitForDebriefs()
        XCTAssertEqual(ingest().voiceHandled, 0, "one more try")
        await intake.waitForDebriefs()
        XCTAssertEqual(ingest().voiceHandled, 1, "then the fallback")
        XCTAssertEqual(store.tasks.count, 1)
        XCTAssertTrue(store.tasks[0].notes.hasSuffix("Book the venue"))

        let offline = DocketFakeAI(error: .network("Offline"))
        intake.ai = { offline }
        try writeVoice(CaptureEnvelope(kind: .voice, createdAt: Date(), transcript: "Renew the lease"))
        for _ in 0..<3 {
            XCTAssertEqual(ingest().voiceHandled, 0)
            await intake.waitForDebriefs()
        }
        XCTAssertEqual(try inboxFiles().count, 2, "kept for when the network is back")
    }

    // MARK: To the phone

    func testSnapshotCarriesListNamesAndVoiceTasksWhateverTheirDate() throws {
        store.addList(name: "Sales", color: .blue)
        store.addList(name: "Hiring", color: .green)
        let now = recordedAt
        var far = TaskItem(title: "Quarterly review")
        far.dueDate = Calendar.current.date(byAdding: .day, value: 40, to: now)
        let voiceTask = store.addTask(far)
        var undated = TaskItem(title: "Someday from voice")
        undated.notes = ""
        let undatedTask = store.addTask(undated)
        store.addTask(TaskItem(title: "Plain someday"))

        let tasks = PhoneSync.snapshotTasks(store, now: now, including: [voiceTask.id, undatedTask.id])
        XCTAssertEqual(tasks.map(\.title), ["Quarterly review", "Someday from voice"], "dated first, undated last; others left out")
        XCTAssertEqual(PhoneSync.snapshotTasks(store, now: now).count, 0)

        let snapshot = PhoneBridge.makeSnapshot(library, tasks: tasks, listNames: store.lists.map(\.name), now: now)
        let decoded = try MemoryCoding.decoder.decode(LibrarySnapshot.self, from: MemoryCoding.compactEncoder.encode(snapshot))
        XCTAssertEqual(decoded.listNames, ["Sales", "Hiring"])
        XCTAssertEqual(decoded.tasks.map(\.id), [voiceTask.id, undatedTask.id])
    }

    func testLedgerKnowsRecentVoiceTasks() {
        let ledger = intake.ledger
        let old = UUID(), new = UUID()
        ledger.link(item: UUID(), tasks: [old], at: Date().addingTimeInterval(-30 * 86_400))
        ledger.link(item: UUID(), tasks: [new], at: Date())
        XCTAssertEqual(ledger.taskIDs(since: Date().addingTimeInterval(-14 * 86_400)), [new])
    }

    // MARK: Recorded on the Mac: the result card

    func testRecordingWithoutKeyGivesMemoryAndFallbackTask() async throws {
        let file = dir.appendingPathComponent("rec.m4a")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 512).write(to: file)
        let outcome = try await intake.processRecording(file, liveTranscript: "Ring the accountant", recordedAt: recordedAt)
        XCTAssertFalse(outcome.processed)
        XCTAssertEqual(outcome.notice, VoiceText.noKeyNotice)
        XCTAssertEqual(outcome.taskIDs.count, 1)
        let item = try XCTUnwrap(library.item(outcome.itemID))
        XCTAssertEqual(item.capturedFrom, "Mac")
        XCTAssertTrue(item.sourceRef?.hasPrefix("voice:") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "moved into the library")
        XCTAssertEqual(item.attachments.count, 1)
    }

    func testResultCardRemoveAndUndoAll() throws {
        let d = debrief()
        let outcome = try intake.apply(d, audio: nil, moveAudio: false, sourceRef: SourceRef.voice(UUID()), origin: .manual,
                                       capturedFrom: "Mac", processed: true)
        let model = VoiceCaptureModel(intake: intake)
        model.show(outcome)
        XCTAssertEqual(model.phase, .result)
        XCTAssertEqual(model.result?.taskIDs, d.tasks.map(\.id))
        XCTAssertEqual(model.result?.title, "Pricing follow-up with Mehta Traders")

        model.remove(d.tasks[1].id)
        XCTAssertNil(store.task(d.tasks[1].id))
        XCTAssertTrue(intake.ledger.isDeleted(d.tasks[1].id))
        XCTAssertEqual(model.result?.taskIDs, [d.tasks[0].id, d.tasks[2].id])
        XCTAssertEqual(model.result?.undone, false)

        model.undoAll()
        XCTAssertTrue(store.tasks.isEmpty)
        XCTAssertEqual(model.result?.taskIDs, [])
        XCTAssertEqual(model.result?.undone, true)
        XCTAssertNotNil(library.item(outcome.itemID), "the recording stays in Memory")
        XCTAssertTrue(d.tasks.allSatisfy { intake.ledger.isDeleted($0.id) })

        // Applying the same debrief again (e.g. it also came from the phone) brings nothing back.
        try intake.apply(d, audio: nil, moveAudio: false, sourceRef: SourceRef.voice(UUID()), origin: .manual,
                         capturedFrom: "Mac", processed: true)
        XCTAssertTrue(store.tasks.isEmpty)

        model.reset()
        XCTAssertEqual(model.phase, .idle)
        XCTAssertNil(model.result)
    }

    func testResultPanelHeights() {
        XCTAssertEqual(VoiceCaptureLayout.result(rows: 0, notice: false), VoiceCaptureLayout.base)
        XCTAssertLessThan(VoiceCaptureLayout.result(rows: 3, notice: false), VoiceCaptureLayout.result(rows: 3, notice: true))
        XCTAssertEqual(VoiceCaptureLayout.result(rows: 9, notice: false) - VoiceCaptureLayout.result(rows: 5, notice: false), 22,
                       "five rows, then a line for the rest")
    }

    // MARK: Words

    func testWords() {
        XCTAssertEqual(VoiceText.headline(tasks: 3), "Added 3 tasks")
        XCTAssertEqual(VoiceText.headline(tasks: 1), "Added 1 task")
        XCTAssertEqual(VoiceText.headline(tasks: 0), "Saved to Memory")
        XCTAssertEqual(VoiceText.speakable("Raised on a SAFE [1][2]. Retention was 92% [3] , mostly."),
                       "Raised on a SAFE. Retention was 92%, mostly.")

        var a = TaskItem(title: "Send revised quote to Rohan Mehta")
        a.dueDate = day(16)
        let b = TaskItem(title: "Call Anil"), c = TaskItem(title: "Chase Priya")
        let n = VoiceText.notification(tasks: [a, b, c])
        XCTAssertEqual(n?.title, "3 tasks from your voice note")
        XCTAssertEqual(n?.body, "Send revised quote to Rohan Mehta · \(Fmt.due(day(16), hasTime: false))\nCall Anil and 1 more")
        XCTAssertNil(VoiceText.notification(tasks: []))
        XCTAssertEqual(VoiceText.when(b), "No date")
        XCTAssertEqual(VoiceCaptureCard.liveLine(""), "Say who you met, what was agreed and what you need to do, with dates.")
        let long = String(repeating: "word ", count: 60)
        XCTAssertTrue(VoiceCaptureCard.liveLine(long).hasPrefix("…word"))
    }

    static let answer = #"""
    {"transcript":"Mehta ji se mila, revised quote by Friday.","title":"Revised quote for Mehta Traders",
     "summary":"Met Mehta Traders.","keyTakeaways":[],"people":["Rohan Mehta"],"projects":[],"tags":[],
     "tasks":[
       {"title":"Send revised quote to Rohan Mehta","notes":"","date":"2026-10-16","time":"","estimateMinutes":0,"priority":3,"waitingOn":"","listName":"sales","people":[]},
       {"title":"Call Rohan Mehta","notes":"","date":"2026-10-10","time":"15:00","estimateMinutes":30,"priority":0,"waitingOn":"","listName":"","people":[]}
     ],
     "moments":[]}
    """#
}

/// A stand-in Gemini for the Mac tests: one canned answer (or error), counts calls, word-hash vectors.
final class DocketFakeAI: MemoryAI, @unchecked Sendable {
    let embeddingModel = "fake-embed"
    let embeddingDimensions = 8
    private let lock = NSLock()
    private let answer: String
    private let error: MemoryAIError?
    private var _generate = 0, _embed = 0
    private var _parts: [MemoryInlinePart] = []
    private var _prompt = ""

    init(answer: String = #"{"title":"T","summary":"S","keyTakeaways":[],"people":[],"projects":[],"topics":[],"tags":[],"moments":[],"extractedText":""}"#,
         error: MemoryAIError? = nil) {
        self.answer = answer
        self.error = error
    }

    var generateCount: Int { lock.lock(); defer { lock.unlock() }; return _generate }
    var embedCount: Int { lock.lock(); defer { lock.unlock() }; return _embed }
    var lastParts: [MemoryInlinePart] { lock.lock(); defer { lock.unlock() }; return _parts }
    var lastPrompt: String { lock.lock(); defer { lock.unlock() }; return _prompt }

    func generateJSON(system: String, prompt: String, schema: MemoryJSON, parts: [MemoryInlinePart]) async throws -> Data {
        lock.withLock {
            _generate += 1
            _parts = parts
            _prompt = prompt
        }
        if let error { throw error }
        return Data(answer.utf8)
    }

    func embed(_ texts: [String], task: EmbedTask) async throws -> [[Float]] {
        lock.withLock { _embed += 1 }
        return texts.map { text in
            var v = [Float](repeating: 0, count: 8)
            for word in text.lowercased().split(separator: " ") { v[abs(word.hashValue) % 8] += 1 }
            v[0] += 0.01
            return v
        }
    }
}
