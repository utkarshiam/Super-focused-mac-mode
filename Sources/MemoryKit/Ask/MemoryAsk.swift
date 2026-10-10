import Foundation

/// One earlier exchange in an Ask conversation.
public struct AskTurn: Hashable, Codable, Sendable {
    public var question: String
    public var answer: String

    public init(question: String, answer: String) {
        self.question = question
        self.answer = answer
    }
}

/// Ask's answer. `text` carries [n] markers; `sources[n - 1]` is the item behind [n].
public struct MemoryAnswer: Hashable, Sendable {
    public struct Citation: Hashable, Sendable {
        /// The n in [n].
        public var number: Int
        public var itemID: UUID
        /// A short exact quote from the source, when the model gave one.
        public var quote: String?
    }

    public var question: String
    public var text: String
    /// Every source cited (in the text or the citation list), in order of first appearance.
    public var citations: [Citation]
    public var followUps: [String]
    /// The cited items, in order of first citation, without duplicates.
    public var usedItemIDs: [UUID]
    /// The numbered sources the model was given (index n - 1).
    public var sources: [MemoryItem]
    /// False when memory didn't hold the answer (the text says so plainly).
    public var answered: Bool

    /// The item behind [n].
    public func item(forCitation number: Int) -> MemoryItem? {
        sources.indices.contains(number - 1) ? sources[number - 1] : nil
    }

    /// As a history turn for the next question.
    public var turn: AskTurn { AskTurn(question: question, answer: text) }
}

/// Ask: question → hybrid retrieval → Gemini answers only from the numbered sources, citing [n];
/// no source, no claim. Works on the Mac (`ask(_:in:)` with the library) and on the phone (`ask(_:search:…)`
/// with a `MemorySearch` built from the snapshot).
public struct MemoryAsk: Sendable {
    public var ai: MemoryAI
    /// Sources given to the model.
    public var sourceLimit: Int
    public var now: @Sendable () -> Date

    public init(ai: MemoryAI, sourceLimit: Int = 8, now: @escaping @Sendable () -> Date = { Date() }) {
        self.ai = ai
        self.sourceLimit = sourceLimit
        self.now = now
    }

    /// Said when nothing in memory matches, without calling Gemini.
    public static let nothingFound = "Nothing in your memory matches that yet."

    /// Asks over the Mac library. `about`: what to look for when it isn't the question itself (a task's title
    /// and notes for "What do I need to know to do: …").
    @MainActor
    public func ask(_ question: String, history: [AskTurn] = [], in library: MemoryLibrary,
                    filter: MemoryFilter = MemoryFilter(), about: String? = nil) async throws -> MemoryAnswer {
        try await ask(question, history: history, search: library.searchEngine(), profile: library.profile,
                      lenses: library.lenses, filter: filter, about: about)
    }

    /// Asks over any searchable set of items (the phone's snapshot).
    public func ask(_ question: String, history: [AskTurn] = [], search: MemorySearch, profile: MemoryProfile,
                    lenses: [Lens], filter: MemoryFilter = MemoryFilter(), about: String? = nil) async throws -> MemoryAnswer {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { throw MemoryAIError.badResponse("Ask a question first.") }
        let topic = about?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sources = await retrieve(topic.isEmpty ? q : topic, history: history, search: search, filter: filter)
            .filter { !TaskContext.isTaskItem($0) }
        guard !sources.isEmpty else {
            return MemoryAnswer(question: q, text: Self.nothingFound, citations: [], followUps: [], usedItemIDs: [],
                                sources: [], answered: false)
        }
        let date = now()
        let system = MemoryPrompts.askSystem(lenses: lenses, profile: profile, now: date)
        let prompt = MemoryPrompts.askPrompt(question: q, history: history, sources: sources, now: date)
        let data = try await ai.generateJSON(system: system, prompt: prompt, schema: MemoryPrompts.askSchema)
        return try Self.parse(data, question: q, sources: sources)
    }

