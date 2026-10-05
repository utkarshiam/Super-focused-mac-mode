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
    /// later day, or it was on today's plate and now sits on a later day. (Dropping today's plan date from
    /// a task due later in the week moves no date later, but the task left today.) Setting a first date,
    /// clearing one, moving earlier or changing only the time on the same day isn't a push, and nothing
    /// that happens to a finished task is.
    static func isPostponement(from old: TaskItem, to new: TaskItem, calendar: Calendar, now: Date = Date()) -> Bool {
        guard !old.isCompleted, !new.isCompleted else { return false }
        if movedLater(old.dueDate, new.dueDate, calendar) || movedLater(old.scheduledDate, new.scheduledDate, calendar) {
            return true
        }
        // The day it sits on: the earlier of its plan date and deadline (as in the Calendar and `DayClear`).
        guard let before = old.agendaDay(calendar: calendar), let after = new.agendaDay(calendar: calendar) else { return false }
        let today = calendar.startOfDay(for: now)
        return before <= today && after > today
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

/// Keeps `postponeCount` honest. Each push to a later day adds one, but quick date changes to the same task
/// (clicking around a date picker, "tomorrow" then "next week", a move that sets the deadline and then clears
/// the plan date, "Do Today" taken straight back) are judged together, from where the task was before the
/// first of them: one push at most, and none if it ends up back where it was, earlier, or with a date it
/// didn't have before.
struct SlipTracker {
    /// How long after one date change the next still counts as part of the same decision.
    var window: TimeInterval

    /// Quick date changes to one task, taken together.
    private struct Run {
        /// The latest change.
        var at: Date
        /// The task as it was before the first change.
        var before: TaskItem
        /// Whether the changes so far, taken together, are a push (and so added one to the count).
        var pushed: Bool
        /// The count the latest change left; anything else means the task was changed since (undo, for one).
        var countAfter: Int
    }

    private var recent: [UUID: Run] = [:]
    /// Finished runs are cleared out once there are this many (it grows with a big bulk change, so moving
    /// thousands of tasks at once doesn't sweep the whole table for each one), or a window after the last sweep.
    private var sweepAt = 64
    private var lastSweep = Date.distantPast

    init(window: TimeInterval = 60) {
        self.window = window
    }

    /// Call with every change to a task, before it's stored; updates `new.postponeCount`.
    mutating func record(from old: TaskItem, to new: inout TaskItem, now: Date, calendar: Calendar) {
        guard old.dueDate != new.dueDate || old.scheduledDate != new.scheduledDate else { return }
        let last = recent.removeValue(forKey: new.id)
        guard !old.isCompleted, !new.isCompleted else { return }

        var run = Run(at: now, before: old, pushed: false, countAfter: 0)
        if let last, now >= last.at, now.timeIntervalSince(last.at) < window, old.postponeCount == last.countAfter {
            run.before = last.before
            run.pushed = last.pushed
        }
        let pushed = Slipping.isPostponement(from: run.before, to: new, calendar: calendar, now: now)
        if pushed != run.pushed {
            // A push adds one; ending up back where it was (or earlier) takes it away again.
            new.postponeCount = max(0, new.postponeCount + (pushed ? 1 : -1))
        }
        run.pushed = pushed
        run.countAfter = new.postponeCount
        recent[new.id] = run
        if recent.count >= sweepAt || (recent.count > 64 && now.timeIntervalSince(lastSweep) >= window) {
            recent = recent.filter { now.timeIntervalSince($0.value.at) < window }
            sweepAt = max(64, recent.count * 2)
            lastSweep = now
        }
    }
}

// MARK: - Clearing the day

enum DayClear {
    /// UserDefaults key: the day ("yyyy-MM-dd") the day-cleared moment last played, so it plays once a day.
    static let lastCelebratedKey = "dayClearedCelebratedOn"

    /// On today's plate: overdue, or due or planned for today (a missed plan date rolls forward to today).
    static func isForToday(_ task: TaskItem, now: Date, calendar: Calendar) -> Bool {
        isForToday(task, before: startOfTomorrow(now, calendar))
    }

    /// Open tasks still on today's plate (the Calendar's Overdue and today).
    static func openTasks(in tasks: [TaskItem], now: Date, calendar: Calendar) -> [TaskItem] {
        let tomorrow = startOfTomorrow(now, calendar)
        return tasks.filter { !$0.isCompleted && isForToday($0, before: tomorrow) }
    }

    /// True when ticking off `completed` emptied today: it was one of today's tasks and nothing open is left.
    static func didClearDay(completing completed: TaskItem, in tasks: [TaskItem], now: Date, calendar: Calendar) -> Bool {
        let tomorrow = startOfTomorrow(now, calendar)
        guard completed.isCompleted, isForToday(completed, before: tomorrow) else { return false }
        return !tasks.contains { !$0.isCompleted && isForToday($0, before: tomorrow) }
    }

    /// A plan date or deadline before the start of tomorrow is today or earlier. Comparing against it, worked
    /// out once, keeps a check over thousands of tasks free of calendar math.
    private static func isForToday(_ task: TaskItem, before tomorrow: Date) -> Bool {
        task.dueDate.map { $0 < tomorrow } == true || task.scheduledDate.map { $0 < tomorrow } == true
    }

    private static func startOfTomorrow(_ now: Date, _ calendar: Calendar) -> Date {
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86_400)
    }

    /// At most once a day.
    static func shouldCelebrate(lastCelebrated dayKey: String?, now: Date) -> Bool {
        dayKey != Fmt.dayKey(now)
    }

    /// The tasks a change from `old` to `new` ticked off just now, wherever it came from (a checkbox, a focus
    /// session's Done, an alarm or a notification, a box ticked in a note). Tasks that come back already
    /// done (an import, or an undo long after) don't count, and neither do repeating tasks: they move on
    /// to their next date instead of being done.
    static func justFinished(from old: [TaskItem], to new: [TaskItem], now: Date) -> [UUID] {
        // Ticking a task off changes it in place, so the two lists line up.
        var ids: [UUID] = []
        for i in 0..<min(old.count, new.count) {
            guard old[i].completedAt == nil, let done = new[i].completedAt, old[i].id == new[i].id,
                  abs(now.timeIntervalSince(done)) < 10 else { continue }
            ids.append(new[i].id)
        }
        return ids
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
