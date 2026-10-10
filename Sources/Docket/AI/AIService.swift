import Foundation

// MARK: - Drafts

/// A task proposed by AI (or by a Slack/Gmail suggestion). The user reviews it before it becomes a real task.
struct TaskDraft: Identifiable, Hashable, Codable {
    var id = UUID()
    var title: String
    var notes = ""
    var due: Date?
    var dueHasTime = false
    var estimateMinutes: Int?
    var priority: Priority = .none
    var listName: String?
    var tags: [String] = []
    var subtasks: [String] = []
    var reminderMinutesBefore: Int?
    var reminderIsAlarm = false
    var waitingOn: String?
    /// One short line on why it's suggested or where it came from.
    var reason: String?
    /// The Slack message or email it came from (set by `AIService.triage`), so a task made from it links back.
    var source: TaskSource?

    enum CodingKeys: String, CodingKey {
        case id, title, notes, due, dueHasTime, estimateMinutes, priority, listName, tags, subtasks
        case reminderMinutesBefore, reminderIsAlarm, waitingOn, reason, source
    }
}

extension TaskDraft {
    // In an extension so the memberwise initializer stays available. Missing keys fall back to defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, default: UUID())
        title = c.value(.title, default: "")
        notes = c.value(.notes, default: "")
        due = c.value(.due, default: nil)
        dueHasTime = c.value(.dueHasTime, default: false)
        estimateMinutes = c.value(.estimateMinutes, default: nil)
        priority = c.value(.priority, default: .none)
        listName = c.value(.listName, default: nil)
        tags = c.value(.tags, default: [])
        subtasks = c.value(.subtasks, default: [])
        reminderMinutesBefore = c.value(.reminderMinutesBefore, default: nil)
        reminderIsAlarm = c.value(.reminderIsAlarm, default: false)
        waitingOn = c.value(.waitingOn, default: nil)
        reason = c.value(.reason, default: nil)
        source = c.value(.source, default: nil)
    }
}

extension TaskDraft {
    /// A real task: list matched by name (case-insensitive, else Inbox), reminders, subtasks, source
    /// (`source`, or the draft's own when that's nil).
    /// Like quick add, a deadline with a time and no reminder of its own gets the default reminder
    /// from Settings (pass `defaultReminder: -1` for none).
    func makeTask(lists: [TaskList], source: TaskSource? = nil,
                  defaultReminder: Int = Prefs.defaultReminder, defaultIsAlarm: Bool = Prefs.defaultReminderIsAlarm) -> TaskItem {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var t = TaskItem(title: name.isEmpty ? "Untitled task" : name)
        t.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if let due {
            t.dueHasTime = dueHasTime
            t.dueDate = dueHasTime ? due : Calendar.current.startOfDay(for: due)
        }
        t.estimateMinutes = estimateMinutes.flatMap { $0 > 0 ? $0 : nil }
        t.priority = priority
        t.listID = Self.list(named: listName, in: lists)?.id

        for raw in tags {
            let tag = raw.trimmingCharacters(in: CharacterSet(charactersIn: "# ").union(.whitespacesAndNewlines))
                .replacingOccurrences(of: " ", with: "-")
            if !tag.isEmpty, !t.tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) { t.tags.append(tag) }
        }
        t.subtasks = subtasks.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.map { Subtask(title: $0) }

        // Reminders count from the deadline, so they need one.
        if t.dueDate != nil {
            if let minutes = reminderMinutesBefore {
                t.reminders = [Reminder(trigger: .beforeDue(minutes: max(0, minutes)), isAlarm: reminderIsAlarm)]
            } else if t.dueHasTime, defaultReminder >= 0 {
                t.reminders = [Reminder(trigger: .beforeDue(minutes: defaultReminder), isAlarm: defaultIsAlarm)]
            }
        }