    /// The sources: hybrid search on the question (by meaning when the vectors match this AI's
    /// model; a follow-up also carries the previous question so "and her?" finds the same people).
    public func retrieve(_ question: String, history: [AskTurn], search: MemorySearch, filter: MemoryFilter) async -> [MemoryItem] {
        var vector: [Float]?
        if search.vectors.isCompatible(model: ai.embeddingModel, dimensions: ai.embeddingDimensions) {
            let context = history.last.map { "\($0.question)\n\(question)" } ?? question
            vector = try? await ai.embed([context], task: .query).first
        }
        var hits = search.search(question, queryVector: vector, model: ai.embeddingModel, filter: filter, limit: sourceLimit)
        if hits.isEmpty, let previous = history.last?.question {
            hits = search.search(previous + " " + question, queryVector: vector, model: ai.embeddingModel, filter: filter, limit: sourceLimit)
        }
        return hits.map(\.item)
    }

    // MARK: Parsing

    private struct Raw: Decodable {
        struct Cite: Decodable {
            var source: Int?
            var quote: String?
        }
        var answer: String?
        var answerable: Bool?
        var citations: [Cite]?
        var followUps: [String]?
    }

    /// Reads the model's JSON: keeps only [n] markers that point at a real source (rewriting "[1, 2]"
    /// as "[1][2]"), maps them to item ids, and keeps quotes the model gave.
    public static func parse(_ data: Data, question: String, sources: [MemoryItem]) throws -> MemoryAnswer {
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data),
              let answer = raw.answer?.trimmingCharacters(in: .whitespacesAndNewlines), !answer.isEmpty else {
            throw MemoryAIError.badResponse(MemoryAIError.unexpectedFormat)
        }
        let valid = 1...max(1, sources.count)
        let (text, inText) = cleanMarkers(answer, valid: sources.isEmpty ? nil : valid)

        var quotes: [Int: String] = [:]
        var listed: [Int] = []
        for cite in raw.citations ?? [] {
            guard let n = cite.source, !sources.isEmpty, valid.contains(n) else { continue }
            listed.append(n)
            let quote = cite.quote?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !quote.isEmpty, quotes[n] == nil { quotes[n] = quote }
        }
        var order: [Int] = []
        for n in inText + listed where !order.contains(n) { order.append(n) }
        let citations = order.map { MemoryAnswer.Citation(number: $0, itemID: sources[$0 - 1].id, quote: quotes[$0]) }
        var used: [UUID] = []
        for c in citations where !used.contains(c.itemID) { used.append(c.itemID) }
        let followUps = (raw.followUps ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return MemoryAnswer(question: question, text: text, citations: citations, followUps: Array(followUps.prefix(3)),
                            usedItemIDs: used, sources: sources, answered: raw.answerable ?? !citations.isEmpty)
    }

    /// Normalizes citation markers and drops ones outside `valid` (all of them when nil).
    /// Returns the text and the cited numbers in order of appearance.
    static func cleanMarkers(_ text: String, valid: ClosedRange<Int>?) -> (String, [Int]) {
        guard let regex = try? NSRegularExpression(pattern: #"\s?\[(\d+(?:\s*[,;–-]\s*\d+)*)\]"#) else { return (text, []) }
        let ns = text as NSString
        var out = ""
        var last = 0
        var numbers: [Int] = []
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let whole = ns.substring(with: m.range)
            let inner = ns.substring(with: m.range(at: 1))
            var cited = inner.split(whereSeparator: { ",;–-".contains($0) || $0 == " " })
                .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            // A range like [2-4] means 2, 3 and 4.
            if inner.contains("-") || inner.contains("–"), cited.count == 2, cited[0] < cited[1], cited[1] - cited[0] < 10 {
                cited = Array(cited[0]...cited[1])
            }
            let kept = cited.filter { valid?.contains($0) ?? false }
            if !kept.isEmpty {
                out += (whole.hasPrefix(" ") ? " " : "") + kept.map { "[\($0)]" }.joined()
                for n in kept where !numbers.contains(n) { numbers.append(n) }
            }
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return (out.trimmingCharacters(in: .whitespacesAndNewlines), numbers)
    }
}
