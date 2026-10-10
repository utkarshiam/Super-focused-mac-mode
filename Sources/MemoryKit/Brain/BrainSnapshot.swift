import Foundation

/// The brain as the phone sees it, inside `LibrarySnapshot.brain` (read-only, published by the Mac).
/// Entities are the same `BrainEntity` type the Mac uses (pages capped), so the same views work on both.
///
/// ```json
/// {"version": 1, "generatedAt": "…", "organizedAt": "…",
///  "entities": [BrainEntity…],                // areas and topics, then the biggest people/organisations/projects
///  "itemsByEntity": {"<entity uuid>": ["<item uuid>"…]},   // newest first, only items in the snapshot, ≤ 60 each
///  "primaryTopics": {"<item uuid>": "<topic uuid>"}, "unsorted": ["<item uuid>"…],
///  "changeLog": [BrainChange…] (≤ 10), "connections": [BrainConnection…] (≤ 5),
///  "digest": BrainDigest | null, "map": MapGraph (≤ 150 nodes, positions included)}
/// ```
public struct BrainSnapshot: Hashable, Codable, Sendable {
    public static let currentVersion = 1
    /// Caps that keep the snapshot small.
    public static let entityLimit = 400
    public static let itemsPerEntity = 60
    public static let summaryLimit = 1500

    public var version: Int
    public var generatedAt: Date
    public var organizedAt: Date?
    public var entities: [BrainEntity]
    public var itemsByEntity: [String: [UUID]]
    public var primaryTopics: [String: UUID]
    public var unsorted: [UUID]
    public var changeLog: [BrainChange]
    public var connections: [BrainConnection]
    public var digest: BrainDigest?
    public var map: MapGraph

    public init(generatedAt: Date = Date(), organizedAt: Date? = nil, entities: [BrainEntity] = [], itemsByEntity: [String: [UUID]] = [:],
                primaryTopics: [String: UUID] = [:], unsorted: [UUID] = [], changeLog: [BrainChange] = [],
                connections: [BrainConnection] = [], digest: BrainDigest? = nil, map: MapGraph = MapGraph()) {
        self.version = Self.currentVersion
        self.generatedAt = generatedAt
        self.organizedAt = organizedAt
        self.entities = entities
        self.itemsByEntity = itemsByEntity
        self.primaryTopics = primaryTopics
        self.unsorted = unsorted
        self.changeLog = changeLog
        self.connections = connections
        self.digest = digest
        self.map = map
    }

    private enum CodingKeys: String, CodingKey {
        case version, generatedAt, organizedAt, entities, itemsByEntity, primaryTopics, unsorted, changeLog, connections, digest, map
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = c.value(.version, default: Self.currentVersion)
        generatedAt = c.value(.generatedAt, default: Date())
        organizedAt = c.value(.organizedAt, default: nil)
        entities = (c.value(.entities, default: [Lossy<BrainEntity>]())).compactMap(\.value)
        itemsByEntity = c.value(.itemsByEntity, default: [:])
        primaryTopics = c.value(.primaryTopics, default: [:])
        unsorted = c.value(.unsorted, default: [])
        changeLog = (c.value(.changeLog, default: [Lossy<BrainChange>]())).compactMap(\.value)
        connections = (c.value(.connections, default: [Lossy<BrainConnection>]())).compactMap(\.value)
        digest = c.value(.digest, default: nil)
        map = c.value(.map, default: MapGraph())
    }

    // MARK: Reading (phone)

    public func entity(_ id: UUID) -> BrainEntity? { entities.first { $0.id == id } }

    public func entity(named name: String, kind: EntityKind) -> BrainEntity? {
        let key = EntityNames.key(name, kind: kind)
        return entities.first { e in e.kind == kind && e.aliases.contains { EntityNames.key($0, kind: kind) == key } }
    }

    /// Entities of one kind, most items first.
    public func entities(_ kind: EntityKind) -> [BrainEntity] {
        entities.filter { $0.kind == kind }.sorted(by: MemoryBrain.byWeight)
    }

