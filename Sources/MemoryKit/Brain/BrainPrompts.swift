import Foundation

/// The brain's prompts and answer schemas. Like `MemoryPrompts`: every prompt states today's date as an
/// absolute date and asks for absolute dates back, works only from the items it is given, uses the user's
/// lens words, and asks for JSON following a schema whose fields are all required. Every answer is
/// validated: unknown ids, out-of-range citations and empty names are dropped or replaced.
public enum BrainPrompts {
    // MARK: Shared

    static func lensLine(_ lenses: [Lens]) -> String {
        let v = Lens.vocabulary(for: lenses)
        return "The user calls projects \"\(v.projects)\", people \"\(v.people)\", decisions \"\(v.decisions)\", " +
            "promises \"\(v.promises)\" and insights \"\(v.insights)\"; use these words."
    }

    /// Example areas for the user's lenses (suggestions, not a fixed list).
    public static func exampleAreas(for lenses: [Lens]) -> [String] {
        var out: [String] = []
        for lens in lenses.isEmpty ? [Lens.founder] : lenses {
            let areas: [String] = switch lens {
            case .founder: ["Fundraising", "Customers", "Product", "Team", "Operations"]
            case .marketer: ["Campaigns", "Audience", "Content", "Channels", "Brand"]
            case .sales: ["Accounts", "Pipeline", "Objections", "Partnerships", "Pricing"]
            case .engineer: ["Services", "Incidents", "Architecture", "Tooling", "Learning"]
            case .manager: ["Team", "1:1s", "Goals", "Hiring", "Process"]
            case .artist: ["Works", "Inspiration", "Techniques", "Shows", "Studio"]
            }
            for a in areas where !out.contains(a) { out.append(a) }
        }
        out.append("Personal")
        return Array(out.prefix(8))
    }

    /// `"Title" (Mon 5 Oct 2026): gist`
    static func sampleLine(_ item: MemoryItem, gistLimit: Int = 140) -> String {
        var line = "\"\(TextFold.cap(item.displayTitle, 90))\" (\(MemoryDates.prompt(item.createdAt)))"
        let gist = item.summary.isEmpty ? TextFold.tidy(item.fullText) : item.summary
        if !gist.isEmpty { line += ": " + TextFold.cap(gist.replacingOccurrences(of: "\n", with: " "), gistLimit) }
        return line
    }

    // MARK: Taxonomy naming

    /// A cluster as shown to the naming call.
    public struct ClusterBrief: Sendable {
        /// "c3", or "c3.1" for a sub-cluster of c3.
        public var id: String
        public var parentID: String?
        public var size: Int
        /// The topic it continues, when matched to one.
        public var currentName: String?
        /// The user locked the name (or it's long established): keep it exactly.
        public var fixedName: Bool
        public var currentArea: String?
        /// Most common topic labels and tags on its items, with counts.
        public var labels: [(String, Int)]
        /// Items closest to its centre.
        public var samples: [MemoryItem]

        public init(id: String, parentID: String? = nil, size: Int, currentName: String? = nil, fixedName: Bool = false,
                    currentArea: String? = nil, labels: [(String, Int)] = [], samples: [MemoryItem] = []) {
            self.id = id
            self.parentID = parentID
            self.size = size
            self.currentName = currentName
            self.fixedName = fixedName
            self.currentArea = currentArea
            self.labels = labels
            self.samples = samples
        }
    }

    public static func taxonomySystem(lenses: [Lens], now: Date) -> String {
        """
        You organise the user's personal memory into a small, clear library: a few broad areas, with specific \
        topics inside them. You get clusters of saved items, already grouped by meaning. Name each cluster as \
        a topic and put every top-level topic in one area.

        \(MemoryPrompts.today(now))

        Rules:
        - Topic names: 1–4 words, Title Case, specific and concrete, the way the user would say it ("Seed \
        round", "Pricing page", "Acme renewal", "Hiring engineers"). Never generic ("Misc", "Notes", \
        "General", "Other", "Updates", "Ideas", "Stuff") and never a date. Every topic name is different.
        - A cluster with an id like "c3.1" is a sub-topic of "c3": name the narrower part, without repeating \
        the parent's words.
        - Keep a cluster's current name when it still fits. A name marked (keep) must be returned exactly.
        - Areas: 4–10 broad parts of the user's life and work, 1–2 words each (examples for this user: \
        \(exampleAreas(for: lenses).joined(separator: ", "))). Reuse the current areas; add an area only when \
        none fits. A small library may need fewer areas.
        - Each top-level topic gets exactly one area from your list. Sub-topics get "" as area.
        - If two top-level clusters are clearly the same subject, set sameAs on the smaller one to the other's \
        id; otherwise sameAs is "".
        - description: one short sentence on what the topic covers, from its samples only.
        - Work only from the clusters given; never invent subjects, names or facts.

        What the user does:
        \(Lens.guidance(for: lenses))
        \(lensLine(lenses))
        """
    }