        let person = waitingOn?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        t.waitingOn = person.isEmpty ? nil : person
        t.source = source ?? self.source
        return t
    }

    /// The list whose name matches, ignoring case, accents and a leading "#". Nil means Inbox.
    static func list(named name: String?, in lists: [TaskList]) -> TaskList? {
        let wanted = (name ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "#").union(.whitespacesAndNewlines))
        guard !wanted.isEmpty else { return nil }
        return lists.first {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).compare(wanted, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
    }

    /// The draft with the defaults of the page it was planned on, as quick add gives them: a list's page
    /// files drafts without a (known) list of their own there, a tag's page adds its tag, and Important
    /// makes them at least High. The Calendar's day isn't applied: dates come from what was written.
    func filed(in page: SidebarItem?, lists: [TaskList]) -> TaskDraft {
        var d = self
        switch page {
        case .list(let id)?:
            if Self.list(named: d.listName, in: lists) == nil, let list = lists.first(where: { $0.id == id }) {
                d.listName = list.name
            }
        case .tag(let raw)?:
            let tag = raw.trimmingCharacters(in: CharacterSet(charactersIn: "#").union(.whitespacesAndNewlines))
            if !tag.isEmpty, !d.tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
                d.tags.append(tag)
            }
        case .important?:
            d.priority = max(d.priority, .high)
        default:
            break
        }
        return d
    }
}

// MARK: - Messages to triage

/// A Slack message or email, as handed to `AIService.triage`.
struct IncomingMessage: Hashable {
    var source: TaskSource
    var from: String
    var subject: String?
    var text: String
    var date: Date
}

// MARK: - Errors

enum AIError: LocalizedError {
    /// No key yet, or AI is switched off.
    case notConfigured
    /// Google refused the key (wrong, revoked or restricted).
    case badKey
    /// Too many requests, or Google is overloaded.
    case rateLimited
    /// Offline, timed out, no route to Google. The text says which, in a sentence.
    case network(String)
    /// Google answered, but not with something usable. The text is a full sentence for the user.
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Add a Google Gemini API key in Settings → AI to use this."
        case .badKey: "Google Gemini didn't accept the API key. Check it in Settings → AI."
        case .rateLimited: "Gemini is busy or the key has hit its limit. Try again in a minute."
        case .network(let detail): detail.isEmpty ? "Couldn't reach Gemini." : "Couldn't reach Gemini. \(detail)"
        case .badResponse(let detail): detail.isEmpty ? "Gemini sent back something unexpected. Try again." : detail
        }
    }

    /// Whether the fix is in Settings → AI (a missing or rejected key, an unknown model), so the UI
    /// offers to open it.
    var needsSettings: Bool {
        switch self {
        case .notConfigured, .badKey: true
        case .badResponse(let detail): detail.contains(Self.settingsHint)
        case .rateLimited, .network: false
        }
    }

    /// Ends the messages whose fix is in Settings (an unknown model name).
    static let settingsHint = "Check the model in Settings → AI."
}

// MARK: - Settings

extension Prefs.Key {
    /// "Use AI" in Settings → AI.
    static let aiEnabled = "aiEnabled"
}

extension Prefs {
    /// "Use AI" in Settings → AI. On unless the user turned it off.
    static var aiEnabled: Bool { UserDefaults.standard.object(forKey: Key.aiEnabled) as? Bool ?? true }
}

// MARK: - Service

/// AI features backed by Google Gemini: planning tasks from free text, breaking a task into steps,
/// finding tasks in a note, ordering the day, sorting Slack and Gmail messages, and drafting replies to them.
/// Everything returns drafts or suggestions for the user to review; nothing is changed or sent behind their back.
@MainActor
final class AIService: ObservableObject {
    static let shared = AIService()

    /// Bumped when the key, model or "Use AI" switch changes in Settings, so views re-check `isConfigured`.
    @Published private(set) var settingsRevision = 0

    /// At most this many messages go to Gemini in one request.
    static let triageBatchSize = 25
    /// Days longer than this keep the rest in their current order.
    static let maxTasksToOrder = 40

