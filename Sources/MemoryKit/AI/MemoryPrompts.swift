import Foundation

/// Every prompt and answer schema MemoryKit sends, in one place. Each prompt states today's date as an
/// absolute date and asks for absolute dates back, includes the user's lens guidance and profile, and
/// asks for JSON that follows a schema with every field required.
public enum MemoryPrompts {
    // MARK: Shared context

    /// "Today is Fri 9 Oct 2026 (2026-10-09)."
    static func today(_ now: Date) -> String {
        "Today is \(MemoryDates.prompt(now)) (\(MemoryDates.dayKey(now)))."
    }

    static func context(profile: MemoryProfile, lenses: [Lens]) -> String {
        var out = "What the user does:\n" + Lens.guidance(for: lenses)
        let facts = profile.promptLines
        if !facts.isEmpty {
            out += "\n\nWhat is known about the user (context, not a source of facts about the item):\n" + facts
        }
        return out
    }

    // MARK: Extraction

    /// The system instruction for turning one item into summary, people, projects and moments.
    /// `vocabulary` (from `MemoryBrain.extractionVocabulary()`) lists the names already in memory so new
    /// items reuse them ("Pricing", not "pricing strategy" one day and "Pricing" the next).
    public static func extractionSystem(lenses: [Lens], profile: MemoryProfile, now: Date,
                                        vocabulary: ExtractionVocabulary? = nil) -> String {
        let known = vocabulary.map { $0.promptSection } ?? ""
        return """
        You file things into the user's personal memory. From one saved item, extract what they would want \
        to find again. Work only from the item; never add facts, names or numbers it doesn't contain.

        \(today(now))

        Rules:
        - title: specific and short (max 8 words), the gist rather than the format ("Pricing call with \
        Northwind", not "Meeting notes"). Keep the user's title if they gave one.
        - summary: 1–2 plain sentences on what it is and why it matters.
        - keyTakeaways: up to 5 short, concrete points (numbers, names, conclusions). Empty for trivial items.
        - people: full names as written; never the user themself. projects: named initiatives, products, \
        deals, campaigns or works. organisations: companies, investors, customers, vendors, schools or \
        institutions named, by their usual short name ("Acme", not "Acme Inc."). topics: 1–5 broad subjects \
        in Title Case ("Pricing", "Hiring"). tags: 0–5 lowercase single words or hyphenated phrases.
        - moments, only when clearly present: "decision" (something decided), "promise" (someone committed to \
        do something), "idea" (a proposal or possibility), "insight" (a learning, finding or reference worth \
        keeping). Each moment's text is one self-contained sentence. For promises set who (the person who \
        promised; "" when it is the user), direction ("mine" if the user owes it, "theirs" if owed to the \
        user) and due as YYYY-MM-DD when a date is stated or implied; resolve relative dates ("Friday", \
        "next week") against the date the item was saved. Otherwise due is "" and direction is "none".
        - extractedText: for an attached image, PDF, audio or video, the transcript (speech, verbatim) or \
        a faithful description including any visible text; "" when the item is already text.
        - Always write absolute dates ("Mon 12 Oct 2026"), never "today", "tomorrow" or "next week".
        \(known)
        \(context(profile: profile, lenses: lenses))
        """
    }

    /// The user turn: the item's facts and content.
    public static func extractionPrompt(for item: MemoryItem, content: String, attachmentNote: String?) -> String {
        var lines = ["Saved: \(MemoryDates.prompt(item.createdAt)) (\(MemoryDates.dayKey(item.createdAt)))",
                     "Kind: \(item.kind.label)"]
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { lines.append("Title given by the user: \(title)") }
        if let url = item.url { lines.append("URL: \(url)") }
        if let from = item.capturedFrom, !from.isEmpty { lines.append("Captured from: \(from)") }
        if !item.people.isEmpty { lines.append("People already linked: \(item.people.joined(separator: ", "))") }
        if !item.tags.isEmpty { lines.append("User's tags: \(item.tags.joined(separator: ", "))") }
        if let attachmentNote { lines.append(attachmentNote) }
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append("")
        lines.append(text.isEmpty ? "(No text: work from the attached file.)" : "Content:\n\(text)")
        return lines.joined(separator: "\n")
    }

