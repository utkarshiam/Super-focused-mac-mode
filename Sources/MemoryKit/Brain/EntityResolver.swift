import Foundation

/// "One name per thing": turns the people / projects / organisations strings on items into canonical
/// entities. Pure and deterministic: the same items, previous entities and corrections always give the
/// same result, and entity ids stay stable across runs (a group keeps the id of the previous entity it
/// overlaps most).
///
/// Rules, in order (never across kinds; a do-not-merge pair always wins):
/// 1. Same key (`EntityNames.key`: case, accents, punctuation, titles, legal suffixes, plurals).
/// 2. User merges (`forced` aliases) and spellings already merged into one entity before.
/// 3. People: same first and last name ("Rohan K. Mehta" = "Rohan Mehta"); initials that match exactly one
///    full name ("R. Mehta", "Rohan M."); a first name alone ("Rohan", "Rohan ji") when exactly one full
///    name starts with it and they co-occur (an item, or a person/project/organisation mentioned with both).
/// 4. Pairs AI confirmed earlier (`decisions`).
/// 5. A lone first name without co-occurrence merges when the two groups' items are similar in meaning
///    (`similarity` ≥ `contextMergeSimilarity`); otherwise it becomes a candidate for AI confirmation, as do
///    near-identical spellings (typos), name prefixes ("Mehta" / "Mehta Traders") and acronyms.
public struct EntityResolver: Sendable {
    /// One name on one item.
    public struct Mention: Hashable, Sendable {
        public var kind: EntityKind
        public var name: String
        public var itemID: UUID
        public var date: Date

        public init(kind: EntityKind, name: String, itemID: UUID, date: Date) {
            self.kind = kind
            self.name = name
            self.itemID = itemID
            self.date = date
        }
    }

    /// An entity as it was before this run (for stable ids, locked names and earlier merges).
    public struct Existing: Sendable {
        public var id: UUID
        public var kind: EntityKind
        public var name: String
        public var aliases: [String]
        public var nameLocked: Bool

        public init(id: UUID, kind: EntityKind, name: String, aliases: [String], nameLocked: Bool = false) {
            self.id = id
            self.kind = kind
            self.name = name
            self.aliases = aliases
            self.nameLocked = nameLocked
        }
    }

    /// A user merge: this spelling belongs to this entity.
    public struct ForcedAlias: Hashable, Codable, Sendable {
        public var entityID: UUID
        public var spelling: String

        public init(entityID: UUID, spelling: String) {
            self.entityID = entityID
            self.spelling = spelling
        }
    }

    /// What the user and AI have said about names.
    public struct Rules: Sendable {
        /// Scoped key ("person:rohan") → the entity it must belong to.
        public var forced: [String: ForcedAlias]
        /// Pair keys (`EntityResolver.pairKey`) that must never end up in one entity.
        public var distinct: Set<String>
        /// AI answers for candidate pairs: true = same, false = different.
        public var decisions: [String: Bool]

        public init(forced: [String: ForcedAlias] = [:], distinct: Set<String> = [], decisions: [String: Bool] = [:]) {
            self.forced = forced
            self.distinct = distinct
            self.decisions = decisions
        }
    }

    /// Two groups that might be one thing; AI is asked (in one batch).
    public struct Candidate: Hashable, Sendable {
        public var kind: EntityKind
        public var a: String
        public var b: String
        public var aName: String
        public var bName: String
        public var aItems: [UUID]
        public var bItems: [UUID]
        public var reason: String
        public var pairKey: String { EntityResolver.pairKey(a, b) }
    }

    /// One canonical entity.
    public struct Resolved: Sendable {
        public var id: UUID
        public var kind: EntityKind
        public var name: String
        /// Display spellings, most seen first (the name first).
        public var aliases: [String]
        public var keys: [String]
        public var itemIDs: Set<UUID>
        public var firstSeen: Date?
        public var lastSeen: Date?
        /// The previous entity whose id it kept, if any.
        public var existingID: UUID?
    }

    public struct Result: Sendable {
        public var entities: [Resolved]
        /// Ambiguous pairs worth an AI check (no decision yet).
        public var candidates: [Candidate]
        /// "Rohan → Rohan Mehta": earlier separate entities now one (for the change log).
        public var merges: [(kept: String, absorbed: [String])]
    }

    /// Lone first names merge without co-occurrence when their items are at least this similar.
    public var contextMergeSimilarity: Float = 0.85
    /// At most this many candidates are returned (the ones with the most items).
    public var candidateLimit = 40

    public init() {}

