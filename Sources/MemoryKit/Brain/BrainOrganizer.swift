import Foundation

/// Builds and maintains the taxonomy and confirms ambiguous names, for one brain.
///
/// `organize()` clusters every processed item (by embedding when most items have one from the same model,
/// else by shared words), splits big topics into sub-topics, matches the new clusters to the previous topics
/// by overlap (so ids, names and pages survive), names new clusters and places topics in areas with one AI
/// call (or from labels without a key), and logs what changed. User locks are respected: a membership-locked
/// topic keeps exactly its items, a name-locked one its name, a parent-locked one its area; an item the user
/// took out of a topic never goes back, and a primary topic the user chose stays.
///
/// `organizeIfDue()` runs it when ≥ `MemoryBrain.organizeAfterNewItems` new items arrived, or
/// `organizeInterval` passed with at least one new item, or it never ran (and there are enough items).
@MainActor
public struct BrainOrganizer {
    public let brain: MemoryBrain
    public var ai: MemoryAI?

    public init(brain: MemoryBrain, ai: MemoryAI?) {
        self.brain = brain
        self.ai = ai
    }

    /// Whether a reorganisation is due (see the type's description).
    public var isDue: Bool { brain.isOrganizeDue }

    /// Reorganises when due. Returns the change log entry, or nil when it wasn't due (or there was nothing to do).
    @discardableResult
    public func organizeIfDue() async throws -> BrainChange? {
        guard isDue else { return nil }
        return try await organize()
    }

    /// Rebuilds the taxonomy now. Throws an AI error when the naming call fails (nothing changes then; without
    /// AI it never throws). Returns the change log entry, or nil when there were too few items.
    @discardableResult
    public func organize() async throws -> BrainChange? {
        brain.refresh()
        let input = brain.organizeInput()
        guard input.totalEligible >= brain.minimumItemsToOrganize else { return nil }
        let plan = await Task.detached(priority: .utility) { Self.plan(input) }.value
        var naming: BrainPrompts.TaxonomyAnswer?
        if let ai, !plan.topics.isEmpty {
            let briefs = brain.briefs(for: plan)
            let currentAreas = brain.areas().map(\.name)
            let locked = brain.areas().filter { $0.locks.name }.map(\.name)
            let data = try await ai.generateJSON(system: BrainPrompts.taxonomySystem(lenses: brain.library.lenses, now: brain.now()),
                                                 prompt: BrainPrompts.taxonomyPrompt(clusters: briefs, currentAreas: currentAreas, lockedAreas: locked),
                                                 schema: BrainPrompts.taxonomySchema)
            naming = try BrainPrompts.parseTaxonomy(data, clusterIDs: Set(plan.topics.map(\.key)))
        }
        return brain.applyOrganize(plan, naming: naming)
    }

    /// Sends ambiguous name pairs ("Rohan" / "Rohan Mehta" without co-occurrence, typos, prefixes) to AI in one
    /// call and remembers the answers; confirmed pairs merge. Returns how many pairs were decided.
    @discardableResult
    public func resolveAmbiguous(limit: Int = 25) async throws -> Int {
        guard let ai else { return 0 }
        let candidates = Array(brain.pendingCandidates.prefix(limit))
        guard !candidates.isEmpty else { return 0 }
        var items: [UUID: MemoryItem] = [:]
        for c in candidates { for id in c.aItems.prefix(3) + c.bItems.prefix(3) { items[id] = brain.library.item(id) } }
        let data = try await ai.generateJSON(system: BrainPrompts.sameEntitySystem(now: brain.now()),
                                             prompt: BrainPrompts.sameEntityPrompt(candidates, items: items),
                                             schema: BrainPrompts.sameEntitySchema)
        let answers = try BrainPrompts.parseSameEntity(data, count: candidates.count)
        return brain.applyDecisions(candidates, answers: answers)
    }

    // MARK: Planning (pure, off the main actor)

    struct OldTopic: Sendable {
        var id: UUID
        var name: String
        var parentID: UUID?
        var isSub: Bool
        /// Items including descendants.
        var items: Set<UUID>
        var provisional: Bool
        var locks: EntityLocks
    }

    struct Input: Sendable {
        var items: [MemoryItem]
        var vectors: VectorIndex
        var oldTopics: [OldTopic]
        /// Items in membership-locked topics: not clustered.
        var lockedItems: Set<UUID>
        var totalEligible: Int
    }

    struct PlanTopic: Sendable {
        /// "c1", or "c1.2" for a sub-topic.
        var key: String
        var parentKey: String?
        /// Items directly in it (a parent's items minus its sub-topics').
        var items: [UUID]
        var allItems: [UUID]
        var centroid: [Float]?
        var samples: [UUID]
        var labels: [Label]
        var matched: UUID?
        var jaccard: Double
        var fallbackName: String
    }

