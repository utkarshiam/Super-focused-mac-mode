import XCTest
@testable import MemoryKit

final class BrainClusteringTests: XCTestCase {
    /// Rows around `k` random directions.
    private func rows(groups: [Int], dims: Int = 32, noise: Float = 0.3, seed: UInt64 = 3) -> [Float] {
        var rng = SeedRandom(seed: seed)
        let bases = groups.map { _ in (0..<dims).map { _ in rng.nextGaussian() } }
        var out: [Float] = []
        for (g, count) in groups.enumerated() {
            for _ in 0..<count { out += VectorIndex.normalized((0..<dims).map { bases[g][$0] + noise * rng.nextGaussian() })! }
        }
        return out
    }

    func testFindsTheGroupsDeterministically() {
        let data = rows(groups: [8, 6, 5])
        let a = BrainClustering.cluster(data, n: 19, d: 32, target: 6, minSize: 2)
        let b = BrainClustering.cluster(data, n: 19, d: 32, target: 6, minSize: 2)
        XCTAssertEqual(a.clusters, b.clusters)
        XCTAssertEqual(a.clusters.map { Set($0) }, [Set(0..<8), Set(8..<14), Set(14..<19)])
        XCTAssertTrue(a.leftovers.isEmpty)
    }

    func testTargetCapsTheNumberOfClusters() {
        let data = rows(groups: [3, 3, 3, 3, 3, 3])
        let r = BrainClustering.cluster(data, n: 18, d: 32, target: 3, minSize: 1, floor: .infinity)
        XCTAssertEqual(r.clusters.count, 3)
        XCTAssertEqual(r.clusters.flatMap { $0 }.count, 18)
    }

    func testSmallGroupsAreLeftOver() {
        let data = rows(groups: [6, 6, 1])
        let r = BrainClustering.cluster(data, n: 13, d: 32, target: 5, minSize: 2)
        XCTAssertEqual(r.clusters.count, 2)
        XCTAssertEqual(r.leftovers, [12])
    }

    func testKMeansPathForBigInputs() {
        let data = rows(groups: [700, 500, 400], dims: 16, noise: 0.25)
        let start = Date()
        let r = BrainClustering.cluster(data, n: 1600, d: 16, target: 10, minSize: 5)
        let elapsed = Date().timeIntervalSince(start)
        print("[perf] clustering 1600 rows (k-means + agglomerative): \(String(format: "%.3f", elapsed)) s")
        XCTAssertEqual(r.clusters.count, 3)
        XCTAssertEqual(r.clusters.map(\.count), [700, 500, 400])
    }

    func testAdaptiveSizes() {
        XCTAssertEqual(BrainClustering.targetTopics(for: 16), 5)
        XCTAssertEqual(BrainClustering.targetTopics(for: 100), 13)
        XCTAssertEqual(BrainClustering.targetTopics(for: 100_000), 60)
        XCTAssertEqual(BrainClustering.minTopicSize(for: 50), 2)
        XCTAssertEqual(BrainClustering.minTopicSize(for: 2000), 10)
    }

    func testWordVectorsGroupItemsSharingWords() {
        let items = (0..<4).map { MemoryItem(title: "Pricing page teardown \($0)", topics: ["pricing"], tags: ["conversion"]) }
            + (0..<4).map { MemoryItem(title: "Hiring senior engineers \($0)", topics: ["hiring"], tags: ["interviews"]) }
        let (data, has) = BrainClustering.wordVectors(items)
        XCTAssertTrue(has.allSatisfy { $0 })
        let r = BrainClustering.cluster(data, n: 8, d: WordSpace.defaultDimensions, target: 4, minSize: 2)
        XCTAssertEqual(r.clusters.map { Set($0) }.sorted { $0.min()! < $1.min()! }, [Set(0..<4), Set(4..<8)])
    }
}

