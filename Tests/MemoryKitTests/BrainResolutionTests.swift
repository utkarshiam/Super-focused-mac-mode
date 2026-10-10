import XCTest
@testable import MemoryKit

final class EntityNamesTests: XCTestCase {
    func testPeopleKeysDropTitlesCaseAccentsAndPunctuation() {
        let k = { EntityNames.key($0, kind: .person) }
        XCTAssertEqual(k("Rohan Mehta"), "rohan mehta")
        XCTAssertEqual(k("  Mr. Rohan  Mehta "), "rohan mehta")
        XCTAssertEqual(k("Rohan ji"), "rohan")
        XCTAssertEqual(k("Rohan-ji"), "rohan")
        XCTAssertEqual(k("Dr Priya Nair"), "priya nair")
        XCTAssertEqual(k("Shri Rohan Mehta sahab"), "rohan mehta")
        XCTAssertEqual(k("José Núñez"), "jose nunez")
        XCTAssertEqual(k("R. Mehta"), "r mehta")
        XCTAssertEqual(k("Sir"), "sir", "a title alone stays")
        XCTAssertEqual(k("Tanaka-san"), "tanaka")
    }

    func testOrganisationKeysDropLegalSuffixes() {
        let k = { EntityNames.key($0, kind: .organisation) }
        XCTAssertEqual(k("Mehta Traders Pvt Ltd"), "mehta traders")
        XCTAssertEqual(k("Mehta Traders Pvt. Ltd."), "mehta traders")
        XCTAssertEqual(k("Mehta Traders Private Limited"), "mehta traders")
        XCTAssertEqual(k("Mehta Traders"), "mehta traders")
        XCTAssertEqual(k("Acme, Inc."), "acme")
        XCTAssertEqual(k("The Acme Corporation"), "acme")
        XCTAssertEqual(k("Northwind GmbH"), "northwind")
        XCTAssertEqual(k("Smith & Sons LLC"), "smith sons")
        XCTAssertEqual(k("Inc"), "inc", "never empty")
    }

    func testTopicKeysFoldPluralsButKeepDifferentTopicsApart() {
        let k = { EntityNames.key($0, kind: .topic) }
        XCTAssertEqual(k("Store pilots"), k("Store pilot"))
        XCTAssertEqual(k("Pricing strategies"), "pricing strategy")
        XCTAssertEqual(k("Annual discounts"), k("annual discount"))
        XCTAssertNotEqual(k("Pricing"), k("Pricing strategy"))
        XCTAssertEqual(k("Analysis"), "analysis")
        XCTAssertEqual(k("Hiring & team"), k("Hiring and team"))
        XCTAssertEqual(k("Boxes"), "box")
        XCTAssertEqual(k("Status"), "status")
        XCTAssertEqual(EntityNames.key("Billing API project", kind: .project), "billing api")
    }

    func testEditDistanceAndAcronyms() {
        XCTAssertEqual(EntityNames.editDistance("rivera", "rivers"), 1)
        XCTAssertEqual(EntityNames.editDistance("kitten", "sitting"), 3)
        XCTAssertGreaterThan(EntityNames.editDistance("abcdefgh", "zzzzzzzz", cap: 2), 2)
        XCTAssertEqual(EntityNames.acronym("international business machines"), "ibm")
        XCTAssertNil(EntityNames.acronym("acme"))
    }

    func testStableIDsAreDeterministic() {
        XCTAssertEqual(BrainIDs.stable("person:rohan mehta"), BrainIDs.stable("person:rohan mehta"))
        XCTAssertNotEqual(BrainIDs.stable("person:rohan mehta"), BrainIDs.stable("person:priya nair"))
    }
}

final class EntityResolverTests: XCTestCase {
    private func m(_ name: String, _ kind: EntityKind = .person, item: UUID, _ d: Int = 0) -> EntityResolver.Mention {
        EntityResolver.Mention(kind: kind, name: name, itemID: item, date: day(d))
    }

    private func names(_ r: EntityResolver.Result, _ kind: EntityKind = .person) -> [String] {
        r.entities.filter { $0.kind == kind }.map(\.name).sorted()
    }

