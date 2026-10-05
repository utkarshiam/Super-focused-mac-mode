import Foundation

// Search across every task and note. Case, accents and curly apostrophes don't matter, every word has to
// match somewhere, "quoted phrases" match as written and #tag filters by tag. Each item's text is kept folded
// (lowercase, accent-free UTF-8) between searches and refolded only when the item changes, so a search over
// 10,000 tasks takes a few milliseconds and typing stays instant.

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

    /// Folds every task and note not folded yet, so the first letter typed doesn't wait for it. The search
    /// field calls this when it gets the cursor; after that it only folds what changed.
    func prepareSearch() {
        SearchIndex.shared.prepare(tasks: tasks, notes: notes)
    }
}

// MARK: - Folding

/// Text in the folded form that searches compare.
enum SearchText {
    static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]

    /// Curly apostrophes and single quotes (’ ‘ ʼ ′), which pasted and generated text is full of: they search
    /// as a straight ', so "sam's" finds “Sam’s”. Each is one UTF-16 unit, like ', so swapping one for the
    /// other keeps UTF-16 offsets (NSRange) lined up with the original text.
    static let apostrophes: Set<Unicode.Scalar> = ["\u{2018}", "\u{2019}", "\u{02BC}", "\u{2032}"]

    /// Lowercase, accent-free and width-normalised, apostrophes straight, each run of whitespace (line breaks
    /// too) as one space.
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
                out.append(apostrophes.contains(u) ? "'" : u)
            }
        }
        return String(out)
    }

    static func bytes(_ s: String) -> [UInt8] { Array(fold(s).utf8) }

    /// Where `needle` (folded text, as in a `SearchQuery`) appears in `text` as written, compared the way the
    /// search compares: ignoring case, accents and width, with curly apostrophes matching straight ones.
    /// Stops after `limit` matches.
    static func ranges(of needle: String, in text: String, limit: Int = .max) -> [Range<String.Index>] {
        guard !needle.isEmpty, !text.isEmpty, limit > 0 else { return [] }
        let hay = straightened(text)
        var found: [Range<String.Index>] = []
        var location = 0
        while location < hay.length {
            let match = hay.range(of: needle, options: options, range: NSRange(location: location, length: hay.length - location))
            // Offsets in `hay` are offsets in `text`: straightening never changes a UTF-16 length.
            guard match.location != NSNotFound, match.length > 0, let range = Range(match, in: text) else { break }
            found.append(range)
            if found.count >= limit { break }
            location = match.location + match.length
        }
        return found
    }

    /// `text` with curly apostrophes made straight, as NSString for searching by UTF-16 offset.
    private static func straightened(_ text: String) -> NSString {
        guard text.unicodeScalars.contains(where: apostrophes.contains) else { return text as NSString }
        var out = String.UnicodeScalarView()
        for u in text.unicodeScalars { out.append(apostrophes.contains(u) ? "'" : u) }
        return String(out) as NSString
    }

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

    /// Byte order, as memcmp: negative when `a` sorts first. Folded UTF-8 in byte order is folded text in
    /// code point order, a steady tie-breaker that's much quicker than comparing Strings.
    static func compare(_ a: [UInt8], _ b: [UInt8]) -> Int {
        let shared = min(a.count, b.count)
        let order = a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb -> Int32 in
                guard shared > 0, let x = pa.baseAddress, let y = pb.baseAddress else { return 0 }
                return memcmp(x, y, shared)
            }
        }
        if order != 0 { return Int(order) }
        return a.count == b.count ? 0 : (a.count < b.count ? -1 : 1)
    }

    /// The first 8 bytes as one big-endian number, zero-padded: two of these compare the way `compare` does,
    /// as far as they reach, so most comparisons are a single integer one.
    static func prefixKey(_ bytes: [UInt8]) -> UInt64 {
        var key: UInt64 = 0
        for i in 0..<8 { key = key << 8 | UInt64(i < bytes.count ? bytes[i] : 0) }
        return key
    }

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
    /// The folded title's first bytes as a number, for ordering equally good matches by title quickly.
    let titleKey: UInt64
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
        titleKey = Bytes.prefixKey(foldedTitle)
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

    /// The score, then overdue before not, as one number that sorts the same way (lower first), so most
    /// pairs of results are settled by a single comparison.
    func rank(overdue: Bool) -> UInt64 {
        UInt64(min(max(tier, 0), 3)) << 40 | UInt64(exact ? 0 : 1) << 39 | UInt64(min(max(sum, 0), 1 << 30)) << 1 | (overdue ? 0 : 1)
    }
}

/// An open task that matched, reduced to what orders it: sorting these instead of whole tasks keeps a search
/// that matches thousands of tasks quick.
private struct OpenMatch {
    /// Where the task is in the store's list.
    var index: Int
    var rank: UInt64
    /// The date the row shows (deadline, else plan date): timed deadlines at their time, others at the end of the day.
    var when: Date
    var priority: Priority
    var titleKey: UInt64
    var title: [UInt8]
    var createdAt: Date

    /// Best match first; equally good matches overdue first, then by the row's date, priority and title.
    static func precedes(_ a: OpenMatch, _ b: OpenMatch) -> Bool {
        if a.rank != b.rank { return a.rank < b.rank }
        if a.when != b.when { return a.when < b.when }
        if a.priority != b.priority { return a.priority > b.priority }
        if a.titleKey != b.titleKey { return a.titleKey < b.titleKey }
        let byTitle = Bytes.compare(a.title, b.title)
        if byTitle != 0 { return byTitle < 0 }
        if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
        return a.index < b.index
    }
}