    /// Order-independent key for two scoped keys.
    public static func pairKey(_ a: String, _ b: String) -> String { a < b ? a + "||" + b : b + "||" + a }

    // MARK: Mentions

    /// The people / projects / organisations names on an item. A people or project name carrying a legal
    /// suffix ("Acme Inc.") counts as an organisation.
    public static func mentions(of item: MemoryItem) -> [Mention] {
        var out: [Mention] = []
        func add(_ names: [String], _ kind: EntityKind) {
            for raw in names {
                let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, name.count <= 80 else { continue }
                let k = kind != .organisation && looksLikeOrganisation(name) ? EntityKind.organisation : kind
                out.append(Mention(kind: k, name: name, itemID: item.id, date: item.createdAt))
            }
        }
        add(item.people, .person)
        add(item.projects, .project)
        add(item.organisations, .organisation)
        return out
    }

    /// Ends with a legal suffix ("Pvt Ltd", "Inc", "LLC", "GmbH"…), not counting generic words like "group".
    static func looksLikeOrganisation(_ name: String) -> Bool {
        let words = TextFold.words(name)
        guard words.count >= 2 else { return false }
        for suffix in EntityNames.orgSuffixes where suffix != ["group"] && suffix != ["company"] && suffix != ["co"]
            && suffix != ["as"] && suffix != ["ab"] && suffix != ["s", "a"] && suffix != ["private"] {
            if words.count > suffix.count && Array(words.suffix(suffix.count)) == suffix { return true }
        }
        return false
    }

    // MARK: Resolve

    private struct Group {
        var kind: EntityKind
        var key: String
        var spellings: [String: Int] = [:]
        var items: Set<UUID> = []
        var first: Date?
        var last: Date?
        var context: Set<String> = []
        var words: [String] { key.split(separator: " ").map(String.init) }
        var mentionCount: Int { spellings.values.reduce(0, +) }
    }

    /// Resolves `mentions` into entities. `similarity` compares two sets of items by meaning (nil when unknown).
    public func resolve(_ mentions: [Mention], existing: [Existing], rules: Rules,
                        similarity: ((Set<UUID>, Set<UUID>) -> Float?)? = nil) -> Result {
        // 1. Groups by scoped key.
        var groups: [String: Group] = [:]
        var itemKeys: [UUID: Set<String>] = [:]
        for m in mentions {
            let k = EntityNames.key(m.name, kind: m.kind)
            guard !k.isEmpty else { continue }
            let scoped = m.kind.rawValue + ":" + k
            var g = groups[scoped] ?? Group(kind: m.kind, key: k)
            g.spellings[m.name, default: 0] += 1
            g.items.insert(m.itemID)
            g.first = min(g.first ?? m.date, m.date)
            g.last = max(g.last ?? m.date, m.date)
            groups[scoped] = g
            itemKeys[m.itemID, default: []].insert(scoped)
        }
        for keys in itemKeys.values where keys.count > 1 {
            for k in keys { groups[k]?.context.formUnion(keys.subtracting([k])) }
        }
        // Forced spellings that no item uses (aliases the user added) still belong to their entity.
        for (scoped, forced) in rules.forced where groups[scoped] == nil {
            guard let colon = scoped.firstIndex(of: ":"), let kind = EntityKind(rawValue: String(scoped[..<colon])) else { continue }
            var g = Group(kind: kind, key: String(scoped[scoped.index(after: colon)...]))
            g.spellings[forced.spelling] = 0
            groups[scoped] = g
        }
        let keys = groups.keys.sorted()
        var uf = UnionFind(keys)

        func union(_ a: String, _ b: String) {
            guard groups[a]?.kind == groups[b]?.kind else { return }
            uf.union(a, b) { x, y in
                for p in x { for q in y {
                    let pk = Self.pairKey(p, q)
                    if rules.distinct.contains(pk) || rules.decisions[pk] == false { return false }
                } }
                return true
            }
        }

        // 2. User merges, then spellings already one entity.
        var forcedByEntity: [UUID: [String]] = [:]
        for k in keys { if let f = rules.forced[k] { forcedByEntity[f.entityID, default: []].append(k) } }
        for (_, ks) in forcedByEntity.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            for k in ks.dropFirst() { union(ks[0], k) }
        }
        var existingKeys: [(Existing, [String])] = []
        for e in existing where e.kind.isExtracted {
            let ks = Set(e.aliases.map { e.kind.rawValue + ":" + EntityNames.key($0, kind: e.kind) }).filter { groups[$0] != nil }.sorted()
            existingKeys.append((e, ks))
            // A forced alias pointing elsewhere was moved out by the user: don't pull it back in.
            let own = ks.filter { rules.forced[$0] == nil || rules.forced[$0]?.entityID == e.id }
            for k in own.dropFirst() { union(own[0], k) }
            // Spellings the user merged into this entity join its own.
            if let first = own.first { for k in forcedByEntity[e.id] ?? [] { union(first, k) } }
        }

