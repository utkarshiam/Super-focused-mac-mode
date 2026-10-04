import Foundation

// MARK: - Decoding helper

/// Lets every model decode files written by older versions of the app:
/// a missing key falls back to the default instead of failing the whole load.
extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, default fallback: @autoclosure () -> T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback()
    }
}

// MARK: - Priority

enum Priority: Int, Codable, CaseIterable, Identifiable, Comparable {
    case none = 0, low = 1, medium = 2, high = 3, urgent = 4

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .none: "None"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .urgent: "Urgent"
        }
    }

    static func < (a: Priority, b: Priority) -> Bool { a.rawValue < b.rawValue }
}

// MARK: - Subtask

struct Subtask: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var done = false
}

// MARK: - Reminder

struct Reminder: Codable, Identifiable, Hashable {
    enum Trigger: Codable, Hashable {
        /// Minutes before the deadline (0 = at the deadline).
        case beforeDue(minutes: Int)
        case absolute(Date)
    }

    var id = UUID()
    var trigger: Trigger
    /// A loud, repeating alarm with a full-screen-level panel instead of a plain notification.
    var isAlarm = false
    /// Created by "Snooze" — cleaned up automatically once it has fired.
    var isSnooze = false

    init(trigger: Trigger, isAlarm: Bool = false, isSnooze: Bool = false) {
        self.trigger = trigger
        self.isAlarm = isAlarm
        self.isSnooze = isSnooze
    }

    enum CodingKeys: String, CodingKey { case id, trigger, isAlarm, isSnooze }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, default: UUID())
        trigger = try c.decode(Trigger.self, forKey: .trigger)
        isAlarm = c.value(.isAlarm, default: false)
        isSnooze = c.value(.isSnooze, default: false)
    }

    func fireDate(for task: TaskItem, allDayHour: Int, calendar: Calendar = .current) -> Date? {
        switch trigger {
        case .absolute(let date):
            return date
        case .beforeDue(let minutes):
            guard let due = task.dueDateTime(allDayHour: allDayHour, calendar: calendar) else { return nil }
            return due.addingTimeInterval(-Double(minutes) * 60)
        }
    }

    /// How it relates to the deadline ("15m before deadline"); nil for a set time, whose date says it all.
    func describe(for task: TaskItem) -> String? {
        switch trigger {
        case .absolute:
            return nil
        case .beforeDue(let minutes):
            if minutes == 0 { return task.dueHasTime || task.dueDate == nil ? "at deadline" : "on the day" }
            return "\(Fmt.duration(minutes: minutes)) before deadline"
        }
    }
}

// MARK: - Task

struct TaskItem: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var notes = ""
    var listID: UUID?
    var tags: [String] = []
    var priority: Priority = .none
    var estimateMinutes: Int?
    var trackedSeconds = 0
    /// Deadline. When `dueHasTime` is false only the day matters.
    var dueDate: Date?
    var dueHasTime = false
    /// The day you plan to work on it ("Do on"), independent of the deadline.
    var scheduledDate: Date?
    var reminders: [Reminder] = []
    var recurrence: Recurrence?
    var subtasks: [Subtask] = []
    var completedAt: Date?
    var createdAt = Date()
    var updatedAt = Date()
    /// Set for tasks extracted from a note's checklist; keeps the two in sync.
    var linkedNoteID: UUID?
    var noteLine: String?
    /// Manual position among the day's tasks (set by drag and drop). Nil = order by priority.
    var rank: Double?

    init(title: String) { self.title = title }

    enum CodingKeys: String, CodingKey {
        case id, title, notes, listID, tags, priority, estimateMinutes, trackedSeconds, dueDate, dueHasTime
        case scheduledDate, reminders, recurrence, subtasks, completedAt, createdAt, updatedAt, linkedNoteID, noteLine, rank
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, default: UUID())
        title = c.value(.title, default: "")
        notes = c.value(.notes, default: "")
        listID = c.value(.listID, default: nil)
        tags = c.value(.tags, default: [])
        priority = c.value(.priority, default: .none)
        estimateMinutes = c.value(.estimateMinutes, default: nil)
        trackedSeconds = c.value(.trackedSeconds, default: 0)
        dueDate = c.value(.dueDate, default: nil)
        dueHasTime = c.value(.dueHasTime, default: false)
        scheduledDate = c.value(.scheduledDate, default: nil)
        reminders = c.value(.reminders, default: [])
        recurrence = c.value(.recurrence, default: nil)
        subtasks = c.value(.subtasks, default: [])
        completedAt = c.value(.completedAt, default: nil)
        createdAt = c.value(.createdAt, default: Date())
        updatedAt = c.value(.updatedAt, default: Date())
        linkedNoteID = c.value(.linkedNoteID, default: nil)
        noteLine = c.value(.noteLine, default: nil)
        rank = c.value(.rank, default: nil)
    }

    var isCompleted: Bool { completedAt != nil }

    /// The concrete moment the deadline refers to. Date-only deadlines resolve to `allDayHour` on that day.
    func dueDateTime(allDayHour: Int, calendar: Calendar = .current) -> Date? {
        guard let due = dueDate else { return nil }
        if dueHasTime { return due }
        return calendar.date(bySettingHour: allDayHour, minute: 0, second: 0, of: due)
    }

    func isOverdue(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard let due = dueDate, !isCompleted else { return false }
        if dueHasTime { return due < now }
        return calendar.startOfDay(for: due) < calendar.startOfDay(for: now)
    }

    func isDue(onOrBefore day: Date, calendar: Calendar = .current) -> Bool {
        guard let due = dueDate else { return false }
        return calendar.startOfDay(for: due) <= calendar.startOfDay(for: day)
    }

    func isScheduled(onOrBefore day: Date, calendar: Calendar = .current) -> Bool {
        guard let s = scheduledDate else { return false }
        return calendar.startOfDay(for: s) <= calendar.startOfDay(for: day)
    }

    /// The day this task shows up on in "Upcoming": the earlier of its plan date and deadline.
    func agendaDay(calendar: Calendar = .current) -> Date? {
        let days = [scheduledDate, dueDate].compactMap { $0.map(calendar.startOfDay(for:)) }
        return days.min()
    }

    /// Estimate minus the time already tracked, in minutes.
    var remainingMinutes: Int {
        guard let est = estimateMinutes else { return 0 }
        return max(0, est - trackedSeconds / 60)
    }

    var hasAlarm: Bool { reminders.contains { $0.isAlarm } }
    var subtaskProgress: (done: Int, total: Int) { (subtasks.filter(\.done).count, subtasks.count) }
}

