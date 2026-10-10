import Foundation
import MemoryKit

// The Memory screens' rules, kept apart from the views so they're easy to test: what each filter shows,
// how an answer's [n] markers split into citation chips, which words a date or a promise gets, where a
// memory's source opens, and when ⌘K offers to ask.

// MARK: - What the library shows

/// The library's filter: one of the kinds along the top, or something picked from Browse (a person,
/// a project, a kind of moment).
enum MemoryScope: Hashable {
    case all, notes, links, media, files, messages
    case person(String)
    case project(String)
    case moments(MomentKind)

    /// The row of filters along the top, in order. No Tasks: tasks aren't memories.
    static let kinds: [MemoryScope] = [.all, .notes, .links, .media, .files, .messages]
    /// The kinds of moment Browse offers.
    static let momentKinds: [MomentKind] = [.decision, .promise, .idea, .insight]

    /// Picked from Browse rather than the row along the top.
    var isBrowse: Bool {
        switch self {
        case .person, .project, .moments: true
        default: false
        }
    }

    /// The library filter behind it.
    var filter: MemoryFilter {
        switch self {
        case .all: MemoryFilter()
        case .notes: MemoryFilter(kinds: [.note, .text, .engram])
        case .links: MemoryFilter(kinds: [.link])
        case .media: MemoryFilter(kinds: [.image, .video, .audio])
        case .files: MemoryFilter(kinds: [.pdf, .file])
        case .messages: MemoryFilter(kinds: [.message])
        case .person(let name): MemoryFilter(person: name)
        case .project(let name): MemoryFilter(project: name)
        case .moments(let kind): MemoryFilter(momentKind: kind)
        }
    }

    /// What the chip says, in the lens's words ("Deals", "Next steps").
    func label(_ vocabulary: LensVocabulary) -> String {
        switch self {
        case .all: "All"
        case .notes: "Notes"
        case .links: "Links"
        case .media: "Media"
        case .files: "Files"
        case .messages: "Messages"
        case .person(let name), .project(let name): name
        case .moments(let kind): vocabulary.label(for: kind)
        }
    }

    /// An SF Symbol for a Browse pick.
    var symbol: String {
        switch self {
        case .person: "person"
        case .project: "folder"
        case .moments(let kind): MemoryText.symbol(for: kind)
        default: "square.grid.2x2"
        }
    }

    /// Pictures and videos read better as a grid: always under Media, and anywhere else that's mostly them.
    static func usesGrid(_ scope: MemoryScope, kinds: [MemoryKind]) -> Bool {
        if scope == .media { return true }
        guard kinds.count >= 4 else { return false }
        let visual = kinds.filter { $0 == .image || $0 == .video }.count
        return visual * 3 >= kinds.count * 2
    }
}

// MARK: - Answers with citations

/// An answer's text cut at its [n] markers, so each one can show as a small citation chip.
enum CitationText {
    enum Segment: Hashable {
        case text(String)
        case citation(Int)
    }

    private static let marker = try! NSRegularExpression(pattern: #"\[(\d{1,3})\]"#)

    /// "Raised on a SAFE [1][2]." → text, 1, 2, text. Markers outside `valid` (when given) stay as text.
    static func segments(_ text: String, valid: ClosedRange<Int>? = nil) -> [Segment] {
        let ns = text as NSString
        var out: [Segment] = []
        var last = 0
        func addText(_ s: String) {
            guard !s.isEmpty else { return }
            if case .text(let previous)? = out.last {
                out[out.count - 1] = .text(previous + s)
            } else {
                out.append(.text(s))
            }
        }
        for m in marker.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let n = Int(ns.substring(with: m.range(at: 1))), valid?.contains(n) ?? true else { continue }
            var before = ns.substring(with: NSRange(location: last, length: m.range.location - last))
            // "word [1]" reads as "word¹": the chip sits right after the word.
            if before.hasSuffix(" ") { before.removeLast() }
            addText(before)
            out.append(.citation(n))
            last = m.range.location + m.range.length
        }
        addText(ns.substring(from: last))
        return out
    }

    /// The numbers cited, in order of first appearance.
    static func numbers(in text: String) -> [Int] {
        var seen: [Int] = []
        for case .citation(let n) in segments(text) where !seen.contains(n) { seen.append(n) }
        return seen
    }
}

// MARK: - Words

enum MemoryText {
    /// Always the real date ("Mon 5 Oct", with the year when it isn't this year). Never "Today".
    static func date(_ d: Date, now: Date = Date()) -> String { Fmt.absoluteDay(d, now: now) }

    /// "Mon 5 Oct, 4:00 PM"
    static func dateTime(_ d: Date, now: Date = Date()) -> String { "\(Fmt.absoluteDay(d, now: now)), \(Fmt.time(d))" }

    /// "1 memory", "12 memories"
    static func count(_ n: Int) -> String { n == 1 ? "1 memory" : "\(n) memories" }