        // 3. People rules.
        let people = keys.filter { groups[$0]?.kind == .person }
        // Full names: first and last name spelled out (a middle initial is fine).
        let fullNames = people.filter { k in
            let w = groups[k]!.words
            return w.count >= 2 && w[0].count > 1 && w[w.count - 1].count > 1
        }
        var byFirstLast: [String: [String]] = [:]
        var byFirst: [String: [String]] = [:]
        var byLast: [String: [String]] = [:]
        for k in fullNames {
            let w = groups[k]!.words
            byFirstLast[w[0] + " " + w[w.count - 1], default: []].append(k)
            byFirst[w[0], default: []].append(k)
            byLast[w[w.count - 1], default: []].append(k)
        }
        for (_, ks) in byFirstLast.sorted(by: { $0.key < $1.key }) where ks.count > 1 {
            for k in ks.dropFirst() { union(ks[0], k) }
        }
        func uniqueRoot(_ ks: [String]) -> String? {
            let roots = Set(ks.map { uf.find($0) })
            return roots.count == 1 ? ks.sorted().first : nil
        }
        // Initials: "r mehta" / "rohan m".
        for k in people {
            let w = groups[k]!.words
            guard w.count >= 2 else { continue }
            var matches: [String] = []
            if w[0].count == 1, w.last!.count > 1 {
                matches = (byLast[w.last!] ?? []).filter { groups[$0]!.words[0].hasPrefix(w[0]) }
            } else if w.last!.count == 1, w[0].count > 1 {
                matches = (byFirst[w[0]] ?? []).filter { groups[$0]!.words.last!.hasPrefix(w.last!) }
            }
            if let target = uniqueRoot(matches) { union(target, k) }
        }
        // Lone first names.
        var candidates: [Candidate] = []
        func contextOf(_ root: String) -> (items: Set<UUID>, context: Set<String>, keys: Set<String>) {
            var items = Set<UUID>(), context = Set<String>(), members = Set<String>()
            for k in uf.members(of: root) {
                guard let g = groups[k] else { continue }
                items.formUnion(g.items)
                context.formUnion(g.context)
                members.insert(k)
            }
            return (items, context.subtracting(members), members)
        }
        for k in people where groups[k]!.words.count == 1 {
            let first = groups[k]!.words[0]
            guard first.count > 1, let matches = byFirst[first], let target = uniqueRoot(matches) else { continue }
            guard uf.find(target) != uf.find(k) else { continue }
            let pk = Self.pairKey(k, target)
            if rules.decisions[pk] == true { union(target, k); continue }
            if rules.decisions[pk] == false || rules.distinct.contains(pk) { continue }
            let a = contextOf(k), b = contextOf(target)
            let cooccur = !a.items.isDisjoint(with: b.items) || !a.context.isDisjoint(with: b.context)
            if cooccur {
                union(target, k)
            } else if let s = similarity?(a.items, b.items), s >= contextMergeSimilarity {
                union(target, k)
            } else {
                candidates.append(candidate(k, target, groups: groups, reason: "first name only"))
            }
        }

        // 4. AI decisions for any other pair.
        for (pk, same) in rules.decisions.sorted(by: { $0.key < $1.key }) where same {
            let parts = pk.components(separatedBy: "||")
            if parts.count == 2, groups[parts[0]] != nil, groups[parts[1]] != nil { union(parts[0], parts[1]) }
        }