@MainActor
final class BrainTaxonomyTests: XCTestCase {
    var dir: URL!
    override func setUp() async throws { dir = makeTempDirectory() }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    private let themes = [Theme(label: "pricing", count: 8, projects: ["Pricing refresh"], tags: ["saas"]),
                          Theme(label: "hiring", count: 7, people: ["Maya Chen"]),
                          Theme(label: "fundraising", count: 6, organisations: ["Harbor Capital"])]

    private func topic(_ brain: MemoryBrain, _ name: String) -> BrainEntity? { brain.allTopics().first { $0.name == name } }

    func testOrganisingWithoutAINamesTopicsFromLabels() async throws {
        let library = themedLibrary(dir, themes: themes)
        let brain = MemoryBrain.test(library)
        XCTAssertTrue(brain.isOrganizeDue)
        let change = await brain.organizeNow(ai: nil)
        XCTAssertNotNil(change)
        XCTAssertEqual(Set(brain.allTopics().map(\.name)), ["Pricing", "Hiring", "Fundraising"])
        XCTAssertTrue(brain.allTopics().allSatisfy(\.provisionalName))
        XCTAssertEqual(topic(brain, "Pricing")?.itemCount, 8)
        XCTAssertTrue(brain.unsortedItems.isEmpty)
        XCTAssertTrue(brain.areas().isEmpty, "too few topics for areas without AI")
        XCTAssertEqual(change?.summary, "Organised 21 memories into 3 topics")
        XCTAssertEqual(brain.changeLog.first?.summary, change?.summary)
        XCTAssertFalse(brain.isOrganizeDue)
        let item = library.items.first { $0.topics == ["hiring"] }!
        XCTAssertEqual(brain.primaryTopic(of: item.id)?.name, "Hiring")
        XCTAssertEqual(brain.currentState.taxonomy.space, "vectors:fake-embed:48")
    }

    func testOrganisingWithAIUsesOneCallForNamesAndAreas() async throws {
        let library = themedLibrary(dir, themes: themes)
        library.setLenses([.founder])
        let brain = MemoryBrain.test(library)
        let ai = brainAI(areas: ["pricing": "Product", "hiring": "Team", "fundraising": "Fundraising"])
        await brain.organizeNow(ai: ai)
        XCTAssertEqual(ai.generateCalls.count, 1)
        let call = ai.generateCalls[0]
        XCTAssertTrue(call.system.contains("Today is Fri 9 Oct 2026"))
        XCTAssertTrue(call.system.contains("Initiatives"), "lens words")
        XCTAssertTrue(call.system.contains("Fundraising, Customers, Product"), "lens example areas")
        XCTAssertTrue(call.prompt.contains("Current areas: none yet"))
        XCTAssertTrue(call.prompt.contains("labels: pricing ×8"))
        XCTAssertTrue(call.prompt.contains("(Fri 9 Oct 2026)") || call.prompt.contains("2026)"), "samples carry real dates")
        XCTAssertEqual(Set(brain.areas().map(\.name)), ["Product", "Team", "Fundraising"])
        let pricing = try XCTUnwrap(topic(brain, "Pricing"))
        XCTAssertFalse(pricing.provisionalName)
        XCTAssertEqual(pricing.detail, "About pricing.")
        XCTAssertEqual(brain.entity(pricing.parentID!)?.name, "Product")
        XCTAssertEqual(brain.areas().first { $0.name == "Product" }?.itemCount, 8)
        XCTAssertEqual(brain.path(to: pricing.id).map(\.name), ["Product", "Pricing"])
        XCTAssertEqual(brain.topics(in: pricing.parentID).map(\.name), ["Pricing"])
    }

    func testAIFailureLeavesTheTaxonomyAlone() async throws {
        let library = themedLibrary(dir, themes: themes)
        let brain = MemoryBrain.test(library)
        let ai = FakeAI(onGenerate: { _ in throw MemoryAIError.network("Offline.") })
        let change = await brain.organizeNow(ai: ai)
        XCTAssertNil(change)
        XCTAssertTrue(brain.allTopics().isEmpty)
        XCTAssertEqual(brain.lastError, .network("Offline."))
        XCTAssertTrue(brain.isOrganizeDue)
    }

