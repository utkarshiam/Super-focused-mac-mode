import XCTest
@testable import MemoryKit

@MainActor
final class EngramImporterTests: XCTestCase {
    var dir: URL!

    override func setUp() async throws { dir = makeTempDirectory() }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    /// The shape ENGRAM's services/exportData.ts writes.
    private let export = #"""
    {
      "app": "ENGRAM",
      "exportedAt": "2026-09-30T10:00:00.000Z",
      "counts": {"entries": 4, "entities": 4, "relationships": 1},
      "entries": [
        {"id": "e1", "title": "Seed pitch feedback", "summary": "Priya Shah liked the retention story.",
         "originalContent": "Met Priya Shah from Harbor Capital. She liked retention.", "contentType": "text",
         "keyTakeaways": ["Retention resonates", "Tighten the market slide"], "createdAt": 1758000000000, "updatedAt": 1758000000000},
        {"id": "e2", "title": "Pricing article", "summary": "Three tiers convert best.", "originalContent": "https://example.com/pricing",
         "sourceUrl": "https://example.com/pricing", "sourceApp": "Safari", "contentType": "url", "keyTakeaways": [], "createdAt": 1757000000000},
        {"id": "e3", "title": "Voice memo", "summary": "Idea about onboarding.", "originalContent": "file:///var/mobile/memo.m4a",
         "contentType": "audio", "keyTakeaways": [], "createdAt": "2025-09-01T08:00:00Z"},
        {"id": "", "title": "No id"},
        {"broken": true}
      ],
      "entities": [
        {"id": "x1", "name": "Priya Shah", "type": "person", "description": "", "mentionCount": 3},
        {"id": "x2", "name": "Harbor Capital", "type": "organization", "description": "", "mentionCount": 1},
        {"id": "x3", "name": "retention", "type": "concept", "description": "", "mentionCount": 2},
        {"id": "x4", "name": "Alex Kim", "type": "person", "description": "", "mentionCount": 1}
      ],
      "relationships": [{"sourceId": "x1", "targetId": "x2", "relationship": "works_at", "weight": 1}]
    }
    """#

    func testImportMapsEntriesAndEntities() throws {
        let library = MemoryLibrary(directory: dir, saveDelay: 60)
        let report = try EngramImporter.importExport(Data(export.utf8), into: library)
        XCTAssertEqual(report.total, 5)
        XCTAssertEqual(report.imported, 3)
        XCTAssertEqual(report.skippedEmpty, 2)
        XCTAssertEqual(report.skippedDuplicates, 0)

        let pitch = try XCTUnwrap(library.item(sourceRef: "engram:e1"))
        XCTAssertEqual(pitch.origin, .engram)
        XCTAssertEqual(pitch.kind, .text)
        XCTAssertEqual(pitch.title, "Seed pitch feedback")
        XCTAssertEqual(pitch.summary, "Priya Shah liked the retention story.")
        XCTAssertEqual(pitch.body, "Met Priya Shah from Harbor Capital. She liked retention.")
        XCTAssertEqual(pitch.keyTakeaways, ["Retention resonates", "Tighten the market slide"])
        XCTAssertEqual(pitch.createdAt.timeIntervalSince1970, 1_758_000_000)
        XCTAssertEqual(pitch.people, ["Priya Shah"], "only people named in the entry")
        XCTAssertEqual(pitch.projects, ["Harbor Capital"])
        XCTAssertEqual(pitch.topics, ["retention"])
        XCTAssertTrue(pitch.lightweight, "already summarised: embed only")
        XCTAssertEqual(pitch.processing, .pending)

        let link = try XCTUnwrap(library.item(sourceRef: "engram:e2"))
        XCTAssertEqual(link.kind, .link)
        XCTAssertEqual(link.url, "https://example.com/pricing")
        XCTAssertEqual(link.body, "", "the URL isn't repeated as the body")
        XCTAssertEqual(link.capturedFrom, "ENGRAM · Safari")

        let memo = try XCTUnwrap(library.item(sourceRef: "engram:e3"))
        XCTAssertEqual(memo.kind, .audio)
        XCTAssertEqual(memo.body, "", "device file paths are dropped")
        XCTAssertEqual(Calendar.current.component(.year, from: memo.createdAt), 2025)
    }

    func testReimportSkipsDuplicates() throws {
        let library = MemoryLibrary(directory: dir, saveDelay: 60)
        try EngramImporter.importExport(Data(export.utf8), into: library)
        let again = try EngramImporter.importExport(Data(export.utf8), into: library)
        XCTAssertEqual(again.imported, 0)
        XCTAssertEqual(again.skippedDuplicates, 3)
        XCTAssertEqual(library.count, 3)
    }

    func testOtherFilesAreRejected() {
        let library = MemoryLibrary(directory: dir, saveDelay: 60)
        XCTAssertThrowsError(try EngramImporter.importExport(Data(#"{"app": "Other", "entries": []}"#.utf8), into: library)) {
            XCTAssertEqual($0 as? EngramImporter.ImportError, .notAnExport)
        }
        XCTAssertThrowsError(try EngramImporter.importExport(Data("not json".utf8), into: library))
    }

    func testImportedItemsAreEmbeddedWithoutExtraction() async throws {
        let library = MemoryLibrary(directory: dir, saveDelay: 60)
        try EngramImporter.importExport(Data(export.utf8), into: library)
        let ai = FakeAI()
        let p = MemoryProcessor(library: library, ai: ai, autoProcess: false)
        p.processPending()
        await p.waitUntilIdle()
        XCTAssertEqual(ai.generateCalls.count, 0)
        XCTAssertEqual(library.vectors.count, 3)
        XCTAssertTrue(library.items.allSatisfy { $0.processing == .processed })
        XCTAssertEqual(library.item(sourceRef: "engram:e1")?.summary, "Priya Shah liked the retention story.", "ENGRAM's summary is kept")
    }
}