        // 5. Other candidates: typos, prefixes, acronyms (asked once; decisions remembered).
        let roots = Dictionary(grouping: keys, by: { uf.find($0) })
        var rootKeys = roots.keys.sorted()
        rootKeys.sort { (groups[$0]?.kind.rawValue ?? "", $0) < (groups[$1]?.kind.rawValue ?? "", $1) }
        var byKind: [EntityKind: [String]] = [:]
        for r in rootKeys { if let kind = groups[r]?.kind { byKind[kind, default: []].append(r) } }
        for (kind, rs) in byKind.sorted(by: { $0.key.rawValue < $1.key.rawValue }) where rs.count > 1 {
            let reps = rs.map { r -> String in
                // The representative key: the most mentioned in the group.
                let best = roots[r]!.max { (groups[$0]!.mentionCount, $1) < (groups[$1]!.mentionCount, $0) }!
                return groups[best]!.key
            }
            // Look-alikes share a first letter (typos, prefixes); acronyms are matched by lookup.
            let buckets = Dictionary(grouping: reps.indices, by: { reps[$0].first ?? " " })
            func consider(_ x: String, _ y: String) {
                guard let reason = Self.lookAlike(x, y, kind: kind) else { return }
                let a = kind.rawValue + ":" + x, b = kind.rawValue + ":" + y
                let pk = Self.pairKey(a, b)
                guard rules.decisions[pk] == nil, !rules.distinct.contains(pk) else { return }
                candidates.append(candidate(a, b, groups: groups, reason: reason))
            }
            for (_, indices) in buckets.sorted(by: { $0.key < $1.key }) where indices.count > 1 {
                let limited = indices.prefix(400)
                for (n, i) in limited.enumerated() {
                    for j in limited.dropFirst(n + 1) { consider(reps[i], reps[j]) }
                }
            }
            if kind == .organisation {
                var acronyms: [String: [String]] = [:]
                for r in reps { if let a = EntityNames.acronym(r), a.count >= 2 { acronyms[a, default: []].append(r) } }
                for r in reps where !r.contains(" ") {
                    for long in acronyms[r] ?? [] { consider(r, long) }
                }
            }
        }

        // 6. Entities, keeping previous ids.
        let finalRoots = Dictionary(grouping: keys, by: { uf.find($0) })
        var built: [(keys: [String], mentions: Int)] = finalRoots.values.map { ks in
            (ks.sorted(), ks.reduce(0) { $0 + (groups[$1]?.mentionCount ?? 0) })
        }
        built.sort { ($0.mentions, $1.keys[0]) > ($1.mentions, $0.keys[0]) }
        var taken = Set<UUID>()
        var existingByID: [UUID: Existing] = [:]
        for e in existing { existingByID[e.id] = e }
        var keyOwners: [String: [UUID]] = [:]
        for (e, ks) in existingKeys { for k in ks { keyOwners[k, default: []].append(e.id) } }
        var entities: [Resolved] = []
        var merges: [(kept: String, absorbed: [String])] = []
        for b in built {
            guard let kind = groups[b.keys[0]]?.kind else { continue }
            var id: UUID?
            // A user merge decides.
            let forcedIDs = b.keys.compactMap { rules.forced[$0]?.entityID }
            if let f = forcedIDs.first(where: { !taken.contains($0) }) { id = f }
            // Else the previous entity sharing the most mentions.
            var overlap: [UUID: Int] = [:]
            for k in b.keys { for owner in keyOwners[k] ?? [] { overlap[owner, default: 0] += max(1, groups[k]?.mentionCount ?? 0) } }
            if id == nil {
                id = overlap.filter { !taken.contains($0.key) }
                    .max { ($0.value, $1.key.uuidString) < ($1.value, $0.key.uuidString) }?.key
            }
            let previous = id.flatMap { existingByID[$0] }
            if id == nil {
                let stable = BrainIDs.stable(b.keys[0])
                id = taken.contains(stable) || existingByID[stable] != nil ? UUID() : stable
            }
            let finalID = id!
            taken.insert(finalID)
            var spellings: [String: Int] = [:]
            var items = Set<UUID>()
            var first: Date?, last: Date?
            for k in b.keys {
                guard let g = groups[k] else { continue }
                for (s, n) in g.spellings { spellings[s, default: 0] += n }
                items.formUnion(g.items)
                if let f = g.first { first = min(first ?? f, f) }
                if let l = g.last { last = max(last ?? l, l) }
            }
            guard !items.isEmpty || !forcedIDs.isEmpty else { continue }
            var name = EntityNames.preferredDisplay(spellings, kind: kind)
            if let previous, previous.nameLocked { name = previous.name }
            var aliases = [name]
            for s in spellings.sorted(by: { ($0.value, $1.key) > ($1.value, $0.key) }).map(\.key) {
                if !aliases.contains(where: { TextFold.fold($0) == TextFold.fold(s) }) { aliases.append(s) }
            }
            entities.append(Resolved(id: finalID, kind: kind, name: name, aliases: aliases, keys: b.keys, itemIDs: items,
                                     firstSeen: first, lastSeen: last, existingID: previous?.id))
        }
        // Entities that only exist through user-added aliases (no items) are dropped.
        entities.removeAll { $0.itemIDs.isEmpty }
        // Previous entities that are now part of another one, for the change log.
        let kept = Set(entities.map(\.id))
        var keyToEntity: [String: Int] = [:]
        for (i, e) in entities.enumerated() { for k in e.keys { keyToEntity[k] = i } }
        var absorbed: [Int: [String]] = [:]
        for (e, ks) in existingKeys where !kept.contains(e.id) {
            let homes = ks.compactMap { keyToEntity[$0] }
            guard let home = Dictionary(grouping: homes, by: { $0 }).max(by: { ($0.value.count, $1.key) < ($1.value.count, $0.key) })?.key else { continue }
            absorbed[home, default: []].append(e.name)
        }
        for (i, names) in absorbed.sorted(by: { $0.key < $1.key }) { merges.append((entities[i].name, names.sorted())) }
        entities.sort { ($0.kind.rawValue, $0.name, $0.id.uuidString) < ($1.kind.rawValue, $1.name, $1.id.uuidString) }

