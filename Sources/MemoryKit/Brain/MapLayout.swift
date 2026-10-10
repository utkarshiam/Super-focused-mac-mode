import Foundation

// MARK: - Graph

/// What a node on the mental map is.
public enum MapNodeKind: String, Codable, CaseIterable, Sendable {
    case area, topic, person, organisation, project, item

    public init(_ kind: EntityKind) {
        switch kind {
        case .area: self = .area
        case .topic: self = .topic
        case .person: self = .person
        case .organisation: self = .organisation
        case .project: self = .project
        }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MapNodeKind(rawValue: raw) ?? .topic
    }
}

/// One node: an entity (or, in a focused view with items, an item).
public struct MapNode: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var kind: MapNodeKind
    public var name: String
    /// Items behind it (as of the graph's date). Draw the radius ∝ √size.
    public var size: Int
    /// The area it sits in (topics through their parents; others through their main topic), if any.
    public var areaID: UUID?
    /// A topic's parent (area or topic).
    public var parentID: UUID?
    public var position: MapPoint
    public var firstSeen: Date?
    public var lastSeen: Date?

    public init(id: UUID, kind: MapNodeKind, name: String, size: Int, areaID: UUID? = nil, parentID: UUID? = nil,
                position: MapPoint = .zero, firstSeen: Date? = nil, lastSeen: Date? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.size = size
        self.areaID = areaID
        self.parentID = parentID
        self.position = position
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
    }

    private enum CodingKeys: String, CodingKey { case id, kind, name, size, areaID, parentID, position, firstSeen, lastSeen }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, default: UUID())
        kind = c.value(.kind, default: .topic)
        name = c.value(.name, default: "")
        size = c.value(.size, default: 0)
        areaID = c.value(.areaID, default: nil)
        parentID = c.value(.parentID, default: nil)
        position = c.value(.position, default: .zero)
        firstSeen = c.value(.firstSeen, default: nil)
        lastSeen = c.value(.lastSeen, default: nil)
    }
}

/// A link between two nodes.
public struct MapEdge: Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Topic → its area or parent topic.
        case hierarchy
        /// The two share items (co-membership).
        case shared
        /// Two topics close in meaning.
        case similar
        /// An item in a focused view → its entity.
        case item

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .shared
        }
    }

    public var a: UUID
    public var b: UUID
    /// 0…1; draw thicker for stronger.
    public var weight: Double
    public var kind: Kind

    public init(a: UUID, b: UUID, weight: Double, kind: Kind) {
        self.a = a
        self.b = b
        self.weight = weight
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey { case a, b, weight, kind }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        a = c.value(.a, default: UUID())
        b = c.value(.b, default: UUID())
        weight = c.value(.weight, default: 0)
        kind = c.value(.kind, default: .shared)
    }
}

/// The mental map: nodes with positions and weighted edges. Positions are in layout units around (0, 0);
/// scale `bounds` to the view. Nodes beyond the cap are left out and counted in `hiddenByKind` ("+ 42 more
/// people").
public struct MapGraph: Hashable, Codable, Sendable {
    public var nodes: [MapNode]
    public var edges: [MapEdge]
    /// Kind raw value → how many entities of that kind were left out by the node cap.
    public var hiddenByKind: [String: Int]
    /// The date the graph shows (nil = now).
    public var asOf: Date?
    /// The node the graph is focused on, if any.
    public var focus: UUID?

    public init(nodes: [MapNode] = [], edges: [MapEdge] = [], hiddenByKind: [String: Int] = [:], asOf: Date? = nil, focus: UUID? = nil) {
        self.nodes = nodes
        self.edges = edges
        self.hiddenByKind = hiddenByKind
        self.asOf = asOf
        self.focus = focus
    }

