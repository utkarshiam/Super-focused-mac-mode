import Foundation

/// A point on the mental map, in layout units (the UI scales to fit `MapGraph.bounds`).
public struct MapPoint: Hashable, Codable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = MapPoint(x: 0, y: 0)

    private enum CodingKeys: String, CodingKey { case x, y }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        x = c.value(.x, default: 0)
        y = c.value(.y, default: 0)
    }
}

/// The taxonomy's item links: which items each topic holds (directly; sub-topics hold their own), each
/// item's primary topic, and what's waiting in "Unsorted". Plus when it was last reorganised.
public struct BrainTaxonomy: Hashable, Codable, Sendable {
    /// Topic id (uuidString) → item ids directly in it.
    public var members: [String: [UUID]]
    /// Item id (uuidString) → its primary topic (the deepest, most fitting one).
    public var primary: [String: UUID]
    /// Items looked at but not close enough to any topic; they wait for the next reorganisation.
    public var unsorted: [UUID]
    public var organizedAt: Date?
    public var itemCountAtOrganize: Int
    /// New items seen since the last reorganisation (one is due at `MemoryBrain.organizeAfterNewItems`).
    public var newSinceOrganize: Int
    /// The similarity floor of the last clustering (incremental assignment uses it).
    public var similarityFloor: Float?
    /// "vectors:<model>:<dimensions>" or "words": the space the topics were clustered in.
    public var space: String

    public init(members: [String: [UUID]] = [:], primary: [String: UUID] = [:], unsorted: [UUID] = [], organizedAt: Date? = nil,
                itemCountAtOrganize: Int = 0, newSinceOrganize: Int = 0, similarityFloor: Float? = nil, space: String = "") {
        self.members = members
        self.primary = primary
        self.unsorted = unsorted
        self.organizedAt = organizedAt
        self.itemCountAtOrganize = itemCountAtOrganize
        self.newSinceOrganize = newSinceOrganize
        self.similarityFloor = similarityFloor
        self.space = space
    }

    private enum CodingKeys: String, CodingKey {
        case members, primary, unsorted, organizedAt, itemCountAtOrganize, newSinceOrganize, similarityFloor, space
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        members = c.value(.members, default: [:])
        primary = c.value(.primary, default: [:])
        unsorted = c.value(.unsorted, default: [])
        organizedAt = c.value(.organizedAt, default: nil)
        itemCountAtOrganize = c.value(.itemCountAtOrganize, default: 0)
        newSinceOrganize = c.value(.newSinceOrganize, default: 0)
        similarityFloor = c.value(.similarityFloor, default: nil)
        space = c.value(.space, default: "")
    }

    public func members(of topic: UUID) -> [UUID] { members[topic.uuidString] ?? [] }
    public func primary(of item: UUID) -> UUID? { primary[item.uuidString] }
}

/// What the user (and AI, for names) has decided, so automation never undoes it.
public struct BrainCorrections: Hashable, Codable, Sendable {
    /// Scoped key ("person:rohan") → the entity the user merged that spelling into.
    public var forced: [String: EntityResolver.ForcedAlias]
    /// Pair keys (`EntityResolver.pairKey`) the user said are different things.
    public var distinct: [String]
    /// AI answers on ambiguous pairs (pair key → same?).
    public var decisions: [String: Bool]
    /// Item id → topics the user took it out of (reorganising never puts it back).
    public var excluded: [String: [UUID]]
    /// Item id → topics the user put it in.
    public var added: [String: [UUID]]
    /// Item id → the primary topic the user chose.
    public var primary: [String: UUID]

    public init(forced: [String: EntityResolver.ForcedAlias] = [:], distinct: [String] = [], decisions: [String: Bool] = [:],
                excluded: [String: [UUID]] = [:], added: [String: [UUID]] = [:], primary: [String: UUID] = [:]) {
        self.forced = forced
        self.distinct = distinct
        self.decisions = decisions
        self.excluded = excluded
        self.added = added
        self.primary = primary
    }