    /// Who owes a promise and when: "You · due Fri 12 Oct", "Priya Shah · due Fri 12 Oct", "Priya Shah".
    static func promiseLine(_ m: Moment, now: Date = Date()) -> String? {
        var parts: [String] = []
        if m.direction == .mine {
            parts.append("You")
        } else if let who = m.who?.trimmingCharacters(in: .whitespaces), !who.isEmpty {
            parts.append(who)
        }
        if let due = m.due { parts.append("due \(date(due, now: now))") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Who decided or had it, when it wasn't the user.
    static func whoLine(_ m: Moment) -> String? {
        guard let who = m.who?.trimmingCharacters(in: .whitespaces), !who.isEmpty else { return nil }
        return who
    }

    static func symbol(for kind: MomentKind) -> String {
        switch kind {
        case .decision: "checkmark.seal"
        case .promise: "hand.raised"
        case .idea: "lightbulb"
        case .insight: "sparkle"
        }
    }

    /// Why an older memory came back, in a few words.
    static func reason(_ reason: ResurfacedItem.Reason, _ vocabulary: LensVocabulary) -> String {
        switch reason {
        case .pinned: "Pinned"
        case .relatedToRecent: "Like this week's"
        case .openPromise: "\(vocabulary.promises) still open"
        case .idea: "An idea to revisit"
        }
    }

    /// "On this day · 9 Oct 2025"
    static func onThisDay(_ d: Date, now: Date = Date()) -> String { "On this day · \(date(d, now: now))" }

    /// Over search results: "Nothing matches “pricing”", "1 memory matches “pricing”", "3 memories match “pricing”".
    static func matches(_ n: Int, _ query: String) -> String {
        switch n {
        case 0: "Nothing matches “\(query)”"
        case 1: "1 memory matches “\(query)”"
        default: "\(n) memories match “\(query)”"
        }
    }

    /// Where it came from, for the detail's first line: "Note · Slack · #design".
    static func origin(_ item: MemoryItem) -> String {
        var parts = [item.kind.label]
        if let from = item.capturedFrom?.trimmingCharacters(in: .whitespaces), !from.isEmpty, from != item.kind.label {
            parts.append(from)
        } else if item.origin == .phone {
            parts.append("iPhone")
        }
        return parts.joined(separator: " · ")
    }

    /// "Ask your memory, e.g. “What did I decide last week?”": an example the chips under the field don't show.
    static func askPlaceholder(_ lenses: [Lens]) -> String {
        let examples = Lens.askExamples(for: lenses, limit: 4)
        guard let example = examples.count > 3 ? examples.last : examples.first else { return "Ask your memory…" }
        return "Ask your memory, e.g. “\(example)”"
    }

    /// The example questions shown as chips under the empty field.
    static func askChips(_ lenses: [Lens]) -> [String] { Lens.askExamples(for: lenses, limit: 3) }

    /// Said under the Ask field when there's no Gemini key.
    static let noKey = "Add a Gemini key in Settings → AI to ask questions. Search still works."

    /// How a file's size reads ("2.4 MB").
    static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

// MARK: - Where a memory's source opens

enum MemorySourceLink: Equatable {
    case task(UUID)
    case note(UUID)
    /// The message in Messages (a `Suggestion.id`), when it's still there.
    case message(String)
    case web(URL)

    /// The place to go back to for an item: the task or note it was captured from, its Slack or email
    /// thread in Messages (`messageIDs`: the ids Messages has now), else its web address.
    static func resolve(_ item: MemoryItem, messageIDs: [String]) -> MemorySourceLink? {
        if let ref = item.sourceRef {
            let scheme = SourceRef.scheme(of: ref)
            let rest = String(ref.dropFirst((scheme?.count ?? 0) + 1))
            switch scheme {
            case "task": if let id = UUID(uuidString: rest) { return .task(id) }
            case "note": if let id = UUID(uuidString: rest) { return .note(id) }
            case "slack", "gmail":
                if let id = messageID(for: ref, among: messageIDs) { return .message(id) }
            default: break
            }
        }
        if let url = item.url.flatMap(URL.init(string:)), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            return .web(url)
        }
        return nil
    }

    /// "slack:C0B:1700.0001" → "slack:C0B/1700.0001"; "gmail:<thread>" → the first "gmail:<thread>/<message>".
    static func messageID(for ref: String, among ids: [String]) -> String? {
        if ref.hasPrefix("slack:") {
            let rest = ref.dropFirst("slack:".count)
            guard let colon = rest.firstIndex(of: ":") else { return nil }
            let id = "slack:" + rest[..<colon] + "/" + rest[rest.index(after: colon)...]
            return ids.contains(id) ? id : nil
        }
        if ref.hasPrefix("gmail:") {
            let prefix = ref + "/"
            return ids.first { $0.hasPrefix(prefix) }
        }
        return nil
    }

    var title: String {
        switch self {
        case .task: "Open task"
        case .note: "Open note"
        case .message: "Open in Messages"
        case .web(let url): "Open \(url.host?.replacingOccurrences(of: "www.", with: "") ?? "link")"
        }
    }

    var symbol: String {
        switch self {
        case .task: "checkmark.circle"
        case .note: "doc.text"
        case .message: "tray.and.arrow.down"
        case .web: "safari"
        }
    }
}

// MARK: - ⌘K

enum PaletteMemory {
    private static let questionWords: Set<String> = [
        "what", "who", "whom", "whose", "when", "where", "why", "how", "which",
        "did", "do", "does", "is", "are", "was", "were", "can", "could", "should", "would", "have", "has", "any",
    ]

    /// Typed text that reads as a question: it ends with "?", or starts with a question word and has a few
    /// words. Then "Ask memory" comes first in ⌘K; otherwise it waits below the tasks and notes.
    static func looksLikeQuestion(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        if t.hasSuffix("?") { return true }
        let words = t.lowercased().split(whereSeparator: { $0.isWhitespace })
        guard words.count >= 3, let first = words.first else { return false }
        return questionWords.contains(String(first.filter(\.isLetter)))
    }
}
