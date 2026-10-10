import CoreGraphics
import Foundation
import MemoryKit

// The brain screens' rules, kept apart from the views so they're easy to test: which of Memory's three
// views is showing, the words and real dates the Topics list uses, the "Docket reorganised your memory"
// line, the merge picker's filter, a living page's text with citation chips, and the map's math (palette,
// viewport, hit testing, which labels fit, the time slider).

// MARK: - Library · Topics · Map

/// Memory's three views, picked in its header and remembered.
enum MemoryMode: String, CaseIterable, Hashable {
    case library, topics, map

    var label: String {
        switch self {
        case .library: "Library"
        case .topics: "Topics"
        case .map: "Map"
        }
    }

    static let defaultsKey = "memoryMode"

    /// The view picked last time (Library the first time).
    static var saved: MemoryMode {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(MemoryMode.init(rawValue:)) ?? .library
    }

    static func save(_ mode: MemoryMode) { UserDefaults.standard.set(mode.rawValue, forKey: defaultsKey) }
}

/// What the Topics view lists: the taxonomy, or people, organisations or projects (in the lens's words).
enum BrainListKind: String, CaseIterable, Hashable {
    case topics, people, organisations, projects

    var entityKind: EntityKind {
        switch self {
        case .topics: .topic
        case .people: .person
        case .organisations: .organisation
        case .projects: .project
        }
    }

    func label(_ vocabulary: LensVocabulary) -> String { entityKind.pluralLabel(vocabulary) }
}

// MARK: - Words

enum BrainText {
    /// "1 memory", "12 memories".
    static func memories(_ n: Int) -> String { MemoryText.count(n) }

    /// "1 sub-topic", "2 sub-topics".
    static func subTopics(_ n: Int) -> String { n == 1 ? "1 sub-topic" : "\(n) sub-topics" }

    /// The Unsorted bucket: "12 not sorted yet".
    static func unsorted(_ n: Int) -> String { "\(n) not sorted yet" }

    /// "Topic · 4 memories · 2 sub-topics", in the lens's words ("Deal · 3 memories").
    static func meta(_ e: BrainEntity, subTopics: Int, vocabulary: LensVocabulary) -> String {
        var parts = [e.kind.label(vocabulary), memories(e.itemCount)]
        if subTopics > 0 { parts.append(self.subTopics(subTopics)) }
        return parts.joined(separator: " · ")
    }

    /// "First Tue 22 Sep · last Thu 8 Oct" (one date when they're the same day). Real dates only.
    static func seen(first: Date?, last: Date?, now: Date = Date(), calendar: Calendar = .current) -> String? {
        guard let first else { return last.map { "Last \(MemoryText.date($0, now: now))" } }
        guard let last, !calendar.isDate(first, inSameDayAs: last) else { return "Seen \(MemoryText.date(first, now: now))" }
        return "First \(MemoryText.date(first, now: now)) · last \(MemoryText.date(last, now: now))"
    }

    /// The other spellings, for a person's row: "also Priya, P. Shah".
    static func aliases(_ e: BrainEntity, limit: Int = 3) -> String? {
        let others = e.aliases.filter { $0.caseInsensitiveCompare(e.name) != .orderedSame }
        guard !others.isEmpty else { return nil }
        let shown = others.prefix(limit).joined(separator: ", ")
        return "also " + shown + (others.count > limit ? " +\(others.count - limit)" : "")
    }

    /// The digest card's one line: "What you learned · 5–11 Oct".
    static func digestTitle(_ d: BrainDigest, now: Date = Date()) -> String {
        "What you learned · " + BrainInsights.weekRange(start: d.weekStart, end: d.weekEnd, now: now)
    }