    struct Label: Sendable, Hashable {
        var name: String
        var count: Int
    }

    struct Plan: Sendable {
        var topics: [PlanTopic]
        var unsorted: [UUID]
        var floor: Float
        var space: String
        /// Old topics with no match, and the cluster that took most of their items (if any).
        var retired: [(id: UUID, into: String?)]
        var totalEligible: Int
    }

    nonisolated static func plan(_ input: Input) -> Plan {
        let candidates = input.items.filter { !input.lockedItems.contains($0.id) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        // The space: embeddings when most items have one, else words.
        let withVectors = candidates.filter { input.vectors.contains($0.id) }
        var space = "words"
        var rowsItems: [MemoryItem] = []
        var rows: [Float] = []
        var d = 0
        var unsorted: [UUID] = []
        if !input.vectors.isEmpty, withVectors.count >= 3, Double(withVectors.count) >= 0.6 * Double(candidates.count) {
            space = "vectors:\(input.vectors.model):\(input.vectors.dimensions)"
            d = input.vectors.dimensions
            rowsItems = withVectors
            rows.reserveCapacity(withVectors.count * d)
            for item in withVectors { rows.append(contentsOf: input.vectors.vector(for: item.id) ?? []) }
            unsorted = candidates.filter { !input.vectors.contains($0.id) }.map(\.id)
        } else {
            let ws = WordSpace(items: input.items)
            d = ws.dimensions
            for item in candidates {
                if let v = ws.vector(item) { rowsItems.append(item); rows.append(contentsOf: v) } else { unsorted.append(item.id) }
            }
        }
        let n = rowsItems.count
        guard n >= 2 else {
            return Plan(topics: [], unsorted: candidates.map(\.id), floor: 0, space: space,
                        retired: input.oldTopics.filter { !$0.locks.any }.map { ($0.id, nil) }, totalEligible: input.totalEligible)
        }
        let target = BrainClustering.targetTopics(for: input.totalEligible)
        let minSize = BrainClustering.minTopicSize(for: input.totalEligible)
        let result = BrainClustering.cluster(rows, n: n, d: d, target: target, minSize: minSize)
        var clusters = result.clusters
        var centroids = clusters.map { BrainClustering.centroid(rows, d: d, of: $0) }
        // Leftovers join the nearest cluster when similar enough; else they wait in Unsorted.
        for r in result.leftovers {
            let v = Array(rows[r * d ..< (r + 1) * d])
            var best = -1
            var bestScore = result.floor
            for (c, centroid) in centroids.enumerated() {
                guard let centroid else { continue }
                let s = VectorIndex.cosine(v, centroid)
                if s >= bestScore { bestScore = s; best = c }
            }
            if best >= 0 { clusters[best].append(r) } else { unsorted.append(rowsItems[r].id) }
        }
        centroids = clusters.map { BrainClustering.centroid(rows, d: d, of: $0) }

        // Labels across the library (for distinctive names).
        var globalLabels: [String: Int] = [:]
        for item in rowsItems { for l in Set(item.topics.map { EntityNames.key($0, kind: .topic) }) where !l.isEmpty { globalLabels[l, default: 0] += 1 } }

        var topics: [PlanTopic] = []
        for (ci, members) in clusters.enumerated() {
            let key = "c\(ci + 1)"
            var direct = members
            var subs: [PlanTopic] = []
            if members.count >= max(10, 3 * minSize) {
                var subRows: [Float] = []
                subRows.reserveCapacity(members.count * d)
                for r in members { subRows.append(contentsOf: rows[r * d ..< (r + 1) * d]) }
                // Natural sub-groups (a stricter, topic-relative floor), at most five.
                var sub = BrainClustering.cluster(subRows, n: members.count, d: d, target: members.count, minSize: max(3, minSize),
                                                  floorDeviations: 0.75)
                if sub.clusters.count > 5 {
                    sub = BrainClustering.cluster(subRows, n: members.count, d: d, target: 5, minSize: max(3, minSize), floor: .infinity)
                }
                if sub.clusters.count >= 2 {
                    var inSub = Set<Int>()
                    for (si, s) in sub.clusters.enumerated() {
                        let rs = s.map { members[$0] }
                        inSub.formUnion(rs)
                        let c = BrainClustering.centroid(rows, d: d, of: rs)
                        subs.append(makeTopic(key: "\(key).\(si + 1)", parent: key, rows: rs, all: rs, centroid: c,
                                              data: rows, d: d, items: rowsItems, global: globalLabels))
                    }
                    direct = members.filter { !inSub.contains($0) }
                }
            }
            topics.append(makeTopic(key: key, parent: nil, rows: direct, all: members, centroid: centroids[ci],
                                    data: rows, d: d, items: rowsItems, global: globalLabels))
            topics += subs
        }

        // Match to the previous topics by overlap, top level first, then sub-topics within matched parents.
        let matchable = input.oldTopics.filter { !$0.locks.membership }
        var taken = Set<UUID>()
        func match(_ tops: [Int], against olds: [OldTopic]) {
            var pairs: [(t: Int, o: OldTopic, inter: Int, jaccard: Double)] = []
            for t in tops {
                let mine = Set(topics[t].allItems)
                for o in olds where !taken.contains(o.id) {
                    let inter = mine.intersection(o.items).count
                    guard inter > 0 else { continue }
                    pairs.append((t, o, inter, Double(inter) / Double(mine.union(o.items).count)))
                }
            }
            pairs.sort { ($0.jaccard, $0.inter, $1.o.id.uuidString) > ($1.jaccard, $1.inter, $0.o.id.uuidString) }
            for p in pairs where topics[p.t].matched == nil && !taken.contains(p.o.id) {
                let size = topics[p.t].allItems.count
                let ok = p.jaccard >= 0.2 || (Double(p.inter) >= 0.5 * Double(p.o.items.count) && Double(p.inter) >= 0.2 * Double(size))
                guard ok else { continue }
                topics[p.t].matched = p.o.id
                topics[p.t].jaccard = p.jaccard
                taken.insert(p.o.id)
            }
        }
        let topIndices = topics.indices.filter { topics[$0].parentKey == nil }
        match(topIndices, against: matchable.filter { !$0.isSub })
        for parent in topIndices {
            let subIndices = topics.indices.filter { topics[$0].parentKey == topics[parent].key }
            guard !subIndices.isEmpty else { continue }
            let oldParent = topics[parent].matched
            match(subIndices, against: matchable.filter { $0.isSub && (oldParent == nil || $0.parentID == oldParent) })
        }
        let leftoverSubs = topics.indices.filter { topics[$0].parentKey != nil && topics[$0].matched == nil }
        match(leftoverSubs, against: matchable.filter(\.isSub))

        // Old topics without a match: retired (unless locked), with where most of their items went.
        var retired: [(id: UUID, into: String?)] = []
        for o in input.oldTopics where !taken.contains(o.id) && !o.locks.any {
            var best: (String, Int)?
            for t in topics where t.parentKey == nil {
                let inter = o.items.intersection(t.allItems).count
                if inter > (best?.1 ?? 0) { best = (t.key, inter) }
            }
            retired.append((o.id, best.map(\.0)))
        }

        // Fallback names, unique by key; sub-topics first (they're the specific ones), then their parents.
        var used = Set(input.oldTopics.filter { $0.locks.any || taken.contains($0.id) }.map { EntityNames.key($0.name, kind: .topic) })
        var wordSpace: WordSpace?
        let byItem = Dictionary(rowsItems.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for i in topics.indices.sorted(by: { (topics[$0].parentKey == nil ? 1 : 0, $0) < (topics[$1].parentKey == nil ? 1 : 0, $1) }) {
            topics[i].fallbackName = uniqueName(topics[i].labels, used: &used) {
                if wordSpace == nil { wordSpace = WordSpace(items: rowsItems) }
                return wordSpace!.topWords(topics[i].allItems.compactMap { byItem[$0] }, limit: 4)
            }
        }
        return Plan(topics: topics, unsorted: unsorted.sorted { $0.uuidString < $1.uuidString }, floor: result.floor, space: space,
                    retired: retired, totalEligible: input.totalEligible)
    }

    private nonisolated static func makeTopic(key: String, parent: String?, rows rs: [Int], all: [Int], centroid: [Float]?, data: [Float],
                                              d: Int, items: [MemoryItem], global: [String: Int]) -> PlanTopic {
        // Labels: topic labels and tags, by how many items carry them.
        var counts: [String: (name: String, count: Int)] = [:]
        for r in all {
            for raw in Set(items[r].topics + items[r].tags.map { $0.replacingOccurrences(of: "-", with: " ") }) {
                let k = EntityNames.key(raw, kind: .topic)
                guard !k.isEmpty else { continue }
                counts[k] = (counts[k]?.name ?? raw, (counts[k]?.count ?? 0) + 1)
            }
        }
        let labels = counts.values.sorted { ($0.count, $1.name) > ($1.count, $0.name) }.map { Label(name: $0.name, count: $0.count) }
        var samples: [(UUID, Float)] = []
        if let centroid {
            for r in all {
                samples.append((items[r].id, VectorIndex.cosine(Array(data[r * d ..< (r + 1) * d]), centroid)))
            }
        }
        samples.sort { ($0.1, $1.0.uuidString) > ($1.1, $0.0.uuidString) }
        return PlanTopic(key: key, parentKey: parent, items: rs.map { items[$0].id }, allItems: all.map { items[$0].id },
                         centroid: centroid, samples: samples.prefix(6).map(\.0), labels: labels, matched: nil, jaccard: 0,
                         fallbackName: "")
    }

    /// A name from the cluster's own words: its most common topic label not used yet, else its most
    /// distinctive words (`words`, computed only when needed), else two labels together ("Pricing & tiers").
    nonisolated static func uniqueName(_ labels: [Label], used: inout Set<String>, words: () -> [String]) -> String {
        var options = labels.map(\.name)
        for option in options {
            let name = titleCase(option)
            let k = EntityNames.key(name, kind: .topic)
            if !k.isEmpty, used.insert(k).inserted { return name }
        }
        if options.count >= 2 {
            let name = titleCase(options[0]) + " & " + options[1].lowercased()
            if used.insert(EntityNames.key(name, kind: .topic)).inserted { return name }
        }
        let extra = words()
        for option in extra {
            let name = titleCase(option)
            let k = EntityNames.key(name, kind: .topic)
            if !k.isEmpty, used.insert(k).inserted { return name }
        }
        options += extra
        var n = 2
        let base = titleCase(options.first ?? "Topic")
        while !used.insert(EntityNames.key("\(base) \(n)", kind: .topic)).inserted { n += 1 }
        return "\(base) \(n)"
    }

    nonisolated static func titleCase(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "-", with: " ")
        guard let first = t.first else { return t }
        // Keep words the user capitalised ("API", "SaaS"); capitalise only the first letter.
        return first.uppercased() + t.dropFirst()
    }
}

// MARK: - Brain side of organising

extension MemoryBrain {
    /// Whether a reorganisation is due: enough items and (never organised, ≥ `organizeAfterNewItems` new items,
    /// `organizeInterval` passed with new items, or the embedding space changed).
    public var isOrganizeDue: Bool {
        let eligible = eligibleItems
        guard eligible.count >= minimumItemsToOrganize else { return false }
        let t = state.taxonomy
        guard let at = t.organizedAt else { return true }
        if t.newSinceOrganize >= organizeAfterNewItems { return true }
        if now().timeIntervalSince(at) >= organizeInterval && t.newSinceOrganize > 0 { return true }
        // Vectors arrived (or the model changed) since a words-only organisation.
        let vectors = library.vectors
        if !vectors.isEmpty {
            let space = "vectors:\(vectors.model):\(vectors.dimensions)"
            let covered = eligible.filter { vectors.contains($0.id) }.count
            if t.space != space && Double(covered) >= 0.6 * Double(eligible.count) { return true }
        }
        return false
    }