    private enum CodingKeys: String, CodingKey { case nodes, edges, hiddenByKind, asOf, focus }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nodes = c.value(.nodes, default: [])
        edges = c.value(.edges, default: [])
        hiddenByKind = c.value(.hiddenByKind, default: [:])
        asOf = c.value(.asOf, default: nil)
        focus = c.value(.focus, default: nil)
    }

    public var isEmpty: Bool { nodes.isEmpty }
    /// Entities left out by the cap.
    public var hiddenCount: Int { hiddenByKind.values.reduce(0, +) }

    public func node(_ id: UUID) -> MapNode? { nodes.first { $0.id == id } }

    /// The smallest rectangle holding every node position: (minX, minY, maxX, maxY).
    public var bounds: (minX: Double, minY: Double, maxX: Double, maxY: Double) {
        guard let first = nodes.first else { return (0, 0, 0, 0) }
        var b = (minX: first.position.x, minY: first.position.y, maxX: first.position.x, maxY: first.position.y)
        for n in nodes {
            b.minX = min(b.minX, n.position.x); b.maxX = max(b.maxX, n.position.x)
            b.minY = min(b.minY, n.position.y); b.maxY = max(b.maxY, n.position.y)
        }
        return b
    }

    /// Ids within `hops` edges of `id` (including it).
    public func neighbourhood(of id: UUID, hops: Int) -> Set<UUID> {
        var adjacency: [UUID: [UUID]] = [:]
        for e in edges {
            adjacency[e.a, default: []].append(e.b)
            adjacency[e.b, default: []].append(e.a)
        }
        var seen: Set<UUID> = [id]
        var frontier: [UUID] = [id]
        for _ in 0..<max(0, hops) {
            var next: [UUID] = []
            for n in frontier { for m in adjacency[n] ?? [] where seen.insert(m).inserted { next.append(m) } }
            frontier = next
        }
        return seen
    }

    /// The part of the graph within `hops` of `id`, positions unchanged (so focusing doesn't move anything).
    public func focused(on id: UUID, hops: Int) -> MapGraph {
        guard nodes.contains(where: { $0.id == id }) else { return self }
        let keep = neighbourhood(of: id, hops: hops)
        var g = self
        g.nodes = nodes.filter { keep.contains($0.id) }
        g.edges = edges.filter { keep.contains($0.a) && keep.contains($0.b) }
        g.focus = id
        return g
    }

    /// Nodes first seen on or before `date`, with the edges between them; positions unchanged. (Sizes stay as
    /// they are: the phone uses this on the published graph; the Mac's `MemoryBrain.map(asOf:)` recounts.)
    public func filtered(asOf date: Date) -> MapGraph {
        var g = self
        g.nodes = nodes.filter { ($0.firstSeen ?? .distantPast) <= date }
        let keep = Set(g.nodes.map(\.id))
        g.edges = edges.filter { keep.contains($0.a) && keep.contains($0.b) }
        g.asOf = date
        return g
    }
}

// MARK: - Layout

/// Deterministic, seeded force-directed layout (Fruchterman–Reingold with a grid for repulsion, so it stays
/// near O(n) per step), anchored on areas: areas sit on a ring and stay put, topics are pulled towards their
/// area (sub-topics towards their topic), everything else settles between what it shares items with. Node
/// mass grows with size, so big nodes push harder.
///
/// Incremental: pass the previous positions and nodes that had one start there; new nodes start next to
/// their neighbours, and fewer, cooler iterations run, so the map doesn't jump. The same input always gives
/// the same output (no randomness beyond a seed and stable hashes of ids).
public struct MapLayout: Sendable {
    public struct Node: Sendable {
        public var id: UUID
        public var kind: MapNodeKind
        public var size: Int
        public var areaID: UUID?
        public var parentID: UUID?

        public init(id: UUID, kind: MapNodeKind, size: Int, areaID: UUID? = nil, parentID: UUID? = nil) {
            self.id = id
            self.kind = kind
            self.size = size
            self.areaID = areaID
            self.parentID = parentID
        }
    }

