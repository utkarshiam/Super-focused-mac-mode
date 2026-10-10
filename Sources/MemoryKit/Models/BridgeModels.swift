import Foundation

// MARK: - Capture envelope (phone → Mac)

/// One capture dropped into `<root>/Inbox/` by the iPhone app (or a Shortcut, or anything else).
///
/// File: `<root>/Inbox/<id>.capture.json`, UTF-8 JSON, ISO 8601 dates, every key optional except `kind`:
/// ```json
/// {
///   "version": 1,
///   "id": "6F1C…-UUID",            // also the attachment's prefix
///   "kind": "note" | "link" | "photo" | "voice" | "file" | "task" | "taskDone" | "taskUndone" | "taskDelete",
///   "createdAt": "2026-10-09T08:15:00Z",
///   "title": "Optional title",       // task: the task title
///   "text": "Note text, or a caption",
///   "url": "https://…",              // link
///   "attachmentName": "IMG_0042.heic", // original name; the file is "<id>--IMG_0042.heic" next to it
///   "due": "2026-10-12T00:00:00Z",   // task, optional
///   "dueHasTime": false,             // task
///   "taskID": "UUID",                // taskDone/taskUndone/taskDelete: which task (TaskSnapshot.id)
///   "task": { DebriefTask },          // task: every field when the phone parsed it (dictated scheduling);
///                                    // its id is the envelope id. Older envelopes have only title/due.
///   "transcript": "…",               // voice: what on-device speech recognition heard (rough)
///   "debrief": { VoiceDebrief },      // voice: already processed on the phone; the Mac creates its
///                                    // tasks (with the same ids) and the memory without asking Gemini again
///   "device": "iPhone"               // free text, shown as "captured from"
/// }
/// ```
/// Writers write the attachment first and the envelope last (both atomically), so a reader that sees
/// the envelope can expect the attachment (modulo iCloud still downloading it).
/// A file in Inbox with no envelope is a capture of that file by itself.
public struct CaptureEnvelope: Identifiable, Hashable, Codable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case note, link, photo, voice, file, task, taskDone, taskUndone, taskDelete

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .note
        }

        /// Task envelopes ask the Mac to change tasks; the others become memories.
        public var isTask: Bool { [.task, .taskDone, .taskUndone, .taskDelete].contains(self) }
    }

    public static let currentVersion = 1

    public var version: Int
    public var id: UUID
    public var kind: Kind
    public var createdAt: Date
    public var title: String?
    public var text: String?
    public var url: String?
    public var attachmentName: String?
    public var due: Date?
    public var dueHasTime: Bool
    public var taskID: UUID?
    public var device: String?
    /// Voice: on-device transcript (rough), so the Mac has words even before it hears the audio.
    public var transcript: String?
    /// Voice: the phone's finished debrief. Nil when the phone couldn't process it (no key, offline).
    public var debrief: VoiceDebrief?
    /// Task: the fully parsed task (date, time, length, reminder, repeat…) when the phone understood it.
    public var task: DebriefTask?

    public init(id: UUID = UUID(), kind: Kind, createdAt: Date = Date(), title: String? = nil, text: String? = nil,
                url: String? = nil, attachmentName: String? = nil, due: Date? = nil, dueHasTime: Bool = false,
                taskID: UUID? = nil, device: String? = nil, transcript: String? = nil, debrief: VoiceDebrief? = nil,
                task: DebriefTask? = nil) {
        self.version = Self.currentVersion
        self.id = id
        self.kind = kind
        self.createdAt = createdAt
        self.title = title
        self.text = text
        self.url = url
        self.attachmentName = attachmentName
        self.due = due
        self.dueHasTime = dueHasTime
        self.taskID = taskID
        self.device = device
        self.transcript = transcript
        self.debrief = debrief
        self.task = task
    }

    private enum CodingKeys: String, CodingKey {
        case version, id, kind, createdAt, title, text, url, attachmentName, due, dueHasTime, taskID, device, transcript, debrief, task
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = c.value(.version, default: Self.currentVersion)
        id = c.value(.id, default: UUID())
        kind = try c.decode(Kind.self, forKey: .kind)
        createdAt = c.value(.createdAt, default: Date())
        title = c.value(.title, default: nil)
        text = c.value(.text, default: nil)
        url = c.value(.url, default: nil)
        attachmentName = c.value(.attachmentName, default: nil)
        due = c.value(.due, default: nil)
        dueHasTime = c.value(.dueHasTime, default: false)
        taskID = c.value(.taskID, default: nil)
        device = c.value(.device, default: nil)
        transcript = c.value(.transcript, default: nil)
        debrief = c.value(.debrief, default: nil)
        task = c.value(.task, default: nil)
    }

    /// "<id>.capture.json"
    public var fileName: String { "\(id.uuidString).capture.json" }
    /// "<id>--<attachmentName>", or nil without an attachment.
    public var attachmentFileName: String? { attachmentName.map { "\(id.uuidString)--\(PhoneBridge.safeFileName($0))" } }
}

// MARK: - Task snapshot

