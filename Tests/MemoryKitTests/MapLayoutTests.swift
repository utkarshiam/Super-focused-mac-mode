import XCTest
@testable import MemoryKit

final class MapLayoutTests: XCTestCase {
    /// A synthetic graph: `areas` areas, `topicsPerArea` topics each, and `others` people/projects linked to
    /// 2–3 topics. Deterministic ids.
    private func graph(areas: Int, topicsPerArea: Int, others: Int, seed: UInt64 = 1) -> ([MapLayout.Node], [MapEdge]) {
        var rng = SeedRandom(seed: seed)
        func id(_ s: String) -> UUID { BrainIDs.stable("map-test:" + s) }
        var nodes: [MapLayout.Node] = []
        var edges: [MapEdge] = []
        var topics: [(UUID, UUID)] = []
        for a in 0..<areas {
            let area = id("area\(a)")
            nodes.append(.init(id: area, kind: .area, size: 50, areaID: area))
            for t in 0..<topicsPerArea {
                let topic = id("topic\(a).\(t)")
                nodes.append(.init(id: topic, kind: .topic, size: 5 + t, areaID: area, parentID: area))
                edges.append(MapEdge(a: topic, b: area, weight: 1, kind: .hierarchy))
                topics.append((topic, area))
            }
        }
        for o in 0..<others {
            let node = id("other\(o)")
            let home = topics[Int(rng.next() % UInt64(topics.count))]
            nodes.append(.init(id: node, kind: o % 3 == 0 ? .project : .person, size: 1 + o % 7, areaID: home.1))
            edges.append(MapEdge(a: node, b: home.0, weight: 0.8, kind: .shared))
            for _ in 0..<2 {
                let other = topics[Int(rng.next() % UInt64(topics.count))]
                edges.append(MapEdge(a: node, b: other.0, weight: 0.2, kind: .shared))
            }
        }
        return (nodes, edges)
    }

    private func distance(_ a: MapPoint, _ b: MapPoint) -> Double { ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot() }

    func testLayoutIsDeterministic() {
        let (nodes, edges) = graph(areas: 4, topicsPerArea: 5, others: 40)
        let a = MapLayout().layout(nodes, edges: edges)
        let b = MapLayout().layout(nodes.reversed(), edges: edges.reversed())
        XCTAssertEqual(a, b, "input order doesn't matter")
        XCTAssertEqual(a.count, nodes.count)
        XCTAssertTrue(a.values.allSatisfy { $0.x.isFinite && $0.y.isFinite })
    }

    func testTopicsSitNearTheirArea() {
        let (nodes, edges) = graph(areas: 5, topicsPerArea: 6, others: 60)
        let p = MapLayout().layout(nodes, edges: edges)
        let areas = nodes.filter { $0.kind == .area }
        var closest = 0, total = 0
        for t in nodes where t.kind == .topic {
            let own = distance(p[t.id]!, p[t.parentID!]!)
            let nearest = areas.map { distance(p[t.id]!, p[$0.id]!) }.min()!
            total += 1
            if own <= nearest + 1e-9 { closest += 1 }
        }
        XCTAssertGreaterThanOrEqual(Double(closest) / Double(total), 0.9, "\(closest) of \(total) topics are nearest their own area")
        // Areas don't overlap.
        for i in areas.indices { for j in areas.indices where j > i { XCTAssertGreaterThan(distance(p[areas[i].id]!, p[areas[j].id]!), 1) } }
    }

