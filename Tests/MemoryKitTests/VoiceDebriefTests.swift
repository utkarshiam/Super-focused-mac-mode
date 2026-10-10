@testable import MemoryKit
import XCTest

/// Spoken debriefs: tasks with real dates resolved against when it was spoken, the user's own promises as
/// tasks (not moments), lists matched to the user's, and the envelope carrying it all to the Mac.
final class VoiceDebriefTests: XCTestCase {
    let kolkata = TimeZone(identifier: "Asia/Kolkata")!

    /// Fri 9 Oct 2026, 16:10 in Kolkata.
    var recordedAt: Date {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = kolkata
        return c.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 16, minute: 10))!
    }

    let answer = #"""
    {"transcript":"Mehta ji se mila, they want the revised quote by Friday next week. I'll call Rohan tomorrow at 3. Priya will send the samples.",
     "title":"Revised quote for Mehta Traders","summary":"Met Mehta Traders; they want a revised quote.",
     "keyTakeaways":["Revised quote needed"],"people":["Rohan Mehta","Priya Shah"],"projects":["Mehta Traders"],"tags":["sales"],
     "tasks":[
       {"title":"Send revised quote to Rohan Mehta","notes":"They asked after the visit","date":"2026-10-16","time":"","estimateMinutes":0,"priority":3,"waitingOn":"","listName":"sales","people":["Rohan Mehta"]},
       {"title":"Call Rohan Mehta","notes":"","date":"2026-10-10","time":"15:00","estimateMinutes":30,"priority":0,"waitingOn":"","listName":"Unknown","people":[]},
       {"title":"Chase samples from Priya","notes":"","date":"","time":"","estimateMinutes":0,"priority":9,"waitingOn":"Priya Shah","listName":"","people":[]},
       {"title":"  ","notes":"","date":"","time":"","estimateMinutes":0,"priority":0,"waitingOn":"","listName":"","people":[]}
     ],
     "moments":[
       {"kind":"promise","text":"Priya will send the samples.","who":"Priya Shah","due":"","direction":"theirs"},
       {"kind":"promise","text":"I'll call Rohan.","who":"","due":"2026-10-10","direction":"mine"},
       {"kind":"decision","text":"Quote goes out with the volume discount.","who":"","due":"","direction":"none"}
     ]}
    """#

    func testParseResolvesDatesListsAndKeepsOwnPromisesAsTasks() throws {
        let d = try VoiceDebriefer.parse(Data(answer.utf8), recordedAt: recordedAt, timeZone: kolkata, listNames: ["Sales", "Hiring"])
        XCTAssertEqual(d.title, "Revised quote for Mehta Traders")
        XCTAssertEqual(d.tasks.count, 3, "blank titles dropped")

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = kolkata
        let quote = d.tasks[0]
        XCTAssertEqual(cal.dateComponents([.year, .month, .day, .hour], from: quote.dueDate!), DateComponents(year: 2026, month: 10, day: 16, hour: 0))
        XCTAssertFalse(quote.dueHasTime)
        XCTAssertEqual(quote.priority, 3)
        XCTAssertEqual(quote.listName, "Sales", "matched to the user's list, their spelling")

        let call = d.tasks[1]
        XCTAssertTrue(call.dueHasTime)
        XCTAssertEqual(cal.dateComponents([.day, .hour, .minute], from: call.dueDate!), DateComponents(day: 10, hour: 15, minute: 0))
        XCTAssertEqual(call.estimateMinutes, 30)
        XCTAssertNil(call.listName, "not one of the user's lists")

        XCTAssertEqual(d.tasks[2].waitingOn, "Priya Shah")
        XCTAssertEqual(d.tasks[2].priority, 4, "clamped")
        XCTAssertNil(d.tasks[2].dueDate)

        XCTAssertEqual(d.moments.map(\.kind), [.promise, .decision], "the user's own promise is a task, not a moment")
        XCTAssertEqual(d.moments[0].direction, .theirs)
        XCTAssertEqual(Set(d.tasks.map(\.id)).count, 3, "each task has its own id")
    }

    func testTimeWithoutDateIsTheNextSuchTime() {
        let late = VoiceDebriefer.dueDate(day: "", time: "09:30", after: recordedAt, timeZone: kolkata)!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = kolkata
        XCTAssertEqual(cal.dateComponents([.day, .hour, .minute], from: late.date), DateComponents(day: 10, hour: 9, minute: 30))
        XCTAssertNil(VoiceDebriefer.dueDate(day: "", time: "", after: recordedAt, timeZone: kolkata))
        XCTAssertNil(VoiceDebriefer.dueDate(day: "soon", time: "25:00", after: recordedAt, timeZone: kolkata))
    }

    func testDebriefSendsAudioRecordingTimeAndListsToGemini() async throws {
        let ai = FakeAI(onGenerate: { _ in Data(self.answer.utf8) })
        let debriefer = VoiceDebriefer(ai: ai, listNames: ["Sales"], knownPeople: ["Rohan Mehta"], timeZone: kolkata)
        let audio = MemoryInlinePart(mimeType: "audio/aac", data: Data([1, 2, 3]))
        let d = try await debriefer.debrief(audio: audio, liveTranscript: "mehta ji se mila", recordedAt: recordedAt, madeBy: "iPhone")
        XCTAssertEqual(d.madeBy, "iPhone")
        let call = try XCTUnwrap(ai.generateCalls.first)
        XCTAssertEqual(call.parts, [audio])
        XCTAssertTrue(call.prompt.contains("Friday 9 October 2026, 16:10"), call.prompt)
        XCTAssertTrue(call.prompt.contains("Lists: Sales"))
        XCTAssertTrue(call.prompt.contains("Rohan Mehta"))
        XCTAssertTrue(call.prompt.contains("mehta ji se mila"))
    }

    func testNothingToDebriefThrowsWithoutCallingGemini() async {
        let ai = FakeAI()
        let debriefer = VoiceDebriefer(ai: ai)
        do {
            _ = try await debriefer.debrief(audio: nil, liveTranscript: "  ", recordedAt: recordedAt)
            XCTFail("should throw")
        } catch {}
        XCTAssertTrue(ai.generateCalls.isEmpty)
    }

    func testUnprocessedFallbackStillMakesATask() {
        let d = VoiceDebrief.unprocessed(transcript: "met the Mehta team", recordedAt: recordedAt)
        XCTAssertEqual(d.tasks.count, 1)
        XCTAssertTrue(d.tasks[0].title.hasPrefix("Go through the voice note from "))
        XCTAssertEqual(d.tasks[0].notes, "met the Mehta team")
    }

    func testEnvelopeCarriesDebriefAndNewTaskKinds() throws {
        let debrief = try VoiceDebriefer.parse(Data(answer.utf8), recordedAt: recordedAt, timeZone: kolkata)
        let env = CaptureEnvelope(kind: .voice, attachmentName: "debrief.m4a", transcript: "rough words", debrief: debrief)
        let data = try MemoryCoding.encoder.encode(env)
        let back = try MemoryCoding.decoder.decode(CaptureEnvelope.self, from: data)
        XCTAssertEqual(back.debrief, debrief)
        XCTAssertEqual(back.transcript, "rough words")

        for kind in [CaptureEnvelope.Kind.taskUndone, .taskDelete] {
            let e = try MemoryCoding.decoder.decode(CaptureEnvelope.self, from: Data(#"{"kind":"\#(kind.rawValue)","taskID":"\#(UUID().uuidString)"}"#.utf8))
            XCTAssertEqual(e.kind, kind)
            XCTAssertTrue(e.kind.isTask)
        }
        let old = try MemoryCoding.decoder.decode(CaptureEnvelope.self, from: Data(#"{"kind":"voice"}"#.utf8))
        XCTAssertNil(old.debrief, "older phones send no debrief")
    }
}
