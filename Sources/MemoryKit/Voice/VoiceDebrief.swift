import Foundation

// MARK: - Debrief

/// What a spoken debrief ("just walked out of the Mehta meeting…") turns into: the words, a memory of the
/// meeting, and the tasks it implies, each with a real date. Made by `VoiceDebriefer` on whichever device
/// has a key first (usually the phone, seconds after recording); the Mac creates the tasks and the memory.
///
/// Travels inside a `CaptureEnvelope` (`debrief`), so it's plain Codable with ISO dates and tolerant decoding.
public struct VoiceDebrief: Hashable, Codable, Sendable {
    /// Verbatim, in the language spoken (mixed languages stay mixed).
    public var transcript: String
    /// "Pricing follow-up with Mehta Traders": the gist, max 8 words.
    public var title: String
    /// 1–2 sentences on what happened.
    public var summary: String
    public var keyTakeaways: [String]
    public var people: [String]
    public var projects: [String]
    public var tags: [String]
    /// Decisions, ideas, insights and promises other people made to the user. The user's own commitments are
    /// `tasks` instead, so they land in the task list.
    public var moments: [Moment]
    /// Things the user has to do (or chase), in the order spoken.
    public var tasks: [DebriefTask]
    /// When it was spoken.
    public var recordedAt: Date
    /// Which device made it ("iPhone", "Mac"): shown nowhere, useful when debugging sync.
    public var madeBy: String?

    public init(transcript: String, title: String, summary: String, keyTakeaways: [String] = [], people: [String] = [],
                projects: [String] = [], tags: [String] = [], moments: [Moment] = [], tasks: [DebriefTask] = [],
                recordedAt: Date, madeBy: String? = nil) {
        self.transcript = transcript
        self.title = title
        self.summary = summary
        self.keyTakeaways = keyTakeaways
        self.people = people
        self.projects = projects
        self.tags = tags
        self.moments = moments
        self.tasks = tasks
        self.recordedAt = recordedAt
        self.madeBy = madeBy
    }

    private enum CodingKeys: String, CodingKey {
        case transcript, title, summary, keyTakeaways, people, projects, tags, moments, tasks, recordedAt, madeBy
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        transcript = c.value(.transcript, default: "")
        title = c.value(.title, default: "")
        summary = c.value(.summary, default: "")
        keyTakeaways = c.value(.keyTakeaways, default: [])
        people = c.value(.people, default: [])
        projects = c.value(.projects, default: [])
        tags = c.value(.tags, default: [])
        moments = c.value(.moments, default: [])
        tasks = c.value(.tasks, default: [])
        recordedAt = c.value(.recordedAt, default: Date())
        madeBy = c.value(.madeBy, default: nil)
    }

    /// The fallback when no AI is available anywhere: one task to listen back, so a debrief never goes
    /// missing, with whatever the phone transcribed on-device as its notes.
    public static func unprocessed(transcript: String?, recordedAt: Date, madeBy: String? = nil) -> VoiceDebrief {
        let text = transcript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let when = MemoryDates.prompt(recordedAt)
        return VoiceDebrief(transcript: text, title: "Voice note, \(when)", summary: "",
                            tasks: [DebriefTask(title: "Go through the voice note from \(when)", notes: text)],
                            recordedAt: recordedAt, madeBy: madeBy)
    }
}