    func testReorganisingKeepsIDsAndNamesAndLogsNewTopics() async throws {
        let library = themedLibrary(dir, themes: themes)
        let brain = MemoryBrain.test(library)
        let ai = brainAI(areas: ["pricing": "Product", "hiring": "Team", "fundraising": "Fundraising", "travel": "Personal"])
        await brain.organizeNow(ai: ai)
        let before = Dictionary(uniqueKeysWithValues: brain.allTopics().map { ($0.name, $0.id) })
        brain.rename(before["Hiring"]!, to: "Hiring engineers")

        // A new theme arrives, plus one more pricing item.
        var rng = SeedRandom(seed: 1234)
        let base = (0..<48).map { _ in rng.nextGaussian() }
        for i in 0..<5 {
            let item = library.add(MemoryItem(title: "Travel note \(i)", topics: ["travel"], createdAt: day(1), processing: .processed))
            library.setVector(base.map { $0 + 0.3 * rng.nextGaussian() }, for: item.id, model: "fake-embed")
        }
        addNear(library, like: library.items.first { $0.topics == ["pricing"] }!, title: "Pricing follow-up", topics: ["pricing"])
        brain.refresh()
        XCTAssertEqual(topic(brain, "Pricing")?.itemCount, 9, "the new pricing item joined by its label")
        XCTAssertEqual(brain.unsortedItems.count, 5, "travel waits for the next reorganisation")
        XCTAssertEqual(brain.newSinceOrganize, 6)

        let change = await brain.organizeNow(ai: ai)
        let after = Dictionary(uniqueKeysWithValues: brain.allTopics().map { ($0.name, $0.id) })
        XCTAssertEqual(after["Pricing"], before["Pricing"])
        XCTAssertEqual(after["Fundraising"], before["Fundraising"])
        XCTAssertEqual(after["Hiring engineers"], before["Hiring"], "renamed and locked: same id, the user's name")
        XCTAssertNotNil(after["Travel"])
        XCTAssertTrue(brain.unsortedItems.isEmpty)
        XCTAssertEqual(change?.details.first, "1 new topic: Travel")
        XCTAssertEqual(brain.areas().first { $0.id == topic(brain, "Travel")?.parentID }?.name, "Personal")
        XCTAssertEqual(brain.newSinceOrganize, 0)
    }

    func testStableWithoutChanges() async throws {
        let library = themedLibrary(dir, themes: themes)
        let brain = MemoryBrain.test(library)
        await brain.organizeNow(ai: brainAI())
        let first = brain.currentState.taxonomy
        let names = brain.allTopics().map(\.name).sorted()
        let change = await brain.organizeNow(ai: brainAI())
        XCTAssertEqual(change?.summary, "No changes")
        XCTAssertEqual(brain.currentState.taxonomy.members.mapValues(Set.init), first.members.mapValues(Set.init))
        XCTAssertEqual(brain.allTopics().map(\.name).sorted(), names)
    }

