import Foundation

// MARK: - Entity kind

/// What a canonical entity in the brain is. Entities never merge across kinds.
public enum EntityKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case person, organisation, project, topic, area

    public var id: String { rawValue }

    /// Unknown raw values (from a newer app) decode as `.topic`.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = EntityKind(rawValue: raw) ?? .topic
    }

    /// Singular label in the user's lens words ("Deal" for projects under the sales lens).
    public func label(_ vocabulary: LensVocabulary = .neutral) -> String {
        switch self {
        case .person: "Person"
        case .organisation: "Organisation"
        case .project: vocabulary.project
        case .topic: "Topic"
        case .area: "Area"
        }
    }

    /// Plural label in the user's lens words ("Deals", "Team", "Contacts").
    public func pluralLabel(_ vocabulary: LensVocabulary = .neutral) -> String {
        switch self {
        case .person: vocabulary.people
        case .organisation: "Organisations"
        case .project: vocabulary.projects
        case .topic: "Topics"
        case .area: "Areas"
        }
    }

    /// An SF Symbol name.
    public var symbolName: String {
        switch self {
        case .person: "person"
        case .organisation: "building.2"
        case .project: "flag"
        case .topic: "number"
        case .area: "square.grid.2x2"
        }
    }

    /// Kinds that come from extraction strings on items (people, projects, organisations).
    public var isExtracted: Bool { self == .person || self == .organisation || self == .project }
    /// Kinds that make up the taxonomy (areas → topics → sub-topics).
    public var isTaxonomy: Bool { self == .topic || self == .area }
}

// MARK: - Locks

/// What the user has fixed on an entity. Automation (resolution, reorganising, synthesis) never changes a
/// locked aspect. User corrections set the matching lock themselves (renaming locks the name, moving a
/// topic locks its parent). A topic merge keeps the source's names as aliases of the target, so a later
/// cluster with that name joins the target instead of coming back.
public struct EntityLocks: Hashable, Codable, Sendable {
    /// The name stays as the user wrote it.
    public var name: Bool
    /// A topic stays under its parent (area or topic).
    public var parent: Bool
    /// A topic's items are fixed: reorganising neither adds nor removes any (the user still can).
    public var membership: Bool

    public init(name: Bool = false, parent: Bool = false, membership: Bool = false) {
        self.name = name
        self.parent = parent
        self.membership = membership
    }

    public static let none = EntityLocks()
    public static let all = EntityLocks(name: true, parent: true, membership: true)
    public var any: Bool { name || parent || membership }

    private enum CodingKeys: String, CodingKey { case name, parent, membership }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.value(.name, default: false)
        parent = c.value(.parent, default: false)
        membership = c.value(.membership, default: false)
    }
}

// MARK: - Cited text

/// Who wrote a piece of a living page. AI text is replaced on the next synthesis; the user's stays.
public enum BrainAuthor: String, Codable, Sendable {
    case ai, user

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = BrainAuthor(rawValue: raw) ?? .user
    }
}

/// A sentence backed by items: a key fact ("Seed target: $2M on a SAFE") or a disagreement ("Seed target:
/// $1.5M in the board deck on Tue 6 Oct vs $2M after Harbor Capital on Thu 8 Oct").
public struct CitedText: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var text: String
    /// The items that say it, in the order cited.
    public var itemIDs: [UUID]
    /// Pinned facts survive every re-synthesis (the user's own are always kept).
    public var pinned: Bool
    public var author: BrainAuthor

    public init(id: UUID = UUID(), text: String, itemIDs: [UUID] = [], pinned: Bool = false, author: BrainAuthor = .ai) {
        self.id = id
        self.text = text
        self.itemIDs = itemIDs
        self.pinned = pinned
        self.author = author
    }

    /// Kept through a re-synthesis.
    public var isKept: Bool { pinned || author == .user }

    private enum CodingKeys: String, CodingKey { case id, text, itemIDs, pinned, author }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, default: UUID())
        text = c.value(.text, default: "")
        itemIDs = c.value(.itemIDs, default: [])
        pinned = c.value(.pinned, default: false)
        author = c.value(.author, default: .ai)
    }
}

// MARK: - Entity