/// One task from a debrief. `id` is chosen when the debrief is made, so the phone can show the task at once and
/// recognise it when the Mac's task list comes back; the Mac creates its task with this same id.
public struct DebriefTask: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var title: String
    public var notes: String
    /// Local midnight when `dueHasTime` is false, else the exact time.
    public var dueDate: Date?
    public var dueHasTime: Bool
    public var estimateMinutes: Int?
    /// 0 none, 1 low, 2 medium, 3 high, 4 urgent (the Mac's `Priority` raw values).
    public var priority: Int
    /// Set when someone else does it and the user only chases it ("Waiting on Priya").
    public var waitingOn: String?
    /// One of the user's existing lists when it clearly fits, else nil (Inbox).
    public var listName: String?
    public var people: [String]
    /// The day the user plans to work on it ("Do on"), separate from the deadline. Never changes `dueDate`.
    public var scheduledDate: Date?
    /// A reminder this many minutes before the due time (0 = at it); nil = the app's default reminder.
    public var reminderMinutes: Int?
    /// The reminder is a loud alarm ("wake me", "alarm").
    public var isAlarm: Bool
    public var repeatRule: TaskRepeat?
    public var tags: [String]

    public init(id: UUID = UUID(), title: String, notes: String = "", dueDate: Date? = nil, dueHasTime: Bool = false,
                estimateMinutes: Int? = nil, priority: Int = 0, waitingOn: String? = nil, listName: String? = nil,
                people: [String] = [], scheduledDate: Date? = nil, reminderMinutes: Int? = nil, isAlarm: Bool = false,
                repeatRule: TaskRepeat? = nil, tags: [String] = []) {
        self.id = id
        self.title = title
        self.notes = notes
        self.dueDate = dueDate
        self.dueHasTime = dueHasTime
        self.estimateMinutes = estimateMinutes
        self.priority = priority
        self.waitingOn = waitingOn
        self.listName = listName
        self.people = people
        self.scheduledDate = scheduledDate
        self.reminderMinutes = reminderMinutes
        self.isAlarm = isAlarm
        self.repeatRule = repeatRule
        self.tags = tags
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, notes, dueDate, dueHasTime, estimateMinutes, priority, waitingOn, listName, people
        case scheduledDate, reminderMinutes, isAlarm, repeatRule, tags
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, default: UUID())
        title = c.value(.title, default: "")
        notes = c.value(.notes, default: "")
        dueDate = c.value(.dueDate, default: nil)
        dueHasTime = c.value(.dueHasTime, default: false)
        estimateMinutes = c.value(.estimateMinutes, default: nil)
        priority = c.value(.priority, default: 0)
        waitingOn = c.value(.waitingOn, default: nil)
        listName = c.value(.listName, default: nil)
        people = c.value(.people, default: [])
        scheduledDate = c.value(.scheduledDate, default: nil)
        reminderMinutes = c.value(.reminderMinutes, default: nil)
        isAlarm = c.value(.isAlarm, default: false)
        repeatRule = c.value(.repeatRule, default: nil)
        tags = c.value(.tags, default: [])
    }
}

/// How a task repeats, in the Mac's `Recurrence` terms: every `interval` days/weeks/months/years, weekly ones on
/// `weekdays` (1 = Sunday … 7 = Saturday; empty = the due date's weekday).
public struct TaskRepeat: Hashable, Codable, Sendable {
    public enum Frequency: String, Codable, Sendable, CaseIterable { case daily, weekly, monthly, yearly }

    public var frequency: Frequency
    public var interval: Int
    public var weekdays: [Int]

    public init(frequency: Frequency, interval: Int = 1, weekdays: [Int] = []) {
        self.frequency = frequency
        self.interval = max(1, interval)
        self.weekdays = Array(Set(weekdays.filter { (1...7).contains($0) })).sorted()
    }

    private enum CodingKeys: String, CodingKey { case frequency, interval, weekdays }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(frequency: c.value(.frequency, default: .weekly), interval: c.value(.interval, default: 1),
                  weekdays: c.value(.weekdays, default: []))
    }

    /// "every week on Mon", "every 2 weeks", "every weekday", "every month".
    public var label: String {
        let unit = ["daily": "day", "weekly": "week", "monthly": "month", "yearly": "year"][frequency.rawValue]!
        if frequency == .weekly, weekdays == [2, 3, 4, 5, 6], interval == 1 { return "every weekday" }
        var text = interval == 1 ? "every \(unit)" : "every \(interval) \(unit)s"
        if frequency == .weekly, !weekdays.isEmpty {
            let names = Calendar(identifier: .gregorian).shortWeekdaySymbols
            text += " on " + weekdays.map { names[$0 - 1] }.joined(separator: ", ")
        }
        return text
    }
}

// MARK: - Debriefer

