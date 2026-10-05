import Foundation

/// The quick dates tasks can be moved to: t / m / w on the keyboard, the bulk edit panel's buttons and
/// the context menu of a multi-selection.
enum QuickDay: CaseIterable, Hashable {
    case today, tomorrow, nextWeek

    /// The action's name ("Today" is fine as an action; the date itself is always shown as a real date).
    var label: String {
        switch self {
        case .today: "Today"
        case .tomorrow: "Tomorrow"
        case .nextWeek: "Next week"
        }
    }

    /// The key that does it in a task list.
    var key: String {
        switch self {
        case .today: "T"
        case .tomorrow: "M"
        case .nextWeek: "W"
        }
    }

    /// Start of that day: today, tomorrow, or the next Monday after today.
    func date(now: Date = Date(), calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: now)
        switch self {
        case .today: return today
        case .tomorrow: return calendar.date(byAdding: .day, value: 1, to: today)!
        case .nextWeek: return Recurrence(frequency: .weekly, weekdays: [2]).advance(today, calendar: calendar)
        }
    }
}

/// Changes made to several tasks at once: the bulk edit panel, keyboard triage and the Task menu when
/// more than one task is selected. Each is a single undo step. Each returns how many tasks it actually
/// changed; when that's none, nothing is recorded, so ⌘Z never undoes a change you can't see.
/// Date changes skip finished tasks: they keep the dates they were done with.
extension Store {
    /// Runs `body` as one undo step called `name`. The store methods it uses (`setDueDay`, `setCompleted`,
    /// `move`…) normally record steps of their own; inside a batch those are folded into this one, so a
    /// single ⌘Z puts every task back and ⇧⌘Z redoes the whole change.
    func undoableBatch(_ name: String, _ body: () -> Void) {
        let manager = undoManager
        undoable(name) {
            manager?.disableUndoRegistration()
            defer { manager?.enableUndoRegistration() }
            body()
        }
    }

    // MARK: Dates

    /// Puts each task on `day` the way dropping it on that day does: a deadline moves there and keeps its
    /// time (and the plan date is cleared, so the task follows its deadline); otherwise the plan date moves.
    @discardableResult
    func moveTasks(_ ids: [UUID], toDay day: Date) -> Int {
        let target = calendar.startOfDay(for: day)
        let changing = bulkTargets(ids).filter { !$0.isCompleted && !isPlaced($0, on: target) }
        guard !changing.isEmpty else { return 0 }
        undoableBatch("Reschedule") {
            for t in changing { move(t.id, toDay: target) }
        }
        return changing.count
    }

    /// Removes the plan date and the deadline (with its time) from each open task.
    @discardableResult
    func clearDates(of ids: [UUID]) -> Int {
        let changing = bulkTargets(ids).filter { !$0.isCompleted && ($0.dueDate != nil || $0.scheduledDate != nil) }
        guard !changing.isEmpty else { return 0 }
        undoableBatch("Remove Dates") {
            for t in changing {
                mutateTask(t.id) {
                    $0.dueDate = nil
                    $0.dueHasTime = false
                    $0.scheduledDate = nil
                }
            }
        }
        return changing.count
    }

    /// "Do Today" on several tasks: plans each open one for `day` and leaves deadlines alone.
    @discardableResult
    func planTasks(_ ids: [UUID], on day: Date) -> Int {
        let target = calendar.startOfDay(for: day)
        let changing = bulkTargets(ids).filter { !$0.isCompleted && $0.scheduledDate.map { calendar.startOfDay(for: $0) } != target }
        guard !changing.isEmpty else { return 0 }
        undoableBatch("Plan") {
            for t in changing { setScheduled(t.id, target) }
        }
        return changing.count
    }

    /// "Move to Tomorrow" on several tasks: whichever date each open one goes by (deadline, else plan date)
    /// moves to tomorrow.
    @discardableResult
    func pushTasksToTomorrow(_ ids: [UUID], now: Date = Date()) -> Int {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        let changing = bulkTargets(ids).filter { !$0.isCompleted && !isPlaced($0, on: tomorrow) }
        guard !changing.isEmpty else { return 0 }
        undoableBatch("Move to Tomorrow") {
            for t in changing { pushToTomorrow(t.id) }
        }
        return changing.count
    }

    // MARK: Done

    /// Ticks off (or reopens) each task that isn't in that state yet. Returns the tasks that changed, with
    /// the next date for repeating ones (they move on to their next occurrence instead of staying done).
    @discardableResult
    func completeTasks(_ ids: [UUID], done: Bool = true) -> [(id: UUID, next: Date?)] {
        let changing = bulkTargets(ids).filter { $0.isCompleted != done }
        guard !changing.isEmpty else { return [] }
        var result: [(id: UUID, next: Date?)] = []
        undoableBatch(done ? "Complete Tasks" : "Reopen Tasks") {
            for t in changing { result.append((t.id, setCompleted(t.id, done))) }
        }
        return result
    }

    // MARK: Details