/// One canonical thing in the user's memory: a person, an organisation, a project, a topic or an area, with
/// every spelling seen and (after synthesis) a living page: what you know, key facts, open questions and
/// disagreements, each backed by item ids.
///
/// Topics form the taxonomy: `parentID` is an area (or, for a sub-topic, a topic); depth is at most 3
/// (area → topic → sub-topic). People, organisations and projects have no parent.
public struct BrainEntity: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var kind: EntityKind
    /// The canonical name ("Rohan Mehta", "Mehta Traders", "Pricing").
    public var name: String
    /// Every spelling seen, the canonical name first ("Rohan Mehta", "Rohan", "R. Mehta", "Rohan ji").
    public var aliases: [String]
    /// Topics: the area or parent topic. Nil for everything else (and for unfiled topics).
    public var parentID: UUID?
    /// One line on what a topic or area covers (from the naming call; may be empty).
    public var detail: String
    /// Topics and areas named from labels without AI: the next AI naming may rename them.
    public var provisionalName: Bool

    /// "What you know": markdown-light (**bold**, "- " bullets), with [n] markers; [n] is `summarySources[n-1]`.
    public var summary: String
    public var summarySources: [UUID]
    /// The user wrote or edited the summary: synthesis leaves it alone.
    public var summaryEditedByUser: Bool
    public var keyFacts: [CitedText]
    /// Things the items leave unresolved ("Does Acme accept a bridge letter instead of the SOC 2 report?").
    public var openQuestions: [String]
    /// Where items contradict each other, with real dates.
    public var disagreements: [CitedText]

    public var createdAt: Date
    public var updatedAt: Date
    /// When the living page was last written by AI.
    public var synthesizedAt: Date?
    /// Items behind it at that time (a re-synthesis is due when this changes).
    public var itemCountAtSynthesis: Int
    /// The last failed synthesis, so a failing entity isn't retried on every pass.
    public var synthesisFailedAt: Date?
    public var locks: EntityLocks

    /// Derived on every refresh (not user data): items linked (topics and areas include their descendants),
    /// and the oldest and newest of them.
    public var itemCount: Int
    public var firstSeen: Date?
    public var lastSeen: Date?

    public init(id: UUID = UUID(), kind: EntityKind, name: String, aliases: [String] = [], parentID: UUID? = nil,
                detail: String = "", provisionalName: Bool = false, summary: String = "", summarySources: [UUID] = [], summaryEditedByUser: Bool = false,
                keyFacts: [CitedText] = [], openQuestions: [String] = [], disagreements: [CitedText] = [],
                createdAt: Date = Date(), updatedAt: Date? = nil, synthesizedAt: Date? = nil, itemCountAtSynthesis: Int = 0,
                synthesisFailedAt: Date? = nil, locks: EntityLocks = .none, itemCount: Int = 0, firstSeen: Date? = nil,
                lastSeen: Date? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.aliases = aliases.isEmpty ? [name] : aliases
        self.parentID = parentID
        self.detail = detail
        self.provisionalName = provisionalName
        self.summary = summary
        self.summarySources = summarySources
        self.summaryEditedByUser = summaryEditedByUser
        self.keyFacts = keyFacts
        self.openQuestions = openQuestions
        self.disagreements = disagreements
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.synthesizedAt = synthesizedAt
        self.itemCountAtSynthesis = itemCountAtSynthesis
        self.synthesisFailedAt = synthesisFailedAt
        self.locks = locks
        self.itemCount = itemCount
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, name, aliases, parentID, detail, provisionalName, summary, summarySources, summaryEditedByUser, keyFacts, openQuestions
        case disagreements, createdAt, updatedAt, synthesizedAt, itemCountAtSynthesis, synthesisFailedAt, locks, itemCount
        case firstSeen, lastSeen
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, default: UUID())
        kind = c.value(.kind, default: .topic)
        name = c.value(.name, default: "")
        aliases = c.value(.aliases, default: [])
        if aliases.isEmpty && !name.isEmpty { aliases = [name] }
        parentID = c.value(.parentID, default: nil)
        detail = c.value(.detail, default: "")
        provisionalName = c.value(.provisionalName, default: false)
        summary = c.value(.summary, default: "")
        summarySources = c.value(.summarySources, default: [])
        summaryEditedByUser = c.value(.summaryEditedByUser, default: false)
        keyFacts = c.value(.keyFacts, default: [])
        openQuestions = c.value(.openQuestions, default: [])
        disagreements = c.value(.disagreements, default: [])
        createdAt = c.value(.createdAt, default: Date())
        updatedAt = c.value(.updatedAt, default: createdAt)
        synthesizedAt = c.value(.synthesizedAt, default: nil)
        itemCountAtSynthesis = c.value(.itemCountAtSynthesis, default: 0)
        synthesisFailedAt = c.value(.synthesisFailedAt, default: nil)
        locks = c.value(.locks, default: .none)
        itemCount = c.value(.itemCount, default: 0)
        firstSeen = c.value(.firstSeen, default: nil)
        lastSeen = c.value(.lastSeen, default: nil)
    }

    /// Whether there is a living page to show (AI or user written).
    public var hasPage: Bool { !summary.isEmpty || !keyFacts.isEmpty || !openQuestions.isEmpty || !disagreements.isEmpty }

    /// The item behind citation `[n]` in `summary` (1-based), if any.
    public func summarySource(_ n: Int) -> UUID? {
        n >= 1 && n <= summarySources.count ? summarySources[n - 1] : nil
    }
}