    private let transport: GeminiClient.Transport
    private let apiKey: () -> String?
    private let model: () -> String
    private let enabled: @MainActor () -> Bool
    /// What memory knows that helps with some text (`MemoryCenter.taskContextBlock`): names, dates, notes and
    /// who it waits on for the tasks written from it. Nil when memory has nothing on it.
    private let memory: @MainActor (String) -> String?

    /// Tests pass a fake transport and their own key, so nothing touches the network or the secrets file (and
    /// memory stays out unless they bring their own).
    init(transport: @escaping GeminiClient.Transport = GeminiClient.defaultTransport,
         apiKey: @escaping () -> String? = { Secrets.geminiAPIKey },
         model: @escaping () -> String = { Secrets.geminiModel },
         enabled: @escaping @MainActor () -> Bool = { Prefs.aiEnabled && !DebugSnapshot.isActive },
         memory: @escaping @MainActor (String) -> String? = { GeminiClient.isUnitTesting ? nil : MemoryCenter.shared.taskContextBlock(for: $0) }) {
        self.transport = transport
        self.apiKey = apiKey
        self.model = model
        self.enabled = enabled
        self.memory = memory
    }

    /// AI is switched on and there's a key to use (screenshot mode never calls out).
    var isConfigured: Bool { enabled() && key() != nil }

    /// Settings → AI calls this after the key, model or "Use AI" changes.
    func settingsChanged() { settingsRevision += 1 }