    /// Reorganises when due (see `BrainOrganizer`). Never throws: an AI failure is kept in `lastError` and the
    /// old taxonomy stays. Returns whether it ran.
    @discardableResult
    public func organizeIfDue(ai: MemoryAI?) async -> Bool {
        guard isOrganizeDue, !organizing else { return false }
        return await organizeNow(ai: ai) != nil
    }

    /// Reorganises now, whether due or not. Returns the change log entry (nil on failure or too few items).
    @discardableResult
    public func organizeNow(ai: MemoryAI?) async -> BrainChange? {
        guard !organizing else { return nil }
        organizing = true
        setWorking(true)
        defer {
            organizing = false
            setWorking(synthesizing)
        }
        do {
            let change = try await BrainOrganizer(brain: self, ai: ai).organize()
            setError(nil)
            return change
        } catch {
            setError((error as? MemoryAIError) ?? .badResponse(error.localizedDescription))
            return nil
        }
    }

    func organizeInput() -> BrainOrganizer.Input {
        let eligible = eligibleItems
        let topics = state.entities.filter { $0.kind == .topic }
        var locked = Set<UUID>()
        var old: [BrainOrganizer.OldTopic] = []
        for t in topics {
            let isSub = t.parentID.flatMap(entity)?.kind == .topic
            old.append(.init(id: t.id, name: t.name, parentID: t.parentID, isSub: isSub, items: topicItems(t.id),
                             provisional: t.provisionalName, locks: t.locks))
            if t.locks.membership { locked.formUnion(state.taxonomy.members(of: t.id)) }
        }
        return BrainOrganizer.Input(items: eligible, vectors: library.vectors, oldTopics: old, lockedItems: locked,
                                    totalEligible: eligible.count)
    }