// MARK: - Note

struct Note: Codable, Identifiable, Hashable {
    var id = UUID()
    var body: String
    var isPinned = false
    var createdAt = Date()
    var updatedAt = Date()
    /// "yyyy-MM-dd" for daily notes.
    var dailyKey: String?

    init(body: String) { self.body = body }

    enum CodingKeys: String, CodingKey { case id, body, isPinned, createdAt, updatedAt, dailyKey }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, default: UUID())
        body = c.value(.body, default: "")
        isPinned = c.value(.isPinned, default: false)
        createdAt = c.value(.createdAt, default: Date())
        updatedAt = c.value(.updatedAt, default: Date())
        dailyKey = c.value(.dailyKey, default: nil)
    }

    var title: String {
        let first = body.split(separator: "\n", omittingEmptySubsequences: true)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let first else { return "New Note" }
        let stripped = Self.describingMedia(String(first.drop { $0 == "#" || $0 == " " }))
        return stripped.isEmpty ? "New Note" : String(stripped.prefix(120))
    }

    private static let mediaPattern = try! NSRegularExpression(pattern: #"!\[([^\]]*)\]\(([^)]*)\)"#)
    private static let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "avi", "mkv", "webm", "3gp", "mpg", "mpeg"]

    /// "![Board deck](attachments/x.png)" reads as "Photo: Board deck" in titles and previews.
    static func describingMedia(_ line: String) -> String {
        let ns = line as NSString
        var result = line
        for m in mediaPattern.matches(in: line, range: NSRange(location: 0, length: ns.length)).reversed() {
            let alt = ns.substring(with: m.range(at: 1))
            let path = ns.substring(with: m.range(at: 2))
            let kind = videoExtensions.contains((path as NSString).pathExtension.lowercased()) ? "Video" : "Photo"
            let label = alt.isEmpty ? kind : "\(kind): \(alt)"
            result = (result as NSString).replacingCharacters(in: m.range, with: label)
        }
        return result
    }

    /// A few lines after the title with Markdown syntax removed, for list rows.
    var preview: String {
        let lines = body.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let text = lines.dropFirst().prefix(4).map { line in
            Self.describingMedia(line)
                .replacingOccurrences(of: #"^(#{1,6}\s+|>\s?|[-*+]\s+(\[[ xX]\]\s+)?|\d+[.)]\s+)"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"(\*\*|__|`)"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"(?<![\w*])[*_](\S(?:[^*_]*\S)?)[*_](?![\w*])"#, with: "$1", options: .regularExpression)
        }
        return text.filter { !$0.isEmpty }.joined(separator: " · ").prefix(160).description
    }

    var openChecklistCount: Int {
        body.components(separatedBy: "\n").filter { NoteChecklist.isUnchecked($0) }.count
    }
}

