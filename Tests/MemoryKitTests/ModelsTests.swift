import XCTest
@testable import MemoryKit

final class ModelsTests: XCTestCase {
    func testItemRoundTripsWithEverything() throws {
        let attachment = MemoryAttachment(name: "Pitch v3.pdf", fileName: "Pitch v3.pdf", mimeType: "application/pdf", byteCount: 1234, addedAt: day(0))
        let item = MemoryItem(kind: .pdf, origin: .phone, sourceRef: "phone:ABC", title: "Pitch", summary: "S", body: "B",
                              extractedText: "E", keyTakeaways: ["one"], url: "https://example.com", imageURL: "https://example.com/i.png",
                              capturedFrom: "iPhone", people: ["Priya Shah"], projects: ["Seed"], topics: ["fundraising"], tags: ["deck"],
                              moments: [Moment(kind: .promise, text: "Send deck", who: "Alex Kim", due: day(3, hour: 0), direction: .theirs, done: true)],
                              attachments: [attachment], pinned: true, createdAt: day(-1), updatedAt: day(0), lastViewedAt: day(0),
                              processing: .failed("Gemini said no."), processedAt: day(0), attempts: 2, lightweight: true)
        XCTAssertEqual(try roundTrip(item), item)
    }

    func testItemDecodesFromAlmostNothing() throws {
        let json = #"{"title": "Just a title", "kind": "hologram", "origin": "satellite", "processing": "processed"}"#
        let item = try MemoryCoding.decoder.decode(MemoryItem.self, from: Data(json.utf8))
        XCTAssertEqual(item.title, "Just a title")
        XCTAssertEqual(item.kind, .note, "unknown kinds fall back to note")
        XCTAssertEqual(item.origin, .manual)
        XCTAssertEqual(item.processing, .processed, "a bare string state is accepted")
        XCTAssertEqual(item.people, [])
        XCTAssertFalse(item.pinned)
    }

    func testBadFieldDoesNotSinkTheItem() throws {
        let json = #"{"title": "T", "people": "not a list", "moments": [{"text": "Decide", "kind": "decision", "due": 12}], "createdAt": 1700000000000}"#
        let item = try MemoryCoding.decoder.decode(MemoryItem.self, from: Data(json.utf8))
        XCTAssertEqual(item.people, [])
        XCTAssertEqual(item.moments.first?.kind, .decision)
        XCTAssertEqual(item.createdAt.timeIntervalSince1970, 1_700_000_000, accuracy: 1, "epoch milliseconds are read")
    }