    func briefs(for plan: BrainOrganizer.Plan) -> [BrainPrompts.ClusterBrief] {
        plan.topics.map { t in
            let old = t.matched.flatMap(entity)
            let fixed = old.map { $0.locks.name || (t.jaccard >= 0.5 && !$0.provisionalName) } ?? false
            let area = old?.parentID.flatMap(entity).flatMap { $0.kind == .area ? $0.name : nil }
            return BrainPrompts.ClusterBrief(id: t.key, parentID: t.parentKey, size: t.allItems.count,
                                             currentName: (old?.provisionalName ?? true) && !(old?.locks.name ?? false) ? nil : old?.name,
                                             fixedName: fixed, currentArea: area,
                                             labels: t.labels.prefix(6).map { ($0.name, $0.count) },
                                             samples: t.samples.compactMap(library.item))
        }
    }

    /// Applies an organisation plan (and the AI's names, if any) to the state. Returns the change log entry.
    func applyOrganize(_ plan: BrainOrganizer.Plan, naming: BrainPrompts.TaxonomyAnswer?) -> BrainChange? {
        var s = state
        let stamp = now()
        let live = Set(library.items.map(\.id))
        let oldTopics = s.entities.filter { $0.kind == .topic }
        let oldAreas = s.entities.filter { $0.kind == .area }
        var byID: [UUID: BrainEntity] = [:]
        for e in s.entities { byID[e.id] = e }
        let firstTime = s.taxonomy.organizedAt == nil && oldTopics.isEmpty

        // Topics that stay exactly as they are: membership-locked, or locked and unmatched.
        let matchedIDs = Set(plan.topics.compactMap(\.matched))
        let keptTopics = oldTopics.filter { $0.locks.membership || ($0.locks.any && !matchedIDs.contains($0.id)) }
        let keptIDs = Set(keptTopics.map(\.id))

        // 1. Merge clusters the AI says are the same (top level only), and duplicates by name.
        var topics = plan.topics.filter { t in t.matched.map { !keptIDs.contains($0) } ?? true }
        var absorbedInto: [String: String] = [:]
        if let naming {
            for t in topics where t.parentKey == nil {
                if let same = naming.topics[t.key]?.sameAs, topics.contains(where: { $0.key == same && $0.parentKey == nil }),
                   absorbedInto[same] == nil {
                    absorbedInto[t.key] = same
                }
            }
        }
        // Names.
        var names: [String: (name: String, provisional: Bool, detail: String)] = [:]
        for t in topics {
            let old = t.matched.flatMap { byID[$0] }
            let answer = naming?.topics[t.key]
            if let old, old.locks.name {
                names[t.key] = (old.name, old.provisionalName, answer?.detail.nonEmpty ?? old.detail)
            } else if let old, !old.provisionalName, t.jaccard >= 0.5 {
                names[t.key] = (old.name, false, old.detail.nonEmpty ?? answer?.detail ?? "")
            } else if let answer {
                names[t.key] = (answer.name, false, answer.detail)
            } else if let old {
                names[t.key] = (old.name, old.provisionalName, old.detail)
            } else {
                names[t.key] = (t.fallbackName, true, "")
            }
        }
        // A new cluster named like a continuing topic's alias (a name the user merged into it, an old name) joins it.
        var aliasOwner: [String: String] = [:]
        for t in topics where t.parentKey == nil {
            guard let old = t.matched.flatMap({ byID[$0] }) else { continue }
            for alias in old.aliases { aliasOwner[EntityNames.key(alias, kind: .topic)] = aliasOwner[EntityNames.key(alias, kind: .topic)] ?? t.key }
        }
        for t in topics where t.parentKey == nil && t.matched == nil && absorbedInto[t.key] == nil {
            if let owner = aliasOwner[EntityNames.key(names[t.key]!.name, kind: .topic)], owner != t.key { absorbedInto[t.key] = owner }
        }
        // Same name twice at the top level (or under one parent) → one topic.
        var seenNames: [String: String] = [:]
        for t in topics.sorted(by: { ($0.allItems.count, $1.key) > ($1.allItems.count, $0.key) }) where absorbedInto[t.key] == nil {
            let scope = (t.parentKey ?? "") + "/" + EntityNames.key(names[t.key]!.name, kind: .topic)
            if let other = seenNames[scope] {
                if t.parentKey == nil {
                    absorbedInto[t.key] = other
                } else {
                    let current = names[t.key]!.name
                    names[t.key]!.name = EntityNames.key(t.fallbackName, kind: .topic) != EntityNames.key(current, kind: .topic) ? t.fallbackName : current + " 2"
                    names[t.key]!.provisional = true
                }
            } else {
                seenNames[scope] = t.key
            }
        }
        for (from, into) in absorbedInto {
            guard let i = topics.firstIndex(where: { $0.key == into }), let j = topics.firstIndex(where: { $0.key == from }) else { continue }
            let moved = topics[j].allItems
            topics[i].items += moved.filter { !topics[i].allItems.contains($0) }
            topics[i].allItems += moved.filter { !topics[i].allItems.contains($0) }
        }
        topics.removeAll { t in absorbedInto[t.key] != nil || (t.parentKey.map { absorbedInto[$0] != nil } ?? false) }

        // 2. Ids.
        var idFor: [String: UUID] = [:]
        for t in topics { idFor[t.key] = t.matched ?? UUID() }

        // 3. Areas.
        var areas: [BrainEntity] = oldAreas
        func areaID(named name: String, create: Bool) -> UUID? {
            let k = EntityNames.key(name, kind: .area)
            guard !k.isEmpty else { return nil }
            if let a = areas.first(where: { a in a.aliases.contains { EntityNames.key($0, kind: .area) == k } }) { return a.id }
            guard create, areas.count < 10 else { return nil }
            let a = BrainEntity(id: BrainIDs.stable("area:" + k), kind: .area, name: name, createdAt: stamp)
            areas.append(a)
            return a.id
        }
        if let naming {
            for a in naming.areas {
                if let id = areaID(named: a.name, create: true), let i = areas.firstIndex(where: { $0.id == id }), !a.detail.isEmpty {
                    areas[i].detail = a.detail
                }
            }
        }
        var parentFor: [String: UUID?] = [:]
        let tops = topics.filter { $0.parentKey == nil }
        for t in tops {
            let old = t.matched.flatMap { byID[$0] }
            if let old, old.locks.parent { parentFor[t.key] = old.parentID; continue }
            let oldArea = old?.parentID.flatMap { id in areas.first { $0.id == id } }
            if let oldArea, t.jaccard >= 0.5 { parentFor[t.key] = oldArea.id; continue }
            if let name = naming?.topics[t.key]?.area, !name.isEmpty, let id = areaID(named: name, create: true) {
                parentFor[t.key] = id
                continue
            }
            if let oldArea { parentFor[t.key] = oldArea.id; continue }
            parentFor[t.key] = .some(nil)
        }
        // Without AI: new topics join the nearest area; with no areas at all, build some from labels.
        let unplaced = tops.filter { parentFor[$0.key] == .some(nil) }
        if naming == nil, !unplaced.isEmpty {
            var areaCentroids: [UUID: [Float]] = [:]
            for t in tops {
                guard let p = parentFor[t.key] ?? nil, let c = t.centroid else { continue }
                if var sum = areaCentroids[p] { for i in sum.indices { sum[i] += c[i] }; areaCentroids[p] = sum } else { areaCentroids[p] = c }
            }
            if !areaCentroids.isEmpty {
                for t in unplaced {
                    guard let c = t.centroid else { continue }
                    var best: (UUID, Float)?
                    for (id, sum) in areaCentroids.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
                        guard let unit = VectorIndex.normalized(sum) else { continue }
                        let sim = VectorIndex.cosine(c, unit)
                        if sim >= plan.floor, sim > (best?.1 ?? -2) { best = (id, sim) }
                    }
                    if let best { parentFor[t.key] = best.0 }
                }
            } else if tops.count >= 6 {
                let placed = tops.filter { $0.centroid != nil }
                let d = placed.first?.centroid?.count ?? 0
                var rows: [Float] = []
                for t in placed { rows += t.centroid! }
                var sims = BrainClustering.similarityMatrix(rows, n: placed.count, d: d)
                let groups = BrainClustering.agglomerate(sims: &sims, sizes: placed.map(\.allItems.count),
                                                         target: max(2, min(6, placed.count / 3)), floor: .infinity)
                var usedNames = Set(topics.map { EntityNames.key(names[$0.key]!.name, kind: .area) })
                for g in groups.sorted(by: { ($0.count, -$0[0]) > ($1.count, -$1[0]) }) {
                    let members = g.map { placed[$0] }
                    let name = Self.areaName(for: members, names: names, items: library, used: &usedNames)
                    guard let id = areaID(named: name, create: true) else { continue }
                    if let i = areas.firstIndex(where: { $0.id == id }) { areas[i].provisionalName = true }
                    for m in members { parentFor[m.key] = id }
                }
            }
        }