    public static func taxonomyPrompt(clusters: [ClusterBrief], currentAreas: [String], lockedAreas: [String] = []) -> String {
        var out = "Current areas: " + (currentAreas.isEmpty ? "none yet" : currentAreas.joined(separator: "; ")) + "\n"
        if !lockedAreas.isEmpty { out += "Areas the user fixed (always keep): " + lockedAreas.joined(separator: "; ") + "\n" }
        out += "\nClusters:\n"
        for c in clusters {
            var head = "\(c.id) · \(c.size) item\(c.size == 1 ? "" : "s")"
            if let parent = c.parentID { head += " · sub-topic of \(parent)" }
            if let name = c.currentName { head += " · current name \"\(name)\"\(c.fixedName ? " (keep)" : "")" }
            if let area = c.currentArea, c.parentID == nil { head += " · current area \(area)" }
            out += head + "\n"
            if !c.labels.isEmpty {
                out += "  labels: " + c.labels.prefix(6).map { "\($0.0) ×\($0.1)" }.joined(separator: ", ") + "\n"
            }
            for item in c.samples.prefix(c.parentID == nil ? 6 : 3) { out += "  - " + sampleLine(item) + "\n" }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static let taxonomySchema: MemoryJSON = MemoryJSON.Schema.object([
        "areas": MemoryJSON.Schema.array(MemoryJSON.Schema.object([
            "name": MemoryJSON.Schema.string(),
            "description": MemoryJSON.Schema.string(),
        ]), maxItems: 10),
        "topics": MemoryJSON.Schema.array(MemoryJSON.Schema.object([
            "id": MemoryJSON.Schema.string("The cluster id, e.g. c3 or c3.1"),
            "name": MemoryJSON.Schema.string(),
            "area": MemoryJSON.Schema.string("One of the areas; \"\" for sub-topics"),
            "description": MemoryJSON.Schema.string(),
            "sameAs": MemoryJSON.Schema.string("Another top-level cluster id, or \"\""),
        ])),
    ])

    /// The naming answer, validated against the clusters asked about.
    public struct TaxonomyAnswer: Equatable, Sendable {
        public struct Area: Equatable, Sendable {
            public var name: String
            public var detail: String
        }
        public struct Topic: Equatable, Sendable {
            public var id: String
            public var name: String
            public var area: String
            public var detail: String
            public var sameAs: String?
        }
        public var areas: [Area]
        /// Keyed by cluster id; only ids that were asked about, with a non-empty name.
        public var topics: [String: Topic]
    }

    private struct RawTaxonomy: Decodable {
        struct Area: Decodable { var name: String?; var description: String? }
        struct Topic: Decodable { var id: String?; var name: String?; var area: String?; var description: String?; var sameAs: String? }
        var areas: [Area]?
        var topics: [Topic]?
    }

    /// Parses and validates a naming answer. Throws when it isn't the expected shape at all.
    public static func parseTaxonomy(_ data: Data, clusterIDs: Set<String>) throws -> TaxonomyAnswer {
        guard let raw = try? JSONDecoder().decode(RawTaxonomy.self, from: data), let topics = raw.topics else {
            throw MemoryAIError.badResponse(MemoryAIError.unexpectedFormat)
        }
        var areas: [TaxonomyAnswer.Area] = []
        for a in raw.areas ?? [] {
            let name = cleanName(a.name ?? "", maxWords: 3)
            guard !name.isEmpty, !areas.contains(where: { EntityNames.key($0.name, kind: .area) == EntityNames.key(name, kind: .area) }) else { continue }
            areas.append(.init(name: name, detail: (a.description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)))
            if areas.count == 10 { break }
        }
        var out: [String: TaxonomyAnswer.Topic] = [:]
        for t in topics {
            let id = (t.id ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let name = cleanName(t.name ?? "", maxWords: 5)
            guard clusterIDs.contains(id), !name.isEmpty, out[id] == nil, !genericNames.contains(TextFold.fold(name)) else { continue }
            let same = (t.sameAs ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            out[id] = .init(id: id, name: name, area: cleanName(t.area ?? "", maxWords: 3),
                            detail: (t.description ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                            sameAs: same.isEmpty || same == id || !clusterIDs.contains(same) ? nil : same)
        }
        return TaxonomyAnswer(areas: areas, topics: out)
    }

    static let genericNames: Set<String> = ["misc", "miscellaneous", "notes", "general", "other", "others", "updates", "ideas",
                                            "stuff", "things", "various", "uncategorized", "unsorted", "random"]

    /// Trimmed, quotes and trailing punctuation removed, at most `maxWords` words and 48 characters.
    static func cleanName(_ raw: String, maxWords: Int) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'“”‘’#*.:;,")))
        let words = s.split(whereSeparator: \.isWhitespace)
        if words.count > maxWords { s = words.prefix(maxWords).joined(separator: " ") }
        if s.count > 48 { s = String(s.prefix(48)).trimmingCharacters(in: .whitespaces) }
        return s
    }

    // MARK: Same entity?

    public static func sameEntitySystem(now: Date) -> String {
        """
        You decide whether two names in the user's personal memory refer to the same real person, \
        organisation or project. Use only the names and the context lines given.

        \(MemoryPrompts.today(now))

        Rules:
        - same is true only when the context makes it clear: the same company, role, deal or conversation; a \
        first name, nickname, initial or misspelling of the same name; a short and a legal form of one company.
        - Different first names, different companies or conflicting details mean false. When unsure, false.
        - Answer every pair by its number.
        """
    }

    public static func sameEntityPrompt(_ candidates: [EntityResolver.Candidate], items: [UUID: MemoryItem]) -> String {
        var out = "Pairs:\n"
        for (i, c) in candidates.enumerated() {
            out += "\(i + 1). \(c.kind.rawValue): \"\(c.aName)\" vs \"\(c.bName)\"\n"
            for (name, ids) in [(c.aName, c.aItems), (c.bName, c.bItems)] {
                let lines = ids.compactMap { items[$0] }.sorted { $0.createdAt > $1.createdAt }.prefix(2)
                for item in lines { out += "   \"\(name)\" in " + sampleLine(item, gistLimit: 160) + "\n" }
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static let sameEntitySchema: MemoryJSON = MemoryJSON.Schema.object([
        "answers": MemoryJSON.Schema.array(MemoryJSON.Schema.object([
            "pair": MemoryJSON.Schema.integer,
            "same": MemoryJSON.Schema.boolean,
        ])),
    ])

    /// Pair number (1-based) → same?
    public static func parseSameEntity(_ data: Data, count: Int) throws -> [Int: Bool] {
        struct Raw: Decodable {
            struct Answer: Decodable { var pair: Int?; var same: Bool? }
            var answers: [Answer]?
        }
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data), let answers = raw.answers else {
            throw MemoryAIError.badResponse(MemoryAIError.unexpectedFormat)
        }
        var out: [Int: Bool] = [:]
        for a in answers {
            guard let n = a.pair, let same = a.same, n >= 1, n <= count, out[n] == nil else { continue }
            out[n] = same
        }
        return out
    }

    // MARK: Living pages

    public static func synthesisSystem(kind: EntityKind, lenses: [Lens], profile: MemoryProfile, now: Date) -> String {
        let label = kind.label(Lens.vocabulary(for: lenses)).lowercased()
        return """
        You keep a living page about one \(label) in the user's personal memory: what they know about it, \
        written only from the numbered items in the message.

        \(MemoryPrompts.today(now))

        Rules:
        - Use ONLY the items. No outside knowledge, no guesses; never invent names, numbers, dates or quotes.
        - summary: 2–5 plain, specific sentences (or short "- " bullets for a list), the most important and \
        most recent first. Cite every claim with its item number in square brackets right after it, like \
        "The seed target is $2M [3]." Combine as [1][4]. Only cite numbers that exist. Use **bold** for at \
        most two key terms.
        - When a previous summary is given, update it: keep wording that is still true, add what the NEW items \
        say, drop what they overturn.
        - keyFacts: up to 8 short, durable facts (numbers, roles, dates, decisions, agreements), each with the \
        item numbers that state it.
        - openQuestions: up to 5 things the items leave open: questions asked and not answered, decisions not \
        yet made, promises with no outcome yet. Each is a short question. Empty when there are none.
        - disagreements: where items contradict each other about the same thing (a number, date, decision or \
        owner), one line each naming both versions with their dates, like "Seed target: $1.5M in the board \
        deck (Tue 6 Oct 2026) vs $2M after the Harbor Capital meeting (Thu 8 Oct 2026)", citing both items. \
        Empty when the items agree.
        - Facts confirmed by the user are true: never contradict or repeat them.
        - Write absolute dates ("Mon 5 Oct 2026"), never "today", "yesterday" or "last week".

        \(MemoryPrompts.context(profile: profile, lenses: lenses))
        \(lensLine(lenses))
        """
    }

    /// The entity, the previous page (citations renumbered to this prompt), the user's kept facts and the
    /// numbered items (oldest first, NEW marked).
    public static func synthesisPrompt(entity: BrainEntity, parentName: String?, items: [MemoryItem], newSince: Date?,
                                       vocabulary: LensVocabulary, now: Date) -> String {
        var out = "\(entity.kind.label(vocabulary)): \(entity.name)"
        let others = entity.aliases.filter { TextFold.fold($0) != TextFold.fold(entity.name) }.prefix(6)
        if !others.isEmpty { out += " (also written: " + others.joined(separator: ", ") + ")" }
        out += "\n"
        if let parentName { out += "Part of: \(parentName)\n" }
        if !entity.detail.isEmpty { out += "Covers: \(entity.detail)\n" }
        let numbers = Dictionary(items.enumerated().map { ($1.id, $0 + 1) }, uniquingKeysWith: { a, _ in a })
        if !entity.summary.isEmpty && !entity.summaryEditedByUser {
            let previous = remapCitations(entity.summary) { n in entity.summarySource(n).flatMap { numbers[$0] } }
            out += "\nPrevious summary (update it):\n\(previous)\n"
        }
        let kept = entity.keyFacts.filter(\.isKept)
        if !kept.isEmpty {
            out += "\nFacts confirmed by the user:\n" + kept.map { "- \($0.text)" }.joined(separator: "\n") + "\n"
        }
        if entity.summaryEditedByUser && !entity.summary.isEmpty {
            out += "\nThe user's own summary (true; don't repeat it):\n\(remapCitations(entity.summary) { _ in nil })\n"
        }
        out += "\nItems (oldest first\(newSince == nil ? "" : "; NEW = saved since the page was last written")):\n"
        var budget = 22_000
        for (i, item) in items.enumerated() {
            var block = MemoryPrompts.sourceBlock(item, number: i + 1, now: now, excerptLimit: budget > 8000 ? 900 : 300)
            if let newSince, item.createdAt > newSince || item.updatedAt > newSince { block = block.replacingOccurrences(of: "[\(i + 1)] ", with: "[\(i + 1)] NEW ", options: .anchored) }
            out += block + "\n\n"
            budget -= block.count
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static let synthesisSchema: MemoryJSON = MemoryJSON.Schema.object([
        "summary": MemoryJSON.Schema.string("2–5 sentences with [n] citations"),
        "keyFacts": MemoryJSON.Schema.array(MemoryJSON.Schema.object([
            "text": MemoryJSON.Schema.string(),
            "sources": MemoryJSON.Schema.array(MemoryJSON.Schema.integer, maxItems: 6),
        ]), maxItems: 8),
        "openQuestions": MemoryJSON.Schema.array(MemoryJSON.Schema.string(), maxItems: 5),
        "disagreements": MemoryJSON.Schema.array(MemoryJSON.Schema.object([
            "text": MemoryJSON.Schema.string(),
            "sources": MemoryJSON.Schema.array(MemoryJSON.Schema.integer, maxItems: 6),
        ]), maxItems: 4),
    ])

    /// A synthesis answer mapped to item ids.
    public struct SynthesisAnswer: Equatable, Sendable {
        /// Citations renumbered 1…k in order of first use; [n] → `summarySources[n-1]`.
        public var summary: String
        public var summarySources: [UUID]
        public var keyFacts: [CitedText]
        public var openQuestions: [String]
        public var disagreements: [CitedText]
    }

    /// Parses a synthesis answer. Facts and disagreements without a valid source are dropped (no source, no claim).
    public static func parseSynthesis(_ data: Data, items: [MemoryItem]) throws -> SynthesisAnswer {
        struct Raw: Decodable {
            struct Cited: Decodable { var text: String?; var sources: [Int]? }
            var summary: String?
            var keyFacts: [Cited]?
            var openQuestions: [String]?
            var disagreements: [Cited]?
        }
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data), let summary = raw.summary else {
            throw MemoryAIError.badResponse(MemoryAIError.unexpectedFormat)
        }
        let ids = items.map(\.id)
        let compact = compactCitations(summary.trimmingCharacters(in: .whitespacesAndNewlines), count: ids.count)
        func cited(_ list: [Raw.Cited]?, limit: Int) -> [CitedText] {
            var out: [CitedText] = []
            var seen = Set<String>()
            for c in list ?? [] {
                let text = stripCitations((c.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
                var sources: [UUID] = []
                for n in c.sources ?? [] where n >= 1 && n <= ids.count && !sources.contains(ids[n - 1]) { sources.append(ids[n - 1]) }
                guard !text.isEmpty, !sources.isEmpty, seen.insert(TextFold.words(text).joined(separator: " ")).inserted else { continue }
                out.append(CitedText(text: text, itemIDs: sources))
                if out.count == limit { break }
            }
            return out
        }
        var questions: [String] = []
        for q in raw.openQuestions ?? [] {
            let t = stripCitations(q.trimmingCharacters(in: .whitespacesAndNewlines))
            if !t.isEmpty, !questions.contains(where: { TextFold.fold($0) == TextFold.fold(t) }) { questions.append(t) }
            if questions.count == 5 { break }
        }
        return SynthesisAnswer(summary: compact.text, summarySources: compact.order.map { ids[$0 - 1] },
                               keyFacts: cited(raw.keyFacts, limit: 8), openQuestions: questions,
                               disagreements: cited(raw.disagreements, limit: 4))
    }

    // MARK: Connections

    public static func connectionsSystem(lenses: [Lens], now: Date) -> String {
        """
        You point out links the user may not have made between pairs of their saved memories that sit in \
        different parts of their work.

        \(MemoryPrompts.today(now))

        Rules:
        - For each pair, one plain sentence (at most 20 words) naming the concrete idea that links the two items \
        and why it could be useful. Use only what the two items say.
        - If there is no meaningful link, the reason is "".
        - Write absolute dates if you mention one. No preamble.
        \(lensLine(lenses))
        """
    }

    public static func connectionsPrompt(_ pairs: [(MemoryItem, MemoryItem)]) -> String {
        var out = "Pairs:\n"
        for (i, pair) in pairs.enumerated() {
            out += "\(i + 1).\n   A: " + sampleLine(pair.0, gistLimit: 260) + "\n   B: " + sampleLine(pair.1, gistLimit: 260) + "\n"
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static let connectionsSchema: MemoryJSON = MemoryJSON.Schema.object([
        "links": MemoryJSON.Schema.array(MemoryJSON.Schema.object([
            "pair": MemoryJSON.Schema.integer,
            "reason": MemoryJSON.Schema.string(),
        ])),
    ])

    /// Pair number (1-based) → reason ("" = no link).
    public static func parseConnections(_ data: Data, count: Int) throws -> [Int: String] {
        struct Raw: Decodable {
            struct Link: Decodable { var pair: Int?; var reason: String? }
            var links: [Link]?
        }
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data), let links = raw.links else {
            throw MemoryAIError.badResponse(MemoryAIError.unexpectedFormat)
        }
        var out: [Int: String] = [:]
        for l in links {
            guard let n = l.pair, n >= 1, n <= count, out[n] == nil else { continue }
            out[n] = TextFold.cap((l.reason ?? "").trimmingCharacters(in: .whitespacesAndNewlines), 200)
        }
        return out
    }

    // MARK: Weekly digest

    public static func digestSystem(lenses: [Lens], profile: MemoryProfile, now: Date) -> String {
        """
        You write the user's weekly digest of what went into their memory, under the heading they already see \
        ("What you learned, 5–11 Oct"). Work only from the week's facts and numbered items in the message.

        \(MemoryPrompts.today(now))

        Rules:
        - 3–6 short "- " bullets, most important first: what they learned, what was decided, what is owed and \
        when, and one link worth noticing when given. No heading, no preamble, no sign-off.
        - Cite items with [n] right after the claim. Only cite numbers that exist. Never invent anything.
        - Write absolute dates ("Mon 5 Oct 2026"), never "today", "tomorrow" or "next week".

        \(MemoryPrompts.context(profile: profile, lenses: lenses))
        \(lensLine(lenses))
        """
    }

    public static func digestPrompt(_ digest: BrainDigest, items: [MemoryItem], now: Date) -> String {
        let end = digest.weekEnd.addingTimeInterval(-1)
        var out = "Week: \(MemoryDates.prompt(digest.weekStart)) – \(MemoryDates.prompt(end)). \(digest.itemCount) items saved.\n"
        if !digest.newTopics.isEmpty { out += "New topics: " + digest.newTopics.map(\.name).joined(separator: ", ") + "\n" }
        if !digest.biggestTopics.isEmpty {
            out += "Busiest topics: " + digest.biggestTopics.map { "\($0.name) (\($0.count))" }.joined(separator: ", ") + "\n"
        }
        let numbers = Dictionary(items.enumerated().map { ($1.id, $0 + 1) }, uniquingKeysWith: { a, _ in a })
        func ref(_ id: UUID) -> String { numbers[id].map { " [\($0)]" } ?? "" }
        if !digest.decisions.isEmpty {
            out += "Decisions:\n" + digest.decisions.map { "- \($0.text)\(ref($0.itemID))" }.joined(separator: "\n") + "\n"
        }
        if !digest.openPromises.isEmpty {
            out += "Open promises:\n" + digest.openPromises.map { m in
                var line = "- \(m.text)"
                if let who = m.who { line += " (\(who))" }
                if let due = m.due { line += ", due \(MemoryDates.prompt(due))" }
                return line + ref(m.itemID)
            }.joined(separator: "\n") + "\n"
        }
        if let c = digest.connection { out += "A link: \(c.reason)\(ref(c.a))\(ref(c.b))\n" }
        out += "\nItems:\n"
        for (i, item) in items.enumerated() {
            out += MemoryPrompts.sourceBlock(item, number: i + 1, now: now, excerptLimit: 300) + "\n\n"
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static let digestSchema: MemoryJSON = MemoryJSON.Schema.object([
        "text": MemoryJSON.Schema.string("3–6 \"- \" bullets with [n] citations"),
    ])

    public static func parseDigest(_ data: Data, items: [MemoryItem]) throws -> (text: String, sources: [UUID]) {
        struct Raw: Decodable { var text: String? }
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data), let text = raw.text else {
            throw MemoryAIError.badResponse(MemoryAIError.unexpectedFormat)
        }
        let compact = compactCitations(text.trimmingCharacters(in: .whitespacesAndNewlines), count: items.count)
        return (compact.text, compact.order.map { items[$0 - 1].id })
    }

    // MARK: Citations

    /// Rewrites `[n]` markers: `map(n)` gives the new number, or nil to drop the marker.
    public static func remapCitations(_ text: String, _ map: (Int) -> Int?) -> String {
        var out = ""
        var i = text.startIndex
        while i < text.endIndex {
            if text[i] == "[", let close = text[i...].firstIndex(of: "]"), close > text.index(after: i),
               text.distance(from: i, to: close) <= 5, let n = Int(text[text.index(after: i)..<close]) {
                if let m = map(n) {
                    out += "[\(m)]"
                } else {
                    // Drop the marker and a space before it.
                    if out.hasSuffix(" ") { out.removeLast() }
                }
                i = text.index(after: close)
            } else {
                out.append(text[i])
                i = text.index(after: i)
            }
        }
        return out
    }

    /// Keeps valid markers (1…count), renumbered 1…k in order of first use. `order[k-1]` is the original number.
    public static func compactCitations(_ text: String, count: Int) -> (text: String, order: [Int]) {
        var order: [Int] = []
        let rewritten = remapCitations(text) { n in
            guard n >= 1, n <= count else { return nil }
            if let i = order.firstIndex(of: n) { return i + 1 }
            order.append(n)
            return order.count
        }
        return (rewritten, order)
    }

    /// The text without any [n] markers.
    public static func stripCitations(_ text: String) -> String {
        remapCitations(text) { _ in nil }.trimmingCharacters(in: .whitespaces)
    }
}
