import Foundation

// Search across every task and note. Case and accents don't matter, every word has to match somewhere,
// "quoted phrases" match as written and #tag filters by tag. Each item's text is kept folded (lowercase,
// accent-free UTF-8) between searches and refolded only when the item changes, so a search over 10,000
// tasks takes a few milliseconds and typing stays instant.

// MARK: - Query

/// What was typed in the search field, split into the parts that have to match.
struct SearchQuery: Equatable {
    struct Term: Equatable {
        /// Folded text: "cafe" for “Café”.
        let text: String
        let bytes: [UInt8]
        let isPhrase: Bool
    }

    /// Words and "quoted phrases" in the order typed. Every one has to appear somewhere.
    private(set) var terms: [Term] = []
    /// #tags, without the #. A task needs a tag that starts with each one; a note has to mention it.
    private(set) var tags: [Term] = []
    /// All the words and phrases as one run ("board deck"), so "the title starts with what I typed" ranks first.
    private(set) var run: [UInt8] = []

    init(_ text: String) {
        var token = ""
        var quoted = false
        for ch in text {
            if Self.quoteMarks.contains(ch) {
                if quoted { addPhrase(token) } else { addWord(token) }
                token = ""
                quoted.toggle()
            } else if !quoted, ch.isWhitespace {
                addWord(token)
                token = ""
            } else {
                token.append(ch)
            }
        }
        // An unclosed quote is a phrase still being typed.
        if quoted { addPhrase(token) } else { addWord(token) }
        run = SearchText.bytes(terms.map(\.text).joined(separator: " "))
    }

    var isEmpty: Bool { terms.isEmpty && tags.isEmpty }
    var words: [String] { terms.filter { !$0.isPhrase }.map(\.text) }
    var phrases: [String] { terms.filter(\.isPhrase).map(\.text) }
    var tagNames: [String] { tags.map(\.text) }

    /// Straight and typographic quotes (the field may turn " into “ ”).
    private static let quoteMarks: Set<Character> = ["\"", "“", "”", "„", "«", "»"]
    /// Stripped from the ends of a word: "board," finds "board".
    private static let edgePunctuation = CharacterSet(charactersIn: ".,;:!?()[]{}<>\"'“”‘’«»„…")

    private mutating func addWord(_ token: String) {
        let word = token.trimmingCharacters(in: Self.edgePunctuation)
        if word.hasPrefix("#") {
            let tag = SearchText.fold(String(word.drop { $0 == "#" }))
            if !tag.isEmpty { tags.append(Term(text: tag, bytes: Array(tag.utf8), isPhrase: false)) }
        } else {
            let folded = SearchText.fold(word)
            if !folded.isEmpty { terms.append(Term(text: folded, bytes: Array(folded.utf8), isPhrase: false)) }
        }
    }

    private mutating func addPhrase(_ token: String) {
        let folded = SearchText.fold(token)
        if !folded.isEmpty { terms.append(Term(text: folded, bytes: Array(folded.utf8), isPhrase: true)) }
    }
}

// MARK: - Results

/// What the Search view lists for a query.
struct SearchResults {
    var query: SearchQuery
    /// Open tasks, best match first. Tasks ticked a moment ago stay here briefly so the list doesn't jump.
    var tasks: [TaskItem] = []
    /// Finished tasks, newest first, at most `Store.searchCompletedLimit`.
    var completed: [TaskItem] = []
    /// Every finished task that matched, including the ones past the limit.
    var completedTotal = 0
    /// Notes, best match first.
    var notes: [Note] = []

    var isEmpty: Bool { tasks.isEmpty && completed.isEmpty && notes.isEmpty }

    /// Task ids in the order the Search view lists them (open, then finished): for ↑/↓, ⇧-click ranges and ⌘A.
    var taskOrder: [UUID] { tasks.map(\.id) + completed.map(\.id) }

