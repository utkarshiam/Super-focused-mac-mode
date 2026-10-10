import XCTest
@testable import MemoryKit

@MainActor
final class BrainInsightsTests: XCTestCase {
    var dir: URL!
    override func setUp() async throws { dir = makeTempDirectory() }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    /// Three themes plus two items in different topics that share an idea (a common vector component).
    private func setUpLinked(_ folder: URL? = nil) async -> (MemoryLibrary, MemoryBrain, MemoryItem, MemoryItem) {
        let library = themedLibrary(folder ?? dir, themes: [Theme(label: "pricing", count: 8, projects: ["Pricing refresh"]),
                                                  Theme(label: "hiring", count: 8, people: ["Maya Chen"]),
                                                  Theme(label: "travel", count: 8)])
        let brain = MemoryBrain.test(library)
        await brain.organizeNow(ai: nil)
        var rng = SeedRandom(seed: 42)
        let shared = (0..<48).map { _ in rng.nextGaussian() }
        let pricingVector = library.vector(for: library.items.first { $0.topics == ["pricing"] }!.id)!
        let hiringVector = library.vector(for: library.items.first { $0.topics == ["hiring"] }!.id)!
        let x = library.add(MemoryItem(title: "Annual plans and retention", summary: "Annual plans keep customers longer.",
                                       topics: ["pricing"], createdAt: day(0, hour: 9), processing: .processed))
        let y = library.add(MemoryItem(title: "Retention of engineers", summary: "Engineers stay longer with clear growth plans.",
                                       topics: ["hiring"], createdAt: day(0, hour: 10), processing: .processed))
        library.setVector((0..<48).map { pricingVector[$0] * 0.5 + shared[$0] * 0.12 }, for: x.id, model: "fake-embed")
        library.setVector((0..<48).map { hiringVector[$0] * 0.5 + shared[$0] * 0.12 }, for: y.id, model: "fake-embed")
        brain.refresh()
        return (library, brain, x, y)
    }

    func testFindsCrossTopicLinksOnceWithReasons() async throws {
        let (_, brain, x, y) = await setUpLinked()
        XCTAssertEqual(brain.primaryTopic(of: x.id)?.name, "Pricing")
        XCTAssertEqual(brain.primaryTopic(of: y.id)?.name, "Hiring")
        let found = await brain.refreshConnections(ai: nil, force: true)
        XCTAssertEqual(found.count, 1)
        let c = try XCTUnwrap(found.first)
        XCTAssertEqual(Set([c.a, c.b]), [x.id, y.id])
        XCTAssertTrue(c.reason.hasPrefix("Both mention "), c.reason)
        XCTAssertTrue(c.reason.contains("retention") || c.reason.contains("longer"), c.reason)
        XCTAssertEqual(brain.connections.map(\.id), [c.id])

        // Seen pairs are never shown again; dismissing hides it.
        let again = await brain.refreshConnections(ai: nil, force: true)
        XCTAssertTrue(again.isEmpty)
        brain.dismissConnection(c.id)
        XCTAssertTrue(brain.connections.isEmpty)
        // Throttled without force.
        let throttled = await brain.refreshConnections(ai: nil)
        XCTAssertTrue(throttled.isEmpty)
    }

