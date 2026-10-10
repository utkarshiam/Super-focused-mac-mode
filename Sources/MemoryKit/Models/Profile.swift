import Foundation

/// "What Docket knows about me": short facts synthesised from memory by AI, plus the user's own.
/// Pinned facts are never overwritten or removed by AI. Every AI call gets these as context.
public struct MemoryProfile: Hashable, Codable, Sendable {
    public var facts: [ProfileFact]
    /// When AI last refreshed the facts.
    public var refreshedAt: Date?
    /// How many items the library had at that refresh (a refresh is due after enough new ones).
    public var itemCountAtRefresh: Int

    public init(facts: [ProfileFact] = [], refreshedAt: Date? = nil, itemCountAtRefresh: Int = 0) {
        self.facts = facts
        self.refreshedAt = refreshedAt
        self.itemCountAtRefresh = itemCountAtRefresh
    }

    private enum CodingKeys: String, CodingKey { case facts, refreshedAt, itemCountAtRefresh }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        facts = c.value(.facts, default: [])
        refreshedAt = c.value(.refreshedAt, default: nil)
        itemCountAtRefresh = c.value(.itemCountAtRefresh, default: 0)
    }

    public var pinnedFacts: [ProfileFact] { facts.filter(\.pinned) }

    /// The facts as prompt lines ("- [role] Runs a 12-person startup (pinned)"); pinned first.
    public var promptLines: String {
        let ordered = facts.filter(\.pinned) + facts.filter { !$0.pinned }
        return ordered.prefix(40).map { "- [\($0.category.rawValue)] \($0.text)\($0.pinned ? " (confirmed by the user)" : "")" }
            .joined(separator: "\n")
    }
}

public struct ProfileFact: Identifiable, Hashable, Codable, Sendable {
    public enum Category: String, Codable, CaseIterable, Identifiable, Sendable {
        case identity, role, work, project, person, goal, interest, preference, style, other
        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .identity: "About"
            case .role: "Role"
            case .work: "Work"
            case .project: "Projects"
            case .person: "People"
            case .goal: "Goals"
            case .interest: "Interests"
            case .preference: "Preferences"
            case .style: "How to talk to me"
            case .other: "Other"
            }
        }

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Category(rawValue: raw) ?? .other
        }
    }

    /// Who wrote it. AI facts are replaced on every refresh unless pinned; user facts stay.
    public enum Source: String, Codable, Sendable {
        case ai, user

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Source(rawValue: raw) ?? .user
        }
    }

    public var id: UUID
    public var text: String
    public var category: Category
    public var pinned: Bool
    public var source: Source
    public var updatedAt: Date

    public init(id: UUID = UUID(), text: String, category: Category = .other, pinned: Bool = false,
                source: Source = .user, updatedAt: Date = Date()) {
        self.id = id
        self.text = text
        self.category = category
        self.pinned = pinned
        self.source = source
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey { case id, text, category, pinned, source, updatedAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, default: UUID())
        text = c.value(.text, default: "")
        category = c.value(.category, default: .other)
        pinned = c.value(.pinned, default: false)
        source = c.value(.source, default: .user)
        updatedAt = c.value(.updatedAt, default: Date())
    }
}