    private enum CodingKeys: String, CodingKey { case forced, distinct, decisions, excluded, added, primary }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        forced = c.value(.forced, default: [:])
        distinct = c.value(.distinct, default: [])
        decisions = c.value(.decisions, default: [:])
        excluded = c.value(.excluded, default: [:])
        added = c.value(.added, default: [:])
        primary = c.value(.primary, default: [:])
    }

    var rules: EntityResolver.Rules {
        EntityResolver.Rules(forced: forced, distinct: Set(distinct), decisions: decisions)
    }

    mutating func addDistinct(_ pairs: [String]) {
        var set = Set(distinct)
        for p in pairs where set.insert(p).inserted { distinct.append(p) }
        for p in pairs { decisions[p] = nil }
    }
}

/// Everything in brain.json.
///
/// ```
/// {"version": 1, "entities": [BrainEntity…], "taxonomy": BrainTaxonomy, "changeLog": [BrainChange…] (last 50),
///  "connections": [BrainConnection…], "seenPairs": ["<uuid>|<uuid>"…], "digests": [BrainDigest…] (last 8 weeks),
///  "layout": {"<entity uuid>": {"x": 0.4, "y": -1.2}…}, "layoutKey": "…", "corrections": BrainCorrections,
///  "connectionsAt": "…", "candidatesAskedAt": "…"}
/// ```
/// Every key is optional when reading; unknown keys are ignored (a newer app may add some).
public struct BrainState: Hashable, Codable, Sendable {
    public static let currentVersion = 1
    public static let changeLogLimit = 50
    public static let digestLimit = 8
    public static let seenPairsLimit = 5000

    public var version: Int
    public var entities: [BrainEntity]
    public var taxonomy: BrainTaxonomy
    public var changeLog: [BrainChange]
    public var connections: [BrainConnection]
    public var seenPairs: [String]
    public var digests: [BrainDigest]
    public var layout: [String: MapPoint]
    /// Which graph `layout` was computed for (node ids), so an unchanged graph isn't laid out again.
    public var layoutKey: String
    public var corrections: BrainCorrections
    public var connectionsAt: Date?
    /// When ambiguous names were last sent for AI confirmation.
    public var candidatesAskedAt: Date?

    public init(entities: [BrainEntity] = [], taxonomy: BrainTaxonomy = BrainTaxonomy(), changeLog: [BrainChange] = [],
                connections: [BrainConnection] = [], seenPairs: [String] = [], digests: [BrainDigest] = [],
                layout: [String: MapPoint] = [:], layoutKey: String = "", corrections: BrainCorrections = BrainCorrections(),
                connectionsAt: Date? = nil, candidatesAskedAt: Date? = nil) {
        self.version = Self.currentVersion
        self.entities = entities
        self.taxonomy = taxonomy
        self.changeLog = changeLog
        self.connections = connections
        self.seenPairs = seenPairs
        self.digests = digests
        self.layout = layout
        self.layoutKey = layoutKey
        self.corrections = corrections
        self.connectionsAt = connectionsAt
        self.candidatesAskedAt = candidatesAskedAt
    }

    private enum CodingKeys: String, CodingKey {
        case version, entities, taxonomy, changeLog, connections, seenPairs, digests, layout, layoutKey, corrections
        case connectionsAt, candidatesAskedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = c.value(.version, default: Self.currentVersion)
        // One unreadable entity doesn't lose the others.
        entities = (c.value(.entities, default: [Lossy<BrainEntity>]())).compactMap(\.value)
        taxonomy = c.value(.taxonomy, default: BrainTaxonomy())
        changeLog = (c.value(.changeLog, default: [Lossy<BrainChange>]())).compactMap(\.value)
        connections = (c.value(.connections, default: [Lossy<BrainConnection>]())).compactMap(\.value)
        seenPairs = c.value(.seenPairs, default: [])
        digests = (c.value(.digests, default: [Lossy<BrainDigest>]())).compactMap(\.value)
        layout = c.value(.layout, default: [:])
        layoutKey = c.value(.layoutKey, default: "")
        corrections = c.value(.corrections, default: BrainCorrections())
        connectionsAt = c.value(.connectionsAt, default: nil)
        candidatesAskedAt = c.value(.candidatesAskedAt, default: nil)
    }

    mutating func log(_ change: BrainChange) {
        changeLog.insert(change, at: 0)
        if changeLog.count > Self.changeLogLimit { changeLog.removeLast(changeLog.count - Self.changeLogLimit) }
    }
}

/// Decodes a value, or nil when it can't (instead of failing the whole array).
struct Lossy<T: Decodable>: Decodable {
    var value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}