/// A task as the phone sees it (read-only), from the Mac's task store.
public struct TaskSnapshot: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var title: String
    /// Midnight for all-day deadlines, the exact time when `dueHasTime`.
    public var dueDate: Date?
    public var dueHasTime: Bool
    /// The day it's planned for ("My Day"), when different from the deadline.
    public var scheduledDate: Date?
    public var estimateMinutes: Int?
    /// 0 none, 1 low, 2 medium, 3 high, 4 urgent (the Mac's `Priority` raw values).
    public var priority: Int
    /// nil = Inbox.
    public var listName: String?
    public var done: Bool
    public var repeatRule: TaskRepeat?
    /// Minutes before the due time of the first reminder (0 = at it); nil = no reminder.
    public var reminderMinutes: Int?
    public var isAlarm: Bool

    public init(id: UUID, title: String, dueDate: Date? = nil, dueHasTime: Bool = false, scheduledDate: Date? = nil,
                estimateMinutes: Int? = nil, priority: Int = 0, listName: String? = nil, done: Bool = false,
                repeatRule: TaskRepeat? = nil, reminderMinutes: Int? = nil, isAlarm: Bool = false) {
        self.id = id
        self.title = title
        self.dueDate = dueDate
        self.dueHasTime = dueHasTime
        self.scheduledDate = scheduledDate
        self.estimateMinutes = estimateMinutes
        self.priority = priority
        self.listName = listName
        self.done = done
        self.repeatRule = repeatRule
        self.reminderMinutes = reminderMinutes
        self.isAlarm = isAlarm
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, dueDate, dueHasTime, scheduledDate, estimateMinutes, priority, listName, done
        case repeatRule, reminderMinutes, isAlarm
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, default: UUID())
        title = c.value(.title, default: "")
        dueDate = c.value(.dueDate, default: nil)
        dueHasTime = c.value(.dueHasTime, default: false)
        scheduledDate = c.value(.scheduledDate, default: nil)
        estimateMinutes = c.value(.estimateMinutes, default: nil)
        priority = c.value(.priority, default: 0)
        listName = c.value(.listName, default: nil)
        done = c.value(.done, default: false)
        repeatRule = c.value(.repeatRule, default: nil)
        reminderMinutes = c.value(.reminderMinutes, default: nil)
        isAlarm = c.value(.isAlarm, default: false)
    }
}

// MARK: - Library snapshot (Mac → phone)

/// What the Mac publishes for the phone at `<root>/Library/snapshot.json` (compact JSON, ISO dates).
/// The phone reads it and never writes it. Vectors are next to it in `vectors.bin` (`VectorIndex` format)
/// and image thumbnails in `Thumbs/<itemID>.jpg` (≤ 400 px JPEG).
/// ```json
/// {
///   "version": 1,
///   "generatedAt": "…",
///   "items": [MemoryItem…],          // newest first; body capped at ~4 000 characters
///   "profile": MemoryProfile,
///   "lenses": ["founder", …],
///   "tasks": [TaskSnapshot…],        // open tasks: overdue, today, the next 7 days, recent voice-note ones
///   "embeddingModel": "gemini-embedding-2", "embeddingDimensions": 768,
///   "listNames": ["Sales", "Hiring"], // the user's task lists, for debriefs made on the phone
///   "brain": BrainSnapshot             // topics, entities, pages, map (optional; older Macs leave it out)
/// }
/// ```
public struct LibrarySnapshot: Hashable, Codable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var generatedAt: Date
    public var items: [MemoryItem]
    public var profile: MemoryProfile
    public var lenses: [Lens]
    public var tasks: [TaskSnapshot]
    /// The model the vectors in vectors.bin came from ("" when there are none).
    public var embeddingModel: String
    public var embeddingDimensions: Int
    /// The user's task list names, so a debrief on the phone can file tasks into them.
    public var listNames: [String]
    /// The organised brain (areas, topics, people, pages, the map). Nil from a Mac without it.
    public var brain: BrainSnapshot?

    public init(generatedAt: Date = Date(), items: [MemoryItem] = [], profile: MemoryProfile = MemoryProfile(),
                lenses: [Lens] = [], tasks: [TaskSnapshot] = [], embeddingModel: String = "", embeddingDimensions: Int = 0,
                listNames: [String] = [], brain: BrainSnapshot? = nil) {
        self.version = Self.currentVersion
        self.generatedAt = generatedAt
        self.items = items
        self.profile = profile
        self.lenses = lenses
        self.tasks = tasks
        self.embeddingModel = embeddingModel
        self.embeddingDimensions = embeddingDimensions
        self.listNames = listNames
        self.brain = brain
    }

    private enum CodingKeys: String, CodingKey {
        case version, generatedAt, items, profile, lenses, tasks, embeddingModel, embeddingDimensions, listNames, brain
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = c.value(.version, default: Self.currentVersion)
        generatedAt = c.value(.generatedAt, default: Date())
        items = c.value(.items, default: [])
        profile = c.value(.profile, default: MemoryProfile())
        lenses = Lens.decodeList(c.value(.lenses, default: [String]()))
        tasks = c.value(.tasks, default: [])
        embeddingModel = c.value(.embeddingModel, default: "")
        embeddingDimensions = c.value(.embeddingDimensions, default: 0)
        listNames = c.value(.listNames, default: [])
        brain = c.value(.brain, default: nil)
    }

    /// Everyone named in the library, most mentioned first: spelling hints for a debrief.
    public var knownPeople: [String] {
        var counts: [String: Int] = [:]
        for item in items { for p in item.people { counts[p, default: 0] += 1 } }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
    }
}

extension Lens {
    /// Known lenses from raw strings, in order, unknown ones dropped (a newer app may add lenses).
    static func decodeList(_ raw: [String]) -> [Lens] {
        var out: [Lens] = []
        for value in raw {
            if let lens = Lens(rawValue: value), !out.contains(lens) { out.append(lens) }
        }
        return out
    }
}