    private func key() -> String? {
        guard let key = apiKey()?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return nil }
        return key
    }

    private func client() throws -> GeminiClient {
        guard enabled(), let key = key() else { throw AIError.notConfigured }
        return GeminiClient(apiKey: key, model: model(), transport: transport)
    }

    // MARK: Features

    /// Tasks for whatever the user wrote ("board meeting thu 10am, deck by wed, …").
    func planTasks(from text: String, store: Store, now: Date = Date()) async throws -> [TaskDraft] {
        let client = try client()
        let input = AIPrompts.planInput(text)
        guard !input.isEmpty else { return [] }
        var context = AIPrompts.Context(store: store, now: now)
        context.memory = memory(input)
        let answer = try await client.generate(system: AIPrompts.planSystem(context), prompt: input, schema: AIPrompts.tasksSchema)
        return try AIAnswers.drafts(answer, calendar: context.calendar)
    }

    /// Steps for a task (none when it's already one step), and a total estimate when the model can tell.
    func breakDown(_ task: TaskItem, store: Store, now: Date = Date()) async throws -> (subtasks: [String], estimateMinutes: Int?) {
        let client = try client()
        var context = AIPrompts.Context(store: store, now: now)
        let people = task.waitingOn.map { [$0] } ?? []
        context.memory = memory(task.title + "\n" + task.notes + (people.isEmpty ? "" : "\nWaiting on " + people[0]))
        let input = AIPrompts.breakDownInput(task, listName: store.list(task.listID)?.name, calendar: context.calendar)
        let answer = try await client.generate(system: AIPrompts.breakDownSystem(context), prompt: input, schema: AIPrompts.breakDownSchema)
        return try AIAnswers.breakDown(answer, existing: task.subtasks.map(\.title))
    }

    /// The action items in a note. Relative dates are read from when the note was written.
    func findTasks(inNote note: Note, store: Store, now: Date = Date()) async throws -> [TaskDraft] {
        let client = try client()
        let input = AIPrompts.noteInput(note)
        guard !input.isEmpty else { return [] }
        var context = AIPrompts.Context(store: store, now: now)
        context.memory = memory(input)
        let answer = try await client.generate(system: AIPrompts.noteSystem(context, note: note), prompt: input, schema: AIPrompts.tasksSchema)
        return try AIAnswers.drafts(answer, calendar: context.calendar)
    }

    /// Suggested order (ids) for the given tasks, with a short reason per task.
    /// Every task comes back exactly once; any the model skipped keep their order at the end.
    func orderDay(_ tasks: [TaskItem], now: Date = Date()) async throws -> [(id: UUID, reason: String)] {
        let client = try client()
        guard tasks.count > 1 else { return tasks.map { (id: $0.id, reason: "") } }
        let considered = Array(tasks.prefix(Self.maxTasksToOrder))
        let calendar = Calendar.current
        let answer = try await client.generate(system: AIPrompts.orderDaySystem(now: now, calendar: calendar, workday: AIPrompts.workday()),
                                               prompt: AIPrompts.orderDayInput(considered, calendar: calendar),
                                               schema: AIPrompts.orderSchema)
        let picks = try AIAnswers.order(answer, count: considered.count)
        guard !picks.isEmpty else { throw AIError.badResponse("Gemini didn't suggest an order. Try again.") }
        var result = picks.map { (id: considered[$0.index].id, reason: $0.reason) }
        let placed = Set(result.map(\.id))
        result += tasks.filter { !placed.contains($0.id) }.map { (id: $0.id, reason: "") }
        return result
    }

    /// Which messages need action, as task drafts keyed by `source.externalID` (absent = no action needed).
    /// Each draft carries its message's `source`. Up to 25 messages go in one request.
    func triage(_ messages: [IncomingMessage], store: Store, now: Date = Date()) async throws -> [String: TaskDraft] {
        let client = try client()
        var seen = Set<String>()
        let unique = messages.filter { seen.insert($0.source.externalID).inserted }
        guard !unique.isEmpty else { return [:] }
        var context = AIPrompts.Context(store: store, now: now)
        var result: [String: TaskDraft] = [:]
        for start in stride(from: 0, to: unique.count, by: Self.triageBatchSize) {
            let batch = Array(unique[start..<min(start + Self.triageBatchSize, unique.count)])
            // Who wrote and what about: the senders and subjects say the most for the fewest words.
            context.memory = memory(AIPrompts.triageMemoryText(batch))
            let system = AIPrompts.triageSystem(context)
            let answer = try await client.generate(system: system, prompt: AIPrompts.triageInput(batch, calendar: context.calendar),
                                                   schema: AIPrompts.triageSchema)
            for pick in try AIAnswers.triage(answer, count: batch.count, calendar: context.calendar) {
                let message = batch[pick.index]
                var draft = pick.draft
                draft.source = message.source
                result[message.source.externalID] = draft
            }
        }
        return result
    }

    /// Sends a tiny request with the saved key and model. Returns a short line for Settings.
    func testConnection() async throws -> String {
        let client = try client()
        let started = Date()
        let answer = try await client.generate(system: AIPrompts.pingSystem, prompt: AIPrompts.pingInput, schema: AIPrompts.pingSchema)
        guard try AIAnswers.object(answer)["ok"] as? Bool == true else {
            throw AIError.badResponse("Gemini answered, but not the way Docket expected. Try again.")
        }
        let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
        return "Connected. \(client.modelID) answered in \(seconds) s."
    }
}

// MARK: - Replying to a message