    func testFirstNameMergesWithTheOnlyFullNameWhenTheyCoOccur() {
        let a = UUID(), b = UUID(), c = UUID()
        let mentions = [m("Rohan Mehta", item: a), m("Mehta Traders", .organisation, item: a),
                        m("Rohan", item: b), m("Mehta Traders", .organisation, item: b),
                        m("Rohan ji", item: c), m("Priya Nair", item: c), m("Priya Nair", item: a)]
        let r = EntityResolver().resolve(mentions, existing: [], rules: .init())
        XCTAssertEqual(names(r), ["Priya Nair", "Rohan Mehta"])
        let rohan = r.entities.first { $0.name == "Rohan Mehta" }!
        XCTAssertEqual(rohan.itemIDs, [a, b, c])
        XCTAssertEqual(Set(rohan.aliases), ["Rohan Mehta", "Rohan", "Rohan ji"])
        XCTAssertEqual(rohan.aliases.first, "Rohan Mehta")
        XCTAssertTrue(r.candidates.isEmpty)
    }

    func testFirstNameWithoutCoOccurrenceWaitsForAI() {
        let a = UUID(), b = UUID()
        let r = EntityResolver().resolve([m("Rohan Mehta", item: a), m("Rohan", item: b)], existing: [], rules: .init())
        XCTAssertEqual(names(r), ["Rohan", "Rohan Mehta"])
        XCTAssertEqual(r.candidates.count, 1)
        XCTAssertEqual(r.candidates.first?.reason, "first name only")
        XCTAssertEqual(Set([r.candidates[0].aName, r.candidates[0].bName]), ["Rohan", "Rohan Mehta"])
    }

    func testFirstNameMergesWhenTheirItemsMeanTheSame() {
        let a = UUID(), b = UUID()
        var resolver = EntityResolver()
        resolver.contextMergeSimilarity = 0.8
        let r = resolver.resolve([m("Rohan Mehta", item: a), m("Rohan", item: b)], existing: [], rules: .init()) { _, _ in 0.9 }
        XCTAssertEqual(names(r), ["Rohan Mehta"])
        let far = resolver.resolve([m("Rohan Mehta", item: a), m("Rohan", item: b)], existing: [], rules: .init()) { _, _ in 0.2 }
        XCTAssertEqual(names(far), ["Rohan", "Rohan Mehta"])
    }

    func testFirstNameShared_byTwoPeopleStaysApart() {
        let a = UUID(), b = UUID(), c = UUID()
        let r = EntityResolver().resolve([m("Rohan Mehta", item: a), m("Rohan Gupta", item: b), m("Rohan", item: c),
                                          m("Priya", item: c), m("Priya", item: a)], existing: [], rules: .init())
        XCTAssertEqual(names(r), ["Priya", "Rohan", "Rohan Gupta", "Rohan Mehta"])
    }

    func testInitialsMatchTheOnlyCandidate() {
        let a = UUID(), b = UUID(), c = UUID()
        let r = EntityResolver().resolve([m("Rohan Mehta", item: a), m("R. Mehta", item: b), m("Rohan M.", item: c)], existing: [], rules: .init())
        XCTAssertEqual(names(r), ["Rohan Mehta"])
        XCTAssertEqual(Set(r.entities[0].aliases), ["Rohan Mehta", "R. Mehta", "Rohan M."])

        let two = EntityResolver().resolve([m("Rohan Mehta", item: a), m("Ravi Mehta", item: b), m("R. Mehta", item: c)], existing: [], rules: .init())
        XCTAssertEqual(names(two), ["R. Mehta", "Ravi Mehta", "Rohan Mehta"], "ambiguous initials stay apart")
    }

    func testMiddleNamesAndTitlesMerge() {
        let a = UUID(), b = UUID(), c = UUID()
        let r = EntityResolver().resolve([m("Rohan Mehta", item: a), m("Rohan K. Mehta", item: b), m("Mr. Rohan Mehta", item: c)],
                                         existing: [], rules: .init())
        XCTAssertEqual(r.entities.filter { $0.kind == .person }.count, 1)
        XCTAssertEqual(r.entities[0].itemIDs.count, 3)
    }

    func testOrganisationSuffixesMergeAndNeverAcrossKinds() {
        let a = UUID(), b = UUID(), c = UUID()
        let r = EntityResolver().resolve([m("Mehta Traders Pvt Ltd", .organisation, item: a), m("Mehta Traders", .organisation, item: b),
                                          m("Mehta Traders", .organisation, item: c), m("Mehta Traders", .project, item: c),
                                          m("Jordan", item: a), m("Jordan", .project, item: b)], existing: [], rules: .init())
        XCTAssertEqual(names(r, .organisation), ["Mehta Traders"], "the more common spelling names it")
        XCTAssertEqual(Set(r.entities.first { $0.kind == .organisation }!.aliases), ["Mehta Traders", "Mehta Traders Pvt Ltd"])
        XCTAssertEqual(names(r, .project), ["Jordan", "Mehta Traders"])
        XCTAssertEqual(names(r, .person), ["Jordan"])
    }

