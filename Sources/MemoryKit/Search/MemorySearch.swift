import Foundation

// MARK: - Filter

/// Narrows a list or a search. Empty sets / nil mean "any".
public struct MemoryFilter: Hashable, Sendable {
    public var kinds: Set<MemoryKind>
    public var origins: Set<MemoryOrigin>
    /// Matches `MemoryItem.people`, ignoring case and accents.
    public var person: String?
    public var project: String?
    /// Matches topics or tags.
    public var topic: String?
    /// Only items with at least one moment of this kind (open promises only, for `.promise`, when `openOnly`).
    public var momentKind: MomentKind?
    public var openOnly: Bool
    /// `createdAt` within this range.
    public var dateRange: ClosedRange<Date>?
    public var pinnedOnly: Bool
    /// Free text, ranked like search (`MemoryLibrary.items(matching:)`). Ignored by `matches(_:)`.
    public var text: String

    public init(kinds: Set<MemoryKind> = [], origins: Set<MemoryOrigin> = [], person: String? = nil, project: String? = nil,
                topic: String? = nil, momentKind: MomentKind? = nil, openOnly: Bool = false, dateRange: ClosedRange<Date>? = nil,
                pinnedOnly: Bool = false, text: String = "") {
        self.kinds = kinds
        self.origins = origins
        self.person = person
        self.project = project
        self.topic = topic
        self.momentKind = momentKind
        self.openOnly = openOnly
        self.dateRange = dateRange
        self.pinnedOnly = pinnedOnly
        self.text = text
    }

    /// No constraint at all (text included).
    public var isEmpty: Bool { self == MemoryFilter() }

    /// Every constraint except `text`.
    public func matches(_ item: MemoryItem) -> Bool {
        if !kinds.isEmpty && !kinds.contains(item.kind) { return false }
        if !origins.isEmpty && !origins.contains(item.origin) { return false }
        if pinnedOnly && !item.pinned { return false }
        if let dateRange, !dateRange.contains(item.createdAt) { return false }
        if let person, !Self.contains(item.people, person) { return false }
        if let project, !Self.contains(item.projects, project) { return false }
        if let topic, !Self.contains(item.topics, topic) && !Self.contains(item.tags, topic) { return false }
        if let momentKind {
            guard item.moments.contains(where: { $0.kind == momentKind && (!openOnly || !$0.done) }) else { return false }
        }
        return true
    }

    static func contains(_ names: [String], _ wanted: String) -> Bool {
        let w = TextFold.fold(wanted.trimmingCharacters(in: .whitespacesAndNewlines))
        return names.contains { TextFold.fold($0) == w }
    }
}

// MARK: - Hits

/// One search result.
public struct MemoryHit: Identifiable, Hashable, Sendable {
    public var item: MemoryItem
    /// Combined score, higher is better (roughly 0…1).
    public var score: Double
    /// Cosine similarity with the query, when vectors were used and the item has one.
    public var vectorScore: Double?
    /// Text match strength, 0…1.
    public var textScore: Double

    public var id: UUID { item.id }
}

// MARK: - Search

/// Hybrid retrieval like ENGRAM's: cosine similarity over vectors from the same model and size, merged
/// with text scoring over title, people, projects, tags, summary and body (case- and accent-insensitive,
/// word-prefix matches). Works with no vectors at all. A value: build one (`MemoryLibrary.searchEngine()`
/// caches it) and search it on any thread.
public struct MemorySearch: Sendable {
    public struct Options: Hashable, Sendable {
        /// Vector hits below this cosine similarity are dropped.
        public var minVectorScore: Float = 0.4
        /// Vector hits below this fraction of the best one are dropped (keeps a weak tail out).
        public var relativeVectorCutoff: Float = 0.75
        /// For `related`: the bar is higher, since a strip of loosely related items is noise.
        public var minRelatedScore: Float = 0.55
        public init() {}
    }

    /// An item with its text pre-folded for matching.
    public struct Entry: Sendable {
        public let item: MemoryItem
        let title: [UInt8]
        let names: [UInt8]
        let labels: [UInt8]
        let summary: [UInt8]
        let body: [UInt8]

        public init(_ item: MemoryItem) {
            self.item = item
            title = Self.bytes(item.displayTitle)
            names = Self.bytes((item.people + item.projects + item.organisations).joined(separator: " | "))
            labels = Self.bytes((item.tags + item.topics).joined(separator: " | ") + " | " + (item.capturedFrom ?? ""))
            summary = Self.bytes(([item.summary] + item.keyTakeaways + item.moments.map(\.text)).joined(separator: " | "))
            var text = item.fullText
            if text.count > MemorySearch.bodyLimit { text = String(text.prefix(MemorySearch.bodyLimit)) }
            if let url = item.url { text += " | " + url }
            text += " | " + item.attachments.map(\.name).joined(separator: " ")
            body = Self.bytes(text)
        }

        static func bytes(_ s: String) -> [UInt8] { Array(TextFold.fold(s).utf8) }
    }

