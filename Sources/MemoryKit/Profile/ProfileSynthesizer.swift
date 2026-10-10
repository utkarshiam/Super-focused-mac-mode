import Foundation

/// Refreshes "What Docket knows about me" from recent and important memories (like ENGRAM's user
/// model). Pinned facts and the user's own facts are never changed or removed; AI facts are replaced
/// by the new set, minus anything that repeats a kept fact.
public struct ProfileSynthesizer: Sendable {
    public var ai: MemoryAI
    public var now: @Sendable () -> Date
    /// Memories in the prompt.
    public var itemLimit = 40

    /// A refresh is due after this long…
    public static let refreshInterval: TimeInterval = 24 * 60 * 60
    /// …or after this many new items.
    public static let refreshAfterNewItems = 10
    /// Too little to go on below this.
    public static let minimumItems = 3

    public init(ai: MemoryAI, now: @escaping @Sendable () -> Date = { Date() }) {
        self.ai = ai
        self.now = now
    }

    /// Whether `refresh` is worth a call: enough items, and stale (a day old, or 10+ new items).
    public static func needsRefresh(_ profile: MemoryProfile, itemCount: Int, now: Date = Date()) -> Bool {
        guard itemCount >= minimumItems else { return false }
        guard let last = profile.refreshedAt else { return true }
        return now.timeIntervalSince(last) > refreshInterval || itemCount - profile.itemCountAtRefresh >= refreshAfterNewItems
    }

    /// Refreshes when due (cheap no-op otherwise). Returns whether it ran.
    @MainActor @discardableResult
    public func refreshIfNeeded(_ library: MemoryLibrary) async throws -> Bool {
        guard Self.needsRefresh(library.profile, itemCount: library.count, now: now()) else { return false }
        try await refresh(library)
        return true
    }

    /// Asks Gemini for a fresh set of facts and saves the merged profile.
    @MainActor
    public func refresh(_ library: MemoryLibrary) async throws {
        let items = Self.pickItems(library.items, limit: itemLimit)
        guard !items.isEmpty else { return }
        let profile = library.profile
        let kept = profile.facts.filter { $0.pinned || $0.source == .user }
        let previous = profile.facts.filter { !$0.pinned && $0.source == .ai }
        let data = try await ai.generateJSON(system: MemoryPrompts.profileSystem(lenses: library.lenses, now: now()),
                                             prompt: MemoryPrompts.profilePrompt(confirmed: kept, previous: previous, items: items),
                                             schema: MemoryPrompts.profileSchema)
        let fresh = try Self.parse(data, now: now())
        // The library may have changed while Gemini was thinking: merge into what's there now.
        var updated = library.profile
        updated.facts = Self.merge(existing: updated.facts, new: fresh)
        updated.refreshedAt = now()
        updated.itemCountAtRefresh = library.count
        library.setProfile(updated)
    }

    /// Pinned items first, then the newest; at most `limit`.
    static func pickItems(_ items: [MemoryItem], limit: Int) -> [MemoryItem] {
        let pinned = items.filter(\.pinned).prefix(limit / 4)
        var out = Array(pinned)
        for item in items where out.count < limit && !item.pinned { out.append(item) }
        return out
    }

    private struct Raw: Decodable {
        struct Fact: Decodable {
            var text: String?
            var category: String?
        }
        var facts: [Fact]?
    }

    static func parse(_ data: Data, now: Date) throws -> [ProfileFact] {
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data), let facts = raw.facts else {
            throw MemoryAIError.badResponse(MemoryAIError.unexpectedFormat)
        }
        return facts.compactMap { f in
            let text = (f.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return ProfileFact(text: text, category: ProfileFact.Category(rawValue: f.category ?? "") ?? .other,
                               pinned: false, source: .ai, updatedAt: now)
        }
    }

    /// Pinned and user facts stay as they are; previous AI facts are replaced by `new`, dropping any that
    /// repeat a kept fact or each other (ignoring case, accents and punctuation). An AI fact that comes
    /// back unchanged keeps its id.
    public static func merge(existing: [ProfileFact], new: [ProfileFact]) -> [ProfileFact] {
        let kept = existing.filter { $0.pinned || $0.source == .user }
        let oldAI = existing.filter { !$0.pinned && $0.source == .ai }
        var seen = Set(kept.map { key($0.text) })
        var out = kept
        for var fact in new {
            let k = key(fact.text)
            guard !k.isEmpty, seen.insert(k).inserted else { continue }
            if let same = oldAI.first(where: { key($0.text) == k }) {
                fact.id = same.id
                fact.updatedAt = same.updatedAt
            }
            out.append(fact)
        }
        return out
    }

    static func key(_ text: String) -> String {
        TextFold.words(text).joined(separator: " ")
    }
}