    /// Under it, collapsed: "9 memories · 2 new topics · 3 decisions".
    static func digestLine(_ d: BrainDigest, vocabulary: LensVocabulary) -> String {
        var parts = [memories(d.itemCount)]
        if !d.newTopics.isEmpty { parts.append(d.newTopics.count == 1 ? "1 new topic" : "\(d.newTopics.count) new topics") }
        if !d.decisions.isEmpty { parts.append("\(d.decisions.count) \(vocabulary.decisions.lowercased())") }
        if !d.openPromises.isEmpty { parts.append("\(d.openPromises.count) open \(vocabulary.promises.lowercased())") }
        return parts.joined(separator: " · ")
    }

    /// "3 connections you haven't made" (or one).
    static func connections(_ n: Int) -> String { n == 1 ? "A connection you haven't made" : "\(n) connections you haven't made" }

    /// A page without a key: one line on what a key would add.
    static func noKeyHint(_ e: BrainEntity) -> String {
        "Add a Gemini key in Settings → AI and Docket writes what you know about \(e.name)."
    }

    /// A living page's "What you know": [n] as citation chips (only numbers with a source), **bold** kept,
    /// "- " bullets as "•". The segments are `CitationText`'s, so Ask and pages cut text the same way.
    static func summarySegments(_ text: String, sources: Int) -> [CitationText.Segment] {
        let bulleted = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") { return "•\u{2002}" + trimmed.dropFirst(2) }
            return String(line)
        }.joined(separator: "\n")
        return CitationText.segments(bulleted, valid: sources > 0 ? 1...sources : nil)
    }

    /// One text piece with **bold** (and other inline markdown) applied; plain text when it doesn't parse.
    static func inline(_ s: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: s, options: options)) ?? AttributedString(s)
    }
}

// MARK: - "Docket reorganised your memory"

/// The one-line banner over Topics: what automation changed since the user last looked (their own corrections
/// don't count), e.g. "Docket reorganised your memory: 2 new topics, 1 merged".
enum BrainBanner {
    static let seenKey = "brainChangesSeen"

    /// With nothing seen yet, changes of the last week count.
    static let firstLookWindow: TimeInterval = 7 * 86_400

    /// The banner's text and the newest change it covers (to store as seen on dismiss); nil when there's nothing new.
    static func line(_ changes: [BrainChange], since seen: Date?, now: Date = Date()) -> (text: String, newest: Date)? {
        let cutoff = seen ?? now.addingTimeInterval(-firstLookWindow)
        let fresh = changes.filter { $0.kind != .correction && $0.date > cutoff }
        guard let newest = fresh.map(\.date).max() else { return nil }
        var newTopics = 0, merged = 0, renamed = 0, moved = 0, retired = 0
        var firstTime: String?
        for change in fresh {
            if change.kind == .resolved {
                merged += max(1, change.details.count)
                continue
            }
            if change.details.isEmpty, change.summary.hasPrefix("Organised ") { firstTime = change.summary }
            for line in change.details {
                let l = line.lowercased()
                if let n = Int(l.prefix { $0.isNumber }), l.contains("new topic") { newTopics += n }
                else if l.hasPrefix("merged ") { merged += 1 }
                else if l.hasPrefix("renamed ") { renamed += 1 }
                else if l.hasPrefix("moved ") { moved += 1 }
                else if l.hasPrefix("retired ") && !l.hasPrefix("retired area") { retired += 1 }
            }
        }
        var parts: [String] = []
        if newTopics > 0 { parts.append(newTopics == 1 ? "1 new topic" : "\(newTopics) new topics") }
        if merged > 0 { parts.append("\(merged) merged") }
        if renamed > 0 { parts.append("\(renamed) renamed") }
        if moved > 0 { parts.append("\(moved) moved") }
        if retired > 0 { parts.append("\(retired) retired") }
        if parts.isEmpty {
            guard let firstTime else { return nil }
            return ("Docket organised your memory: " + firstTime.dropFirst("Organised ".count), newest)
        }
        return ("Docket reorganised your memory: " + parts.joined(separator: ", "), newest)
    }