    func testAIWritesTheReasonOrDropsTheLink() async throws {
        let (_, brain, _, _) = await setUpLinked()
        let ai = brainAI()
        let found = await brain.refreshConnections(ai: ai, force: true)
        XCTAssertEqual(found.first?.reason, "Both are about the same idea.")
        let call = try XCTUnwrap(ai.generateCalls.last)
        XCTAssertTrue(call.system.contains("links the user may not have made"))
        XCTAssertTrue(call.prompt.contains("A: \"Annual plans and retention\"") || call.prompt.contains("B: \"Annual plans and retention\""))

        let second = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: second) }
        let (_, other, _, _) = await setUpLinked(second)
        let unrelated = FakeAI(onGenerate: { _ in Data(#"{"links": [{"pair": 1, "reason": ""}]}"#.utf8) })
        let none = await other.refreshConnections(ai: unrelated, force: true)
        XCTAssertTrue(none.isEmpty, "AI found no meaningful link")
        XCTAssertTrue(other.connections.isEmpty)
    }

    func testNoConnectionsWithoutStandoutPairs() {
        var rng = SeedRandom(seed: 9)
        var vectors = VectorIndex()
        var infos: [BrainInsights.ItemInfo] = []
        for i in 0..<20 {
            let item = MemoryItem(title: "Item \(i)", createdAt: day(-i))
            vectors.set((0..<64).map { _ in rng.nextGaussian() }, for: item.id, model: "m")
            infos.append(.init(item: item, primaryTopic: UUID(), entities: []))
        }
        XCTAssertTrue(BrainInsights.findConnections(infos, vectors: vectors, seen: []).isEmpty)
    }

    func testSharedEntitiesAndSeenPairsRuleOutAConnection() {
        var rng = SeedRandom(seed: 11)
        var vectors = VectorIndex()
        let base = (0..<64).map { _ in rng.nextGaussian() }
        let a = MemoryItem(title: "A"), b = MemoryItem(title: "B")
        vectors.set(base.map { $0 + 0.1 * rng.nextGaussian() }, for: a.id, model: "m")
        vectors.set(base.map { $0 + 0.1 * rng.nextGaussian() }, for: b.id, model: "m")
        var others: [BrainInsights.ItemInfo] = []
        for i in 0..<12 {
            let o = MemoryItem(title: "O\(i)")
            vectors.set((0..<64).map { _ in rng.nextGaussian() }, for: o.id, model: "m")
            others.append(.init(item: o, primaryTopic: UUID(), entities: []))
        }
        let shared = UUID()
        let linked = [BrainInsights.ItemInfo(item: a, primaryTopic: UUID(), entities: [shared]),
                      BrainInsights.ItemInfo(item: b, primaryTopic: UUID(), entities: [shared])]
        XCTAssertTrue(BrainInsights.findConnections(linked + others, vectors: vectors, seen: []).isEmpty)
        let free = [BrainInsights.ItemInfo(item: a, primaryTopic: UUID(), entities: []),
                    BrainInsights.ItemInfo(item: b, primaryTopic: UUID(), entities: [])]
        let found = BrainInsights.findConnections(free + others, vectors: vectors, seen: [])
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(Set([found[0].a, found[0].b]), [a.id, b.id])
        XCTAssertTrue(BrainInsights.findConnections(free + others, vectors: vectors, seen: [BrainConnection.pairKey(a.id, b.id)]).isEmpty)
    }

    func testWeeklyDigestStructureAndTitle() async throws {
        let library = MemoryLibrary(directory: dir, saveDelay: 60)
        library.add(MemoryItem(title: "Before the week", createdAt: day(-5)))  // Sun 4 Oct
        let mon = library.add(MemoryItem(title: "Pricing decision", moments: [Moment(kind: .decision, text: "Price at $45 a seat.")],
                                         createdAt: day(-4), processing: .processed))
        library.add(MemoryItem(title: "Promise", moments: [Moment(kind: .promise, text: "Send the quote.", due: day(2), direction: .mine),
                                                         Moment(kind: .promise, text: "Done already.", done: true)],
                               createdAt: day(0), processing: .processed))
        let brain = MemoryBrain.test(library)
        let week = BrainInsights.week(of: day(0))
        XCTAssertEqual(MemoryDates.dayKey(week.start), "2026-10-05")
        XCTAssertEqual(MemoryDates.dayKey(week.end), "2026-10-12")
        let d = brain.digest(for: day(0))
        XCTAssertEqual(d.itemCount, 2)
        XCTAssertEqual(d.decisions.map(\.text), ["Price at $45 a seat."])
        XCTAssertEqual(d.decisions.first?.itemID, mon.id)
        XCTAssertEqual(d.openPromises.map(\.text), ["Send the quote."])
        XCTAssertFalse(d.isWritten)
        XCTAssertTrue(d.title.hasPrefix("What you learned, "))
        XCTAssertTrue(d.title.contains("5") && d.title.contains("11"), d.title)
        XCTAssertFalse(d.title.contains("Today"))

        let ai = brainAI()
        let written = try await brain.writeDigest(for: day(0), ai: ai)
        XCTAssertEqual(written.text, "- You learned a thing [1].\n- And another [2].")
        XCTAssertEqual(written.sources.count, 2)
        let call = try XCTUnwrap(ai.generateCalls.first)
        XCTAssertTrue(call.prompt.hasPrefix("Week: Mon 5 Oct 2026 – Sun 11 Oct 2026. 2 items saved."))
        XCTAssertTrue(call.prompt.contains("Decisions:\n- Price at $45 a seat. [1]"))
        XCTAssertTrue(call.prompt.contains("due Sun 11 Oct 2026"))
        XCTAssertTrue(brain.digest(for: day(-1)).isWritten, "cached for the week")
        library.add(MemoryItem(title: "Late addition", createdAt: day(1)))
        XCTAssertFalse(brain.digest(for: day(0)).isWritten, "a new item makes the cached text stale")
    }

    func testDigestTitleAcrossMonthsAndYears() {
        let cal = Calendar.current
        let start = cal.date(from: DateComponents(year: 2026, month: 9, day: 28))!
        let end = cal.date(byAdding: .day, value: 7, to: start)!
        let title = BrainInsights.digestTitle(start: start, end: end, now: day(0))
        XCTAssertTrue(title.contains(" – "), title)
        let old = BrainInsights.digestTitle(start: cal.date(byAdding: .year, value: -1, to: start)!,
                                            end: cal.date(byAdding: .year, value: -1, to: end)!, now: day(0))
        XCTAssertTrue(old.contains("2025"), old)
    }

    func testWeekRangeIsDayFirstWithRealDates() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/London")!
        let posix = Locale(identifier: "en_US_POSIX")
        func date(_ y: Int, _ m: Int, _ d: Int) -> Date { cal.date(from: DateComponents(year: y, month: m, day: d))! }
        func range(_ start: Date, now: Date) -> String {
            BrainInsights.weekRange(start: start, end: cal.date(byAdding: .day, value: 7, to: start)!, now: now, calendar: cal, locale: posix)
        }
        let now = date(2026, 10, 10)
        XCTAssertEqual(range(date(2026, 10, 5), now: now), "5–11 Oct")
        XCTAssertEqual(range(date(2026, 9, 28), now: now), "28 Sep – 4 Oct")
        XCTAssertEqual(range(date(2025, 10, 6), now: now), "6–12 Oct 2025")
        XCTAssertEqual(range(date(2025, 12, 29), now: date(2026, 1, 2)), "29 Dec 2025 – 4 Jan")
        XCTAssertEqual(range(date(2025, 12, 29), now: date(2027, 1, 2)), "29 Dec 2025 – 4 Jan 2026")
        // Even a month-first locale keeps the day first.
        let us = BrainInsights.digestTitle(start: date(2026, 10, 5), end: date(2026, 10, 12), now: now, calendar: cal,
                                           locale: Locale(identifier: "en_US"))
        XCTAssertEqual(us, "What you learned, 5–11 Oct")
    }
}
