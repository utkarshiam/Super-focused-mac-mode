@testable import MemoryKit
import XCTest

/// The live transcript across pauses and restarted recognition requests: nothing said is lost, nothing is
/// written twice.
final class TranscriptAccumulatorTests: XCTestCase {
    func testPartialRevisionsReplaceTheCurrentUtterance() {
        var t = TranscriptAccumulator()
        let g = t.generation
        t.receive("Call", generation: g, isFinal: false)
        t.receive("Call Rohan", generation: g, isFinal: false)
        t.receive("Call Rohan Mehta on Friday", generation: g, isFinal: false)
        t.receive("Hi Rohan Mehta on Friday", generation: g, isFinal: false)
        XCTAssertEqual(t.text, "Hi Rohan Mehta on Friday", "a revised first word is still the same utterance")
    }

    func testANewUtteranceAfterAPauseKeepsWhatWasSaid() {
        var t = TranscriptAccumulator()
        let g = t.generation
        t.receive("Just walked out of the Mehta Traders meeting and they want a revised quote", generation: g, isFinal: false)
        // Long pause: the recognizer silently starts over with only the new words.
        t.receive("Priya", generation: g, isFinal: false)
        t.receive("Priya will send the samples", generation: g, isFinal: false)
        XCTAssertEqual(t.text, "Just walked out of the Mehta Traders meeting and they want a revised quote Priya will send the samples")
    }

    func testTimestampsThatMoveOnMarkANewUtterance() {
        var t = TranscriptAccumulator()
        let g = t.generation
        t.receive("Send the deck", generation: g, start: 0.4, isFinal: false)
        t.receive("Send it", generation: g, start: 9.2, isFinal: false)
        XCTAssertEqual(t.text, "Send the deck Send it")
    }

    func testARestartedRequestKeepsTextAndIgnoresLateResultsFromTheOldOne() {
        var t = TranscriptAccumulator()
        let old = t.generation
        t.receive("Call Anil about delivery dates", generation: old, isFinal: true)
        let new = t.restart()
        // The old task reports again after the restart (late final, or an error with its last text).
        t.receive("Call Anil about delivery dates", generation: old, isFinal: true)
        t.receive("tomorrow at three", generation: new, isFinal: false)
        XCTAssertEqual(t.text, "Call Anil about delivery dates tomorrow at three")
    }

    func testAFinalRepeatOfTheLastWordsIsNotAddedTwice() {
        var t = TranscriptAccumulator()
        let g = t.generation
        t.receive("Book the offsite venue", generation: g, isFinal: true)
        t.receive("Book the offsite venue", generation: g, isFinal: true)
        XCTAssertEqual(t.text, "Book the offsite venue")
    }

    func testEmptyResultsNeverWipeTheText() {
        var t = TranscriptAccumulator()
        let g = t.generation
        t.receive("Pricing page draft", generation: g, isFinal: false)
        t.receive("  ", generation: g, isFinal: false)
        t.receive("", generation: g, isFinal: true)
        XCTAssertEqual(t.text, "Pricing page draft")
        t.reset()
        XCTAssertEqual(t.text, "")
    }
}