    /// "3 tasks · 2 completed · 1 note", or nil when nothing matched.
    var summary: String? {
        let open = tasks.filter { !$0.isCompleted }.count
        let done = completedTotal + (tasks.count - open)
        var parts: [String] = []
        if open > 0 { parts.append(Fmt.plural(open, "task")) }
        if done > 0 { parts.append("\(done) completed") }
        if !notes.isEmpty { parts.append(Fmt.plural(notes.count, "note")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

extension Store {
    /// How many finished tasks a search lists (newest first).
    static let searchCompletedLimit = 50

    /// Searches every task (title, notes, tags, list, steps, waiting on, source) and note (title, body).
    /// Ranking: the title starts with it, then a word in the title starts with it, then it's inside the title,
    /// then it's only in another field. Open tasks come first, then finished ones, then notes.
    /// `keeping` lists tasks ticked a moment ago, which stay with the open ones for now.
    func search(_ query: String, keeping: Set<UUID> = [], now: Date = Date()) -> SearchResults {
        SearchIndex.shared.results(for: query, keeping: keeping, now: now, in: self)
    }
}

// MARK: - Folding

/// Text in the folded form that searches compare.
enum SearchText {
    static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]

    /// Lowercase, accent-free and width-normalised, each run of whitespace (line breaks too) as one space.
    static func fold(_ s: String) -> String {
        guard !s.isEmpty else { return "" }
        let folded = s.folding(options: options, locale: nil).precomposedStringWithCanonicalMapping
        var out = String.UnicodeScalarView()
        var pendingSpace = false
        for u in folded.unicodeScalars {
            if isSpace(u) {
                pendingSpace = !out.isEmpty
            } else {
                if pendingSpace { out.append(" ") }
                pendingSpace = false
                out.append(u)
            }
        }
        return String(out)
    }

    static func bytes(_ s: String) -> [UInt8] { Array(fold(s).utf8) }

    private static func isSpace(_ u: Unicode.Scalar) -> Bool {
        u.value < 0x80 ? (u == " " || (0x09...0x0D).contains(u.value)) : u.properties.isWhitespace
    }

    static func isWordCharacter(_ u: Unicode.Scalar) -> Bool {
        if u.value < 0x80 {
            let v = u.value
            return (0x30...0x39).contains(v) || (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v)
        }
        return u.properties.isAlphabetic || u.properties.numericType != nil
    }

    /// Byte offset of the first letter or digit (0 if there's none), so "“Board” prep" starts at "b".
    static func wordStartOffset(_ folded: String) -> Int {
        var offset = 0
        for u in folded.unicodeScalars {
            if isWordCharacter(u) { return offset }
            offset += UTF8.width(u)
        }
        return 0
    }
}

/// Byte-level matching on folded UTF-8.
private enum Bytes {
    /// Where `needle` first occurs in `hay` at or after `start`.
    static func find(_ needle: [UInt8], in hay: [UInt8], from start: Int = 0) -> Int? {
        let n = needle.count
        guard n > 0, start >= 0, hay.count - start >= n else { return nil }
        return hay.withUnsafeBytes { h -> Int? in
            needle.withUnsafeBytes { nd -> Int? in
                guard let base = h.baseAddress, let found = memmem(base + start, h.count - start, nd.baseAddress, n) else { return nil }
                return base.distance(to: UnsafeRawPointer(found))
            }
        }
    }

    static func contains(_ needle: [UInt8], in hay: [UInt8]) -> Bool { find(needle, in: hay) != nil }

    /// Whether position `i` begins a word: the start, or right after something that isn't a letter or digit.
    static func isWordStart(_ hay: [UInt8], at i: Int) -> Bool {
        guard i > 0, i <= hay.count else { return true }
        var j = i - 1
        while j > 0, (hay[j] & 0xC0) == 0x80 { j -= 1 }
        var decoder = UTF8()
        var bytes = hay[j..<i].makeIterator()
        if case .scalarValue(let u) = decoder.decode(&bytes) { return !SearchText.isWordCharacter(u) }
        return true
    }

    /// How a term sits in a title: 0 the title starts with it, 1 a word starts with it, 2 it's inside a word.
    /// `start` is where the title's first letter or digit is. Nil: it isn't in the title.
    static func titleTier(of term: [UInt8], in title: [UInt8], start: Int) -> Int? {
        var from = 0
        var tier: Int?
        while let i = find(term, in: title, from: from) {
            if i <= start { return 0 }
            // The leftmost word start is as good as it gets now: later ones can't start the title.
            if isWordStart(title, at: i) { return 1 }
            tier = 2
            from = i + 1
        }
        return tier
    }

    /// Whether `hay` mentions `#tag` (or a longer tag starting with it) as a hashtag, not inside a word or link.
    static func hasHashtag(_ tag: [UInt8], in hay: [UInt8]) -> Bool {
        let needle = [UInt8(ascii: "#")] + tag
        var from = 0
        while let i = find(needle, in: hay, from: from) {
            if isWordStart(hay, at: i) { return true }
            from = i + 1
        }
        return false
    }
}

// MARK: - Index

/// A task's searchable text, folded, plus the values it was made from (to notice when the task changes).
private struct TaskDoc {
    let title: String
    let notes: String
    let tags: [String]
    let subtasks: [Subtask]
    let waitingOn: String?
    let sourceLabel: String?

    let foldedTitle: [UInt8]
    let titleStart: Int
    /// Notes, tags, steps, waiting on and source, one per line so a phrase can't run from one into the next.
    let foldedRest: [UInt8]
    let foldedTags: [[UInt8]]

    init(_ t: TaskItem) {
        title = t.title
        notes = t.notes
        tags = t.tags
        subtasks = t.subtasks
        waitingOn = t.waitingOn
        sourceLabel = t.source?.label
        let folded = SearchText.fold(t.title)
        foldedTitle = Array(folded.utf8)
        titleStart = SearchText.wordStartOffset(folded)
        var rest = [t.notes] + t.tags + t.subtasks.map(\.title)
        if let w = t.waitingOn { rest.append(w) }
        if let label = t.source?.label { rest.append(label) }
        foldedRest = Array(rest.map(SearchText.fold).filter { !$0.isEmpty }.joined(separator: "\n").utf8)
        foldedTags = t.tags.map(SearchText.bytes)
    }

    /// Cheap: unchanged strings and arrays share storage, so these comparisons don't read the text.
    func isCurrent(for t: TaskItem) -> Bool {
        title == t.title && notes == t.notes && tags == t.tags && subtasks == t.subtasks
            && waitingOn == t.waitingOn && sourceLabel == t.source?.label
    }
}

private struct NoteDoc {
    let body: String
    let isBlank: Bool
    let foldedTitle: [UInt8]
    let titleStart: Int
    let foldedBody: [UInt8]

    init(_ n: Note) {
        body = n.body
        isBlank = n.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let folded = isBlank ? "" : SearchText.fold(n.title)
        foldedTitle = Array(folded.utf8)
        titleStart = SearchText.wordStartOffset(folded)
        // Photos read as "Photo: caption" rather than their file paths.
        foldedBody = isBlank ? [] : SearchText.bytes(Note.describingMedia(n.body))
    }
}

/// How well an item matched. Lower sorts first.
private struct Score: Comparable {
    /// The weakest word: 0 the title starts with it, 1 a title word starts with it, 2 inside the title, 3 elsewhere.
    var tier: Int
    /// The whole title is what was typed.
    var exact: Bool
    /// All the words' tiers added up: more of them in the title is better.
    var sum: Int

    static func < (a: Score, b: Score) -> Bool {
        (a.tier, a.exact ? 0 : 1, a.sum) < (b.tier, b.exact ? 0 : 1, b.sum)
    }
}

@MainActor
private final class SearchIndex {
    static let shared = SearchIndex()

    private var taskDocs: [UUID: TaskDoc] = [:]
    private var noteDocs: [UUID: NoteDoc] = [:]

    /// Everything a result depends on. Unchanged arrays compare in constant time.
    private struct Inputs: Equatable {
        var text: String
        var keeping: Set<UUID>
        var now: Date
        var tasks: [TaskItem]
        var notes: [Note]
        var lists: [TaskList]
    }

    /// The view, the arrow keys and the field all ask for the same results; work them out once.
    private var last: (inputs: Inputs, results: SearchResults)?

    func results(for text: String, keeping: Set<UUID>, now: Date, in store: Store) -> SearchResults {
        let inputs = Inputs(text: text, keeping: keeping, now: now, tasks: store.tasks, notes: store.notes, lists: store.lists)
        if let last, last.inputs == inputs { return last.results }
        let results = compute(SearchQuery(text), inputs, calendar: store.calendar)
        last = (inputs, results)
        return results
    }

    private func compute(_ query: SearchQuery, _ input: Inputs, calendar cal: Calendar) -> SearchResults {
        var results = SearchResults(query: query)
        guard !query.isEmpty else { return results }

        var listNames: [UUID: [UInt8]] = [:]
        for list in input.lists { listNames[list.id] = SearchText.bytes(list.name) }

        struct OpenMatch {
            var task: TaskItem
            var score: Score
            var overdue: Bool
            var when: Date
            var titleKey: [UInt8]
        }
        var open: [OpenMatch] = []
        var done: [TaskItem] = []
        for t in input.tasks {
            let doc = taskDoc(t)
            guard let score = Self.score(doc, listName: t.listID.flatMap { listNames[$0] }, query) else { continue }
            if t.isCompleted && !input.keeping.contains(t.id) {
                done.append(t)
            } else {
                open.append(OpenMatch(task: t, score: score, overdue: t.isOverdue(now: input.now, calendar: cal),
                                      when: Self.when(t, calendar: cal), titleKey: doc.foldedTitle))
            }
        }

        // Equally good matches: overdue first, then by the date shown on the row, priority, title.
        open.sort { a, b in
            if a.score != b.score { return a.score < b.score }
            if a.overdue != b.overdue { return a.overdue }
            if a.when != b.when { return a.when < b.when }
            if a.task.priority != b.task.priority { return a.task.priority > b.task.priority }
            if a.titleKey != b.titleKey { return a.titleKey.lexicographicallyPrecedes(b.titleKey) }
            return a.task.createdAt < b.task.createdAt
        }
        results.tasks = open.map(\.task)

        done.sort { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
        results.completedTotal = done.count
        results.completed = Array(done.prefix(Store.searchCompletedLimit))

        var notes: [(note: Note, score: Score)] = []
        for n in input.notes {
            let doc = noteDoc(n)
            guard !doc.isBlank, let score = Self.score(doc, query) else { continue }
            notes.append((n, score))
        }
        notes.sort { a, b in
            if a.score != b.score { return a.score < b.score }
            if a.note.isPinned != b.note.isPinned { return a.note.isPinned }
            return a.note.updatedAt > b.note.updatedAt
        }
        results.notes = notes.map(\.note)

        prune(input)
        return results
    }

    private func taskDoc(_ t: TaskItem) -> TaskDoc {
        if let doc = taskDocs[t.id], doc.isCurrent(for: t) { return doc }
        let doc = TaskDoc(t)
        taskDocs[t.id] = doc
        return doc
    }

    private func noteDoc(_ n: Note) -> NoteDoc {
        if let doc = noteDocs[n.id], doc.body == n.body { return doc }
        let doc = NoteDoc(n)
        noteDocs[n.id] = doc
        return doc
    }

    /// Forgets deleted items once there are enough of them to matter.
    private func prune(_ input: Inputs) {
        if taskDocs.count > input.tasks.count + 256 {
            let live = Set(input.tasks.map(\.id))
            taskDocs = taskDocs.filter { live.contains($0.key) }
        }
        if noteDocs.count > input.notes.count + 64 {
            let live = Set(input.notes.map(\.id))
            noteDocs = noteDocs.filter { live.contains($0.key) }
        }
    }

    /// The date the row shows (deadline, else plan date); timed deadlines at their time, others at the end of the day.
    private static func when(_ t: TaskItem, calendar cal: Calendar) -> Date {
        if let due = t.dueDate { return t.dueHasTime ? due : cal.endOfDay(for: due) }
        if let planned = t.scheduledDate { return cal.endOfDay(for: planned) }
        return .distantFuture
    }

    // MARK: Matching

    private static func score(_ doc: TaskDoc, listName: [UInt8]?, _ q: SearchQuery) -> Score? {
        for tag in q.tags where !doc.foldedTags.contains(where: { $0.starts(with: tag.bytes) }) { return nil }
        return score(title: doc.foldedTitle, start: doc.titleStart, q) { term in
            Bytes.contains(term, in: doc.foldedRest) || listName.map { Bytes.contains(term, in: $0) } == true
        }
    }

    private static func score(_ doc: NoteDoc, _ q: SearchQuery) -> Score? {
        for tag in q.tags where !Bytes.hasHashtag(tag.bytes, in: doc.foldedBody) { return nil }
        return score(title: doc.foldedTitle, start: doc.titleStart, q) { Bytes.contains($0, in: doc.foldedBody) }
    }

    /// Every word must be in the title or, failing that, somewhere in `elsewhere`.
    private static func score(title: [UInt8], start: Int, _ q: SearchQuery, elsewhere: ([UInt8]) -> Bool) -> Score? {
        var worst = 0, sum = 0
        for term in q.terms {
            if let tier = Bytes.titleTier(of: term.bytes, in: title, start: start) {
                worst = max(worst, tier)
                sum += tier
            } else if elsewhere(term.bytes) {
                worst = 3
                sum += 3
            } else {
                return nil
            }
        }
        // "board deck" finds "Board deck review" first: the title starts with everything typed, in order.
        var exact = false
        if q.terms.count > 1 || worst == 0, !q.run.isEmpty, let i = Bytes.find(q.run, in: title), i <= start {
            worst = 0
            exact = i + q.run.count == title.count
        }
        return Score(tier: worst, exact: exact, sum: sum)
    }
}

// MARK: - Highlights and excerpts

extension SearchQuery {
    /// What to look for in displayed text: the words and phrases, and #tags as written.
    private var needles: [String] { terms.map(\.text) + tags.map { "#" + $0.text } }

    /// Where the query's words, phrases and #tags appear in `text` (ignoring case and accents), merged, in order.
    func highlights(in text: String) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        for needle in needles {
            var from = text.startIndex
            while from < text.endIndex, let r = text.range(of: needle, options: SearchText.options, range: from..<text.endIndex) {
                guard !r.isEmpty else { break }
                found.append(r)
                from = r.upperBound
            }
        }
        found.sort { $0.lowerBound < $1.lowerBound }
        var merged: [Range<String.Index>] = []
        for r in found {
            if let last = merged.last, r.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, r.upperBound)
            } else {
                merged.append(r)
            }
        }
        return merged
    }

    /// A short excerpt of a note around its first match below the title line, without Markdown symbols,
    /// e.g. "…send the board deck to Priya by Friday". Nil when the match is only in the title.
    func snippet(in body: String, maxLength: Int = 150) -> String? {
        let needles = needles
        guard !needles.isEmpty else { return nil }
        let lines = body.split(separator: "\n", omittingEmptySubsequences: true)
        guard let titleLine = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return nil }
        for line in lines[(titleLine + 1)...] {
            let text = Self.plainLine(String(line))
            guard !text.isEmpty else { continue }
            let first = needles.compactMap { text.range(of: $0, options: SearchText.options) }.min { $0.lowerBound < $1.lowerBound }
            if let first { return Self.excerpt(text, around: first, maxLength: maxLength) }
        }
        return nil
    }