    func testLegalSuffixOnAPersonOrProjectNameMakesItAnOrganisation() {
        let item = MemoryItem(people: ["Acme Inc."], projects: ["Northwind LLC", "Seed round"], organisations: ["Harbor Capital"])
        let kinds = Dictionary(uniqueKeysWithValues: EntityResolver.mentions(of: item).map { ($0.name, $0.kind) })
        XCTAssertEqual(kinds["Acme Inc."], .organisation)
        XCTAssertEqual(kinds["Northwind LLC"], .organisation)
        XCTAssertEqual(kinds["Seed round"], .project)
        XCTAssertEqual(kinds["Harbor Capital"], .organisation)
    }

    func testDoNotMergeIsRespected() {
        let a = UUID(), b = UUID()
        let mentions = [m("Rohan Mehta", item: a), m("Rohan", item: a), m("Rohan", item: b)]
        let pair = EntityResolver.pairKey("person:rohan", "person:rohan mehta")
        let r = EntityResolver().resolve(mentions, existing: [], rules: .init(distinct: [pair]))
        XCTAssertEqual(names(r), ["Rohan", "Rohan Mehta"])
        XCTAssertTrue(r.candidates.isEmpty, "a pair the user separated isn't asked about")
    }

    func testAIDecisionsMergeOrSeparate() {
        let a = UUID(), b = UUID()
        let mentions = [m("Sam Rivera", item: a), m("Sam Rivers", item: b)]
        let open = EntityResolver().resolve(mentions, existing: [], rules: .init())
        XCTAssertEqual(open.candidates.map(\.reason), ["similar spelling"])
        let pk = open.candidates[0].pairKey
        XCTAssertEqual(names(EntityResolver().resolve(mentions, existing: [], rules: .init(decisions: [pk: true]))).count, 1)
        let apart = EntityResolver().resolve(mentions, existing: [], rules: .init(decisions: [pk: false]))
        XCTAssertEqual(names(apart).count, 2)
        XCTAssertTrue(apart.candidates.isEmpty)
    }

    func testPrefixAndAcronymCandidatesForOrganisations() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let r = EntityResolver().resolve([m("Mehta", .organisation, item: a), m("Mehta Traders", .organisation, item: b),
                                          m("IBM", .organisation, item: c), m("International Business Machines", .organisation, item: d)],
                                         existing: [], rules: .init())
        XCTAssertEqual(Set(r.candidates.map(\.reason)), ["one name starts the other", "acronym"])
        XCTAssertEqual(names(r, .organisation).count, 4, "candidates don't merge on their own")
    }

    func testIDsStayStableAcrossRunsAndNewSpellings() {
        let a = UUID(), b = UUID(), c = UUID()
        let first = EntityResolver().resolve([m("Rohan Mehta", item: a)], existing: [], rules: .init())
        let id = first.entities[0].id
        XCTAssertEqual(id, BrainIDs.stable("person:rohan mehta"))
        let existing = first.entities.map { EntityResolver.Existing(id: $0.id, kind: $0.kind, name: $0.name, aliases: $0.aliases) }
        let second = EntityResolver().resolve([m("Rohan Mehta", item: a), m("R. Mehta", item: b), m("Rohan Mehta", item: c)],
                                              existing: existing, rules: .init())
        XCTAssertEqual(second.entities.map(\.id), [id])
        XCTAssertEqual(second.entities[0].existingID, id)
    }

    func testSeparateEntitiesThatMergeKeepTheBiggerOnesIDAndAreLogged() {
        let a = UUID(), b = UUID(), c = UUID()
        let mentions = [m("Rohan Mehta", item: a), m("Rohan Mehta", item: c), m("Rohan", item: b)]
        let first = EntityResolver().resolve(mentions, existing: [], rules: .init())
        XCTAssertEqual(first.entities.count, 2)
        let existing = first.entities.map { EntityResolver.Existing(id: $0.id, kind: $0.kind, name: $0.name, aliases: $0.aliases) }
        let fullID = first.entities.first { $0.name == "Rohan Mehta" }!.id
        let pk = first.candidates[0].pairKey
        let merged = EntityResolver().resolve(mentions, existing: existing, rules: .init(decisions: [pk: true]))
        XCTAssertEqual(merged.entities.map(\.id), [fullID])
        XCTAssertEqual(merged.merges.first?.kept, "Rohan Mehta")
        XCTAssertEqual(merged.merges.first?.absorbed, ["Rohan"])
    }

    func testLockedNamesAndForcedAliases() {
        let a = UUID(), b = UUID()
        let id = UUID()
        let existing = [EntityResolver.Existing(id: id, kind: .person, name: "RM", aliases: ["Rohan Mehta"], nameLocked: true)]
        let forced = ["person:boss": EntityResolver.ForcedAlias(entityID: id, spelling: "Boss")]
        let r = EntityResolver().resolve([m("Rohan Mehta", item: a), m("Boss", item: b)], existing: existing, rules: .init(forced: forced))
        XCTAssertEqual(r.entities.count, 1)
        XCTAssertEqual(r.entities[0].id, id)
        XCTAssertEqual(r.entities[0].name, "RM")
        XCTAssertEqual(r.entities[0].itemIDs, [a, b])
    }

    func testDiacriticsAndCaseAreOneEntity() {
        let r = EntityResolver().resolve([m("José Núñez", item: UUID()), m("jose nunez", item: UUID()), m("JOSÉ NÚÑEZ", item: UUID())],
                                         existing: [], rules: .init())
        XCTAssertEqual(r.entities.count, 1)
        XCTAssertEqual(r.entities[0].name, "José Núñez")
    }
}

