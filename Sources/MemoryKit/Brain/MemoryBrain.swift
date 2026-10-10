import Combine
import Foundation

/// Docket Brain: organised memory on top of a `MemoryLibrary`. Canonical entities (people, organisations,
/// projects, topics, areas) with every spelling seen, a taxonomy (areas → topics → sub-topics) built by
/// clustering, living pages per entity, connections, a weekly digest and a mental map. Shared by the Mac
/// (which computes it) and the phone (which reads `BrainSnapshot`).
///
/// Lifecycle:
/// - `init(library:)` reads `<library>/brain.json` and resolves entities right away (no AI, cheap).
/// - With `autoUpdate`, it follows `library.changes`: names are resolved again and new items join the
///   nearest topic (or wait in Unsorted). No AI, no network.
/// - AI work runs only when the app asks: `runMaintenance(ai:)` (or `attach(to:)` a processor, which calls it
///   whenever processing goes idle). It is safe to call often: each step runs only when due.
///
/// Storage: `brain.json` next to memory.json (`BrainState`), versioned, tolerant, written atomically after
/// `saveDelay` (debounced). Call `flush()` on quit.
@MainActor
public final class MemoryBrain: ObservableObject {
    public let library: MemoryLibrary
    public nonisolated let fileURL: URL

    /// Bumps on every visible change. Cheap to compare for caches.
    @Published public private(set) var revision = 0
    /// Reorganising, synthesising or looking for connections right now.
    @Published public private(set) var isWorking = false
    /// The last AI failure in brain work (cleared by the next success).
    @Published public private(set) var lastError: MemoryAIError?
    /// brain.json couldn't be read at launch (it was set aside; the brain started fresh).
    @Published public private(set) var loadProblem: String?
    @Published public private(set) var saveProblem: String?
    /// Fires after every visible change.
    public let changes = PassthroughSubject<Void, Never>()

    public var saveDelay: TimeInterval
    /// The clock (tests pin it).
    public var now: () -> Date = { Date() }

    // Policy (see the spec): reorganise after this many new items, or this long with at least one new item.
    public var organizeAfterNewItems = 25
    public var organizeInterval: TimeInterval = 7 * 86_400
    /// Below this many items there is nothing to organise.
    public var minimumItemsToOrganize = 6
    /// `runMaintenance` does nothing when called again within this interval.
    public var maintenanceInterval: TimeInterval = 120
    /// Living pages are rewritten at most this often, unless at least `synthesisBurst` items arrived.
    public var synthesisMinInterval: TimeInterval = 6 * 3600
    public var synthesisBurst = 3
    /// Living pages need at least this many items.
    public var synthesisMinimumItems = 2
    /// Connections are looked for at most this often.
    public var connectionsInterval: TimeInterval = 24 * 3600

    var state: BrainState
    let resolver = EntityResolver()

    // Derived indices (rebuilt by `refresh`).
    private var position: [UUID: Int] = [:]
    private(set) var extractedItems: [UUID: Set<UUID>] = [:]
    private var itemEntities: [UUID: [UUID]] = [:]
    private var childrenByParent: [UUID: [UUID]] = [:]
    private var aliasIndex: [String: UUID] = [:]
    private var topicItemCache: [UUID: Set<UUID>] = [:]
    private var mentionCache: [UUID: (updatedAt: Date, mentions: [EntityResolver.Mention])] = [:]
    /// Ambiguous names from the last resolution, waiting for AI.
    public private(set) var pendingCandidates: [EntityResolver.Candidate] = []
    func pendingCandidatesRemoveAll(where drop: (EntityResolver.Candidate) -> Bool) { pendingCandidates.removeAll(where: drop) }

    private var subscription: AnyCancellable?
    var processorSubscription: AnyCancellable?
    private var saveTask: Task<Void, Never>?
    private var dirty = false
    private nonisolated let io = DispatchQueue(label: "MemoryKit.MemoryBrain.io", qos: .utility)
    var mapCache: (key: String, graph: MapGraph)?
    private var centroidCache: (key: String, centroids: [UUID: TopicCentroid])?
    private var wordSpaceCache: (count: Int, space: WordSpace)?
    var lastMaintenance: Date?
    var maintenanceRunning = false
    private var vocabularyCache: (revision: Int, library: Int, value: ExtractionVocabulary)?
    var organizing = false
    var synthesizing = false
    private var taxonomyStamp = 0