    public static let extractionSchema: MemoryJSON = MemoryJSON.Schema.object([
        "title": MemoryJSON.Schema.string(),
        "summary": MemoryJSON.Schema.string(),
        "keyTakeaways": MemoryJSON.Schema.array(MemoryJSON.Schema.string(), maxItems: 5),
        "people": MemoryJSON.Schema.array(MemoryJSON.Schema.string(), maxItems: 20),
        "projects": MemoryJSON.Schema.array(MemoryJSON.Schema.string(), maxItems: 10),
        "organisations": MemoryJSON.Schema.array(MemoryJSON.Schema.string(), maxItems: 10),
        "topics": MemoryJSON.Schema.array(MemoryJSON.Schema.string(), maxItems: 5),
        "tags": MemoryJSON.Schema.array(MemoryJSON.Schema.string(), maxItems: 5),
        "moments": MemoryJSON.Schema.array(MemoryJSON.Schema.object([
            "kind": MemoryJSON.Schema.string(enum: ["decision", "promise", "idea", "insight"]),
            "text": MemoryJSON.Schema.string(),
            "who": MemoryJSON.Schema.string("Who decided or promised; \"\" for the user or unknown"),
            "due": MemoryJSON.Schema.string("YYYY-MM-DD or \"\""),
            "direction": MemoryJSON.Schema.string(enum: ["mine", "theirs", "none"]),
        ]), maxItems: 12),
        "extractedText": MemoryJSON.Schema.string(),
    ])

    /// Gemini's extraction answer, decoded leniently (missing arrays are empty).
    public struct Extraction: Decodable, Equatable, Sendable {
        public struct RawMoment: Decodable, Equatable, Sendable {
            public var kind: String
            public var text: String
            public var who: String
            public var due: String
            public var direction: String

            private enum CodingKeys: String, CodingKey { case kind, text, who, due, direction }
            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                kind = c.value(.kind, default: "insight")
                text = c.value(.text, default: "")
                who = c.value(.who, default: "")
                due = c.value(.due, default: "")
                direction = c.value(.direction, default: "none")
            }
        }

        public var title: String
        public var summary: String
        public var keyTakeaways: [String]
        public var people: [String]
        public var projects: [String]
        public var organisations: [String]
        public var topics: [String]
        public var tags: [String]
        public var moments: [RawMoment]
        public var extractedText: String