    func testWarmStartKeepsTheMapStill() {
        let (nodes, edges) = graph(areas: 4, topicsPerArea: 5, others: 60)
        let first = MapLayout().layout(nodes, edges: edges)
        var more = nodes
        var moreEdges = edges
        let newcomer = BrainIDs.stable("map-test:newcomer")
        let anchor = nodes.first { $0.kind == .topic }!
        more.append(.init(id: newcomer, kind: .person, size: 3, areaID: anchor.areaID))
        moreEdges.append(MapEdge(a: newcomer, b: anchor.id, weight: 0.9, kind: .shared))
        let second = MapLayout().layout(more, edges: moreEdges, previous: first)
        let moves = nodes.map { distance(first[$0.id]!, second[$0.id]!) }
        let mean = moves.reduce(0, +) / Double(moves.count)
        XCTAssertLessThan(mean, 0.5, "existing nodes barely move (mean \(mean))")
        XCTAssertEqual(nodes.filter { $0.kind == .area }.map { first[$0.id]! }, nodes.filter { $0.kind == .area }.map { second[$0.id]! })
        XCTAssertLessThan(distance(second[newcomer]!, second[anchor.id]!), 4, "the newcomer lands next to its neighbour")
    }

    func testNewAreaGoesIntoTheWidestGap() {
        let (nodes, edges) = graph(areas: 3, topicsPerArea: 2, others: 0)
        let first = MapLayout().layout(nodes, edges: edges)
        let extra = BrainIDs.stable("map-test:area-new")
        let second = MapLayout().layout(nodes + [.init(id: extra, kind: .area, size: 1, areaID: extra)], edges: edges, previous: first)
        for a in nodes where a.kind == .area { XCTAssertGreaterThan(distance(second[extra]!, second[a.id]!), 1) }
    }

    func testPerformanceOfAThousandNodes() {
        let (nodes, edges) = graph(areas: 8, topicsPerArea: 18, others: 848)
        XCTAssertEqual(nodes.count, 1000)
        let start = Date()
        let cold = MapLayout().layout(nodes, edges: edges)
        let coldTime = Date().timeIntervalSince(start)
        let warmStart = Date()
        _ = MapLayout().layout(nodes, edges: edges, previous: cold)
        let warmTime = Date().timeIntervalSince(warmStart)
        print("[perf] map layout, 1000 nodes / \(edges.count) edges: cold \(String(format: "%.3f", coldTime)) s, warm \(String(format: "%.3f", warmTime)) s")
        XCTAssertEqual(cold.count, 1000)
    }

    func testGraphFilteringAndNeighbourhoods() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let g = MapGraph(nodes: [MapNode(id: a, kind: .area, name: "A", size: 3, firstSeen: day(-10)),
                                 MapNode(id: b, kind: .topic, name: "B", size: 2, firstSeen: day(-5)),
                                 MapNode(id: c, kind: .person, name: "C", size: 1, firstSeen: day(-1)),
                                 MapNode(id: d, kind: .person, name: "D", size: 1, firstSeen: day(-20))],
                         edges: [MapEdge(a: a, b: b, weight: 1, kind: .hierarchy), MapEdge(a: b, b: c, weight: 0.5, kind: .shared)])
        XCTAssertEqual(g.neighbourhood(of: a, hops: 1), [a, b])
        XCTAssertEqual(g.neighbourhood(of: a, hops: 2), [a, b, c])
        XCTAssertEqual(Set(g.focused(on: c, hops: 1).nodes.map(\.id)), [b, c])
        XCTAssertEqual(g.focused(on: c, hops: 1).focus, c)
        let old = g.filtered(asOf: day(-3))
        XCTAssertEqual(Set(old.nodes.map(\.id)), [a, b, d])
        XCTAssertEqual(old.edges.count, 1)
        XCTAssertEqual(try roundTrip(g), g)
    }
}