    static var seen: Date? {
        let t = UserDefaults.standard.double(forKey: seenKey)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    static func markSeen(_ date: Date) { UserDefaults.standard.set(date.timeIntervalSince1970, forKey: seenKey) }
}

// MARK: - Picking an entity

/// The merge picker (and ⌘K): entities whose name or any spelling contains the query, case and accents
/// ignored; names that start with it first, then the biggest.
enum EntityPicker {
    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func filter(_ entities: [BrainEntity], query: String, kind: EntityKind? = nil, excluding: Set<UUID> = [],
                       limit: Int = 60) -> [BrainEntity] {
        let q = fold(query)
        var scored: [(BrainEntity, Int)] = []
        for e in entities where !excluding.contains(e.id) && (kind == nil || e.kind == kind) {
            guard !q.isEmpty else { scored.append((e, 2)); continue }
            let name = fold(e.name)
            if name.hasPrefix(q) { scored.append((e, 0)); continue }
            let words = name.split(separator: " ")
            if words.contains(where: { $0.hasPrefix(q) }) || name.contains(q) { scored.append((e, 1)); continue }
            if e.aliases.contains(where: { fold($0).contains(q) }) { scored.append((e, 2)) }
        }
        return scored.sorted { a, b in
            if a.1 != b.1 { return a.1 < b.1 }
            if a.0.itemCount != b.0.itemCount { return a.0.itemCount > b.0.itemCount }
            return a.0.name.localizedCaseInsensitiveCompare(b.0.name) == .orderedAscending
        }.prefix(limit).map(\.0)
    }

    /// ⌘K: "go to pricing" finds Pricing too.
    static func paletteQuery(_ typed: String) -> String {
        let t = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["go to ", "open "] where t.lowercased().hasPrefix(prefix) { return String(t.dropFirst(prefix.count)) }
        return t
    }
}

// MARK: - Map: colours

/// Areas get colours from a muted categorical palette that sits on paper in light and dark. Each area keeps its
/// colour as others come and go: it starts at a slot from a stable hash of its id and takes the next free one
/// (areas are visited in id order, so the input order doesn't matter).
enum BrainPalette {
    /// Dusty blue, terracotta, sage, lavender, ochre, teal, plum, olive.
    static let light: [UInt32] = [0x5F83AB, 0xB57A62, 0x6E9874, 0x9C80B0, 0xB8954A, 0x5E9A96, 0x9A5F86, 0x878760]
    static let dark: [UInt32] = [0x8EA9CB, 0xD49C84, 0x94BD99, 0xC0A6D3, 0xD8B872, 0x87C1BC, 0xC98AB4, 0xB0B086]

    static var count: Int { light.count }

    static func slots(for areas: [UUID]) -> [UUID: Int] {
        var taken = Set<Int>()
        var out: [UUID: Int] = [:]
        for id in Set(areas).sorted(by: { $0.uuidString < $1.uuidString }) {
            var slot = Int(stableHash(id.uuidString).unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } % count)
            if taken.count < count {
                while taken.contains(slot) { slot = (slot + 1) % count }
            }
            taken.insert(slot)
            out[id] = slot
        }
        return out
    }

    static func hex(slot: Int, dark: Bool) -> UInt32 { (dark ? self.dark : light)[((slot % count) + count) % count] }
}

// MARK: - Map: viewport

/// Where the map's layout units land on screen: screen = world × scale + offset.
struct MapViewport: Equatable {
    var scale: Double = 40
    var offset: CGPoint = .zero

    func toScreen(_ p: MapPoint) -> CGPoint { CGPoint(x: p.x * scale + offset.x, y: p.y * scale + offset.y) }

    func toWorld(_ p: CGPoint) -> MapPoint { MapPoint(x: (p.x - offset.x) / scale, y: (p.y - offset.y) / scale) }