        private enum CodingKeys: String, CodingKey { case title, summary, keyTakeaways, people, projects, organisations, topics, tags, moments, extractedText }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            title = c.value(.title, default: "")
            summary = c.value(.summary, default: "")
            keyTakeaways = c.value(.keyTakeaways, default: [])
            people = c.value(.people, default: [])
            projects = c.value(.projects, default: [])
            organisations = c.value(.organisations, default: [])
            topics = c.value(.topics, default: [])
            tags = c.value(.tags, default: [])
            moments = c.value(.moments, default: [])
            extractedText = c.value(.extractedText, default: "")
        }

        /// Moments as stored, dropping empty ones. Keeps `done` (and the id) from `previous` moments with the same text.
        public func moments(keeping previous: [Moment]) -> [Moment] {
            moments.compactMap { raw in
                let text = raw.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, let kind = MomentKind(rawValue: raw.kind.lowercased()) else { return nil }
                let who = raw.who.trimmingCharacters(in: .whitespacesAndNewlines)
                var m = Moment(kind: kind, text: text, who: who.isEmpty ? nil : who)
                if kind == .promise {
                    m.due = MemoryDates.day(from: raw.due)
                    m.direction = PromiseDirection(rawValue: raw.direction.lowercased()) ?? (who.isEmpty ? .mine : .theirs)
                }
                if let old = previous.first(where: { TextFold.fold($0.text) == TextFold.fold(text) && $0.kind == kind }) {
                    m.id = old.id
                    m.done = old.done
                }
                return m
            }
        }
    }

    // MARK: Ask

    /// The rules for answering from numbered sources only.
    public static func askSystem(lenses: [Lens], profile: MemoryProfile, now: Date) -> String {
        """
        You answer the user's questions from their own saved memory: the numbered sources in the message. \
        You have no other knowledge of their life or work.

        \(today(now))

        Rules:
        - Use ONLY the sources. Never use outside knowledge, never guess, never invent names, numbers, dates \
        or quotes.
        - Cite every claim with the source number in square brackets right after it, like "The launch moved \
        to Fri 13 Nov 2026 [2]." Combine as [1][3]. Only cite numbers that exist.
        - If the sources don't answer the question, say so plainly in one sentence (for example "Your memory \
        doesn't say when the contract renews.") and set answerable to false. If they answer part of it, \
        answer that part and say what's missing.
        - Lead with the answer in 1–3 sentences; use short "- " bullets only for lists. No preamble, no \
        restating the question.
        - Write absolute dates ("Mon 5 Oct 2026"), never "today", "yesterday" or "last week".
        - citations: one entry per source you used, with a short exact quote from it that supports the claim.
        - followUps: 2–3 short questions the user could ask next that these sources could answer.

        \(context(profile: profile, lenses: lenses))
        """
    }

    /// The question, recent conversation and numbered sources.
    public static func askPrompt(question: String, history: [AskTurn], sources: [MemoryItem], now: Date) -> String {
        var out = ""
        let recent = history.suffix(4)
        if !recent.isEmpty {
            out += "Conversation so far (for context; cite only the sources below):\n"
            for turn in recent {
                out += "User: \(TextFold.cap(turn.question, 400))\nYou: \(TextFold.cap(turn.answer, 800))\n"
            }
            out += "\n"
        }
        out += "Question: \(question.trimmingCharacters(in: .whitespacesAndNewlines))\n\nSources:\n"
        var budget = 24_000
        for (i, item) in sources.enumerated() {
            let block = sourceBlock(item, number: i + 1, now: now, excerptLimit: budget > 6000 ? 1500 : 500)
            out += block + "\n\n"
            budget -= block.count
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One numbered source: title, kind, absolute date, people and projects, summary, takeaways,
    /// moments and an excerpt of the body.
    static func sourceBlock(_ item: MemoryItem, number: Int, now: Date, excerptLimit: Int) -> String {
        var head = "[\(number)] \"\(item.displayTitle)\" — \(item.kind.label.lowercased()), \(MemoryDates.prompt(item.createdAt))"
        if !item.people.isEmpty { head += " · people: \(item.people.prefix(8).joined(separator: ", "))" }
        if !item.projects.isEmpty { head += " · projects: \(item.projects.prefix(5).joined(separator: ", "))" }
        if !item.organisations.isEmpty { head += " · organisations: \(item.organisations.prefix(5).joined(separator: ", "))" }
        if let from = item.capturedFrom, !from.isEmpty { head += " · from: \(from)" }
        var lines = [head]
        if !item.summary.isEmpty { lines.append("Summary: \(item.summary)") }
        if !item.keyTakeaways.isEmpty { lines.append("Takeaways: " + item.keyTakeaways.joined(separator: "; ")) }
        for m in item.moments.prefix(8) {
            var line = "\(m.kind.rawValue.capitalized): \(m.text)"
            var extra: [String] = []
            if let who = m.who { extra.append(who) }
            if let due = m.due { extra.append("due \(MemoryDates.prompt(due))") }
            if m.done { extra.append("done") }
            if !extra.isEmpty { line += " (\(extra.joined(separator: ", ")))" }
            lines.append(line)
        }
        let body = TextFold.tidy(item.fullText)
        if !body.isEmpty { lines.append("Excerpt: " + TextFold.cap(body, excerptLimit)) }
        return lines.joined(separator: "\n")
    }

    public static let askSchema: MemoryJSON = MemoryJSON.Schema.object([
        "answer": MemoryJSON.Schema.string("The answer with [n] citations"),
        "answerable": MemoryJSON.Schema.boolean,
        "citations": MemoryJSON.Schema.array(MemoryJSON.Schema.object([
            "source": MemoryJSON.Schema.integer,
            "quote": MemoryJSON.Schema.string(),
        ]), maxItems: 12),
        "followUps": MemoryJSON.Schema.array(MemoryJSON.Schema.string(), maxItems: 3),
    ])

    // MARK: Profile

    public static func profileSystem(lenses: [Lens], now: Date) -> String {
        """
        You maintain a short, living profile of the user, distilled from their saved memory: who they are, \
        their role and work, active projects, the people who matter to them, goals, interests and how they \
        like to communicate. It is used as background for every answer an assistant gives them.

        \(today(now))

        Rules:
        - Each fact is one short sentence about the user ("Runs a 12-person design studio in Lisbon"), \
        grounded in the memories. No generic filler, no guesses about private matters (health, religion, \
        politics, relationships) unless the user wrote them down as facts about themself.
        - Facts confirmed by the user are true: never contradict or repeat them.
        - Keep previous facts that are still supported; revise what changed; drop what no longer holds.
        - At most 20 facts. Write absolute dates when a date matters ("since Mar 2026").
        - category is one of: identity, role, work, project, person, goal, interest, preference, style, other.

        What the user does:
        \(Lens.guidance(for: lenses))
        """
    }

    public static func profilePrompt(confirmed: [ProfileFact], previous: [ProfileFact], items: [MemoryItem]) -> String {
        var out = ""
        if !confirmed.isEmpty {
            out += "Facts confirmed by the user:\n" + confirmed.map { "- \($0.text)" }.joined(separator: "\n") + "\n\n"
        }
        if !previous.isEmpty {
            out += "Previous profile facts (update these):\n" + previous.map { "- [\($0.category.rawValue)] \($0.text)" }.joined(separator: "\n") + "\n\n"
        }
        out += "Their \(items.count) most recent and important memories:\n"
        out += items.map { item in
            var line = "- [\(item.kind.label)] \(item.displayTitle) (\(MemoryDates.prompt(item.createdAt)))"
            let gist = item.summary.isEmpty ? TextFold.tidy(item.fullText) : item.summary
            if !gist.isEmpty { line += ": " + TextFold.cap(gist.replacingOccurrences(of: "\n", with: " "), 220) }
            if !item.people.isEmpty { line += " · people: " + item.people.prefix(5).joined(separator: ", ") }
            if !item.projects.isEmpty { line += " · projects: " + item.projects.prefix(4).joined(separator: ", ") }
            return line
        }.joined(separator: "\n")
        return out
    }

    public static let profileSchema: MemoryJSON = MemoryJSON.Schema.object([
        "facts": MemoryJSON.Schema.array(MemoryJSON.Schema.object([
            "text": MemoryJSON.Schema.string(),
            "category": MemoryJSON.Schema.string(enum: ProfileFact.Category.allCases.map(\.rawValue)),
        ]), maxItems: 20),
    ])
}

// MARK: - Vocabulary for extraction

/// The names already in the user's memory, given to extraction so new items reuse them: topic names from
/// the brain's taxonomy, the most used tags, and canonical spellings of people, projects and organisations.
/// Build it with `MemoryBrain.extractionVocabulary()`; give `MemoryProcessor.vocabulary` a closure returning it.
public struct ExtractionVocabulary: Hashable, Sendable {
    public var topics: [String]
    public var tags: [String]
    public var people: [String]
    public var projects: [String]
    public var organisations: [String]

    public init(topics: [String] = [], tags: [String] = [], people: [String] = [], projects: [String] = [], organisations: [String] = []) {
        self.topics = topics
        self.tags = tags
        self.people = people
        self.projects = projects
        self.organisations = organisations
    }

    public var isEmpty: Bool { topics.isEmpty && tags.isEmpty && people.isEmpty && projects.isEmpty && organisations.isEmpty }

    /// Caps for the prompt (most important first; the caller orders them).
    static let limits = (topics: 40, tags: 30, people: 40, projects: 30, organisations: 25)

    /// The rules block added to the extraction prompt ("" when empty).
    var promptSection: String {
        guard !isEmpty else { return "" }
        func line(_ label: String, _ names: [String], _ limit: Int) -> String? {
            let list = TextFold.uniqueNames(names, limit: limit)
            return list.isEmpty ? nil : "- \(label): " + list.joined(separator: "; ")
        }
        let lines = [
            line("Topics", topics, Self.limits.topics),
            line("Tags", tags, Self.limits.tags),
            line("People", people, Self.limits.people),
            line("Projects", projects, Self.limits.projects),
            line("Organisations", organisations, Self.limits.organisations),
        ].compactMap { $0 }
        return """

        Names already in the user's memory. Reuse the exact spelling when the item is about the same thing \
        ("Rohan" in the text is "Rohan Mehta" if that is clearly who it means); use a topic from this list \
        whenever one fits and add a new topic only for a genuinely new subject; prefer these tags over \
        synonyms. Never add a name the item doesn't mention.
        \(lines.joined(separator: "\n"))

        """
    }
}