@MainActor
final class BrainMapTests: XCTestCase {
    var dir: URL!
    override func setUp() async throws { dir = makeTempDirectory() }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    func testBrainMapHasAreasTopicsPeopleAndCachedPositions() async throws {
        let library = themedLibrary(dir, themes: [Theme(label: "pricing", count: 6, people: ["Ana Ruiz"], projects: ["Pricing refresh"]),
                                                  Theme(label: "hiring", count: 6, people: ["Maya Chen", "Ana Ruiz"]),
                                                  Theme(label: "fundraising", count: 6, organisations: ["Harbor Capital"])])
        let brain = MemoryBrain.test(library)
        await brain.organizeNow(ai: brainAI(areas: ["pricing": "Product", "hiring": "Team", "fundraising": "Money"]))
        let map = brain.map()
        let kinds = Dictionary(grouping: map.nodes, by: \.kind).mapValues(\.count)
        XCTAssertEqual(kinds[.area], 3)
        XCTAssertEqual(kinds[.topic], 3)
        XCTAssertEqual(kinds[.person], 2)
        XCTAssertEqual(kinds[.organisation], 1)
        XCTAssertEqual(kinds[.project], 1)
        XCTAssertEqual(map.edges.filter { $0.kind == .hierarchy }.count, 3)
        let ana = try XCTUnwrap(map.nodes.first { $0.name == "Ana Ruiz" })
        XCTAssertEqual(ana.size, 12)
        XCTAssertTrue(map.edges.contains { $0.kind == .shared && ($0.a == ana.id || $0.b == ana.id) })
        let pricing = try XCTUnwrap(map.nodes.first { $0.name == "Pricing" })
        XCTAssertEqual(map.node(pricing.areaID!)?.name, "Product")

        // Cached: the same positions again, and after a reload from disk.
        XCTAssertEqual(brain.map(), map)
        brain.flush()
        let reopened = MemoryBrain.test(library)
        XCTAssertEqual(reopened.map().nodes.map(\.position), map.nodes.map(\.position))

        // A new person nudges nothing much.
        library.add(MemoryItem(title: "Intro", people: ["Leo Martins", "Maya Chen"], topics: ["hiring"], createdAt: day(1), processing: .processed))
        brain.refresh()
        let after = brain.map()
        let before = Dictionary(uniqueKeysWithValues: map.nodes.map { ($0.id, $0.position) })
        for n in after.nodes where n.kind == .area { XCTAssertEqual(n.position, before[n.id]) }
        XCTAssertNotNil(after.nodes.first { $0.name == "Leo Martins" })
    }

    func testAsOfFocusAndCap() async throws {
        let library = themedLibrary(dir, themes: [Theme(label: "pricing", count: 6, people: ["Ana Ruiz"]),
                                                  Theme(label: "hiring", count: 6, people: ["Maya Chen"])])
        // Items are one per day backwards from day(0): pricing are days 0…-5, hiring days -6…-11.
        let brain = MemoryBrain.test(library)
        await brain.organizeNow(ai: nil)
        let full = brain.map()
        let past = brain.map(asOf: day(-6, hour: 23))
        XCTAssertNil(past.nodes.first { $0.name == "Pricing" }, "pricing didn't exist yet")
        XCTAssertNil(past.nodes.first { $0.name == "Ana Ruiz" })
        let hiring = try XCTUnwrap(past.nodes.first { $0.name == "Hiring" })
        XCTAssertEqual(hiring.size, 6)
        XCTAssertEqual(hiring.position, full.node(hiring.id)?.position, "positions don't move with the date")
        XCTAssertEqual(past.asOf, day(-6, hour: 23))
        let mid = brain.map(asOf: day(-9, hour: 23))
        XCTAssertEqual(mid.nodes.first { $0.name == "Hiring" }?.size, 3)

        let focus = brain.map(focus: hiring.id, hops: 1, includeItems: true)
        XCTAssertEqual(focus.focus, hiring.id)
        XCTAssertTrue(focus.nodes.contains { $0.name == "Maya Chen" })
        XCTAssertFalse(focus.nodes.contains { $0.name == "Ana Ruiz" })
        XCTAssertEqual(focus.nodes.filter { $0.kind == .item }.count, 6)

        let capped = brain.map(maxNodes: 3)
        XCTAssertEqual(capped.nodes.count, 3)
        XCTAssertEqual(capped.hiddenCount, 1)
        XCTAssertEqual(capped.hiddenByKind["topic"], 1, "topics get at most 60% of the cap")
    }
}
