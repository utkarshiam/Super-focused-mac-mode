import Foundation

extension MemoryBrain {
    /// The default node cap for the map: all areas, then topics and the biggest people, organisations and
    /// projects. The rest are counted in `MapGraph.hiddenByKind`.
    public nonisolated static let defaultMapNodes = 150

    /// The mental map.
    /// - asOf: show the graph as it was on that date (items saved later don't count; entities with no items
    ///   by then disappear). Positions don't change with the date, so a time slider doesn't make nodes jump.
    /// - focus, hops: only the neighbourhood of one entity (1–2 hops), positions unchanged.
    /// - maxNodes: the cap (areas always shown).
    /// - includeItems: with a focus, also the focus's newest items (up to 24) placed around it.
    ///
    /// Positions come from a cached layout that is updated incrementally (warm start) when the graph
    /// changes, and stored in brain.json. Cheap to call repeatedly; the full graph is cached per revision.
    public func map(asOf: Date? = nil, focus: UUID? = nil, hops: Int = 1, maxNodes: Int = MemoryBrain.defaultMapNodes,
                    includeItems: Bool = false) -> MapGraph {
        var graph = fullMap(maxNodes: maxNodes)
        if let asOf {
            let positions = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0.position) })
            var dated = buildGraph(asOf: asOf, maxNodes: maxNodes, restrictTo: Set(positions.keys))
            for i in dated.nodes.indices { dated.nodes[i].position = positions[dated.nodes[i].id] ?? .zero }
            dated.hiddenByKind = graph.hiddenByKind
            dated.asOf = asOf
            graph = dated
        }
        if let focus {
            graph = graph.focused(on: focus, hops: hops)
            if includeItems, let center = graph.node(focus) {
                let items = items(for: focus).filter { asOf == nil || $0.createdAt <= asOf! }.prefix(24)
                for (i, item) in items.enumerated() {
                    let angle = 2 * Double.pi * Double(i) / Double(max(1, items.count))
                    let r = 0.9 * (1 + Double(i % 2) * 0.35)
                    graph.nodes.append(MapNode(id: item.id, kind: .item, name: item.displayTitle, size: 1, areaID: center.areaID,
                                               position: MapPoint(x: center.position.x + cos(angle) * r, y: center.position.y + sin(angle) * r),
                                               firstSeen: item.createdAt, lastSeen: item.createdAt))
                    graph.edges.append(MapEdge(a: item.id, b: focus, weight: 0.5, kind: .item))
                }
            }
        }
        return graph
    }

    /// The current graph with positions (cached per revision; layout cached in brain.json).
    func fullMap(maxNodes: Int) -> MapGraph {
        let cacheKey = "\(revision)|\(maxNodes)"
        if let cached = mapCache, cached.key == cacheKey { return cached.graph }
        var graph = buildGraph(asOf: nil, maxNodes: maxNodes, restrictTo: nil)
        let ids = graph.nodes.map(\.id)
        let key = MapLayout.key(for: ids)
        var previous: [UUID: MapPoint] = [:]
        for id in ids { if let p = state.layout[id.uuidString] { previous[id] = p } }
        let positions: [UUID: MapPoint]
        if key == state.layoutKey && previous.count == ids.count {
            positions = previous
        } else {
            let nodes = graph.nodes.map { MapLayout.Node(id: $0.id, kind: $0.kind, size: $0.size, areaID: $0.areaID, parentID: $0.parentID) }
            positions = MapLayout().layout(nodes, edges: graph.edges, previous: previous)
            var layout = state.layout
            for (id, p) in positions { layout[id.uuidString] = p }
            // Forget positions of entities that no longer exist.
            let live = Set(state.entities.map(\.id.uuidString))
            layout = layout.filter { live.contains($0.key) }
            state.layout = layout
            state.layoutKey = key
            didChangeQuietly()
        }
        for i in graph.nodes.indices { graph.nodes[i].position = positions[graph.nodes[i].id] ?? .zero }
        mapCache = (cacheKey, graph)
        return graph
    }

    /// Nodes and edges (no positions) as of a date, capped. `restrictTo` limits nodes to a set (the current
    /// graph's), so a dated graph is always a subset of today's.
    func buildGraph(asOf: Date?, maxNodes: Int, restrictTo: Set<UUID>?) -> MapGraph {
        let visibleItem: (UUID) -> Bool = { id in
            guard let asOf else { return true }
            return (self.library.item(id)?.createdAt ?? .distantFuture) <= asOf
        }
        // Sizes as of the date.
        var sizes: [UUID: Int] = [:]
        var firstSeen: [UUID: Date] = [:]
        for e in state.entities {
            let ids = itemIDs(for: e.id).filter(visibleItem)
            sizes[e.id] = ids.count
            if let first = ids.compactMap({ library.item($0)?.createdAt }).min() { firstSeen[e.id] = first }
        }
        func allowed(_ e: BrainEntity) -> Bool { (sizes[e.id] ?? 0) > 0 && (restrictTo?.contains(e.id) ?? true) }

        // Pick nodes: areas, then topics, then the biggest people/organisations/projects.
        let areas = state.entities.filter { $0.kind == .area && allowed($0) }
        var budget = max(areas.count, maxNodes) - areas.count
        let rank: (BrainEntity, BrainEntity) -> Bool = { a, b in
            let sa = sizes[a.id] ?? 0, sb = sizes[b.id] ?? 0
            if sa != sb { return sa > sb }
            if (a.lastSeen ?? .distantPast) != (b.lastSeen ?? .distantPast) { return (a.lastSeen ?? .distantPast) > (b.lastSeen ?? .distantPast) }
            return a.id.uuidString < b.id.uuidString
        }
        let topicCandidates = state.entities.filter { $0.kind == .topic && allowed($0) }.sorted(by: rank)
        // Parents before children so a sub-topic never shows without its topic.
        var topics: [BrainEntity] = []
        let topicCap = max(1, (budget * 6) / 10)
        for t in topicCandidates.filter({ t in t.parentID.flatMap(entity)?.kind != .topic }) + topicCandidates.filter({ t in t.parentID.flatMap(entity)?.kind == .topic }) {
            guard topics.count < topicCap else { break }
            if let p = t.parentID, entity(p)?.kind == .topic, !topics.contains(where: { $0.id == p }) { continue }
            topics.append(t)
        }
        budget -= topics.count
        let others = state.entities.filter { $0.kind.isExtracted && allowed($0) }.sorted(by: rank)
        let shownOthers = Array(others.prefix(max(0, budget)))
        var hidden: [String: Int] = [:]
        let hiddenTopics = topicCandidates.count - topics.count
        if hiddenTopics > 0 { hidden[EntityKind.topic.rawValue] = hiddenTopics }
        for o in others.dropFirst(shownOthers.count) { hidden[o.kind.rawValue, default: 0] += 1 }

        let chosen = areas + topics + shownOthers
        let chosenIDs = Set(chosen.map(\.id))
        // Each item's visible entities (a hidden sub-topic counts as its topic).
        func visibleTopic(_ id: UUID) -> UUID? {
            var cursor: UUID? = id
            while let c = cursor {
                if chosenIDs.contains(c), entity(c)?.kind == .topic { return c }
                cursor = entity(c)?.parentID
            }
            return nil
        }
        var pairCounts: [Pair: Int] = [:]
        var areaVotes: [UUID: [UUID: Int]] = [:]
        for item in library.items where asOf == nil || item.createdAt <= asOf! {
            var set = Set<UUID>()
            for e in entities(for: item.id) {
                if e.kind == .topic { if let t = visibleTopic(e.id) { set.insert(t) } } else if chosenIDs.contains(e.id) { set.insert(e.id) }
            }
            guard set.count > 1 else { continue }
            let list = set.sorted { $0.uuidString < $1.uuidString }.prefix(12)
            for (i, a) in list.enumerated() {
                for b in list.dropFirst(i + 1) { pairCounts[Pair(a, b), default: 0] += 1 }
            }
            // People and projects sit in the area of their main topic.
            if let topic = state.taxonomy.primary(of: item.id), let area = areaOf(topic) {
                for id in list where entity(id)?.kind.isExtracted == true { areaVotes[id, default: [:]][area, default: 0] += 1 }
            }
        }

        var nodes: [MapNode] = []
        for e in chosen {
            var area: UUID?
            if e.kind == .area { area = e.id } else if e.kind == .topic { area = areaOf(e.id) } else {
                area = areaVotes[e.id]?.max { ($0.value, $1.key.uuidString) < ($1.value, $0.key.uuidString) }?.key
            }
            let parent = e.kind == .topic ? e.parentID.flatMap { chosenIDs.contains($0) ? $0 : nil } : nil
            nodes.append(MapNode(id: e.id, kind: MapNodeKind(e.kind), name: e.name, size: sizes[e.id] ?? 0, areaID: area,
                                 parentID: parent, firstSeen: firstSeen[e.id], lastSeen: e.lastSeen))
        }

        // Edges: hierarchy, then the strongest shared-item links per node, then topic similarity.
        var edges: [MapEdge] = []
        for t in topics { if let p = t.parentID, chosenIDs.contains(p) { edges.append(MapEdge(a: t.id, b: p, weight: 1, kind: .hierarchy)) } }
        let hierarchy = Set(edges.map { Pair($0.a, $0.b) })
        var candidates: [(Pair, Double)] = []
        for (pair, count) in pairCounts where !hierarchy.contains(pair) {
            let w = Double(count) / (Double(max(1, sizes[pair.a] ?? 1)) * Double(max(1, sizes[pair.b] ?? 1))).squareRoot()
            candidates.append((pair, min(1, w)))
        }
        candidates.sort { ($0.1, $0.0.key) > ($1.1, $1.0.key) }
        var degree: [UUID: Int] = [:]
        let perNode = 6
        for (pair, w) in candidates where (degree[pair.a] ?? 0) < perNode || (degree[pair.b] ?? 0) < perNode {
            edges.append(MapEdge(a: pair.a, b: pair.b, weight: (w * 1000).rounded() / 1000, kind: .shared))
            degree[pair.a, default: 0] += 1
            degree[pair.b, default: 0] += 1
        }
        if asOf == nil, state.taxonomy.space.hasPrefix("vectors:") {
            let centroids = topicCentroids()
            let floor = state.taxonomy.similarityFloor ?? 0.5
            let tops = topics.filter { entity($0.parentID ?? UUID())?.kind != .topic }
            var existing = Set(edges.map { Pair($0.a, $0.b) })
            for t in tops {
                guard let c = centroids[t.id] else { continue }
                let near = tops.filter { $0.id != t.id }.compactMap { o -> (UUID, Float)? in
                    centroids[o.id].map { (o.id, VectorIndex.cosine(c.vector, $0.vector)) }
                }.filter { $0.1 >= floor }.sorted { ($0.1, $1.0.uuidString) > ($1.1, $0.0.uuidString) }.prefix(2)
                for (o, s) in near where existing.insert(Pair(t.id, o)).inserted {
                    let w = Double((s - floor) / max(0.05, 1 - floor))
                    edges.append(MapEdge(a: Pair(t.id, o).a, b: Pair(t.id, o).b, weight: (min(1, max(0.05, w)) * 1000).rounded() / 1000, kind: .similar))
                }
            }
        }
        return MapGraph(nodes: nodes, edges: edges, hiddenByKind: hidden, asOf: asOf)
    }

    /// The area above a topic (nil if none).
    func areaOf(_ topic: UUID) -> UUID? {
        var cursor: UUID? = topic
        var steps = 0
        while let c = cursor, steps < 5 {
            guard let e = entity(c) else { return nil }
            if e.kind == .area { return e.id }
            cursor = e.parentID
            steps += 1
        }
        return nil
    }
}

/// An unordered pair of ids.
struct Pair: Hashable {
    let a: UUID
    let b: UUID
    init(_ x: UUID, _ y: UUID) {
        if x.uuidString < y.uuidString { a = x; b = y } else { a = y; b = x }
    }
    var key: String { a.uuidString + b.uuidString }
}