    public func areas() -> [BrainEntity] { entities(.area) }

    /// Topics under `parentID`; nil gives topics with no parent.
    public func topics(in parentID: UUID?) -> [BrainEntity] {
        entities.filter { $0.kind == .topic && $0.parentID == parentID }.sorted(by: MemoryBrain.byWeight)
    }

    public func children(of id: UUID) -> [BrainEntity] {
        entities.filter { $0.parentID == id }.sorted(by: MemoryBrain.byWeight)
    }

    /// Item ids behind an entity (newest first, those in the snapshot).
    public func itemIDs(for id: UUID) -> [UUID] { itemsByEntity[id.uuidString] ?? [] }

    /// The snapshot's items behind an entity, newest first.
    public func items(for id: UUID, in library: LibrarySnapshot) -> [MemoryItem] {
        let wanted = Set(itemIDs(for: id))
        return library.items.filter { wanted.contains($0.id) }
    }

    /// The entities an item belongs to (topics first).
    public func entities(forItem itemID: UUID) -> [BrainEntity] {
        let ids = itemsByEntity.compactMap { key, items in items.contains(itemID) ? UUID(uuidString: key) : nil }
        return ids.compactMap(entity).sorted { ($0.kind == .topic ? 0 : 1, $0.name) < ($1.kind == .topic ? 0 : 1, $1.name) }
    }

    public func primaryTopic(of itemID: UUID) -> BrainEntity? { primaryTopics[itemID.uuidString].flatMap(entity) }

    /// The published map, optionally as of a date (nodes first seen by then; sizes as published) and focused.
    public func map(asOf: Date? = nil, focus: UUID? = nil, hops: Int = 1) -> MapGraph {
        var g = map
        if let asOf { g = g.filtered(asOf: asOf) }
        if let focus { g = g.focused(on: focus, hops: hops) }
        return g
    }
}

extension MemoryBrain {
    /// The compact brain for the phone. `itemIDs` are the items in the same snapshot (memberships are limited
    /// to them).
    public func snapshot(itemIDs: Set<UUID>? = nil) -> BrainSnapshot {
        let taxonomy = state.entities.filter { $0.kind.isTaxonomy }.sorted(by: Self.byWeight)
        let extracted = state.entities.filter { $0.kind.isExtracted && $0.itemCount > 0 }.sorted(by: Self.byWeight)
        let chosen = Array((taxonomy + extracted).prefix(BrainSnapshot.entityLimit))
        var items: [String: [UUID]] = [:]
        var capped: [BrainEntity] = []
        for var e in chosen {
            let ids = self.items(for: e.id).map(\.id).filter { itemIDs?.contains($0) ?? true }
            items[e.id.uuidString] = Array(ids.prefix(BrainSnapshot.itemsPerEntity))
            e.aliases = Array(e.aliases.prefix(6))
            if e.summary.count > BrainSnapshot.summaryLimit { e.summary = TextFold.cap(e.summary, BrainSnapshot.summaryLimit) }
            e.keyFacts = Array(e.keyFacts.prefix(6))
            e.openQuestions = Array(e.openQuestions.prefix(4))
            e.disagreements = Array(e.disagreements.prefix(3))
            capped.append(e)
        }
        let primary = state.taxonomy.primary.filter { key, _ in itemIDs.map { ids in UUID(uuidString: key).map(ids.contains) ?? false } ?? true }
        let unsorted = state.taxonomy.unsorted.filter { itemIDs?.contains($0) ?? true }
        let thisWeek = digest(for: now())
        let lastWeek = digest(for: BrainInsights.week(of: now()).start.addingTimeInterval(-86_400))
        return BrainSnapshot(generatedAt: now(), organizedAt: state.taxonomy.organizedAt, entities: capped, itemsByEntity: items,
                             primaryTopics: primary, unsorted: unsorted, changeLog: Array(state.changeLog.prefix(10)),
                             connections: connections, digest: thisWeek.itemCount > 0 ? thisWeek : (lastWeek.itemCount > 0 ? lastWeek : nil),
                             map: map())
    }
}