        var seen = Set<String>()
        let unique = candidates.filter { seen.insert($0.pairKey).inserted }
            .filter { uf.find($0.a) != uf.find($0.b) }
            .sorted { ($0.aItems.count + $0.bItems.count, $1.pairKey) > ($1.aItems.count + $1.bItems.count, $0.pairKey) }
        return Result(entities: entities, candidates: Array(unique.prefix(candidateLimit)), merges: merges)
    }

    private func candidate(_ a: String, _ b: String, groups: [String: Group], reason: String) -> Candidate {
        let ga = groups[a], gb = groups[b]
        return Candidate(kind: ga?.kind ?? .person, a: a, b: b,
                         aName: ga.map { EntityNames.preferredDisplay($0.spellings, kind: $0.kind) } ?? a,
                         bName: gb.map { EntityNames.preferredDisplay($0.spellings, kind: $0.kind) } ?? b,
                         aItems: (ga?.items ?? []).sorted { $0.uuidString < $1.uuidString },
                         bItems: (gb?.items ?? []).sorted { $0.uuidString < $1.uuidString }, reason: reason)
    }

    /// Why two different keys of one kind might still be one thing, or nil.
    static func lookAlike(_ a: String, _ b: String, kind: EntityKind) -> String? {
        guard a != b else { return nil }
        let wa = a.split(separator: " "), wb = b.split(separator: " ")
        // Typos: same first letter, close spelling, long enough to mean it.
        if min(a.count, b.count) >= 6, a.first == b.first, EntityNames.editDistance(a, b, cap: 2) <= (min(a.count, b.count) >= 10 ? 2 : 1) {
            return "similar spelling"
        }
        switch kind {
        case .person:
            return nil
        case .organisation, .project:
            // "mehta" / "mehta traders": one is the start of the other.
            let (short, long) = wa.count <= wb.count ? (wa, wb) : (wb, wa)
            if short.count < long.count, short.joined().count >= 4, Array(long.prefix(short.count)) == short {
                return "one name starts the other"
            }
            if kind == .organisation {
                if wa.count == 1, EntityNames.acronym(b) == a, a.count >= 2 { return "acronym" }
                if wb.count == 1, EntityNames.acronym(a) == b, b.count >= 2 { return "acronym" }
            }
            return nil
        case .topic, .area:
            return nil
        }
    }
}

/// Union–find over string keys with a veto on each union (do-not-merge pairs).
struct UnionFind {
    private var parent: [String: String] = [:]
    private var members: [String: [String]] = [:]

    init(_ keys: [String]) {
        for k in keys {
            parent[k] = k
            members[k] = [k]
        }
    }

    mutating func find(_ k: String) -> String {
        guard let p = parent[k] else { return k }
        if p == k { return k }
        let root = find(p)
        parent[k] = root
        return root
    }

    func members(of root: String) -> [String] { members[root] ?? [root] }

    /// Joins the sets of `a` and `b` unless `allowed(membersA, membersB)` says no. The smaller key
    /// (alphabetically) becomes the root, so results don't depend on call order.
    @discardableResult
    mutating func union(_ a: String, _ b: String, allowed: ([String], [String]) -> Bool = { _, _ in true }) -> Bool {
        let ra = find(a), rb = find(b)
        guard ra != rb, parent[ra] != nil, parent[rb] != nil else { return false }
        let ma = members[ra] ?? [ra], mb = members[rb] ?? [rb]
        guard allowed(ma, mb) else { return false }
        let (root, child) = ra < rb ? (ra, rb) : (rb, ra)
        parent[child] = root
        members[root] = (members[root] ?? [root]) + (members[child] ?? [child])
        members[child] = nil
        return true
    }
}
