import Foundation

// The rules behind the small extras: delegation ("Waiting on"), slipping tasks, the day-cleared
// moment and the one-click overdue rollover. Kept apart from the views so they can be unit-tested.

// MARK: - Delegation

enum Delegation {
    /// A name as typed, tidied: trimmed, with inner runs of spaces collapsed. Nil when nothing is left.
    static func normalized(_ name: String?) -> String? {
        guard let name else { return nil }
        let words = name.split(whereSeparator: \.isWhitespace)
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

    /// The people tasks have waited on, most recently touched first, each name once (ignoring case and accents).
    static func recentPeople(in tasks: [TaskItem], limit: Int = 12) -> [String] {
        let delegated = tasks.filter { $0.waitingOn != nil }.sorted { $0.updatedAt > $1.updatedAt }
        var seen = Set<String>()
        var people: [String] = []
        for task in delegated {
            guard let name = normalized(task.waitingOn),
                  seen.insert(name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)).inserted else { continue }
            people.append(name)
            if people.count == limit { break }
        }
        return people
    }
}

// MARK: - Slipping tasks

enum Slipping {
    /// From this many pushes a row shows "↻ 3×" and the detail asks: do it, delegate it, or drop it.
    static let threshold = 3

    /// Whether a change pushed an open task back: its deadline or its plan date moved from one day to a
    /// later day. Setting a first date, clearing one, moving earlier or changing only the time on the same
    /// day isn't a push, and nothing that happens to a finished task is.
    static func isPostponement(from old: TaskItem, to new: TaskItem, calendar: Calendar) -> Bool {
        guard !old.isCompleted, !new.isCompleted else { return false }
        return movedLater(old.dueDate, new.dueDate, calendar) || movedLater(old.scheduledDate, new.scheduledDate, calendar)
    }

    private static func movedLater(_ old: Date?, _ new: Date?, _ calendar: Calendar) -> Bool {
        guard let old, let new else { return false }
        return calendar.startOfDay(for: new) > calendar.startOfDay(for: old)
    }

    /// Open, pushed back at least `threshold` times, and still yours (once it's delegated, the question is answered).
    static func needsNudge(_ task: TaskItem) -> Bool {
        !task.isCompleted && task.postponeCount >= threshold && Delegation.normalized(task.waitingOn) == nil
    }
}

/// Keeps `postponeCount` honest. Each push to a later day adds one, but quick follow-up changes to the same
/// task (clicking around a date picker, "tomorrow" then "next week", a move that sets the deadline and then
/// clears the plan date) are one push, judged from where the task was before it began. Moving the task back
/// within that window takes the count back down.
struct SlipTracker {
    /// How long after a push further date changes still count as part of it.
    var window: TimeInterval

    private struct Push {
        var at: Date
        /// The task as it was before the push.
        var before: TaskItem
        /// The count the push left; anything else means the task was changed since (undo, for one).
        var countAfter: Int
    }

    private var recent: [UUID: Push] = [:]

    init(window: TimeInterval = 60) {
        self.window = window
    }

    /// Call with every change to a task, before it's stored; updates `new.postponeCount`.
    mutating func record(from old: TaskItem, to new: inout TaskItem, now: Date, calendar: Calendar) {
        guard old.dueDate != new.dueDate || old.scheduledDate != new.scheduledDate else { return }
        let push = recent.removeValue(forKey: new.id)
        guard !old.isCompleted, !new.isCompleted else { return }

        if let push, now >= push.at, now.timeIntervalSince(push.at) < window, old.postponeCount == push.countAfter {
            if Slipping.isPostponement(from: push.before, to: new, calendar: calendar) {
                recent[new.id] = Push(at: now, before: push.before, countAfter: new.postponeCount)
            } else {
                // Back where it was (or earlier): that push didn't happen after all.
                new.postponeCount = max(0, new.postponeCount - 1)
            }
            return
        }

        guard Slipping.isPostponement(from: old, to: new, calendar: calendar) else { return }
        new.postponeCount += 1
        recent[new.id] = Push(at: now, before: old, countAfter: new.postponeCount)
        if recent.count > 64 {
            recent = recent.filter { now.timeIntervalSince($0.value.at) < window }
        }
    }
}

// MARK: - Clearing the day

enum DayClear {
    /// UserDefaults key: the day ("yyyy-MM-dd") the day-cleared moment last played, so it plays once a day.
    static let lastCelebratedKey = "dayClearedCelebratedOn"

    /// On today's plate: overdue, or due or planned for today (a missed plan date rolls forward to today).
    static func isForToday(_ task: TaskItem, now: Date, calendar: Calendar) -> Bool {
        guard let day = task.agendaDay(calendar: calendar) else { return false }
        return day <= calendar.startOfDay(for: now)
    }

    /// Open tasks still on today's plate (the Calendar's Overdue and today).
    static func openTasks(in tasks: [TaskItem], now: Date, calendar: Calendar) -> [TaskItem] {
        tasks.filter { !$0.isCompleted && isForToday($0, now: now, calendar: calendar) }
    }

    /// True when ticking off `completed` emptied today: it was one of today's tasks and nothing open is left.
    static func didClearDay(completing completed: TaskItem, in tasks: [TaskItem], now: Date, calendar: Calendar) -> Bool {
        guard completed.isCompleted, isForToday(completed, now: now, calendar: calendar) else { return false }
        return !tasks.contains { !$0.isCompleted && isForToday($0, now: now, calendar: calendar) }
    }

    /// At most once a day.
    static func shouldCelebrate(lastCelebrated dayKey: String?, now: Date) -> Bool {
        dayKey != Fmt.dayKey(now)
    }
}

// MARK: - Overdue rollover

extension Store {
    /// Open tasks whose deadline day has passed: the Calendar's Overdue group.
    func rolloverCandidates(now: Date = Date()) -> [UUID] {
        let today = calendar.startOfDay(for: now)
        return tasks.filter { !$0.isCompleted && isOverdueByDay($0, today: today) }.map(\.id)
    }

    /// "Move all to today": every overdue task moves to today, keeping its time, as one undo step.
    /// It's an explicit date change (not a drag), so each task counts as pushed back once.
    /// Returns how many tasks moved.
    @discardableResult
    func rollOverdueToToday(now: Date = Date()) -> Int {
        let ids = rolloverCandidates(now: now)
        guard !ids.isEmpty else { return 0 }
        let today = calendar.startOfDay(for: now)
        let manager = undoManager
        undoable("Move to Today") {
            // Each move would record a step of its own; this one step covers them all.
            manager?.disableUndoRegistration()
            defer { manager?.enableUndoRegistration() }
            for id in ids { move(id, toDay: today) }
        }
        return ids.count
    }
}