    /// One line of Markdown as plain text (the same clean-up as a note's preview).
    static func plainLine(_ line: String) -> String {
        Note.describingMedia(line.trimmingCharacters(in: .whitespaces))
            .replacingOccurrences(of: #"^(#{1,6}\s+|>\s?|(?:[-*+]|\d+[.)])\s+(\[[ xX]\]\s+)?)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(\*\*|__|`)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?<![\w*])[*_](\S(?:[^*_]*\S)?)[*_](?![\w*])"#, with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Cuts a long line to about `maxLength` characters, keeping the match near the start and words whole.
    static func excerpt(_ line: String, around match: Range<String.Index>, maxLength: Int) -> String {
        guard line.count > maxLength else { return line }
        var start = line.startIndex
        var lead = ""
        let context = maxLength / 4
        if line.distance(from: line.startIndex, to: match.lowerBound) > context {
            start = line.index(match.lowerBound, offsetBy: -context)
            // Begin at a word: skip the partial one.
            if let space = line[start..<match.lowerBound].firstIndex(where: \.isWhitespace) {
                start = line.index(after: space)
            }
            lead = "…"
        }
        // Never cut the match itself, even a long phrase.
        var end = max(line.index(start, offsetBy: maxLength, limitedBy: line.endIndex) ?? line.endIndex, match.upperBound)
        var trail = ""
        if end < line.endIndex {
            if match.upperBound < end, let space = line[match.upperBound..<end].lastIndex(where: \.isWhitespace) { end = space }
            trail = "…"
        }
        return lead + line[start..<end].trimmingCharacters(in: .whitespaces) + trail
    }
}