// MARK: - Membership

/// How an item came to be linked to an entity.
public enum MembershipSource: String, Codable, Sendable {
    /// A people / projects / organisations string on the item, resolved through aliases.
    case extracted
    /// The item's topic label matched a topic's alias.
    case label
    /// Clustering or nearest-topic assignment by meaning.
    case cluster
    /// The user put it there.
    case user
}

/// One item ↔ entity link (derived; not stored as such).
public struct BrainMembership: Hashable, Sendable {
    public var itemID: UUID
    public var entityID: UUID
    public var source: MembershipSource
    /// The item's primary topic (topics only; one per item).
    public var primary: Bool

    public init(itemID: UUID, entityID: UUID, source: MembershipSource, primary: Bool = false) {
        self.itemID = itemID
        self.entityID = entityID
        self.source = source
        self.primary = primary
    }
}

// MARK: - Change log

/// One entry in "what changed in your brain": a reorganisation, an automatic merge, a user correction.
public struct BrainChange: Identifiable, Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// A reorganisation (its `details` say what happened).
        case organised
        /// People, organisations or projects merged by resolution or AI confirmation.
        case resolved
        /// Something the user did (rename, merge, move…).
        case correction

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .organised
        }
    }

    public var id: UUID
    public var date: Date
    public var kind: Kind
    /// One line: "2 new topics: Annual discounts, Store pilots · merged Pricing strategy into Pricing".
    public var summary: String
    /// One line per change.
    public var details: [String]
    /// Entities it touched (for links).
    public var entityIDs: [UUID]

    public init(id: UUID = UUID(), date: Date, kind: Kind, summary: String, details: [String] = [], entityIDs: [UUID] = []) {
        self.id = id
        self.date = date
        self.kind = kind
        self.summary = summary
        self.details = details
        self.entityIDs = entityIDs
    }

    private enum CodingKeys: String, CodingKey { case id, date, kind, summary, details, entityIDs }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, default: UUID())
        date = c.value(.date, default: Date())
        kind = c.value(.kind, default: .organised)
        summary = c.value(.summary, default: "")
        details = c.value(.details, default: [])
        entityIDs = c.value(.entityIDs, default: [])
    }
}

// MARK: - Connections

/// "A connection you haven't made": two items from different topics that say related things without
/// sharing a person, organisation or project.
public struct BrainConnection: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var a: UUID
    public var b: UUID
    /// Cosine similarity of the two items (or word overlap without vectors).
    public var score: Double
    /// One line on what links them ("Both are about emails customers actually open.").
    public var reason: String
    public var foundAt: Date
    public var dismissed: Bool

    public init(id: UUID = UUID(), a: UUID, b: UUID, score: Double, reason: String, foundAt: Date, dismissed: Bool = false) {
        self.id = id
        self.a = a
        self.b = b
        self.score = score
        self.reason = reason
        self.foundAt = foundAt
        self.dismissed = dismissed
    }

    /// Order-independent key for "seen before".
    public var pairKey: String { BrainConnection.pairKey(a, b) }

    public static func pairKey(_ a: UUID, _ b: UUID) -> String {
        let x = a.uuidString, y = b.uuidString
        return x < y ? x + "|" + y : y + "|" + x
    }

    private enum CodingKeys: String, CodingKey { case id, a, b, score, reason, foundAt, dismissed }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, default: UUID())
        a = c.value(.a, default: UUID())
        b = c.value(.b, default: UUID())
        score = c.value(.score, default: 0)
        reason = c.value(.reason, default: "")
        foundAt = c.value(.foundAt, default: Date())
        dismissed = c.value(.dismissed, default: false)
    }
}

// MARK: - Digest

/// A moment quoted in the digest.
public struct DigestMoment: Identifiable, Hashable, Codable, Sendable {
    public var momentID: UUID
    public var itemID: UUID
    public var kind: MomentKind
    public var text: String
    public var who: String?
    public var due: Date?
    public var id: UUID { momentID }

