@testable import MemoryKit
import XCTest

/// The memory a debrief turns into: kind audio, the transcript as extracted text, AI's findings, and the
/// processing state that decides whether the processor extracts again (pending) or only embeds (processed).
final class VoiceMemoryTests: XCTestCase {
    func testDebriefBecomesAnAudioMemory() {
        let at = day(-1, hour: 16)
        let d = VoiceDebrief(transcript: "  Mehta ji se mila.  ", title: "Pricing follow-up", summary: "Revised quote needed.",
                             keyTakeaways: ["Quote by Friday", " ", "a", "b", "c", "d"], people: ["Rohan Mehta", "rohan mehta"],
                             projects: ["Mehta Traders"], tags: ["Sales Calls"],
                             moments: [Moment(kind: .decision, text: "Pilot first.")],
                             tasks: [DebriefTask(title: "Send quote")], recordedAt: at)
        let ref = SourceRef.voice(UUID())
        let item = d.memoryItem(sourceRef: ref, origin: .manual, capturedFrom: "Mac", processed: true, now: at)
        XCTAssertEqual(item.kind, .audio)
        XCTAssertEqual(item.sourceRef, ref)
        XCTAssertTrue(ref.hasPrefix("voice:"))
        XCTAssertEqual(item.title, "Pricing follow-up")
        XCTAssertEqual(item.extractedText, "Mehta ji se mila.")
        XCTAssertEqual(item.keyTakeaways, ["Quote by Friday", "a", "b", "c", "d"])
        XCTAssertEqual(item.people, ["Rohan Mehta"], "one spelling per person")
        XCTAssertEqual(item.tags, ["sales-calls"])
        XCTAssertEqual(item.moments.count, 1)
        XCTAssertEqual(item.createdAt, at)
        XCTAssertEqual(item.processing, .processed)
        XCTAssertEqual(item.processedAt, at)

        let fallback = VoiceDebrief.unprocessed(transcript: "Call the bank", recordedAt: at)
            .memoryItem(sourceRef: nil, origin: .phone, capturedFrom: "iPhone", processed: false)
        XCTAssertEqual(fallback.processing, .pending)
        XCTAssertNil(fallback.processedAt)
        XCTAssertTrue(fallback.title.hasPrefix("Voice note, "))
        XCTAssertEqual(fallback.extractedText, "Call the bank")

        var untitled = d
        untitled.title = "  "
        XCTAssertEqual(untitled.memoryItem(sourceRef: nil, origin: .manual, capturedFrom: nil, processed: true).title,
                       "Voice note, \(MemoryDates.prompt(at))")
    }
}
