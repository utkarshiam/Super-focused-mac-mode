import XCTest
@testable import MemoryKit

final class BrainCitationTests: XCTestCase {
    func testCompactingRenumbersInOrderOfUseAndDropsBadOnes() {
        let r = BrainPrompts.compactCitations("A [3]. B [1][3]. C [9]. D [0]. Keep [x] and [12345].", count: 4)
        XCTAssertEqual(r.text, "A [1]. B [2][1]. C. D. Keep [x] and [12345].")
        XCTAssertEqual(r.order, [3, 1])
        XCTAssertEqual(BrainPrompts.stripCitations("Fact [1][2]"), "Fact")
        XCTAssertEqual(BrainPrompts.remapCitations("x [2] y [1]") { $0 == 1 ? 5 : nil }, "x y [5]")
    }

    func testParseSynthesisMapsCitationsToItems() throws {
        let items = [MemoryItem(title: "One"), MemoryItem(title: "Two"), MemoryItem(title: "Three")]
        let json = """
        {"summary": "Seed target is $2M [3]. Retention matters [1][3]. Invented [7].",
         "keyFacts": [{"text": "Target $2M [3]", "sources": [3, 3]}, {"text": "Orphan", "sources": [8]}, {"text": "target $2M", "sources": [1]}],
         "openQuestions": ["When does the term sheet arrive?", "when does the term sheet arrive?", ""],
         "disagreements": [{"text": "Target: $1.5M vs $2M", "sources": [2, 3]}]}
        """
        let a = try BrainPrompts.parseSynthesis(Data(json.utf8), items: items)
        XCTAssertEqual(a.summary, "Seed target is $2M [1]. Retention matters [2][1]. Invented.")
        XCTAssertEqual(a.summarySources, [items[2].id, items[0].id])
        XCTAssertEqual(a.keyFacts.map(\.text), ["Target $2M"], "no source no claim; duplicates dropped")
        XCTAssertEqual(a.keyFacts[0].itemIDs, [items[2].id])
        XCTAssertEqual(a.openQuestions, ["When does the term sheet arrive?"])
        XCTAssertEqual(a.disagreements[0].itemIDs, [items[1].id, items[2].id])
        XCTAssertThrowsError(try BrainPrompts.parseSynthesis(Data("{}".utf8), items: items))
    }
}

@MainActor
final class BrainPagesTests: XCTestCase {
    var dir: URL!
    override func setUp() async throws { dir = makeTempDirectory() }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    private func library() -> MemoryLibrary {
        let library = MemoryLibrary(directory: dir, saveDelay: 60)
        library.setLenses([.sales])
        library.add(MemoryItem(title: "Quote call", summary: "Rohan wants 8% off.", people: ["Rohan Mehta"], projects: ["Mehta Traders"],
                               createdAt: day(-5), processing: .processed))
        library.add(MemoryItem(title: "PO follow-up", summary: "Rohan will send the PO.", people: ["Rohan Mehta"], projects: ["Mehta Traders"],
                               createdAt: day(-1), processing: .processed))
        library.add(MemoryItem(title: "Solo", people: ["Priya Nair"], createdAt: day(-2), processing: .processed))
        return library
    }

    func testSynthesisPromptIsGroundedDatedAndLensAware() async throws {
        let library = library()
        let brain = MemoryBrain.test(library)
        let rohan = try XCTUnwrap(brain.entity(named: "Rohan Mehta", kind: .person))
        let ai = brainAI()
        try await brain.synthesize(rohan.id, ai: ai)
        let call = try XCTUnwrap(ai.generateCalls.first)
        XCTAssertTrue(call.system.contains("living page about one person"))
        XCTAssertTrue(call.system.contains("Use ONLY the items"))
        XCTAssertTrue(call.system.contains("Today is Fri 9 Oct 2026"))
        XCTAssertTrue(call.system.contains("\"Deals\""), "sales lens words")
        XCTAssertTrue(call.prompt.hasPrefix("Person: Rohan Mehta"))
        XCTAssertTrue(call.prompt.contains("[1] \"Quote call\" — note, Sun 4 Oct 2026"), "oldest first, real dates")
        XCTAssertTrue(call.prompt.contains("[2] \"PO follow-up\""))
        XCTAssertFalse(call.prompt.contains("NEW"), "first page: nothing is marked new")

        let page = try XCTUnwrap(brain.entity(rohan.id))
        XCTAssertEqual(page.summary, "First point [1]. Second point [2][1]. Bad cite.")
        let quote = library.items.first { $0.title == "Quote call" }!.id, po = library.items.first { $0.title == "PO follow-up" }!.id
        XCTAssertEqual(page.summarySources, [quote, po])
        XCTAssertEqual(page.summarySource(2), po)
        XCTAssertEqual(page.keyFacts.map(\.text), ["A fact"])
        XCTAssertEqual(page.openQuestions, ["What next?"])
        XCTAssertEqual(page.disagreements.first?.itemIDs, [quote, po])
        XCTAssertEqual(page.synthesizedAt, day(0))
        XCTAssertEqual(page.itemCountAtSynthesis, 2)
    }