    public init(momentID: UUID, itemID: UUID, kind: MomentKind, text: String, who: String? = nil, due: Date? = nil) {
        self.momentID = momentID
        self.itemID = itemID
        self.kind = kind
        self.text = text
        self.who = who
        self.due = due
    }

    private enum CodingKeys: String, CodingKey { case momentID, itemID, kind, text, who, due }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        momentID = c.value(.momentID, default: UUID())
        itemID = c.value(.itemID, default: UUID())
        kind = c.value(.kind, default: .insight)
        text = c.value(.text, default: "")
        who = c.value(.who, default: nil)
        due = c.value(.due, default: nil)
    }
}

/// A topic and how many items it gained in the week.
public struct DigestTopic: Identifiable, Hashable, Codable, Sendable {
    public var topicID: UUID
    public var name: String
    public var count: Int
    public var id: UUID { topicID }

    public init(topicID: UUID, name: String, count: Int) {
        self.topicID = topicID
        self.name = name
        self.count = count
    }

    private enum CodingKeys: String, CodingKey { case topicID, name, count }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        topicID = c.value(.topicID, default: UUID())
        name = c.value(.name, default: "")
        count = c.value(.count, default: 0)
    }
}

/// "What you learned, 5–11 Oct": the week's new topics, biggest topics, decisions, open promises and a
/// connection. Always available as structure; `text` is AI-written (markdown-light, [n] citations into
/// `sources`) when a key is set, else empty.
public struct BrainDigest: Hashable, Codable, Sendable {
    /// Monday 00:00 of the week (local time).
    public var weekStart: Date
    /// The following Monday 00:00 (exclusive end).
    public var weekEnd: Date
    /// "What you learned, 5–11 Oct".
    public var title: String
    public var itemCount: Int
    public var newTopics: [DigestTopic]
    public var biggestTopics: [DigestTopic]
    public var decisions: [DigestMoment]
    public var openPromises: [DigestMoment]
    public var connection: BrainConnection?
    /// AI prose ("" without a key). [n] → `sources[n-1]`.
    public var text: String
    public var sources: [UUID]
    public var generatedAt: Date

    public init(weekStart: Date, weekEnd: Date, title: String, itemCount: Int = 0, newTopics: [DigestTopic] = [],
                biggestTopics: [DigestTopic] = [], decisions: [DigestMoment] = [], openPromises: [DigestMoment] = [],
                connection: BrainConnection? = nil, text: String = "", sources: [UUID] = [], generatedAt: Date) {
        self.weekStart = weekStart
        self.weekEnd = weekEnd
        self.title = title
        self.itemCount = itemCount
        self.newTopics = newTopics
        self.biggestTopics = biggestTopics
        self.decisions = decisions
        self.openPromises = openPromises
        self.connection = connection
        self.text = text
        self.sources = sources
        self.generatedAt = generatedAt
    }

    /// Whether AI wrote `text`.
    public var isWritten: Bool { !text.isEmpty }
    public var isEmpty: Bool { itemCount == 0 }

    private enum CodingKeys: String, CodingKey {
        case weekStart, weekEnd, title, itemCount, newTopics, biggestTopics, decisions, openPromises, connection, text, sources, generatedAt
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        weekStart = c.value(.weekStart, default: Date())
        weekEnd = c.value(.weekEnd, default: weekStart.addingTimeInterval(7 * 86_400))
        title = c.value(.title, default: "")
        itemCount = c.value(.itemCount, default: 0)
        newTopics = c.value(.newTopics, default: [])
        biggestTopics = c.value(.biggestTopics, default: [])
        decisions = c.value(.decisions, default: [])
        openPromises = c.value(.openPromises, default: [])
        connection = c.value(.connection, default: nil)
        text = c.value(.text, default: "")
        sources = c.value(.sources, default: [])
        generatedAt = c.value(.generatedAt, default: Date())
    }
}

// MARK: - Related and timeline

/// An entity related to another, by how many items they share.
public struct RelatedEntity: Identifiable, Hashable, Sendable {
    public var entity: BrainEntity
    public var sharedItems: Int
    /// Association strength 0…1 (shared / √(sizeA × sizeB)).
    public var strength: Double
    public var id: UUID { entity.id }
}

/// One item on an entity's timeline, with its moments.
public struct TimelineEntry: Identifiable, Hashable, Sendable {
    public var item: MemoryItem
    public var date: Date
    public var moments: [Moment]
    public var id: UUID { item.id }
}