    /// Steps from scratch, and when most nodes have previous positions.
    public var iterations = 300
    public var warmIterations = 80
    /// The ideal edge length (layout units).
    public var idealLength = 1.0
    public var seed: UInt64 = 0x5EED_0DC
    /// Pull towards the area anchor (topics) and for everything else.
    public var topicAnchor = 0.14
    public var otherAnchor = 0.02

    public init() {}

    /// Positions for `nodes`, keyed by id.
    public func layout(_ nodes: [Node], edges: [MapEdge], previous: [UUID: MapPoint] = [:]) -> [UUID: MapPoint] {
        let n = nodes.count
        guard n > 0 else { return [:] }
        let order = nodes.indices.sorted { nodes[$0].id.uuidString < nodes[$1].id.uuidString }
        let sorted = order.map { nodes[$0] }
        var index: [UUID: Int] = [:]
        for (i, node) in sorted.enumerated() { index[node.id] = i }
        let k = idealLength
        let ring = max(3, Double(n).squareRoot() * 0.9) * k
        let mass = sorted.map { 1 + log(1 + Double(max(0, $0.size))) }

        var x = [Double](repeating: 0, count: n), y = [Double](repeating: 0, count: n)
        var placed = [Bool](repeating: false, count: n)
        var known = 0
        for (i, node) in sorted.enumerated() {
            if let p = previous[node.id] { x[i] = p.x; y[i] = p.y; placed[i] = true; known += 1 }
        }
        func jitter(_ id: UUID, _ radius: Double) -> (Double, Double) {
            var rng = SeedRandom(seed: seed ^ BrainIDs.hash(id.uuidString))
            let angle = rng.nextUnit() * 2 * .pi, r = radius * (0.3 + 0.7 * rng.nextUnit())
            return (cos(angle) * r, sin(angle) * r)
        }

        // Areas: on a ring; new ones go into the widest gap between areas already placed.
        let areaIdx = (0..<n).filter { sorted[$0].kind == .area }
            .sorted { (sorted[$0].size, sorted[$1].id.uuidString) > (sorted[$1].size, sorted[$0].id.uuidString) }
        let placedAreas = areaIdx.filter { placed[$0] }
        if placedAreas.isEmpty {
            for (j, i) in areaIdx.enumerated() {
                let angle = 2 * Double.pi * Double(j) / Double(max(1, areaIdx.count)) - .pi / 2
                x[i] = cos(angle) * ring; y[i] = sin(angle) * ring; placed[i] = true
            }
        } else {
            var angles = placedAreas.map { atan2(y[$0], x[$0]) }
            for i in areaIdx where !placed[i] {
                let sortedAngles = angles.sorted()
                var gapStart = sortedAngles.last! - 2 * .pi, best = 0.0, at = 0.0
                for a in sortedAngles {
                    if a - gapStart > best { best = a - gapStart; at = gapStart + best / 2 }
                    gapStart = a
                }
                let radius = placedAreas.map { (x[$0] * x[$0] + y[$0] * y[$0]).squareRoot() }.max() ?? ring
                x[i] = cos(at) * radius; y[i] = sin(at) * radius; placed[i] = true
                angles.append(at)
            }
        }
        // Topics near their parent, parents first.
        let topicIdx = (0..<n).filter { sorted[$0].kind == .topic }
            .sorted { (depthKey(sorted[$0], index, sorted), sorted[$0].id.uuidString) < (depthKey(sorted[$1], index, sorted), sorted[$1].id.uuidString) }
        for i in topicIdx where !placed[i] {
            let anchor = sorted[i].parentID.flatMap { index[$0] }.flatMap { placed[$0] ? $0 : nil }
            let (jx, jy) = jitter(sorted[i].id, anchor == nil ? ring * 0.5 : k * 1.2)
            x[i] = (anchor.map { x[$0] } ?? 0) + jx
            y[i] = (anchor.map { y[$0] } ?? 0) + jy
            placed[i] = true
        }
        // Edges as index pairs in a canonical order, so the result doesn't depend on the input's order.
        var pairs: [(a: Int, b: Int, w: Double)] = []
        pairs.reserveCapacity(edges.count)
        for e in edges {
            guard let a = index[e.a], let b = index[e.b], a != b else { continue }
            pairs.append((min(a, b), max(a, b), e.weight))
        }
        pairs.sort { ($0.a, $0.b, $0.w) < ($1.a, $1.b, $1.w) }
        // Everything else between its placed neighbours.
        var adjacency = [[(Int, Double)]](repeating: [], count: n)
        for p in pairs {
            adjacency[p.a].append((p.b, p.w))
            adjacency[p.b].append((p.a, p.w))
        }
        for i in 0..<n where !placed[i] {
            var sx = 0.0, sy = 0.0, w = 0.0
            for (j, weight) in adjacency[i] where placed[j] { sx += x[j] * weight; sy += y[j] * weight; w += weight }
            let (jx, jy) = jitter(sorted[i].id, w > 0 ? k : ring * 0.6)
            x[i] = (w > 0 ? sx / w : 0) + jx
            y[i] = (w > 0 ? sy / w : 0) + jy
            placed[i] = true
        }

        // Anchors: the area (or parent topic) each node is pulled towards (-1: none).
        let anchor: [Int] = sorted.map { node in
            if node.kind == .area { return -1 }
            if node.kind == .topic, let p = node.parentID, let pi = index[p] { return pi }
            return node.areaID.flatMap { index[$0] } ?? -1
        }
        let pinned = sorted.map { $0.kind == .area }
        let anchorStrength = sorted.map { $0.kind == .topic ? topicAnchor * 10 : otherAnchor * 10 }
        let edgeA = pairs.map(\.a), edgeB = pairs.map(\.b), edgeW = pairs.map { max(0.05, $0.w) }

        let warm = Double(known) >= 0.5 * Double(n)
        let steps = warm ? warmIterations : iterations
        let t0 = warm ? 0.35 * k : ring * 0.25
        let cell = 3 * k
        let cutoff2 = cell * cell
        var dx = [Double](repeating: 0, count: n), dy = [Double](repeating: 0, count: n)
        var cellOf = [Int](repeating: 0, count: n)
        var cellStart: [Int] = []
        var cellNodes = [Int](repeating: 0, count: n)
        // Tiny fixed nudges for nodes exactly on top of each other.
        let nudge: [(Double, Double)] = sorted.map { jitter($0.id, 0.01) }

        x.withUnsafeMutableBufferPointer { X in
        y.withUnsafeMutableBufferPointer { Y in
        dx.withUnsafeMutableBufferPointer { DX in
        dy.withUnsafeMutableBufferPointer { DY in
            for step in 0..<steps {
                for i in 0..<n { DX[i] = 0; DY[i] = 0 }
                // Grid: counting sort of nodes into cells of size `cell` over the current bounds.
                var minX = X[0], minY = Y[0], maxX = X[0], maxY = Y[0]
                for i in 1..<max(1, n) {
                    minX = Swift.min(minX, X[i]); maxX = Swift.max(maxX, X[i])
                    minY = Swift.min(minY, Y[i]); maxY = Swift.max(maxY, Y[i])
                }
                let w = Swift.max(1, Swift.min(4096, Int((maxX - minX) / cell) + 1))
                let h = Swift.max(1, Swift.min(4096, Int((maxY - minY) / cell) + 1))
                cellStart = [Int](repeating: 0, count: w * h + 1)
                for i in 0..<n {
                    let cx = Swift.min(w - 1, Int((X[i] - minX) / cell)), cy = Swift.min(h - 1, Int((Y[i] - minY) / cell))
                    cellOf[i] = cy * w + cx
                    cellStart[cellOf[i] + 1] += 1
                }
                for c in 0..<(w * h) { cellStart[c + 1] += cellStart[c] }
                var fill = cellStart
                for i in 0..<n { cellNodes[fill[cellOf[i]]] = i; fill[cellOf[i]] += 1 }

                // Repulsion within neighbouring cells (each pair once).
                for i in 0..<n {
                    let cx = cellOf[i] % w, cy = cellOf[i] / w
                    let xi = X[i], yi = Y[i], mi = mass[i]
                    for oy in Swift.max(0, cy - 1)...Swift.min(h - 1, cy + 1) {
                        for ox in Swift.max(0, cx - 1)...Swift.min(w - 1, cx + 1) {
                            let c = oy * w + ox
                            for slot in cellStart[c]..<cellStart[c + 1] {
                                let j = cellNodes[slot]
                                guard j > i else { continue }
                                var ddx = xi - X[j], ddy = yi - Y[j]
                                var d2 = ddx * ddx + ddy * ddy
                                if d2 > cutoff2 { continue }
                                if d2 < 1e-6 { (ddx, ddy) = nudge[j]; d2 = ddx * ddx + ddy * ddy }
                                let f = k * k * (mi * mass[j]).squareRoot() / d2
                                DX[i] += ddx * f; DY[i] += ddy * f
                                DX[j] -= ddx * f; DY[j] -= ddy * f
                            }
                        }
                    }
                }
                // Attraction along edges (|F| = d² / k × weight).
                for e in 0..<edgeA.count {
                    let a = edgeA[e], b = edgeB[e]
                    let ddx = X[a] - X[b], ddy = Y[a] - Y[b]
                    let d = (ddx * ddx + ddy * ddy).squareRoot()
                    guard d > 1e-9 else { continue }
                    let f = d / k * edgeW[e]
                    DX[a] -= ddx * f / mass[a]; DY[a] -= ddy * f / mass[a]
                    DX[b] += ddx * f / mass[b]; DY[b] += ddy * f / mass[b]
                }
                // Anchors, and a weak pull to the centre for the unanchored.
                for i in 0..<n where !pinned[i] {
                    let a = anchor[i]
                    if a >= 0 {
                        DX[i] += (X[a] - X[i]) * anchorStrength[i]
                        DY[i] += (Y[a] - Y[i]) * anchorStrength[i]
                    } else {
                        DX[i] -= X[i] * 0.1
                        DY[i] -= Y[i] * 0.1
                    }
                }
                // Move, limited by the temperature.
                let t = t0 * (1 - Double(step) / Double(steps)) + 0.01 * k
                for i in 0..<n where !pinned[i] {
                    let d = (DX[i] * DX[i] + DY[i] * DY[i]).squareRoot()
                    guard d > 1e-12 else { continue }
                    let s = Swift.min(d, t) / d
                    X[i] += DX[i] * s
                    Y[i] += DY[i] * s
                }
            }
        }
        }
        }
        }
        var out: [UUID: MapPoint] = [:]
        for i in 0..<n {
            // Rounded so the cache and snapshots stay small and comparisons stable.
            out[sorted[i].id] = MapPoint(x: (x[i] * 1000).rounded() / 1000, y: (y[i] * 1000).rounded() / 1000)
        }
        return out
    }

    /// 0 for a top-level topic, 1 for a sub-topic (parents are placed first).
    private func depthKey(_ node: Node, _ index: [UUID: Int], _ nodes: [Node]) -> Int {
        guard let p = node.parentID, let pi = index[p] else { return 0 }
        return nodes[pi].kind == .topic ? 1 : 0
    }

    /// A key for a node set (cache invalidation).
    public static func key(for ids: [UUID]) -> String {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        for id in ids.map(\.uuidString).sorted() { for b in id.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01B3 } }
        return String(h, radix: 16) + "-\(ids.count)"
    }
}