        // 4. Topic entities.
        var newTopics: [BrainEntity] = []
        var topicCountsByArea: [UUID: Int] = [:]
        for t in topics {
            let id = idFor[t.key]!
            let named = names[t.key]!
            var e = byID[id] ?? BrainEntity(id: id, kind: .topic, name: named.name, createdAt: stamp)
            if e.name != named.name {
                if !e.aliases.contains(where: { TextFold.fold($0) == TextFold.fold(e.name) }) { e.aliases.append(e.name) }
                e.name = named.name
                e.updatedAt = stamp
            }
            e.provisionalName = named.provisional
            e.detail = named.detail
            if let parentKey = t.parentKey { e.parentID = idFor[parentKey] } else { e.parentID = parentFor[t.key] ?? nil }
            e.aliases = Self.topicAliases(name: e.name, previous: e.aliases, labels: t.labels, size: t.allItems.count)
            if let p = e.parentID { topicCountsByArea[p, default: 0] += 1 }
            newTopics.append(e)
        }
        for t in keptTopics { if let p = t.parentID { topicCountsByArea[p, default: 0] += 1 } }
        // Areas with no topics go, unless the user locked them.
        let retiredAreas = areas.filter { topicCountsByArea[$0.id] == nil && !$0.locks.any }
        areas.removeAll { a in retiredAreas.contains { $0.id == a.id } }