    func testProcessingStateCoding() throws {
        for state in [ProcessingState.pending, .processed, .skipped, .failed("Nope.")] {
            XCTAssertEqual(try roundTrip([state]), [state])
        }
        let data = try MemoryCoding.encoder.encode(ProcessingState.failed("Nope."))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: String]
        XCTAssertEqual(object, ["state": "failed", "message": "Nope."])
    }

    func testDatesAcceptFractionalSecondsAndDays() throws {
        struct Box: Codable { var d: Date }
        let a = try MemoryCoding.decoder.decode(Box.self, from: Data(#"{"d":"2026-10-09T08:15:00.250Z"}"#.utf8))
        XCTAssertEqual(a.d.timeIntervalSince1970, 1_791_533_700.25, accuracy: 0.01)
        let b = try MemoryCoding.decoder.decode(Box.self, from: Data(#"{"d":"2026-10-09"}"#.utf8))
        XCTAssertEqual(Calendar.current.component(.day, from: b.d), 9)
    }

    func testEnvelopeAndSnapshotRoundTrip() throws {
        let env = CaptureEnvelope(kind: .task, createdAt: day(0), title: "Call Priya", due: day(1, hour: 0), dueHasTime: false, device: "iPhone")
        XCTAssertEqual(try roundTrip(env), env)
        XCTAssertEqual(env.version, 1)

        let snapshot = LibrarySnapshot(generatedAt: day(0), items: [MemoryItem(title: "A", createdAt: day(-1))],
                                       profile: MemoryProfile(facts: [ProfileFact(text: "Founder", category: .role, pinned: true, updatedAt: day(0))]),
                                       lenses: [.sales, .founder], tasks: [TaskSnapshot(id: UUID(), title: "Ship", dueDate: day(0), priority: 3, listName: "Work")],
                                       embeddingModel: "gemini-embedding-2", embeddingDimensions: 768)
        XCTAssertEqual(try roundTrip(snapshot), snapshot)

        let tolerant = try MemoryCoding.decoder.decode(LibrarySnapshot.self, from: Data(#"{"lenses": ["sales", "astronaut"], "tasks": [{"title": "T"}]}"#.utf8))
        XCTAssertEqual(tolerant.lenses, [.sales], "unknown lenses are dropped")
        XCTAssertEqual(tolerant.tasks.first?.title, "T")
        XCTAssertEqual(tolerant.version, LibrarySnapshot.currentVersion)
    }

    func testEnvelopeNeedsAKindButNothingElse() throws {
        let env = try MemoryCoding.decoder.decode(CaptureEnvelope.self, from: Data(#"{"kind": "note", "text": "hi"}"#.utf8))
        XCTAssertEqual(env.kind, .note)
        XCTAssertEqual(env.text, "hi")
        XCTAssertThrowsError(try MemoryCoding.decoder.decode(CaptureEnvelope.self, from: Data(#"{"text": "hi"}"#.utf8)))
    }

    func testSourceRefs() {
        let id = UUID()
        XCTAssertEqual(SourceRef.note(id), "note:\(id.uuidString)")
        XCTAssertEqual(SourceRef.slack(channel: "C1", ts: "17.1"), "slack:C1:17.1")
        XCTAssertEqual(SourceRef.gmail(threadID: "abc"), "gmail:abc")
        XCTAssertEqual(SourceRef.engram("42"), "engram:42")
        XCTAssertEqual(SourceRef.url("https://www.Example.com/a/?utm_source=x&id=7#top"), "url:example.com/a?id=7")
        XCTAssertEqual(SourceRef.url("http://example.com/a"), SourceRef.url("example.com/a/"))
        XCTAssertNil(SourceRef.url("not a url"))
        XCTAssertNil(SourceRef.url("ftp://example.com/file"))
        XCTAssertEqual(SourceRef.scheme(of: "slack:C1:17.1"), "slack")
    }

    func testKindsForFiles() {
        XCTAssertEqual(MemoryKind.forFile(extension: "HEIC"), .image)
        XCTAssertEqual(MemoryKind.forFile(extension: "m4a"), .audio)
        XCTAssertEqual(MemoryKind.forFile(extension: "pdf"), .pdf)
        XCTAssertEqual(MemoryKind.forFile(extension: "mov"), .video)
        XCTAssertEqual(MemoryKind.forFile(extension: "key"), .file)
        XCTAssertEqual(MimeType.forExtension("m4a"), "audio/mp4")
        XCTAssertTrue(MimeType.isPlainText("text/markdown"))
        XCTAssertFalse(MimeType.isPlainText("text/html"))
        XCTAssertTrue(MimeType.isInlineable("application/pdf"))
    }

    func testDisplayTitleFallsBack() {
        XCTAssertEqual(MemoryItem(title: "  Named ").displayTitle, "Named")
        XCTAssertEqual(MemoryItem(body: "\nFirst line\nSecond").displayTitle, "First line")
        XCTAssertEqual(MemoryItem(kind: .link, url: "https://example.com/x").displayTitle, "example.com")
        XCTAssertEqual(MemoryItem(kind: .audio).displayTitle, "Voice note")
    }

    func testDateLabelsAreRealDates() {
        let now = day(0)
        let sameYear = MemoryDates.label(day(-4), now: now)
        XCTAssertFalse(sameYear.contains("2026"))
        XCTAssertTrue(MemoryDates.label(Calendar.current.date(byAdding: .year, value: -1, to: now)!, now: now).contains("2025"))
        XCTAssertEqual(MemoryDates.prompt(now), "Fri 9 Oct 2026")
        XCTAssertEqual(MemoryDates.dayKey(now), "2026-10-09")
        XCTAssertEqual(MemoryDates.day(from: "2026-10-12").map(MemoryDates.dayKey), "2026-10-12")
        XCTAssertNil(MemoryDates.day(from: ""))
    }
}