extension AIService {
    /// A reply to `message` in the user's voice, for them to edit and send. What to say comes from `notes`
    /// and `instruction`; the complete message and the earlier messages in its thread give the context.
    /// Facts that aren't in them are left as "[placeholder]".
    ///
    /// Slack: a few sentences for the thread, no greeting or sign-off, Slack formatting. Email: plain text
    /// with a greeting and a sign-off with `myName` (an address isn't a name; without one it signs
    /// "[your name]"). `content` nil uses `message.text`. Nothing is ever sent from here.
    ///
    /// `thread` is the rest of the thread or conversation, as much as there is (the prompt keeps the newest
    /// ~30 messages, ~12,000 characters). `replyingTo`: the message of the thread being answered when it isn't
    /// `message` (the user picked another one, or a newer email is the one replies go to); the prompt says
    /// which, and the reply answers that one.
    func draftReply(to message: IncomingMessage, content: MessageContent?, thread: [ThreadMessage], notes: String,
                    tone: ReplyTone, instruction: String?, myName: String?, replyingTo: ThreadMessage? = nil,
                    now: Date = Date()) async throws -> String {
        let client = try client()
        let calendar = Calendar.current
        let format = AIPrompts.ReplyFormat(message.source.kind)
        let system = AIPrompts.replySystem(format, tone: tone, notes: notes, instruction: instruction,
                                           myName: AIPrompts.personName(myName), answersAnother: replyingTo != nil,
                                           now: now, calendar: calendar)
        let answer = try await client.generate(system: system,
                                               prompt: AIPrompts.replyInput(message, content: content, thread: thread,
                                                                            replyingTo: replyingTo, calendar: calendar),
                                               schema: AIPrompts.replySchema)
        return try AIAnswers.reply(answer, format: format)
    }
}

// MARK: - Summarizing a thread

extension AIService {
    /// 2–4 bullets on a Slack thread or email conversation and what's waiting on the user, for the summary
    /// card in Messages. `messages` oldest first (the prompt keeps the first and the newest that fit).
    func summarizeThread(title: String, kind: TaskSource.Kind, messages: [ThreadMessage], myName: String?,
                         now: Date = Date()) async throws -> SummaryText {
        let client = try client()
        guard !messages.isEmpty else { throw AIError.badResponse(AIAnswers.emptySummary) }
        let calendar = Calendar.current
        let answer = try await client.generate(
            system: AIPrompts.summarySystem(kind, myName: AIPrompts.personName(myName), now: now, calendar: calendar),
            prompt: AIPrompts.summaryInput(title: title, kind: kind, messages: messages, calendar: calendar),
            schema: AIPrompts.summarySchema)
        return try AIAnswers.summary(answer)
    }
}

// MARK: - Reading answers

