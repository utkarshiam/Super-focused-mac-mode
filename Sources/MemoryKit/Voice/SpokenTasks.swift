import Foundation

/// Turns a dictated request ("call Rohan next Friday at 3 for half an hour, remind me 15 minutes before") into
/// scheduled tasks: title, deadline vs "Do on" day, time, length, reminder or alarm, repeat, priority, list,
/// tags. One Gemini call; any language or mix in, English titles out. Unlike `VoiceDebriefer` (a meeting told
/// after the fact), this is the user telling Docket what to put in their calendar, so every scheduling word counts.
public struct SpokenTaskParser: Sendable {
    public var ai: MemoryAI
    public var listNames: [String]
    public var knownPeople: [String]
    public var timeZone: TimeZone

    public init(ai: MemoryAI, listNames: [String] = [], knownPeople: [String] = [], timeZone: TimeZone = .current) {
        self.ai = ai
        self.listNames = listNames
        self.knownPeople = knownPeople
        self.timeZone = timeZone
    }

    /// The tasks in `text` (usually one), dated against `now`. Throws `MemoryAIError`; empty text throws too.
    public func parse(_ text: String, now: Date = Date()) async throws -> [DebriefTask] {
        let spoken = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else { throw MemoryAIError.badResponse("Nothing was said.") }
        let data = try await ai.generateJSON(system: Self.system,
                                             prompt: Self.prompt(spoken, now: now, timeZone: timeZone,
                                                                 listNames: listNames, knownPeople: knownPeople),
                                             schema: Self.schema)
        return try Self.parse(data, now: now, timeZone: timeZone, listNames: listNames)
    }

    // MARK: Prompt

    static let system = """
        The user dictated one or more tasks to schedule in their to-do app. Return each task exactly as asked; \
        never invent tasks, people, dates or details.

        Rules:
        - title: short imperative English, starting with a verb, without the scheduling words ("Call Rohan Mehta \
        about the quote"). Keep names as spoken; use a known spelling when it matches.
        - Dates and times are resolved against the "Now" line, in the user's local time. "tomorrow", "Friday" \
        (the next one; today counts only if a later time today is given), "next week" (Monday of next week), \
        "end of month" (its last day), "in 2 hours" (exact time). A time alone means its next occurrence.
        - due: the deadline or the time it happens. "by Friday", "before the board meeting on 20 Oct", "due \
        Friday" → dueDate. "at 3", "Friday at 3pm", "on Monday 10:30" → dueDate + dueTime (that's when it's \
        scheduled). dueDate "" when none.
        - doOn: only when the user separates the day they'll work on it from the deadline ("work on the deck \
        Monday, it's due Friday" → doOn Monday, due Friday). Otherwise "".
        - minutes: the length when said ("for an hour" 60, "half an hour" 30, "15 min call" 15), else 0.
        - reminderMinutes: when a reminder is asked: "remind me 15 minutes before" 15, "remind me at the time" 0, \
        "remind me an hour before" 60; -1 when no reminder is mentioned. alarm: true when they say alarm, wake \
        me, or don't let me miss it.
        - repeat: "" or one of daily | weekly | monthly | yearly, with interval (every 2 weeks → 2) and weekdays \
        1–7 (1 = Sunday … 7 = Saturday): "every Monday" weekly [2]; "every weekday" weekly [2,3,4,5,6]; \
        "every Tuesday and Thursday" weekly [3,5]. For a repeat with no start date, due is its first occurrence.
        - priority: 3 for urgent/important/asap/high priority, 4 for "top priority"/"critical", 1 for low, else 0.
        - listName: one of the given lists when named or clearly meant ("for work" → Work), else "".
        - tags: words the user marks as tags ("tag it finance"), lowercase, else [].
        - waitingOn: the person when the task is to chase someone else's work ("follow up with Priya on the \
        samples"), else "".
        - notes: any extra detail said that isn't scheduling, else "".
        """