// MARK: - List

enum ListColor: String, Codable, CaseIterable, Identifiable {
    case blue, indigo, purple, pink, red, orange, yellow, green, teal, gray
    var id: String { rawValue }
}

struct TaskList: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var color: ListColor = .blue
    var icon = "list.bullet"
    var sortOrder = 0

    init(name: String, color: ListColor = .blue, icon: String = "list.bullet", sortOrder: Int = 0) {
        self.name = name
        self.color = color
        self.icon = icon
        self.sortOrder = sortOrder
    }

    enum CodingKeys: String, CodingKey { case id, name, color, icon, sortOrder }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, default: UUID())
        name = c.value(.name, default: "List")
        color = c.value(.color, default: .blue)
        icon = c.value(.icon, default: "list.bullet")
        sortOrder = c.value(.sortOrder, default: 0)
    }
}

// MARK: - Focus session

struct FocusSession: Codable, Identifiable, Hashable {
    var id = UUID()
    var taskID: UUID?
    var start: Date
    var seconds: Int
}

// MARK: - Database file

struct Database: Codable {
    var version = 1
    var tasks: [TaskItem] = []
    var notes: [Note] = []
    var lists: [TaskList] = []
    var sessions: [FocusSession] = []

    init() {}

    enum CodingKeys: String, CodingKey { case version, tasks, notes, lists, sessions }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = c.value(.version, default: 1)
        tasks = try c.decodeIfPresent([TaskItem].self, forKey: .tasks) ?? []
        notes = try c.decodeIfPresent([Note].self, forKey: .notes) ?? []
        lists = try c.decodeIfPresent([TaskList].self, forKey: .lists) ?? []
        sessions = c.value(.sessions, default: [])
    }
}

// MARK: - Note checklist helpers

enum NoteChecklist {
    // Bullet or numbered items ("- [ ] …", "1. [ ] …", "2) [x] …"), the ones Read mode shows as checkboxes.
    private static let unchecked = try! NSRegularExpression(pattern: #"^(\s*(?:[-*+]|\d{1,9}[.)])\s+)\[ \]\s+(.+?)\s*$"#)
    private static let checked = try! NSRegularExpression(pattern: #"^(\s*(?:[-*+]|\d{1,9}[.)])\s+)\[[xX]\]\s+(.+?)\s*$"#)

    static func isUnchecked(_ line: String) -> Bool { match(unchecked, line) != nil }

    /// The text of an unchecked "- [ ] text" line.
    static func uncheckedText(_ line: String) -> String? { match(unchecked, line) }
    static func checkedText(_ line: String) -> String? { match(checked, line) }

    private static func match(_ re: NSRegularExpression, _ line: String) -> String? {
        let ns = line as NSString
        guard let m = re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: m.range(at: 2))
    }

    /// Any quote depth, spaced as Read mode allows (">  > - [ ] …" is a nested quote too).
    private static let boxOnLine = try! NSRegularExpression(pattern: #"^(\s*+(?:>\s*+)*+(?:[-*+]|\d{1,9}[.)])\s+)(\[[ xX]\])"#)

    /// Flips the checkbox on line `index` (0-based), e.g. when it's clicked in Read mode.
    static func toggle(lineAt index: Int, in body: String) -> String? {
        var lines = body.components(separatedBy: "\n")
        guard lines.indices.contains(index) else { return nil }
        let line = lines[index] as NSString
        guard let m = boxOnLine.firstMatch(in: lines[index], range: NSRange(location: 0, length: line.length)) else { return nil }
        let box = m.range(at: 2)
        lines[index] = line.replacingCharacters(in: box, with: line.substring(with: box) == "[ ]" ? "[x]" : "[ ]")
        return lines.joined(separator: "\n")
    }

    /// Flips the checkbox on the first line whose item text equals `text`.
    static func setChecked(_ checked: Bool, text: String, in body: String) -> String? {
        var lines = body.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            let current = checked ? uncheckedText(line) : checkedText(line)
            guard current == text, let r = line.range(of: checked ? "[ ]" : (line.contains("[x]") ? "[x]" : "[X]")) else { continue }
            lines[i] = line.replacingCharacters(in: r, with: checked ? "[x]" : "[ ]")
            return lines.joined(separator: "\n")
        }
        return nil
    }
}

// Value types handed to the background save queue.
extension Priority: Sendable {}
extension Subtask: Sendable {}
extension Reminder: Sendable {}
extension Reminder.Trigger: Sendable {}
extension TaskItem: Sendable {}
extension Note: Sendable {}
extension ListColor: Sendable {}
extension TaskList: Sendable {}
extension FocusSession: Sendable {}
extension Database: Sendable {}