        // 5. Membership.
        var members: [String: [UUID]] = [:]
        var primary: [String: UUID] = [:]
        for t in keptTopics { members[t.id.uuidString] = s.taxonomy.members(of: t.id).filter(live.contains) }
        for t in topics {
            guard let id = idFor[t.key] else { continue }
            let items = t.items.filter { live.contains($0) && !(s.corrections.excluded[$0.uuidString]?.contains(id) ?? false) }
            if !items.isEmpty { members[id.uuidString, default: []] += items }
        }
        // Deepest cluster first: a sub-topic's items have it as primary.
        for t in topics.sorted(by: { ($0.parentKey == nil ? 1 : 0, $0.key) < ($1.parentKey == nil ? 1 : 0, $1.key) }) {
            guard let id = idFor[t.key] else { continue }
            for item in members[id.uuidString] ?? [] where primary[item.uuidString] == nil { primary[item.uuidString] = id }
        }
        let topicIDs = Set(newTopics.map(\.id)).union(keptIDs)
        for (item, ids) in s.corrections.added {
            guard let itemID = UUID(uuidString: item), live.contains(itemID) else { continue }
            for id in ids where topicIDs.contains(id) && !(members[id.uuidString]?.contains(itemID) ?? false) {
                members[id.uuidString, default: []].append(itemID)
            }
        }
        for (key, ids) in members.sorted(by: { $0.key < $1.key }) {
            for id in ids where primary[id.uuidString] == nil { primary[id.uuidString] = UUID(uuidString: key) }
        }
        for (item, topic) in s.corrections.primary where members[topic.uuidString]?.contains(where: { $0.uuidString == item }) == true {
            primary[item] = topic
        }
        // Items in a membership-locked topic only (not clustered) keep their primary there.
        for t in keptTopics {
            for id in s.taxonomy.members(of: t.id) where primary[id.uuidString] == nil { primary[id.uuidString] = t.id }
        }
        // Unsorted: what the plan couldn't place, plus clustered items the user took out of their only topic.
        var unsortedSet = Set<UUID>()
        var unsorted: [UUID] = []
        for id in plan.unsorted + plan.topics.flatMap(\.allItems) where live.contains(id) && primary[id.uuidString] == nil {
            if unsortedSet.insert(id).inserted { unsorted.append(id) }
        }