    func testUserLocksAndCorrectionsSurviveReorganising() async throws {
        let library = themedLibrary(dir, themes: themes)
        let brain = MemoryBrain.test(library)
        await brain.organizeNow(ai: brainAI())
        let pricing = try XCTUnwrap(topic(brain, "Pricing"))
        let hiring = try XCTUnwrap(topic(brain, "Hiring"))
        let fundraising = try XCTUnwrap(topic(brain, "Fundraising"))

        // Take one pricing item out; file another under Hiring as primary; lock Fundraising's membership.
        let out = brain.items(for: pricing.id)[0]
        brain.removeItem(out.id, fromTopic: pricing.id)
        XCTAssertEqual(brain.unsortedItems.map(\.id), [out.id])
        let moved = brain.items(for: pricing.id)[0]
        brain.setPrimaryTopic(hiring.id, for: moved.id)
        XCTAssertEqual(brain.primaryTopic(of: moved.id)?.id, hiring.id)
        var locks = fundraising.locks
        locks.membership = true
        brain.setLocks(locks, for: fundraising.id)
        let lockedItems = brain.itemIDs(for: fundraising.id)
        let extra = library.items.first { $0.topics == ["hiring"] }!
        brain.addItem(extra.id, toTopic: fundraising.id)
        XCTAssertTrue(brain.itemIDs(for: fundraising.id).contains(extra.id))

        await brain.organizeNow(ai: brainAI())
        XCTAssertFalse(brain.itemIDs(for: pricing.id).contains(out.id), "an item taken out never goes back")
        XCTAssertEqual(brain.primaryTopic(of: moved.id)?.id, hiring.id)
        XCTAssertEqual(brain.itemIDs(for: fundraising.id), lockedItems.union([extra.id]))
        XCTAssertEqual(topic(brain, "Fundraising")?.id, fundraising.id)

        // Corrections persist.
        brain.flush()
        let reopened = MemoryBrain.test(library)
        XCTAssertEqual(reopened.primaryTopic(of: moved.id)?.id, hiring.id)
        XCTAssertTrue(reopened.entity(fundraising.id)?.locks.membership == true)
        XCTAssertEqual(reopened.currentState.corrections.excluded[out.id.uuidString], [pricing.id])
    }

    func testMovingRenamingMergingAndDeletingTopics() async throws {
        let library = themedLibrary(dir, themes: themes)
        let brain = MemoryBrain.test(library)
        await brain.organizeNow(ai: brainAI(areas: ["pricing": "Product", "hiring": "Team", "fundraising": "Money"]))
        let pricing = topic(brain, "Pricing")!, hiring = topic(brain, "Hiring")!, fundraising = topic(brain, "Fundraising")!
        let team = brain.areas().first { $0.name == "Team" }!

        XCTAssertTrue(brain.move(pricing.id, to: team.id))
        XCTAssertEqual(brain.entity(pricing.id)?.parentID, team.id)
        XCTAssertTrue(brain.entity(pricing.id)!.locks.parent)
        XCTAssertTrue(brain.move(fundraising.id, to: hiring.id), "a top-level topic can become a sub-topic")
        XCTAssertFalse(brain.move(pricing.id, to: fundraising.id), "no sub-sub-topics")
        XCTAssertEqual(brain.items(for: hiring.id).count, 13, "a topic's items include its sub-topics'")
        XCTAssertEqual(brain.items(for: hiring.id, includeDescendants: false).count, 7)

        XCTAssertTrue(brain.merge(fundraising.id, into: hiring.id))
        XCTAssertNil(brain.entity(fundraising.id))
        XCTAssertEqual(brain.items(for: hiring.id, includeDescendants: false).count, 13)
        XCTAssertTrue(brain.entity(hiring.id)!.aliases.contains("Fundraising"))
        XCTAssertEqual(brain.changeLog.first?.summary, "Merged Fundraising into Hiring")
        XCTAssertFalse(brain.merge(hiring.id, into: team.id), "never across kinds")

        brain.deleteTopic(pricing.id)
        XCTAssertNil(brain.entity(pricing.id))
        XCTAssertEqual(brain.unsortedItems.count, 8)

        let made = try XCTUnwrap(brain.createTopic(named: "Board prep", in: team.id))
        XCTAssertTrue(brain.entity(made)!.locks.name)
        brain.addItem(brain.unsortedItems[0].id, toTopic: made)
        XCTAssertEqual(brain.entity(made)?.itemCount, 1)
        XCTAssertEqual(brain.unsortedItems.count, 7)
    }

    func testAUserMergeSurvivesReorganising() async throws {
        let library = themedLibrary(dir, themes: themes)
        let brain = MemoryBrain.test(library)
        await brain.organizeNow(ai: brainAI())
        let hiring = topic(brain, "Hiring")!, fundraising = topic(brain, "Fundraising")!
        XCTAssertTrue(brain.merge(fundraising.id, into: hiring.id))
        await brain.organizeNow(ai: brainAI())
        XCTAssertNil(topic(brain, "Fundraising"), "the cluster named like a merged alias joins the target")
        XCTAssertEqual(topic(brain, "Hiring")?.id, hiring.id)
        XCTAssertEqual(topic(brain, "Hiring")?.itemCount, 13)
    }

