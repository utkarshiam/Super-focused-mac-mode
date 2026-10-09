import Foundation

// "Save as note" in Messages: a Slack message or email, or its whole thread, as a note. The note starts with
// a title (the email's subject, or "#channel · sender"), a line with where it's from, who's in it, when and a
// link back, then the AI summary when there is one, then every message in readable Markdown (an email without
// the history it quotes), with its attachments: photos, videos and PDFs show in the note, other files are
// listed by name.

// MARK: - The note (pure, so it's easy to test)

/// One message as the note shows it.
struct NoteMessage: Equatable {
    var from: String
    var date: Date
    var text: String
    var files: [NoteFile] = []
}

/// An attachment as the note shows it: in the note (`markdown`, from `MediaLibrary.importFiles`), or by name.
struct NoteFile: Equatable {
    var name: String
    var size: Int?
    /// The Markdown line that shows the file in the note, once it's in the note's library.
    var markdown: String?
    /// Why it isn't in the note ("open it in Gmail"), when it couldn't be.
    var problem: String?
}

enum MessageNote {
    /// The note's title: the email's subject; "#leadership · Priya Shah" for a Slack message.
    static func title(for s: Suggestion) -> String {
        switch s.source.kind {
        case .gmail:
            let subject = MailText.cleanSubject(s.subject ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return oneLine(subject.isEmpty ? "Email from \(s.from)" : subject)
        case .slack, .ai:
            let place = InboxText.place(of: s)
            let from = s.from.trimmingCharacters(in: .whitespacesAndNewlines)
            return oneLine(from.isEmpty ? place : "\(place) · \(from)")
        }
    }

    /// Who's in it, in order of appearance, the user ("You") last: "Sam Lee, Lena Park and you".
    static func people(_ messages: [NoteMessage]) -> String {
        var seen = Set<String>()
        var names: [String] = []
        var includesYou = false
        for m in messages {
            let name = oneLine(m.from)
            if name == "You" {
                includesYou = true
            } else if !name.isEmpty, seen.insert(name.lowercased()).inserted {
                names.append(name)
            }
        }
        if includesYou { names.append("you") }
        guard names.count > 1 else { return names.first.map { $0 == "you" ? "You" : $0 } ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
    }

    /// The whole note, as Markdown.
    ///
    ///     # Contract redlines
    ///     Gmail · Sam Lee, Lena Park and you · Thu 8 Oct · 10:42 AM · [Open in Gmail](https://…)
    ///
    ///     ## Summary
    ///     - …
    ///     **Needs from you:** …
    ///
    ///     ## Conversation · 3 messages
    ///     **Sam Lee** · Thu 8 Oct · 10:42 AM
    ///     …
    static func body(title: String, kind: TaskSource.Kind, date: Date, link: URL?, summary: ThreadSummary?,
                     messages: [NoteMessage], wholeThread: Bool, now: Date) -> String {
        var lines: [String] = ["# " + escapedLine(title.isEmpty ? "Message" : title)]
        var header = [SourceStyle.name(kind)]
        let people = people(messages)
        if !people.isEmpty { header.append(escapedLine(people)) }
        header.append(Fmt.due(date, hasTime: true, now: now))
        if let link, link.scheme == "https" { header.append("[\(SourceStyle.openTitle(kind))](\(link.absoluteString))") }
        lines.append(header.joined(separator: " · "))

        if let summary, !summary.bullets.isEmpty {
            lines.append("")
            lines.append("## Summary")
            lines.append(contentsOf: summary.bullets.map { "- " + escapedLine($0) })
            if let needs = summary.needsFromYou?.trimmingCharacters(in: .whitespacesAndNewlines), !needs.isEmpty {
                lines.append("")
                lines.append("**Needs from you:** " + escapedLine(needs))
            }
        }

        lines.append("")
        if wholeThread, messages.count > 1 {
            lines.append("## \(kind == .gmail ? "Conversation" : "Thread") · \(messages.count) messages")
        } else {
            lines.append("## Message")
        }
        for (i, m) in messages.enumerated() {
            if i > 0 {
                lines.append("")
                lines.append("---")
            }
            lines.append("")
            lines.append("**\(escapedLine(m.from.isEmpty ? "Someone" : m.from))** · \(Fmt.due(m.date, hasTime: true, now: now))")
            let text = markdownSafe(m.text)
            if !text.isEmpty {
                lines.append("")
                lines.append(text)
            }
            if !m.files.isEmpty {
                lines.append("")
                lines.append(contentsOf: m.files.map(fileLine))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A photo, video or PDF shown in the note; any other file by name, size and why it isn't there.
    static func fileLine(_ f: NoteFile) -> String {
        if let markdown = f.markdown { return markdown }
        var parts = [escapedLine(f.name.isEmpty ? "Attachment" : f.name)]
        if let size = AttachmentInfo.size(f.size) { parts.append(size) }
        if let problem = f.problem, !problem.isEmpty { parts.append(problem) }
        return "- 📎 " + parts.joined(separator: " · ")
    }

    /// A message's text as Markdown that reads as it was written: trailing spaces and runs of blank lines go,
    /// and a line that would turn into a heading, a rule or an image tag is escaped.
    static func markdownSafe(_ text: String) -> String {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) }
            .map(escapedStart)
        return lines.joined(separator: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "# x" → "\# x", "---" → "\---", "![" → "!\[": the message's own words, never the note's structure (a
    /// heading, a rule, or an image from somewhere on this Mac).
    private static func escapedStart(_ line: String) -> String {
        let line = line.replacingOccurrences(of: "![", with: "!\\[")
        let trimmed = String(line.drop { $0 == " " })
        if trimmed.range(of: #"^#{1,6}(\s|$)"#, options: .regularExpression) != nil { return "\\" + trimmed }
        let bare = trimmed.filter { $0 != " " }
        if bare.count >= 3, Set(bare).count == 1, let c = bare.first, "-*_=".contains(c) { return "\\" + trimmed }
        return line
    }

    /// One line, for a title or a name.
    private static func oneLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func escapedLine(_ text: String) -> String { escapedStart(oneLine(text)) }
}

// MARK: - Saving one

extension Integrations {
    /// At most this many attachments are put in a note (the rest are listed by name).
    static let noteFileLimit = 20

    /// Saves the item's whole thread (or, with `messageID`, just that message of it) as a note: see the top of
    /// this file. Attachments are downloaded (as the inbox does) and put in the note's library; any that can't
    /// be are listed by name. One undo step takes the note away. Returns the note.
    @discardableResult
    func saveAsNote(_ id: String, message messageID: String? = nil, now: Date = Date()) async throws -> Note {
        guard suggestion(id) != nil else { throw IntegrationError.api(id.hasPrefix("gmail:") ? .gmail : .slack, "This message isn't in Docket's inbox any more.") }
        // The whole thread when it can be had; the message alone otherwise (offline, a missing permission).
        let thread = try? await fullThread(for: id, reload: false)
        let content = try? await content(for: id)
        guard let store, let s = suggestion(id) else {
            throw IntegrationError.api(id.hasPrefix("gmail:") ? .gmail : .slack, "This message isn't in Docket's inbox any more.")
        }
        var sources = noteSources(s, thread: thread, content: content)
        if let messageID {
            let wanted = InboxThread.bareMessageID(messageID)
            let picked = sources.filter { $0.id == wanted || InboxThread.sameSlackMessage($0.id, wanted) }
            if !picked.isEmpty { sources = picked }
        }
        var messages: [NoteMessage] = []
        var budget = Self.noteFileLimit
        for source in sources {
            var files: [NoteFile] = []
            for a in source.files {
                if budget > 0 {
                    budget -= 1
                    files.append(await noteFile(a, itemID: id, kind: s.source.kind))
                } else {
                    files.append(NoteFile(name: a.name, size: a.size, problem: "not added (too many files)"))
                }
            }
            messages.append(NoteMessage(from: source.from, date: source.date, text: source.text, files: files))
        }
        let whole = messageID == nil
        let body = MessageNote.body(title: MessageNote.title(for: s), kind: s.source.kind,
                                    date: whole ? s.receivedAt : (messages.first?.date ?? s.receivedAt),
                                    link: s.source.url, summary: whole ? threadSummaries[id] : nil,
                                    messages: messages, wholeThread: whole, now: now)
        // One undo step of its own: ⌘Z takes the note away. (It runs after downloads, outside any click's
        // event, so it's grouped here.)
        let undo = store.undoManager
        undo?.beginUndoGrouping()
        let note = store.addNote(body: body)
        undo?.setActionName("Save as Note")
        undo?.endUndoGrouping()
        return note
    }

    /// The messages a note shows, oldest first: who wrote each (the user as "You"), when, its words (an email
    /// without the history it quotes) and its files (not the images an email's body shows inline).
    private func noteSources(_ s: Suggestion, thread: InboxThread?, content: MessageContent?)
        -> [(id: String, from: String, date: Date, text: String, files: [MessageAttachment])] {
        switch thread {
        case .slack(let messages, _)? where !messages.isEmpty:
            let names = slackNames
            return messages.map { m in
                (m.id, ThreadText.sender(of: m, names: names), m.date, m.text, m.files)
            }
        case .email(let emails, _)? where !emails.isEmpty:
            return emails.map { e in
                var text = MailQuote.trimmed(e.content.text).trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty { text = e.snippet }
                return (e.id, ThreadText.sender(of: e), e.date, text, e.content.attachments.filter { $0.contentID == nil })
            }
        default:
            let c = content ?? s.content
            let whole = c?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            var text = s.source.kind == .gmail ? MailQuote.trimmed(whole) : whole
            if text.isEmpty { text = s.snippet }
            let files = (c?.attachments ?? []).filter { $0.contentID == nil }
            return [(InboxThread.bareMessageID(s.id), s.from, s.receivedAt, text, files)]
        }
    }

    /// The attachment downloaded and put in the note's library; by name when that can't be done.
    private func noteFile(_ a: MessageAttachment, itemID: String, kind: TaskSource.Kind) async -> NoteFile {
        let place = kind == .gmail ? "Gmail" : "Slack"
        if (a.size ?? 0) > InboxCache.largestFile { return NoteFile(name: a.name, size: a.size, problem: "open it in \(place)") }
        do {
            let url = try await file(for: a, messageID: itemID)
            // Copying a big file takes a moment: not on the main thread.
            let line = await Task.detached(priority: .userInitiated) { MediaLibrary.importFiles([url]).first }.value
            return NoteFile(name: a.name, size: a.size, markdown: line, problem: line == nil ? "open it in \(place)" : nil)
        } catch {
            return NoteFile(name: a.name, size: a.size, problem: "open it in \(place)")
        }
    }
}