    @discardableResult
    func setPriority(_ priority: Priority, for ids: [UUID]) -> Int {
        change(ids, "Set Priority", where: { $0.priority != priority }) { $0.priority = priority }
    }

    /// Moves the tasks into a list (nil = Inbox).
    @discardableResult
    func setList(_ listID: UUID?, for ids: [UUID]) -> Int {
        change(ids, "Move to List", where: { $0.listID != listID }) { $0.listID = listID }
    }

    /// Sets (or with nil, removes) the estimate in minutes.
    @discardableResult
    func setEstimate(_ minutes: Int?, for ids: [UUID]) -> Int {
        let value = minutes.map { max(1, $0) }
        return change(ids, "Set Estimate", where: { $0.estimateMinutes != value }) { $0.estimateMinutes = value }
    }

    /// Who the tasks are waiting on; nil or blank clears it.
    @discardableResult
    func setWaitingOn(_ name: String?, for ids: [UUID]) -> Int {
        let value = Self.personName(name)
        // Comparing the stored text also tidies stray spaces ("  " becomes nil).
        return change(ids, "Set Waiting On", where: { $0.waitingOn != value }) { $0.waitingOn = value }
    }

    /// Adds a tag to every task that doesn't have it yet (in any capitalisation). "#Board prep" becomes "Board-prep".
    @discardableResult
    func addTag(_ text: String, to ids: [UUID]) -> Int {
        guard let tag = Self.tagName(text) else { return 0 }
        return change(ids, "Add Tag", where: { !$0.tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame } }) {
            $0.tags.append(tag)
        }
    }

    /// Takes a tag off every task that has it (in any capitalisation).
    @discardableResult
    func removeTag(_ text: String, from ids: [UUID]) -> Int {
        guard let tag = Self.tagName(text) else { return 0 }
        let matches: (String) -> Bool = { $0.caseInsensitiveCompare(tag) == .orderedSame }
        return change(ids, "Remove Tag", where: { $0.tags.contains(where: matches) }) { $0.tags.removeAll(where: matches) }
    }

    // MARK: Sharing

    /// The tasks as a Markdown checklist, one line each, in the order given:
    /// "- [ ] Board prep — Fri 9 Oct · 3:00 PM · 1h 30m". Done tasks are ticked and carry no details.
    func checklistMarkdown(for ids: [UUID], now: Date = Date()) -> String {
        bulkTargets(ids).map { t in
            let title = t.title.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            var details: [String] = []
            if !t.isCompleted {
                if let due = t.dueDate {
                    details.append(Fmt.due(due, hasTime: t.dueHasTime, now: now))
                } else if let planned = t.scheduledDate {
                    details.append(Fmt.absoluteDay(planned, now: now))
                }
                if let minutes = t.estimateMinutes { details.append(Fmt.duration(minutes: minutes)) }
            }
            let line = "- [\(t.isCompleted ? "x" : " ")] \(title)"
            return details.isEmpty ? line : "\(line) — \(details.joined(separator: " · "))"
        }
        .joined(separator: "\n")
    }

    // MARK: Helpers

    /// Whether moving `t` to `day` would change nothing (same rules as `move(_:toDay:)`): before its deadline
    /// it's already planned for that day; otherwise its deadline is on that day with no separate plan date,
    /// or it has no deadline and is planned for that day.
    func isPlaced(_ t: TaskItem, on day: Date) -> Bool {
        let target = calendar.startOfDay(for: day)
        let plannedThere = t.scheduledDate.map { calendar.isDate($0, inSameDayAs: target) } ?? false
        guard let due = t.dueDate else { return plannedThere }
        if calendar.startOfDay(for: due) > target { return plannedThere }
        return t.scheduledDate == nil && calendar.isDate(due, inSameDayAs: target)
    }

    /// A tag as it's stored: no leading "#", no spaces (they become "-"). Nil when nothing is left.
    static func tagName(_ text: String) -> String? {
        let words = text.trimmingCharacters(in: CharacterSet(charactersIn: "#").union(.whitespacesAndNewlines))
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        return words.isEmpty ? nil : words.joined(separator: "-")
    }

    /// A person's name as stored in `waitingOn`: trimmed, nil when blank.
    static func personName(_ text: String?) -> String? {
        guard let name = text?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        return name
    }

    /// The existing tasks for `ids`, in that order, without repeats.
    private func bulkTargets(_ ids: [UUID]) -> [TaskItem] {
        let byID = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<UUID>()
        return ids.compactMap { seen.insert($0).inserted ? byID[$0] : nil }
    }

    /// Applies `edit` to the tasks that `needsChange` picks, as one undo step. Returns how many changed.
    private func change(_ ids: [UUID], _ name: String, where needsChange: (TaskItem) -> Bool, _ edit: (inout TaskItem) -> Void) -> Int {
        let changing = bulkTargets(ids).filter(needsChange)
        guard !changing.isEmpty else { return 0 }
        undoableBatch(name) {
            for t in changing { mutateTask(t.id, edit) }
        }
        return changing.count
    }
}