/// Turns a recording (or text the phone transcribed) into a `VoiceDebrief` with one Gemini call: transcript,
/// summary, people, moments and tasks with absolute dates resolved against when it was spoken.
public struct VoiceDebriefer: Sendable {
    public var ai: MemoryAI
    public var profile: MemoryProfile
    public var lenses: [Lens]
    /// The user's task lists, so tasks can be filed ("Sales", "Hiring"); empty = everything to the Inbox.
    public var listNames: [String]
    /// People already in memory, so names are spelled the way the user has them.
    public var knownPeople: [String]
    public var timeZone: TimeZone
    /// `TaskContext.promptBlock()` for what was said (when there's a transcript to build it from): names, dates
    /// and notes memory can fill in. Nil leaves the prompt as it was.
    public var memoryContext: String?

    public init(ai: MemoryAI, profile: MemoryProfile = MemoryProfile(), lenses: [Lens] = [], listNames: [String] = [],
                knownPeople: [String] = [], timeZone: TimeZone = .current, memoryContext: String? = nil) {
        self.ai = ai
        self.profile = profile
        self.lenses = lenses
        self.listNames = listNames
        self.knownPeople = knownPeople
        self.timeZone = timeZone
        self.memoryContext = memoryContext
    }

    /// `audio` is the recording (nil when only text is available); `liveTranscript` is what on-device speech
    /// recognition heard, a hint for names and the only input when there's no audio.
    public func debrief(audio: MemoryInlinePart?, liveTranscript: String?, recordedAt: Date,
                        madeBy: String? = nil) async throws -> VoiceDebrief {
        let hint = liveTranscript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard audio != nil || !hint.isEmpty else { throw MemoryAIError.badResponse("There's nothing in this recording.") }
        let data = try await ai.generateJSON(
            system: TaskContext.adding(memoryContext, to: Self.system(lenses: lenses, profile: profile, timeZone: timeZone)),
            prompt: Self.prompt(recordedAt: recordedAt, timeZone: timeZone, hasAudio: audio != nil, liveTranscript: hint,
                                listNames: listNames, knownPeople: knownPeople),
            schema: Self.schema, parts: audio.map { [$0] } ?? [])
        var debrief = try Self.parse(data, recordedAt: recordedAt, timeZone: timeZone, listNames: listNames)
        if debrief.transcript.isEmpty { debrief.transcript = hint }
        debrief.madeBy = madeBy
        return debrief
    }

    // MARK: Prompt

    static func system(lenses: [Lens], profile: MemoryProfile, timeZone: TimeZone) -> String {
        """
        The user just spoke a quick debrief into their phone, usually right after a meeting, call or visit. \
        Turn it into their to-do list and a memory of what happened. Work only from what was said; never \
        invent names, numbers, dates or commitments.

        Rules:
        - transcript: verbatim, in the language(s) spoken (keep Hindi/English or any mix as spoken, in the \
        script it was spoken in; Latin script for romanised speech). Drop filler like "um". "" if silent.
        - title: the gist in max 8 words, naming who or what ("Pricing follow-up with Mehta Traders").
        - summary: 1–2 sentences in English. keyTakeaways: up to 5 concrete points (numbers, names, outcomes).
        - tasks: every action the user has to take or chase, as short imperative English titles starting with \
        a verb ("Send revised quote to Rohan Mehta"). Include the user's own promises ("I said I'd send…"). \
        One task per action; don't split one action into steps; don't add tasks nobody mentioned.
          - date YYYY-MM-DD and time HH:mm (24 h, the user's local time) only when stated or clearly implied \
        ("by Friday", "tomorrow at 3", "end of month" = last day of that month, "next week" = Monday of next \
        week); resolve them against the recording time given below. Otherwise "". A time without a date means \
        the next such time.
          - estimateMinutes when a length is said or obvious (a call ≈ 30), else 0.
          - priority: 3 when urgent or important is said ("asap", "critical", "must"), else 0.
          - waitingOn: the person's name when someone else will do it and the user only needs to follow up, \
        else "". listName: exactly one of the given lists when it clearly fits, else "".
          - notes: one line of context from the debrief (who, what was agreed), "" if the title says it all.
        - people: full names as spoken, never the user. Use a known spelling when it matches. projects: named \
        deals, accounts, products or initiatives.
        - moments: decisions made, ideas, insights, and promises OTHER people made to the user \
        (direction "theirs", who = that person, due YYYY-MM-DD or ""). The user's own commitments go in tasks, \
        not moments.
        - Never write relative dates ("tomorrow") in any text; use dates like "Mon 12 Oct".

        \(MemoryPrompts.context(profile: profile, lenses: lenses))
        """
    }