    /// The whole graph in `size` with `padding` around it, leaving `top` and `bottom` free for controls (a lone
    /// node sits in the middle at `maxScale`).
    static func fit(_ b: (minX: Double, minY: Double, maxX: Double, maxY: Double), in size: CGSize, padding: CGFloat = 56,
                    top: CGFloat = 0, bottom: CGFloat = 0, maxScale: Double = 140) -> MapViewport {
        let w = max(1, Double(size.width - padding * 2)), h = max(1, Double(size.height - padding * 2 - top - bottom))
        let bw = max(b.maxX - b.minX, 0.0001), bh = max(b.maxY - b.minY, 0.0001)
        let scale = min(maxScale, min(w / bw, h / bh))
        let cx = (b.minX + b.maxX) / 2, cy = (b.minY + b.maxY) / 2
        let midY = Double(top) + (Double(size.height - top - bottom)) / 2
        return MapViewport(scale: scale, offset: CGPoint(x: Double(size.width) / 2 - cx * scale, y: midY - cy * scale))
    }

    /// Zoomed by `factor` about a screen point (the point under the pointer stays put), within `range`.
    func zoomed(by factor: Double, about anchor: CGPoint, range: ClosedRange<Double>) -> MapViewport {
        let next = min(range.upperBound, max(range.lowerBound, scale * factor))
        let world = toWorld(anchor)
        return MapViewport(scale: next, offset: CGPoint(x: anchor.x - world.x * next, y: anchor.y - world.y * next))
    }

    func panned(by d: CGSize) -> MapViewport { MapViewport(scale: scale, offset: CGPoint(x: offset.x + d.width, y: offset.y + d.height)) }

    /// Between two viewports, for the gentle animation (scale eases geometrically so zooming feels even).
    static func interpolate(_ a: MapViewport, _ b: MapViewport, _ t: Double) -> MapViewport {
        let s = a.scale * pow(b.scale / a.scale, t)
        return MapViewport(scale: s, offset: CGPoint(x: a.offset.x + (b.offset.x - a.offset.x) * t,
                                                     y: a.offset.y + (b.offset.y - a.offset.y) * t))
    }
}

// MARK: - Map: nodes on screen

enum MapGeometry {
    /// A node's radius in points: √size, by kind, a little bigger as you zoom in (`zoom` = scale ÷ the fitted scale).
    static func radius(kind: MapNodeKind, size: Int, zoom: Double) -> CGFloat {
        let s = Double(max(1, size)).squareRoot()
        let base: Double
        switch kind {
        case .area: base = 7 + 2.4 * s
        case .topic: base = 4 + 2.6 * s
        case .item: base = 3
        default: base = 3 + 1.8 * s
        }
        let z = min(2.2, max(0.6, zoom.squareRoot()))
        return CGFloat(min(base, 34) * z)
    }

    /// The node under `point` (within its radius plus `slop`), the closest edge-to-pointer first.
    static func hit(_ point: CGPoint, nodes: [(id: UUID, center: CGPoint, radius: CGFloat)], slop: CGFloat = 4) -> UUID? {
        var best: (UUID, CGFloat)?
        for n in nodes {
            let d = hypot(n.center.x - point.x, n.center.y - point.y)
            guard d <= n.radius + slop else { continue }
            let score = d - n.radius
            if best == nil || score < best!.1 { best = (n.id, score) }
        }
        return best?.0
    }
}

/// Which labels fit: the most important first (areas, then biggest), each placed under its node, skipped
/// when it would overlap one already placed or leave the view; at most `limit`. Zooming in spreads the nodes,
/// so more labels fit by themselves.
enum MapLabels {
    struct Candidate {
        var id: UUID
        var center: CGPoint
        var radius: CGFloat
        /// Estimated text width and height in points.
        var size: CGSize
        var priority: Double
    }

    /// The label's box: centred under the node.
    static func rect(_ c: Candidate) -> CGRect {
        CGRect(x: c.center.x - c.size.width / 2, y: c.center.y + c.radius + 3, width: c.size.width, height: c.size.height)
    }

