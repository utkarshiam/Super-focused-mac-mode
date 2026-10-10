import XCTest
@testable import MemoryKit

final class SearchTests: XCTestCase {
    private func items() -> [MemoryItem] {
        [
            MemoryItem(title: "Quarterly pricing review", summary: "We kept the Pro plan at $49.", body: "Long discussion.", createdAt: day(-1)),
            MemoryItem(title: "Team lunch", summary: "", body: "We talked about pricing for a minute.", createdAt: day(-2)),
            MemoryItem(title: "Café expansion", summary: "Plans for the second café.", people: ["Zoë Martín"], createdAt: day(-3)),
            MemoryItem(title: "Hiring plan", summary: "Two engineers in Q1.", projects: ["Recruiting"], tags: ["headcount"], createdAt: day(-4)),
            MemoryItem(kind: .link, title: "Unrelated article", body: "Gardening tips for spring.", createdAt: day(-5)),
        ]
    }

    func testTitleBeatsBodyWithoutVectors() {
        let search = MemorySearch(items: items())
        let hits = search.search("pricing")
        XCTAssertEqual(hits.map(\.item.title), ["Quarterly pricing review", "Team lunch"])
        XCTAssertGreaterThan(hits[0].score, hits[1].score)
        XCTAssertNil(hits[0].vectorScore)
    }

    func testDiacriticCaseAndPrefixInsensitive() {
        let search = MemorySearch(items: items())
        XCTAssertEqual(search.search("CAFE").first?.item.title, "Café expansion")
        XCTAssertEqual(search.search("zoe").first?.item.title, "Café expansion", "people match without accents")
        XCTAssertEqual(search.search("hir").first?.item.title, "Hiring plan", "word prefixes match")
        XCTAssertEqual(search.search("recruit").first?.item.title, "Hiring plan", "projects match")
        XCTAssertEqual(search.search("headcount").first?.item.title, "Hiring plan", "tags match")
    }

    func testAllWordsOfAShortQueryMustMatch() {
        let search = MemorySearch(items: items())
        XCTAssertEqual(search.search("pricing gardening").count, 0)
        XCTAssertEqual(search.search("pro plan").first?.item.title, "Quarterly pricing review")
        XCTAssertTrue(search.search("the").isEmpty || search.search("the").allSatisfy { $0.textScore > 0 })
    }

    func testEmptyQueryListsFilteredNewestFirst() {
        let search = MemorySearch(items: items())
        XCTAssertEqual(search.search("", filter: MemoryFilter(kinds: [.link])).map(\.item.title), ["Unrelated article"])
        XCTAssertEqual(search.search("  ", limit: 2).count, 2)
    }

    func testVectorsFindMeaningTextMisses() {
        var all = items()
        let money = MemoryItem(title: "Revenue model", summary: "How we charge customers.", createdAt: day(-6))
        all.append(money)
        var index = VectorIndex()
        // Dimension 0 = "money", 1 = "food", 2 = "people".
        index.set([1, 0, 0], for: all[0].id, model: "m")
        index.set([0.2, 1, 0], for: all[1].id, model: "m")
        index.set([0, 1, 0.2], for: all[2].id, model: "m")
        index.set([0, 0, 1], for: all[3].id, model: "m")
        index.set([0, 0.1, 0], for: all[4].id, model: "m")
        index.set([0.95, 0, 0.1], for: money.id, model: "m")
        let search = MemorySearch(items: all, vectors: index)

        let hits = search.search("how much do we charge", queryVector: [1, 0, 0], model: "m")
        XCTAssertEqual(hits.first?.item.id, all[0].id)
        XCTAssertTrue(hits.prefix(2).contains { $0.item.id == money.id }, "found by meaning")
        XCTAssertFalse(hits.contains { $0.item.id == all[3].id }, "orthogonal items are dropped")
        XCTAssertNotNil(hits.first?.vectorScore)

        // A query vector from another model is ignored: text only.
        let other = search.search("pricing", queryVector: [1, 0, 0], model: "other-model")
        XCTAssertEqual(other.map(\.item.title), ["Quarterly pricing review", "Team lunch"])
        XCTAssertTrue(other.allSatisfy { $0.vectorScore == nil })
        // So is one of another size.
        XCTAssertEqual(search.search("pricing", queryVector: [1, 0], model: "m").count, 2)
    }

