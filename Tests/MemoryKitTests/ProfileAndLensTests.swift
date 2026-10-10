import XCTest
@testable import MemoryKit

@MainActor
final class ProfileSynthesizerTests: XCTestCase {
    var dir: URL!

    override func setUp() async throws { dir = makeTempDirectory() }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    func testMergeKeepsPinnedAndUserFactsAndDedupes() {
        let pinned = ProfileFact(text: "Founder of a design studio.", category: .role, pinned: true, source: .ai)
        let mine = ProfileFact(text: "Prefers short answers", category: .style, source: .user)
        let oldAI = ProfileFact(text: "Lives in Lisbon", category: .identity, source: .ai)
        let stale = ProfileFact(text: "Training for a marathon", category: .goal, source: .ai)
        let fresh = [
            ProfileFact(text: "founder of a design studio", category: .role, source: .ai),
            ProfileFact(text: "Lives in Lisbon.", category: .identity, source: .ai),
            ProfileFact(text: "Hiring a second designer", category: .goal, source: .ai),
            ProfileFact(text: "Hiring a second designer!", category: .goal, source: .ai),
        ]
        let merged = ProfileSynthesizer.merge(existing: [pinned, mine, oldAI, stale], new: fresh)
        XCTAssertEqual(merged.map(\.text), ["Founder of a design studio.", "Prefers short answers", "Lives in Lisbon.", "Hiring a second designer"])
        XCTAssertEqual(merged[2].id, oldAI.id, "a returning fact keeps its id")
        XCTAssertFalse(merged.contains { $0.id == stale.id }, "AI facts that aren't returned are dropped")
    }

    func testRefreshCallsTheModelAndSaves() async throws {
        let library = MemoryLibrary(directory: dir, saveDelay: 60)
        library.setLenses([.founder])
        library.addFact("Runs a startup", category: .role, pinned: true)
        for i in 0..<4 { library.addNote("Note \(i) about the seed round", createdAt: day(-i)) }
        XCTAssertTrue(ProfileSynthesizer.needsRefresh(library.profile, itemCount: library.count, now: day(0)))

        let ai = FakeAI(onGenerate: { call in
            XCTAssertTrue(call.prompt.contains("Facts confirmed by the user:\n- Runs a startup"))
            XCTAssertTrue(call.prompt.contains("Note 0 about the seed round"))
            XCTAssertTrue(call.system.contains("Today is Fri 9 Oct 2026"))
            return Data(#"{"facts": [{"text": "Raising a seed round", "category": "project"}, {"text": "runs a startup", "category": "role"}, {"text": "", "category": "other"}, {"text": "Odd", "category": "weird"}]}"#.utf8)
        })
        let synthesizer = ProfileSynthesizer(ai: ai, now: { day(0) })
        let ran = try await synthesizer.refreshIfNeeded(library)
        XCTAssertTrue(ran)
        XCTAssertEqual(library.profile.facts.map(\.text), ["Runs a startup", "Raising a seed round", "Odd"])
        XCTAssertEqual(library.profile.facts.last?.category, .other)
        XCTAssertEqual(library.profile.refreshedAt, day(0))
        XCTAssertEqual(library.profile.itemCountAtRefresh, 4)
        XCTAssertFalse(ProfileSynthesizer.needsRefresh(library.profile, itemCount: 5, now: day(0)))
        XCTAssertTrue(ProfileSynthesizer.needsRefresh(library.profile, itemCount: 14, now: day(0)))
        XCTAssertTrue(ProfileSynthesizer.needsRefresh(library.profile, itemCount: 5, now: day(2)))
        XCTAssertFalse(ProfileSynthesizer.needsRefresh(MemoryProfile(), itemCount: 2))
    }
}

final class LensTests: XCTestCase {
    func testVocabulary() {
        XCTAssertEqual(Lens.sales.vocabulary.projects, "Deals")
        XCTAssertEqual(Lens.marketer.vocabulary.projects, "Campaigns")
        XCTAssertEqual(Lens.engineer.vocabulary.projects, "Services")
        XCTAssertEqual(Lens.manager.vocabulary.projects, "Team goals")
        XCTAssertEqual(Lens.artist.vocabulary.projects, "Works")
        XCTAssertEqual(Lens.founder.vocabulary.insights, "Learnings")
        XCTAssertEqual(Lens.sales.vocabulary.insights, "Objections")
        XCTAssertEqual(Lens.marketer.vocabulary.insights, "Swipe file")
        XCTAssertEqual(Lens.sales.vocabulary.label(for: .promise), "Next steps")
        XCTAssertEqual(Lens.vocabulary(for: [.artist, .sales]).projects, "Works", "the primary lens names things")
        XCTAssertEqual(Lens.vocabulary(for: []), .neutral)
    }

    func testEveryLensIsComplete() {
        for lens in Lens.allCases {
            XCTAssertEqual(lens.askExamples.count, 4, "\(lens)")
            XCTAssertGreaterThanOrEqual(lens.outputs.count, 4, "\(lens)")
            XCTAssertTrue(lens.outputs.allSatisfy { !$0.name.isEmpty && !$0.description.isEmpty && $0.id.hasPrefix(lens.rawValue + ".") })
            XCTAssertGreaterThan(lens.guidance.count, 300, "\(lens)")
            XCTAssertFalse(lens.blurb.isEmpty)
            XCTAssertFalse(lens.guidance.contains("  "), "line continuations leave no double spaces")
        }
        XCTAssertEqual(Set(Lens.allCases.flatMap(\.outputs).map(\.id)).count, Lens.allCases.flatMap(\.outputs).count)
    }

    func testCombinedSelections() {
        let examples = Lens.askExamples(for: [.sales, .engineer])
        XCTAssertEqual(examples, [Lens.sales.askExamples[0], Lens.engineer.askExamples[0], Lens.sales.askExamples[1], Lens.engineer.askExamples[1]])
        XCTAssertEqual(Lens.askExamples(for: []).count, 4)
        XCTAssertEqual(Lens.outputs(for: [.sales, .sales]).count, Lens.sales.outputs.count)
        XCTAssertTrue(Lens.guidance(for: [.founder, .artist]).contains(Lens.artist.guidance))
        XCTAssertFalse(Lens.guidance(for: []).isEmpty)
    }

    func testExtractionPromptCarriesLensAndDates() {
        let system = MemoryPrompts.extractionSystem(lenses: [.engineer], profile: MemoryProfile(), now: day(0))
        XCTAssertTrue(system.contains(Lens.engineer.guidance))
        XCTAssertTrue(system.contains("Today is Fri 9 Oct 2026 (2026-10-09)."))
        XCTAssertTrue(system.contains("YYYY-MM-DD"))
        XCTAssertTrue(system.contains("never \"today\""))
        let item = MemoryItem(kind: .link, title: "Given", url: "https://e.com", capturedFrom: "Safari", createdAt: day(-3))
        let prompt = MemoryPrompts.extractionPrompt(for: item, content: "Body", attachmentNote: nil)
        XCTAssertTrue(prompt.contains("Saved: Tue 6 Oct 2026 (2026-10-06)"))
        XCTAssertTrue(prompt.contains("Title given by the user: Given"))
        XCTAssertTrue(prompt.contains("URL: https://e.com"))
    }

    func testSchemasRequireEveryField() throws {
        for schema in [MemoryPrompts.extractionSchema, MemoryPrompts.askSchema, MemoryPrompts.profileSchema] {
            let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(schema)) as! [String: Any]
            let properties = (object["properties"] as! [String: Any]).keys.sorted()
            XCTAssertEqual((object["required"] as! [String]).sorted(), properties)
        }
    }
}