    func testStaleEntitiesAndThrottling() async throws {
        let library = library()
        let brain = MemoryBrain.test(library)
        XCTAssertEqual(Set(brain.staleEntities().map(\.name)), ["Rohan Mehta", "Mehta Traders"], "single-item entities have no page")
        let ai = brainAI()
        let written = await brain.synthesizeStale(ai: ai, limit: 10)
        XCTAssertEqual(written, 2)
        XCTAssertEqual(ai.generateCalls.count, 2)
        XCTAssertTrue(brain.staleEntities().isEmpty)
        let none = await brain.synthesizeStale(ai: ai)
        XCTAssertEqual(none, 0, "nothing due, no calls")
        XCTAssertEqual(ai.generateCalls.count, 2)

        // One new item: due only after the minimum interval.
        library.add(MemoryItem(title: "Price agreed", people: ["Rohan Mehta"], createdAt: day(0, hour: 15), processing: .processed))
        brain.refresh()
        XCTAssertTrue(brain.staleEntities().isEmpty, "throttled")
        brain.now = { day(1) }
        XCTAssertEqual(brain.staleEntities().map(\.name), ["Rohan Mehta"])
        await brain.synthesizeStale(ai: ai)
        let prompt = ai.generateCalls.last!.prompt
        XCTAssertTrue(prompt.contains("Previous summary (update it):\nFirst point [1]. Second point [2][1]. Bad cite."))
        XCTAssertTrue(prompt.contains("NEW \"Price agreed\""))
    }

    func testUserTextIsKept() async throws {
        let library = library()
        let brain = MemoryBrain.test(library)
        let rohan = brain.entity(named: "Rohan Mehta", kind: .person)!.id
        try await brain.synthesize(rohan, ai: brainAI())
        let aiFact = brain.entity(rohan)!.keyFacts[0]
        brain.setFactPinned(aiFact.id, in: rohan, true)
        let mine = try XCTUnwrap(brain.addFact("Prefers WhatsApp", to: rohan))
        brain.editSummary(rohan, text: "My own words about Rohan.")
        XCTAssertTrue(brain.entity(rohan)!.summaryEditedByUser)

        let ai = brainAI()
        try await brain.synthesize(rohan, ai: ai)
        let page = brain.entity(rohan)!
        XCTAssertEqual(page.summary, "My own words about Rohan.")
        XCTAssertTrue(page.summaryEditedByUser)
        XCTAssertEqual(page.keyFacts.map(\.text), ["Prefers WhatsApp", "A fact"], "the AI repeat of a pinned fact is dropped")
        XCTAssertEqual(page.keyFacts.first?.id, mine.id)
        XCTAssertTrue(ai.generateCalls[0].prompt.contains("Facts confirmed by the user:\n- Prefers WhatsApp\n- A fact"))
        XCTAssertTrue(ai.generateCalls[0].prompt.contains("The user's own summary (true; don't repeat it):\nMy own words about Rohan."))

        brain.editSummary(rohan, text: nil)
        try await brain.synthesize(rohan, ai: brainAI())
        XCTAssertEqual(brain.entity(rohan)!.summary, "First point [1]. Second point [2][1]. Bad cite.")
    }

    func testFailuresBackOffAndStopTheBatch() async throws {
        let library = library()
        let brain = MemoryBrain.test(library)
        let ai = FakeAI(onGenerate: { _ in throw MemoryAIError.rateLimited })
        let written = await brain.synthesizeStale(ai: ai, limit: 10)
        XCTAssertEqual(written, 0)
        XCTAssertEqual(brain.lastError, .rateLimited)
        XCTAssertEqual(ai.generateCalls.count, 2, "the first pair runs together, then the batch stops")
        XCTAssertTrue(brain.staleEntities().isEmpty, "a failed entity waits an hour")
        brain.now = { day(0).addingTimeInterval(3700) }
        XCTAssertEqual(brain.staleEntities().count, 2)
    }

    func testStalenessRules() {
        var e = BrainEntity(kind: .topic, name: "X", itemCount: 1)
        XCTAssertFalse(EntitySynthesizer.isStale(e, latestItemChange: nil, now: day(0)), "one item")
        e.itemCount = 2
        XCTAssertTrue(EntitySynthesizer.isStale(e, latestItemChange: nil, now: day(0)), "never written")
        e.synthesizedAt = day(0)
        e.itemCountAtSynthesis = 2
        XCTAssertFalse(EntitySynthesizer.isStale(e, latestItemChange: day(-1), now: day(1)), "nothing new")
        XCTAssertTrue(EntitySynthesizer.isStale(e, latestItemChange: day(0, hour: 13), now: day(1)), "an item changed")
        e.itemCount = 5
        XCTAssertTrue(EntitySynthesizer.isStale(e, latestItemChange: nil, now: day(0)), "a burst skips the interval")
        let area = BrainEntity(kind: .area, name: "A", itemCount: 10)
        XCTAssertFalse(EntitySynthesizer.isStale(area, latestItemChange: nil, now: day(0)), "areas have no page")
    }
}