    /// How much of a body is searched by text (vectors cover meaning beyond it).
    static let bodyLimit = 6000

    public let entries: [Entry]
    public let vectors: VectorIndex
    public var options: Options
    private let positions: [UUID: Int]

    public init(entries: [Entry], vectors: VectorIndex, options: Options = Options()) {
        self.entries = entries
        self.vectors = vectors
        self.options = options
        var positions: [UUID: Int] = [:]
        positions.reserveCapacity(entries.count)
        for (i, e) in entries.enumerated() { positions[e.item.id] = i }
        self.positions = positions
    }

    /// For a snapshot on the phone: folds every item's text (do it once, off the main thread).
    public init(items: [MemoryItem], vectors: VectorIndex = VectorIndex(), options: Options = Options()) {
        self.init(entries: items.map(Entry.init), vectors: vectors, options: options)
    }

    public func item(_ id: UUID) -> MemoryItem? { positions[id].map { entries[$0].item } }

    // MARK: Search

    /// Best matches for `query`, best first. Pass `queryVector` (and its `model`) to rank by meaning as
    /// well; without it (no key, offline) ranking is text-only. An empty query lists filtered items newest first.
    public func search(_ query: String, queryVector: [Float]? = nil, model: String? = nil,
                       filter: MemoryFilter = MemoryFilter(), limit: Int = 20) -> [MemoryHit] {
        let tokens = Self.tokens(query)
        guard !tokens.isEmpty else {
            return entries.lazy.filter { filter.matches($0.item) }.prefix(limit).map { MemoryHit(item: $0.item, score: 0, vectorScore: nil, textScore: 0) }
        }
        let phrase = tokens.count > 1 ? Array(TextFold.fold(query.trimmingCharacters(in: .whitespacesAndNewlines)).utf8) : nil

        var vectorScores: [UUID: Float] = [:]
        let useVectors = queryVector.map { vectors.isCompatible(model: model ?? vectors.model, dimensions: $0.count) } ?? false
        if useVectors, let queryVector {
            let hits = vectors.nearest(to: queryVector, limit: max(limit * 4, 60), minScore: options.minVectorScore)
            let floor = (hits.first?.score ?? 0) * options.relativeVectorCutoff
            for hit in hits where hit.score >= floor { vectorScores[hit.id] = hit.score }
        }

        var hits: [MemoryHit] = []
        for entry in entries {
            let item = entry.item
            let t = Self.textScore(entry, tokens: tokens, phrase: phrase)
            let v = vectorScores[item.id]
            guard t > 0 || v != nil, filter.matches(item) else { continue }
            var score: Double
            if useVectors {
                if let v {
                    score = 0.75 * Double(v) + 0.25 * t + (t > 0 ? 0.05 : 0)
                } else if !vectors.contains(item.id) {
                    // Not embedded yet: rank on text, on a scale comparable with a good vector match.
                    score = 0.35 + 0.35 * t
                } else {
                    // Embedded and not similar in meaning: a text match alone ranks low.
                    score = 0.25 * t
                }
            } else {
                score = t
            }
            score += Self.nudge(item)
            hits.append(MemoryHit(item: item, score: score, vectorScore: v.map(Double.init), textScore: t))
        }
        hits.sort { $0.score != $1.score ? $0.score > $1.score : $0.item.createdAt > $1.item.createdAt }
        return Array(hits.prefix(limit))
    }

    /// Items related to a piece of text (a task, a thread): by meaning when `vector` is given, else by
    /// shared names and distinctive words. A higher bar than search, so a short strip stays relevant.
    public func related(to text: String, vector: [Float]? = nil, model: String? = nil,
                        excluding: Set<UUID> = [], limit: Int = 3) -> [MemoryHit] {
        if let vector, vectors.isCompatible(model: model ?? vectors.model, dimensions: vector.count) {
            return vectors.nearest(to: vector, limit: limit, minScore: options.minRelatedScore, excluding: excluding).compactMap { hit in
                item(hit.id).map { MemoryHit(item: $0, score: Double(hit.score), vectorScore: Double(hit.score), textScore: 0) }
            }
        }
        return relatedByText(text, excluding: excluding, limit: limit)
    }

    /// Items related to a stored item (its vector, or its text when it has none).
    public func related(toItem id: UUID, limit: Int = 3) -> [MemoryHit] {
        guard let source = item(id) else { return [] }
        if let v = vectors.vector(for: id) {
            return related(to: "", vector: v, model: vectors.model, excluding: [id], limit: limit)
        }
        return relatedByText(source.embeddingText, excluding: [id], limit: limit)
    }

    private func relatedByText(_ text: String, excluding: Set<UUID>, limit: Int) -> [MemoryHit] {
        let folded = TextFold.fold(text)
        // The most distinctive words: long, not stopwords, most frequent first.
        var counts: [String: Int] = [:]
        for w in TextFold.words(text) where w.count >= 4 && !TextFold.stopwords.contains(w) { counts[w, default: 0] += 1 }
        let keywords = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key.count > $1.key.count }.prefix(12).map(\.key)
        guard !keywords.isEmpty || !folded.isEmpty else { return [] }

