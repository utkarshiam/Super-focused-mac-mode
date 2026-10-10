import Combine
import Foundation
import MemoryKit

/// Remembers the user's notes without being asked (behind its switch in Settings → Memory): once editing
/// pauses (5 s), a note that says something goes into memory, and again whenever its words change. Empty, very
/// short and untouched template notes stay out. Deleting the note forgets it.
///
/// Tasks never go in: memory is what the user knows, tasks are what they do (memory feeds tasks through
/// `TaskContext`, not the other way round). It watches the Store and never changes it. What existed before
/// launch counts as already seen: only edits made while Docket runs are remembered, apart from the one-time
/// `backfill` when Memory first starts.
@MainActor
final class MemoryAutoCapture {
    struct Switches: Equatable {
        var notes = true

        static var current: Switches { Switches(notes: Prefs.memoryCapturesNotes) }
    }

    enum NoteAction: Equatable { case remember, forget, none }

    nonisolated static let noteDelay: TimeInterval = 5
    /// Notes with fewer letters and digits than this aren't worth remembering.
    static let minimumNoteCharacters = 30

    let library: MemoryLibrary
    private weak var store: Store?
    var switches: () -> Switches = { .current }
    var now: () -> Date = { Date() }

    /// Each note's body as last seen, to tell an edit from a note that's just there.
    private var noteBaseline: [UUID: String] = [:]
    /// Notes remembered another way (a message saved as a note is remembered as the message).
    private var skippedNotes: Set<UUID> = []
    private var cancellables = Set<AnyCancellable>()

    init(library: MemoryLibrary, store: Store, noteDelay: TimeInterval = MemoryAutoCapture.noteDelay) {
        self.library = library
        self.store = store
        noteBaseline = Dictionary(store.notes.map { ($0.id, $0.body) }, uniquingKeysWith: { a, _ in a })
        store.$notes.dropFirst()
            .debounce(for: .seconds(noteDelay), scheduler: DispatchQueue.main)
            .sink { [weak self] notes in self?.notesSettled(notes) }
            .store(in: &cancellables)
    }

    /// Leaves a note out from now on.
    func skipNote(_ id: UUID) {
        skippedNotes.insert(id)
    }

    /// Once, when Memory first starts: remembers the notes already written, following the same rules (and
    /// switch) as new ones. Returns how many it added.
    @discardableResult
    func backfill() -> Int {
        guard let store, switches().notes else { return 0 }
        var added = 0
        library.batch {
            for note in store.notes where !skippedNotes.contains(note.id) && library.item(sourceRef: SourceRef.note(note.id)) == nil {
                guard Self.noteAction(note, previous: nil, remembered: false) == .remember else { continue }
                library.add(Self.item(for: note))
                added += 1
            }
        }
        return added
    }

    // MARK: Notes

    /// After editing pauses: remembers notes whose words changed, forgets deleted ones.
    func notesSettled(_ notes: [Note]) {
        let switches = switches()
        let ids = Set(notes.map(\.id))
        library.batch {
            // Gone from Docket, gone from memory (whatever the switches say).
            for id in noteBaseline.keys where !ids.contains(id) { forget(SourceRef.note(id)) }
            guard switches.notes else { return }
            for note in notes where !skippedNotes.contains(note.id) {
                let ref = SourceRef.note(note.id)
                let existing = library.item(sourceRef: ref)
                switch Self.noteAction(note, previous: existing?.body ?? noteBaseline[note.id], remembered: existing != nil) {
                case .remember: library.add(Self.item(for: note))
                case .forget: forget(ref)
                case .none: break
                }
            }
        }
        noteBaseline = Dictionary(notes.map { ($0.id, $0.body) }, uniquingKeysWith: { a, _ in a })
    }

    /// What to do with a note whose body was `previous` when last seen or remembered (nil: a new note).
    static func noteAction(_ note: Note, previous: String?, remembered: Bool) -> NoteAction {
        let words = meaningful(note.body)
        if words.isEmpty { return remembered ? .forget : .none }
        guard words.filter({ $0.isLetter || $0.isNumber }).count >= minimumNoteCharacters,
              !isUntouchedTemplate(note, words: words) else { return .none }
        if let previous, meaningful(previous) == words { return .none }
        return .remember
    }