        // 6. Change log.
        var details: [String] = []
        var touched: [UUID] = []
        let added = topics.filter { $0.matched == nil }.map { names[$0.key]!.name }
        if !added.isEmpty && !firstTime {
            details.append("\(added.count) new topic\(added.count == 1 ? "" : "s"): " + added.joined(separator: ", "))
            touched += topics.filter { $0.matched == nil }.compactMap { idFor[$0.key] }
        }
        for (from, into) in absorbedInto.sorted(by: { $0.key < $1.key }) {
            guard let fromOld = plan.topics.first(where: { $0.key == from })?.matched.flatMap({ byID[$0] }),
                  let intoName = names[into]?.name else { continue }
            details.append("merged \(fromOld.name) into \(intoName)")
        }
        for r in plan.retired {
            guard let old = byID[r.id], old.kind == .topic else { continue }
            if let into = r.into, let name = names[into]?.name, absorbedInto[into] == nil {
                details.append("merged \(old.name) into \(name)")
                if let id = idFor[into] { touched.append(id) }
            } else {
                details.append("retired \(old.name)")
            }
        }
        for t in topics {
            guard let old = t.matched.flatMap({ byID[$0] }), let e = newTopics.first(where: { $0.id == old.id }) else { continue }
            if old.name != e.name {
                details.append("renamed \(old.name) to \(e.name)")
                touched.append(e.id)
            }
            if t.parentKey == nil, old.parentID != e.parentID, let area = e.parentID.flatMap({ id in areas.first { $0.id == id } }), old.parentID != nil {
                details.append("moved \(e.name) to \(area.name)")
                touched.append(e.id)
            }
        }
        let newAreas = areas.filter { a in !oldAreas.contains { $0.id == a.id } }.map(\.name)
        if !newAreas.isEmpty && !firstTime { details.append("new area\(newAreas.count == 1 ? "" : "s"): " + newAreas.joined(separator: ", ")) }
        for a in retiredAreas { details.append("retired area \(a.name)") }