    func testNamingAnswersAreValidated() throws {
        let json = """
        {"areas": [{"name": "Product", "description": "x"}, {"name": "product", "description": "dup"}, {"name": "", "description": ""}],
         "topics": [{"id": "c1", "name": "  \\"Pricing\\". ", "area": "Product", "description": "d", "sameAs": ""},
                    {"id": "c2", "name": "Misc", "area": "Product", "description": "", "sameAs": ""},
                    {"id": "c9", "name": "Ghost", "area": "Product", "description": "", "sameAs": ""},
                    {"id": "c3", "name": "Pricing tiers and plans and more words here", "area": "Product", "description": "", "sameAs": "c1"},
                    {"id": "c1", "name": "Again", "area": "", "description": "", "sameAs": ""}]}
        """
        let a = try BrainPrompts.parseTaxonomy(Data(json.utf8), clusterIDs: ["c1", "c2", "c3"])
        XCTAssertEqual(a.areas.map(\.name), ["Product"])
        XCTAssertEqual(a.topics["c1"]?.name, "Pricing")
        XCTAssertNil(a.topics["c2"], "generic names are refused")
        XCTAssertNil(a.topics["c9"], "unknown ids are dropped")
        XCTAssertEqual(a.topics["c3"]?.name, "Pricing tiers and plans and")
        XCTAssertEqual(a.topics["c3"]?.sameAs, "c1")
        XCTAssertThrowsError(try BrainPrompts.parseTaxonomy(Data("[]".utf8), clusterIDs: []))
    }

    func testSameAsMergesClustersAndLogsIt() async throws {
        let library = themedLibrary(dir, themes: themes)
        let brain = MemoryBrain.test(library)
        await brain.organizeNow(ai: brainAI())
        let fundraisingID = topic(brain, "Fundraising")!.id
        // Next time the AI says the fundraising cluster is the same as the pricing one.
        let ai = FakeAI(dimensions: 48, onGenerate: { call in
            var answer = try JSONSerialization.jsonObject(with: taxonomyAnswer(call.prompt, areas: [:])) as! [String: Any]
            var topics = answer["topics"] as! [[String: Any]]
            let pricing = topics.first { ($0["name"] as! String) == "Pricing" }!["id"] as! String
            for i in topics.indices where (topics[i]["name"] as! String) == "Fundraising" { topics[i]["sameAs"] = pricing }
            answer["topics"] = topics
            return try JSONSerialization.data(withJSONObject: answer)
        })
        let change = await brain.organizeNow(ai: ai)
        XCTAssertNil(brain.entity(fundraisingID))
        XCTAssertEqual(topic(brain, "Pricing")?.itemCount, 14)
        XCTAssertEqual(change?.details, ["merged Fundraising into Pricing"])
    }

    func testIncrementalAssignmentByMeaningAndUnsorted() async throws {
        let library = themedLibrary(dir, themes: themes)
        let brain = MemoryBrain.test(library)
        await brain.organizeNow(ai: nil)
        let hiringItem = library.items.first { $0.topics == ["hiring"] }!
        let near = addNear(library, like: hiringItem, title: "Interview loop")
        var rng = SeedRandom(seed: 77)
        let far = library.add(MemoryItem(title: "Something else entirely", processing: .processed))
        library.setVector((0..<48).map { _ in rng.nextGaussian() }, for: far.id, model: "fake-embed")
        let pending = library.add(MemoryItem(title: "Not processed yet"))
        brain.refresh()
        XCTAssertEqual(brain.primaryTopic(of: near.id)?.name, "Hiring")
        XCTAssertNil(brain.primaryTopic(of: far.id))
        XCTAssertEqual(brain.unsortedItems.map(\.id), [far.id])
        XCTAssertNil(brain.primaryTopic(of: pending.id))
        XCTAssertFalse(brain.unsortedItems.contains { $0.id == pending.id }, "pending items wait for processing")
        XCTAssertEqual(brain.newSinceOrganize, 2)
    }

