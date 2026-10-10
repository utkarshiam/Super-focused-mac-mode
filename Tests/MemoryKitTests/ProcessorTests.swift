import XCTest
@testable import MemoryKit

@MainActor
final class ProcessorTests: XCTestCase {
    var dir: URL!

    override func setUp() async throws { dir = makeTempDirectory() }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    private func processor(_ library: MemoryLibrary, ai: MemoryAI?, fetcher: LinkFetcher = LinkFetcher()) -> MemoryProcessor {
        let p = MemoryProcessor(library: library, ai: ai, fetcher: fetcher, autoProcess: false)
        p.retryDelays = [0.01, 0.01]
        p.resumeDelay = 3600
        p.now = { day(0) }
        return p
    }

    private static let extraction = #"""
    {"title": "Pricing call with Northwind", "summary": "Northwind asked for 20% off.",
     "keyTakeaways": ["Wants 20% off", " "], "people": ["Jordan Lee", "jordan lee"], "projects": ["Northwind renewal"],
     "topics": ["sales"], "tags": ["Pricing", "renewal"],
     "moments": [{"kind": "promise", "text": "Send a revised quote", "who": "", "due": "2026-10-12", "direction": "mine"},
                 {"kind": "decision", "text": "Hold the price", "who": "Jordan Lee", "due": "", "direction": "none"},
                 {"kind": "nonsense", "text": "dropped", "who": "", "due": "", "direction": "none"}],
     "extractedText": ""}
    """#

    func testNoKeyMarksSkippedAndTextSearchStillWorks() async {
        let library = MemoryLibrary(directory: dir, saveDelay: 60)
        let item = library.addNote("Northwind wants 20% off")
        let p = processor(library, ai: nil)
        p.processPending()
        XCTAssertEqual(library.item(item.id)?.processing, .skipped)
        XCTAssertEqual(library.items(matching: MemoryFilter(text: "northwind")).first?.id, item.id)
    }

    func testSuccessFillsTheItemAndStoresAVector() async throws {
        let library = MemoryLibrary(directory: dir, saveDelay: 60)
        library.setLenses([.sales])
        library.addFact("Account executive", category: .role, pinned: true)
        let item = library.add(MemoryItem(body: "Call notes: Northwind wants 20% off. I'll send a revised quote Monday.",
                                          people: ["Alex Kim"], tags: ["calls"], createdAt: day(-1)))
        let ai = FakeAI(onGenerate: { _ in Data(Self.extraction.utf8) })
        let p = processor(library, ai: ai)
        p.processPending()
        XCTAssertEqual(p.processingCount, 1)
        await p.waitUntilIdle()

        let done = try XCTUnwrap(library.item(item.id))
        XCTAssertEqual(done.processing, .processed)
        XCTAssertEqual(done.processedAt, day(0))
        XCTAssertEqual(done.title, "Pricing call with Northwind")
        XCTAssertEqual(done.summary, "Northwind asked for 20% off.")
        XCTAssertEqual(done.keyTakeaways, ["Wants 20% off"])
        XCTAssertEqual(done.people, ["Alex Kim", "Jordan Lee"])
        XCTAssertEqual(done.projects, ["Northwind renewal"])
        XCTAssertEqual(done.tags, ["calls", "pricing", "renewal"])
        XCTAssertEqual(done.moments.count, 2)
        let promise = try XCTUnwrap(done.moments.first { $0.kind == .promise })
        XCTAssertEqual(promise.direction, .mine)
        XCTAssertNil(promise.who)
        XCTAssertEqual(promise.due.map(MemoryDates.dayKey), "2026-10-12")
        XCTAssertEqual(done.moments.first { $0.kind == .decision }?.who, "Jordan Lee")
        XCTAssertNotNil(library.vector(for: item.id))
        XCTAssertEqual(library.vectors.model, "fake-embed")
        XCTAssertEqual(p.processingCount, 0)
        XCTAssertNil(p.lastError)

        let call = try XCTUnwrap(ai.generateCalls.first)
        XCTAssertTrue(call.system.contains(Lens.sales.guidance))
        XCTAssertTrue(call.system.contains("Account executive"))
        XCTAssertTrue(call.system.contains("Today is Fri 9 Oct 2026"))
        XCTAssertTrue(call.prompt.contains("Saved: Thu 8 Oct 2026 (2026-10-08)"))
        XCTAssertTrue(call.prompt.contains("Northwind wants 20% off"))
        XCTAssertEqual(ai.embedCalls.first?.task, .document)
    }

    func testReprocessingKeepsDoneMarksAndUserTitle() async throws {
        let library = MemoryLibrary(directory: dir, saveDelay: 60)
        let item = library.add(MemoryItem(title: "My title", body: "x", moments: [Moment(kind: .promise, text: "send a revised quote", done: true)]))
        let p = processor(library, ai: FakeAI(onGenerate: { _ in Data(Self.extraction.utf8) }))
        p.processPending()
        await p.waitUntilIdle()
        let done = try XCTUnwrap(library.item(item.id))
        XCTAssertEqual(done.title, "My title")
        XCTAssertEqual(done.moments.first { $0.kind == .promise }?.done, true)
        XCTAssertEqual(done.moments.first { $0.kind == .promise }?.id, item.moments[0].id)
    }

    func testTransientFailureRetriesThenSucceeds() async {
        let library = MemoryLibrary(directory: dir, saveDelay: 60)
        let item = library.addNote("Retry me")
        var failures = 2
        let lock = NSLock()
        let ai = FakeAI(onGenerate: { _ in
            lock.lock(); defer { lock.unlock() }
            if failures > 0 { failures -= 1; throw MemoryAIError.network("You're offline.") }
            return Data(Self.extraction.utf8)
        })
        let p = processor(library, ai: ai)
        p.processPending()
        await p.waitUntilIdle()
        XCTAssertEqual(library.item(item.id)?.processing, .processed)
        XCTAssertEqual(ai.generateCalls.count, 3)
        XCTAssertFalse(p.isPaused)
    }

    func testStaysPendingAndPausesWhenOffline() async {
        let library = MemoryLibrary(directory: dir, saveDelay: 60)
        let a = library.addNote("One"), b = library.addNote("Two")
        let ai = FakeAI(onGenerate: { _ in throw MemoryAIError.network("You're offline.") })
        let p = processor(library, ai: ai)
        p.concurrency = 1
        p.processPending()
        await p.waitUntilIdle()
        XCTAssertTrue(p.isPaused)
        XCTAssertEqual(p.lastError, .network("You're offline."))
        XCTAssertEqual(library.item(a.id)?.processing, .pending)
        XCTAssertEqual(library.item(b.id)?.processing, .pending)
        XCTAssertEqual(ai.generateCalls.count, 3, "one item tried (with retries); the rest wait")

        // Pending items survive a relaunch and resume.
        library.flush()
        let reopened = MemoryLibrary(directory: dir, saveDelay: 60)
        let p2 = processor(reopened, ai: FakeAI(onGenerate: { _ in Data(Self.extraction.utf8) }))
        p2.processPending()
        await p2.waitUntilIdle()
        XCTAssertEqual(reopened.items.map(\.processing), [.processed, .processed])
    }

    func testBadAnswerFailsTheItemWithAMessage() async {
        let library = MemoryLibrary(directory: dir, saveDelay: 60)
        let item = library.addNote("Bad")
        let ai = FakeAI(onGenerate: { _ in Data("[1, 2]".utf8) })
        let p = processor(library, ai: ai)
        p.processPending()
        await p.waitUntilIdle()
        XCTAssertEqual(library.item(item.id)?.processing, .failed(MemoryAIError.unexpectedFormat))
        XCTAssertEqual(library.item(item.id)?.attempts, 1)
        XCTAssertEqual(ai.generateCalls.count, 2, "one retry for a bad answer")

        ai.onGenerate = { _ in Data(Self.extraction.utf8) }
        p.retryFailed()
        await p.waitUntilIdle()
        XCTAssertEqual(library.item(item.id)?.processing, .processed)
    }

    func testBadKeyPausesUntilANewAIArrives() async {
        let library = MemoryLibrary(directory: dir, saveDelay: 60)
        let item = library.addNote("Key")
        let p = processor(library, ai: FakeAI(onGenerate: { _ in throw MemoryAIError.badKey }))
        p.processPending()
        await p.waitUntilIdle()
        XCTAssertTrue(p.isPaused)
        XCTAssertEqual(p.lastError?.needsSettings, true)
        XCTAssertEqual(library.item(item.id)?.processing, .pending)

        p.ai = FakeAI(onGenerate: { _ in Data(Self.extraction.utf8) })
        await p.waitUntilIdle()
        XCTAssertEqual(library.item(item.id)?.processing, .processed)
        XCTAssertFalse(p.isPaused)
    }

    func testSkippedItemsAreProcessedWhenAKeyAppears() async {
        let library = MemoryLibrary(directory: dir, saveDelay: 60)
        let item = library.addNote("Later")
        let p = processor(library, ai: nil)
        p.processPending()
        XCTAssertEqual(library.item(item.id)?.processing, .skipped)
        p.ai = FakeAI()
        await p.waitUntilIdle()
        XCTAssertEqual(library.item(item.id)?.processing, .processed)
        XCTAssertEqual(library.item(item.id)?.title, "Fake title")
    }

    func testLightweightItemsAreOnlyEmbeddedInOneBatch() async {
        let library = MemoryLibrary(directory: dir, saveDelay: 60)
        let ids = (0..<5).map { library.add(MemoryItem(kind: .task, origin: .auto, title: "Task \($0)", lightweight: true)).id }
        let ai = FakeAI()
        let p = processor(library, ai: ai)
        p.processPending()
        await p.waitUntilIdle()
        XCTAssertEqual(ai.generateCalls.count, 0)
        XCTAssertEqual(ai.embedCalls.count, 1)
        XCTAssertEqual(ai.embedCalls.first?.texts.count, 5)
        XCTAssertTrue(ids.allSatisfy { library.item($0)?.processing == .processed && library.vector(for: $0) != nil })
    }

    func testNewEmbeddingModelReembedsEverything() async {
        let library = MemoryLibrary(directory: dir, saveDelay: 60)
        let item = library.add(MemoryItem(title: "Old", summary: "S", processing: .processed))
        library.setVector([1, 0, 0], for: item.id, model: "old-model")
        let ai = FakeAI(model: "new-model", dimensions: 32)
        let p = processor(library, ai: ai)
        p.processPending()
        await p.waitUntilIdle()
        XCTAssertEqual(library.vectors.model, "new-model")
        XCTAssertEqual(library.vectors.dimensions, 32)
        XCTAssertNotNil(library.vector(for: item.id))
        XCTAssertEqual(ai.generateCalls.count, 0, "processed items are only re-embedded")
    }

    func testLinksAreFetchedAndMediaIsSentInline() async throws {
        let library = MemoryLibrary(directory: dir, saveDelay: 60)
        let link = library.addLink("https://example.com/post", note: "Worth reading")
        let fake = FakeTransport()
        fake.reply(body: Data(#"<html><head><title>Post title</title><meta property="og:image" content="/img.png"></head><body><nav>Menu</nav><article><p>The real article text.</p></article></body></html>"#.utf8))
        let ai = FakeAI(onGenerate: { _ in Data(#"{"title":"AI title","summary":"S","keyTakeaways":[],"people":[],"projects":[],"topics":[],"tags":[],"moments":[],"extractedText":""}"#.utf8) })
        let p = processor(library, ai: ai, fetcher: LinkFetcher(transport: fake.transport))
        p.processPending()
        await p.waitUntilIdle()
        let done = try XCTUnwrap(library.item(link.id))
        XCTAssertEqual(done.title, "Post title", "the page's own title wins")
        XCTAssertEqual(done.body, "Worth reading", "the user's note stays the body")
        XCTAssertEqual(done.extractedText, "The real article text.")
        XCTAssertEqual(done.imageURL, "https://example.com/img.png")
        XCTAssertTrue(ai.generateCalls[0].prompt.contains("The user's note: Worth reading"))
        XCTAssertTrue(ai.generateCalls[0].prompt.contains("The real article text."))
        XCTAssertFalse(ai.generateCalls[0].prompt.contains("Menu"))

        let photo = dir.appendingPathComponent("photo.png")
        try XCTUnwrap(MemoryLibrary.debugImagePNG(width: 20, height: 20)).write(to: photo)
        let image = try library.addFile(at: photo)
        ai.onGenerate = { _ in Data(#"{"title":"Whiteboard","summary":"S","keyTakeaways":[],"people":[],"projects":[],"topics":[],"tags":[],"moments":[],"extractedText":"Three boxes and an arrow."}"#.utf8) }
        p.processPending()
        await p.waitUntilIdle()
        XCTAssertEqual(ai.generateCalls.last?.parts.first?.mimeType, "image/png")
        XCTAssertEqual(library.item(image.id)?.extractedText, "Three boxes and an arrow.")
        XCTAssertEqual(library.item(image.id)?.title, "Whiteboard")
    }

    func testAutoProcessPicksUpNewItems() async throws {
        let library = MemoryLibrary(directory: dir, saveDelay: 60)
        let p = MemoryProcessor(library: library, ai: FakeAI(), autoProcess: true)
        p.retryDelays = []
        let item = library.addNote("Auto")
        for _ in 0..<500 where library.item(item.id)?.processing != .processed {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(library.item(item.id)?.processing, .processed)
    }
}