    /// The words, with every run of whitespace as one space: re-flowing a paragraph isn't a change.
    static func meaningful(_ body: String) -> String {
        body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// A template (daily note, meeting notes…) or the guide, as made: nothing of the user's yet.
    private static func isUntouchedTemplate(_ note: Note, words: String) -> Bool {
        words == meaningful(NoteTemplate.guideBody)
            || NoteTemplate.allCases.contains { meaningful($0.body(for: note.createdAt)) == words }
    }

    static func item(for note: Note) -> MemoryItem {
        MemoryItem(kind: .note, origin: .auto, sourceRef: SourceRef.note(note.id), title: note.title, body: note.body,
                   capturedFrom: "Notes", createdAt: note.createdAt)
    }

    private func forget(_ ref: String) {
        if let item = library.item(sourceRef: ref) { library.remove(item.id) }
    }
}

// MARK: - Messages

/// A Slack thread or an email conversation as one memory: the summary when there is one, then what was said
/// (newest kept when it's long), who was in it, and where it was ("Slack #leadership", "Email").
enum MessageMemory {
    /// Longest body kept; older messages give way first.
    static let bodyLimit = 8_000

    /// One memory per thread: `slack:<channel>:<thread ts>`, `gmail:<thread id>`.
    static func sourceRef(for s: Suggestion) -> String {
        if let ids = InboxIDs.slack(s.id) {
            let parent = s.threadTS.flatMap { SlackClient.isTimestamp($0) ? $0 : nil } ?? ids.ts
            return SourceRef.slack(channel: ids.channel, ts: parent)
        }
        if let ids = InboxIDs.gmail(s.id) { return SourceRef.gmail(threadID: ids.thread) }
        return s.id
    }

    static func capturedFrom(_ s: Suggestion) -> String {
        s.source.kind == .gmail ? "Email" : "Slack " + InboxText.place(of: s)
    }

    /// "Sam Lee" from "Sam Lee <sam@northwind.example>"; the address when there's no name.
    static func personName(_ from: String) -> String {
        let text = from.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let open = text.firstIndex(of: "<") else { return text }
        let name = text[..<open].trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"")))
        if !name.isEmpty { return name }
        return text[text.index(after: open)...].trimmingCharacters(in: CharacterSet(charactersIn: "> "))
    }

    /// The memory for a message. `thread` is the whole thread when it's loaded (oldest first); `reply` a reply
    /// just sent, when the thread doesn't show it yet.
    static func item(for s: Suggestion, summary: ThreadSummary?, thread: [ThreadMessage]?, reply: String? = nil,
                     origin: MemoryOrigin) -> MemoryItem {
        let messages = thread.flatMap { $0.isEmpty ? nil : $0 } ?? [ownMessage(s)]
        var head: [String] = []
        if let summary, !summary.bullets.isEmpty {
            head.append(summary.bullets.map { "- " + $0 }.joined(separator: "\n"))
            if let needs = summary.needsFromYou?.trimmingCharacters(in: .whitespacesAndNewlines), !needs.isEmpty {
                head.append("Needs from you: " + needs)
            }
        }
        var tail: [String] = []
        let sent = reply?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !sent.isEmpty, !messages.contains(where: { $0.isMine && $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == sent }) {
            tail.append("You replied: " + sent)
        }
        // The newest messages that fit, in order.
        var budget = bodyLimit - (head + tail).reduce(0) { $0 + $1.count + 2 }
        var said: [String] = []
        for m in messages.reversed() {
            let text = m.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let line = "\(m.isMine ? "You" : personName(m.from)), \(MemoryDates.label(m.date)): \(text)"
            if line.count > budget {
                if said.isEmpty { said.append(String(line.prefix(max(0, budget)))) }
                break
            }
            said.append(line)
            budget -= line.count + 2
        }
        let body = (head + said.reversed() + tail).joined(separator: "\n\n")

        var people: [String] = []
        let senders = [personName(s.from)] + messages.filter({ !$0.isMine }).map({ personName($0.from) })
        for name in senders where !name.isEmpty && !people.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            people.append(name)
        }
        let url = s.source.url.flatMap { $0.scheme == "https" ? $0.absoluteString : nil }
        return MemoryItem(kind: .message, origin: origin, sourceRef: sourceRef(for: s), title: MessageNote.title(for: s),
                          body: body, url: url, capturedFrom: capturedFrom(s), people: people,
                          createdAt: messages.first?.date ?? s.receivedAt)
    }

    /// The item's own message, when the thread isn't loaded.
    private static func ownMessage(_ s: Suggestion) -> ThreadMessage {
        let whole = s.content?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let text = s.source.kind == .gmail ? MailQuote.trimmed(whole) : whole
        return ThreadMessage(id: InboxThread.bareMessageID(s.id), from: s.replyHeaders?.from ?? s.from, date: s.receivedAt,
                             text: text.isEmpty ? s.snippet : text, isMine: false)
    }
}
