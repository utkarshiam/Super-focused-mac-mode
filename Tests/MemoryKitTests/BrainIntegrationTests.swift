import XCTest
@testable import MemoryKit

@MainActor
final class BrainStoreTests: XCTestCase {
    var dir: URL!
    override func setUp() async throws { dir = makeTempDirectory() }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    func testBrainJSONRoundTripsAndIsVersioned() async throws {
        let library = themedLibrary(dir, themes: [Theme(label: "pricing", count: 4, people: ["Ana Ruiz"]), Theme(label: "hiring", count: 4)])
        let brain = MemoryBrain.test(library)
        await brain.organizeNow(ai: brainAI())
        _ = brain.map()
        brain.flush()
        let data = try Data(contentsOf: brain.fileURL)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["version"] as? Int, 1)
        XCTAssertNotNil(json["taxonomy"])
        XCTAssertFalse((json["layout"] as! [String: Any]).isEmpty)
        let decoded = try MemoryCoding.decoder.decode(BrainState.self, from: data)
        XCTAssertEqual(decoded, brain.currentState)
        let reopened = MemoryBrain.test(library)
        XCTAssertEqual(reopened.currentState.entities.map(\.id).sorted { $0.uuidString < $1.uuidString },
                       brain.currentState.entities.map(\.id).sorted { $0.uuidString < $1.uuidString })
        XCTAssertEqual(reopened.allTopics().map(\.name).sorted(), brain.allTopics().map(\.name).sorted())
    }

    func testTolerantDecoding() throws {
        let json = """
        {"version": 7, "future": true,
         "entities": [{"id": "6F1C0D1E-0000-4000-8000-000000000001", "kind": "galaxy", "name": "Pricing"},
                      {"kind": 12},
                      {"id": "6F1C0D1E-0000-4000-8000-000000000002", "kind": "person", "name": "Ana", "locks": {"name": true}}],
         "taxonomy": {"members": {"6F1C0D1E-0000-4000-8000-000000000001": ["6F1C0D1E-0000-4000-8000-0000000000AA"]}},
         "changeLog": [{"summary": "Organised"}, "garbage"],
         "layout": {"6F1C0D1E-0000-4000-8000-000000000001": {"x": 1.5}}}
        """
        let state = try MemoryCoding.decoder.decode(BrainState.self, from: Data(json.utf8))
        XCTAssertEqual(state.version, 7)
        XCTAssertEqual(state.entities.count, 3, "a bad kind becomes a topic; missing fields get defaults")
        XCTAssertEqual(state.entities[0].kind, .topic)
        XCTAssertEqual(state.entities[0].aliases, ["Pricing"])
        XCTAssertTrue(state.entities[2].locks.name)
        XCTAssertFalse(state.entities[2].locks.membership)
        XCTAssertEqual(state.taxonomy.members.count, 1)
        XCTAssertEqual(state.changeLog.map(\.summary), ["Organised"])
        XCTAssertEqual(state.layout.first?.value, MapPoint(x: 1.5, y: 0))
        XCTAssertEqual(try MemoryCoding.decoder.decode(BrainState.self, from: Data("{}".utf8)), BrainState())
    }

    func testUnreadableFileIsSetAside() throws {
        try Data("not json".utf8).write(to: dir.appendingPathComponent("brain.json"))
        let library = MemoryLibrary(directory: dir, saveDelay: 60)
        let brain = MemoryBrain.test(library)
        XCTAssertNotNil(brain.loadProblem)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(files.contains { $0.hasPrefix("brain.unreadable-") })
    }

    func testSavesAreDebouncedAndFlushWritesNow() async throws {
        let library = MemoryLibrary(directory: dir, saveDelay: 60)
        library.add(MemoryItem(title: "A", people: ["Ana Ruiz"]))
        let brain = MemoryBrain(library: library, saveDelay: 0.05, autoUpdate: false)
        let id = brain.entities(.person)[0].id
        brain.rename(id, to: "Ana R.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: brain.fileURL.path), "not written right away")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: brain.fileURL.path))
        brain.rename(id, to: "Ana Ruiz-Lopez")
        brain.flush()
        let state = try MemoryCoding.decoder.decode(BrainState.self, from: Data(contentsOf: brain.fileURL))
        XCTAssertEqual(state.entities.first { $0.id == id }?.name, "Ana Ruiz-Lopez")
    }

    func testAutoUpdateFollowsTheLibrary() async throws {
        let library = MemoryLibrary(directory: dir, saveDelay: 60)
        let brain = MemoryBrain(library: library, saveDelay: 60)
        library.add(MemoryItem(title: "A", people: ["Ana Ruiz"]))
        for _ in 0..<40 where brain.entities(.person).isEmpty { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(brain.entities(.person).map(\.name), ["Ana Ruiz"])
        library.remove(library.items[0].id)
        for _ in 0..<40 where !brain.entities(.person).isEmpty { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertTrue(brain.entities(.person).isEmpty, "entities go with their last item")
    }
}

@MainActor
final class BrainCorrectionsTests: XCTestCase {
    var dir: URL!
    override func setUp() async throws { dir = makeTempDirectory() }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    private func people() -> (MemoryLibrary, MemoryBrain) {
        let library = MemoryLibrary(directory: dir, saveDelay: 60)
        library.add(MemoryItem(title: "One", people: ["Rohan Mehta", "Priya Nair"], projects: ["Quote"]))
        library.add(MemoryItem(title: "Two", people: ["Rohan"], projects: ["Quote"]))
        library.add(MemoryItem(title: "Three", people: ["Rohan Gupta"]))
        library.add(MemoryItem(title: "Four", people: ["R. Mehta"]))
        return (library, MemoryBrain.test(library))
    }

    func testMergeUnmergeAndDistinctPersist() {
        let (library, brain) = people()
        let mehta = brain.entity(named: "Rohan Mehta", kind: .person)!
        XCTAssertEqual(Set(mehta.aliases), ["Rohan Mehta", "R. Mehta"], "two Rohans: the first name stays apart")
        XCTAssertNotNil(brain.entity(named: "Rohan", kind: .person))
        let gupta = brain.entity(named: "Rohan Gupta", kind: .person)!
        let bare = brain.entity(named: "Rohan", kind: .person)!

        XCTAssertTrue(brain.merge(bare.id, into: mehta.id))
        XCTAssertEqual(brain.entity(named: "Rohan", kind: .person)?.id, mehta.id)
        XCTAssertEqual(brain.entity(mehta.id)?.itemCount, 3)
        XCTAssertNil(brain.entity(bare.id))
        XCTAssertFalse(brain.merge(mehta.id, into: brain.entity(named: "Quote", kind: .project)!.id), "never across kinds")

        let split = brain.unmerge(alias: "R. Mehta", from: mehta.id)
        let r = try! XCTUnwrap(split.flatMap(brain.entity))
        XCTAssertEqual(r.name, "R. Mehta")
        XCTAssertEqual(brain.entity(mehta.id)?.itemCount, 2)

        brain.markDistinct(mehta.id, gupta.id)
        XCTAssertEqual(brain.changeLog.first?.summary, "Rohan Mehta and Rohan Gupta are different")

        // Everything survives a reload and a fresh resolution.
        brain.flush()
        let reopened = MemoryBrain.test(library)
        XCTAssertEqual(reopened.entity(named: "Rohan", kind: .person)?.id, mehta.id)
        XCTAssertEqual(reopened.entity(named: "R. Mehta", kind: .person)?.id, r.id)
        XCTAssertEqual(reopened.entity(mehta.id)?.itemCount, 2)
        XCTAssertEqual(reopened.changeLog.map(\.kind).prefix(3), [.correction, .correction, .correction])
    }

    func testRenameLocksTheNameAndAddsTheSpelling() {
        let (library, brain) = people()
        let priya = brain.entity(named: "Priya Nair", kind: .person)!
        brain.rename(priya.id, to: "Priya N.")
        XCTAssertEqual(brain.entity(priya.id)?.name, "Priya N.")
        XCTAssertTrue(brain.entity(priya.id)!.locks.name)
        library.add(MemoryItem(title: "Five", people: ["Priya Nair"]))
        brain.refresh()
        XCTAssertEqual(brain.entity(priya.id)?.name, "Priya N.", "resolution keeps a locked name")
        XCTAssertEqual(brain.entity(priya.id)?.itemCount, 2)
        XCTAssertTrue(brain.addAlias("PN", to: priya.id))
        XCTAssertEqual(brain.entity(named: "pn", kind: .person)?.id, priya.id)
    }
}

@MainActor
final class BrainIntegrationTests: XCTestCase {
    var dir: URL!
    override func setUp() async throws { dir = makeTempDirectory() }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    func testExtractionPromptGetsTheBrainsVocabulary() async throws {
        let library = themedLibrary(dir, themes: [Theme(label: "pricing", count: 4, people: ["Rohan Mehta"], tags: ["saas"]),
                                                  Theme(label: "hiring", count: 4, organisations: ["Harbor Capital"])])
        let brain = MemoryBrain.test(library)
        await brain.organizeNow(ai: nil)
        let ai = brainAI()
        let processor = MemoryProcessor(library: library, ai: ai, autoProcess: false)
        processor.now = { day(0) }
        brain.attach(to: processor, runNow: false)
        library.addNote("Rohan called about annual pricing.")
        processor.processPending()
        await processor.waitUntilIdle()
        let system = try XCTUnwrap(ai.generateCalls.first { $0.system.contains("You file things") }?.system)
        XCTAssertTrue(system.contains("Names already in the user's memory"))
        XCTAssertTrue(system.contains("- Topics: Pricing; Hiring") || system.contains("- Topics: Hiring; Pricing"), system)
        XCTAssertTrue(system.contains("- Tags: saas"))
        XCTAssertTrue(system.contains("- People: Rohan Mehta"))
        XCTAssertTrue(system.contains("- Organisations: Harbor Capital"))
        XCTAssertTrue(system.contains("organisations: companies"))

        // Without a provider the prompt is as before.
        let plain = MemoryPrompts.extractionSystem(lenses: [], profile: MemoryProfile(), now: day(0))
        XCTAssertFalse(plain.contains("Names already in the user's memory"))
    }

    func testOrganisationsAreExtracted() async throws {
        let library = MemoryLibrary(directory: dir, saveDelay: 60)
        let item = library.addNote("Met Acme.")
        let json = #"{"title":"T","summary":"S.","keyTakeaways":[],"people":[],"projects":[],"organisations":["Acme","acme"],"topics":[],"tags":[],"moments":[],"extractedText":""}"#
        let processor = MemoryProcessor(library: library, ai: brainAI(extraction: json), autoProcess: false)
        processor.processPending()
        await processor.waitUntilIdle()
        XCTAssertEqual(library.item(item.id)?.organisations, ["Acme"])
        XCTAssertTrue(library.item(item.id)!.embeddingText.contains("Organisations: Acme"))
        let decoded = try roundTrip(library.item(item.id)!)
        XCTAssertEqual(decoded.organisations, ["Acme"])
        let old = try MemoryCoding.decoder.decode(MemoryItem.self, from: Data(#"{"title": "Old"}"#.utf8))
        XCTAssertEqual(old.organisations, [])
    }

    func testSnapshotCarriesACompactBrainAndOldSnapshotsStillLoad() async throws {
        let library = MemoryLibrary(directory: dir.appendingPathComponent("Mac"), saveDelay: 60)
        let brain = MemoryBrain.test(library)
        brain.debugSeed(now: day(0))
        let root = dir.appendingPathComponent("Docket")
        let bridge = PhoneBridge(root: root)
        try await bridge.publish(library, tasks: [], now: day(0), brain: brain)
        let snapshot = try XCTUnwrap(try bridge.readSnapshot())
        let b = try XCTUnwrap(snapshot.brain)
        XCTAssertEqual(b.areas().count, 6)
        XCTAssertEqual(b.topics(in: b.areas().first { $0.name == "Product" }!.id).map(\.name).sorted(),
                       ["Billing reliability", "Onboarding", "Pricing", "Retention ideas"])
        let pricing = try XCTUnwrap(b.entity(named: "pricing strategy", kind: .topic))
        XCTAssertEqual(pricing.name, "Pricing")
        XCTAssertEqual(b.children(of: pricing.id).map(\.name).sorted(), ["Annual discounts", "Pricing page"])
        XCTAssertEqual(b.items(for: pricing.id, in: snapshot).count, 2)
        XCTAssertFalse(b.map.nodes.isEmpty)
        XCTAssertEqual(b.connections.count, 3)
        XCTAssertNotNil(b.digest)
        let seedItem = snapshot.items.first { $0.title == "Seed round: investor feedback" }!
        XCTAssertEqual(b.primaryTopic(of: seedItem.id)?.name, "Seed round")
        XCTAssertTrue(b.entities(forItem: seedItem.id).contains { $0.name == "Priya Shah" })
        XCTAssertEqual(b.map(focus: pricing.id, hops: 1).focus, pricing.id)

        // A snapshot from a Mac without the brain decodes with brain == nil.
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: bridge.snapshotURL)) as! [String: Any]
        json["brain"] = nil
        let old = try MemoryCoding.decoder.decode(LibrarySnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(old.brain)
        XCTAssertEqual(old.items.count, snapshot.items.count)
        // And publishing without a brain still works.
        try await bridge.publish(library, tasks: [], now: day(0))
        XCTAssertNil(try bridge.readSnapshot()?.brain)
    }

    func testDebugSeedIsRichAndOffline() throws {
        let library = MemoryLibrary(directory: dir, saveDelay: 60)
        let brain = MemoryBrain.test(library)
        brain.debugSeed(now: day(0))
        XCTAssertGreaterThanOrEqual(library.count, 15, "seeds the library when needed")
        XCTAssertEqual(brain.areas().count, 6)
        XCTAssertEqual(brain.allTopics().count, 13)
        let pricing = try XCTUnwrap(brain.entity(named: "Pricing", kind: .topic))
        XCTAssertEqual(brain.children(of: pricing.id).count, 2)
        XCTAssertTrue(brain.unsortedItems.isEmpty)
        // Merged aliases.
        let acme = try XCTUnwrap(brain.entity(named: "Acme Inc.", kind: .organisation))
        XCTAssertEqual(acme.name, "Acme")
        XCTAssertEqual(Set(acme.aliases), ["Acme", "Acme Inc."])
        XCTAssertEqual(brain.entity(named: "P. Shah", kind: .person)?.name, "Priya Shah")
        XCTAssertEqual(brain.entity(named: "Harbor Capital Partners", kind: .organisation)?.name, "Harbor Capital")
        // Pages with citations that point at real items; one disagreement; open questions.
        let seedRound = try XCTUnwrap(brain.entity(named: "Seed round", kind: .topic))
        XCTAssertTrue(seedRound.summary.contains("[3]"))
        XCTAssertEqual(seedRound.summarySources.count, 3)
        XCTAssertTrue(seedRound.summarySources.allSatisfy { library.item($0) != nil })
        XCTAssertEqual(seedRound.disagreements.count, 1)
        XCTAssertTrue(seedRound.disagreements[0].text.hasPrefix("Seed target: $1.5M in the board deck ("))
        XCTAssertFalse(seedRound.openQuestions.isEmpty)
        let pages = brain.entities.filter(\.hasPage)
        XCTAssertGreaterThanOrEqual(pages.count, 6)
        for page in pages { for fact in page.keyFacts { XCTAssertFalse(fact.itemIDs.isEmpty, fact.text) } }
        XCTAssertTrue(brain.staleEntities().filter(\.hasPage).isEmpty, "seeded pages aren't due again")
        // Connections, digest, change log, layout.
        XCTAssertEqual(brain.connections.count, 3)
        let digest = brain.digest(for: day(0))
        XCTAssertTrue(digest.isWritten)
        XCTAssertEqual(digest.sources.count, 4)
        XCTAssertEqual(brain.changeLog.count, 3)
        XCTAssertFalse(brain.currentState.layout.isEmpty)
        XCTAssertFalse(brain.isOrganizeDue)
        let map = brain.map()
        XCTAssertGreaterThan(map.nodes.count, 25)
        XCTAssertEqual(map.nodes.filter { $0.kind == .area }.count, 6)
        // Deterministic.
        let other = MemoryBrain.test(MemoryLibrary(directory: makeTempDirectory(), saveDelay: 60))
        other.debugSeed(now: day(0))
        XCTAssertEqual(other.allTopics().map(\.id).sorted { $0.uuidString < $1.uuidString },
                       brain.allTopics().map(\.id).sorted { $0.uuidString < $1.uuidString })
    }

    func testMaintenanceWithoutAIOrganisesAndFindsNoPages() async throws {
        let library = themedLibrary(dir, themes: [Theme(label: "pricing", count: 5, people: ["Ana Ruiz"]), Theme(label: "hiring", count: 5)])
        let brain = MemoryBrain.test(library)
        let report = await brain.runMaintenance(ai: nil)
        XCTAssertFalse(report.skipped)
        XCTAssertTrue(report.organized)
        XCTAssertEqual(report.pagesWritten, 0)
        XCTAssertEqual(brain.allTopics().count, 2)
        let again = await brain.runMaintenance(ai: nil)
        XCTAssertTrue(again.skipped, "called again too soon")
    }

    func testMaintenanceWithAIRunsEveryStepOnce() async throws {
        let library = themedLibrary(dir, themes: [Theme(label: "pricing", count: 5, people: ["Ana Ruiz"]), Theme(label: "hiring", count: 5)])
        library.add(MemoryItem(title: "Last week", people: ["Ana"], createdAt: day(-7), processing: .processed))
        let brain = MemoryBrain.test(library)
        let ai = brainAI(areas: ["pricing": "Product", "hiring": "Team"])
        let report = await brain.runMaintenance(ai: ai)
        XCTAssertEqual(report.resolvedPairs, 1, "Ana / Ana Ruiz asked about once")
        XCTAssertTrue(report.organized)
        XCTAssertEqual(report.pagesWritten, 3)
        XCTAssertTrue(report.digestWritten)
        XCTAssertEqual(brain.entities(.person).map(\.name), ["Ana Ruiz"])
        let calls = ai.generateCalls.count
        let second = await brain.runMaintenance(ai: ai, force: true)
        XCTAssertFalse(second.organized)
        XCTAssertEqual(second.pagesWritten, 0)
        XCTAssertFalse(second.digestWritten)
        XCTAssertEqual(ai.generateCalls.count, calls, "nothing due: no calls")
    }

    func testAttachRunsMaintenanceWhenProcessingGoesIdle() async throws {
        let library = themedLibrary(dir, themes: [Theme(label: "pricing", count: 4), Theme(label: "hiring", count: 4)])
        let brain = MemoryBrain.test(library)
        let processor = MemoryProcessor(library: library, ai: nil, autoProcess: false)
        brain.attach(to: processor, runNow: true)
        for _ in 0..<40 where brain.organizedAt == nil { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertNotNil(brain.organizedAt)
    }
}
