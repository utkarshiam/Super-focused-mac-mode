import CoreGraphics
import MemoryKit
import XCTest
@testable import Docket

// The brain screens' rules, without a window: the map's viewport math, hit testing and which labels fit, the
// area palette, the time slider, kind filters, the "Docket reorganised your memory" line, a page's text with
// citation chips, the merge picker and ⌘K's filter, and which page or memory is open on the right. Made-up
// names (Priya Shah, Pricing) and a throwaway library folder.

@MainActor
final class BrainViewsTests: XCTestCase {
    private var folders: [URL] = []

    override func tearDown() async throws {
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
        folders = []
    }

    private func seededBrain(now: Date = Date()) -> MemoryBrain {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("docket-brain-views-\(UUID().uuidString)")
        folders.append(folder)
        let brain = MemoryBrain(library: MemoryLibrary(directory: folder, saveDelay: 0), saveDelay: 0, autoUpdate: false)
        brain.debugSeed(now: now)
        return brain
    }

    private func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))! }

    // MARK: Viewport

    func testViewportRoundTripsBetweenWorldAndScreen() {
        let v = MapViewport(scale: 32, offset: CGPoint(x: 100, y: -40))
        let p = MapPoint(x: 1.5, y: -2.25)
        let s = v.toScreen(p)
        XCTAssertEqual(s.x, 148, accuracy: 0.0001)
        XCTAssertEqual(s.y, -112, accuracy: 0.0001)
        let back = v.toWorld(s)
        XCTAssertEqual(back.x, p.x, accuracy: 0.0001)
        XCTAssertEqual(back.y, p.y, accuracy: 0.0001)
    }

    func testFitCentresTheGraphBetweenTheControls() {
        let size = CGSize(width: 800, height: 600)
        let v = MapViewport.fit((minX: -2, minY: -1, maxX: 4, maxY: 3), in: size, padding: 50, top: 40, bottom: 60)
        // Height is the tighter side: (600 - 100 - 100) / 4 = 100.
        XCTAssertEqual(v.scale, 100, accuracy: 0.0001)
        let centre = v.toScreen(MapPoint(x: 1, y: 1))
        XCTAssertEqual(centre.x, 400, accuracy: 0.0001)
        XCTAssertEqual(centre.y, 40 + 500 / 2, accuracy: 0.0001)
        // Everything lands inside, clear of the bars.
        let corner = v.toScreen(MapPoint(x: 4, y: 3))
        XCTAssertLessThanOrEqual(corner.y, 600 - 60 - 50 + 0.0001)
        // A lone node doesn't blow up to infinity.
        let lone = MapViewport.fit((minX: 1, minY: 1, maxX: 1, maxY: 1), in: size, maxScale: 140)
        XCTAssertEqual(lone.scale, 140)
    }

    func testZoomKeepsThePointUnderThePointerAndStaysInRange() {
        let v = MapViewport(scale: 40, offset: CGPoint(x: 10, y: 20))
        let anchor = CGPoint(x: 300, y: 200)
        let before = v.toWorld(anchor)
        let z = v.zoomed(by: 2, about: anchor, range: 10...200)
        XCTAssertEqual(z.scale, 80)
        let after = z.toWorld(anchor)
        XCTAssertEqual(after.x, before.x, accuracy: 0.0001)
        XCTAssertEqual(after.y, before.y, accuracy: 0.0001)
        XCTAssertEqual(v.zoomed(by: 100, about: anchor, range: 10...200).scale, 200, "clamped")
        XCTAssertEqual(MapViewport.interpolate(v, z, 0), v)
        XCTAssertEqual(MapViewport.interpolate(v, z, 1).scale, z.scale, accuracy: 0.0001)
    }

    // MARK: Hit testing and labels

    func testHitTestingPicksTheClosestNodeWithinItsRadius() {
        let nodes: [(id: UUID, center: CGPoint, radius: CGFloat)] = [
            (id(1), CGPoint(x: 100, y: 100), 20),
            (id(2), CGPoint(x: 130, y: 100), 6),
        ]
        XCTAssertEqual(MapGeometry.hit(CGPoint(x: 101, y: 100), nodes: nodes), id(1))
        // Inside both: the small one whose edge is nearer wins.
        XCTAssertEqual(MapGeometry.hit(CGPoint(x: 128, y: 100), nodes: nodes), id(2))
        XCTAssertNil(MapGeometry.hit(CGPoint(x: 300, y: 300), nodes: nodes))
        XCTAssertEqual(MapGeometry.hit(CGPoint(x: 123, y: 100), nodes: nodes, slop: 4), id(2))
    }

    func testNodeRadiusGrowsWithSizeAndZoom() {
        XCTAssertGreaterThan(MapGeometry.radius(kind: .topic, size: 16, zoom: 1), MapGeometry.radius(kind: .topic, size: 1, zoom: 1))
        XCTAssertGreaterThan(MapGeometry.radius(kind: .topic, size: 4, zoom: 4), MapGeometry.radius(kind: .topic, size: 4, zoom: 1))
        XCTAssertLessThanOrEqual(MapGeometry.radius(kind: .area, size: 10_000, zoom: 1), 34)
    }

    func testLabelsSkipOverlapsAndKeepTheMostImportant() {
        func c(_ n: Int, _ x: CGFloat, _ priority: Double) -> MapLabels.Candidate {
            .init(id: id(n), center: CGPoint(x: x, y: 100), radius: 5, size: CGSize(width: 60, height: 14), priority: priority)
        }
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        let shown = MapLabels.visible([c(1, 100, 10), c(2, 120, 50), c(3, 300, 1)], in: bounds, limit: 10)
        XCTAssertEqual(shown, [id(2), id(3)], "the bigger of two overlapping labels wins")
        let forced = MapLabels.visible([c(1, 100, 10), c(2, 120, 50)], in: bounds, always: [id(1)], limit: 10)
        XCTAssertTrue(forced.contains(id(1)), "the hovered node's label always shows")
        XCTAssertEqual(MapLabels.visible([c(1, 50, 1), c(2, 200, 2), c(3, 350, 3)], in: bounds, limit: 2).count, 2)
        XCTAssertTrue(MapLabels.visible([c(1, 395, 1)], in: bounds, limit: 5).isEmpty, "a label off the edge is skipped")
        XCTAssertGreaterThan(MapLabels.limit(for: CGSize(width: 1200, height: 800), zoom: 3), MapLabels.limit(for: CGSize(width: 1200, height: 800), zoom: 1))
    }

    // MARK: Palette, filters, time

    func testPaletteIsDeterministicAndDistinct() {
        let areas = (1...6).map(id)
        let a = BrainPalette.slots(for: areas)
        let b = BrainPalette.slots(for: areas.reversed())
        XCTAssertEqual(a, b, "the order areas come in doesn't matter")
        XCTAssertEqual(Set(a.values).count, 6, "no two areas share a colour while there are colours left")
        let many = BrainPalette.slots(for: (1...12).map(id))
        XCTAssertEqual(many.count, 12)
        XCTAssertTrue(many.values.allSatisfy { (0..<BrainPalette.count).contains($0) })
        XCTAssertNotEqual(BrainPalette.hex(slot: 0, dark: false), BrainPalette.hex(slot: 0, dark: true))
    }

    func testKindFiltersKeepAreasAndDropEdgesToHiddenNodes() {
        let area = MapNode(id: id(1), kind: .area, name: "Product", size: 4)
        let topic = MapNode(id: id(2), kind: .topic, name: "Pricing", size: 2, areaID: id(1))
        let person = MapNode(id: id(3), kind: .person, name: "Priya Shah", size: 1)
        let graph = MapGraph(nodes: [area, topic, person],
                             edges: [MapEdge(a: id(2), b: id(1), weight: 1, kind: .hierarchy), MapEdge(a: id(3), b: id(2), weight: 0.5, kind: .shared)],
                             hiddenByKind: ["person": 4, "project": 2])
        let topicsOnly = MapFilter.apply(graph, kinds: [.topic])
        XCTAssertEqual(Set(topicsOnly.nodes.map(\.id)), [id(1), id(2)])
        XCTAssertEqual(topicsOnly.edges.count, 1)
        XCTAssertEqual(MapFilter.hiddenCount(graph, kinds: [.topic, .person]), 4)
        XCTAssertEqual(MapFilter.hiddenCount(graph, kinds: Set(MapFilter.switchable)), 6)
        XCTAssertEqual(MapFilter.label(.project, Lens.sales.vocabulary), Lens.sales.vocabulary.projects)
    }

    func testTimeSliderMapsToRealDaysAndNowAtTheEnd() {
        let cal = Calendar.current
        let first = cal.date(from: DateComponents(year: 2026, month: 9, day: 1, hour: 9))!
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 9))!
        XCTAssertNil(MapTime.date(at: 1, first: first, now: now), "the right end is now")
        XCTAssertEqual(MapTime.fraction(of: nil, first: first, now: now), 1)
        let mid = MapTime.date(at: 0.5, first: first, now: now)!
        XCTAssertEqual(mid, cal.endOfDay(for: cal.date(from: DateComponents(year: 2026, month: 9, day: 16))!))
        XCTAssertEqual(MapTime.fraction(of: mid, first: first, now: now), 0.5, accuracy: 0.05)
        XCTAssertEqual(MapTime.fraction(of: first.addingTimeInterval(-86_400), first: first, now: now), 0)
        XCTAssertEqual(MapMotion.spring(0), 0)
        XCTAssertEqual(MapMotion.spring(10), 1)
        XCTAssertGreaterThan(MapMotion.spring(0.2), MapMotion.spring(0.1))
    }

    // MARK: Banner

    func testBannerCountsWhatAutomationChangedSinceLastSeen() {
        let now = Date()
        let changes = [
            BrainChange(date: now.addingTimeInterval(-3600), kind: .organised, summary: "…",
                        details: ["2 new topics: Pricing page, Annual discounts", "merged Pricing strategy into Pricing", "renamed Hiring to Hiring engineers"]),
            BrainChange(date: now.addingTimeInterval(-7200), kind: .resolved, summary: "Merged Acme Inc. into Acme", details: ["Acme Inc. → Acme"]),
            BrainChange(date: now.addingTimeInterval(-60), kind: .correction, summary: "Renamed Seed to Seed round", details: ["Renamed Seed to Seed round"]),
        ]
        let line = BrainBanner.line(changes, since: now.addingTimeInterval(-86_400), now: now)
        XCTAssertEqual(line?.text, "Docket reorganised your memory: 2 new topics, 2 merged, 1 renamed")
        XCTAssertEqual(line?.newest, now.addingTimeInterval(-3600), "the user's own correction isn't news")
        XCTAssertNil(BrainBanner.line(changes, since: now.addingTimeInterval(-1800), now: now), "seen already")
        // Never seen: the last week counts; an old change doesn't.
        let old = [BrainChange(date: now.addingTimeInterval(-30 * 86_400), kind: .organised, summary: "…", details: ["1 new topic: Pricing"])]
        XCTAssertNil(BrainBanner.line(old, since: nil, now: now))
        let first = [BrainChange(date: now.addingTimeInterval(-60), kind: .organised, summary: "Organised 16 memories into 11 topics in 6 areas")]
        XCTAssertEqual(BrainBanner.line(first, since: nil, now: now)?.text, "Docket organised your memory: 16 memories into 11 topics in 6 areas")
    }

    // MARK: Page text

    func testSummaryReusesCitationSegmentsWithBullets() {
        let segments = BrainText.summarySegments("- Raising **$2M** on a SAFE [1].\n- Board deck said $1.5M [2][5].", sources: 2)
        XCTAssertEqual(segments, [.text("•\u{2002}Raising **$2M** on a SAFE"), .citation(1), .text(".\n•\u{2002}Board deck said $1.5M"), .citation(2),
                                  .text("[5].")])
        let bold = BrainText.inline("Raising **$2M** now")
        XCTAssertEqual(String(bold.characters), "Raising $2M now")
        XCTAssertEqual(String(BrainText.inline("broken **bold").characters), "broken **bold")
    }

    func testWordsUseRealDatesAndCounts() {
        let cal = Calendar.current
        let a = cal.date(from: DateComponents(year: 2026, month: 9, day: 22, hour: 10))!
        let b = cal.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 10))!
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 10))!
        let seen = BrainText.seen(first: a, last: b, now: now)!
        XCTAssertTrue(seen.hasPrefix("First \(MemoryText.date(a, now: now))"), seen)
        XCTAssertFalse(seen.contains("Today") || seen.contains("Yesterday"))
        XCTAssertEqual(BrainText.seen(first: a, last: a, now: now), "Seen \(MemoryText.date(a, now: now))")
        XCTAssertEqual(BrainText.unsorted(12), "12 not sorted yet")
        XCTAssertEqual(BrainText.subTopics(1), "1 sub-topic")
        let deal = BrainEntity(kind: .project, name: "Acme pilot", itemCount: 3)
        XCTAssertEqual(BrainText.meta(deal, subTopics: 0, vocabulary: Lens.sales.vocabulary), "\(Lens.sales.vocabulary.project) · 3 memories")
        let priya = BrainEntity(kind: .person, name: "Priya Shah", aliases: ["Priya Shah", "Priya", "P. Shah"])
        XCTAssertEqual(BrainText.aliases(priya), "also Priya, P. Shah")
        XCTAssertNil(BrainText.aliases(BrainEntity(kind: .person, name: "Tom Becker")))
    }

    // MARK: Picking

    func testPickerFiltersByNameAndSpellingSameKind() {
        let pricing = BrainEntity(id: id(1), kind: .topic, name: "Pricing", aliases: ["Pricing", "Pricing strategy"], itemCount: 2)
        let page = BrainEntity(id: id(2), kind: .topic, name: "Pricing page", itemCount: 5)
        let discounts = BrainEntity(id: id(3), kind: .topic, name: "Annual discounts", aliases: ["Annual discounts", "Discounts on pricing"], itemCount: 9)
        let priya = BrainEntity(id: id(4), kind: .person, name: "Priya Shah", aliases: ["Priya Shah", "P. Shah"], itemCount: 1)
        let all = [pricing, page, discounts, priya]
        XCTAssertEqual(EntityPicker.filter(all, query: "pric", kind: .topic).map(\.id), [id(2), id(1), id(3)],
                       "names starting with it first (bigger first), then a spelling that mentions it")
        XCTAssertEqual(EntityPicker.filter(all, query: "PRÍCING", kind: .topic, excluding: [id(1)]).map(\.id), [id(2), id(3)])
        XCTAssertEqual(EntityPicker.filter(all, query: "shah").map(\.id), [id(4)])
        XCTAssertEqual(EntityPicker.filter(all, query: "", kind: .person).map(\.id), [id(4)])
        XCTAssertEqual(EntityPicker.paletteQuery("Go to Pricing"), "Pricing")
        XCTAssertEqual(EntityPicker.paletteQuery("pricing page"), "pricing page")
    }

    func testSeededBrainIsFoundBySpellingsAndBanner() {
        let now = Date()
        let brain = seededBrain(now: now)
        let byAlias = EntityPicker.filter(brain.entities, query: "P. Shah", kind: .person)
        XCTAssertEqual(byAlias.first?.name, "Priya Shah")
        XCTAssertNotNil(BrainBanner.line(brain.changeLog, since: nil, now: now), "the seed reorganised yesterday")
        let slots = BrainPalette.slots(for: brain.areas().map(\.id))
        XCTAssertEqual(Set(slots.values).count, brain.areas().count)
        let digest = brain.digest(for: now)
        XCTAssertTrue(BrainText.digestTitle(digest, now: now).hasPrefix("What you learned · "))
    }

    // MARK: What's open on the right

    func testPagesAndMemoriesTakeTurnsOnTheRight() {
        let app = AppState()
        let page = id(1), item = id(2)
        app.selectedMemoryID = item
        app.selectedEntityID = page
        XCTAssertNil(app.selectedMemoryID, "opening a page closes the memory")
        app.openMemory(item, from: page)
        XCTAssertEqual(app.selectedMemoryID, item)
        XCTAssertNil(app.selectedEntityID)
        XCTAssertEqual(app.memoryBackEntityID, page, "the memory knows its way back")
        app.selectedMemoryID = id(3)
        XCTAssertNil(app.memoryBackEntityID, "a memory opened elsewhere has no way back")
    }

    func testMemoryModeIsRemembered() {
        let key = MemoryMode.defaultsKey
        let saved = UserDefaults.standard.string(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        MemoryMode.save(.map)
        XCTAssertEqual(MemoryMode.saved, .map)
        UserDefaults.standard.set("nonsense", forKey: key)
        XCTAssertEqual(MemoryMode.saved, .library)
        XCTAssertEqual(MemoryMode.allCases.map(\.label), ["Library", "Topics", "Map"])
    }
}