    static func prompt(recordedAt: Date, timeZone: TimeZone, hasAudio: Bool, liveTranscript: String,
                       listNames: [String], knownPeople: [String]) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.timeZone = timeZone
        f.dateFormat = "EEEE d MMMM yyyy, HH:mm"
        var lines = ["Recorded: \(f.string(from: recordedAt)) (\(timeZone.identifier))"]
        lines.append(listNames.isEmpty ? "Lists: none (leave listName empty)." : "Lists: \(listNames.joined(separator: ", "))")
        if !knownPeople.isEmpty { lines.append("People the user knows: \(knownPeople.prefix(60).joined(separator: ", "))") }
        lines.append("")
        if hasAudio {
            lines.append("The recording is attached; transcribe it yourself.")
            if !liveTranscript.isEmpty {
                lines.append("On-device speech recognition heard (rough, may misspell names):\n\(liveTranscript)")
            }
        } else {
            lines.append("Only this on-device transcript is available (rough, may misspell names):\n\(liveTranscript)")
        }
        return lines.joined(separator: "\n")
    }

    public static let schema: MemoryJSON = MemoryJSON.Schema.object([
        "transcript": MemoryJSON.Schema.string(),
        "title": MemoryJSON.Schema.string(),
        "summary": MemoryJSON.Schema.string(),
        "keyTakeaways": MemoryJSON.Schema.array(MemoryJSON.Schema.string(), maxItems: 5),
        "people": MemoryJSON.Schema.array(MemoryJSON.Schema.string(), maxItems: 20),
        "projects": MemoryJSON.Schema.array(MemoryJSON.Schema.string(), maxItems: 10),
        "tags": MemoryJSON.Schema.array(MemoryJSON.Schema.string(), maxItems: 5),
        "tasks": MemoryJSON.Schema.array(MemoryJSON.Schema.object([
            "title": MemoryJSON.Schema.string(),
            "notes": MemoryJSON.Schema.string(),
            "date": MemoryJSON.Schema.string("YYYY-MM-DD or \"\""),
            "time": MemoryJSON.Schema.string("HH:mm or \"\""),
            "estimateMinutes": MemoryJSON.Schema.integer,
            "priority": MemoryJSON.Schema.integer,
            "waitingOn": MemoryJSON.Schema.string(),
            "listName": MemoryJSON.Schema.string(),
            "people": MemoryJSON.Schema.array(MemoryJSON.Schema.string(), maxItems: 5),
        ]), maxItems: 20),
        "moments": MemoryJSON.Schema.array(MemoryJSON.Schema.object([
            "kind": MemoryJSON.Schema.string(enum: ["decision", "promise", "idea", "insight"]),
            "text": MemoryJSON.Schema.string(),
            "who": MemoryJSON.Schema.string(),
            "due": MemoryJSON.Schema.string("YYYY-MM-DD or \"\""),
            "direction": MemoryJSON.Schema.string(enum: ["mine", "theirs", "none"]),
        ]), maxItems: 12),
    ])

    // MARK: Answer

    private struct Raw: Decodable {
        struct RawTask: Decodable {
            var title: String, notes: String, date: String, time: String, estimateMinutes: Int, priority: Int
            var waitingOn: String, listName: String, people: [String]

            private enum CodingKeys: String, CodingKey {
                case title, notes, date, time, estimateMinutes, priority, waitingOn, listName, people
            }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                title = c.value(.title, default: "")
                notes = c.value(.notes, default: "")
                date = c.value(.date, default: "")
                time = c.value(.time, default: "")
                estimateMinutes = c.value(.estimateMinutes, default: 0)
                priority = c.value(.priority, default: 0)
                waitingOn = c.value(.waitingOn, default: "")
                listName = c.value(.listName, default: "")
                people = c.value(.people, default: [])
            }
        }

        var transcript: String, title: String, summary: String, keyTakeaways: [String], people: [String]
        var projects: [String], tags: [String], tasks: [RawTask]

        private enum CodingKeys: String, CodingKey { case transcript, title, summary, keyTakeaways, people, projects, tags, tasks }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            transcript = c.value(.transcript, default: "")
            title = c.value(.title, default: "")
            summary = c.value(.summary, default: "")
            keyTakeaways = c.value(.keyTakeaways, default: [])
            people = c.value(.people, default: [])
            projects = c.value(.projects, default: [])
            tags = c.value(.tags, default: [])
            tasks = c.value(.tasks, default: [])
        }
    }

    /// Decodes Gemini's answer: real dates in `timeZone`, priorities and estimates clamped, lists matched to
    /// the user's own (case-insensitively), the user's own promises left to `tasks`.
    public static func parse(_ data: Data, recordedAt: Date, timeZone: TimeZone = .current,
                             listNames: [String] = []) throws -> VoiceDebrief {
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data),
              let extraction = try? JSONDecoder().decode(MemoryPrompts.Extraction.self, from: data) else {
            throw MemoryAIError.badResponse(MemoryAIError.unexpectedFormat)
        }
        let tasks: [DebriefTask] = raw.tasks.compactMap { t in
            let title = t.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            let due = dueDate(day: t.date, time: t.time, after: recordedAt, timeZone: timeZone)
            let list = t.listName.trimmingCharacters(in: .whitespacesAndNewlines)
            let waiting = t.waitingOn.trimmingCharacters(in: .whitespacesAndNewlines)
            return DebriefTask(title: title, notes: t.notes.trimmingCharacters(in: .whitespacesAndNewlines),
                               dueDate: due?.date, dueHasTime: due?.hasTime ?? false,
                               estimateMinutes: t.estimateMinutes > 0 ? min(t.estimateMinutes, 8 * 60) : nil,
                               priority: max(0, min(4, t.priority)),
                               waitingOn: waiting.isEmpty ? nil : waiting,
                               listName: listNames.first { $0.caseInsensitiveCompare(list) == .orderedSame },
                               people: t.people.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        }
        let moments = extraction.moments(keeping: []).filter { !($0.kind == .promise && $0.direction == .mine) }
        return VoiceDebrief(transcript: raw.transcript.trimmingCharacters(in: .whitespacesAndNewlines),
                            title: raw.title.trimmingCharacters(in: .whitespacesAndNewlines),
                            summary: raw.summary.trimmingCharacters(in: .whitespacesAndNewlines),
                            keyTakeaways: raw.keyTakeaways, people: raw.people, projects: raw.projects, tags: raw.tags,
                            moments: moments, tasks: tasks, recordedAt: recordedAt)
    }

    /// "2026-10-16" + "15:00" → that moment in `timeZone`. A time with no date is the next such time after
    /// `recordedAt`. Nil when neither parses.
    static func dueDate(day: String, time: String, after recordedAt: Date, timeZone: TimeZone) -> (date: Date, hasTime: Bool)? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let dayParts = day.trimmingCharacters(in: .whitespaces).split(separator: "-").compactMap { Int($0) }
        let timeParts = time.trimmingCharacters(in: .whitespaces).split(separator: ":").compactMap { Int($0) }
        let hasTime = timeParts.count == 2 && (0..<24).contains(timeParts[0]) && (0..<60).contains(timeParts[1])
        if dayParts.count == 3 {
            var c = DateComponents(year: dayParts[0], month: dayParts[1], day: dayParts[2])
            if hasTime { c.hour = timeParts[0]; c.minute = timeParts[1] }
            guard let date = calendar.date(from: c) else { return nil }
            return (date, hasTime)
        }
        guard hasTime else { return nil }
        let match = DateComponents(hour: timeParts[0], minute: timeParts[1])
        guard let next = calendar.nextDate(after: recordedAt, matching: match, matchingPolicy: .nextTime) else { return nil }
        return (next, true)
    }
}