        var hits: [MemoryHit] = []
        for entry in entries where !excluding.contains(entry.item.id) {
            let item = entry.item
            // A person or project named in the text is the strongest link.
            var names = 0
            for name in item.people + item.projects where name.count >= 3 && folded.contains(TextFold.fold(name)) { names += 1 }
            var matched = 0
            var raw = 0.0
            for word in keywords {
                let s = Self.tokenScore(entry, Array(word.utf8))
                if s > 0 { matched += 1; raw += s }
            }
            guard names > 0 || matched >= 2 else { continue }
            let t = min(1, raw / (3.0 * Double(max(keywords.count, 1))) * 2)
            let score = min(1, Double(names) * 0.35 + t)
            guard score >= 0.3 else { continue }
            hits.append(MemoryHit(item: item, score: score + Self.nudge(item), vectorScore: nil, textScore: t))
        }
        hits.sort { $0.score != $1.score ? $0.score > $1.score : $0.item.createdAt > $1.item.createdAt }
        return Array(hits.prefix(limit))
    }

    // MARK: Text scoring

    /// Folded query words, stopwords dropped (unless that leaves nothing), unique, in order.
    static func tokens(_ query: String) -> [[UInt8]] {
        let words = TextFold.words(query)
        let meaningful = words.filter { !TextFold.stopwords.contains($0) }
        var seen = Set<String>()
        return (meaningful.isEmpty ? words : meaningful).filter { seen.insert($0).inserted }.map { Array($0.utf8) }
    }

    /// 0…1. Each word scores its best field; words that match nothing reduce the score, and a query
    /// of one or two words needs all of them.
    static func textScore(_ entry: Entry, tokens: [[UInt8]], phrase: [UInt8]?) -> Double {
        var raw = 0.0
        var matched = 0
        for token in tokens {
            let s = tokenScore(entry, token)
            if s > 0 { matched += 1; raw += s }
        }
        guard matched > 0 else { return 0 }
        if tokens.count <= 2 && matched < tokens.count { return 0 }
        if Double(matched) < Double(tokens.count) * 0.5 { return 0 }
        if let phrase {
            if strength(phrase, in: entry.title) > 0 { raw += 2 }
            else if strength(phrase, in: entry.summary) > 0 || strength(phrase, in: entry.body) > 0 { raw += 1 }
        }
        let coverage = Double(matched) / Double(tokens.count)
        return min(1, raw / (3.0 * Double(tokens.count)) * coverage)
    }

    /// The best field match for one word: field weight × how well it matched (whole word, word prefix, inside a word).
    static func tokenScore(_ entry: Entry, _ token: [UInt8]) -> Double {
        let fields: [(bytes: [UInt8], weight: Double)] = [
            (entry.title, 3.0), (entry.names, 2.6), (entry.labels, 2.0), (entry.summary, 1.4), (entry.body, 0.8),
        ]
        var best = 0.0
        for field in fields where field.weight > best {
            let s = strength(token, in: field.bytes)
            guard s > 0 else { continue }
            let factor = s == 3 ? 1.0 : s == 2 ? 0.8 : 0.4
            best = max(best, field.weight * factor)
        }
        return best
    }

    /// 3 whole word, 2 word prefix, 1 inside a word (words of 4+ letters only), 0 no match.
    static func strength(_ needle: [UInt8], in haystack: [UInt8]) -> Int {
        guard !needle.isEmpty, haystack.count >= needle.count else { return 0 }
        var best = 0
        haystack.withUnsafeBufferPointer { hay in
            needle.withUnsafeBufferPointer { nee in
                guard let hayBase = hay.baseAddress, let neeBase = nee.baseAddress else { return }
                var offset = 0
                while offset <= hay.count - nee.count {
                    guard let found = memmem(hayBase + offset, hay.count - offset, neeBase, nee.count) else { break }
                    let start = hayBase.distance(to: found.assumingMemoryBound(to: UInt8.self))
                    let end = start + nee.count
                    let atStart = start == 0 || !isWordByte(hay[start - 1])
                    let atEnd = end == hay.count || !isWordByte(hay[end])
                    let s = atStart ? (atEnd ? 3 : 2) : (nee.count >= 4 ? 1 : 0)
                    best = max(best, s)
                    if best == 3 { break }
                    offset = start + 1
                }
            }
        }
        return best
    }

    /// Letters, digits and any non-ASCII byte (part of a multi-byte letter).
    @inline(__always) static func isWordByte(_ b: UInt8) -> Bool {
        (b >= 48 && b <= 57) || (b >= 97 && b <= 122) || (b >= 65 && b <= 90) || b >= 128
    }

    /// A small lift for pinned and recent items, enough to break near-ties.
    static func nudge(_ item: MemoryItem, now: Date = Date()) -> Double {
        let days = max(0, now.timeIntervalSince(item.createdAt) / 86_400)
        return (item.pinned ? 0.02 : 0) + 0.03 * exp(-days / 180)
    }
}