@MainActor
private final class SearchIndex {
    static let shared = SearchIndex()

    private var taskDocs: [UUID: TaskDoc] = [:]
    private var noteDocs: [UUID: NoteDoc] = [:]
    /// Note excerpts already worked out, with the note text and query they're for.
    private var excerpts: [UUID: (body: String, needles: [String], text: String)] = [:]

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

        // Calendar math is slow next to everything else here, so it's done once per day, not once per task.
        let startOfToday = cal.startOfDay(for: input.now)
        var dayEnds: [Date: Date] = [:]
        func endOfDay(_ date: Date) -> Date {
            if let end = dayEnds[date] { return end }
            let end = cal.endOfDay(for: date)
            dayEnds[date] = end
            return end
        }

        var open: [OpenMatch] = []
        var done: [(index: Int, completedAt: Date)] = []
        for (index, t) in input.tasks.enumerated() {
            let doc = taskDoc(t)
            guard let score = Self.score(doc, listName: t.listID.flatMap { listNames[$0] }, query) else { continue }
            if let completedAt = t.completedAt, !input.keeping.contains(t.id) {
                done.append((index, completedAt))
                continue
            }
            // As `TaskItem.isOverdue`: a timed deadline that has passed, or a date-only one on an earlier day.
            let overdue = !t.isCompleted && t.dueDate.map { t.dueHasTime ? $0 < input.now : $0 < startOfToday } == true
            let when: Date
            if let due = t.dueDate {
                when = t.dueHasTime ? due : endOfDay(due)
            } else if let planned = t.scheduledDate {
                when = endOfDay(planned)
            } else {
                when = .distantFuture
            }
            open.append(OpenMatch(index: index, rank: score.rank(overdue: overdue), when: when, priority: t.priority,
                                  titleKey: doc.titleKey, title: doc.foldedTitle, createdAt: t.createdAt))
        }
        open.sort(by: OpenMatch.precedes)
        results.tasks = open.map { input.tasks[$0.index] }

        done.sort { $0.completedAt != $1.completedAt ? $0.completedAt > $1.completedAt : $0.index < $1.index }
        results.completedTotal = done.count
        results.completed = done.prefix(Store.searchCompletedLimit).map { input.tasks[$0.index] }

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

        prune(tasks: input.tasks, notes: input.notes)
        return results
    }

    /// Folds whatever isn't folded yet (or changed since), without searching.
    func prepare(tasks: [TaskItem], notes: [Note]) {
        for t in tasks { _ = taskDoc(t) }
        for n in notes { _ = noteDoc(n) }
        prune(tasks: tasks, notes: notes)
    }

    func excerpt(for note: Note, query: SearchQuery) -> String {
        let needles = query.needles
        if let known = excerpts[note.id], known.needles == needles, known.body == note.body { return known.text }
        let text = query.snippet(in: note.body) ?? note.preview
        excerpts[note.id] = (note.body, needles, text)
        return text
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
    private func prune(tasks: [TaskItem], notes: [Note]) {
        if taskDocs.count > tasks.count + 256 {
            let live = Set(tasks.map(\.id))
            taskDocs = taskDocs.filter { live.contains($0.key) }
        }
        if noteDocs.count > notes.count + 64 || excerpts.count > notes.count + 64 {
            let live = Set(notes.map(\.id))
            noteDocs = noteDocs.filter { live.contains($0.key) }
            excerpts = excerpts.filter { live.contains($0.key) }
        }
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
    fileprivate var needles: [String] { terms.map(\.text) + tags.map { "#" + $0.text } }

    /// What a note in the results shows under its title: the line that matched (`snippet(in:)`), else its
    /// opening lines. Remembered while the note and the query stay the same, since rows redraw often.
    @MainActor func excerpt(for note: Note) -> String {
        SearchIndex.shared.excerpt(for: note, query: self)
    }

    /// Where the query's words, phrases and #tags appear in `text` (compared as the search compares), merged, in order.
    func highlights(in text: String) -> [Range<String.Index>] {
        var found = needles.flatMap { SearchText.ranges(of: $0, in: text) }
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
            let raw = String(line)
            guard Self.mayMatch(raw, needles) else { continue }
            let text = Self.plainLine(raw)
            guard !text.isEmpty else { continue }
            let first = needles.compactMap { SearchText.ranges(of: $0, in: text, limit: 1).first }.min { $0.lowerBound < $1.lowerBound }
            if let first { return Self.excerpt(text, around: first, maxLength: maxLength) }
        }
        return nil
    }

    /// A quick look at a line as written, before the slower clean-up into plain text: could any needle be in it?
    /// Photos count by their description and emphasis marks are skipped, as `plainLine` does, so a long note's
    /// many other lines are passed over cheaply.
    private static func mayMatch(_ line: String, _ needles: [String]) -> Bool {
        var probes = [line.contains("![") ? Note.describingMedia(line) : line]
        if line.contains(where: { $0 == "*" || $0 == "_" || $0 == "`" }) {
            probes.append(probes[0].filter { $0 != "*" && $0 != "_" && $0 != "`" })
        }
        return needles.contains { needle in probes.contains { !SearchText.ranges(of: needle, in: $0, limit: 1).isEmpty } }
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