@MainActor
final class BrainResolutionTests: XCTestCase {
    var dir: URL!
    override func setUp() async throws { dir = makeTempDirectory() }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    func testBrainResolvesItemsIntoEntitiesWithCounts() {
        let library = MemoryLibrary(directory: dir, saveDelay: 60)
        library.add(MemoryItem(title: "Call", people: ["Rohan Mehta", "Priya Nair"], organisations: ["Mehta Traders Pvt Ltd"], createdAt: day(-3)))
        library.add(MemoryItem(title: "Quote", people: ["Rohan"], organisations: ["Mehta Traders"], createdAt: day(-1)))
        library.add(MemoryItem(title: "PO", people: ["R. Mehta"], projects: ["Mehta Traders"], createdAt: day(0)))
        let brain = MemoryBrain.test(library)
        let rohan = try! XCTUnwrap(brain.entity(named: "Rohan", kind: .person))
        XCTAssertEqual(rohan.name, "Rohan Mehta")
        XCTAssertEqual(rohan.itemCount, 3)
        XCTAssertEqual(rohan.firstSeen, day(-3))
        XCTAssertEqual(rohan.lastSeen, day(0))
        XCTAssertEqual(brain.entity(named: "mehta traders pvt. ltd.", kind: .organisation)?.itemCount, 2)
        XCTAssertEqual(brain.entities(.project).map(\.name), ["Mehta Traders"], "a project of the same name stays a project")
        XCTAssertEqual(Set(brain.entities(for: library.items[0].id).map(\.name)), ["Rohan Mehta", "Mehta Traders"])
        let related = brain.related(rohan.id).map(\.entity.name)
        XCTAssertEqual(related.first, "Mehta Traders")
    }

    func testAmbiguousNamesGoToAIOnceAndAnswersStick() async throws {
        let library = MemoryLibrary(directory: dir, saveDelay: 60)
        library.add(MemoryItem(title: "A", people: ["Rohan Mehta"]))
        library.add(MemoryItem(title: "B", people: ["Rohan"]))
        let brain = MemoryBrain.test(library)
        XCTAssertEqual(brain.entities(.person).count, 2)
        XCTAssertEqual(brain.pendingCandidates.count, 1)
        let ai = brainAI(same: true)
        let decided = try await BrainOrganizer(brain: brain, ai: ai).resolveAmbiguous()
        XCTAssertEqual(decided, 1)
        XCTAssertEqual(brain.entities(.person).map(\.name), ["Rohan Mehta"])
        XCTAssertTrue(brain.pendingCandidates.isEmpty)
        XCTAssertTrue(ai.generateCalls[0].prompt.contains("\"Rohan\" vs \"Rohan Mehta\"") || ai.generateCalls[0].prompt.contains("\"Rohan Mehta\" vs \"Rohan\""))
        XCTAssertEqual(brain.changeLog.first?.kind, .resolved)
        // Remembered: a new brain on the same files doesn't ask again.
        brain.flush()
        let again = MemoryBrain.test(library)
        XCTAssertEqual(again.entities(.person).count, 1)
        XCTAssertTrue(again.pendingCandidates.isEmpty)
    }
}