        // 7. Commit.
        let extracted = s.entities.filter { $0.kind.isExtracted }
        s.entities = areas + keptTopics + newTopics + extracted
        s.taxonomy = BrainTaxonomy(members: members, primary: primary, unsorted: unsorted, organizedAt: stamp,
                                   itemCountAtOrganize: plan.totalEligible, newSinceOrganize: 0,
                                   similarityFloor: plan.floor, space: plan.space)
        var change: BrainChange?
        if firstTime {
            let topicCount = newTopics.count + keptTopics.count
            let summary = "Organised \(plan.totalEligible) memories into \(topicCount) topic\(topicCount == 1 ? "" : "s")"
                + (areas.isEmpty ? "" : " in \(areas.count) area\(areas.count == 1 ? "" : "s")")
            change = BrainChange(date: stamp, kind: .organised, summary: summary, details: [], entityIDs: areas.map(\.id))
        } else if !details.isEmpty {
            change = BrainChange(date: stamp, kind: .organised, summary: details.prefix(3).joined(separator: " · "), details: details,
                                 entityIDs: Array(Set(touched)).sorted { $0.uuidString < $1.uuidString })
        }
        if let change { s.log(change) }
        replaceState(s)
        return change ?? BrainChange(date: stamp, kind: .organised, summary: "No changes", details: [])
    }

    /// The topic's aliases: its name, its previous names, and labels that mostly mean it (carried by at least
    /// 30% of its items), at most 8.
    static func topicAliases(name: String, previous: [String], labels: [BrainOrganizer.Label], size: Int) -> [String] {
        var out = [name]
        func add(_ s: String) {
            let k = EntityNames.key(s, kind: .topic)
            if !k.isEmpty, !out.contains(where: { EntityNames.key($0, kind: .topic) == k }), out.count < 8 { out.append(s) }
        }
        for p in previous { add(p) }
        for l in labels where l.count >= max(2, Int((Double(size) * 0.3).rounded(.up))) { add(BrainOrganizer.titleCase(l.name)) }
        return out
    }

    /// An area name without AI: the most common broad label across its topics' items that isn't a topic's name.
    static func areaName(for topics: [BrainOrganizer.PlanTopic], names: [String: (name: String, provisional: Bool, detail: String)],
                         items library: MemoryLibrary, used: inout Set<String>) -> String {
        var counts: [String: (String, Int)] = [:]
        for t in topics {
            for id in t.allItems {
                guard let item = library.item(id) else { continue }
                for l in Set(item.topics) {
                    let k = EntityNames.key(l, kind: .area)
                    guard !k.isEmpty else { continue }
                    counts[k] = (counts[k]?.0 ?? l, (counts[k]?.1 ?? 0) + 1)
                }
            }
        }
        for (k, value) in counts.sorted(by: { ($0.value.1, $1.key) > ($1.value.1, $0.key) }) where !used.contains(k) {
            used.insert(k)
            return BrainOrganizer.titleCase(value.0)
        }
        let biggest = topics.max { $0.allItems.count < $1.allItems.count }.flatMap { names[$0.key]?.name } ?? "Area"
        let name = biggest + " & more"
        used.insert(EntityNames.key(name, kind: .area))
        return name
    }

    /// Records AI answers for ambiguous pairs and re-resolves. Returns how many were decided.
    func applyDecisions(_ candidates: [EntityResolver.Candidate], answers: [Int: Bool]) -> Int {
        var decided = 0
        for (i, c) in candidates.enumerated() {
            guard let same = answers[i + 1] else { continue }
            state.corrections.decisions[c.pairKey] = same
            decided += 1
        }
        state.candidatesAskedAt = now()
        if decided > 0 { reindex(resolve: true, logMerges: true) } else { scheduleSaveOnly() }
        return decided
    }

    func scheduleSaveOnly() { didChangeQuietly() }
}

extension String {
    /// nil for an empty (or whitespace) string.
    var nonEmpty: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}