/// Reads the model's JSON answers. Lenient on purpose: a missing or mistyped field falls back to
/// "not set" instead of failing the whole answer, and anything unusable is dropped.
enum AIAnswers {
    static func object(_ data: Data) throws -> [String: Any] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw AIError.badResponse(GeminiClient.unexpectedFormat)
        }
        return object
    }

    private static func items(_ data: Data, key: String) throws -> [[String: Any]] {
        guard let list = try object(data)[key] as? [Any] else {
            throw AIError.badResponse(GeminiClient.unexpectedFormat)
        }
        return list.compactMap { $0 as? [String: Any] }
    }

    /// {"tasks": [draft…]} → drafts; items without a usable title are skipped.
    static func drafts(_ data: Data, calendar: Calendar) throws -> [TaskDraft] {
        try items(data, key: "tasks").compactMap { draft($0, calendar: calendar) }
    }

    /// {"tasks": [{"message": n, …}]} → (0-based message index, draft). Unknown or repeated numbers are dropped.
    static func triage(_ data: Data, count: Int, calendar: Calendar) throws -> [(index: Int, draft: TaskDraft)] {
        var taken = Set<Int>()
        return try items(data, key: "tasks").compactMap { item in
            guard let number = item.integer("message"), number >= 1, number <= count,
                  taken.insert(number).inserted, let draft = draft(item, calendar: calendar) else { return nil }
            return (index: number - 1, draft: draft)
        }
    }

    /// {"subtasks": […], "estimateMinutes": n} → clean steps (none it already has) and a sane estimate.
    static func breakDown(_ data: Data, existing: [String]) throws -> (subtasks: [String], estimateMinutes: Int?) {
        let root = try object(data)
        var seen = Set(existing.map(key))
        let steps = root.strings("subtasks").map { title($0, limit: 120) }.filter { !$0.isEmpty && seen.insert(key($0)).inserted }
        return (Array(steps.prefix(10)), estimate(root.integer("estimateMinutes")))
    }

    /// {"order": [{"task": n, "reason": "…"}]} → (0-based index, reason), each task at most once.
    static func order(_ data: Data, count: Int) throws -> [(index: Int, reason: String)] {
        var taken = Set<Int>()
        return try items(data, key: "order").compactMap { item in
            guard let number = item.integer("task"), number >= 1, number <= count, taken.insert(number).inserted else { return nil }
            return (index: number - 1, reason: item.text("reason").map { title($0, limit: 140) } ?? "")
        }
    }

    /// {"reply": "…"} → the reply, tidied for where it goes (see `tidyReply`). No text is a `badResponse`.
    static func reply(_ data: Data, format: AIPrompts.ReplyFormat) throws -> String {
        guard let raw = try object(data)["reply"] as? String else {
            throw AIError.badResponse(GeminiClient.unexpectedFormat)
        }
        let reply = tidyReply(raw, format: format)
        guard !reply.isEmpty else { throw AIError.badResponse(emptyReply) }
        return reply
    }

    static let emptyReply = "Gemini didn't write a reply. Try again, or add a note on what to say."

    /// {"bullets": […], "needsFromYou": "…"} → at most 4 clean bullets, and what's waiting on the user (nil
    /// when nothing is, however the model says so). No bullets is a `badResponse`.
    static func summary(_ data: Data) throws -> SummaryText {
        let root = try object(data)
        var seen = Set<String>()
        let bullets = root.strings("bullets")
            .map { title($0.trimmingCharacters(in: CharacterSet(charactersIn: "-•*·–— ").union(.whitespacesAndNewlines)), limit: 220) }
            .filter { !$0.isEmpty && seen.insert(key($0)).inserted }
        guard !bullets.isEmpty else { throw AIError.badResponse(emptySummary) }
        var needs = root.text("needsFromYou").map { title($0, limit: 220) }
        if let n = needs, nothingWaiting.contains(key(n).trimmingCharacters(in: CharacterSet(charactersIn: ".!"))) { needs = nil }
        return SummaryText(bullets: Array(bullets.prefix(4)), needsFromYou: needs?.isEmpty == false ? needs : nil)
    }

    static let emptySummary = "Gemini didn't write a summary. Try again."

    /// What models write instead of null when nothing is waiting.
    private static let nothingWaiting: Set<String> = ["nothing", "none", "no", "nothing needed", "nothing from you", "no action needed",
                                                      "no action", "n/a", "nothing is needed", "nothing right now"]

    /// Fixes the slips models make out of habit: line breaks escaped twice, Markdown bold (one asterisk in
    /// Slack, none in a plain-text email), Markdown links (as "text (url)", which both show as a link), a
    /// subject line on top of an email, trailing spaces and runs of blank lines.
    static func tidyReply(_ raw: String, format: AIPrompts.ReplyFormat) -> String {
        var text = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if !text.contains("\n"), text.contains(#"\n"#) {
            text = text.replacingOccurrences(of: #"\n"#, with: "\n").replacingOccurrences(of: #"\""#, with: "\"")
        }
        text = text.replacingOccurrences(of: #"\*\*(?=\S)([^\n]+?)(?<=\S)\*\*"#, with: format == .slack ? "*$1*" : "$1",
                                         options: .regularExpression)
        text = text.replacingOccurrences(of: #"\[(https?://[^\s()\[\]]+)\]\(\1\)"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\[([^\[\]\n]+)\]\((https?://[^\s()]+)\)"#, with: "$1 ($2)", options: .regularExpression)
        var lines = text.components(separatedBy: "\n").map { $0.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) }
        if format == .email, let first = lines.firstIndex(where: { !$0.isEmpty }), lines[first].lowercased().hasPrefix("subject:") {
            lines.removeSubrange(...first)
        }
        return lines.joined(separator: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What's still to fill in a drafted reply ("[date]", "[link to the deck]"), in order, each once: for a
    /// last look before it's sent. Checkboxes, footnote numbers and Markdown links don't count.
    static func placeholders(in text: String) -> [String] {
        let ns = text as NSString
        var seen = Set<String>()
        return placeholderPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            let found = ns.substring(with: match.range)
            guard ns.substring(with: match.range(at: 1)).filter(\.isLetter).count >= 2,
                  seen.insert(found.lowercased()).inserted else { return nil }
            return found
        }
    }

    private static let placeholderPattern = try! NSRegularExpression(pattern: #"\[([^\[\]\n]{1,80})\](?!\()"#)

    /// One task object from the model, cleaned up.
    static func draft(_ item: [String: Any], calendar: Calendar) -> TaskDraft? {
        let name = title(item.text("title") ?? "", limit: 140)
        guard !name.isEmpty else { return nil }
        var d = TaskDraft(title: name)
        d.notes = item.text("notes").map { String($0.prefix(2_000)) } ?? ""
        if let due = due(item.text("due"), hasTime: item.flag("hasTime"), calendar: calendar) {
            d.due = due.date
            d.dueHasTime = due.hasTime
        }
        d.estimateMinutes = estimate(item.integer("estimateMinutes"))
        d.priority = priority(item.text("priority"))
        if let list = item.text("list"), list.caseInsensitiveCompare("Inbox") != .orderedSame { d.listName = list }
        var tags = Set<String>()
        d.tags = item.strings("tags")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).replacingOccurrences(of: " ", with: "-") }
            .filter { !$0.isEmpty && tags.insert($0.lowercased()).inserted }
            .prefix(5).map { String($0.prefix(40)) }
        var steps = Set<String>()
        d.subtasks = Array(item.strings("subtasks").map { title($0, limit: 120) }
            .filter { !$0.isEmpty && steps.insert(key($0)).inserted }.prefix(10))
        if let person = item.text("waitingOn"), !["me", "you", "myself", "nobody", "no one"].contains(person.lowercased()) {
            d.waitingOn = String(person.prefix(60))
        }
        if d.due != nil, let minutes = item.integer("reminderMinutesBefore"), (0...(14 * 24 * 60)).contains(minutes) {
            d.reminderMinutesBefore = minutes
            d.reminderIsAlarm = item.flag("alarm")
        }
        d.reason = item.text("reason").map { title($0, limit: 160) }.flatMap { $0.isEmpty ? nil : $0 }
        return d
    }

    /// "2026-10-07" (date only) or "2026-10-08T10:00" (local time; seconds and a zone are tolerated).
    /// A midnight time the model didn't mark as timed, or an impossible time, leaves just the date.
    /// Impossible dates are dropped.
    static func due(_ text: String?, hasTime: Bool, calendar: Calendar) -> (date: Date, hasTime: Bool)? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              let match = duePattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        func group(_ i: Int) -> String? {
            guard let r = Range(match.range(at: i), in: text) else { return nil }
            return String(text[r])
        }
        guard let year = group(1).flatMap(Int.init), let month = group(2).flatMap(Int.init), let day = group(3).flatMap(Int.init),
              (2000...2200).contains(year), (1...12).contains(month), (1...31).contains(day) else { return nil }

        var cal = AIPrompts.gregorian(calendar)
        var parts = DateComponents(year: year, month: month, day: day)
        // A time counts when it's a real one and either marked as timed or not plain midnight.
        var timed = false
        if let hour = group(4).flatMap(Int.init), let minute = group(5).flatMap(Int.init),
           (0...23).contains(hour), (0...59).contains(minute), hasTime || hour != 0 || minute != 0 {
            timed = true
            parts.hour = hour
            parts.minute = minute
            if let zone = group(7), let offset = zoneOffset(zone), let tz = TimeZone(secondsFromGMT: offset) { cal.timeZone = tz }
        }
        guard let date = cal.date(from: parts) else { return nil }
        // Reject dates that rolled over ("2026-02-30" would quietly become 2 March).
        let check = cal.dateComponents([.year, .month, .day], from: date)
        guard check.year == year, check.month == month, check.day == day else { return nil }
        return timed ? (date, true) : (calendar.startOfDay(for: date), false)
    }

    private static let duePattern = try! NSRegularExpression(
        pattern: #"^(\d{4})-(\d{1,2})-(\d{1,2})(?:[T ](\d{1,2}):(\d{2})(?::(\d{2})(?:\.\d+)?)?)?\s*(Z|[+-]\d{2}:?\d{2})?$"#)

    /// "Z", "+05:30", "-0700" → seconds east of GMT.
    private static func zoneOffset(_ zone: String) -> Int? {
        if zone == "Z" { return 0 }
        let digits = zone.dropFirst().filter(\.isNumber)
        guard digits.count == 4, let hours = Int(digits.prefix(2)), let minutes = Int(digits.suffix(2)) else { return nil }
        let seconds = hours * 3600 + minutes * 60
        return zone.hasPrefix("-") ? -seconds : seconds
    }

    private static func priority(_ text: String?) -> Priority {
        switch text?.lowercased() {
        case "urgent": .urgent
        case "high": .high
        case "medium": .medium
        case "low": .low
        default: .none
        }
    }

    /// Positive minutes up to a full day; anything else means "no estimate".
    private static func estimate(_ minutes: Int?) -> Int? {
        guard let minutes, minutes > 0 else { return nil }
        return min(minutes, 24 * 60)
    }

    /// Trimmed, one line, no trailing full stop, at most `limit` characters.
    private static func title(_ text: String, limit: Int) -> String {
        var s = text.components(separatedBy: .newlines).joined(separator: " ")
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasSuffix("."), !s.hasSuffix("..") { s.removeLast() }
        return s.count > limit ? String(s.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…" : s
    }

    private static func key(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).trimmingCharacters(in: .whitespaces)
    }
}

