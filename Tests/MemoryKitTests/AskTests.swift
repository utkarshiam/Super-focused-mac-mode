import XCTest
@testable import MemoryKit

final class AskTests: XCTestCase {
    private let sources = [
        MemoryItem(title: "Pricing call", summary: "Northwind wants 20% off.", body: "Jordan said budget is tight.",
                   people: ["Jordan Lee"], projects: ["Northwind renewal"],
                   moments: [Moment(kind: .promise, text: "Send revised quote", due: day(3, hour: 0), direction: .mine)], createdAt: day(-2)),
        MemoryItem(title: "Security review", summary: "They need SOC 2.", createdAt: day(-400)),
    ]

    func testPromptNumbersSourcesWithAbsoluteDates() {
        let prompt = MemoryPrompts.askPrompt(question: "What does Northwind want?", history: [AskTurn(question: "Who is Jordan?", answer: "A buyer [1].")],
                                             sources: sources, now: day(0))
        XCTAssertTrue(prompt.contains("Question: What does Northwind want?"))
        XCTAssertTrue(prompt.contains("[1] \"Pricing call\" — note, Wed 7 Oct 2026"))
        XCTAssertTrue(prompt.contains("people: Jordan Lee"))
        XCTAssertTrue(prompt.contains("Promise: Send revised quote (due Mon 12 Oct 2026)"))
        XCTAssertTrue(prompt.contains("[2] \"Security review\" — note, Thu 4 Sep 2025"))
        XCTAssertTrue(prompt.contains("User: Who is Jordan?"))
        XCTAssertFalse(prompt.lowercased().contains("yesterday"))

        let profile = MemoryProfile(facts: [ProfileFact(text: "Runs sales at a startup", category: .role, pinned: true)])
        let system = MemoryPrompts.askSystem(lenses: [.sales], profile: profile, now: day(0))
        XCTAssertTrue(system.contains("Today is Fri 9 Oct 2026 (2026-10-09)."))
        XCTAssertTrue(system.contains("Use ONLY the sources"))
        XCTAssertTrue(system.contains("[n]") || system.contains("square brackets"))
        XCTAssertTrue(system.contains("Runs sales at a startup (confirmed by the user)"))
        XCTAssertTrue(system.contains(Lens.sales.guidance))
        XCTAssertTrue(system.contains("never \"today\""))
    }

    func testParseMapsCitationsAndDropsInventedOnes() throws {
        let json = #"""
        {"answer": "They want 20% off [1, 2] and SOC 2 [2][7]. Budget is tight [1].",
         "answerable": true,
         "citations": [{"source": 1, "quote": "Northwind wants 20% off."}, {"source": 9, "quote": "made up"}],
         "followUps": ["When is the renewal?", "  ", "Who signs?", "What else?", "Too many"]}
        """#
        let answer = try MemoryAsk.parse(Data(json.utf8), question: "Q", sources: sources)
        XCTAssertEqual(answer.text, "They want 20% off [1][2] and SOC 2 [2]. Budget is tight [1].")
        XCTAssertEqual(answer.citations.map(\.number), [1, 2])
        XCTAssertEqual(answer.citations[0].itemID, sources[0].id)
        XCTAssertEqual(answer.citations[0].quote, "Northwind wants 20% off.")
        XCTAssertNil(answer.citations[1].quote)
        XCTAssertEqual(answer.usedItemIDs, [sources[0].id, sources[1].id])
        XCTAssertEqual(answer.followUps, ["When is the renewal?", "Who signs?", "What else?"])
        XCTAssertTrue(answer.answered)
        XCTAssertEqual(answer.item(forCitation: 2)?.id, sources[1].id)
        XCTAssertNil(answer.item(forCitation: 3))
    }

    func testParseUnanswerable() throws {
        let json = #"{"answer": "Your memory doesn't say when the contract renews.", "answerable": false, "citations": [], "followUps": []}"#
        let answer = try MemoryAsk.parse(Data(json.utf8), question: "Q", sources: sources)
        XCTAssertFalse(answer.answered)
        XCTAssertTrue(answer.citations.isEmpty)
        XCTAssertThrowsError(try MemoryAsk.parse(Data(#"{"answerable": true}"#.utf8), question: "Q", sources: sources))
    }

    func testCitationRanges() {
        XCTAssertEqual(MemoryAsk.cleanMarkers("A [1-3].", valid: 1...5).0, "A [1][2][3].")
        XCTAssertEqual(MemoryAsk.cleanMarkers("A [9].", valid: 1...5).0, "A.")
        XCTAssertEqual(MemoryAsk.cleanMarkers("See [2]", valid: 1...5).1, [2])
    }

    @MainActor
    func testAskEndToEndWithFakeAI() async throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = MemoryLibrary(directory: dir, saveDelay: 60)
        library.setLenses([.sales])
        let a = library.add(sources[0])
        library.add(MemoryItem(title: "Garden", body: "Tomatoes"))

        let ai = FakeAI(onGenerate: { call in
            XCTAssertTrue(call.prompt.contains("[1] \"Pricing call\""))
            XCTAssertFalse(call.prompt.contains("Tomatoes"), "unrelated items aren't sources")
            return Data(#"{"answer": "20% off [1].", "answerable": true, "citations": [{"source": 1, "quote": "20% off"}], "followUps": ["What about SOC 2?"]}"#.utf8)
        })
        let asker = MemoryAsk(ai: ai, now: { day(0) })
        let answer = try await asker.ask("What discount does Northwind want?", in: library)
        XCTAssertEqual(answer.text, "20% off [1].")
        XCTAssertEqual(answer.usedItemIDs, [a.id])
        XCTAssertEqual(answer.turn.question, "What discount does Northwind want?")
        XCTAssertEqual(ai.generateCalls.count, 1)
        XCTAssertTrue(ai.generateCalls[0].system.contains("Deals") || ai.generateCalls[0].system.contains(Lens.sales.guidance))
    }

    @MainActor
    func testNothingFoundSkipsTheModel() async throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = MemoryLibrary(directory: dir, saveDelay: 60)
        library.addNote("Garden plans")
        let ai = FakeAI()
        let answer = try await MemoryAsk(ai: ai).ask("quarterly revenue numbers", in: library)
        XCTAssertFalse(answer.answered)
        XCTAssertEqual(answer.text, MemoryAsk.nothingFound)
        XCTAssertEqual(ai.generateCalls.count, 0)
    }
}