    struct TopicCentroid {
        var vector: [Float]
        var cohesion: Float
    }

    /// Opens the brain stored next to `library`. With `autoUpdate`, it follows library changes by itself.
    public init(library: MemoryLibrary, saveDelay: TimeInterval = 1.0, autoUpdate: Bool = true) {
        self.library = library
        self.saveDelay = saveDelay
        fileURL = library.directory.appendingPathComponent("brain.json")
        state = BrainState()
        load()
        refresh()
        if autoUpdate {
            subscription = library.changes
                .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
                .sink { [weak self] in Task { @MainActor in self?.refresh() } }
        }
    }

    // MARK: Loading and saving

    private func load() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return }
        do {
            state = try MemoryCoding.decoder.decode(BrainState.self, from: Data(contentsOf: fileURL))
        } catch {
            let aside = library.directory.appendingPathComponent("brain.unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? fm.moveItem(at: fileURL, to: aside)
            loadProblem = "Your brain file couldn't be read, so Docket started a new one. The old file was kept as \(aside.lastPathComponent)."
        }
    }

    /// Writes pending changes now (synchronously).
    public func flush() {
        saveTask?.cancel()
        saveTask = nil
        write(synchronously: true)
    }

    private func scheduleSave() {
        dirty = true
        guard saveTask == nil else { return }
        let delay = saveDelay
        saveTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled, let self else { return }
            self.saveTask = nil
            self.write(synchronously: false)
        }
    }

    private func write(synchronously: Bool) {
        guard dirty else { return }
        dirty = false
        let contents = state, url = fileURL, directory = library.directory
        let job: @Sendable () -> String? = {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try MemoryCoding.encoder.encode(contents).write(to: url, options: .atomic)
                return nil
            } catch {
                return "Docket couldn't save your brain: \(error.localizedDescription)"
            }
        }
        if synchronously {
            saveProblem = io.sync(execute: job)
        } else {
            io.async { [weak self] in
                let problem = job()
                Task { @MainActor in self?.saveProblem = problem }
            }
        }
    }

    /// A visible change: new revision, observers told, saved soon.
    func didChange() {
        revision &+= 1
        mapCache = nil
        scheduleSave()
        changes.send()
    }

    /// A change nobody needs to see right away (the layout cache): saved soon, no notification.
    func didChangeQuietly() { scheduleSave() }

    // MARK: Reading

    /// Every entity (areas, topics, people, organisations, projects).
    public var entities: [BrainEntity] { state.entities }

    public func entity(_ id: UUID) -> BrainEntity? { position[id].map { state.entities[$0] } }

    /// The entity of `kind` with this name or alias (any spelling that folds to the same key).
    public func entity(named name: String, kind: EntityKind) -> BrainEntity? {
        aliasIndex[EntityNames.scopedKey(name, kind: kind)].flatMap(entity)
    }

    /// Entities of one kind, most items first (then name).
    public func entities(_ kind: EntityKind) -> [BrainEntity] {
        state.entities.filter { $0.kind == kind }.sorted(by: Self.byWeight)
    }

    /// The areas, biggest first.
    public func areas() -> [BrainEntity] { entities(.area) }

    /// Topics directly under `parentID` (an area or a topic); nil gives the topics that have no parent.
    public func topics(in parentID: UUID?) -> [BrainEntity] {
        if let parentID { return children(of: parentID).filter { $0.kind == .topic } }
        return state.entities.filter { $0.kind == .topic && $0.parentID == nil }.sorted(by: Self.byWeight)
    }

    /// Every topic and sub-topic, biggest first.
    public func allTopics() -> [BrainEntity] { entities(.topic) }

    /// Direct children (topics of an area, sub-topics of a topic), biggest first.
    public func children(of id: UUID) -> [BrainEntity] { (childrenByParent[id] ?? []).compactMap(entity) }

    /// Area → topic → sub-topic, ending with the entity itself.
    public func path(to id: UUID) -> [BrainEntity] {
        var out: [BrainEntity] = []
        var cursor = entity(id)
        while let e = cursor, out.count < 4 {
            out.insert(e, at: 0)
            cursor = e.parentID.flatMap(entity)
        }
        return out
    }

    /// The ids of items behind an entity (topics and areas include their descendants).
    public func itemIDs(for id: UUID) -> Set<UUID> {
        guard let e = entity(id) else { return [] }
        if e.kind.isExtracted { return extractedItems[id] ?? [] }
        return topicItems(id)
    }

    /// Items behind an entity, newest first (topics and areas include their descendants unless told not to).
    public func items(for id: UUID, includeDescendants: Bool = true) -> [MemoryItem] {
        let ids: Set<UUID>
        if !includeDescendants, entity(id)?.kind == .topic { ids = Set(state.taxonomy.members(of: id)) } else { ids = itemIDs(for: id) }
        return ids.compactMap(library.item).sorted { $0.createdAt != $1.createdAt ? $0.createdAt > $1.createdAt : $0.id.uuidString < $1.id.uuidString }
    }

    /// The entities an item belongs to: its topics (direct), people, organisations and projects.
    public func entities(for itemID: UUID) -> [BrainEntity] {
        (itemEntities[itemID] ?? []).compactMap(entity)
    }

    /// The item's primary topic, if it's sorted.
    public func primaryTopic(of itemID: UUID) -> BrainEntity? {
        state.taxonomy.primary(of: itemID).flatMap(entity)
    }

    /// Entities that share items with this one, most shared first (ancestors, descendants and areas excluded).
    public func related(_ id: UUID, limit: Int = 12) -> [RelatedEntity] {
        guard let e = entity(id) else { return [] }
        let mine = itemIDs(for: id)
        guard !mine.isEmpty else { return [] }
        var excluded: Set<UUID> = [id]
        for p in path(to: id) { excluded.insert(p.id) }
        if e.kind.isTaxonomy { excluded.formUnion(descendants(of: id)) }
        var shared: [UUID: Int] = [:]
        for item in mine {
            var seen = Set<UUID>()
            for other in itemEntities[item] ?? [] where !excluded.contains(other) {
                // A sub-topic counts for its parent topic too.
                var cursor: UUID? = other
                while let c = cursor, !excluded.contains(c), let ce = entity(c), ce.kind != .area {
                    if seen.insert(c).inserted { shared[c, default: 0] += 1 }
                    cursor = ce.parentID
                }
            }
        }
        return shared.compactMap { otherID, count -> RelatedEntity? in
            guard let other = entity(otherID) else { return nil }
            let strength = Double(count) / (Double(mine.count) * Double(max(1, other.itemCount))).squareRoot()
            return RelatedEntity(entity: other, sharedItems: count, strength: min(1, strength))
        }
        .sorted { ($0.sharedItems, $0.strength, $1.entity.name) > ($1.sharedItems, $1.strength, $0.entity.name) }
        .prefix(limit).map { $0 }
    }

    /// The entity's items newest first, each with its moments.
    public func timeline(_ id: UUID) -> [TimelineEntry] {
        items(for: id).map { TimelineEntry(item: $0, date: $0.createdAt, moments: $0.moments) }
    }

    /// Items not in any topic yet (newest first). They join one at the next reorganisation.
    public var unsortedItems: [MemoryItem] {
        state.taxonomy.unsorted.compactMap(library.item).sorted { $0.createdAt > $1.createdAt }
    }

    /// What changed, newest first (last 50).
    public var changeLog: [BrainChange] { state.changeLog }

    /// Current connections, not dismissed.
    public var connections: [BrainConnection] { state.connections.filter { !$0.dismissed } }

    /// When the taxonomy was last rebuilt.
    public var organizedAt: Date? { state.taxonomy.organizedAt }

    /// New items since the last reorganisation.
    public var newSinceOrganize: Int { state.taxonomy.newSinceOrganize }

    /// The read-only state (for tests, snapshots and debugging).
    public var currentState: BrainState { state }

    nonisolated static func byWeight(_ a: BrainEntity, _ b: BrainEntity) -> Bool {
        if a.itemCount != b.itemCount { return a.itemCount > b.itemCount }
        let c = a.name.localizedCaseInsensitiveCompare(b.name)
        return c != .orderedSame ? c == .orderedAscending : a.id.uuidString < b.id.uuidString
    }

    func descendants(of id: UUID) -> Set<UUID> {
        var out = Set<UUID>()
        var stack = childrenByParent[id] ?? []
        while let next = stack.popLast() {
            if out.insert(next).inserted { stack += childrenByParent[next] ?? [] }
        }
        return out
    }

    /// Items of a topic or area including descendants.
    func topicItems(_ id: UUID) -> Set<UUID> {
        if let cached = topicItemCache[id] { return cached }
        var out = Set(state.taxonomy.members(of: id))
        for child in childrenByParent[id] ?? [] { out.formUnion(topicItems(child)) }
        topicItemCache[id] = out
        return out
    }

    // MARK: Vocabulary

    /// Names already in memory for the extraction prompt: topic names (biggest first), the most used tags, and
    /// canonical people, projects and organisations.
    public func extractionVocabulary() -> ExtractionVocabulary {
        if let cached = vocabularyCache, cached.revision == revision, cached.library == library.revision { return cached.value }
        var tagCounts: [String: Int] = [:]
        for item in library.items.prefix(2000) { for t in item.tags { tagCounts[t.lowercased(), default: 0] += 1 } }
        let tags = tagCounts.filter { $0.value >= 2 }.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key)
        func names(_ kind: EntityKind, _ limit: Int) -> [String] { Array(entities(kind).prefix(limit).map(\.name)) }
        let value = ExtractionVocabulary(topics: names(.topic, ExtractionVocabulary.limits.topics),
                                         tags: Array(tags.prefix(ExtractionVocabulary.limits.tags)),
                                         people: names(.person, ExtractionVocabulary.limits.people),
                                         projects: names(.project, ExtractionVocabulary.limits.projects),
                                         organisations: names(.organisation, ExtractionVocabulary.limits.organisations))
        vocabularyCache = (revision, library.revision, value)
        return value
    }

    // MARK: Refresh (no AI)

    /// Resolves names again, drops deleted items, sorts new items into topics (or Unsorted) and recounts.
    /// Deterministic, no AI. Runs by itself on library changes with `autoUpdate`.
    public func refresh() {
        let before = state
        resolveEntities()
        pruneTaxonomy()
        rebuildIndex()
        if assignNewItems() { rebuildIndex() }
        computeStats()
        rebuildIndex()
        if state != before { didChange() }
    }

    /// The items the taxonomy works with: everything except items still waiting for AI processing.
    var eligibleItems: [MemoryItem] { library.items.filter { $0.processing != .pending } }

    /// Re-resolves names. `logMerges`: put automatic merges in the change log (not when a user correction
    /// caused them; that one is logged already).
    private func resolveEntities(logMerges: Bool = true) {
        var mentions: [EntityResolver.Mention] = []
        for item in library.items {
            if let cached = mentionCache[item.id], cached.updatedAt == item.updatedAt {
                mentions += cached.mentions
            } else {
                let m = EntityResolver.mentions(of: item)
                mentionCache[item.id] = (item.updatedAt, m)
                mentions += m
            }
        }
        if mentionCache.count > library.count + 200 {
            let live = Set(library.items.map(\.id))
            mentionCache = mentionCache.filter { live.contains($0.key) }
        }
        let existing = state.entities.filter { $0.kind.isExtracted }
            .map { EntityResolver.Existing(id: $0.id, kind: $0.kind, name: $0.name, aliases: $0.aliases, nameLocked: $0.locks.name) }
        let library = library
        let vectors = library.vectors
        let result = resolver.resolve(mentions, existing: existing, rules: state.corrections.rules) { a, b in
            Self.setSimilarity(a, b, vectors: vectors)
        }
        pendingCandidates = result.candidates

        var old: [UUID: BrainEntity] = [:]
        for e in state.entities { old[e.id] = e }
        var extracted: [BrainEntity] = []
        var items: [UUID: Set<UUID>] = [:]
        let stamp = now()
        for r in result.entities {
            var e = old[r.id] ?? BrainEntity(id: r.id, kind: r.kind, name: r.name, aliases: r.aliases, createdAt: r.firstSeen ?? stamp)
            if e.name != r.name { e.name = r.name; e.updatedAt = stamp }
            if e.aliases != r.aliases { e.aliases = r.aliases }
            extracted.append(e)
            items[r.id] = r.itemIDs
        }
        extractedItems = items
        state.entities = state.entities.filter { !$0.kind.isExtracted } + extracted
        if logMerges && !result.merges.isEmpty && !old.isEmpty {
            let lines = result.merges.map { "\($0.absorbed.joined(separator: ", ")) → \($0.kept)" }
            let summary = "Merged " + result.merges.map { "\($0.absorbed.joined(separator: ", ")) into \($0.kept)" }.joined(separator: " · ")
            state.log(BrainChange(date: stamp, kind: .resolved, summary: summary, details: lines,
                                  entityIDs: result.merges.compactMap { m in result.entities.first { $0.name == m.kept }?.id }))
        }
    }

    /// Cosine similarity of the centroids of two item sets (nil without vectors for both).
    nonisolated static func setSimilarity(_ a: Set<UUID>, _ b: Set<UUID>, vectors: VectorIndex) -> Float? {
        func centroid(_ ids: Set<UUID>) -> [Float]? {
            var sum: [Float]?
            for id in ids.sorted(by: { $0.uuidString < $1.uuidString }) {
                guard let v = vectors.vector(for: id) else { continue }
                if sum == nil { sum = v } else { for i in 0..<v.count { sum![i] += v[i] } }
            }
            return sum.flatMap(VectorIndex.normalized)
        }
        guard let x = centroid(a), let y = centroid(b) else { return nil }
        return VectorIndex.cosine(x, y)
    }

    /// Drops deleted items and topics from the taxonomy and corrections.
    private func pruneTaxonomy() {
        let live = Set(library.items.map(\.id))
        let topics = Set(state.entities.filter { $0.kind == .topic }.map(\.id.uuidString))
        var t = state.taxonomy
        var members: [String: [UUID]] = [:]
        for (topic, ids) in t.members where topics.contains(topic) {
            let kept = ids.filter { live.contains($0) }
            if !kept.isEmpty { members[topic] = kept }
        }
        t.members = members
        let memberSets = members.mapValues(Set.init)
        t.primary = t.primary.filter { key, topic in
            guard let id = UUID(uuidString: key), live.contains(id), memberSets[topic.uuidString]?.contains(id) == true else { return false }
            return true
        }
        // An item still in a topic but whose primary went away gets its first remaining topic.
        for (topic, ids) in members.sorted(by: { $0.key < $1.key }) {
            for id in ids where t.primary[id.uuidString] == nil { t.primary[id.uuidString] = UUID(uuidString: topic) }
        }
        t.unsorted = t.unsorted.filter { live.contains($0) && t.primary[$0.uuidString] == nil }
        if t != state.taxonomy {
            state.taxonomy = t
            taxonomyStamp &+= 1
        }
        var c = state.corrections
        c.excluded = c.excluded.filter { UUID(uuidString: $0.key).map(live.contains) == true }
        c.added = c.added.filter { UUID(uuidString: $0.key).map(live.contains) == true }
        c.primary = c.primary.filter { UUID(uuidString: $0.key).map(live.contains) == true }
        if c != state.corrections { state.corrections = c }
    }

    private func rebuildIndex() {
        position.removeAll(keepingCapacity: true)
        aliasIndex.removeAll(keepingCapacity: true)
        childrenByParent.removeAll(keepingCapacity: true)
        topicItemCache.removeAll(keepingCapacity: true)
        for (i, e) in state.entities.enumerated() {
            position[e.id] = i
            for alias in e.aliases + [e.name] {
                let k = EntityNames.scopedKey(alias, kind: e.kind)
                if aliasIndex[k] == nil || alias == e.name { aliasIndex[k] = e.id }
            }
            if let p = e.parentID { childrenByParent[p, default: []].append(e.id) }
        }
        for (p, kids) in childrenByParent {
            childrenByParent[p] = kids.compactMap { position[$0].map { state.entities[$0] } }.sorted(by: Self.byWeight).map(\.id)
        }
        var byItem: [UUID: [UUID]] = [:]
        for (topic, ids) in state.taxonomy.members {
            guard let t = UUID(uuidString: topic) else { continue }
            for id in ids { byItem[id, default: []].append(t) }
        }
        for (entity, ids) in extractedItems { for id in ids { byItem[id, default: []].append(entity) } }
        for (item, list) in byItem {
            let primary = state.taxonomy.primary(of: item)
            byItem[item] = list.sorted { a, b in
                if (a == primary) != (b == primary) { return a == primary }
                let ka = position[a].map { state.entities[$0].kind.rawValue } ?? "", kb = position[b].map { state.entities[$0].kind.rawValue } ?? ""
                return ka != kb ? ka > kb : a.uuidString < b.uuidString
            }
        }
        itemEntities = byItem
    }

    /// Item counts and first/last dates for every entity.
    private func computeStats() {
        func dates(_ ids: Set<UUID>) -> (Int, Date?, Date?) {
            var first: Date?, last: Date?
            var count = 0
            for id in ids {
                guard let item = library.item(id) else { continue }
                count += 1
                first = min(first ?? item.createdAt, item.createdAt)
                last = max(last ?? item.createdAt, item.createdAt)
            }
            return (count, first, last)
        }
        for i in state.entities.indices {
            let e = state.entities[i]
            let ids = e.kind.isExtracted ? (extractedItems[e.id] ?? []) : topicItems(e.id)
            let (count, first, last) = dates(ids)
            if e.itemCount != count { state.entities[i].itemCount = count }
            if e.firstSeen != first { state.entities[i].firstSeen = first }
            if e.lastSeen != last { state.entities[i].lastSeen = last }
        }
    }

    // MARK: Incremental assignment

    /// Puts new (and still unsorted) items into the nearest topic: by a topic label that matches a topic's
    /// name or alias, else by meaning when similar enough to the topic's centre. The rest wait in Unsorted.
    /// Returns whether anything changed.
    @discardableResult
    func assignNewItems() -> Bool {
        guard state.taxonomy.organizedAt != nil else { return false }
        var t = state.taxonomy
        let unsorted = Set(t.unsorted)
        let candidates = library.items.filter { item in
            item.processing != .pending && t.primary[item.id.uuidString] == nil
        }
        guard !candidates.isEmpty else { return false }
        let topics = state.entities.filter { $0.kind == .topic && !$0.locks.membership }
        guard !topics.isEmpty else {
            let fresh = candidates.filter { !unsorted.contains($0.id) }
            guard !fresh.isEmpty else { return false }
            t.unsorted += fresh.map(\.id)
            t.newSinceOrganize += fresh.count
            state.taxonomy = t
            taxonomyStamp &+= 1
            return true
        }
        let centroids = topicCentroids()
        let floor = t.similarityFloor ?? 0.5
        let topIDs = topics.filter { e in e.parentID.flatMap(entity)?.kind != .topic }.map(\.id)
        var changed = false
        for item in candidates {
            let isNew = !unsorted.contains(item.id)
            let excluded = Set(state.corrections.excluded[item.id.uuidString] ?? [])
            var chosen: UUID?
            // 1. A label naming a topic.
            for label in item.topics {
                if let id = aliasIndex[EntityNames.scopedKey(label, kind: .topic)], !excluded.contains(id),
                   let e = entity(id), !e.locks.membership {
                    chosen = id
                    break
                }
            }
            // 2. Meaning.
            if chosen == nil, let v = itemVector(item, space: t.space) {
                func best(among ids: [UUID]) -> (UUID, Float)? {
                    var top: (UUID, Float)?
                    for id in ids where !excluded.contains(id) {
                        guard let c = centroids[id] else { continue }
                        let s = VectorIndex.cosine(v, c.vector)
                        let threshold = max(floor, c.cohesion - 0.1)
                        if s >= threshold, s > (top?.1 ?? -1) { top = (id, s) }
                    }
                    return top
                }
                if let (topic, _) = best(among: topIDs) {
                    chosen = topic
                    if let (sub, _) = best(among: childrenByParent[topic] ?? []) { chosen = sub }
                }
            }
            if let chosen {
                t.members[chosen.uuidString, default: []].append(item.id)
                t.primary[item.id.uuidString] = chosen
                t.unsorted.removeAll { $0 == item.id }
                if isNew { t.newSinceOrganize += 1 }
                changed = true
            } else if isNew {
                t.unsorted.append(item.id)
                t.newSinceOrganize += 1
                changed = true
            }
        }
        if changed {
            state.taxonomy = t
            taxonomyStamp &+= 1
        }
        return changed
    }

    /// The item's vector in the taxonomy's space ("vectors:…" uses the library's vectors, "words" the word space).
    func itemVector(_ item: MemoryItem, space: String) -> [Float]? {
        if space.hasPrefix("vectors:") { return library.vector(for: item.id) }
        return wordSpace().vector(item)
    }

    func wordSpace() -> WordSpace {
        let count = library.count
        if let cached = wordSpaceCache, abs(cached.count - count) <= max(10, count / 5) { return cached.space }
        let space = WordSpace(items: eligibleItems)
        wordSpaceCache = (count, space)
        return space
    }

    /// Topic centres (descendants included) and how tight each topic is, in the taxonomy's space.
    func topicCentroids() -> [UUID: TopicCentroid] {
        let space = state.taxonomy.space
        let key = "\(taxonomyStamp)|\(space)|\(library.vectors.count)"
        if let cached = centroidCache, cached.key == key { return cached.centroids }
        var out: [UUID: TopicCentroid] = [:]
        for topic in state.entities where topic.kind == .topic {
            let vectors = topicItems(topic.id).sorted { $0.uuidString < $1.uuidString }.compactMap { id in
                library.item(id).flatMap { itemVector($0, space: space) }
            }
            guard let first = vectors.first else { continue }
            var sum = first
            for v in vectors.dropFirst() where v.count == sum.count { for i in 0..<v.count { sum[i] += v[i] } }
            guard let unit = VectorIndex.normalized(sum) else { continue }
            let cohesion = vectors.map { VectorIndex.cosine($0, unit) }.reduce(0, +) / Float(vectors.count)
            out[topic.id] = TopicCentroid(vector: unit, cohesion: cohesion)
        }
        centroidCache = (key, out)
        return out
    }

    // MARK: Mutation helpers (for the organiser, synthesiser and corrections)

    /// Replaces the state wholesale and re-derives everything (used by the organiser and the seed).
    func replaceState(_ new: BrainState) {
        state = new
        taxonomyStamp &+= 1
        resolveEntities()
        pruneTaxonomy()
        rebuildIndex()
        computeStats()
        rebuildIndex()
        didChange()
    }

    /// Changes one entity in place (no-op when it's gone). Doesn't re-derive; call `reindex()` if needed.
    func updateEntity(_ id: UUID, _ change: (inout BrainEntity) -> Void) {
        guard let i = position[id] else { return }
        change(&state.entities[i])
    }

    /// Re-derives indices and counts after a structural change, then notifies.
    func reindex(resolve: Bool = false, logMerges: Bool = false) {
        taxonomyStamp &+= 1
        if resolve { resolveEntities(logMerges: logMerges) }
        pruneTaxonomy()
        rebuildIndex()
        computeStats()
        rebuildIndex()
        didChange()
    }

    func setWorking(_ working: Bool) { if isWorking != working { isWorking = working } }
    func setError(_ error: MemoryAIError?) { if lastError != error { lastError = error } }
}