    static func prompt(_ spoken: String, now: Date, timeZone: TimeZone, listNames: [String], knownPeople: [String]) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.timeZone = timeZone
        f.dateFormat = "EEEE d MMMM yyyy, HH:mm"
        var lines = ["Now: \(f.string(from: now)) (\(timeZone.identifier))"]
        lines.append(listNames.isEmpty ? "Lists: none (leave listName empty)." : "Lists: \(listNames.joined(separator: ", "))")
        if !knownPeople.isEmpty { lines.append("People the user knows: \(knownPeople.prefix(60).joined(separator: ", "))") }
        lines.append("")
        lines.append("Dictated (speech recognition, may misspell names):\n\(spoken)")
        return lines.joined(separator: "\n")
    }

    public static let schema: MemoryJSON = MemoryJSON.Schema.object([
        "tasks": MemoryJSON.Schema.array(MemoryJSON.Schema.object([
            "title": MemoryJSON.Schema.string(),
            "notes": MemoryJSON.Schema.string(),
            "dueDate": MemoryJSON.Schema.string("YYYY-MM-DD or \"\""),
            "dueTime": MemoryJSON.Schema.string("HH:mm or \"\""),
            "doOn": MemoryJSON.Schema.string("YYYY-MM-DD or \"\""),
            "minutes": MemoryJSON.Schema.integer,
            "reminderMinutes": MemoryJSON.Schema.integer,
            "alarm": MemoryJSON.Schema.boolean,
            "repeat": MemoryJSON.Schema.string(enum: ["", "daily", "weekly", "monthly", "yearly"]),
            "interval": MemoryJSON.Schema.integer,
            "weekdays": MemoryJSON.Schema.array(MemoryJSON.Schema.integer, maxItems: 7),
            "priority": MemoryJSON.Schema.integer,
            "listName": MemoryJSON.Schema.string(),
            "tags": MemoryJSON.Schema.array(MemoryJSON.Schema.string(), maxItems: 5),
            "waitingOn": MemoryJSON.Schema.string(),
        ]), maxItems: 10),
    ])

    // MARK: Answer

    private struct Raw: Decodable {
        struct RawTask: Decodable {
            var title = "", notes = "", dueDate = "", dueTime = "", doOn = "", repeatRule = "", listName = "", waitingOn = ""
            var minutes = 0, reminderMinutes = -1, interval = 1, priority = 0
            var alarm = false
            var weekdays: [Int] = [], tags: [String] = []

            private enum CodingKeys: String, CodingKey {
                case title, notes, dueDate, dueTime, doOn, minutes, reminderMinutes, alarm, interval, weekdays, priority
                case listName, tags, waitingOn
                case repeatRule = "repeat"
            }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                title = c.value(.title, default: "")
                notes = c.value(.notes, default: "")
                dueDate = c.value(.dueDate, default: "")
                dueTime = c.value(.dueTime, default: "")
                doOn = c.value(.doOn, default: "")
                repeatRule = c.value(.repeatRule, default: "")
                listName = c.value(.listName, default: "")
                waitingOn = c.value(.waitingOn, default: "")
                minutes = c.value(.minutes, default: 0)
                reminderMinutes = c.value(.reminderMinutes, default: -1)
                interval = c.value(.interval, default: 1)
                priority = c.value(.priority, default: 0)
                alarm = c.value(.alarm, default: false)
                weekdays = c.value(.weekdays, default: [])
                tags = c.value(.tags, default: [])
            }
        }
        var tasks: [RawTask]

        private enum CodingKeys: String, CodingKey { case tasks }
        init(from decoder: Decoder) throws {
            tasks = try decoder.container(keyedBy: CodingKeys.self).value(.tasks, default: [])
        }
    }

    /// Decodes Gemini's answer into tasks with real dates in `timeZone` and values clamped to what Docket allows.
    public static func parse(_ data: Data, now: Date, timeZone: TimeZone = .current, listNames: [String] = []) throws -> [DebriefTask] {
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data) else {
            throw MemoryAIError.badResponse(MemoryAIError.unexpectedFormat)
        }
        return raw.tasks.compactMap { t in
            let title = t.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            let due = VoiceDebriefer.dueDate(day: t.dueDate, time: t.dueTime, after: now, timeZone: timeZone)
            let doOn = VoiceDebriefer.dueDate(day: t.doOn, time: "", after: now, timeZone: timeZone)?.date
            let list = t.listName.trimmingCharacters(in: .whitespacesAndNewlines)
            let waiting = t.waitingOn.trimmingCharacters(in: .whitespacesAndNewlines)
            let rule = TaskRepeat.Frequency(rawValue: t.repeatRule.lowercased())
                .map { TaskRepeat(frequency: $0, interval: min(max(1, t.interval), 52), weekdays: $0 == .weekly ? t.weekdays : []) }
            return DebriefTask(title: title, notes: t.notes.trimmingCharacters(in: .whitespacesAndNewlines),
                               dueDate: due?.date, dueHasTime: due?.hasTime ?? false,
                               estimateMinutes: t.minutes > 0 ? min(t.minutes, 12 * 60) : nil,
                               priority: max(0, min(4, t.priority)),
                               waitingOn: waiting.isEmpty ? nil : waiting,
                               listName: listNames.first { $0.caseInsensitiveCompare(list) == .orderedSame },
                               scheduledDate: doOn,
                               reminderMinutes: t.reminderMinutes >= 0 ? min(t.reminderMinutes, 7 * 24 * 60) : nil,
                               isAlarm: t.alarm, repeatRule: rule,
                               tags: t.tags.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        }
    }
}