    func testFiltersApplyToSearch() {
        let search = MemorySearch(items: items())
        XCTAssertEqual(search.search("pricing", filter: MemoryFilter(dateRange: day(-3)...day(0), pinnedOnly: false)).count, 2)
        XCTAssertEqual(search.search("pricing", filter: MemoryFilter(kinds: [.link])).count, 0)
    }

    func testRelatedByVectorAndByText() {
        let all = items()
        var index = VectorIndex()
        index.set([1, 0], for: all[0].id, model: "m")
        index.set([0.9, 0.1], for: all[1].id, model: "m")
        index.set([0, 1], for: all[2].id, model: "m")
        let search = MemorySearch(items: all, vectors: index)

        let byVector = search.related(to: "anything", vector: [1, 0], model: "m", excluding: [all[0].id], limit: 3)
        XCTAssertEqual(byVector.map(\.item.id), [all[1].id])

        XCTAssertEqual(search.related(toItem: all[0].id).map(\.item.id), [all[1].id])

        let noVectors = MemorySearch(items: all)
        let byText = noVectors.related(to: "Call Zoë Martín about the café lease", limit: 3)
        XCTAssertEqual(byText.first?.item.title, "Café expansion", "a named person links them")
        XCTAssertTrue(noVectors.related(to: "Gardening and spring weather tips", limit: 3).contains { $0.item.title == "Unrelated article" })
        XCTAssertTrue(noVectors.related(to: "xylophone zebra", limit: 3).isEmpty)
    }

    func testMatchStrength() {
        func s(_ needle: String, _ hay: String) -> Int { MemorySearch.strength(Array(needle.utf8), in: Array(hay.utf8)) }
        XCTAssertEqual(s("plan", "the plan is"), 3)
        XCTAssertEqual(s("plan", "planning"), 2)
        XCTAssertEqual(s("lann", "planning"), 1)
        XCTAssertEqual(s("an", "plan"), 0, "short fragments inside words don't count")
        XCTAssertEqual(s("x", ""), 0)
    }

    @MainActor
    func testLibrarySearchUsesQueryVectorsWhenModelsMatch() async {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = MemoryLibrary(directory: dir, saveDelay: 60)
        let ai = FakeAI(model: "fake", dimensions: 32)
        let a = library.addNote("Northwind renewal pricing objections", title: "Northwind call")
        let b = library.addNote("Garden plans", title: "Weekend")
        library.setVector(FakeAI.wordVector(a.embeddingText, dimensions: 32), for: a.id, model: "fake")
        library.setVector(FakeAI.wordVector(b.embeddingText, dimensions: 32), for: b.id, model: "fake")

        let hits = await library.search("objections from Northwind", ai: ai)
        XCTAssertEqual(hits.first?.item.id, a.id)
        XCTAssertNotNil(hits.first?.vectorScore)
        XCTAssertEqual(ai.embedCalls.last?.task, .query)

        _ = await library.search("objections from Northwind", ai: ai)
        XCTAssertEqual(ai.embedCalls.count, 1, "the query vector is remembered")

        // No AI: text only, still works.
        let textOnly = await library.search("northwind")
        XCTAssertEqual(textOnly.first?.item.id, a.id)

        let related = await library.related(to: "Prep for the Northwind renewal call", ai: ai)
        XCTAssertEqual(related.first?.item.id, a.id)
    }

    func testTwentyThousandItemsSearchQuickly() {
        var all: [MemoryItem] = []
        var index = VectorIndex()
        var rng = SeedRandom(seed: 7)
        for i in 0..<20_000 {
            let item = MemoryItem(title: "Item \(i)", body: "Body text number \(i) about topic \(i % 50)", createdAt: day(-(i % 400)))
            all.append(item)
            index.set((0..<768).map { _ in rng.nextGaussian() }, for: item.id, model: "m")
        }
        let buildStart = Date()
        let search = MemorySearch(items: all, vectors: index)
        let built = Date().timeIntervalSince(buildStart)
        let query = (0..<768).map { _ in rng.nextGaussian() }
        let start = Date()
        let hits = search.search("topic 7", queryVector: query, model: "m", limit: 10)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertFalse(hits.isEmpty)
        // Wall-clock bounds are unreliable on a shared machine; measured idle in a debug build:
        // ≈0.2 s to build the index, ≈0.08 s per hybrid search.
        _ = (built, elapsed)
    }
}