    /// A rough width for a label (no text layout in the hot path).
    static func estimatedWidth(_ text: String, fontSize: CGFloat) -> CGFloat { CGFloat(min(text.count, 28)) * fontSize * 0.56 + 4 }

    /// How many labels a view this big can carry.
    static func limit(for size: CGSize, zoom: Double) -> Int {
        Int(min(400, max(8, Double(size.width * size.height) / 9000 * max(1, zoom))))
    }

    static func visible(_ candidates: [Candidate], in bounds: CGRect, always: Set<UUID> = [], limit: Int) -> Set<UUID> {
        var placed: [CGRect] = []
        var out = Set<UUID>()
        let ordered = candidates.sorted { a, b in
            let aa = always.contains(a.id), bb = always.contains(b.id)
            if aa != bb { return aa }
            return a.priority != b.priority ? a.priority > b.priority : a.id.uuidString < b.id.uuidString
        }
        for c in ordered {
            let forced = always.contains(c.id)
            guard forced || out.count < limit else { continue }
            let r = rect(c)
            guard forced || bounds.contains(r) else { continue }
            let padded = r.insetBy(dx: -3, dy: -2)
            if !forced && placed.contains(where: { $0.intersects(padded) }) { continue }
            placed.append(r)
            out.insert(c.id)
        }
        return out
    }
}

// MARK: - Map: filters and time

enum MapFilter {
    /// The kinds the chips switch (areas always show).
    static let switchable: [MapNodeKind] = [.topic, .person, .organisation, .project]

    static func label(_ kind: MapNodeKind, _ vocabulary: LensVocabulary) -> String {
        switch kind {
        case .topic: EntityKind.topic.pluralLabel(vocabulary)
        case .person: EntityKind.person.pluralLabel(vocabulary)
        case .organisation: EntityKind.organisation.pluralLabel(vocabulary)
        case .project: EntityKind.project.pluralLabel(vocabulary)
        case .area: EntityKind.area.pluralLabel(vocabulary)
        case .item: "Memories"
        }
    }

    /// Nodes of the shown kinds (and areas, and the focus), with the edges between them.
    static func apply(_ graph: MapGraph, kinds: Set<MapNodeKind>) -> MapGraph {
        var g = graph
        g.nodes = graph.nodes.filter { $0.kind == .area || $0.kind == .item || kinds.contains($0.kind) || $0.id == graph.focus }
        let keep = Set(g.nodes.map(\.id))
        g.edges = graph.edges.filter { keep.contains($0.a) && keep.contains($0.b) }
        return g
    }

    /// "+ 42 more": entities of the shown kinds left out by the node cap.
    static func hiddenCount(_ graph: MapGraph, kinds: Set<MapNodeKind>) -> Int {
        kinds.reduce(0) { $0 + (graph.hiddenByKind[$1.rawValue] ?? 0) }
    }
}

/// The time slider: from the first memory to now. The right end means "now" (no cut-off); anywhere else is the
/// end of that day.
enum MapTime {
    static func fraction(of date: Date?, first: Date, now: Date) -> Double {
        guard let date, now > first else { return 1 }
        return min(1, max(0, date.timeIntervalSince(first) / now.timeIntervalSince(first)))
    }

    static func date(at fraction: Double, first: Date, now: Date, calendar: Calendar = .current) -> Date? {
        guard fraction < 0.999, now > first else { return nil }
        let raw = first.addingTimeInterval(now.timeIntervalSince(first) * max(0, fraction))
        let end = calendar.endOfDay(for: raw)
        return end >= now ? nil : end
    }
}

/// The map's gentle spring (critically damped): 0 → 1 over about half a second.
enum MapMotion {
    static let duration: TimeInterval = 0.55

    static func spring(_ t: TimeInterval) -> Double {
        guard t > 0 else { return 0 }
        guard t < duration else { return 1 }
        let w = 11.0
        return 1 - (1 + w * t) * exp(-w * t)
    }
}