/// Loose readers for the model's JSON: one field of the wrong type never sinks the whole answer.
private extension Dictionary where Key == String, Value == Any {
    /// A non-empty string; "null"/"none" (written as text) count as missing.
    func text(_ key: String) -> String? {
        guard let raw = self[key] as? String else { return nil }
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty || ["null", "none", "n/a", "nil"].contains(s.lowercased()) ? nil : s
    }

    /// A whole number, also when written as 30.0 or "30". Booleans don't count.
    func integer(_ key: String) -> Int? {
        let value: Double?
        switch self[key] {
        case let n as NSNumber where CFGetTypeID(n) != CFBooleanGetTypeID(): value = n.doubleValue
        case let s as String: value = Double(s.trimmingCharacters(in: .whitespaces))
        default: value = nil
        }
        guard let value, value.isFinite, abs(value) < 1_000_000_000 else { return nil }
        return Int(value.rounded())
    }

    func flag(_ key: String) -> Bool {
        switch self[key] {
        case let b as Bool: b
        case let s as String: s.lowercased() == "true"
        default: false
        }
    }

    /// Non-empty strings from an array (other values skipped).
    func strings(_ key: String) -> [String] {
        (self[key] as? [Any] ?? []).compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}

// MARK: - Adding planned tasks

extension Store {
    /// Adds the tasks the planner made as one undo step ("Add Tasks"): one ⌘Z takes them all back.
    /// A group around each task's own step (rather than one snapshot with undo switched off), so
    /// whatever joins the step as the tasks appear is undone with them too: the Slack or Gmail card
    /// a task made through Edit… retires comes back on ⌘Z.
    @discardableResult
    func addPlannedTasks(_ items: [TaskItem]) -> [TaskItem] {
        guard !items.isEmpty else { return [] }
        let manager = undoManager
        manager?.beginUndoGrouping()
        let added = items.map { addTask($0) }
        manager?.setActionName(items.count == 1 ? "New Task" : "Add Tasks")
        manager?.endUndoGrouping()
        return added
    }
}