    func testOrganizeIsDuePolicy() async throws {
        let library = themedLibrary(dir, themes: [Theme(label: "pricing", count: 4)])
        var clock = day(0)
        let brain = MemoryBrain(library: library, saveDelay: 60, autoUpdate: false)
        brain.now = { clock }
        XCTAssertFalse(brain.isOrganizeDue, "too few items")
        for i in 0..<4 { library.add(MemoryItem(title: "Extra \(i)", topics: ["pricing"], processing: .processed)) }
        XCTAssertTrue(brain.isOrganizeDue, "never organised")
        await brain.organizeNow(ai: nil)
        XCTAssertFalse(brain.isOrganizeDue)
        library.add(MemoryItem(title: "One more", topics: ["pricing"], processing: .processed))
        brain.refresh()
        XCTAssertFalse(brain.isOrganizeDue, "one new item, not a week yet")
        clock = day(8)
        XCTAssertTrue(brain.isOrganizeDue, "a week passed with something new")
        clock = day(1)
        brain.organizeAfterNewItems = 3
        for i in 0..<3 { library.add(MemoryItem(title: "Burst \(i)", topics: ["pricing"], processing: .processed)) }
        brain.refresh()
        XCTAssertTrue(brain.isOrganizeDue, "enough new items")
    }

    func testWithoutVectorsClustersOnSharedWords() async throws {
        let library = themedLibrary(dir, themes: themes, withVectors: false)
        let brain = MemoryBrain.test(library)
        await brain.organizeNow(ai: nil)
        XCTAssertEqual(brain.currentState.taxonomy.space, "words")
        XCTAssertEqual(Set(brain.allTopics().map(\.name)), ["Pricing", "Hiring", "Fundraising"])
        let p = library.add(MemoryItem(title: "Another pricing thought", topics: ["Pricing"], processing: .skipped))
        brain.refresh()
        XCTAssertEqual(brain.primaryTopic(of: p.id)?.name, "Pricing", "a matching label files it without vectors")
    }

    func testBigTopicsGetSubTopics() {
        // One theme with two clear sub-themes, plus two small themes; a tiny target forces the parent together.
        var rng = SeedRandom(seed: 5)
        let d = 32
        let a = (0..<d).map { _ in rng.nextGaussian() }
        let subs = (0..<2).map { _ in (0..<d).map { _ in rng.nextGaussian() * 0.7 } }
        var items: [MemoryItem] = []
        var vectors = VectorIndex()
        func add(_ v: [Float], label: String) {
            let item = MemoryItem(title: "\(label) \(items.count)", topics: [label], processing: .processed)
            items.append(item)
            vectors.set(v, for: item.id, model: "m")
        }
        for s in 0..<2 { for _ in 0..<15 { add((0..<d).map { a[$0] + subs[s][$0] + 0.15 * rng.nextGaussian() }, label: s == 0 ? "tiers" : "discounts") } }
        for label in ["hiring", "travel"] {
            let b = (0..<d).map { _ in rng.nextGaussian() }
            for _ in 0..<10 { add((0..<d).map { b[$0] + 0.2 * rng.nextGaussian() }, label: label) }
        }
        let input = BrainOrganizer.Input(items: items, vectors: vectors, oldTopics: [], lockedItems: [], totalEligible: 4)
        let plan = BrainOrganizer.plan(input)
        let top = plan.topics.filter { $0.parentKey == nil }
        XCTAssertEqual(top.count, 3)
        let parent = try! XCTUnwrap(top.first { $0.allItems.count == 30 })
        let children = plan.topics.filter { $0.parentKey == parent.key }
        XCTAssertEqual(children.map(\.allItems.count), [15, 15])
        XCTAssertEqual(Set(children.map(\.fallbackName)), ["Tiers", "Discounts"])
        XCTAssertEqual(parent.fallbackName, "Discounts & tiers")
        XCTAssertTrue(parent.items.isEmpty, "all of the parent's items are in its sub-topics")
    }
}
