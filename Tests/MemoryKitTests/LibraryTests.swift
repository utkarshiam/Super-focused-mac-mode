import XCTest
@testable import MemoryKit

@MainActor
final class LibraryTests: XCTestCase {
    var dir: URL!

    override func setUp() async throws {
        dir = makeTempDirectory()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testAddKeepsNewestFirstAndPersists() throws {
        let library = MemoryLibrary(directory: dir, saveDelay: 60)
        let old = library.addNote("Old note", createdAt: day(-5))
        let new = library.addNote("New note", createdAt: day(0))
        let middle = library.addNote("Middle", createdAt: day(-2))
        XCTAssertEqual(library.items.map(\.id), [new.id, middle.id, old.id])
        XCTAssertEqual(library.item(middle.id)?.body, "Middle")

        library.flush()
        let reopened = MemoryLibrary(directory: dir)
        XCTAssertEqual(reopened.items.map(\.id), [new.id, middle.id, old.id])
        XCTAssertEqual(reopened.items.first?.body, "New note")

        let json = try String(contentsOf: library.fileURL, encoding: .utf8)
        XCTAssertTrue(json.contains("\"version\" : 1"))
        XCTAssertTrue(json.contains("\n  "), "pretty-printed")
    }

    func testDebouncedSaveWritesOnItsOwn() async throws {
        let library = MemoryLibrary(directory: dir, saveDelay: 0.05)
        library.addNote("Saved later")
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.fileURL.path))
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: library.fileURL.path) {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        library.flush() // waits for the background write
        XCTAssertEqual(MemoryLibrary(directory: dir).items.first?.body, "Saved later")
    }

    func testUpdateRemovePinAndMoments() {
        let library = MemoryLibrary(directory: dir, saveDelay: 60)
        var item = library.add(MemoryItem(title: "T", moments: [Moment(kind: .promise, text: "Send it")]))
        item.title = "Renamed"
        library.update(item)
        XCTAssertEqual(library.item(item.id)?.title, "Renamed")

        library.setPinned(item.id, true)
        XCTAssertEqual(library.item(item.id)?.pinned, true)

        let momentID = item.moments[0].id
        library.setMomentDone(momentID, in: item.id, true)
        XCTAssertEqual(library.item(item.id)?.moments.first?.done, true)

        let revision = library.revision
        library.update(item.id) { $0.createdAt = day(-30) }
        XCTAssertGreaterThan(library.revision, revision)

        library.remove(item.id)
        XCTAssertNil(library.item(item.id))
        XCTAssertEqual(library.count, 0)
    }

    func testUpsertBySourceRefUpdatesInsteadOfDuplicating() {
        let library = MemoryLibrary(directory: dir, saveDelay: 60)
        let ref = SourceRef.note(UUID())
        let first = library.add(MemoryItem(origin: .auto, sourceRef: ref, title: "Plan", body: "v1", tags: ["Work"], createdAt: day(-3)))
        library.update(first.id) { $0.processing = .processed; $0.pinned = true }
        library.setVector([1, 0, 0], for: first.id, model: "m")

        let second = library.upsert(MemoryItem(origin: .auto, sourceRef: ref, title: "Plan", body: "v2", tags: ["urgent"]))
        XCTAssertEqual(second.id, first.id)
        XCTAssertEqual(library.count, 1)
        XCTAssertEqual(library.item(first.id)?.body, "v2")
        XCTAssertEqual(library.item(first.id)?.pinned, true, "pinned survives")
        XCTAssertEqual(library.item(first.id)?.createdAt, day(-3))
        XCTAssertEqual(library.item(first.id)?.tags, ["work", "urgent"])
        XCTAssertEqual(library.item(first.id)?.processing, .pending, "new content is processed again")
        XCTAssertNil(library.vector(for: first.id), "its old vector is dropped")

        // Same content again: nothing to redo.
        library.update(first.id) { $0.processing = .processed }
        library.upsert(MemoryItem(origin: .auto, sourceRef: ref, title: "Plan", body: "v2"))
        XCTAssertEqual(library.item(first.id)?.processing, .processed)

        // add() with a known sourceRef also upserts.
        library.add(MemoryItem(sourceRef: ref, body: "v3"))
        XCTAssertEqual(library.count, 1)
        XCTAssertEqual(library.item(sourceRef: ref)?.body, "v3")
    }

    func testAddLinkDedupesByNormalizedURL() {
        let library = MemoryLibrary(directory: dir, saveDelay: 60)
        let a = library.addLink("https://www.example.com/post?utm_source=mail")
        let b = library.addLink("http://example.com/post/", note: "Read this again")
        XCTAssertEqual(a.id, b.id)
        XCTAssertEqual(library.count, 1)
        XCTAssertEqual(library.item(a.id)?.body, "Read this again")
        XCTAssertEqual(library.item(a.id)?.kind, .link)
    }

    func testFilesAreCopiedInAndRemovedWithTheItem() throws {
        let library = MemoryLibrary(directory: dir, saveDelay: 60)
        let source = dir.appendingPathComponent("outside.pdf")
        try Data("%PDF-1.4 fake".utf8).write(to: source)

        let item = try library.addFile(at: source, note: "The deck")
        XCTAssertEqual(item.kind, .pdf)
        XCTAssertEqual(item.title, "outside", "documents keep their file name as a title")
        let attachment = try XCTUnwrap(item.attachments.first)
        XCTAssertEqual(attachment.mimeType, "application/pdf")
        XCTAssertEqual(attachment.byteCount, 13)
        let stored = library.fileURL(for: attachment, of: item.id)
        XCTAssertTrue(stored.path.hasPrefix(library.filesURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stored.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "copied, not moved")

        let second = try library.attachData(Data("hello".utf8), name: "outside.pdf", to: item.id)
        XCTAssertNotEqual(second.fileName, attachment.fileName, "names don't collide")
        XCTAssertEqual(library.item(item.id)?.attachments.count, 2)

        library.removeAttachment(second.id, from: item.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.fileURL(for: second, of: item.id).path))

        library.remove(item.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stored.deletingLastPathComponent().path))
    }

    func testFiltersAndDirectories() {
        let library = MemoryLibrary(directory: dir, saveDelay: 60)
        library.add(MemoryItem(kind: .note, title: "A", people: ["Priya Shah"], projects: ["Seed round"], topics: ["fundraising"],
                               moments: [Moment(kind: .decision, text: "Go SAFE")], createdAt: day(-1)))
        library.add(MemoryItem(kind: .link, origin: .phone, title: "B", people: ["priya shah", "Alex Kim"], tags: ["pricing"], createdAt: day(-10)))
        library.add(MemoryItem(kind: .message, title: "C", people: ["Alex Kim"], projects: ["Seed round"],
                               moments: [Moment(kind: .promise, text: "Send deck", done: true)], pinned: true, createdAt: day(-20)))

        XCTAssertEqual(library.items(matching: MemoryFilter(kinds: [.link])).map(\.title), ["B"])
        XCTAssertEqual(library.items(matching: MemoryFilter(origins: [.phone])).map(\.title), ["B"])
        XCTAssertEqual(library.items(matching: MemoryFilter(person: "PRIYA SHAH")).map(\.title), ["A", "B"])
        XCTAssertEqual(library.items(matching: MemoryFilter(project: "seed round")).map(\.title), ["A", "C"])
        XCTAssertEqual(library.items(matching: MemoryFilter(topic: "pricing")).map(\.title), ["B"])
        XCTAssertEqual(library.items(matching: MemoryFilter(momentKind: .decision)).map(\.title), ["A"])
        XCTAssertEqual(library.items(matching: MemoryFilter(momentKind: .promise, openOnly: true)).map(\.title), [])
        XCTAssertEqual(library.items(matching: MemoryFilter(dateRange: day(-15)...day(0))).map(\.title), ["A", "B"])
        XCTAssertEqual(library.items(matching: MemoryFilter(pinnedOnly: true)).map(\.title), ["C"])
        XCTAssertEqual(library.items(matching: MemoryFilter(text: "alex")).map(\.title).sorted(), ["B", "C"])

        let people = library.people()
        XCTAssertEqual(people.map(\.name), ["Alex Kim", "Priya Shah"].sorted { a, b in a < b })
        XCTAssertEqual(people.first { $0.name == "Priya Shah" }?.count, 2)
        XCTAssertEqual(people.first { $0.name == "Priya Shah" }?.lastSeen, day(-1))
        XCTAssertEqual(library.projects().first?.name, "Seed round")
        XCTAssertEqual(library.projects().first?.count, 2)
        XCTAssertEqual(library.moments(.decision).map(\.moment.text), ["Go SAFE"])
        XCTAssertEqual(library.moments(.promise, openOnly: true).count, 0)
    }

    func testProfileCrudKeepsUserEditsAsTheUsers() {
        let library = MemoryLibrary(directory: dir, saveDelay: 60)
        let fact = library.addFact("  Runs a design studio ", category: .role)!
        XCTAssertEqual(fact.text, "Runs a design studio")
        XCTAssertNil(library.addFact("   "))

        library.setProfile(MemoryProfile(facts: library.profile.facts + [ProfileFact(text: "Likes tea", category: .interest, source: .ai)]))
        var ai = library.profile.facts[1]
        ai.text = "Likes green tea"
        library.updateFact(ai)
        XCTAssertEqual(library.profile.facts[1].source, .user, "editing an AI fact makes it the user's")

        library.setFactPinned(fact.id, true)
        XCTAssertTrue(library.profile.facts[0].pinned)
        library.removeFact(fact.id)
        XCTAssertEqual(library.profile.facts.map(\.text), ["Likes green tea"])

        library.flush()
        XCTAssertEqual(MemoryLibrary(directory: dir).profile.facts.map(\.text), ["Likes green tea"])
    }

    func testLensesPersistAndNameThings() {
        let library = MemoryLibrary(directory: dir, saveDelay: 60)
        XCTAssertFalse(library.lensesChosen)
        XCTAssertEqual(library.vocabulary, .neutral)
        library.setLenses([.sales, .founder, .sales])
        XCTAssertEqual(library.lenses, [.sales, .founder])
        XCTAssertEqual(library.vocabulary.projects, "Deals")
        library.flush()
        let reopened = MemoryLibrary(directory: dir)
        XCTAssertEqual(reopened.lenses, [.sales, .founder])
        XCTAssertTrue(reopened.lensesChosen)

        library.setLenses([])
        XCTAssertTrue(library.lensesChosen, "choosing none still finishes onboarding")
    }

    func testVectorsPersistWithModelStampAndFollowDeletes() throws {
        let library = MemoryLibrary(directory: dir, saveDelay: 60)
        let a = library.addNote("a"), b = library.addNote("b")
        library.setVector([3, 4], for: a.id, model: "m1")
        library.setVector([0, 2], for: b.id, model: "m1")
        XCTAssertEqual(library.vector(for: a.id)!, [0.6, 0.8], "stored normalized")
        library.remove(b.id)
        library.flush()

        let reopened = MemoryLibrary(directory: dir)
        XCTAssertEqual(reopened.vectors.model, "m1")
        XCTAssertEqual(reopened.vectors.dimensions, 2)
        XCTAssertEqual(reopened.vectors.ids, [a.id])

        // Another model starts the index over.
        reopened.setVector([1, 0, 0], for: a.id, model: "m2")
        XCTAssertEqual(reopened.vectors.model, "m2")
        XCTAssertEqual(reopened.vectors.count, 1)
    }

    func testUnreadableFileIsSetAside() throws {
        try Data("{ not json".utf8).write(to: dir.appendingPathComponent("memory.json"))
        let library = MemoryLibrary(directory: dir, saveDelay: 60)
        XCTAssertEqual(library.count, 0)
        XCTAssertNotNil(library.loadProblem)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(names.contains { $0.hasPrefix("memory.unreadable-") })
    }

    func testBatchSendsOneChange() {
        let library = MemoryLibrary(directory: dir, saveDelay: 60)
        var count = 0
        let sub = library.changes.sink { count += 1 }
        library.batch {
            library.addNote("1")
            library.addNote("2")
            library.addNote("3")
        }
        XCTAssertEqual(count, 1)
        XCTAssertEqual(library.count, 3)
        sub.cancel()
    }
}
